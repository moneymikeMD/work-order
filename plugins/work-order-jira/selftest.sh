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
HTTPLIB="$HERE/lib/jira-http.sh"
COMMON="$HERE/lib/common.sh"

for f in "$PROVIDER" "$PROVISION" "$HTTPLIB"; do
    [ -x "$f" ] || { echo "$f is missing or not executable" >&2; exit 2; }
done
[ -f "$COMMON" ] || { echo "$COMMON is missing" >&2; exit 2; }
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
# provider.sh retries a stale read-back within a settle window; here no wait.
export WORK_ORDER_JIRA_SETTLE_DELAY=0

# ---- the stub ------------------------------------------------------------

STUB="$WORK/jira-http-stub.sh"
cat > "$STUB" <<'STUBEOF'
#!/bin/bash
# A jira-http.sh-shaped stub. Responses come from fixtures/ except where
# marked SYNTHETIC. Knobs: WO_TEST_PROJECT, WO_TEST_FIELDS, WO_TEST_SEARCH,
# WO_TEST_STATUS, WO_TEST_OUTCOME, WO_TEST_DUP.
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
{"id":"customfield_10053","name":"outcome","custom":true,"schema":{"type":"string","custom":"com.atlassian.jira.plugin.system.customfieldtypes:textarea"}},
{"id":"customfield_10054","name":"blocked_by_external","custom":true,"schema":{"type":"string","custom":"com.atlassian.jira.plugin.system.customfieldtypes:textarea"}}]'

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

    # SYNTHETIC: the create duplicate check. WO_TEST_DUP is the summary of the one
    # issue the search returns; WO_TEST_DUP_CAT its statusCategory key.
    GET:/search/jql*fields=summary,status*)
        if [ -n "${WO_TEST_DUP:-}" ]; then
            jq -cn --arg s "$WO_TEST_DUP" --arg c "${WO_TEST_DUP_CAT:-new}" \
                '{issues: [{id: "10077", key: "PROJ-77", self: "https://example.atlassian.net/rest/api/3/issue/10077", fields: {summary: $s, status: {statusCategory: {key: $c}}}}], isLast: true}'
        else
            echo '{"issues":[],"isLast":true}'
        fi ;;
    # SYNTHETIC: one complete page, for a reader that pages to the end.
    GET:/search/jql*)
        if [ "${WO_TEST_SEARCH:-ok}" = "onepage" ]; then
            echo '{"issues":[{"key":"PROJ-111","fields":{"summary":"Served through issues-api.sh","status":{"name":"Open"},"labels":[],"issuelinks":[],"created":"2026-10-08T09:00:00.000+0000","updated":"2026-10-08T09:00:00.000+0000","issuetype":{"name":"Task","hierarchyLevel":0}}}],"isLast":true}'
            exit 0
        fi
        if [ "${WO_TEST_SEARCH:-ok}" = "400-once" ]; then
            SEEN="$WO_TEST_WORK/probe.$(printf '%s' "$P" | cksum | tr -d ' ')"
            if [ ! -f "$SEEN" ]; then
                : > "$SEEN"
                badrequest
            fi
        fi
        fx search.jql.searchable.txt ;;

    POST:/issue)
        # SYNTHETIC: the created body is kept so the GET below can serve it back.
        printf '%s' "$B" > "$WO_TEST_WORK/created-issue.json"
        fx issue.create.json ;;
    # SYNTHETIC: issue types and epics. WO_TEST_LEVELS maps KEY:LEVEL, space
    # separated, and a key it does not name reads as a 404 by issuetype.
    # WO_TEST_PARENT_OF seeds KEY:EPIC; a parent PUT is kept per key, the
    # created issue (PROJ-42) carries the parent its create sent, and
    # WO_TEST_PARENT=nowrite accepts a parent and keeps none.
    GET:/issue/*fields=issuetype|GET:/issue/*fields=parent,issuetype|GET:/issue/*fields=parent)
        K="${P#/issue/}"; K="${K%%\?*}"
        LV=""; PAR=""
        for kv in ${WO_TEST_LEVELS:-}; do [ "${kv%%:*}" = "$K" ] && LV="${kv#*:}"; done
        for kv in ${WO_TEST_PARENT_OF:-}; do [ "${kv%%:*}" = "$K" ] && PAR="${kv#*:}"; done
        if [ -f "$WO_TEST_WORK/parent.$K" ]; then
            PAR=$(cat "$WO_TEST_WORK/parent.$K")
        elif [ "$K" = "PROJ-42" ] && [ -f "$WO_TEST_WORK/created-issue.json" ] && [ "${WO_TEST_PARENT:-}" != "nowrite" ]; then
            PAR=$(jq -r '.fields.parent.key // empty' "$WO_TEST_WORK/created-issue.json")
        fi
        case "$P" in
            *fields=issuetype)
                [ -n "$LV" ] || { printf 'HTTP 404\n{"errorMessages":["Issue does not exist or you do not have permission to see it."],"errors":{}}\n' >&2; exit 1; }
                jq -cn --arg k "$K" --argjson l "$LV" \
                    '{key: $k, fields: {issuetype: {name: (if $l == 1 then "Epic" else "Task" end), hierarchyLevel: $l}}}' ;;
            *)
                jq -cn --arg k "$K" --argjson l "${LV:-0}" --arg p "$PAR" \
                    '{key: $k, fields: {issuetype: {hierarchyLevel: $l}, parent: (if $p == "" then null else {key: $p} end)}}' ;;
        esac ;;
    # SYNTHETIC: issue links, kept as {id, inward, outward} so the stub reads
    # them the way Jira does: an entry on the outward issue carries
    # inwardIssue, and one on the inward issue carries outwardIssue.
    # WO_TEST_LINKS seeds PROJ-1 / PROJ-2: right, reversed, or none;
    # nowrite accepts a POST and stores nothing.
    GET:/issue/*fields=issuelinks)
        LF="$WO_TEST_WORK/links.json"
        if [ ! -f "$LF" ]; then
            case "${WO_TEST_LINKS:-none}" in
                right)    echo '[{"id":"9001","inward":"PROJ-2","outward":"PROJ-1"}]' > "$LF" ;;
                reversed) echo '[{"id":"9001","inward":"PROJ-1","outward":"PROJ-2"}]' > "$LF" ;;
                *)        echo '[]' > "$LF" ;;
            esac
        fi
        K="${P#/issue/}"; K="${K%%\?*}"
        jq -c --arg k "$K" '{key: $k, fields: {issuelinks: [.[]
            | if .outward == $k then {id, type: {name: "Blocks"}, inwardIssue: {key: .inward}}
              elif .inward == $k then {id, type: {name: "Blocks"}, outwardIssue: {key: .outward}}
              else empty end]}}' "$LF" ;;
    POST:/issueLink)
        LF="$WO_TEST_WORK/links.json"
        [ -f "$LF" ] || echo '[]' > "$LF"
        if [ "${WO_TEST_LINKS:-none}" != "nowrite" ]; then
            jq -c --argjson b "$B" '. + [{id: "9100", inward: $b.inwardIssue.key, outward: $b.outwardIssue.key}]' "$LF" > "$LF.new" \
                && mv "$LF.new" "$LF"
        fi ;;
    DELETE:/issueLink/*)
        LF="$WO_TEST_WORK/links.json"
        jq -c --arg id "${P#/issueLink/}" 'map(select(.id != $id))' "$LF" > "$LF.new" && mv "$LF.new" "$LF" ;;
    # SYNTHETIC: WO_TEST_STALE_TRANSITIONS=N serves an empty list N times, the
    # way Jira can answer a read made just after a write from before it.
    GET:/issue/*/transitions)
        TN=$(cat "$WO_TEST_WORK/transseq" 2>/dev/null || echo 0); TN=$((TN + 1)); echo "$TN" > "$WO_TEST_WORK/transseq"
        if [ "$TN" -le "${WO_TEST_STALE_TRANSITIONS:-0}" ]; then echo '{"transitions":[]}'; exit 0; fi
        fx issue.transitions.json ;;
    # SYNTHETIC: a transition POST is remembered so the status read-back that
    # follows it reports the status that transition leads to.
    POST:/issue/*/transitions) printf '%s' "$B" | jq -r '.transition.id' > "$WO_TEST_WORK/transitioned"; echo '{}' ;;
    # SYNTHETIC: the outcome field. WO_TEST_OUTCOME=set seeds it, nowrite makes
    # a PUT accept and store nothing; otherwise a PUT is served back on the GET.
    PUT:/issue/*)
        if printf '%s' "$B" | jq -e '.fields.parent' >/dev/null 2>&1; then
            [ "${WO_TEST_PARENT:-}" = "nowrite" ] \
                || printf '%s' "$B" | jq -r '.fields.parent.key' > "$WO_TEST_WORK/parent.${P#/issue/}"
        else
            [ "${WO_TEST_OUTCOME:-}" = "nowrite" ] || printf '%s' "$B" | jq -c '.fields | to_entries[0].value' > "$WO_TEST_WORK/outcome.json"
            # SYNTHETIC: every field a PUT writes is kept per key and served back
            # on a GET naming fields; WO_TEST_UPDATE=nowrite keeps nothing.
            UF="$WO_TEST_WORK/updated.${P#/issue/}.json"
            if [ "${WO_TEST_UPDATE:-}" != "nowrite" ]; then
                [ -f "$UF" ] || echo '{}' > "$UF"
                jq -c --argjson f "$(printf '%s' "$B" | jq -c '.fields')" '. + $f' "$UF" > "$UF.new" && mv "$UF.new" "$UF"
            fi
        fi
        echo '{}' ;;
    GET:/issue/*fields=customfield_10053)
        if [ -f "$WO_TEST_WORK/outcome.json" ]; then V=$(cat "$WO_TEST_WORK/outcome.json")
        elif [ "${WO_TEST_OUTCOME:-}" = "set" ]; then
            V='{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"prior reason"}]}]}'
        else V=null; fi
        jq -cn --argjson v "$V" '{key: "PROJ-1", fields: {customfield_10053: $v}}' ;;
    POST:/issue/*/comment) echo '{}' ;;
    GET:/issue/*fields=status)
        # SYNTHETIC: WO_TEST_STATUS_SEQ="A|B" serves A, then B, to successive
        # status reads before the normal answers resume: a stale read.
        if [ -n "${WO_TEST_STATUS_SEQ:-}" ]; then
            SN=$(cat "$WO_TEST_WORK/statusseq" 2>/dev/null || echo 0); SN=$((SN + 1)); echo "$SN" > "$WO_TEST_WORK/statusseq"
            S=$(printf '%s' "$WO_TEST_STATUS_SEQ" | awk -F'|' -v n="$SN" '{ print $n }')
            if [ -n "$S" ]; then fx issue.status.json | jq -c --arg s "$S" '.fields.status.name = $s'; exit 0; fi
        fi
        if [ -f "$WO_TEST_WORK/transitioned" ]; then
            fx issue.status.json | jq -c --arg s "$(fx issue.transitions.json | jq -r --arg id "$(cat "$WO_TEST_WORK/transitioned")" '.transitions[] | select(.id == $id) | .to.name')" '.fields.status.name = $s'
        elif [ -n "${WO_TEST_STATUS:-}" ]; then
            fx issue.status.json | jq -c --arg s "$WO_TEST_STATUS" '.fields.status.name = $s'
        else
            fx issue.status.json
        fi ;;
    GET:/issue/*fields=*)
        K="${P#/issue/}"; K="${K%%\?*}"
        if [ -f "$WO_TEST_WORK/updated.$K.json" ]; then
            jq -c --arg k "$K" '{key: $k, fields: .}' "$WO_TEST_WORK/updated.$K.json"
        else
            jq -cn --arg k "$K" '{key: $k, fields: {}}'
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
    rm -f "$WORK/fieldseq" "$WORK/created" "$WORK/created-issue.json" "$WORK/links.json" "$WORK/transitioned" "$WORK/outcome.json" "$WORK"/probe.* "$WORK"/parent.* "$WORK"/updated.* "$WORK/transseq" "$WORK/statusseq"
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

# A curl that answers 200 with a body, so a call runs to completion, and a
# fresh TMPDIR, so anything a run leaves behind is visible.
OKBIN="$WORK/okbin"
mkdir -p "$OKBIN" "$WORK/tmpdir"
cat > "$OKBIN/curl" <<'CURLEOF'
#!/bin/sh
cat >/dev/null
while [ $# -gt 0 ]; do
    case "$1" in -o) printf '{"ok":true}' > "$2"; shift 2 ;; *) shift ;; esac
done
printf '200'
CURLEOF
chmod +x "$OKBIN/curl"
OUT=$(TMPDIR="$WORK/tmpdir" WORK_ORDER_JIRA_BASE_URL=https://example.atlassian.net \
      WORK_ORDER_JIRA_EMAIL=a@b.c WORK_ORDER_JIRA_TOKEN=t PATH="$OKBIN:$PATH" \
      "$HTTPLIB" GET /myself 2>&1); RC=$?
eq "jira-http.sh returns a 2xx body" '{"ok":true}' "$OUT"
eq "  and leaves no scratch directory behind" "" "$(ls -A "$WORK/tmpdir")"
OUT=$(TMPDIR="$WORK/tmpdir" PATH="$OKBIN:$PATH" WORK_ORDER_JIRA_BASE_URL=https://example.atlassian.net \
      WORK_ORDER_JIRA_EMAIL=a@b.c WORK_ORDER_JIRA_TOKEN=t \
      "$PROVIDER" parent PROJ-2 --epic PROJ-1 2>&1) || true
eq "provider.sh, through the real client, leaves no scratch directory behind either" "" "$(ls -A "$WORK/tmpdir")"

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

reset_log position-todo
OUT=$(WO_TEST_LOG="$LOG" "$PROVIDER" --http "$STUB" position PROJ-1 2>/dev/null); RC=$?
eq "provider position reports the template's To Do as unmapped (WO-81 retired the alias)" "4" "$RC"
contains "  naming the status on stdout" "unmapped-status	To Do" "$OUT"

reset_log position-triage
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_STATUS="Triage" \
      "$PROVIDER" --http "$STUB" position PROJ-1 2>&1)
eq "triage reads back as a lifecycle position" "triage" "$OUT"

reset_log position-deferred
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_STATUS="Deferred" \
      "$PROVIDER" --http "$STUB" position PROJ-1 2>&1)
eq "deferred reads back as a lifecycle position" "deferred" "$OUT"

reset_log position-open
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_STATUS="Open" \
      "$PROVIDER" --http "$STUB" position PROJ-1 2>&1); RC=$?
eq "provider position maps Open, the status open binds to, to open" "open" "$OUT"
eq "  and says nothing on stderr, because Open is not an alias" "0" "$RC"

reset_log position-unmapped
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_STATUS="Build Broken" \
      "$PROVIDER" --http "$STUB" position PROJ-1 2>/dev/null); RC=$?
ERRTXT=$(WO_TEST_LOG="$LOG" WO_TEST_STATUS="Build Broken" \
      "$PROVIDER" --http "$STUB" position PROJ-1 2>&1 >/dev/null) || true
eq "an unmapped status is reported as unmapped, not as an error" "4" "$RC"
contains "  on stdout, as a token a caller can parse rather than prose" "unmapped-status" "$OUT"
contains "  naming the status it found" "Build Broken" "$OUT"
contains "  and citing the binding requirement on stderr" "JIRA-3" "$ERRTXT"

reset_log transition-pos
OUT=$(WO_TEST_LOG="$LOG" "$PROVIDER" --http "$STUB" transition PROJ-1 completed 2>&1)
nonempty "provider transition by position reached the stub" "$(cat "$LOG")"
contains "provider transition completed resolves the transition into Completed" \
    'POST /issue/PROJ-1/transitions {"transition":{"id":"81"}}' "$(cat "$LOG")"

reset_log transition-cancel
WO_TEST_LOG="$LOG" WO_TEST_FIELDS=all "$PROVIDER" --http "$STUB" transition PROJ-1 cancelled --outcome "dropped" >/dev/null 2>&1
contains "provider transition cancelled resolves its own transition" \
    '{"transition":{"id":"91"}}' "$(cat "$LOG")"

reset_log transition-open
WO_TEST_LOG="$LOG" "$PROVIDER" --http "$STUB" transition PROJ-1 open >/dev/null 2>&1
contains "provider transition open resolves the transition into Open" \
    '{"transition":{"id":"51"}}' "$(cat "$LOG")"

reset_log transition-triage
WO_TEST_LOG="$LOG" "$PROVIDER" --http "$STUB" transition PROJ-1 triage >/dev/null 2>&1
contains "provider transition triage resolves its own transition" \
    '{"transition":{"id":"41"}}' "$(cat "$LOG")"

reset_log transition-deferred
WO_TEST_LOG="$LOG" "$PROVIDER" --http "$STUB" transition PROJ-1 deferred >/dev/null 2>&1
contains "provider transition deferred resolves its own transition" \
    '{"transition":{"id":"71"}}' "$(cat "$LOG")"

OUT=$("$PROVIDER" --dry-run transition PROJ-1 almost-done 2>&1); RC=$?
eq "provider rejects a position that is not one of the seven" "1" "$RC"
contains "  listing all seven" "awaiting-deployment" "$OUT"
contains "  including the two added in specification 0.2" "deferred" "$OUT"

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
for name in ("title", "executor", "outcome"):
    same(name, want.get(name) or "", got.get(name) or "")
# [MUST-10]: the base-state observation travels as verify's last line.
same("verify", want["verify"] + "\n# " + want["verify_fails_today"], got.get("verify") or "")
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

# ---- 5. provision.sh ---------------------------------------------------

# The universal scripts are spies: each records its argv, in call order, and
# exits with the code its knob names, so provision.sh's handling of them is
# tested without either script's own behaviour.
USPY="$WORK/uspy.log"
UAPPLY="$WORK/universal-apply-spy.sh"
USWITCH="$WORK/universal-switch-spy.sh"
cat > "$UAPPLY" <<'SPY'
#!/bin/sh
echo "universal-apply $*" >> "$WO_TEST_USPY"
exit "${WO_TEST_UA_RC:-0}"
SPY
cat > "$USWITCH" <<'SPY'
#!/bin/sh
echo "universal-switch $*" >> "$WO_TEST_USPY"
exit "${WO_TEST_US_RC:-0}"
SPY
chmod +x "$UAPPLY" "$USWITCH"
export WO_TEST_USPY="$USPY"
USE_SPIES=(--universal-apply "$UAPPLY" --universal-switch "$USWITCH")

reset_log prov-dry
: > "$USPY"
OUT=$(WO_TEST_LOG="$LOG" PATH="$FAKEBIN:$PATH" \
      "$PROVISION" --dry-run --project ZZPROBE --http "$STUB" "${USE_SPIES[@]}" 2>&1); RC=$?
eq "provision --dry-run exits 0" "0" "$RC"
contains "  and says it would create the project" "would read-or-create the project" "$OUT"
nonempty "  having reached the stub" "$(cat "$LOG")"
BAREcalls=$(grep -cv -- '--dry-run' "$LOG" || true)
eq "  every call the stub saw carried --dry-run" "0" "$BAREcalls"
eq "  and neither universal script was invoked, only announced" "" "$(cat "$USPY")"
not_contains "  no curl was reached" "curl was called" "$OUT"
for f in touches executor verify human_steps appends defer_until outcome blocked_by_external; do
    contains "  the plan names the $f field" "\"name\":\"$f\"" "$OUT"
done
contains "  the plan announces universal-apply with no project argument" "$UAPPLY --http $STUB --yes" "$OUT"
contains "  then universal-switch for this project on the managed tier by default" "$USWITCH ZZPROBE --tier managed --http $STUB --yes" "$OUT"
contains "  naming the shared scheme" "Universal Managed Workflow Scheme" "$OUT"
contains "  and the entry state the create transition targets" "Triage" "$OUT"
contains "  the contract fields arrive on the shared ticket screen" "'Universal Managed Ticket Screen', which carries every field above" "$OUT"
not_contains "  and no per-project screen walk is planned" "/screens/<id>/tabs" "$OUT"
contains "  the plan names the searcherKey repair" "searcherKey" "$OUT"

reset_log prov-dry-simplified
OUT=$(WO_TEST_LOG="$LOG" PATH="$FAKEBIN:$PATH" \
      "$PROVISION" --dry-run --project ZZPROBE --tier simplified --http "$STUB" "${USE_SPIES[@]}" 2>&1); RC=$?
eq "provision --dry-run --tier simplified exits 0" "0" "$RC"
contains "  announcing the switch onto the simplified tier" "$USWITCH ZZPROBE --tier simplified --http $STUB --yes" "$OUT"
contains "  onto the simplified schemes" "'Universal Simplified Issue Type Screen Scheme'" "$OUT"
not_contains "  with no managed lifecycle" "Awaiting Deployment" "$OUT"

OUT=$("$PROVISION" --dry-run --project ZZPROBE --tier bogus --http "$STUB" "${USE_SPIES[@]}" 2>&1); RC=$?
eq "provision rejects an unknown tier" "1" "$RC"
contains "  naming the two tiers" "--tier must be managed or simplified" "$OUT"

reset_log prov-noyes
: > "$USPY"
OUT=$(WO_TEST_LOG="$LOG" "$PROVISION" --project ZZPROBE --http "$STUB" "${USE_SPIES[@]}" </dev/null 2>&1); RC=$?
eq "provision without --yes and with no terminal refuses with exit 3" "3" "$RC"
eq "  and sent nothing at all" "" "$(cat "$LOG")"
eq "  and invoked neither universal script" "" "$(cat "$USPY")"

OUT=$("$PROVISION" --dry-run --project ZZPROBE --http "$STUB" --workflow-apply "$UAPPLY" 2>&1); RC=$?
eq "provision rejects the retired --workflow-apply flag" "1" "$RC"
contains "  as an unknown flag" "unknown flag '--workflow-apply'" "$OUT"

OUT=$("$PROVISION" --dry-run --project ZZPROBE --http "$STUB" --rules x 2>&1); RC=$?
eq "provision rejects the retired --rules flag" "1" "$RC"

reset_log prov-default-apply
OUT=$(WO_TEST_LOG="$LOG" "$PROVISION" --dry-run --project ZZPROBE --http "$STUB" --universal-switch "$USWITCH" 2>&1); RC=$?
if [ -x "$HERE/universal-apply.sh" ]; then
    eq "provision finds universal-apply.sh beside itself by default" "0" "$RC"
else
    eq "provision looks for universal-apply.sh beside itself by default" "1" "$RC"
    contains "  naming the path it looked at" "$HERE/universal-apply.sh" "$OUT"
fi

reset_log prov-business
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_PROJECT=business \
      "$PROVISION" --yes --project SPK4 --http "$STUB" "${USE_SPIES[@]}" 2>&1); RC=$?
eq "provision refuses a project that is not classic software" "1" "$RC"
contains "  naming the style it found" "next-gen" "$OUT"

reset_log prov-wrongtype
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_FIELDS=wrongtype \
      "$PROVISION" --yes --project SPK4 --http "$STUB" "${USE_SPIES[@]}" 2>&1); RC=$?
eq "provision refuses to reuse a field of the wrong type" "1" "$RC"
contains "  naming the field" "'verify'" "$OUT"

reset_log prov-happy
: > "$USPY"
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_FIELDS=live \
      "$PROVISION" --yes --project SPK4 --http "$STUB" "${USE_SPIES[@]}" 2>&1); RC=$?
eq "provision converges an existing conforming project" "0" "$RC"
not_contains "  without creating the project again" "creating it" "$OUT"
eq "  running universal-apply then universal-switch, each once, passing --yes through" \
    "universal-apply --http $STUB --yes
universal-switch SPK4 --tier managed --http $STUB --yes" "$(cat "$USPY")"
CREATED=$(printf '%s' "$OUT" | grep -c "absent — creating" || true)
eq "  creating exactly the five fields the site lacks" "5" "$CREATED"
contains "  reusing the field that is already present" "field 'verify' already present" "$OUT"
contains "  leaving the executor option that exists alone" "executor option 'agent' already present" "$OUT"
contains "  adding the executor options that do not" "executor option 'mixed' absent" "$OUT"
eq "  touching no per-project screen or screen scheme" "0" "$(grep -cE ' /(screens|screenscheme|issuetypescreenscheme)' "$LOG" || true)"
contains "  and printing the resolved field ids" "customfield_" "$OUT"

reset_log prov-simplified
: > "$USPY"
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_FIELDS=all \
      "$PROVISION" --yes --project SPK4 --tier simplified --http "$STUB" "${USE_SPIES[@]}" 2>&1); RC=$?
eq "provision --tier simplified switches the project onto that tier" "universal-apply --http $STUB --yes
universal-switch SPK4 --tier simplified --http $STUB --yes" "$(cat "$USPY")"
contains "  and says the project is not a contract project" "on the Universal Simplified tier" "$OUT"

reset_log prov-unsearchable
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_FIELDS=live WO_TEST_SEARCH=400-once \
      "$PROVISION" --yes --project SPK4 --http "$STUB" "${USE_SPIES[@]}" 2>&1); RC=$?
eq "provision repairs a field JQL cannot search" "0" "$RC"
contains "  treating the HTTP 400 as the signal" "confirmed via HTTP 400" "$OUT"
contains "  and re-probing after the repair" "JQL-searchable after repair" "$OUT"
PUTS=$(grep -c '^PUT /field/' "$LOG" || true)
eq "  with one searcherKey PUT per field" "8" "$PUTS"

reset_log prov-create
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_PROJECT=missing WO_TEST_FIELDS=live \
      "$PROVISION" --yes --project SPK4 --name "Spike 4" --http "$STUB" "${USE_SPIES[@]}" 2>&1); RC=$?
eq "provision creates a project that does not exist" "0" "$RC"
contains "  saying so" "does not exist — creating it" "$OUT"
contains "  with the classic scrum template" "gh-simplified-scrum-classic" "$(cat "$LOG")"
contains "  and a lead resolved from /myself" "GET /myself" "$(cat "$LOG")"

reset_log prov-apply-fails
: > "$USPY"
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_FIELDS=all WO_TEST_UA_RC=2 \
      "$PROVISION" --yes --project SPK4 --http "$STUB" "${USE_SPIES[@]}" 2>&1); RC=$?
eq "provision fails when universal-apply reports the stored rules differ" "1" "$RC"
contains "  naming the script that failed" "universal-apply-spy.sh failed" "$OUT"
eq "  and never switches the project onto an unconverged scheme" "universal-apply --http $STUB --yes" "$(cat "$USPY")"

reset_log prov-switch-fails
: > "$USPY"
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_FIELDS=all WO_TEST_US_RC=1 \
      "$PROVISION" --yes --project SPK4 --http "$STUB" "${USE_SPIES[@]}" 2>&1); RC=$?
eq "provision fails when universal-switch fails" "1" "$RC"
contains "  naming the script and the project" "universal-switch-spy.sh failed for 'SPK4'" "$OUT"

# ---- provider link / unlink ---------------------------------------------

reset_log link-new
OUT=$(WO_TEST_LOG="$LOG" "$PROVIDER" --http "$STUB" link PROJ-1 --blocked-by PROJ-2 2>&1); RC=$?
eq "link writes a new Blocks link and exits 0" "0" "$RC"
POSTED=$(grep '^POST /issueLink ' "$LOG" | sed 's/^POST \/issueLink //')
eq "  with the blocker as inwardIssue and the blocked ticket as outwardIssue" \
   '{"type":{"name":"Blocks"},"inwardIssue":{"key":"PROJ-2"},"outwardIssue":{"key":"PROJ-1"}}' "$POSTED"
eq "  then reads the blocked ticket back after the write" "GET /issue/PROJ-1?fields=issuelinks" \
   "$(sed -n '/^POST \/issueLink /,$p' "$LOG" | sed -n '2p')"

reset_log link-swapped
SWAPPED="$WORK/provider-swapped.sh"
sed -e 's/inwardIssue: {key: \$b}, outwardIssue: {key: \$k}/inwardIssue: {key: $k}, outwardIssue: {key: $b}/' "$PROVIDER" > "$SWAPPED"
chmod +x "$SWAPPED"
cp -R "$HERE/lib" "$WORK/lib"
OUT=$(WO_TEST_LOG="$LOG" "$SWAPPED" --http "$STUB" link PROJ-1 --blocked-by PROJ-2 2>&1); RC=$?
eq "mutation: swapping inwardIssue and outwardIssue in the payload turns the link row red" "1" "$RC"
contains "  because the read-back shows no inward entry naming the blocker" "shows no inward Blocks link naming 'PROJ-2'" "$OUT"

reset_log link-exists
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_LINKS=right "$PROVIDER" --http "$STUB" link PROJ-1 --blocked-by PROJ-2 2>&1); RC=$?
eq "link on an existing right-direction link exits 0" "0" "$RC"
eq "  and issues no POST and no DELETE" "0" "$(grep -c '^POST \|^DELETE ' "$LOG" || true)"

reset_log link-reversed
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_LINKS=reversed "$PROVIDER" --http "$STUB" link PROJ-1 --blocked-by PROJ-2 2>&1); RC=$?
eq "link on a reversed link without --replace exits 1" "1" "$RC"
contains "  naming the link id" "9001" "$OUT"
eq "  and issues no write" "0" "$(grep -c '^POST \|^DELETE ' "$LOG" || true)"

reset_log link-replace
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_LINKS=reversed "$PROVIDER" --http "$STUB" link PROJ-1 --blocked-by PROJ-2 --replace 2>&1); RC=$?
eq "link --replace over a reversed link exits 0" "0" "$RC"
DEL_AT=$(grep -n '^DELETE /issueLink/9001' "$LOG" | head -1 | cut -d: -f1)
POST_AT=$(grep -n '^POST /issueLink ' "$LOG" | head -1 | cut -d: -f1)
nonempty "  with the DELETE of the reversed link logged" "$DEL_AT"
if [ -n "$DEL_AT" ] && [ -n "$POST_AT" ] && [ "$DEL_AT" -lt "$POST_AT" ]; then ok "  and the DELETE precedes the POST"; else bad "  and the DELETE precedes the POST (delete at '$DEL_AT', post at '$POST_AT')"; fi

reset_log link-nowrite
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_LINKS=nowrite "$PROVIDER" --http "$STUB" link PROJ-1 --blocked-by PROJ-2 2>&1); RC=$?
eq "link exits 1 when the read-back lacks the link" "1" "$RC"
contains "  and says the link was not written" "was not written" "$OUT"

reset_log unlink
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_LINKS=right "$PROVIDER" --http "$STUB" unlink PROJ-1 --blocked-by PROJ-2 2>&1); RC=$?
eq "unlink exits 0" "0" "$RC"
contains "  deleting by the id it read from the blocked ticket" "DELETE /issueLink/9001" "$(cat "$LOG")"
eq "  and reads the ticket back after the delete" "GET /issue/PROJ-1?fields=issuelinks" \
   "$(sed -n '/^DELETE /,$p' "$LOG" | sed -n '2p')"

reset_log unlink-reversed
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_LINKS=reversed "$PROVIDER" --http "$STUB" unlink PROJ-1 --blocked-by PROJ-2 2>&1); RC=$?
eq "unlink leaves a reversed link alone and exits 0" "0" "$RC"
contains "  warning that it is the reverse" "reverse of what was asked" "$OUT"
eq "  with no DELETE" "0" "$(grep -c '^DELETE ' "$LOG" || true)"

reset_log link-args
OUT=$("$PROVIDER" --http "$STUB" link PROJ-1 PROJ-2 2>&1); RC=$?
eq "link takes its direction from the flag, so a bare second key is refused" "1" "$RC"
OUT=$("$PROVIDER" --http "$STUB" link PROJ-1 2>&1); RC=$?
eq "link without --blocked-by is refused" "1" "$RC"
OUT=$("$PROVIDER" --http "$STUB" link PROJ-1 --blocked-by PROJ-1 2>&1); RC=$?
eq "link refuses an issue blocking itself" "1" "$RC"
OUT=$("$PROVIDER" --http "$STUB" unlink PROJ-1 --blocked-by PROJ-2 --replace 2>&1); RC=$?
eq "unlink refuses --replace" "1" "$RC"

reset_log link-dry
OUT=$(WO_TEST_LOG="$LOG" "$PROVIDER" --dry-run --http "$STUB" link PROJ-1 --blocked-by PROJ-2 2>&1); RC=$?
eq "link --dry-run exits 0" "0" "$RC"
contains "  and prints the POST it would make" "WOULD POST /issueLink" "$OUT"
eq "  the stub never serving a write" "0" "$(grep -c '^POST \|^DELETE ' "$LOG" | tr -d ' ')"

# ---- provider parent, and create writing the epic (WO-103) ---------------

OUT=$("$PROVIDER" --dry-run parent PROJ-2 --epic PROJ-1 2>&1); RC=$?
eq "parent --dry-run exits 0" "0" "$RC"
contains "  printing the parent PUT it would make" '{"fields":{"parent":{"key":"PROJ-1"}}}' "$OUT"
contains "  against the ticket" "/rest/api/3/issue/PROJ-2" "$OUT"
OUT=$("$PROVIDER" --dry-run parent PROJ-2 2>&1); RC=$?
eq "parent without --epic is refused" "1" "$RC"
OUT=$("$PROVIDER" --dry-run parent PROJ-2 --epic PROJ-2 2>&1); RC=$?
eq "parent refuses an issue as its own epic" "1" "$RC"

reset_log parent-write
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_LEVELS="PROJ-1:1 PROJ-2:0" "$PROVIDER" --http "$STUB" parent PROJ-2 --epic PROJ-1 2>&1); RC=$?
eq "parent writes the epic and exits 0" "0" "$RC"
contains "  sending fields.parent" 'PUT /issue/PROJ-2 {"fields":{"parent":{"key":"PROJ-1"}}}' "$(cat "$LOG")"
eq "  then reads the ticket back after the write" "GET /issue/PROJ-2?fields=parent" \
   "$(sed -n '/^PUT \/issue\/PROJ-2 /,$p' "$LOG" | sed -n '2p')"
contains "  and says where it now sits" "PROJ-2 is now under epic PROJ-1" "$OUT"

reset_log parent-noop
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_LEVELS="PROJ-1:1 PROJ-2:0" WO_TEST_PARENT_OF="PROJ-2:PROJ-1" \
      "$PROVIDER" --http "$STUB" parent PROJ-2 --epic PROJ-1 2>&1); RC=$?
eq "parent on a ticket already under the epic exits 0" "0" "$RC"
eq "  and writes nothing" "0" "$(grep -c '^PUT ' "$LOG" || true)"

reset_log parent-other
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_LEVELS="PROJ-1:1 PROJ-5:1 PROJ-2:0" WO_TEST_PARENT_OF="PROJ-2:PROJ-5" \
      "$PROVIDER" --http "$STUB" parent PROJ-2 --epic PROJ-1 2>&1); RC=$?
eq "parent refuses to move a ticket out of another epic without --replace" "1" "$RC"
contains "  naming the epic it is under" "PROJ-5" "$OUT"
eq "  and writes nothing" "0" "$(grep -c '^PUT ' "$LOG" || true)"

reset_log parent-replace
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_LEVELS="PROJ-1:1 PROJ-5:1 PROJ-2:0" WO_TEST_PARENT_OF="PROJ-2:PROJ-5" \
      "$PROVIDER" --http "$STUB" parent PROJ-2 --epic PROJ-1 --replace 2>&1); RC=$?
eq "parent --replace moves the ticket to the new epic" "0" "$RC"
contains "  with one parent PUT" 'PUT /issue/PROJ-2 {"fields":{"parent":{"key":"PROJ-1"}}}' "$(cat "$LOG")"

reset_log parent-not-epic
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_LEVELS="PROJ-1:0 PROJ-2:0" "$PROVIDER" --http "$STUB" parent PROJ-2 --epic PROJ-1 2>&1); RC=$?
eq "parent refuses a target that is not at hierarchyLevel 1" "1" "$RC"
contains "  citing the requirement" "JIRA-20" "$OUT"
eq "  and writes nothing" "0" "$(grep -c '^PUT ' "$LOG" || true)"

reset_log parent-missing
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_LEVELS="PROJ-2:0" "$PROVIDER" --http "$STUB" parent PROJ-2 --epic PROJ-1 2>&1); RC=$?
eq "parent refuses an epic that does not exist" "1" "$RC"
contains "  saying so" "does not exist" "$OUT"

reset_log parent-epic-under-epic
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_LEVELS="PROJ-1:1 PROJ-2:1" "$PROVIDER" --http "$STUB" parent PROJ-2 --epic PROJ-1 2>&1); RC=$?
eq "parent refuses to put an epic under an epic" "1" "$RC"
eq "  and writes nothing" "0" "$(grep -c '^PUT ' "$LOG" || true)"

reset_log parent-nowrite
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_LEVELS="PROJ-1:1 PROJ-2:0" WO_TEST_PARENT=nowrite \
      "$PROVIDER" --http "$STUB" parent PROJ-2 --epic PROJ-1 2>&1); RC=$?
eq "parent exits 1 when the read-back shows no epic" "1" "$RC"
contains "  and says the parent was not written" "was not written" "$OUT"

jq '.epic = "PROJ-1"' "$FX/ticket-minimal.json" > "$WORK/epic-ticket.json"

reset_log create-epic
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_FIELDS=all WO_TEST_LEVELS="PROJ-1:1" \
      "$PROVIDER" --http "$STUB" create ZZPROBE Task "" --ticket "$WORK/epic-ticket.json" 2>&1); RC=$?
eq "create --ticket with an existing epic exits 0" "0" "$RC"
contains "  sending the epic as fields.parent in the create body" '"parent":{"key":"PROJ-1"}' "$(grep '^POST /issue ' "$LOG")"
contains "  and reading the created issue's epic back" "GET /issue/PROJ-42?fields=parent" "$(cat "$LOG")"

reset_log create-epic-missing
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_FIELDS=all \
      "$PROVIDER" --http "$STUB" create ZZPROBE Task "" --ticket "$WORK/epic-ticket.json" 2>&1); RC=$?
eq "create --ticket still creates when the epic does not exist yet" "0" "$RC"
contains "  warning with the command that sets it later" "provider.sh parent KEY --epic PROJ-1" "$OUT"
not_contains "  and sending no parent" '"parent"' "$(grep '^POST /issue ' "$LOG")"

reset_log create-epic-wrong-level
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_FIELDS=all WO_TEST_LEVELS="PROJ-1:0" \
      "$PROVIDER" --http "$STUB" create ZZPROBE Task "" --ticket "$WORK/epic-ticket.json" 2>&1); RC=$?
eq "create --ticket refuses an epic that is not at hierarchyLevel 1" "1" "$RC"
eq "  having created nothing" "0" "$(grep -c '^POST /issue ' "$LOG" || true)"

reset_log create-epic-nowrite
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_FIELDS=all WO_TEST_LEVELS="PROJ-1:1" WO_TEST_PARENT=nowrite \
      "$PROVIDER" --http "$STUB" create ZZPROBE Task "" --ticket "$WORK/epic-ticket.json" 2>&1); RC=$?
eq "create --ticket exits 1 when the created issue reads back with no epic" "1" "$RC"
contains "  still printing the issue it created" '"key": "PROJ-42"' "$OUT"
contains "  and naming the command that repairs it" "provider.sh parent PROJ-42 --epic PROJ-1" "$OUT"

jq '.epic = "golden flows"' "$FX/ticket-minimal.json" > "$WORK/epic-local.json"
OUT=$("$PROVIDER" --dry-run create ZZPROBE Task "" --ticket "$WORK/epic-local.json" 2>&1); RC=$?
eq "create --ticket treats an epic that is not a Jira key as not filed yet" "0" "$RC"
contains "  and warns that it writes no parent" "is not a Jira issue key" "$OUT"

OUT=$("$PROVIDER" --dry-run create ZZPROBE Task "" --ticket "$WORK/epic-ticket.json" 2>&1); RC=$?
eq "create --ticket --dry-run with an epic exits 0" "0" "$RC"
contains "  showing the epic lookup" "/rest/api/3/issue/PROJ-1?fields=issuetype" "$OUT"
contains "  and the parent in the body" '"parent":{"key":"PROJ-1"}' "$OUT"

# ---- update, stdin decisions, verify's observation, a transition already
# taken, and issues-api.sh (WO-104) -------------------------------------------

OUT=$(printf '{"defer_until":"2026-12-01"}' | "$PROVIDER" --dry-run update PROJ-1 --ticket - 2>&1); RC=$?
eq "update --ticket - --dry-run exits 0" "0" "$RC"
contains "  printing the PUT, the field named for the site to resolve" '{"fields":{"<defer_until>":"2026-12-01"}}' "$OUT"

reset_log update-write
OUT=$(printf '%s' '{"verify":"make check","verify_fails_today":"make check exits 2 today","touches":["a.txt","b.txt"],"executor":"mixed","defer_until":null,"tags":[]}' \
      | WO_TEST_LOG="$LOG" WO_TEST_FIELDS=all "$PROVIDER" --http "$STUB" update PROJ-1 --ticket - 2>&1); RC=$?
eq "update writes the fields the decision carries and exits 0" "0" "$RC"
PUT=$(grep '^PUT /issue/PROJ-1 ' "$LOG" | sed 's/^PUT \/issue\/PROJ-1 //')
eq "  verify carrying the observation as its last line" "make check
# make check exits 2 today" "$(printf '%s' "$PUT" | jq -r '[.fields.customfield_10044 | .. | objects | select(.type == "text") | .text] | join("\n")')"
eq "  clearing defer_until, given empty, with an explicit null" "null" "$(printf '%s' "$PUT" | jq -c '.fields.customfield_10052')"
eq "  clearing the labels" "[]" "$(printf '%s' "$PUT" | jq -c '.fields.labels')"
eq "  and sending no key the decision does not carry" "customfield_10043,customfield_10044,customfield_10047,customfield_10052,labels" \
   "$(printf '%s' "$PUT" | jq -r '.fields | keys | join(",")')"
contains "  then reading it back and naming what it wrote" "PROJ-1 updated: tags touches executor verify defer_until" "$OUT"

reset_log update-nowrite
OUT=$(printf '{"verify":"make check"}' | WO_TEST_LOG="$LOG" WO_TEST_FIELDS=all WO_TEST_UPDATE=nowrite \
      "$PROVIDER" --http "$STUB" update PROJ-1 --ticket - 2>&1); RC=$?
eq "update exits 1 when the read-back does not show the write" "1" "$RC"
contains "  naming the field by its name" "does not show what was written for: verify" "$OUT"

reset_log update-far-date
OUT=$(printf '{"defer_until":"2099-01-01"}' | WO_TEST_LOG="$LOG" WO_TEST_FIELDS=all \
      "$PROVIDER" --http "$STUB" update PROJ-1 --ticket - 2>&1); RC=$?
eq "update refuses a date Jira's two-digit-year pivot would store a century early" "1" "$RC"
contains "  naming what Jira would store" "would store it as 1999" "$OUT"
eq "  and writes nothing" "0" "$(grep -c '^PUT ' "$LOG" || true)"
OUT=$(printf '{"defer_until":"next week"}' | "$PROVIDER" --dry-run update PROJ-1 --ticket - 2>&1); RC=$?
eq "update refuses a defer_until that is not a full-date" "1" "$RC"

OUT=$(printf '{"problem":"only this"}' | "$PROVIDER" --dry-run update PROJ-1 --ticket - 2>&1); RC=$?
eq "update refuses a description given in part" "1" "$RC"
contains "  because it rewrites the description whole" "rewrites the description whole" "$OUT"
OUT=$(jq -c '.decisions[0] | {problem, solution, rationale, out_of_scope}' "$FX/ticket-full.json" \
      | "$PROVIDER" --dry-run update PROJ-1 --ticket - 2>&1); RC=$?
eq "update rewrites a description given whole" "0" "$RC"
contains "  under the same headings create writes" '"text":"Out of scope"' "$OUT"
OUT=$(printf '{"title":"  "}' | "$PROVIDER" --dry-run update PROJ-1 --ticket - 2>&1); RC=$?
eq "update refuses an empty title" "1" "$RC"
OUT=$(printf '{"verify_fails_today":"x"}' | "$PROVIDER" --dry-run update PROJ-1 --ticket - 2>&1); RC=$?
eq "update refuses verify_fails_today without verify" "1" "$RC"
OUT=$(printf '{"id":"X-1"}' | "$PROVIDER" --dry-run update PROJ-1 --ticket - 2>&1); RC=$?
eq "update refuses a decision carrying nothing it writes" "1" "$RC"
OUT=$(printf '{"epic":"PROJ-9","blocked_by":["PROJ-3"],"verify":"x"}' | "$PROVIDER" --dry-run update PROJ-1 --ticket - 2>&1); RC=$?
eq "update writes the rest of a decision that carries epic and blocked_by" "0" "$RC"
contains "  pointing the epic at parent" "provider.sh parent PROJ-1 --epic EPIC" "$OUT"
contains "  and blocked_by at link" "provider.sh link PROJ-1 --blocked-by BLOCKER" "$OUT"

OUT=$("$PROVIDER" --dry-run create ZZPROBE Task "" --ticket - < "$FX/ticket-minimal.json" 2>&1); RC=$?
eq "create --ticket - reads the decision from stdin" "0" "$RC"
contains "  taking its title" '"summary":"The smallest decision create will write"' "$OUT"
OUT=$("$PROVIDER" --dry-run create ZZPROBE Task "" --ticket "$FX/ticket-full.json" 2>&1)
contains "create writes verify_fails_today as verify's last line ([MUST-10])" \
    '"text":"# create takes a summary and nothing else, so the dry-run body carries no description."' "$OUT"

reset_log transition-noop
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_STATUS="Open" "$PROVIDER" --http "$STUB" transition PROJ-1 open 2>&1); RC=$?
eq "transition to the position the issue already holds exits 0" "0" "$RC"
contains "  saying so" "PROJ-1 is already Open" "$OUT"
eq "  and posts nothing" "0" "$(grep -c '^POST \|^PUT ' "$LOG" || true)"

reset_log stale-transitions
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_STALE_TRANSITIONS=2 "$PROVIDER" --http "$STUB" transition PROJ-1 completed 2>&1); RC=$?
eq "a transition list read stale just after a write is read again, and the move goes through" "0" "$RC"
eq "  on the third read of the list" "3" "$(grep -c '^GET /issue/PROJ-1/transitions' "$LOG")"
reset_log stale-transitions-out
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_STALE_TRANSITIONS=9 WORK_ORDER_JIRA_SETTLE_TRIES=3 \
      "$PROVIDER" --http "$STUB" transition PROJ-1 completed 2>&1); RC=$?
eq "  and refused once the settle window runs out" "1" "$RC"
eq "  after exactly WORK_ORDER_JIRA_SETTLE_TRIES reads" "3" "$(grep -c '^GET /issue/PROJ-1/transitions' "$LOG")"
eq "  having posted nothing" "0" "$(grep -c '^POST ' "$LOG" || true)"

reset_log stale-status
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_STATUS_SEQ="To Do|To Do" "$PROVIDER" --http "$STUB" transition PROJ-1 completed 2>&1); RC=$?
eq "a status read-back that is stale is read again rather than reported as a failed move" "0" "$RC"
contains "  and the move is reported once it reads back" "PROJ-1 is now Completed" "$OUT"

reset_log stale-noop
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_STATUS_SEQ="Completed|To Do" "$PROVIDER" --http "$STUB" transition PROJ-1 completed 2>&1); RC=$?
eq "a no-op needs two reads: one stale read showing the target does not skip the move" "0" "$RC"
contains "  so the transition is posted" '{"transition":{"id":"81"}}' "$(cat "$LOG")"

ISSUESAPI="$HERE/issues-api.sh"
reset_log issues-api
OUT=$(WO_TEST_LOG="$LOG" ISSUES_API_HTTP="$STUB" "$ISSUESAPI" --show-secrets raw GET /field 2>&1); RC=$?
eq "issues-api.sh forwards a GET to the client" "0" "$RC"
eq "  as the client's own GET" "GET /field" "$(cat "$LOG")"
OUT=$(ISSUES_API_HTTP="$STUB" "$ISSUESAPI" raw POST /issue '{}' 2>&1); RC=$?
eq "issues-api.sh forwards nothing but GET" "1" "$RC"
reset_log issues-api-board
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_SEARCH=onepage ISSUES_API_HTTP="$STUB" python3 "$HERE/../../reference/issues.py" board \
      --source jira --jira-api "$ISSUESAPI" --jira-project PROJ 2>&1); RC=$?
eq "reference/issues.py reads a Space through issues-api.sh" "0" "$RC"
contains "  listing the issue the search returned" "PROJ-111" "$OUT"
eq "  having resolved the field ids by name first" "GET /field" "$(head -1 "$LOG")"

# ---- provider transition --outcome and create's duplicate check (WO-96) ---

MUTANT="$WORK/provider-outcome-in-body.sh"
reset_log cancel-outcome
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_FIELDS=all "$PROVIDER" --http "$STUB" transition PROJ-1 cancelled --outcome "superseded by PROJ-9" 2>&1); RC=$?
eq "transition cancelled --outcome exits 0" "0" "$RC"
contains "  and reports the status read back" "PROJ-1 is now Cancelled" "$OUT"
PUT_AT=$(grep -n '^PUT /issue/PROJ-1 ' "$LOG" | head -1 | cut -d: -f1)
TRANS_AT=$(grep -n '^POST /issue/PROJ-1/transitions ' "$LOG" | head -1 | cut -d: -f1)
nonempty "  with the outcome PUT logged" "$PUT_AT"
nonempty "  and the transition POST logged" "$TRANS_AT"
if [ -n "$PUT_AT" ] && [ -n "$TRANS_AT" ] && [ "$PUT_AT" -lt "$TRANS_AT" ]; then ok "  the outcome PUT comes before the transition POST"; else bad "  the outcome PUT comes before the transition POST"; fi
eq "  the PUT body is the outcome as an ADF document under the resolved field id" \
   '{"fields":{"customfield_10053":{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"superseded by PROJ-9"}]}]}}}' \
   "$(grep '^PUT /issue/PROJ-1 ' "$LOG" | sed 's/^PUT \/issue\/PROJ-1 //')"
eq "  the transition body carries no fields" '{"transition":{"id":"91"}}' \
   "$(grep '^POST /issue/PROJ-1/transitions ' "$LOG" | sed 's/^POST \/issue\/PROJ-1\/transitions //')"
READ_OUTCOME_AT=$(grep -n '^GET /issue/PROJ-1?fields=customfield_10053' "$LOG" | head -1 | cut -d: -f1)
READ_STATUS_AT=$(grep -n '^GET /issue/PROJ-1?fields=status' "$LOG" | tail -1 | cut -d: -f1)
if [ -n "$READ_OUTCOME_AT" ] && [ -n "$PUT_AT" ] && [ "$READ_OUTCOME_AT" -gt "$PUT_AT" ] && [ "$READ_OUTCOME_AT" -lt "$TRANS_AT" ]; then ok "  the outcome is read back between the PUT and the transition"; else bad "  the outcome is read back between the PUT and the transition"; fi
if [ -n "$READ_STATUS_AT" ] && [ -n "$TRANS_AT" ] && [ "$READ_STATUS_AT" -gt "$TRANS_AT" ]; then ok "  the status is read back after the transition"; else bad "  the status is read back after the transition"; fi

reset_log cancel-outcome-stdin
printf 'from stdin\n' | WO_TEST_LOG="$LOG" WO_TEST_FIELDS=all "$PROVIDER" --http "$STUB" transition PROJ-1 cancelled --outcome - >/dev/null 2>&1
contains "transition --outcome - reads the outcome from stdin" '"text":"from stdin"' "$(cat "$LOG")"

sed -e 's/http PUT "\/issue\/\$TKEY" "\$OBODY" >\/dev\/null || die/true || die/' \
    -e 's/settled outcome_is "\$TKEY" "\$OFID" \\/true \\/' \
    -e "s#--arg id \"\$TRANSITION_ID\" '{transition: {id: \$id}}'#--arg id \"\$TRANSITION_ID\" --argjson o \"\$ODOC\" '{transition: {id: \$id}, fields: {customfield_10053: \$o}}'#" \
    "$PROVIDER" > "$MUTANT"
chmod +x "$MUTANT"
reset_log cancel-mutant
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_FIELDS=all "$MUTANT" --http "$STUB" transition PROJ-1 cancelled --outcome "superseded by PROJ-9" 2>&1); RC=$?
nonempty "  the mutant (outcome moved into the transition body) actually ran" "$(cat "$LOG")"
contains "  and sent the field inside the transition body" '"fields":{"customfield_10053"' "$(grep '^POST /issue/PROJ-1/transitions ' "$LOG")"
eq "mutation: moving outcome into the transition body leaves row 1's PUT assertion with nothing to find" "" \
   "$(grep -n '^PUT /issue/PROJ-1 ' "$LOG" | head -1 | cut -d: -f1)"

reset_log cancel-noop
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_FIELDS=all "$PROVIDER" --http "$STUB" transition PROJ-1 cancelled 2>&1); RC=$?
eq "transition cancelled with no --outcome and an empty field exits 1" "1" "$RC"
contains "  naming --outcome" "--outcome" "$OUT"
eq "  and writing nothing" "0" "$(grep -c '^POST \|^PUT \|^DELETE ' "$LOG" | tr -d ' ')"

reset_log cancel-prior
WO_TEST_LOG="$LOG" WO_TEST_FIELDS=all WO_TEST_OUTCOME=set "$PROVIDER" --http "$STUB" transition PROJ-1 cancelled >/dev/null 2>&1; RC=$?
eq "transition cancelled with no --outcome but the field already set goes through" "0" "$RC"
eq "  without an outcome PUT" "0" "$(grep -c '^PUT ' "$LOG" | tr -d ' ')"

reset_log cancel-nowrite
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_FIELDS=all WO_TEST_OUTCOME=nowrite "$PROVIDER" --http "$STUB" transition PROJ-1 cancelled --outcome "x" 2>&1); RC=$?
eq "a PUT whose read-back lacks the outcome exits 1" "1" "$RC"
eq "  and takes no transition" "0" "$(grep -c '^POST /issue/PROJ-1/transitions' "$LOG" | tr -d ' ')"

reset_log cancel-nofield
OUT=$(WO_TEST_LOG="$LOG" "$PROVIDER" --http "$STUB" transition PROJ-1 cancelled --outcome "x" 2>&1); RC=$?
eq "--outcome on a site with no outcome field exits 1 before any write" "1" "$RC"
contains "  naming the field" "no custom field named 'outcome'" "$OUT"
eq "  and writing nothing" "0" "$(grep -c '^POST \|^PUT ' "$LOG" | tr -d ' ')"

reset_log outcome-args
OUT=$("$PROVIDER" --http "$STUB" transition PROJ-1 cancelled --outcome 2>&1); RC=$?
eq "--outcome with no text is refused" "1" "$RC"
OUT=$("$PROVIDER" --http "$STUB" transition PROJ-1 cancelled --bogus 2>&1); RC=$?
eq "transition refuses an unknown trailing flag" "1" "$RC"

reset_log cancel-dry
OUT=$(WO_TEST_LOG="$LOG" "$PROVIDER" --dry-run --http "$STUB" transition PROJ-1 cancelled --outcome "x" 2>&1); RC=$?
eq "transition --outcome --dry-run exits 0" "0" "$RC"
contains "  and prints the PUT it would make" "WOULD PUT /issue/PROJ-1" "$OUT"
eq "  the stub never serving a write" "0" "$(grep -c '^POST \|^PUT \|^DELETE ' "$LOG" | tr -d ' ')"

reset_log dup-exact
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_DUP="Fix the thing" "$PROVIDER" --http "$STUB" create PROJ Task "Fix the thing" 2>/dev/null); RC=$?
eq "create with an open issue of identical summary exits 3" "3" "$RC"
eq "  printing the existing issue as {id,key,self}" \
   '{"id":"10077","key":"PROJ-77","self":"https://example.atlassian.net/rest/api/3/issue/10077"}' "$(printf '%s' "$OUT" | jq -c .)"
eq "  and issuing no POST /issue" "0" "$(grep -c '^POST /issue ' "$LOG" | tr -d ' ')"
contains "  the search excludes Done issues" "statusCategory" "$(grep '^GET /search/jql' "$LOG")"

reset_log dup-ticket
TITLE=$(jq -r '.title' "$FX/ticket-minimal.json")
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_DUP="$TITLE" "$PROVIDER" --http "$STUB" create PROJ Task "" --ticket "$FX/ticket-minimal.json" 2>/dev/null); RC=$?
eq "create --ticket checks the ticket's own title and exits 3 on a match" "3" "$RC"
eq "  with no POST /issue" "0" "$(grep -c '^POST /issue ' "$LOG" | tr -d ' ')"

reset_log dup-fuzzy
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_DUP="Fix the thing now" "$PROVIDER" --http "$STUB" create PROJ Task "Fix the thing" 2>&1); RC=$?
eq "a summary that only fuzzily matches still creates" "0" "$RC"
eq "  with one POST /issue" "1" "$(grep -c '^POST /issue ' "$LOG" | tr -d ' ')"

reset_log dup-done
WO_TEST_LOG="$LOG" WO_TEST_DUP="Fix the thing" WO_TEST_DUP_CAT="done" "$PROVIDER" --http "$STUB" create PROJ Task "Fix the thing" >/dev/null 2>&1; RC=$?
eq "an identical summary on a Done issue does not block create" "0" "$RC"

reset_log dup-allow
WO_TEST_LOG="$LOG" WO_TEST_DUP="Fix the thing" "$PROVIDER" --http "$STUB" create PROJ Task "Fix the thing" --allow-duplicate >/dev/null 2>&1; RC=$?
eq "--allow-duplicate creates despite an exact match" "0" "$RC"
eq "  with one POST /issue and no search" "1:0" "$(grep -c '^POST /issue ' "$LOG" | tr -d ' '):$(grep -c '^GET /search/jql' "$LOG" | tr -d ' ')"

reset_log dup-dry
OUT=$(WO_TEST_LOG="$LOG" "$PROVIDER" --dry-run --http "$STUB" create PROJ Task "Fix the thing" 2>&1); RC=$?
eq "create --dry-run exits 0" "0" "$RC"
contains "  and prints the duplicate search it would make" "WOULD GET /search/jql" "$OUT"

jql_sent() { grep '^GET /search/jql' "$1" | head -1 | sed 's/^GET \/search\/jql?jql=//; s/&fields=.*//' | python3 -c 'import sys,urllib.parse; print(urllib.parse.unquote(sys.stdin.read().strip()))'; }

OLDPROVIDER="$WORK/provider-old-escape.sh"
python3 - "$PROVIDER" "$OLDPROVIDER" <<'PYEOF2'
import sys
s = open(sys.argv[1]).read()
new = ' | gsub("\\\\\\\\"; "\\\\\\\\")'
assert new in s
open(sys.argv[2], "w").write(s.replace(new, ""))
PYEOF2
chmod +x "$OLDPROVIDER"

reset_log esc-backslash
WO_TEST_LOG="$LOG" "$PROVIDER" --http "$STUB" create PROJ Task 'a\b' >/dev/null 2>&1
eq "a backslash in the summary reaches JQL as one Lucene-escaped, string-escaped backslash" \
   'project = "PROJ" AND statusCategory != Done AND summary ~ "a\\\\b"' "$(jql_sent "$LOG")"
reset_log esc-backslash-old
WO_TEST_LOG="$LOG" "$OLDPROVIDER" --http "$STUB" create PROJ Task 'a\b' >/dev/null 2>&1
not_contains "mutation: without the doubling step the backslash row is red" 'summary ~ "a\\\\b"' "$(jql_sent "$LOG")"

reset_log esc-bsq
WO_TEST_LOG="$LOG" "$PROVIDER" --http "$STUB" create PROJ Task 'a\"b' >/dev/null 2>&1
eq "a backslash then a quote cannot close the JQL string early" \
   'project = "PROJ" AND statusCategory != Done AND summary ~ "a\\\\\"b"' "$(jql_sent "$LOG")"
reset_log esc-bsq-old
WO_TEST_LOG="$LOG" "$OLDPROVIDER" --http "$STUB" create PROJ Task 'a\"b' >/dev/null 2>&1
not_contains "mutation: without the doubling step the backslash-quote row is red" 'summary ~ "a\\\\\"b"' "$(jql_sent "$LOG")"

reset_log esc-quote
WO_TEST_LOG="$LOG" "$PROVIDER" --http "$STUB" create PROJ Task 'Fix "quoted" thing' >/dev/null 2>&1
eq "plain quotes in the summary are escaped" \
   'project = "PROJ" AND statusCategory != Done AND summary ~ "Fix \"quoted\" thing"' "$(jql_sent "$LOG")"

reset_log esc-dup
OUT=$(WO_TEST_LOG="$LOG" WO_TEST_DUP='a\"b' "$PROVIDER" --http "$STUB" create PROJ Task 'a\"b' 2>/dev/null); RC=$?
eq "an exact match on a backslash-and-quote summary still exits 3" "3" "$RC"

reset_log contract-new
NEWOUT=$(WO_TEST_LOG="$LOG" "$PROVIDER" --http "$STUB" create PROJ Task "Brand new" 2>/dev/null); NEWRC=$?
reset_log contract-dup
DUPOUT=$(WO_TEST_LOG="$LOG" WO_TEST_DUP="Brand new" "$PROVIDER" --http "$STUB" create PROJ Task "Brand new" 2>/dev/null); DUPRC=$?
eq "create stdout contract: exit 0 prints JSON with .id, .key and .self" "true" \
   "$(printf '%s' "$NEWOUT" | jq -r '(.id != null) and (.key != null) and (.self != null)' 2>/dev/null)"
eq "  exit 3 prints JSON with the same three fields" "true" \
   "$(printf '%s' "$DUPOUT" | jq -r '(.id != null) and (.key != null) and (.self != null)' 2>/dev/null)"
eq "  so \$(provider.sh create ...) is read with jq -r .key on both paths, exits 0 and 3" "0:3" "$NEWRC:$DUPRC"

# ---- summary ------------------------------------------------------------

echo
if [ "$FAIL" -eq 0 ]; then
    echo "$N assertions, all passed."
    exit 0
fi
echo "$N assertions, $FAIL failed."
exit 1
