#!/bin/bash
#
# universal-apply-selftest.sh — offline tests for universal-apply.sh.
#
# Nothing here reaches a network, a Jira site or a credential: every run
# passes --http pointing at a stub of jira-http.sh's shape, and the stub
# answers 501 to any request it has no case for. Responses come from
# fixtures/universal/, recorded live and read-only. Writes the site was never
# sent are modelled on the behaviour recorded in
# fixtures/workflows.bulkget.rules-after.txt — Jira stores the transitions as
# sent, adds a uuid to each new rule and bumps the version — and every such
# line is marked SYNTHETIC.
#
# Usage: plugins/work-order-jira/universal-apply-selftest.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
FX="$HERE/fixtures/universal"
APPLY="$HERE/universal-apply.sh"
SPEC="$HERE/universal-workflows.json"

[ -x "$APPLY" ] || { echo "$APPLY is missing or not executable" >&2; exit 2; }
[ -f "$SPEC" ]  || { echo "$SPEC is missing" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq is required to run this selftest" >&2; exit 2; }

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
        *"$2"*) bad "$1"; printf '       unwanted substring: %s\n' "$2" ;;
        *) ok "$1" ;;
    esac
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

STUB="$WORK/jira-http-stub.sh"
cat > "$STUB" <<'STUBEOF'
#!/bin/bash
# A jira-http.sh-shaped stub, stateful per test through $WO_TEST_STATE.
# Knobs: WO_TEST_VALIDATION=error, WO_TEST_RENAME=ignored, WO_TEST_ITYPES=dupes.
set -uo pipefail
FX="$WO_TEST_FX"
ST="$WO_TEST_STATE"
printf '%s\n' "$*" >> "$WO_TEST_LOG"
M="${1:-}"; P="${2:-}"; B="${3:-}"

fx() { sed -e '/^#/d' "$FX/$1"; }
absent() { fx workflows.bulkget.absent.txt >&2; exit 1; }

by_name() {
    local n="$1" f src id
    for f in "$ST"/wf.*.json; do
        [ -f "$f" ] || continue
        if [ "$(jq -r '.workflows[0].name' "$f")" = "$n" ]; then cat "$f"; return 0; fi
    done
    case "$n" in
        "Universal Managed Workflow") src=workflows.bulkget.task.txt ;;
        "Universal Managed Epic Workflow") src=workflows.bulkget.epic.txt ;;
        *) absent ;;
    esac
    id=$(fx "$src" | jq -r '.workflows[0].id')
    [ -f "$ST/wf.$id.json" ] && absent
    fx "$src"
}

by_id() {
    local id="$1"
    if [ -f "$ST/wf.$id.json" ]; then cat "$ST/wf.$id.json"; return 0; fi
    fx workflows.bulkget.task.txt | jq -e --arg id "$id" 'select(.workflows[0].id == $id)' \
        || fx workflows.bulkget.epic.txt | jq -e --arg id "$id" 'select(.workflows[0].id == $id)'
}

case "$M:$P" in
    GET:/statuses/search*) fx statuses.search.txt ;;
    GET:/field) fx field.list.txt ;;
    GET:/issuetype)
        if [ "${WO_TEST_ITYPES:-}" = "dupes" ]; then
            # SYNTHETIC: a second company-managed Sub-task, an Epic-named
            # standard type and a team-managed Epic, none of them on this site.
            fx issuetype.list.txt | jq -c '. + [
                {id: "10050", name: "Sub-task", hierarchyLevel: -1, subtask: true},
                {id: "10051", name: "Epic", hierarchyLevel: 0, subtask: false},
                {id: "10052", name: "Epic", hierarchyLevel: 1, subtask: false, scope: {type: "PROJECT", project: {id: "10099"}}}]'
        else
            fx issuetype.list.txt
        fi ;;
    POST:/workflows/update/validation)
        if [ "${WO_TEST_VALIDATION:-}" = "error" ]; then
            fx workflows.update.validation.error.txt
        else
            fx workflows.update.validation.ok.txt
        fi ;;
    POST:/workflows/update)
        # SYNTHETIC write, modelled on the recorded rules-after behaviour.
        printf '%s' "$B" | jq -c '.workflows[]' | while IFS= read -r w; do
            id=$(printf '%s' "$w" | jq -r '.id')
            base=$(by_id "$id") || { printf 'HTTP 404\n{}\n' >&2; exit 1; }
            jq -cn --argjson base "$base" --argjson w "$w" --argjson top "$B" --arg ren "${WO_TEST_RENAME:-honoured}" '
                $base | .statuses = $top.statuses
                | .workflows[0] |= (. + {statuses: $w.statuses,
                    transitions: ($w.transitions | map(.validators |= map(if .id then . else .id = "stub-rule-uuid" end))),
                    version: {versionNumber: (.version.versionNumber + 1), id: "stub-version"}}
                  | if ($w.name != null and $ren != "ignored") then .name = $w.name else . end)
                ' > "$ST/wf.$id.json"
        done
        echo '{}' ;;
    POST:/workflows)
        by_name "$(printf '%s' "$B" | jq -r '.workflowNames[0]')" ;;
    GET:/workflowscheme*)
        if [ -f "$ST/scheme.json" ]; then
            fx workflowscheme.list.txt | jq -c --slurpfile s "$ST/scheme.json" '.values += $s | .total += 1'
        else
            fx workflowscheme.list.txt
        fi ;;
    POST:/workflowscheme)
        # SYNTHETIC: the create response, carrying what was sent plus an id.
        printf '%s' "$B" | jq -c '. + {id: 10100}' > "$ST/scheme.json"
        cat "$ST/scheme.json" ;;
    PUT:/workflowscheme/10100/issuetype/*)
        # SYNTHETIC
        [ -f "$ST/scheme.json" ] || { printf 'HTTP 404\n{}\n' >&2; exit 1; }
        jq -c --argjson b "$B" '.issueTypeMappings[$b.issueType] = $b.workflow' "$ST/scheme.json" > "$ST/scheme.new"
        mv "$ST/scheme.new" "$ST/scheme.json"
        cat "$ST/scheme.json" ;;
    *) printf 'HTTP 501\n{"stub":"no case for %s %s"}\n' "$M" "$P" >&2; exit 1 ;;
esac
STUBEOF
chmod +x "$STUB"

LOG=""
STATE=""
# fresh NAME — a new call log and an empty stub state for the next test.
fresh() {
    LOG="$WORK/$1.log"
    STATE="$WORK/$1.state"
    : > "$LOG"
    mkdir -p "$STATE"
}
run() {
    WO_TEST_FX="$FX" WO_TEST_LOG="$LOG" WO_TEST_STATE="$STATE" "$APPLY" --http "$STUB" "$@" 2>&1
}
# body_of NAME OUTPUT — the /workflows/update body printed for workflow NAME.
body_of() {
    printf '%s\n' "$2" | awk -v n="('$1'):" '
        index($0, "POST /rest/api/3/workflows/update") && index($0, n) {p=1; next}
        p && /^(validation passed|Exact request body)/ {p=0}
        p && NF' | jq -c .
}
writes() { grep -cE '^(POST /workflows/update |POST /workflowscheme|PUT )' "$LOG"; }
fxbody() { sed -e '/^#/d' "$FX/$1"; }

TASK_ID=$(fxbody workflows.bulkget.task.txt | jq -r '.workflows[0].id')
EPIC_ID=$(fxbody workflows.bulkget.epic.txt | jq -r '.workflows[0].id')

# ---- 1. dry-run against the recorded site ---------------------------------

fresh dry
OUT=$(run --dry-run); RC=$?
eq "dry-run against the recorded workflows exits 0" "0" "$RC"
contains "  plans 16 changes on the task workflow" "16 changes" "$OUT"
contains "  names the rename" "\"Universal Managed Epic Workflow\" -> \"Universal Managed Grouping Workflow\"" "$OUT"
contains "  plans the scheme create" "create: default \"Universal Managed Workflow\"" "$OUT"
contains "  totals 20 changes" "20 changes planned." "$OUT"
eq "  called validation once per changed workflow" "2" "$(grep -c '^POST /workflows/update/validation' "$LOG")"
eq "  and wrote nothing" "0" "$(writes)"
not_contains "  and never adds a previous-status validator" "previous-status" "$OUT"

TB=$(body_of "Universal Managed Workflow" "$OUT")
EB=$(body_of "Universal Managed Epic Workflow" "$OUT")
eq "  the task body targets the task workflow at its stored version" "$TASK_ID 1" \
    "$(printf '%s' "$TB" | jq -r '.workflows[0] | "\(.id) \(.version.versionNumber)"')"
eq "new transitions: Triage, Open and Deferred -> Cancelled, DIRECTED, fresh ids, outcome-gated" \
    '[{"id":"16","type":"DIRECTED","from":"10011","to":"10015","f":["customfield_10079"]},{"id":"17","type":"DIRECTED","from":"1","to":"10015","f":["customfield_10079"]},{"id":"18","type":"DIRECTED","from":"10013","to":"10015","f":["customfield_10079"]}]' \
    "$(printf '%s' "$TB" | jq -c '[.workflows[0].transitions[] | select(.id | tonumber > 15)
        | {id, type, from: .links[0].fromStatusReference, to: .toStatusReference, f: [.validators[].parameters.fieldsRequired]}]')"
eq "  start work gains verify then touches" '["customfield_10044","customfield_10043"]' \
    "$(printf '%s' "$TB" | jq -c '[.workflows[0].transitions[] | select(.id == "3") | .validators[].parameters.fieldsRequired]')"
eq "  complete (no verify) gains verify and outcome" '["customfield_10044","customfield_10079"]' \
    "$(printf '%s' "$TB" | jq -c '[.workflows[0].transitions[] | select(.id == "10") | .validators[].parameters.fieldsRequired]')"
eq "  every re-open, re-work, ready for verification and Create stays ungated" "0" \
    "$(printf '%s' "$TB" | jq '[.workflows[0].transitions[] | select(.id == "1" or .id == "4" or .id == "9" or .id == "12" or .id == "13" or .id == "15") | .validators[]] | length')"
eq "  untouched transitions are carried byte for byte" \
    "$(fxbody workflows.bulkget.task.txt | jq -c '[.workflows[0].transitions[] | select(.id == "15" or .id == "4")]')" \
    "$(printf '%s' "$TB" | jq -c '[.workflows[0].transitions[] | select(.id == "15" or .id == "4")]')"
eq "  every stored status is declared with id and statusReference" \
    "$(fxbody workflows.bulkget.task.txt | jq -c '.statuses')" "$(printf '%s' "$TB" | jq -c '.statuses')"

eq "rename: the epic body carries the new name on the old workflow's id" \
    "$EPIC_ID Universal Managed Grouping Workflow" "$(printf '%s' "$EB" | jq -r '.workflows[0] | "\(.id) \(.name)"')"
eq "  adds Cancel from Triage and Open with no validator" '[["10011","10015",0],["1","10015",0]]' \
    "$(printf '%s' "$EB" | jq -c '[.workflows[0].transitions[] | select(.id == "9" or .id == "10") | [.links[0].fromStatusReference, .toStatusReference, (.validators | length)]]')"
eq "  and the grouping workflow carries zero validators in all" "0" \
    "$(printf '%s' "$EB" | jq '[.workflows[0].transitions[].validators[]] | length')"

SCHEME=$(printf '%s\n' "$OUT" | sed -n '/^Exact request body for POST \/rest\/api\/3\/workflowscheme:/,/^}/p' | sed 1d | jq -c .)
eq "scheme create body: default task workflow, Epic and Sub-task on the grouping workflow" \
    '{"name":"Universal Managed Workflow Scheme","defaultWorkflow":"Universal Managed Workflow","issueTypeMappings":{"10000":"Universal Managed Grouping Workflow","10011":"Universal Managed Grouping Workflow"}}' \
    "$(printf '%s' "$SCHEME" | jq -c 'del(.description)')"

# ---- 2. refusals -------------------------------------------------------------

fresh noyes
OUT=$(run); RC=$?
eq "without --yes it refuses with exit 3" "3" "$RC"
eq "  and writes nothing" "0" "$(writes)"

fresh valerr
OUT=$(WO_TEST_VALIDATION=error run --yes); RC=$?
eq "a validation ERROR refuses the write, even with --yes" "1" "$RC"
contains "  quoting Jira's error" "TRANSITION_REFERENCES_AN_UNKNOWN_STATUS_REFERENCE" "$OUT"
contains "  and saying why it stopped" "refusing to write" "$OUT"
eq "  and writes nothing" "0" "$(writes)"

fresh project
OUT=$(run SPK4 --dry-run); RC=$?
eq "a project argument is refused: the workflows are global" "1" "$RC"
eq "  before any request" "0" "$(wc -l < "$LOG" | tr -d ' ')"

# ---- 3. apply, then converge -----------------------------------------------

fresh apply
OUT=$(run --yes); RC=$?
eq "--yes applies both workflows and the scheme" "0" "$RC"
contains "  proves the rules were stored" "rule diff is empty" "$OUT"
contains "  and reads back clean" "read-back confirms: 0 changes outstanding." "$OUT"
eq "  with two workflow updates and one scheme create" "2 1" \
    "$(grep -c '^POST /workflows/update {' "$LOG") $(grep -c '^POST /workflowscheme ' "$LOG")"
kept() {
    jq -r --argjson was "$(fxbody "$1")" \
        '"lost=\([$was.workflows[0].transitions[].id] - [.workflows[0].transitions[].id] | length) total=\(.workflows[0].transitions | length)"' "$2"
}
eq "  losing no stored transition, adding 3 to tasks and 2 to grouping" "lost=0 total=18 lost=0 total=10" \
    "$(kept workflows.bulkget.task.txt "$STATE/wf.$TASK_ID.json") $(kept workflows.bulkget.epic.txt "$STATE/wf.$EPIC_ID.json")"

: > "$LOG"
OUT=$(run --yes); RC=$?
eq "a second run is idempotent" "0" "$RC"
contains "  and says 0 changes" "0 changes" "$OUT"
eq "  writing nothing and validating nothing" "0 0" \
    "$(writes) $(grep -c 'validation' "$LOG")"

# ---- 4. existing validators preserved -----------------------------------------

fresh preserve
# SYNTHETIC: start work already carries verify as Jira stores it (uuid id, from
# the rules-after recording) plus a rule the spec does not name.
fxbody workflows.bulkget.task.txt | jq -c '.workflows[0].transitions |= map(if .id == "3" then .validators = [
    {ruleKey: "system:validate-field-value", parameters: {ruleType: "fieldRequired", fieldsRequired: "customfield_10044", ignoreContext: "true", errorMessage: "verify is required before work starts (work-order MUST-7)"}, id: "6bceb88f-467a-460e-b1aa-3d5d5a21b916"},
    {ruleKey: "system:validate-field-value", parameters: {ruleType: "fieldRequired", fieldsRequired: "customfield_10046", ignoreContext: "true", errorMessage: "site-local rule"}, id: "e56f4066-2557-4336-8db3-9f5de87b415e"}]
    else . end)' > "$STATE/wf.$TASK_ID.json"
OUT=$(run --dry-run); RC=$?
eq "with some validators already stored, dry-run exits 0" "0" "$RC"
contains "  appending only the missing touches rule to start work" "start work (3)  Open -> In Progress: requires touches" "$OUT"
contains "  reporting the site-local rule as left alone" "not in spec (left alone): validator system:validate-field-value" "$OUT"
contains "  planning one change fewer" "15 changes" "$OUT"
TB=$(body_of "Universal Managed Workflow" "$OUT")
eq "  existing rules kept verbatim, in order, with their ids, touches appended" \
    '["6bceb88f-467a-460e-b1aa-3d5d5a21b916","e56f4066-2557-4336-8db3-9f5de87b415e",null]|["customfield_10044","customfield_10046","customfield_10043"]' \
    "$(printf '%s' "$TB" | jq -r '[.workflows[0].transitions[] | select(.id == "3") | .validators] | .[0] | "\(map(.id) | tojson)|\(map(.parameters.fieldsRequired) | tojson)"')"

# ---- 5. rename paths -------------------------------------------------------------

fresh renamed
# SYNTHETIC: the epic workflow after a rename that already happened.
fxbody workflows.bulkget.epic.txt | jq -c '.workflows[0].name = "Universal Managed Grouping Workflow"' > "$STATE/wf.$EPIC_ID.json"
OUT=$(run --dry-run); RC=$?
eq "an already-renamed grouping workflow is found under its new name" "0" "$RC"
not_contains "  and no rename is planned" "rename:" "$OUT"
not_contains "  and the old name is never asked for" "Universal Managed Epic Workflow" "$(cat "$LOG")"

fresh rename-ignored
OUT=$(WO_TEST_RENAME=ignored run --yes); RC=$?
eq "if Jira ignores the rename, the run exits 2" "2" "$RC"
contains "  naming the manual step" "Rename it by hand" "$OUT"
eq "  and stops before creating a scheme that names a missing workflow" "0" "$(grep -c '^POST /workflowscheme ' "$LOG")"

fresh nowf
# SYNTHETIC: both epic names absent — the old one was renamed to something else.
fxbody workflows.bulkget.epic.txt | jq -c '.workflows[0].name = "Somebody Else Workflow"' > "$STATE/wf.$EPIC_ID.json"
OUT=$(run --dry-run); RC=$?
eq "a workflow missing under both names fails" "1" "$RC"
contains "  saying this script does not create workflows" "does not create them" "$OUT"

# ---- 6. scheme paths ---------------------------------------------------------------

fresh dupes
OUT=$(WO_TEST_ITYPES=dupes run --dry-run); RC=$?
SCHEME=$(printf '%s\n' "$OUT" | sed -n '/^Exact request body for POST \/rest\/api\/3\/workflowscheme:/,/^}/p' | sed 1d | jq -c .)
eq "same-named issue types: every company-managed one at the right level is mapped" \
    '["10000","10011","10050"]' "$(printf '%s' "$SCHEME" | jq -c '.issueTypeMappings | keys')"

fresh scheme-drift
fxbody workflows.bulkget.epic.txt | jq -c '.workflows[0].name = "Universal Managed Grouping Workflow"' > "$STATE/wf.$EPIC_ID.json"
# SYNTHETIC: the scheme exists with Epic mapped, Sub-task missing, and a Bug
# mapping the spec does not name.
printf '%s' '{"id":10100,"name":"Universal Managed Workflow Scheme","defaultWorkflow":"Universal Managed Workflow","issueTypeMappings":{"10000":"Universal Managed Grouping Workflow","10012":"jira"}}' > "$STATE/scheme.json"
OUT=$(run --yes); RC=$?
eq "an existing scheme gains only its missing mapping" "0" "$RC"
contains "  planned by name and id" "add mapping:      Sub-task (10011)" "$OUT"
contains "  leaving the extra mapping alone" "not in spec (left alone): mapping Bug (10012)" "$OUT"
eq "  through one PUT and no create" "1 0" \
    "$(grep -c '^PUT /workflowscheme/10100/issuetype/10011 ' "$LOG") $(grep -c '^POST /workflowscheme ' "$LOG")"
eq "  the Bug mapping survives" "jira" "$(jq -r '.issueTypeMappings["10012"]' "$STATE/scheme.json")"

echo
if [ "$FAIL" -eq 0 ]; then
    echo "all $N checks passed"
    exit 0
fi
echo "$FAIL of $N checks failed"
exit 1
