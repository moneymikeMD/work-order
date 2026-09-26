#!/bin/bash
#
# universal-switch-selftest.sh — offline tests for universal-switch.sh.
#
# Every run passes --http pointing at a stub of jira-http.sh's shape, so
# nothing reaches a network, a Jira site or a credential. The stub replays
# fixtures/switch/, recorded live from project LAB, and keeps state in a
# scratch directory so a switch, and the deletes after it, change what later
# reads return. Responses no live read can produce (the Universal scheme
# before it exists, the switch's 303 task, GET /task, the writes) are built
# inline and marked SYNTHETIC.
#
# Usage: plugins/work-order-jira/universal-switch-selftest.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SWITCH="$HERE/universal-switch.sh"
export WO_TEST_FX="$HERE/fixtures/switch"
export WO_TEST_FIELDS="$HERE/fixtures/field.list.txt"

[ -x "$SWITCH" ] || { echo "$SWITCH is missing or not executable" >&2; exit 2; }
[ -d "$WO_TEST_FX" ] || { echo "$WO_TEST_FX is missing" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq is required to run this selftest" >&2; exit 2; }

N=0
FAIL=0
ok()  { N=$((N + 1)); echo "ok - $1"; }
bad() { N=$((N + 1)); FAIL=$((FAIL + 1)); echo "FAIL - $1"; }
eq() {
    if [ "$2" = "$3" ]; then ok "$1"; else
        bad "$1"; printf '       expected: %s\n       actual:   %s\n' "$2" "$3"
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

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

STUB="$WORK/jira-http-stub.sh"
cat > "$STUB" <<'STUBEOF'
#!/bin/bash
# A jira-http.sh-shaped stub over fixtures/switch/. State lives in
# $WO_TEST_STATE. Knobs: SW_SCHEME=missing, SW_INUSE=<status id>, SW_GROUP_DROP=<status>,
# SW_TASK=failed|empty, SW_BUSY=1 (one 409 first), SW_LOCKED=1 (one lock 500 on delete), SW_EXTRA_SCHEME=<scheme id still using the old workflow>,
# SW_LAYOUT=missing (no tier issue type schemes yet), SW_WFS=current (the recorded post-WO-75 workflow scheme list).
set -uo pipefail
FX="$WO_TEST_FX"
ST="$WO_TEST_STATE"
printf '%s\n' "$*" >> "$WO_TEST_LOG"
M="${1:-}"; P="${2:-}"; B="${3:-}"

fx() { sed -e '/^#/d' -e '/^HTTP [0-9]*$/d' "$FX/$1"; }
LABWF=c01c212e-e092-4d2b-92aa-ca757e11a56f

# SYNTHETIC: the Universal scheme, derived from the recorded NWM scheme,
# which is the one live scheme with per-issue-type mappings.
target_scheme() {
    fx workflowscheme.10010.txt | jq -c '{id: 10100, name: "Universal Managed Workflow Scheme",
        defaultWorkflow: "Universal Managed Workflow",
        issueTypeMappings: {"10000": "Universal Managed Grouping Workflow", "10011": "Universal Managed Grouping Workflow"}}'
}

# SYNTHETIC: the two Universal workflows, derived from the recorded LAB
# workflow by dropping the statuses each one does not carry.
universal_wf() {
    fx workflow.search.lab.txt | jq -c --arg n "$1" --argjson drop "$2" '
        .values[0].id = {name: $n, entityId: ("u-" + ($n | length | tostring))}
        | .values[0].statuses |= map(select(.name as $s | $drop | index($s) | not))'
}

key_of() { case "$1" in 10004) echo LAB ;; 10013) echo EBS ;; *) echo "?" ;; esac; }
# dels KIND — the ids of KIND this test deleted, as a JSON array.
dels() { find "$ST" -name "deleted.$1.*" | sed "s#.*/deleted\.$1\.##" | jq -Rsc 'split("\n") | map(select(length > 0))'; }
on() { cat "$ST/on.$1" 2>/dev/null || echo null; }

# SYNTHETIC: the tier schemes universal-apply.sh creates; SW_LAYOUT=missing
# leaves them out.
targets() {
    [ "${SW_LAYOUT:-}" = "missing" ] && { echo '[]'; return; }
    case "$1" in
        its) echo '[{"id":"10200","name":"Universal Managed Issue Type Scheme","description":"","defaultIssueTypeId":"10010"},
                    {"id":"10202","name":"Universal Simplified Issue Type Scheme","description":"","defaultIssueTypeId":"10010"}]' ;;
        itss) echo '[{"id":"10201","name":"Universal Managed Issue Type Screen Scheme","description":""},
                     {"id":"10203","name":"Universal Simplified Issue Type Screen Scheme","description":""}]' ;;
    esac
}

# scheme_list FIXTURE KIND — the recorded list, less what this test deleted,
# plus the tier schemes, with the switched project moved onto its target.
scheme_list() {
    fx "$1" | jq -c --argjson t "$(targets "$2")" --argjson d "$(dels "$2")" --argjson on "$(on "$2")" '
        .values |= (map(select((.id | tostring) as $i | $d | index([$i]) | not)) + $t
            | map(if $on == null then . else
                    .projects.values = ([(.projects.values // [])[] | select((.id | tostring) != $on.pid)]
                        + (if (.id | tostring) == $on.target then [{id: $on.pid, key: $on.key}] else [] end))
                  end))
        | .total = (.values | length)'
}

# project_scheme KIND FIXTURE_STEM OBJKEY PID — GET /<stem>/project for one project.
project_scheme() {
    local o
    o=$(on "$1")
    if [ "$o" != "null" ]; then
        scheme_list "$2.list.txt" "$1" | jq -c --arg k "$3" --arg p "$4" --argjson on "$o" \
            '{values: [.values[] | select((.id | tostring) == $on.target) | {($k): del(.projects), projectIds: [$p]}]}'
    else
        fx "$2.project.$(key_of "$4").txt"
    fi
}

ss_list() {
    fx screenscheme.list.txt | jq -c --argjson d "$(dels ss)" --argjson di "$(dels itss)" '
        .values |= [.[] | select((.id | tostring) as $i | $d | index([$i]) | not)
            | .issueTypeScreenSchemes.values |= map(select((.id | tostring) as $i | $di | index([$i]) | not))]
        | .total = (.values | length)'
}

case "$M:$P" in
    GET:/project/*)
        K=${P#/project/}
        fx "project.$K.txt" | jq -c --argjson c "$(cat "$ST/category.$K" 2>/dev/null || echo null)" \
            'if $c == null then . else .projectCategory = {id: ($c | tostring)} end' ;;
    PUT:/project/*)
        # SYNTHETIC: 200 with the project.
        K=${P#/project/}
        printf '%s' "$B" | jq -r '.categoryId' > "$ST/category.$K"
        echo '{}' ;;
    GET:/projectCategory) fx projectcategory.list.txt ;;
    GET:/issuetypescheme/project\?projectId=*)
        project_scheme its issuetypescheme issueTypeScheme "${P#*projectId=}" ;;
    GET:/issuetypescreenscheme/project\?projectId=*)
        project_scheme itss issuetypescreenscheme issueTypeScreenScheme "${P#*projectId=}" ;;
    GET:/issuetypescheme\?*) scheme_list issuetypescheme.list.txt its ;;
    GET:/issuetypescreenscheme\?*) scheme_list issuetypescreenscheme.list.txt itss ;;
    PUT:/issuetypescheme/project|PUT:/issuetypescreenscheme/project)
        # SYNTHETIC: 204. The project moves onto the named scheme.
        k=its; [ "$P" = "/issuetypescreenscheme/project" ] && k=itss
        pid=$(printf '%s' "$B" | jq -r '.projectId')
        printf '%s' "$B" | jq -c --arg k "$(key_of "$pid")" \
            '{target: (.issueTypeSchemeId // .issueTypeScreenSchemeId), pid: .projectId, key: $k}' > "$ST/on.$k" ;;
    DELETE:/issuetypescheme/*|DELETE:/issuetypescreenscheme/*)
        # SYNTHETIC: 204, or 400 while a project still uses it.
        k=its; case "$P" in /issuetypescreenscheme/*) k=itss ;; esac
        id=${P##*/}
        f=issuetypescheme.list.txt; [ "$k" = "itss" ] && f=issuetypescreenscheme.list.txt
        n=$(scheme_list "$f" "$k" | jq --arg i "$id" '[.values[] | select((.id | tostring) == $i) | (.projects.values // [])[]] | length')
        [ "$n" = "0" ] || { printf 'HTTP 400\n{"errorMessages":["scheme is in use"]}\n' >&2; exit 1; }
        : > "$ST/deleted.$k.$id" ;;
    GET:/screenscheme\?*) ss_list ;;
    DELETE:/screenscheme/*)
        # SYNTHETIC: 204, or 400 while an issue type screen scheme uses it.
        id=${P##*/}
        n=$(ss_list | jq --arg i "$id" '[.values[] | select((.id | tostring) == $i) | .issueTypeScreenSchemes.values[]] | length')
        [ "$n" = "0" ] || { printf 'HTTP 400\n{"errorMessages":["screen scheme is in use"]}\n' >&2; exit 1; }
        : > "$ST/deleted.ss.$id" ;;
    GET:/screens\?*)
        fx screens.list.txt | jq -c --argjson d "$(dels screen)" '
            .values |= map(select((.id | tostring) as $i | $d | index([$i]) | not)) | .total = (.values | length)' ;;
    DELETE:/screens/*)
        # SYNTHETIC: 204, or 400 while a screen scheme uses it.
        id=${P##*/}
        n=$(fx screenscheme.list.txt | jq --argjson d "$(dels ss)" --arg i "$id" \
            '[.values[] | select((.id | tostring) as $s | $d | index([$s]) | not) | select([.screens[] | tostring] | index([$i]))] | length')
        [ "$n" = "0" ] || { printf 'HTTP 400\n{"errorMessages":["screen is in use"]}\n' >&2; exit 1; }
        : > "$ST/deleted.screen.$id" ;;
    GET:/workflowscheme\?*)
        [ "${SW_WFS:-}" = "current" ] && { fx workflowscheme.list.current.txt; exit 0; }
        fx workflowscheme.list.txt | jq -c --argjson t "$(target_scheme)" \
            --arg missing "${SW_SCHEME:-}" --arg gone "$([ -f "$ST/scheme-deleted" ] && echo 1)" '
            .values |= (map(select(.name | startswith("LAB:")) | select($gone != "1"))
                        + (if $missing == "missing" then [] else [$t] end))
            | .total = (.values | length)' ;;
    GET:/workflowscheme/project\?projectId=10013) fx workflowscheme.project.EBS.txt ;;
    GET:/workflowscheme/project\?projectId=10004)
        if [ -f "$ST/switched" ]; then
            jq -cn --argjson t "$(target_scheme)" '{values: [{projectIds: ["10004"], workflowScheme: $t}]}'
        else
            fx workflowscheme.project.LAB.txt
        fi ;;
    GET:/workflowscheme/10005/projectUsages)
        if [ -f "$ST/switched" ]; then
            fx workflowscheme.10005.projectUsages.txt | jq -c '.projects.values = []'
        else
            fx workflowscheme.10005.projectUsages.txt
        fi ;;
    GET:/workflow/search\?workflowName=Software%20Simplified%20Workflow%20for%20Project%20LAB*)
        if [ -f "$ST/wf-deleted" ]; then fx workflow.search.missing.txt; else fx workflow.search.lab.txt; fi ;;
    GET:/workflow/search\?workflowName=Universal%20Managed%20Workflow\&*|GET:/workflow/search\?workflowName=Universal%20Managed%20Workflow)
        universal_wf "Universal Managed Workflow" '["To Do","Done"]' ;;
    GET:/workflow/search\?workflowName=Universal%20Managed%20Grouping%20Workflow*)
        universal_wf "Universal Managed Grouping Workflow" "$(jq -cn --arg x "${SW_GROUP_DROP:-}" '["To Do","Done","Awaiting Deployment","Deferred"] + (if $x == "" then [] else [$x] end)')" ;;
    GET:/workflow/search*) fx workflow.search.missing.txt ;;
    GET:/workflow/$LABWF/workflowSchemes)
        fx workflow.workflowSchemes.txt | jq -c --arg gone "$([ -f "$ST/scheme-deleted" ] && echo 1)" --arg extra "${SW_EXTRA_SCHEME:-}" '
            .workflowSchemes.values |= (map(select($gone != "1")) + (if $extra == "" then [] else [{id: $extra}] end))' ;;
    GET:/workflow/$LABWF/projectUsages)
        if [ -f "$ST/switched" ]; then fx workflow.projectUsages.txt | jq -c '.projects.values = []'
        else fx workflow.projectUsages.txt; fi ;;
    GET:/field) sed -e '/^#/d' "$WO_TEST_FIELDS" ;;
    POST:/search/jql)
        J=$(printf '%s' "$B" | jq -r '.jql'); T=$(printf '%s' "$B" | jq -r '.nextPageToken // ""')
        P1=$(fx search.jql.todo.page1.txt | jq -r '.nextPageToken')
        P2=$(fx search.jql.todo.page2.txt | jq -r '.nextPageToken')
        case "$J" in
            *'status = "To Do"'*)
                if [ -f "$ST/switched" ]; then fx search.jql.empty.txt
                elif [ -z "$T" ]; then fx search.jql.todo.page1.txt
                elif [ "$T" = "$P1" ]; then fx search.jql.todo.page2.txt
                elif [ "$T" = "$P2" ]; then fx search.jql.todo.page3.txt
                else printf 'HTTP 400\n{"errorMessages":["stub: unknown nextPageToken"]}\n' >&2; exit 1; fi ;;
            *'status in ("To Do", "Done")'*) fx search.jql.empty.txt ;;
            *"AND status = ${SW_INUSE:-none}") fx search.jql.todo.page1.txt | jq -c '.issues |= .[0:1] | .isLast = true' ;;
            *) fx search.jql.empty.txt ;;
        esac ;;
    GET:/issue/*/transitions) fx issue.transitions.LAB-14.txt ;;
    # SYNTHETIC: a transition answers 204 with no body.
    POST:/issue/*/transitions) : ;;
    POST:/workflowscheme/project/switch)
        # SYNTHETIC: Jira answers 303 with the task bean, which jira-http.sh
        # reports as a non-2xx: "HTTP 303" on stderr, then the body.
        printf '%s' "$B" > "$ST/switch-body.json"
        [ "${SW_TASK:-}" = "failed" ] || : > "$ST/switched"
        # Measured live on WO 2026-09-26: the 303 body was empty.
        if [ "${SW_BUSY:-}" = "1" ] && [ ! -f "$ST/busy-once" ]; then
            : > "$ST/busy-once"
            printf 'HTTP 409\n{"errorMessages":["Another task is currently running, please try again later."]}\n' >&2; exit 1
        fi
        [ "${SW_TASK:-}" = "empty" ] && { printf 'HTTP 303\n' >&2; exit 1; }
        printf 'HTTP 303\n{"self":"https://example.atlassian.net/rest/api/3/task/10500","id":"10500","description":"Switch workflow scheme","status":"ENQUEUED","progress":0,"submitted":1,"submittedBy":1,"elapsedRuntime":0,"lastUpdate":1}\n' >&2
        exit 1 ;;
    GET:/task/10500)
        # SYNTHETIC: RUNNING on the first poll, then the final state.
        if [ ! -f "$ST/polled" ]; then : > "$ST/polled"; echo '{"id":"10500","status":"RUNNING","progress":50}'
        elif [ "${SW_TASK:-}" = "failed" ]; then echo '{"id":"10500","status":"FAILED","progress":100,"message":"Status migration failed"}'
        else echo '{"id":"10500","status":"COMPLETE","progress":100}'; fi ;;
    # SYNTHETIC: the deletes answer 204, or 400 while still in use (per the API docs).
    DELETE:/workflowscheme/10005)
        if [ "${SW_LOCKED:-}" = "1" ] && [ ! -f "$ST/locked-once" ]; then
            : > "$ST/locked-once"
            printf 'HTTP 500\n{"message":"Cannot acquire workflow lock. There is a currently running workflow task: x","status-code":500}\n' >&2; exit 1
        fi
        [ -f "$ST/switched" ] || { printf 'HTTP 400\n{"errorMessages":["scheme is active"]}\n' >&2; exit 1; }
        : > "$ST/scheme-deleted" ;;
    DELETE:/workflow/$LABWF)
        { [ -f "$ST/scheme-deleted" ] && [ -z "${SW_EXTRA_SCHEME:-}" ]; } \
            || { printf 'HTTP 400\n{"errorMessages":["workflow is in use"]}\n' >&2; exit 1; }
        : > "$ST/wf-deleted" ;;
    *) printf 'HTTP 501\n{"stub":"no case for %s %s"}\n' "$M" "$P" >&2; exit 1 ;;
esac
STUBEOF
chmod +x "$STUB"

export WO_SWITCH_POLL_SECONDS=0 WO_SWITCH_TIMEOUT_SECONDS=5

# fresh NAME — a new call log and an empty state directory.
LOG=""
fresh() {
    LOG="$WORK/log.$1"
    export WO_TEST_LOG="$LOG" WO_TEST_STATE="$WORK/state.$1"
    : > "$LOG"
    rm -rf "$WO_TEST_STATE"; mkdir -p "$WO_TEST_STATE"
}
writes() { grep -Ev '^(GET |POST /search/jql )' "$LOG" || true; }
run() { OUT=$("$SWITCH" LAB --http "$STUB" "$@" 2>&1); RC=$?; }

# ---- no --yes ------------------------------------------------------------

fresh noyes
run
eq "without --yes, writes are refused with exit 3" "3" "$RC"
contains "  and says so" "not confirmed (no --yes)" "$OUT"
eq "  and not one write reached the client" "" "$(writes)"

# ---- --dry-run ----------------------------------------------------------

fresh dry
run --dry-run
eq "--dry-run exits 0" "0" "$RC"
eq "  sending only reads" "" "$(writes)"
BODY=$(printf '%s\n' "$OUT" | awk 'f{print; exit} /^WOULD POST \/rest\/api\/3\/workflowscheme\/project\/switch$/{f=1}')
eq "  the switch body names the project and target scheme" '10004 10100' \
    "$(printf '%s' "$BODY" | jq -r '"\(.projectId) \(.targetSchemeId)"')"
m() { printf '%s' "$BODY" | jq -c --arg t "$1" '[.mappingsByIssueTypeOverride[] | select(.issueTypeId == $t) | .statusMappings[]] | sort_by(.oldStatusId)'; }
eq "  Task maps To Do -> Triage and Done -> Completed" \
    '[{"oldStatusId":"10009","newStatusId":"10011"},{"oldStatusId":"10010","newStatusId":"10014"}]' "$(m 10010)"
eq "  Bug maps the same as Task" "$(m 10010)" "$(m 10012)"
eq "  Epic maps To Do -> Open, Done -> Completed, Awaiting Deployment -> In Progress, Deferred -> Open" \
    '[{"oldStatusId":"10009","newStatusId":"1"},{"oldStatusId":"10010","newStatusId":"10014"},{"oldStatusId":"10012","newStatusId":"3"},{"oldStatusId":"10013","newStatusId":"1"}]' "$(m 10000)"
eq "  Sub-task maps the same as Epic" "$(m 10000)" "$(m 10011)"
contains "  the pre-drain transition is printed, not sent" "WOULD POST /rest/api/3/issue/LAB-14/transitions" "$OUT"
contains "  the old scheme delete is planned" "WOULD DELETE /rest/api/3/workflowscheme/10005" "$OUT"
contains "  the old workflow delete is planned" "WOULD DELETE /rest/api/3/workflow/c01c212e" "$OUT"

# ---- --yes: pre-drain, switch, verify, delete ----------------------------

fresh yes
run --yes
eq "--yes completes with exit 0" "0" "$RC"
W=$(writes)
eq "pre-drain moves every To Do issue with verify set (10 of 12)" "10" \
    "$(printf '%s\n' "$W" | grep -c '^POST /issue/.*/transitions')"
not_contains "  and leaves LAB-321, whose verify is empty" "POST /issue/LAB-321/" "$W"
not_contains "  and leaves LAB-322, whose verify is empty" "POST /issue/LAB-322/" "$W"
contains "  moving each through its transition into Open (51)" \
    'POST /issue/LAB-14/transitions {"transition":{"id":"51"}}' "$W"
contains "  and reports each move" "pre-drain: moved LAB-14 To Do -> Open" "$OUT"
ORDER=$(printf '%s\n' "$W" | awk '{print $1, $2}' | grep -v '^POST /issue/' | tr '\n' '|')
eq "switch, delete the old workflow objects, then category, issue type and screen schemes, then screens" \
    "POST /workflowscheme/project/switch|DELETE /workflowscheme/10005|DELETE /workflow/c01c212e-e092-4d2b-92aa-ca757e11a56f|PUT /project/LAB|PUT /issuetypescheme/project|DELETE /issuetypescheme/10149|PUT /issuetypescreenscheme/project|DELETE /issuetypescreenscheme/10004|DELETE /screenscheme/10014|DELETE /screenscheme/10015|DELETE /screenscheme/10016|DELETE /screens/10014|DELETE /screens/10015|DELETE /screens/10016|" "$ORDER"
contains "  the category PUT names the Managed category by number" 'PUT /project/LAB {"categoryId":10000}' "$W"
contains "  the issue type scheme PUT names the tier scheme and project" \
    'PUT /issuetypescheme/project {"issueTypeSchemeId":"10200","projectId":"10004"}' "$W"
contains "  the issue type screen scheme PUT likewise" \
    'PUT /issuetypescreenscheme/project {"issueTypeScreenSchemeId":"10201","projectId":"10004"}' "$W"
not_contains "  no other project's screens are touched" "DELETE /screens/10037" "$W"
contains "the async task is polled to COMPLETE" "switch task 10500: COMPLETE" "$OUT"
contains "verify confirms the scheme and an empty To Do/Done" "no issue is in To Do, Done" "$OUT"
eq "the sent switch body is the one the dry run printed" "$BODY" "$(jq -c . "$WO_TEST_STATE/switch-body.json")"

: > "$LOG"
run --yes
eq "a second run exits 0" "0" "$RC"
contains "  and reports 0 changes" "0 changes" "$OUT"
eq "  sending nothing" "" "$(writes)"

fresh ontarget
touch "$WO_TEST_STATE/switched" "$WO_TEST_STATE/scheme-deleted" "$WO_TEST_STATE/wf-deleted" \
    "$WO_TEST_STATE/deleted.its.10149" "$WO_TEST_STATE/deleted.itss.10004" \
    "$WO_TEST_STATE/deleted.ss.10014" "$WO_TEST_STATE/deleted.ss.10015" "$WO_TEST_STATE/deleted.ss.10016" \
    "$WO_TEST_STATE/deleted.screen.10014" "$WO_TEST_STATE/deleted.screen.10015" "$WO_TEST_STATE/deleted.screen.10016"
echo 10000 > "$WO_TEST_STATE/category.LAB"
echo '{"target":"10200","pid":"10004","key":"LAB"}' > "$WO_TEST_STATE/on.its"
echo '{"target":"10201","pid":"10004","key":"LAB"}' > "$WO_TEST_STATE/on.itss"
run
eq "a project already on the scheme exits 0 even without --yes" "0" "$RC"
contains "  and prints 0 changes" "0 changes" "$OUT"
not_contains "  without planning a switch" "project/switch" "$OUT"

# ---- refusals and failures ------------------------------------------------

fresh inuse
SW_GROUP_DROP=Cancelled SW_INUSE=10015 run --yes
eq "an in-use status the target lacks and no rule covers fails" "1" "$RC"
contains "  naming the status and issue type" "'Cancelled' (Epic)" "$OUT"
eq "  before any write" "" "$(writes)"

fresh unused
SW_GROUP_DROP=Cancelled run --dry-run
BODY=$(printf '%s\n' "$OUT" | awk 'f{print; exit} /^WOULD POST \/rest\/api\/3\/workflowscheme\/project\/switch$/{f=1}')
contains "an unused status the target lacks, with no rule, maps to Triage" '{"oldStatusId":"10015","newStatusId":"10011"}' "$(m 10000)"

fresh nescheme
SW_SCHEME=missing run --yes
eq "a missing target scheme fails" "1" "$RC"
contains "  naming it" "'Universal Managed Workflow Scheme' does not exist" "$OUT"
eq "  after reading only the scheme list" "GET /workflowscheme?startAt=0&maxResults=50" "$(cat "$LOG")"

fresh taskfail
SW_TASK=failed run --yes
eq "an async switch task that ends FAILED is a failure" "1" "$RC"
contains "  and says so" "ended FAILED" "$OUT"
not_contains "  and nothing is deleted" "DELETE" "$(writes)"

fresh busy
SW_BUSY=1 run --yes
eq "a 409 from a running site task is retried, not fatal" "0" "$RC"
contains "  and says so" "another Jira task is running" "$OUT"

fresh locked
SW_LOCKED=1 run --yes
eq "a workflow-lock 500 on a delete is retried, not fatal" "0" "$RC"
contains "  and says so" "holds the lock; retrying DELETE" "$OUT"

fresh empty303
SW_TASK=empty run --yes
eq "a 303 with no task body falls back to polling the project's scheme" "0" "$RC"
contains "  and says so" "waiting for the project's scheme to change" "$OUT"
not_contains "  never polls a task" "GET /task/" "$(cat "$LOG")"

fresh wfinuse
SW_EXTRA_SCHEME=10099 run --yes
eq "an old workflow another scheme still uses is not deleted, and the run fails" "1" "$RC"
contains "  the unused old scheme is still deleted" "DELETE /workflowscheme/10005" "$(writes)"
not_contains "  but no DELETE reaches the workflow" "DELETE /workflow/" "$(writes)"
contains "  and the message names what still uses it" "schemes: 10099" "$OUT"

OUT=$("$SWITCH" LAB --http "$STUB" --scheme "LAB: Software Simplified Workflow Scheme" --dry-run 2>&1); RC=$?
eq "the project's own old scheme is refused as a target" "1" "$RC"

# ---- issue type and screen layers -----------------------------------------------

fresh dry-layout
run --dry-run
eq "--dry-run plans the layer moves while the old workflow scheme is still in place" "0" "$RC"
contains "  the issue type scheme PUT" 'WOULD PUT /rest/api/3/issuetypescheme/project' "$OUT"
contains "  the old issue type scheme delete, counting the planned move" "WOULD DELETE /rest/api/3/issuetypescheme/10149" "$OUT"
contains "  the old issue type screen scheme delete" "WOULD DELETE /rest/api/3/issuetypescreenscheme/10004" "$OUT"
contains "  the three screen scheme deletes" "WOULD DELETE /rest/api/3/screenscheme/10016" "$OUT"
contains "  and the three screen deletes" "WOULD DELETE /rest/api/3/screens/10016" "$OUT"
eq "  sending only reads" "" "$(writes)"

fresh nolayout
SW_LAYOUT=missing run --yes
eq "a tier issue type scheme that does not exist fails the run" "1" "$RC"
contains "  pointing at universal-apply.sh" "'Universal Managed Issue Type Scheme' does not exist — create it first (universal-apply.sh)" "$OUT"
not_contains "  and the old issue type scheme is kept" "DELETE /issuetypescheme/" "$(writes)"

fresh nolayout-dry
SW_LAYOUT=missing run --dry-run
eq "--dry-run before universal-apply.sh has run still plans the moves" "0" "$RC"
contains "  naming the scheme still to be made" "onto 'Universal Managed Issue Type Scheme', not on this site yet" "$OUT"
contains "  and the delete that follows it" "WOULD DELETE /rest/api/3/issuetypescheme/10149" "$OUT"

fresh ebs
OUT=$(SW_WFS=current "$SWITCH" EBS --tier simplified --http "$STUB" --dry-run 2>&1); RC=$?
eq "--tier simplified on EBS, already on its workflow scheme, dry-runs clean" "0" "$RC"
contains "  verifying the six simplified retired statuses" \
    "no issue is in To Do, Triage, Deferred, Awaiting Deployment, Completed, Cancelled" "$OUT"
contains "  leaving its category alone" "already in category 'Universal Simplified'" "$OUT"
contains "  moving it onto the Simplified issue type scheme" '{"issueTypeSchemeId":"10202","projectId":"10013"}' "$OUT"
contains "  and the Simplified issue type screen scheme" '{"issueTypeScreenSchemeId":"10203","projectId":"10013"}' "$OUT"
eq "  planning its 2 PUTs and 8 DELETEs" "2 8" \
    "$(printf '%s\n' "$OUT" | grep -c '^WOULD PUT') $(printf '%s\n' "$OUT" | grep -c '^WOULD DELETE')"
not_contains "  and no LAB object" "/10149" "$OUT"

OUT=$("$SWITCH" LAB --tier bogus --http "$STUB" --dry-run 2>&1); RC=$?
eq "an unknown tier is refused" "1" "$RC"

echo
echo "$N tests, $FAIL failed"
[ "$FAIL" -eq 0 ]
