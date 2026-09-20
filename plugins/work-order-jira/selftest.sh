#!/bin/bash
#
# selftest.sh — offline tests for the work-order Jira binding.
#
# Nothing here reaches a network, a Jira site or a credential. Every test
# either exercises a --dry-run path, which never opens a socket, or passes
# --http pointing at a stub of jira-http.sh's shape. The stub, not an
# unroutable host, is what makes this network-free: a stub that is never
# reached is an assertion failure, not a pass.
#
# The stub composes its responses from fixtures/, which are recorded live
# responses. Where no live capture exists for a request — a project readback,
# GET /myself, a POST /field response — the stub builds one inline and is
# marked SYNTHETIC at that line.
#
# The stub also keeps what a create sent and serves it back on the matching
# GET, so a ticket can be created and then read back through the repo's own
# Jira reader (conformance/jira_source.py) and compared with what was sent.
# That reader is the one place the field mapping lives, so this file — not the
# binding, which stays self-contained — depends on the repository around it.
#
# Usage: plugins/work-order-jira/selftest.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
FX="$HERE/fixtures"
PROVIDER="$HERE/provider.sh"
PROVISION="$HERE/provision.sh"
WFAPPLY="$HERE/workflow-apply.sh"
HTTPLIB="$HERE/lib/jira-http.sh"
COMMON="$HERE/lib/common.sh"
RULES="$HERE/workflow-rules.json"

for f in "$PROVIDER" "$PROVISION" "$WFAPPLY" "$HTTPLIB"; do
    [ -x "$f" ] || { echo "$f is missing or not executable" >&2; exit 2; }
done
[ -f "$COMMON" ] || { echo "$COMMON is missing" >&2; exit 2; }
[ -f "$RULES" ]  || { echo "$RULES is missing" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq is required to run this selftest" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 \
    || { echo "python3 is required: the round trip reads back through conformance/" >&2; exit 2; }
READER="$HERE/../../conformance/jira_source.py"
[ -f "$READER" ] \
    || { echo "$READER is missing: the round trip has no reader to read back through" >&2; exit 2; }

N=0
FAIL=0
ok()  { N=$((N + 1)); echo "ok - $1"; }
bad() { N=$((N + 1)); FAIL=$((FAIL + 1)); echo "FAIL - $1"; }

eq() {
    if [ "$2" = "$3" ]; then ok "$1"; else
        bad "$1"
        printf '       expected: %s\n' "$2"
        printf '       actual:   %s\n' "$3"
    fi
}
contains() {
    case "$3" in
        *"$2"*) ok "$1" ;;
        *) bad "$1"; printf '       wanted substring: %s\n       in: %s\n' "$2" "$3" ;;
    esac
}
not_contains() {
    case "$3" in
        *"$2"*) bad "$1"; printf '       unwanted substring: %s\n       in: %s\n' "$2" "$3" ;;
        *) ok "$1" ;;
    esac
}
nonempty() {
    if [ -n "$2" ]; then ok "$1"; else bad "$1 (output was empty — the stub was never reached, so this proves nothing)"; fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ---- the stub ------------------------------------------------------------

STUB="$WORK/jira-http-stub.sh"
cat > "$STUB" <<'STUBEOF'
#!/bin/bash
# A jira-http.sh-shaped stub. Responses come from fixtures/ except where
# marked SYNTHETIC. Knobs: WO_TEST_PROJECT, WO_TEST_FIELDS, WO_TEST_WF,
# WO_TEST_SEARCH, WO_TEST_STATUS.
set -uo pipefail
FX="$WO_TEST_FX"
printf '%s\n' "$*" >> "$WO_TEST_LOG"

DRY=0
if [ "${1:-}" = "--dry-run" ]; then DRY=1; shift; fi
M="${1:-}"; P="${2:-}"; B="${3:-}"

fx() { sed -e '/^#/d' -e '/^HTTP [0-9]*$/d' "$FX/$1"; }
notfound() { printf 'HTTP 404\n{"errorMessages":["No project could be found"]}\n' >&2; exit 1; }
badrequest() { printf 'HTTP 400\n' >&2; fx search.jql.not-searchable.txt >&2; exit 1; }

if [ "$DRY" = "1" ]; then
    printf 'WOULD %s %s\n' "$M" "$P"
    [ -n "$B" ] && printf '%s\n' "$B"
    exit 0
fi

ADDED_FIELDS='[{"id":"customfield_10050","name":"human_steps","custom":true,"schema":{"type":"string","custom":"com.atlassian.jira.plugin.system.customfieldtypes:textarea"}},
{"id":"customfield_10051","name":"appends","custom":true,"schema":{"type":"string","custom":"com.atlassian.jira.plugin.system.customfieldtypes:textarea"}},
{"id":"customfield_10052","name":"defer_until","custom":true,"schema":{"type":"date","custom":"com.atlassian.jira.plugin.system.customfieldtypes:datepicker"}},
{"id":"customfield_10053","name":"outcome","custom":true,"schema":{"type":"string","custom":"com.atlassian.jira.plugin.system.customfieldtypes:textarea"}}]'

wf_search() {
    case "${WO_TEST_WF:-live}" in
        missing-ad)
            fx workflow.search.txt | jq -c '
                .values[0].statuses |= map(select(.name != "Awaiting Deployment"))
                | .values[0].transitions |= map(select(.name != "Awaiting Deployment"))' ;;
        collision)
            fx workflow.search.txt | jq -c '
                .values[0].statuses |= map(select(.name != "Awaiting Deployment"))
                | .values[0].transitions |= map(if .name == "Awaiting Deployment" then .name = "Legacy AD" else . end)' ;;
        *) fx workflow.search.txt ;;
    esac
}

wf_bulkget() {
    case "${WO_TEST_WF:-live}" in
        missing-ad)
            fx workflows.bulkget.rules-after.txt | jq -c '
                ([.statuses[] | select(.name == "Awaiting Deployment") | .id][0]) as $ad
                | .statuses |= map(select(.name != "Awaiting Deployment"))
                | .workflows[0].statuses |= map(select(.statusReference != $ad))
                | .workflows[0].transitions |= map(select(.name != "Awaiting Deployment"))' ;;
        *) fx workflows.bulkget.rules-after.txt ;;
    esac
}

case "$M:$P" in
    # SYNTHETIC: no live capture of /myself is filed, only its shape is needed.
    GET:/myself) echo '{"accountId":"5f9a1111aaaa2222bbbb3333","displayName":"Test Bot"}' ;;

    GET:/project/*)
        case "${WO_TEST_PROJECT:-classic}" in
            # Stateful on purpose: a create in this run makes the readback
            # succeed, so ensure_project's own assert runs on it.
            missing) [ -f "$WO_TEST_WORK/created" ] || notfound
                echo '{"id":"10017","key":"SPK4","style":"classic","projectTypeKey":"software","issueTypes":[{"id":"10000","name":"Epic","hierarchyLevel":1}]}' ;;
            # SYNTHETIC: the two project readbacks this asserts on.
            business) echo '{"id":"10017","key":"SPK4","style":"next-gen","projectTypeKey":"business","issueTypes":[]}' ;;
            *) echo '{"id":"10017","key":"SPK4","style":"classic","projectTypeKey":"software","issueTypes":[{"id":"10000","name":"Epic","hierarchyLevel":1},{"id":"10001","name":"Task","hierarchyLevel":0}]}' ;;
        esac ;;
    # SYNTHETIC
    POST:/project) : > "$WO_TEST_WORK/created"; echo '{"id":"10017","key":"SPK4"}' ;;

    GET:/field/*/context/*/option)
        # SYNTHETIC: 'agent' present, so human and mixed must be added.
        echo '{"values":[{"id":"10200","value":"agent"}]}' ;;
    POST:/field/*/context/*/option) echo '{}' ;;
    GET:/field/*/context) echo '{"values":[{"id":"10100","isGlobalContext":true}]}' ;;
    PUT:/field/*) echo '{}' ;;
    GET:/field/search*)
        # provision.sh reads /field/search beside /field, because /field omits
        # a custom field with no screen context. The stub mirrors whatever
        # scenario /field is serving, so a field the scenario hides stays
        # hidden here too and still gets created.
        case "${WO_TEST_FIELDS:-live}" in
            all) fx field.list.txt | jq -c --argjson add "$ADDED_FIELDS" \
                     '{values: ((. + $add) | map(select(.custom == true))), isLast: true}' ;;
            *)   fx field.list.txt | jq -c \
                     '{values: (map(select(.custom == true))), isLast: true}' ;;
        esac ;;
    GET:/field)
        case "${WO_TEST_FIELDS:-live}" in
            all) fx field.list.txt | jq -c --argjson add "$ADDED_FIELDS" '. + $add' ;;
            wrongtype) fx field.list.txt | jq -c '[.[] | if .name == "verify" then .schema.custom = "com.atlassian.jira.plugin.system.customfieldtypes:float" else . end]' ;;
            *) fx field.list.txt ;;
        esac ;;
    POST:/field)
        # SYNTHETIC: a create response's id, unique per call in a run.
        NEXT=$(cat "$WO_TEST_WORK/fieldseq" 2>/dev/null || echo 10059)
        NEXT=$((NEXT + 1))
        printf '%s' "$NEXT" > "$WO_TEST_WORK/fieldseq"
        printf '{"id":"customfield_%s"}\n' "$NEXT" ;;

    GET:/search/jql*)
        if [ "${WO_TEST_SEARCH:-ok}" = "400-once" ]; then
            SEEN="$WO_TEST_WORK/probe.$(printf '%s' "$P" | cksum | tr -d ' ')"
            if [ ! -f "$SEEN" ]; then
                : > "$SEEN"
                badrequest
            fi
        fi
        fx search.jql.searchable.txt ;;

    GET:/issuetypescreenscheme/project*) fx issuetypescreenscheme.project.txt ;;
    GET:/issuetypescreenscheme/mapping*) fx issuetypescreenscheme.mapping.txt ;;
    GET:/screenscheme*) fx screenscheme.txt ;;
    GET:/screens/*/tabs/*/fields)
        REST="${P#/screens/}"; SID="${REST%%/*}"
        REST="${REST#*/tabs/}"; TID="${REST%%/*}"
        fx "screens.$SID.tab.$TID.fields.txt" ;;
    POST:/screens/*/tabs/*/fields) echo '{}' ;;
    GET:/screens/*/tabs)
        REST="${P#/screens/}"; SID="${REST%%/*}"
        fx "screens.$SID.tabs.txt" ;;

    GET:/statuses/search*) fx statuses.search.txt ;;
    GET:/workflow/search*) wf_search ;;
    POST:/workflows/update/validation) fx workflows.update.validation.txt ;;
    # SYNTHETIC
    POST:/workflows/update) echo '{}' ;;
    POST:/workflows) wf_bulkget ;;

    POST:/issue)
        # SYNTHETIC: the created body is kept so the GET below can serve it back.
        printf '%s' "$B" > "$WO_TEST_WORK/created-issue.json"
        fx issue.create.json ;;
    GET:/issue/*/transitions) fx issue.transitions.json ;;
    POST:/issue/*/transitions) echo '{}' ;;
    POST:/issue/*/comment) echo '{}' ;;
    GET:/issue/*fields=status)
        if [ -n "${WO_TEST_STATUS:-}" ]; then
            fx issue.status.json | jq -c --arg s "$WO_TEST_STATUS" '.fields.status.name = $s'
        else
            fx issue.status.json
        fi ;;
    GET:/issue/*)
        if [ -f "$WO_TEST_WORK/created-issue.json" ]; then
            # SYNTHETIC: the fields as sent, plus the four Jira maintains itself.
            jq -c --arg k "${P#/issue/}" '{key: $k, fields: (.fields + {
                status: {name: "Open"}, issuelinks: [],
                created: "2026-09-20T09:00:00.000+0100",
                updated: "2026-09-20T09:00:00.000+0100"})}' \
                "$WO_TEST_WORK/created-issue.json"
        else
            fx issue.fetch.json
        fi ;;

    *) printf 'HTTP 501\n{"stub":"no case for %s %s"}\n' "$M" "$P" >&2; exit 1 ;;
esac
STUBEOF
chmod +x "$STUB"

# reset_log — a fresh call log for the next test.
LOG=""
reset_log() {
    LOG="$WORK/log.$1"
    : > "$LOG"
    rm -f "$WORK/fieldseq" "$WORK/created" "$WORK/created-issue.json" "$WORK"/probe.*
}
export WO_TEST_FX="$FX"
export WO_TEST_WORK="$WORK"

# ---- 1. lib/common.sh ----------------------------------------------------

OUT=$(bash -c '. "'"$COMMON"'"; require_project_key ZZPROBE && echo yes || echo "no: $WO_JIRA_KEY_ERR"')
eq "require_project_key accepts ZZPROBE" "yes" "$OUT"

OUT=$(bash -c '. "'"$COMMON"'"; require_project_key zz && echo yes || echo "no"')
eq "require_project_key rejects a lowercase key" "no" "$OUT"

OUT=$(bash -c '. "'"$COMMON"'"; require_project_key A && echo yes || echo "no"')
eq "require_project_key rejects a one-character key" "no" "$OUT"

OUT=$(bash -c '. "'"$COMMON"'"; require_issue_key PROJ-123 && echo yes || echo no')
eq "require_issue_key accepts PROJ-123" "yes" "$OUT"

OUT=$(bash -c '. "'"$COMMON"'"; require_issue_key PROJ-abc && echo yes || echo no')
eq "require_issue_key rejects a non-numeric suffix" "no" "$OUT"

OUT=$(bash -c '. "'"$COMMON"'"; jira_comment_body "one
two" | jq -c "[.body.content[].content[0].text // \"\"]"')
eq "jira_comment_body makes one paragraph per line" '["one","two"]' "$OUT"

OUT=$(bash -c '. "'"$COMMON"'"; in_list "In Progress" "Open
In Progress" && echo yes || echo no')
eq "in_list matches a whole line containing a space" "yes" "$OUT"

OUT=$(bash -c '. "'"$COMMON"'"; in_list "Progress" "Open
In Progress" && echo yes || echo no')
eq "in_list does not match a substring of a line" "no" "$OUT"

# ---- 2. lib/jira-http.sh ------------------------------------------------

# A curl that fails loudly if anything reaches it. No test below may touch it.
FAKEBIN="$WORK/bin"
mkdir -p "$FAKEBIN"
printf '#!/bin/sh\necho "curl was called: $*" >&2\nexit 42\n' > "$FAKEBIN/curl"
chmod +x "$FAKEBIN/curl"

OUT=$(PATH="$FAKEBIN:$PATH" "$HTTPLIB" --dry-run GET /issue/PROJ-1 2>&1)
RC=$?
eq "jira-http.sh --dry-run exits 0" "0" "$RC"
contains "jira-http.sh --dry-run prints the request it would make" "WOULD GET" "$OUT"
not_contains "jira-http.sh --dry-run never calls curl" "curl was called" "$OUT"

OUT=$("$HTTPLIB" --dry-run GET issue/PROJ-1 2>&1); RC=$?
eq "jira-http.sh rejects a path with no leading slash" "1" "$RC"
contains "  and says why" "must start with '/'" "$OUT"

OUT=$("$HTTPLIB" --dry-run POST /issue 'not json' 2>&1); RC=$?
eq "jira-http.sh rejects a body that is not JSON" "1" "$RC"

OUT=$("$HTTPLIB" --dry-run PATCH /issue 2>&1); RC=$?
eq "jira-http.sh rejects an unsupported method" "1" "$RC"

OUT=$(WORK_ORDER_JIRA_BASE_URL="" WORK_ORDER_JIRA_EMAIL=a@b.c \
      WORK_ORDER_JIRA_TOKEN="sekrit-token-value" PATH="$FAKEBIN:$PATH" \
      "$HTTPLIB" GET /myself 2>&1); RC=$?
eq "jira-http.sh with no base URL fails before reaching curl" "1" "$RC"
not_contains "  and never prints the token" "sekrit-token-value" "$OUT"
not_contains "  and never reached curl" "curl was called" "$OUT"

# ---- 3. provider.sh -----------------------------------------------------

reset_log provider
OUT=$(PATH="$FAKEBIN:$PATH" "$PROVIDER" --dry-run fetch PROJ-1 2>&1)
contains "provider fetch --dry-run prints the GET it would make" "WOULD GET" "$OUT"
contains "  against the issue endpoint" "/rest/api/3/issue/PROJ-1" "$OUT"

OUT=$("$PROVIDER" --dry-run fetch "PROJ-1;rm" 2>&1); RC=$?
eq "provider rejects a malformed issue key" "1" "$RC"
contains "  naming the key" "PROJ-1;rm" "$OUT"

OUT=$("$PROVIDER" --dry-run fetch "PROJ" 2>&1); RC=$?
eq "provider rejects a key with no issue number" "1" "$RC"
contains "  saying it is not a Jira key" "is not a Jira key" "$OUT"

reset_log position-ok
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_STATUS="Awaiting Deployment" \
      "$PROVIDER" --http "$STUB" position PROJ-1 2>&1)
eq "provider position maps a bound status to its lifecycle position" "awaiting-deployment" "$OUT"

reset_log position-unmapped
OUT=$(WO_TEST_LOG="$LOG" "$PROVIDER" --http "$STUB" position PROJ-1 2>&1); RC=$?
eq "provider position fails on a status outside the binding" "1" "$RC"
contains "  citing the binding requirement" "JIRA-3" "$OUT"
contains "  and naming the status it found" "To Do" "$OUT"

reset_log transition-pos
OUT=$(WO_TEST_LOG="$LOG" "$PROVIDER" --http "$STUB" transition PROJ-1 completed 2>&1)
nonempty "provider transition by position reached the stub" "$(cat "$LOG")"
contains "provider transition completed resolves the transition into Completed" \
    'POST /issue/PROJ-1/transitions {"transition":{"id":"81"}}' "$(cat "$LOG")"

reset_log transition-cancel
WO_TEST_LOG="$LOG" "$PROVIDER" --http "$STUB" transition PROJ-1 cancelled >/dev/null 2>&1
contains "provider transition cancelled resolves its own transition" \
    '{"transition":{"id":"91"}}' "$(cat "$LOG")"

OUT=$("$PROVIDER" --dry-run transition PROJ-1 almost-done 2>&1); RC=$?
eq "provider rejects a position that is not one of the five" "1" "$RC"
contains "  listing the five" "awaiting-deployment" "$OUT"

reset_log comment
WO_TEST_LOG="$LOG" "$PROVIDER" --http "$STUB" comment PROJ-1 "line one
line two" >/dev/null 2>&1
contains "provider comment posts an ADF document" '"type":"doc"' "$(cat "$LOG")"
contains "  with one paragraph per line" '"text":"line two"' "$(cat "$LOG")"

OUT=$("$PROVIDER" --dry-run create ZZPROBE Task "" 2>&1); RC=$?
eq "provider create refuses an empty title" "1" "$RC"
contains "  citing the requirement" "MUST-3" "$OUT"

reset_log create
WO_TEST_LOG="$LOG" "$PROVIDER" --http "$STUB" create ZZPROBE Task "A title" >/dev/null 2>&1
contains "provider create sends project, issuetype and summary" '"summary":"A title"' "$(cat "$LOG")"

# ---- 3b. provider.sh create --ticket ------------------------------------

OUT=$(python3 "$HERE/../../decision-list/validate.py" "$FX/ticket-full.json" 2>&1); RC=$?
eq "the create fixture is a decision list WO-009's own validator accepts" "0" "$RC"

OUT=$(PATH="$FAKEBIN:$PATH" "$PROVIDER" --dry-run create ZZPROBE Task "s" \
      --ticket "$FX/ticket-full.json" 2>&1); RC=$?
eq "provider create --ticket --dry-run exits 0" "0" "$RC"
contains "  sending a description" '"description"' "$OUT"
contains "  with the problem as a heading Jira renders" '"text":"Problem"' "$OUT"
contains "  and the ticket's tags as labels" '"labels":["work-order","jira","binding"]' "$OUT"
not_contains "  resolving no credential" "atlassian.net" "$OUT"
not_contains "  and never calling curl" "curl was called" "$OUT"

TABLE=$(bash -c '. "'"$COMMON"'"; printf "%s\n" "$WO_JIRA_FIELD_NAMES"')
for f in $TABLE; do
    contains "  naming the $f field it would resolve" "\"<$f>\"" "$OUT"
done

reset_log create-ticket
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_FIELDS=all "$PROVIDER" --http "$STUB" \
      create ZZPROBE Task "" --ticket "$FX/ticket-full.json" 2>&1); RC=$?
eq "provider create --ticket against a provisioned site exits 0" "0" "$RC"
contains "  resolving the field id this site assigns by name" '"customfield_10043"' "$(cat "$LOG")"
contains "  including one outside the reference implementation's ids" '"customfield_10053"' "$(cat "$LOG")"
contains "  taking the title from the ticket when SUMMARY is empty" \
    '"summary":"Populate every field this binding provisions"' "$(cat "$LOG")"
not_contains "  leaving no unresolved placeholder in the request" '"<touches>"' "$(cat "$LOG")"

reset_log create-unprovisioned
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_FIELDS=live "$PROVIDER" --http "$STUB" \
      create ZZPROBE Task "t" --ticket "$FX/ticket-full.json" 2>&1); RC=$?
eq "provider create refuses to drop a field this site has not provisioned" "1" "$RC"
contains "  naming the field and the fix" "run provision.sh" "$OUT"
not_contains "  having created no half-populated issue" "POST /issue " "$(cat "$LOG")"

jq '.decisions[0].tags = ["work order"]' "$FX/ticket-full.json" > "$WORK/bad-tag.json"
OUT=$("$PROVIDER" --dry-run create ZZPROBE Task "t" --ticket "$WORK/bad-tag.json" 2>&1); RC=$?
eq "provider create refuses a tag Jira cannot hold as a label" "1" "$RC"
contains "  naming the tag" "work order" "$OUT"

jq '.decisions = [.decisions[0], .decisions[0]]' "$FX/ticket-full.json" > "$WORK/two.json"
OUT=$("$PROVIDER" --dry-run create ZZPROBE Task "t" --ticket "$WORK/two.json" 2>&1); RC=$?
eq "provider create refuses a decision list holding more than one decision" "1" "$RC"

OUT=$("$PROVIDER" --dry-run create ZZPROBE Task "" --ticket "$FX/ticket-minimal.json" 2>&1); RC=$?
eq "provider create writes a ticket carrying only some of the fields" "0" "$RC"
contains "  declaring the blocked_by it does not write" "second pass" "$OUT"
not_contains "  and sending no field the ticket has no value for" "<outcome>" "$OUT"

reset_log create-roundtrip
WO_TEST_LOG="$LOG" WO_TEST_FIELDS=all "$STUB" GET /field > "$WORK/field.list.json" 2>/dev/null
WO_TEST_LOG="$LOG" WO_TEST_FIELDS=all "$PROVIDER" --http "$STUB" \
    create ZZPROBE Task "" --ticket "$FX/ticket-full.json" >/dev/null 2>&1
WO_TEST_LOG="$LOG" WO_TEST_FIELDS=all "$PROVIDER" --http "$STUB" fetch ZZPROBE-1 \
    > "$WORK/fetched.json" 2>/dev/null
ROUNDTRIP=$(python3 - "$HERE/../.." "$WORK/field.list.json" "$WORK/fetched.json" \
    "$FX/ticket-full.json" <<'PY'
import json, sys
from pathlib import Path

root, fieldlist, fetched, source = (Path(a) for a in sys.argv[1:5])
sys.path.insert(0, str(root / "conformance"))
import jira_source

ids = jira_source.resolve_field_ids(json.loads(fieldlist.read_text()))
got = jira_source.issue_to_ticket(json.loads(fetched.read_text()), ids)
want = json.loads(source.read_text())["decisions"][0]

diffs = []


def same(name, sent, read_back):
    if sent != read_back:
        diffs.append(f"{name}: sent {sent!r}, read back {read_back!r}")


for name in ("touches", "appends", "human_steps"):
    same(name, want.get(name) or [], got.get(name) or [])
# Jira serves labels sorted, so tags round-trip as a set, not a sequence.
same("tags", sorted(want.get("tags") or []), sorted(got.get("tags") or []))
for name in ("title", "verify", "executor", "outcome"):
    same(name, want.get(name) or "", got.get(name) or "")
same("defer_until", want.get("defer_until"), got.get("defer_until"))

body = got.get("_body") or ""
for head in ("## Problem", "## Solution", "## Decisions", "## Out of scope"):
    if head not in body:
        diffs.append(f"description lost the {head!r} heading")
for name in ("problem", "solution", "out_of_scope"):
    if (want.get(name) or "") not in body:
        diffs.append(f"description lost the {name} text")

print("ROUNDTRIP OK" if not diffs else "; ".join(diffs))
PY
)
eq "a ticket survives create then fetch unchanged" "ROUNDTRIP OK" "$ROUNDTRIP"

# ---- 4. workflow-apply.sh ----------------------------------------------

reset_log wf-complete
OUT=$(WO_TEST_LOG="$LOG" "$WFAPPLY" SPK4 --http "$STUB" --rules none --dry-run 2>&1); RC=$?
eq "workflow-apply with every status present exits 0" "0" "$RC"
contains "  and says already complete" "already complete" "$OUT"
not_contains "  without ever bulk-getting the workflow" "POST /workflows" "$(cat "$LOG")"

reset_log wf-unresolved
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_FIELDS=live \
      "$WFAPPLY" SPK4 --http "$STUB" --rules "$RULES" --dry-run 2>&1); RC=$?
eq "workflow-apply fails when a rule names a field this site lacks" "1" "$RC"
contains "  naming the unresolved field" "UNRESOLVED:field:outcome" "$OUT"

reset_log wf-dry
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_FIELDS=all \
      "$WFAPPLY" SPK4 --http "$STUB" --rules "$RULES" --dry-run 2>&1); RC=$?
eq "workflow-apply --dry-run with resolvable rules exits 0" "0" "$RC"
contains "  and validates the body it built" "validation passed" "$OUT"
contains "  adding the outcome validator to Cancelled" "customfield_10053" "$OUT"
contains "  and the previous-status validator to Completed" "system:previous-status-validator" "$OUT"
contains "  validation was called" "POST /workflows/update/validation" "$(cat "$LOG")"
not_contains "  but the update itself never was" "POST /workflows/update {" "$(cat "$LOG")"

reset_log wf-noyes
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_FIELDS=all \
      "$WFAPPLY" SPK4 --http "$STUB" --rules "$RULES" 2>&1); RC=$?
eq "workflow-apply without --yes refuses with exit 3" "3" "$RC"
not_contains "  and sent no update" "POST /workflows/update {" "$(cat "$LOG")"

reset_log wf-missing-status
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_FIELDS=all WO_TEST_WF=missing-ad \
      "$WFAPPLY" SPK4 --http "$STUB" --rules "$RULES" --dry-run 2>&1); RC=$?
eq "workflow-apply adds a missing lifecycle status" "0" "$RC"
contains "  reporting it as missing" "Awaiting Deployment" "$OUT"
ADDED=$(printf '%s' "$OUT" | sed -n '/^{/,$p' | jq -c '[.statuses[] | select(.name == "Awaiting Deployment") | {id, statusReference}]' 2>/dev/null)
eq "  with id and statusReference both set to the global status id" \
    '[{"id":"10012","statusReference":"10012"}]' "$ADDED"

reset_log wf-collision
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_FIELDS=all WO_TEST_WF=collision \
      "$WFAPPLY" SPK4 --http "$STUB" --rules "$RULES" --dry-run 2>&1); RC=$?
eq "workflow-apply refuses to reuse a transition id held by another name" "1" "$RC"
contains "  naming the holder" "Legacy AD" "$OUT"

# ---- 5. provision.sh ---------------------------------------------------

reset_log prov-dry
WFSPY="$WORK/wfapply-spy.sh"
printf '#!/bin/sh\necho "workflow-apply invoked: $*" >> "%s"\nexit 0\n' "$WORK/wfspy.log" > "$WFSPY"
chmod +x "$WFSPY"
: > "$WORK/wfspy.log"
OUT=$(WO_TEST_LOG="$LOG" PATH="$FAKEBIN:$PATH" \
      "$PROVISION" --dry-run --project ZZPROBE --http "$STUB" --workflow-apply "$WFSPY" 2>&1); RC=$?
eq "provision --dry-run exits 0" "0" "$RC"
contains "  and says it would create the project" "would read-or-create the project" "$OUT"
nonempty "  having reached the stub" "$(cat "$LOG")"
BAREcalls=$(grep -cv -- '--dry-run' "$LOG" || true)
eq "  every call the stub saw carried --dry-run" "0" "$BAREcalls"
eq "  and workflow-apply was announced, not invoked" "" "$(cat "$WORK/wfspy.log")"
not_contains "  no curl was reached" "curl was called" "$OUT"
for f in touches executor verify human_steps appends defer_until outcome; do
    contains "  the plan names the $f field" "\"name\":\"$f\"" "$OUT"
done
contains "  the plan names the screen walk" "/screens/<id>/tabs/<tab>/fields" "$OUT"
contains "  the plan names the searcherKey repair" "searcherKey" "$OUT"

reset_log prov-noyes
OUT=$(WO_TEST_LOG="$LOG" "$PROVISION" --project ZZPROBE --http "$STUB" --workflow-apply "$WFSPY" </dev/null 2>&1); RC=$?
eq "provision without --yes and with no terminal refuses with exit 3" "3" "$RC"
eq "  and sent nothing at all" "" "$(cat "$LOG")"

reset_log prov-business
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_PROJECT=business \
      "$PROVISION" --yes --project SPK4 --http "$STUB" --workflow-apply "$WFSPY" 2>&1); RC=$?
eq "provision refuses a project that is not classic software" "1" "$RC"
contains "  naming the style it found" "next-gen" "$OUT"

reset_log prov-wrongtype
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_FIELDS=wrongtype \
      "$PROVISION" --yes --project SPK4 --http "$STUB" --workflow-apply "$WFSPY" 2>&1); RC=$?
eq "provision refuses to reuse a field of the wrong type" "1" "$RC"
contains "  naming the field" "'verify'" "$OUT"

reset_log prov-happy
: > "$WORK/wfspy.log"
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_FIELDS=live \
      "$PROVISION" --yes --project SPK4 --http "$STUB" --workflow-apply "$WFSPY" 2>&1); RC=$?
eq "provision converges an existing conforming project" "0" "$RC"
not_contains "  without creating the project again" "creating it" "$OUT"
contains "  invoking workflow-apply for the lifecycle" "workflow-apply invoked" "$(cat "$WORK/wfspy.log")"
CREATED=$(printf '%s' "$OUT" | grep -c "absent — creating" || true)
eq "  creating exactly the four fields the site lacks" "4" "$CREATED"
contains "  reusing the field that is already present" "field 'verify' already present" "$OUT"
contains "  leaving the executor option that exists alone" "executor option 'agent' already present" "$OUT"
contains "  adding the executor options that do not" "executor option 'mixed' absent" "$OUT"
ADDS=$(grep -c 'POST /screens/' "$LOG" || true)
eq "  adding 7 fields to each of the 3 screens" "21" "$ADDS"
contains "  and printing the resolved field ids" "customfield_" "$OUT"

reset_log prov-unsearchable
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_FIELDS=live WO_TEST_SEARCH=400-once \
      "$PROVISION" --yes --project SPK4 --http "$STUB" --workflow-apply "$WFSPY" 2>&1); RC=$?
eq "provision repairs a field JQL cannot search" "0" "$RC"
contains "  treating the HTTP 400 as the signal" "confirmed via HTTP 400" "$OUT"
contains "  and re-probing after the repair" "JQL-searchable after repair" "$OUT"
PUTS=$(grep -c '^PUT /field/' "$LOG" || true)
eq "  with one searcherKey PUT per field" "7" "$PUTS"

reset_log prov-create
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_PROJECT=missing WO_TEST_FIELDS=live \
      "$PROVISION" --yes --project SPK4 --name "Spike 4" --http "$STUB" --workflow-apply "$WFSPY" 2>&1); RC=$?
eq "provision creates a project that does not exist" "0" "$RC"
contains "  saying so" "does not exist — creating it" "$OUT"
contains "  with the classic scrum template" "gh-simplified-scrum-classic" "$(cat "$LOG")"
contains "  and a lead resolved from /myself" "GET /myself" "$(cat "$LOG")"

# ---- summary ------------------------------------------------------------

echo
if [ "$FAIL" -eq 0 ]; then
    echo "$N assertions, all passed."
    exit 0
fi
echo "$N assertions, $FAIL failed."
exit 1
