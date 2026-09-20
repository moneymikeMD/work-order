#!/bin/bash
#
# workflow-apply.sh — provisioning step 3: put the seven lifecycle statuses of
# work-order MUST-25, a GLOBAL transition into each, and the validators in
# workflow-rules.json onto a company-managed Jira project's own copy of the
# "simplified scrum classic" template workflow, which ships only To Do /
# In Progress / Done, none of which this script writes. It also retargets the
# workflow's INITIAL transition — the one Jira runs on create — at the entry
# state, Triage, which the template points at To Do ([JIRA-12]). Idempotent:
# "already complete" exits 0 doing nothing.
#
# Usage:
#   workflow-apply.sh PROJECT_KEY [--http PATH] [--rules PATH]
#                                 [--dry-run] [--yes]
#
#   --http PATH   a jira-http.sh-shaped client. Default: lib/jira-http.sh.
#   --rules PATH  also ensure these transition validators are present,
#                 additively. Default: workflow-rules.json beside this file;
#                 --rules none skips the validators entirely.
#   --dry-run     run every read, print the exact final request body, and
#                 exit 0 without calling /workflows/update.
#   --yes         actually issue /workflows/update. This script's own --yes
#                 is the only gate.
#
# Exit status:
#   0  already complete, --dry-run completed, or the write succeeded and both
#      the rule diff and the read-back prove it.
#   1  a general failure — nothing was changed.
#   2  the write SUCCEEDED but the stored rules differ from what was sent.
#   3  stopped because --yes was not given. A refusal, not a failure.
#
# Every status id and transition id is resolved by NAME at runtime: both are
# assigned per Jira site, so a hardcoded id is wrong on the next site.
#
# POST /workflows/update REPLACES a transition wholesale rather than merging,
# so the existing statuses and transitions are carried forward verbatim from
# the bulk-get. Reshaping one, even reordering its keys, strips its rules.
#
# The bulk-get response must reach this script unredacted. A client that
# blanks `ruleKey`-shaped values destroys every rule on the round trip back.
#
# bash 3.2 compatible.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$DIR/lib/common.sh"

# The seven statuses BINDING.md section 3 binds, in lifecycle order. The
# template's own `To Do` and `Done` are NOT here: they are read-only aliases
# ([JIRA-15]), so this script neither adds nor writes them.
TARGET_STATUS_LIST='Triage
Open
In Progress
Awaiting Deployment
Deferred
Completed
Cancelled'
# Caller-assigned ids for the transitions this script may ADD, matched per name
# to the ids night-watchman's own provisioner uses, so a project either tool has
# touched converges instead of colliding. 21 is the template's own In Progress.
TARGET_TRANSITION_IDS='41
51
21
61
71
81
91'
# The entry state of work-order MUST-46. The initial transition is retargeted
# here, and it must be one of TARGET_STATUS_LIST above.
ENTRY_STATUS_NAME='Triage'

PROJECT_KEY=""
HTTP=""
RULES_PATH=""
DRY_RUN=0
ASSUME_YES=0

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            sed -n '3,33p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        --http)
            [ $# -ge 2 ] || die "--http needs a path"
            HTTP="$2"; shift 2 ;;
        --rules)
            [ $# -ge 2 ] || die "--rules needs a path, or 'none'"
            RULES_PATH="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --yes|-y)  ASSUME_YES=1; shift ;;
        --) shift; break ;;
        -*) die "unknown flag '$1' — run with --help" ;;
        *)
            [ -z "$PROJECT_KEY" ] || die "unexpected extra argument '$1' (project key already given: '$PROJECT_KEY')"
            PROJECT_KEY="$1"; shift ;;
    esac
done

[ -n "$PROJECT_KEY" ] || die "a PROJECT_KEY is required, e.g. ${0##*/} ZZPROBE --dry-run"
require_project_key "$PROJECT_KEY" || die "$WO_JIRA_KEY_ERR"

[ -n "$HTTP" ] || HTTP="$DIR/lib/jira-http.sh"
[ -x "$HTTP" ] || die "--http path is not an executable file: '$HTTP'"

[ -n "$RULES_PATH" ] || RULES_PATH="$DIR/workflow-rules.json"
if [ "$RULES_PATH" = "none" ]; then
    RULES_PATH=""
else
    [ -f "$RULES_PATH" ] || die "--rules file not found: '$RULES_PATH'"
fi

need jq

http_get() { "$HTTP" GET "$1"; }
http_post() { "$HTTP" POST "$1" "$2"; }

RESOLVED_STATUS_IDS=""
RESOLVED_STATUS_CATEGORIES=""

# resolve_status_ids — fill the id and statusCategory lists, in
# TARGET_STATUS_LIST order, dying on every name this site does not have.
resolve_status_ids() {
    local all resolved missing="" name id category ids="" categories=""
    all=$(http_get "/statuses/search?maxResults=100") \
        || die "could not read /statuses/search — cannot resolve target status ids by name"
    # One jq for the whole list, not two per name: a per-name pair of forks is
    # what exhausted the process table on a loaded machine.
    resolved=$(printf '%s' "$all" | jq -r --arg names "$TARGET_STATUS_LIST" '
        ($names | split("\n") | map(select(length > 0))) as $want
        | . as $root
        | $want[] as $n
        | ([$root.values[] | select(.name == $n)][0] // {})
        | "\(.id // "")\t\(.statusCategory // "")"') \
        || die "could not parse /statuses/search while resolving the target status names"
    while IFS="$(printf '\t')" read -r name id category; do
        [ -n "$name" ] || continue
        if [ -z "$id" ] || [ -z "$category" ]; then
            missing="$missing$name, "
        else
            ids="$ids$id
"
            categories="$categories$category
"
        fi
    done <<EOF
$(paste <(printf '%s\n' "$TARGET_STATUS_LIST") <(printf '%s\n' "$resolved"))
EOF
    [ -z "$missing" ] || die "these status names do not exist on this Jira site — create them once, site-wide, then re-run: ${missing%, }"
    RESOLVED_STATUS_IDS="$ids"
    RESOLVED_STATUS_CATEGORIES="$categories"
}

WORKFLOW_NAME=""
WORKFLOW_ENTITY_ID=""
WORKFLOW_JSON=""

read_workflow() {
    local enc total
    WORKFLOW_NAME="Software Simplified Workflow for Project $PROJECT_KEY"
    enc=$(jq -rn --arg v "$WORKFLOW_NAME" '$v|@uri') || die "could not url-encode the workflow name"
    WORKFLOW_JSON=$(http_get "/workflow/search?workflowName=$enc&expand=transitions,statuses") \
        || die "could not read workflow '$WORKFLOW_NAME'"
    total=$(printf '%s' "$WORKFLOW_JSON" | jq -r '.total // 0') \
        || die "could not parse the workflow/search response"
    [ "$total" -ge 1 ] 2>/dev/null \
        || die "no workflow named '$WORKFLOW_NAME' was found — is '$PROJECT_KEY' a project created from the simplified-scrum classic template with its default workflow still in place?"
    WORKFLOW_ENTITY_ID=$(printf '%s' "$WORKFLOW_JSON" | jq -r '.values[0].id.entityId // empty') \
        || die "could not read the workflow's entityId from workflow/search"
    [ -n "$WORKFLOW_ENTITY_ID" ] \
        || die "workflow/search returned no id.entityId for '$WORKFLOW_NAME' — cannot build an update request without it"
}

# entry_status_id — the site's id for ENTRY_STATUS_NAME, taken from the ids
# resolve_status_ids already read by name. Empty output plus 1 if the name is
# not in TARGET_STATUS_LIST, which is a bug in this file, not in the site.
entry_status_id() {
    local n
    n=$(printf '%s\n' "$TARGET_STATUS_LIST" | grep -nxF "$ENTRY_STATUS_NAME" | cut -d: -f1) || return 1
    [ -n "$n" ] || return 1
    list_nth "$RESOLVED_STATUS_IDS" "$n"
}

workflow_status_names()     { printf '%s' "$WORKFLOW_JSON" | jq -r '.values[0].statuses[].name'; }
workflow_transition_names() { printf '%s' "$WORKFLOW_JSON" | jq -r '.values[0].transitions[].name'; }

MISSING_STATUS_NAMES=""
MISSING_TRANSITION_NAMES=""
# Non-empty when the initial transition points somewhere other than the entry
# state; the value is the status id it must be repointed at.
INITIAL_RETARGET_TO=""
INITIAL_TRANSITION_ID=""
INITIAL_TRANSITION_TO=""

# check_transition_id_collisions — die if an id this run would ADD is already
# held under a different name. Only the missing set is checked: a transition
# already present keeps its own id and the target id is never sent for it.
check_transition_id_collisions() {
    local have_pairs want_name want_id existing_name
    have_pairs=$(printf '%s' "$WORKFLOW_JSON" | jq -r '.values[0].transitions[] | "\(.id)\t\(.name)"') \
        || die "could not read the current transition id/name pairs"
    while IFS="$(printf '\t')" read -r want_name want_id; do
        [ -n "$want_name" ] || continue
        in_list "$want_name" "$MISSING_TRANSITION_NAMES" || continue
        existing_name=$(printf '%s\n' "$have_pairs" | awk -F'\t' -v id="$want_id" '$1==id{print $2; exit}')
        if [ -n "$existing_name" ] && [ "$existing_name" != "$want_name" ]; then
            die "transition id $want_id on workflow '$WORKFLOW_NAME' is already held by '$existing_name', not '$want_name' — refusing to reuse an id that would collide with an unrelated transition"
        fi
    done <<EOF
$(paste <(printf '%s\n' "$TARGET_STATUS_LIST") <(printf '%s\n' "$TARGET_TRANSITION_IDS"))
EOF
}

compute_missing() {
    local have_statuses have_transitions name
    have_statuses=$(workflow_status_names) || die "could not read the workflow's current statuses"
    have_transitions=$(workflow_transition_names) || die "could not read the workflow's current transitions"
    MISSING_STATUS_NAMES=""
    MISSING_TRANSITION_NAMES=""
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        in_list "$name" "$have_statuses" || MISSING_STATUS_NAMES="$MISSING_STATUS_NAMES$name
"
        in_list "$name" "$have_transitions" || MISSING_TRANSITION_NAMES="$MISSING_TRANSITION_NAMES$name
"
    done <<EOF
$TARGET_STATUS_LIST
EOF
    check_transition_id_collisions
    compute_initial_retarget
}

# compute_initial_retarget — read the workflow's one initial transition and
# decide whether it already targets the entry state ([JIRA-12]). Both the
# transition id and the status id are per-site, so neither is written down:
# the transition is found by its type and the status by its name.
compute_initial_retarget() {
    local want line
    want=$(entry_status_id) \
        || die "'$ENTRY_STATUS_NAME' is not in this script's target status list — the entry state must be one of the statuses it provisions"
    [ -n "$want" ] || die "could not resolve the entry state '$ENTRY_STATUS_NAME' to a status id on this site"
    line=$(printf '%s' "$WORKFLOW_JSON" | jq -r '
        [.values[0].transitions[] | select(((.type // "") | ascii_downcase) == "initial")] as $i
        | if ($i | length) == 1 then "\($i[0].id)\t\($i[0].to // "")" else "" end') \
        || die "could not read the initial transition from workflow '$WORKFLOW_NAME'"
    [ -n "$line" ] \
        || die "workflow '$WORKFLOW_NAME' does not have exactly one transition of type 'initial' — refusing to guess which one Jira runs on create"
    INITIAL_TRANSITION_ID="${line%%$'\t'*}"
    INITIAL_TRANSITION_TO="${line#*$'\t'}"
    if [ "$INITIAL_TRANSITION_TO" = "$want" ]; then
        INITIAL_RETARGET_TO=""
    else
        INITIAL_RETARGET_TO="$want"
    fi
}

RESOLVED_RULES_JSON="[]"
MISSING_RULES_JSON="[]"

# resolve_rules — replace every {field:...} and {status:...} placeholder in
# the rules spec with the one site id its name matches, dying on any name
# that matches zero or several things.
resolve_rules() {
    local spec fields statuses unresolved
    spec=$(jq -c '.transitions
        | if type != "array" then error("no top-level transitions array") else . end
        | map(if (.name | type) != "string" or (.validators | type) != "array" then error("each transition needs a name and a validators array") else . end)
        | map(.validators |= map(if (.ruleKey | type) != "string" or (.parameters | type) != "object" then error("each validator needs a ruleKey string and a parameters object") else {ruleKey, parameters} end))
        ' "$RULES_PATH") \
        || die "--rules file '$RULES_PATH' is not a valid rules spec (see workflow-rules.json for the shape)"
    fields=$(http_get "/field") || die "could not read /field — cannot resolve rule field names"
    statuses=$(http_get "/statuses/search?maxResults=100") \
        || die "could not read /statuses/search — cannot resolve rule status names"
    RESOLVED_RULES_JSON=$(jq -cn --argjson spec "$spec" --argjson fields "$fields" --argjson statuses "$statuses" '
        def one($kind; $n; $matches):
            if ($matches | length) == 1 then $matches[0].id else "UNRESOLVED:" + $kind + ":" + $n end;
        def resolve:
            if type != "string" then .
            elif test("^\\{field:.+\\}$") then
                capture("^\\{field:(?<n>.+)\\}$").n as $n | one("field"; $n; [$fields[] | select(.name == $n)])
            elif test("^\\{status:.+\\}$") then
                capture("^\\{status:(?<n>.+)\\}$").n as $n | one("status"; $n; [$statuses.values[] | select(.name == $n)])
            else . end;
        def resolve_all:
            if type == "object" then map_values(resolve_all)
            elif type == "array" then map(resolve_all)
            else resolve end;
        $spec | map(.validators |= map(.parameters |= resolve_all))
        ') || die "could not resolve the placeholders in '$RULES_PATH'"
    unresolved=$(printf '%s' "$RESOLVED_RULES_JSON" | jq -r '[.. | strings | select(startswith("UNRESOLVED:"))] | unique | join(", ")') \
        || die "could not scan the resolved rules for unresolved names"
    [ -z "$unresolved" ] || die "'$RULES_PATH' names something this site does not have exactly once: $unresolved"
    # A mistyped placeholder ({Field:x}, { field:x}, trailing text) matches
    # neither pattern above and would otherwise reach Jira literally.
    if printf '%s' "$RESOLVED_RULES_JSON" | grep -Eiq '\{[[:space:]]*(field|status)[[:space:]]*:'; then
        die "'$RULES_PATH' still contains a placeholder-shaped value after resolution (a typo, wrong case, or extra text) — refusing to send it"
    fi
}

check_rule_transitions() {
    local have names name unknown=""
    have=$(workflow_transition_names) || die "could not read the workflow's current transitions"
    names=$(printf '%s' "$RESOLVED_RULES_JSON" | jq -r '.[].name') || die "could not read transition names from the rules spec"
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        in_list "$name" "$have" || in_list "$name" "$TARGET_STATUS_LIST" || unknown="$unknown$name, "
    done <<EOF
$names
EOF
    [ -z "$unknown" ] || die "'$RULES_PATH' names transitions workflow '$WORKFLOW_NAME' does not have and this run does not add: ${unknown%, }"
}

# compute_missing_rules BULKGET_JSON — per transition name, the spec
# validators not already stored, compared by ruleKey + parameters. Never by
# the rule's own uuid, which Jira regenerates on every write.
compute_missing_rules() {
    MISSING_RULES_JSON=$(jq -cn --argjson bulkget "$1" --argjson rules "$RESOLVED_RULES_JSON" --arg wfname "$WORKFLOW_NAME" '
        ($bulkget.workflows[] | select(.name == $wfname)) as $wf
        | [ $rules[] as $r
            | ([$wf.transitions[] | select(.name == $r.name)][0].validators // [] | map({ruleKey, parameters})) as $have
            | {name: $r.name, validators: [$r.validators[] | select(. as $v | any($have[]; . == $v) | not)]}
            | select(.validators | length > 0)
          ]') || die "could not compare the rules spec against the workflow's stored validators"
}

# build_update_body BULKGET_JSON VERSION_JSON — the full /workflows/update
# request: the existing statuses and transitions verbatim plus the additions.
# Never a delta, and never a no-op.
build_update_body() {
    jq -n \
        --argjson bulkget "$1" \
        --argjson version "$2" \
        --arg wfname "$WORKFLOW_NAME" \
        --arg targetNamesNL "$TARGET_STATUS_LIST" \
        --arg statusIdsNL "$RESOLVED_STATUS_IDS" \
        --arg statusCategoriesNL "$RESOLVED_STATUS_CATEGORIES" \
        --arg transitionIdsNL "$TARGET_TRANSITION_IDS" \
        --arg missingStatusNamesNL "$MISSING_STATUS_NAMES" \
        --arg missingTransitionNamesNL "$MISSING_TRANSITION_NAMES" \
        --argjson missingRules "$MISSING_RULES_JSON" \
        --arg initialRetargetTo "$INITIAL_RETARGET_TO" \
        '
        def lines: split("\n") | map(select(length > 0));
        ( $targetNamesNL | lines ) as $allNames
        | ( $statusIdsNL | lines ) as $allIds
        | ( $statusCategoriesNL | lines ) as $allCats
        | ( $transitionIdsNL | lines ) as $allTransIds
        | ( $missingStatusNamesNL | lines ) as $missingStatusNames
        | ( $missingTransitionNamesNL | lines ) as $missingTransitionNames
        | [ range(0; ($allNames | length))
            | { name: $allNames[.], id: $allIds[.], category: $allCats[.], transitionId: $allTransIds[.] }
          ] as $resolved
        | [ $resolved[] | select(.name as $n | $missingStatusNames | index($n) != null)
            | { id: .id, statusReference: .id, name: .name, statusCategory: .category }
          ] as $status_additions
        | [ $resolved[] | select(.name as $n | $missingTransitionNames | index($n) != null)
            | { id: .transitionId, name: .name, type: "GLOBAL", toStatusReference: .id }
          ] as $transition_additions
        | if ($status_additions | length) == 0 and ($transition_additions | length) == 0 and ($missingRules | length) == 0 and ($initialRetargetTo | length) == 0
          then error("build_update_body: computed additions are EMPTY — the caller must check \"already complete\" before calling this")
          else . end
        | ($bulkget.workflows[] | select(.name == $wfname)) as $wf
        | {
            statuses: ($bulkget.statuses + $status_additions),
            workflows: [ {
                id: $wf.id,
                version: $version,
                statuses: ($wf.statuses + ($status_additions | map({statusReference}))),
                transitions: (($wf.transitions + $transition_additions)
                    | map(
                        # Assign into the key that is already there rather than
                        # rebuilding the object: /workflows/update replaces a
                        # transition wholesale, and reshaping one strips its rules.
                        (if ($initialRetargetTo | length) > 0 and (((.type // "") | ascii_downcase) == "initial")
                         then .toStatusReference = $initialRetargetTo else . end)
                        | . as $t
                        | [$missingRules[] | select(.name == $t.name) | .validators[]] as $add
                        | if ($add | length) > 0 then .validators = ((.validators // []) + $add) else . end))
            } ]
        }
        '
}

# A status declaration needs id AND statusReference set to the same global
# status id, or Jira reads it as a create and 400s NON_UNIQUE_STATUS_NAME.

# validate_update_body BODY — POST /workflows/update/validation, which runs
# even under --dry-run. The endpoint needs a {payload, validationOptions}
# envelope, not the bare body.
validate_update_body() {
    local envelope resp error_count warning_count errors_json
    envelope=$(jq -n --argjson payload "$1" \
        '{payload: $payload, validationOptions: {levels: ["ERROR", "WARNING"]}}') \
        || die "could not build the /workflows/update/validation envelope"
    resp=$(http_post /workflows/update/validation "$envelope") \
        || die "POST /workflows/update/validation failed outright"
    printf '%s' "$resp" | jq -e '.errors | type == "array"' >/dev/null 2>&1 \
        || die "POST /workflows/update/validation returned no 'errors' array — refusing to read that as zero errors. Raw response: $resp"
    errors_json=$(printf '%s' "$resp" | jq -c '.errors')
    error_count=$(printf '%s' "$errors_json" | jq '[.[] | select(.level == "ERROR")] | length')
    warning_count=$(printf '%s' "$errors_json" | jq '[.[] | select(.level == "WARNING")] | length')
    if [ "$warning_count" != "0" ]; then
        warn "workflow update validation reported $warning_count warning(s):"
        printf '%s\n' "$errors_json" | jq '[.[] | select(.level == "WARNING")]' >&2
    fi
    if [ "$error_count" != "0" ]; then
        warn "workflow update validation reported $error_count error(s):"
        printf '%s\n' "$errors_json" | jq '[.[] | select(.level == "ERROR")]' >&2
        die "refusing to write — /workflows/update/validation reported at least one ERROR"
    fi
}

assert_readback() {
    read_workflow
    compute_missing
    if [ -z "$MISSING_STATUS_NAMES" ] && [ -z "$MISSING_TRANSITION_NAMES" ] && [ -z "$INITIAL_RETARGET_TO" ]; then
        echo "read-back confirms: every target status and transition is present, and the create transition targets the entry state $ENTRY_STATUS_NAME."
        return 0
    fi
    [ -z "$MISSING_STATUS_NAMES" ] || warn "still missing statuses: $(printf '%s' "$MISSING_STATUS_NAMES" | tr '\n' ',' | sed 's/,$//')"
    [ -z "$MISSING_TRANSITION_NAMES" ] || warn "still missing transitions: $(printf '%s' "$MISSING_TRANSITION_NAMES" | tr '\n' ',' | sed 's/,$//')"
    [ -z "$INITIAL_RETARGET_TO" ] || warn "the create transition ($INITIAL_TRANSITION_ID) still targets status $INITIAL_TRANSITION_TO, not the entry state $ENTRY_STATUS_NAME ($INITIAL_RETARGET_TO)"
    die "the workflow update did not take effect as expected"
}

BULKGET_BODY=""

# assert_rules_stored SENT_BODY — re-read and compare the rules Jira stored
# against the rules that were sent, transition by transition, ignoring the
# uuid rule ids Jira regenerates. The baseline is the request, so rules added
# on purpose compare equal while a rule Jira dropped or altered does not.
assert_rules_stored() {
    local after diff changed
    after=$(http_post /workflows "$BULKGET_BODY") \
        || die "the write returned, but the post-write re-read failed — check the workflow's actual state by hand before trusting anything about it"
    diff=$(jq -n --argjson sent "$1" --argjson after "$after" --arg wfname "$WORKFLOW_NAME" '
        def without_ids: map(del(.id));
        def rules: {
            actions:    ((.actions    // []) | without_ids),
            validators: ((.validators // []) | without_ids),
            triggers:   ((.triggers   // []) | without_ids),
            links:      ((.links      // []) | without_ids)
        };
        ($sent.workflows[0].transitions | map({id, r: rules})) as $sentT
        | ($after.workflows[] | select(.name == $wfname) | .transitions | map({id, r: rules})) as $afterT
        | [ $sentT[] as $s | ($afterT[] | select(.id == $s.id)) as $a
            | select($s.r != $a.r)
            | {id: $s.id, sent: $s.r, stored: $a.r}
          ]') || die "could not compute the per-transition rule diff"
    changed=$(printf '%s' "$diff" | jq -r '.[0].id // empty')
    if [ -n "$changed" ]; then
        printf '%s\n' "$diff" | jq . >&2
        warn "stored rules differ from what the update sent, starting at transition $changed"
        exit 2
    fi
    echo "rule diff is empty: Jira stored exactly the rules that were sent."
}

resolve_status_ids
read_workflow
compute_missing
if [ -n "$RULES_PATH" ]; then
    resolve_rules
    check_rule_transitions
fi

if [ -z "$RULES_PATH" ] && [ -z "$MISSING_STATUS_NAMES" ] && [ -z "$MISSING_TRANSITION_NAMES" ] && [ -z "$INITIAL_RETARGET_TO" ]; then
    echo "already complete: workflow '$WORKFLOW_NAME' carries every target status and transition, and the create transition already targets the entry state $ENTRY_STATUS_NAME (matched by name and id only)."
    exit 0
fi

BULKGET_BODY=$(jq -n --arg n "$WORKFLOW_NAME" '{workflowNames: [$n]}') \
    || die "could not build the /workflows bulk-get request body"
BULKGET=$(http_post /workflows "$BULKGET_BODY") \
    || die "could not obtain the workflow's current version via POST /workflows"
VERSION_JSON=$(printf '%s' "$BULKGET" | jq -c --arg n "$WORKFLOW_NAME" '[.workflows[] | select(.name == $n)][0].version // null') \
    || die "could not parse the POST /workflows response"
[ "$VERSION_JSON" != "null" ] \
    || die "POST /workflows returned no 'version' for '$WORKFLOW_NAME' — refusing to write with nothing to guard against a stale-write conflict"

# Cross-check two independent reads of "the same workflow" against a name
# collision or a stale cache on either side.
BULKGET_WF_ID=$(printf '%s' "$BULKGET" | jq -r --arg n "$WORKFLOW_NAME" '[.workflows[] | select(.name == $n)][0].id // empty') \
    || die "could not read the workflow id from the POST /workflows response"
[ "$BULKGET_WF_ID" = "$WORKFLOW_ENTITY_ID" ] \
    || die "workflow/search's entityId ('$WORKFLOW_ENTITY_ID') does not match POST /workflows's id ('$BULKGET_WF_ID') — refusing to update a possibly-wrong workflow"

if [ -n "$RULES_PATH" ]; then
    compute_missing_rules "$BULKGET"
    if [ -z "$MISSING_STATUS_NAMES" ] && [ -z "$MISSING_TRANSITION_NAMES" ] && [ -z "$INITIAL_RETARGET_TO" ] && [ "$MISSING_RULES_JSON" = "[]" ]; then
        echo "already complete: workflow '$WORKFLOW_NAME' carries every target status, transition and validator, and the create transition targets the entry state $ENTRY_STATUS_NAME: 0 changes."
        exit 0
    fi
fi

echo "workflow '$WORKFLOW_NAME' is missing:"
[ -z "$MISSING_STATUS_NAMES" ]     || echo "  statuses:    $(printf '%s' "$MISSING_STATUS_NAMES" | tr '\n' ',' | sed 's/,$//')"
[ -z "$MISSING_TRANSITION_NAMES" ] || echo "  transitions: $(printf '%s' "$MISSING_TRANSITION_NAMES" | tr '\n' ',' | sed 's/,$//')"
[ -z "$INITIAL_RETARGET_TO" ]      || echo "  create transition: id $INITIAL_TRANSITION_ID (type initial) targets status $INITIAL_TRANSITION_TO, not the entry state $ENTRY_STATUS_NAME (status $INITIAL_RETARGET_TO) — would retarget it ([JIRA-12])"
if [ "$MISSING_RULES_JSON" != "[]" ]; then
    printf '%s' "$MISSING_RULES_JSON" | jq -r '.[] | "  validators:  \(.name): \([.validators[].ruleKey] | join(", "))"' \
        || die "could not summarise the missing validators"
fi

FINAL_BODY=$(build_update_body "$BULKGET" "$VERSION_JSON") \
    || die "could not render the /workflows/update request body"

validate_update_body "$FINAL_BODY"

echo
echo "validation passed. This is the exact request body for POST /rest/api/3/workflows/update:"
printf '%s\n' "$FINAL_BODY" | jq .

if [ "$DRY_RUN" = "1" ]; then
    warn "--dry-run: the update itself was never sent (every call above is read-only by semantics)."
    exit 0
fi
if [ "$ASSUME_YES" != "1" ]; then
    warn "not confirmed (no --yes) — the update was never sent."
    exit 3
fi

UPDATE_RESP=$(http_post /workflows/update "$FINAL_BODY") \
    || die "POST /workflows/update failed outright — nothing after this point ran; check the workflow's actual state before retrying"
echo
echo "/workflows/update response:"
printf '%s\n' "$UPDATE_RESP" | jq . 2>/dev/null || printf '%s\n' "$UPDATE_RESP"

assert_rules_stored "$FINAL_BODY"
assert_readback
