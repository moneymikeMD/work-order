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
        "Universal Simpllfied Workflow") src=workflows.bulkget.simplified.txt ;;
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
        || fx workflows.bulkget.epic.txt | jq -e --arg id "$id" 'select(.workflows[0].id == $id)' \
        || fx workflows.bulkget.simplified.txt | jq -e --arg id "$id" 'select(.workflows[0].id == $id)'
}

# Screens and schemes this test created live in $ST as JSON arrays.
st() { if [ -f "$ST/$1" ]; then cat "$ST/$1"; else echo '[]'; fi; }
add() { st "$1" | jq -c --argjson o "$2" '. + [$o]' > "$ST/$1.new" && mv "$ST/$1.new" "$ST/$1"; }
paged() { fx "$1" | jq -c --argjson s "$(st "$2")" '.values += $s | .total += ($s | length)'; }
nextid() {
    local n
    n=$(cat "$ST/seq" 2>/dev/null || echo 20000)
    n=$((n + 1))
    echo "$n" > "$ST/seq"
    echo "$n"
}
map_itss() {
    printf '%s' "$B" | jq -c --arg id "$1" '.issueTypeMappings[] | {issueTypeScreenSchemeId: $id, issueTypeId, screenSchemeId}' \
        | while IFS= read -r m; do add itssm.json "$m"; done
}
map_its() {
    printf '%s' "$B" | jq -c --arg id "$1" '.issueTypeIds[] | {issueTypeSchemeId: $id, issueTypeId: .}' \
        | while IFS= read -r m; do add itsm.json "$m"; done
}

case "$M:$P" in
    GET:/statuses/search*) fx statuses.search.txt ;;
    GET:/field) fx field.list.txt ;;
    GET:/resolution) fx resolution.list.txt ;;
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
    GET:/screens/*/tabs/*/fields)
        s=${P#/screens/}; sid=${s%%/*}; t=${s#*/tabs/}; tid=${t%%/*}
        if [ -f "$ST/fields.$sid.$tid.json" ]; then cat "$ST/fields.$sid.$tid.json"
        elif [ -f "$FX/screens.$sid.tab.$tid.fields.txt" ]; then fx "screens.$sid.tab.$tid.fields.txt"
        else echo '[]'; fi ;;
    GET:/screens/*/tabs)
        s=${P#/screens/}; sid=${s%%/*}
        if [ -f "$ST/tabs.$sid.json" ]; then cat "$ST/tabs.$sid.json"
        elif [ -f "$FX/screens.$sid.tabs.txt" ]; then fx "screens.$sid.tabs.txt"
        else echo '[]'; fi ;;
    GET:/screens\?*) paged screens.list.txt screens.json ;;
    POST:/screens)
        # SYNTHETIC: Jira gives a new screen one "Field Tab" unless WO_TEST_NOTAB=1.
        id=$(nextid)
        o=$(printf '%s' "$B" | jq -c --argjson id "$id" '{id: $id, name, description}')
        add screens.json "$o"
        [ "${WO_TEST_NOTAB:-}" = "1" ] || printf '[{"id":%s,"name":"Field Tab"}]' "$(nextid)" > "$ST/tabs.$id.json"
        echo "$o" ;;
    POST:/screens/*/tabs)
        # SYNTHETIC
        s=${P#/screens/}; sid=${s%%/*}
        o=$(printf '%s' "$B" | jq -c --argjson id "$(nextid)" '{id: $id, name}')
        add "tabs.$sid.json" "$o"
        echo "$o" ;;
    POST:/screens/*/tabs/*/fields)
        # SYNTHETIC: the added field, named from the recorded field list.
        s=${P#/screens/}; sid=${s%%/*}; t=${s#*/tabs/}; tid=${t%%/*}
        o=$(fx field.list.txt | jq -c --arg f "$(printf '%s' "$B" | jq -r '.fieldId')" '[.[] | select(.id == $f) | {id, name}][0]')
        [ "$o" != "null" ] || { printf 'HTTP 400\n{"errorMessages":["no such field"]}\n' >&2; exit 1; }
        add "fields.$sid.$tid.json" "$o"
        echo "$o" ;;
    GET:/screenscheme\?*) paged screenscheme.list.txt ss.json ;;
    POST:/screenscheme)
        # SYNTHETIC
        id=$(nextid)
        add ss.json "$(printf '%s' "$B" | jq -c --argjson id "$id" '. + {id: $id}')"
        printf '{"id":%s}\n' "$id" ;;
    GET:/issuetypescreenscheme/mapping\?*) paged issuetypescreenscheme.mapping.txt itssm.json ;;
    GET:/issuetypescreenscheme\?*) paged issuetypescreenscheme.list.txt itss.json ;;
    POST:/issuetypescreenscheme)
        # SYNTHETIC
        id=$(nextid)
        add itss.json "$(printf '%s' "$B" | jq -c --arg id "$id" '{id: $id, name, description}')"
        map_itss "$id"
        printf '{"issueTypeScreenSchemeId":"%s"}\n' "$id" ;;
    PUT:/issuetypescreenscheme/*/mapping)
        # SYNTHETIC: 204, no body.
        s=${P#/issuetypescreenscheme/}; map_itss "${s%%/*}" ;;
    GET:/issuetypescheme/mapping\?*) paged issuetypescheme.mapping.txt itsm.json ;;
    GET:/issuetypescheme\?*) paged issuetypescheme.list.txt its.json ;;
    POST:/issuetypescheme)
        # SYNTHETIC
        id=$(nextid)
        add its.json "$(printf '%s' "$B" | jq -c --arg id "$id" '{id: $id, name, description, defaultIssueTypeId}')"
        map_its "$id"
        printf '{"issueTypeSchemeId":"%s"}\n' "$id" ;;
    PUT:/issuetypescheme/*/issuetype)
        # SYNTHETIC: 204, no body.
        s=${P#/issuetypescheme/}; map_its "${s%%/*}" ;;
    GET:/projectCategory) fx projectcategory.list.txt | jq -c --argjson s "$(st cats.json)" '. + $s' ;;
    POST:/projectCategory)
        # SYNTHETIC
        o=$(printf '%s' "$B" | jq -c --arg id "$(nextid)" '. + {id: $id}')
        add cats.json "$o"
        echo "$o" ;;
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
writes() { grep -cE '^(POST /workflows/update |POST /workflowscheme|PUT |POST /(screens|screenscheme|issuetypescreenscheme|issuetypescheme|projectCategory))' "$LOG"; }
fxbody() { sed -e '/^#/d' "$FX/$1"; }

TASK_ID=$(fxbody workflows.bulkget.task.txt | jq -r '.workflows[0].id')
EPIC_ID=$(fxbody workflows.bulkget.epic.txt | jq -r '.workflows[0].id')

# ---- 1. dry-run against the recorded site ---------------------------------

fresh dry
OUT=$(run --dry-run); RC=$?
eq "dry-run against the recorded workflows exits 0" "0" "$RC"
contains "  plans 24 changes on the task workflow, 7 of them resolution actions" "24 changes" "$OUT"
contains "  names the rename" "\"Universal Managed Epic Workflow\" -> \"Universal Managed Grouping Workflow\"" "$OUT"
contains "  plans the scheme create" "create: default \"Universal Managed Workflow\"" "$OUT"
contains "  totals 45 changes: 14 resolution actions, 10 screens and schemes" "45 changes planned." "$OUT"
contains "  the ticket screen gets the standard and all eight contract fields" "create: 25 fields: Summary (summary)" "$OUT"
contains "  the grouping screen gets the standard fields only" "create: 17 fields: Summary (summary)" "$OUT"
contains "  Epic and Sub-task map to the grouping screen scheme" \
    'create: default -> "Universal Managed Ticket Screen Scheme", Epic (10000) -> "Universal Managed Grouping Screen Scheme", Sub-task (10011) -> "Universal Managed Grouping Screen Scheme"' "$OUT"
contains "  both issue type schemes offer five types, default Task" \
    "create: Task (10010), Story (10005), Bug (10012), Epic (10000), Sub-task (10011); default Task (10010)" "$OUT"
contains "  the existing categories need nothing" "$(printf 'project category "Universal Managed":\n  0 changes')" "$OUT"
contains "  the declared simplified workflow scheme is only reported" "absent: this script declares it and never creates it" "$OUT"
contains "  a screen scheme names its screen by the id Jira will assign" \
    'POST /rest/api/3/screenscheme {"name":"Universal Managed Ticket Screen Scheme","description":"Owned by moneymikeMD/work-order.","screens":{"default":"<id of screen \"Universal Managed Ticket Screen\">"}}' "$OUT"
eq "  called validation once per changed workflow" "3" "$(grep -c '^POST /workflows/update/validation' "$LOG")"
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
eq "  every transition into Open requires verify, re-open included" '["customfield_10044"]' \
    "$(printf '%s' "$TB" | jq -c '[.workflows[0].transitions[] | select(.toStatusReference == "1") | .validators[].parameters.fieldsRequired] | unique')"
eq "  all five of them" "5" \
    "$(printf '%s' "$TB" | jq '[.workflows[0].transitions[] | select(.toStatusReference == "1" and (.validators | length) == 1)] | length')"
contains "complete (no verify) is not in the spec, so it is reported" "not in spec (left alone): transition 10 \"complete (no verify)\"  In Progress -> Completed" "$OUT"
eq "  and left exactly as stored, never gated or removed" \
    "$(fxbody workflows.bulkget.task.txt | jq -c '.workflows[0].transitions[] | select(.id == "10")')" \
    "$(printf '%s' "$TB" | jq -c '.workflows[0].transitions[] | select(.id == "10")')"
eq "  re-work, ready for verification and Create stay ungated" "0" \
    "$(printf '%s' "$TB" | jq '[.workflows[0].transitions[] | select(.id == "1" or .id == "4" or .id == "15") | .validators[]] | length')"
eq "  untouched transitions are carried byte for byte" \
    "$(fxbody workflows.bulkget.task.txt | jq -c '[.workflows[0].transitions[] | select(.id == "1" or .id == "4")]')" \
    "$(printf '%s' "$TB" | jq -c '[.workflows[0].transitions[] | select(.id == "1" or .id == "4")]')"
eq "  every stored status is declared with id and statusReference" \
    "$(fxbody workflows.bulkget.task.txt | jq -c '.statuses')" "$(printf '%s' "$TB" | jq -c '.statuses')"

eq "rename: the epic body carries the new name on the old workflow's id" \
    "$EPIC_ID Universal Managed Grouping Workflow" "$(printf '%s' "$EB" | jq -r '.workflows[0] | "\(.id) \(.name)"')"
eq "  adds Cancel from Triage and Open with no validator" '[["10011","10015",0],["1","10015",0]]' \
    "$(printf '%s' "$EB" | jq -c '[.workflows[0].transitions[] | select(.id == "9" or .id == "10") | [.links[0].fromStatusReference, .toStatusReference, (.validators | length)]]')"
eq "  and the grouping workflow carries zero validators in all" "0" \
    "$(printf '%s' "$EB" | jq '[.workflows[0].transitions[].validators[]] | length')"

# res BODY — each transition carrying an action, as "id=<resolution value>", "" for a clear.
res() { printf '%s' "$1" | jq -r '[.workflows[0].transitions[] | select((.actions // []) | length > 0)
    | "\(.id)=\([.actions[] | select(.ruleKey == "system:update-field" and .parameters.field == "resolution" and .parameters.mode == "") | .parameters.value] | join("+"))"]
    | sort_by(split("=")[0] | tonumber) | join(" ")'; }
eq "resolution: complete sets Done, every cancel Won't Do, re-open and re-work clear it" \
    "5=10000 6=10001 9= 11=10001 12= 13= 15= 16=10001 17=10001 18=10001" "$(res "$TB")"
eq "  grouping: Complete sets Done, Cancel Won't Do, Continue Progress clears" \
    "4=10000 5=10001 6= 7= 9=10001 10=10001" "$(res "$EB")"
SB=$(body_of "Universal Simpllfied Workflow" "$OUT")
eq "  simplified: Done sets Done, both transitions out of Done clear" "3=10000 4= 5=" "$(res "$SB")"
contains "  and the plan says so in words" "complete (5)  Awaiting Deployment -> Completed: sets resolution Done" "$OUT"

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
eq "  with three workflow updates and one scheme create" "3 1" \
    "$(grep -c '^POST /workflows/update {' "$LOG") $(grep -c '^POST /workflowscheme ' "$LOG")"
kept() {
    jq -r --argjson was "$(fxbody "$1")" \
        '"lost=\([$was.workflows[0].transitions[].id] - [.workflows[0].transitions[].id] | length) total=\(.workflows[0].transitions | length)"' "$2"
}
eq "  losing no stored transition, adding 3 to tasks and 2 to grouping" "lost=0 total=18 lost=0 total=10" \
    "$(kept workflows.bulkget.task.txt "$STATE/wf.$TASK_ID.json") $(kept workflows.bulkget.epic.txt "$STATE/wf.$EPIC_ID.json")"
eq "  creating three screens, three screen schemes and four issue type (screen) schemes" "3 3 2 2" \
    "$(grep -c '^POST /screens ' "$LOG") $(grep -c '^POST /screenscheme ' "$LOG") $(grep -c '^POST /issuetypescreenscheme ' "$LOG") $(grep -c '^POST /issuetypescheme ' "$LOG")"
eq "  and no category" "0" "$(grep -c '^POST /projectCategory' "$LOG")"
sid_of() { jq -r --arg n "$1" '.[] | select(.name == $n) | .id' "$STATE/$2"; }
TICKET_SID=$(sid_of "Universal Managed Ticket Screen" screens.json)
GROUP_SID=$(sid_of "Universal Managed Grouping Screen" screens.json)
screen_fields() { jq -c '[.[].id]' "$STATE"/fields."$1".*.json; }
eq "  the ticket screen holds outcome and blocked_by_external" "true true 25" \
    "$(screen_fields "$TICKET_SID" | jq -r '"\(index(["customfield_10079"]) != null) \(index(["customfield_10080"]) != null) \(length)"')"
eq "  the grouping screen holds no contract field" "false 17" \
    "$(screen_fields "$GROUP_SID" | jq -r '"\(index(["customfield_10079"]) != null) \(length)"')"
eq "  the screen scheme points at the screen created before it" "$TICKET_SID" \
    "$(jq -r '.[] | select(.name == "Universal Managed Ticket Screen Scheme") | .screens.default' "$STATE/ss.json")"
MITSS=$(sid_of "Universal Managed Issue Type Screen Scheme" itss.json)
eq "  the issue type screen scheme maps default, Epic and Sub-task to the new screen schemes" \
    "default=$(sid_of "Universal Managed Ticket Screen Scheme" ss.json) 10000=$(sid_of "Universal Managed Grouping Screen Scheme" ss.json) 10011=$(sid_of "Universal Managed Grouping Screen Scheme" ss.json)" \
    "$(jq -r --arg id "$MITSS" '[.[] | select(.issueTypeScreenSchemeId == $id) | "\(.issueTypeId)=\(.screenSchemeId)"] | join(" ")' "$STATE/itssm.json")"
MITS=$(sid_of "Universal Managed Issue Type Scheme" its.json)
eq "  the issue type scheme holds five types with Task the default" "10010 10000,10005,10010,10011,10012" \
    "$(jq -r --arg id "$MITS" '.[] | select(.id == $id) | .defaultIssueTypeId' "$STATE/its.json") $(jq -r --arg id "$MITS" '[.[] | select(.issueTypeSchemeId == $id) | .issueTypeId] | sort | join(",")' "$STATE/itsm.json")"

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
contains "  planning one change fewer" "23 changes" "$OUT"
TB=$(body_of "Universal Managed Workflow" "$OUT")
eq "  existing rules kept verbatim, in order, with their ids, touches appended" \
    '["6bceb88f-467a-460e-b1aa-3d5d5a21b916","e56f4066-2557-4336-8db3-9f5de87b415e",null]|["customfield_10044","customfield_10046","customfield_10043"]' \
    "$(printf '%s' "$TB" | jq -r '[.workflows[0].transitions[] | select(.id == "3") | .validators] | .[0] | "\(map(.id) | tojson)|\(map(.parameters.fieldsRequired) | tojson)"')"

fresh preserve-action
# SYNTHETIC: re-work already clears resolution (uuid id as Jira stores it), and
# complete carries a site-local field update the spec does not name.
fxbody workflows.bulkget.task.txt | jq -c '.workflows[0].transitions |= map(
    if .id == "15" then .actions = [{ruleKey: "system:update-field", parameters: {field: "resolution", value: "", mode: ""}, id: "0b6f0c1e-1111-4a4a-9d9d-000000000015"}]
    elif .id == "5" then .actions = [{ruleKey: "system:update-field", parameters: {field: "assignee", value: "", mode: ""}, id: "0b6f0c1e-1111-4a4a-9d9d-000000000005"}]
    else . end)' > "$STATE/wf.$TASK_ID.json"
OUT=$(run --dry-run); RC=$?
eq "with a resolution action already stored, dry-run exits 0" "0" "$RC"
not_contains "  and re-work gains no second clear" "re-work (15)  Awaiting Deployment -> In Progress: clears resolution" "$OUT"
contains "  the site-local action is reported, not removed" "not in spec (left alone): action system:update-field (system:update-field) on transition 5 \"complete\"" "$OUT"
TB=$(body_of "Universal Managed Workflow" "$OUT")
eq "  complete keeps its stored action first and gains the resolution after it" \
    '["0b6f0c1e-1111-4a4a-9d9d-000000000005",null]|["assignee","resolution"]' \
    "$(printf '%s' "$TB" | jq -r '[.workflows[0].transitions[] | select(.id == "5") | .actions] | .[0] | "\(map(.id) | tojson)|\(map(.parameters.field) | tojson)"')"

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

# ---- 7. screens and schemes: converge, tabs, duplicates --------------------------

fresh layout
run --yes >/dev/null
TICKET_SID=$(sid_of "Universal Managed Ticket Screen" screens.json)
TICKET_FF=$(ls "$STATE"/fields."$TICKET_SID".*.json)
TICKET_TAB=${TICKET_FF##*/fields."$TICKET_SID".}; TICKET_TAB=${TICKET_TAB%.json}
MITSS=$(sid_of "Universal Managed Issue Type Screen Scheme" itss.json)
MITS=$(sid_of "Universal Managed Issue Type Scheme" its.json)
# SYNTHETIC drift: outcome gone from the ticket screen, which also carries an
# unnamed field; Sub-task unmapped; Bug dropped from the issue type scheme.
jq -c 'map(select(.id != "customfield_10079")) + [{id: "environment", name: "Environment"}]' "$TICKET_FF" > "$TICKET_FF.new" && mv "$TICKET_FF.new" "$TICKET_FF"
jq -c --arg id "$MITSS" 'map(select(.issueTypeScreenSchemeId != $id or .issueTypeId != "10011"))' "$STATE/itssm.json" > "$STATE/x" && mv "$STATE/x" "$STATE/itssm.json"
jq -c --arg id "$MITS" 'map(select(.issueTypeSchemeId != $id or .issueTypeId != "10012"))' "$STATE/itsm.json" > "$STATE/x" && mv "$STATE/x" "$STATE/itsm.json"
: > "$LOG"
OUT=$(run --dry-run); RC=$?
eq "a drifted layout plans only what is missing" "0" "$RC"
contains "  the missing contract field" "add field:        outcome (customfield_10079)" "$OUT"
contains "  leaving the extra field alone" "not in spec (left alone): field Environment (environment)" "$OUT"
contains "  the missing mapping" "add mapping:      Sub-task (10011) -> \"Universal Managed Grouping Screen Scheme\"" "$OUT"
contains "  the missing issue type" "add issue type:   Bug (10012)" "$OUT"
contains "  3 changes in all" "3 changes planned." "$OUT"
: > "$LOG"
OUT=$(run --yes); RC=$?
eq "  --yes sends them and reads back clean" "0" "$RC"
eq "  through one field POST on the existing tab and two PUTs" "1 1 1" \
    "$(grep -c "^POST /screens/$TICKET_SID/tabs/$TICKET_TAB/fields {\"fieldId\":\"customfield_10079\"}" "$LOG") $(grep -c "^PUT /issuetypescreenscheme/$MITSS/mapping " "$LOG") $(grep -c "^PUT /issuetypescheme/$MITS/issuetype {\"issueTypeIds\":\[\"10012\"\]}" "$LOG")"
eq "  creating nothing" "0" "$(grep -cE '^POST /(screens|screenscheme|issuetypescreenscheme|issuetypescheme) ' "$LOG")"

fresh notab
OUT=$(WO_TEST_NOTAB=1 run --yes); RC=$?
eq "a new screen Jira gives no tab gets one" "0" "$RC"
eq "  one tab per created screen" "3" "$(grep -cE '^POST /screens/[0-9]+/tabs \{"name":"Field Tab"\}' "$LOG")"

fresh dupscreen
# SYNTHETIC: two screens carry a spec name.
printf '%s' '[{"id":30001,"name":"Universal Simplified Screen","description":""},{"id":30002,"name":"Universal Simplified Screen","description":""}]' > "$STATE/screens.json"
OUT=$(run --dry-run); RC=$?
eq "two screens with one spec name fail" "1" "$RC"
contains "  naming the clash" "2 screens are named \"Universal Simplified Screen\"" "$OUT"
eq "  before any write" "0" "$(writes)"

echo
if [ "$FAIL" -eq 0 ]; then
    echo "all $N checks passed"
    exit 0
fi
echo "$FAIL of $N checks failed"
exit 1
