#!/bin/bash
#
# universal-apply.sh — converge the site-wide Universal workflows, their
# shared workflow scheme, and the two tiers' shared screens, screen schemes,
# issue type screen schemes and issue type schemes towards
# universal-workflows.json. Everything here is shared by every project of a
# tier, so this script takes no project.
#
# Usage:
#   universal-apply.sh [--http PATH] [--spec PATH] [--dry-run] [--yes]
#
#   --http PATH   a jira-http.sh-shaped client. Default: lib/jira-http.sh.
#   --spec PATH   the spec to converge towards. Default:
#                 universal-workflows.json beside this file.
#   --dry-run     run every read and POST /workflows/update/validation, print
#                 the exact request bodies, and exit 0 without writing.
#   --yes         actually write. This script's own --yes is the only gate.
#
# Convergence is additive. A workflow present only under its spec
# `renamed_from` name is renamed; a missing status, transition (matched by
# from -> to, never by name), validator or action (each matched by ruleKey +
# parameters) is added; a missing scheme mapping is added. A missing project category,
# screen, screen scheme, issue type screen scheme or issue type scheme is
# created; a missing field,
# mapping or issue type is added to an existing one. Nothing is ever changed or
# removed: a differing value is printed as "differs", and whatever Jira holds
# that the spec does not name as "not in spec (left alone)". The declared
# workflow schemes are only reported.
#
# Exit status:
#   0  0 changes, --dry-run completed, or every write succeeded and the
#      read-back proves it.
#   1  a general failure — nothing was changed by the step that failed.
#   2  a write SUCCEEDED but what Jira stored differs from what was sent,
#      including a rename Jira did not apply.
#   3  stopped because --yes was not given. A refusal, not a failure.
#
# bash 3.2 compatible.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$DIR/lib/common.sh"

HTTP=""
SPEC=""
DRY_RUN=0
ASSUME_YES=0

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            sed -n '3,37p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        --http)
            [ $# -ge 2 ] || die "--http needs a path"
            HTTP="$2"; shift 2 ;;
        --spec)
            [ $# -ge 2 ] || die "--spec needs a path"
            SPEC="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --yes|-y)  ASSUME_YES=1; shift ;;
        *) die "unknown argument '$1' — this script takes no project; run with --help" ;;
    esac
done

[ -n "$HTTP" ] || HTTP="$DIR/lib/jira-http.sh"
[ -x "$HTTP" ] || die "--http path is not an executable file: '$HTTP'"
[ -n "$SPEC" ] || SPEC="$DIR/universal-workflows.json"
[ -f "$SPEC" ] || die "--spec file not found: '$SPEC'"

need jq

trap tmpclean EXIT
tmpinit || die "could not create a scratch directory"
ERRF=$(tmpfile) || die "could not create a scratch file"

http_get()  { "$HTTP" GET "$1" 2>"$ERRF"; }
http_post() { "$HTTP" POST "$1" "$2" 2>"$ERRF"; }
http_put()  { "$HTTP" PUT "$1" "$2" 2>"$ERRF"; }
http_err()  { tr '\n' ' ' < "$ERRF"; }
http_404()  { [ "$(head -n 1 "$ERRF")" = "HTTP 404" ]; }

SPEC_JSON=$(jq -c '
    def need(c; msg): if c then . else error(msg) end;
    need((.workflows | type) == "array" and (.workflows | length) > 0; "no workflows array")
    | need((.scheme | type) == "object"; "no scheme object")
    | .workflows[] |= (
        need((.name | type) == "string" and (.statuses | type) == "array" and (.transitions | type) == "array";
             "each workflow needs a name, a statuses array and a transitions array")
        | .transitions[] |= (
            need((.name | type) == "string" and (.to | type) == "string" and ((.from | type) == "string" or .from == null) and (.validators | type) == "array";
                 "each transition needs a name, a to, a from (a status name or null) and a validators array")
            | .actions //= []
            | need((.actions | type) == "array"; "the actions of a transition, when present, must be an array")
            | (.validators[], .actions[]) |= need((.ruleKey | type) == "string" and (.parameters | type) == "object";
                 "each validator and action needs a ruleKey string and a parameters object")))
    | .scheme |= need((.name | type) == "string" and (.defaultWorkflow | type) == "string"
                      and (.issueTypeMappings | type) == "object" and (.issueTypeHierarchyLevels | type) == "object";
                      "the scheme needs name, defaultWorkflow, issueTypeMappings and issueTypeHierarchyLevels")
    ' "$SPEC") || die "'$SPEC' is not a valid spec (see universal-workflows.json for the shape)"

STATUSES=$(http_get "/statuses/search?maxResults=100") \
    || die "could not read /statuses/search: $(http_err)"
FIELDS=$(http_get "/field") || die "could not read /field: $(http_err)"
RESOLUTIONS=$(http_get "/resolution") || die "could not read /resolution: $(http_err)"

# Every status name becomes {name, id, category}, every transition end a status
# id, every {field:NAME} a custom field id and every {resolution:NAME} a
# resolution id. Anything that resolves to zero or several site objects is left
# as UNRESOLVED:... and fatal below.
RESOLVED=$(jq -cn --argjson spec "$SPEC_JSON" --argjson statuses "$STATUSES" --argjson fields "$FIELDS" --argjson res "$RESOLUTIONS" '
    def one($kind; $n; $m): if ($m | length) == 1 then $m[0].id else "UNRESOLVED:" + $kind + ":" + $n end;
    def sid($n): if $n == null then null else one("status"; $n; [$statuses.values[] | select(.name == $n)]) end;
    def ph:
        if type == "string" and test("^\\{field:.+\\}$") then
            capture("^\\{field:(?<n>.+)\\}$").n as $n | one("field"; $n; [$fields[] | select(.name == $n)])
        elif type == "string" and test("^\\{resolution:.+\\}$") then
            capture("^\\{resolution:(?<n>.+)\\}$").n as $n | one("resolution"; $n; [$res[] | select(.name == $n)])
        else . end;
    $spec.workflows | map(
        .statuses |= map(. as $n | {name: $n, id: sid($n),
            category: ([$statuses.values[] | select(.name == $n) | .statusCategory][0] // null)})
        | .transitions |= map(.fromName = .from | .toName = .to | .from = sid(.from) | .to = sid(.to)
            | .validators |= map({ruleKey, parameters: (.parameters | map_values(ph))})
            | .actions |= map({ruleKey, parameters: (.parameters | map_values(ph))})))
    ') || die "could not resolve the names in '$SPEC'"
UNRESOLVED=$(printf '%s' "$RESOLVED" | jq -r '[.. | strings | select(startswith("UNRESOLVED:"))] | unique | join(", ")') \
    || die "could not scan the resolved spec"
[ -z "$UNRESOLVED" ] || die "'$SPEC' names something this site does not have exactly once: $UNRESOLVED"
if printf '%s' "$RESOLVED" | grep -Eiq '\{[[:space:]]*(field|resolution)[[:space:]]*:'; then
    die "'$SPEC' still contains a placeholder-shaped value after resolution (a typo, wrong case, or extra text) — refusing to send it"
fi

WF_COUNT=$(printf '%s' "$RESOLVED" | jq 'length')

# bulkget NAME — POST /workflows for one name. The whole request 404s when any
# listed name is absent, so names are never batched. See http_404.
bulkget() {
    local body
    body=$(jq -cn --arg n "$1" '{workflowNames: [$n]}') || return 1
    http_post /workflows "$body"
}

# locate_workflow SPEC_NAME RENAMED_FROM — set CUR_NAME and BULK to the stored
# workflow, trying the spec name first and then renamed_from.
CUR_NAME=""
BULK=""
locate_workflow() {
    CUR_NAME=""
    BULK=""
    if BULK=$(bulkget "$1"); then
        CUR_NAME="$1"
        return 0
    fi
    http_404 || die "could not read workflow '$1' via POST /workflows: $(http_err)"
    if [ -n "$2" ]; then
        if BULK=$(bulkget "$2"); then
            CUR_NAME="$2"
            return 0
        fi
        http_404 || die "could not read workflow '$2' via POST /workflows: $(http_err)"
        die "neither '$1' nor '$2' (its renamed_from) exists on this site — this script converges existing workflows and does not create them"
    fi
    die "workflow '$1' does not exist on this site — this script converges existing workflows and does not create them"
}

# plan_workflow SPEC_WF_JSON — print the plan for one workflow as JSON:
# rename, statuses/transitions/validators to add, what is not in the spec, and
# errors. Pure function of the spec, the bulk-get in $BULK and $CUR_NAME.
plan_workflow() {
    jq -cn --argjson s "$1" --argjson bulk "$BULK" --arg cur "$CUR_NAME" --argjson fields "$FIELDS" --argjson statuses "$STATUSES" --argjson res "$RESOLUTIONS" '
        def sname($id): if $id == null then "(create)" else ([$statuses.values[] | select(.id == $id) | .name][0] // ("status " + $id)) end;
        def rule_label: if .parameters.fieldsRequired then
                (.parameters.fieldsRequired as $f | "requires " + ([$fields[] | select(.id == $f) | .name][0] // $f))
            elif .ruleKey == "system:update-field" and .parameters.field == "resolution" then
                (.parameters.value as $v | if ($v // "") == "" then "clears resolution"
                 else "sets resolution " + ([$res[] | select(.id == $v) | .name][0] // $v) end)
            else .ruleKey end;
        def core: {ruleKey, parameters};
        def missing($want; $have): [$want[] | select(. as $r | any($have[]; . == $r) | not)];
        def is_initial: ((.type // "") | ascii_downcase) == "initial";
        def froms: [(.links // [])[] | .fromStatusReference | select(. != null)];
        [$bulk.workflows[] | select(.name == $cur)] as $wfs
        | if ($wfs | length) != 1 then {errors: ["POST /workflows returned \($wfs | length) workflows named \"\($cur)\", expected exactly 1"]} else
        $wfs[0] as $wf
        | ($wf.transitions // []) as $have
        | [$s.transitions[] as $t
            | {t: $t, m: [$have[] | select(.toStatusReference == $t.to and
                (if $t.from == null then is_initial else (is_initial | not) and (froms | index($t.from) != null) end))]}
          ] as $pairs
        | ([$have[].id | tonumber? ] | max // 0) as $maxid
        | [$pairs[] | select((.m | length) == 0) | .t] as $missing
        | [$missing | to_entries[] | .key as $k | .value
            | {id: (($maxid + 1 + $k) | tostring), type: "DIRECTED", name, description: "",
               toStatusReference: .to, links: [{fromStatusReference: .from}],
               actions, validators, triggers: [], properties: {},
               _label: "\(.name)  \(.fromName) -> \(.toName)", _rules: ((.validators + .actions) | map(rule_label))}
          ] as $addT
        | [$pairs[] | select((.m | length) == 1)
            | .m[0] as $e | .t as $t
            | missing($t.validators; ($e.validators // []) | map(core)) as $add
            | select(($add | length) > 0)
            | {id: $e.id, validators: $add, _label: "\($e.name) (\($e.id))  \($t.fromName // "(create)") -> \($t.toName)", _rules: ($add | map(rule_label))}
          ] as $addV
        | [$pairs[] | select((.m | length) == 1)
            | .m[0] as $e | .t as $t
            | missing($t.actions; ($e.actions // []) | map(core)) as $add
            | select(($add | length) > 0)
            | {id: $e.id, actions: $add, _label: "\($e.name) (\($e.id))  \($t.fromName // "(create)") -> \($t.toName)", _rules: ($add | map(rule_label))}
          ] as $addA
        | ([$s.statuses[].id]) as $specSids
        | [$s.statuses[] | select(.id as $i | [$wf.statuses[].statusReference] | index($i) | not)
            | {id, statusReference: .id, name, statusCategory: .category}] as $addS
        | [$pairs[] | select((.m | length) == 1) | .m[0].id] as $matchedIds
        | {
            name: $s.name,
            current: $cur,
            id: $wf.id,
            version: $wf.version,
            scope: ($wf.scope.type // null),
            rename: ($cur != $s.name),
            addStatuses: $addS,
            addTransitions: $addT,
            addValidators: $addV,
            addActions: $addA,
            notInSpec: (
                [$wf.statuses[] | select(.statusReference as $r | $specSids | index($r) | not) | "status \(sname(.statusReference))"]
                + [$have[] | select(.id as $i | $matchedIds | index($i) | not)
                    | "transition \(.id) \"\(.name)\"  \(if is_initial then "(create)" elif (froms | length) == 0 then "(any)" else (froms | map(sname(.)) | join(",")) end) -> \(sname(.toStatusReference))"]
                + [$pairs[] | select((.m | length) == 1) | .m[0] as $e | .t as $t
                    | (($e.validators // [])[] | select(core as $v | any($t.validators[]; . == $v) | not)
                        | "validator \(.ruleKey) (\(rule_label)) on transition \($e.id) \"\($e.name)\""),
                      (($e.actions // [])[] | select(core as $v | any($t.actions[]; . == $v) | not)
                        | "action \(.ruleKey) (\(rule_label)) on transition \($e.id) \"\($e.name)\""),
                      (select($e.name != $t.name) | "transition \($e.id) is named \"\($e.name)\" here, \"\($t.name)\" in the spec")]
            ),
            errors: (
                [$pairs[] | select((.m | length) > 1)
                    | "several transitions match \(.t.fromName // "(create)") -> \(.t.toName): ids \(.m | map(.id) | join(", ")) — refusing to guess"]
                + [$missing[] | select(.from == null) | "workflow has no initial transition targeting \(.toName) — this script will not add or retarget an initial transition"]
                + (if ($wf.scope.type // "") != "GLOBAL" then ["workflow scope is \($wf.scope.type // "unknown"), not GLOBAL"] else [] end)
                + (if $wf.version == null then ["POST /workflows returned no version — nothing to guard a stale write with"] else [] end)
            )
          }
          | .changes = ((if .rename then 1 else 0 end) + (.addStatuses | length) + (.addTransitions | length)
                        + ([.addValidators[].validators | length] | add // 0)
                        + ([.addActions[].actions | length] | add // 0))
        end'
}

# build_body PLAN — the full /workflows/update request: the stored statuses and
# transitions verbatim, plus the additions. Transitions are edited in place,
# never rebuilt, because the endpoint replaces each one wholesale.
build_body() {
    jq -cn --argjson p "$1" --argjson bulk "$BULK" --arg cur "$CUR_NAME" '
        ($bulk.workflows[] | select(.name == $cur)) as $wf
        | [$bulk.statuses[].id] as $known
        | {
            statuses: ($bulk.statuses + [$p.addStatuses[] | select(.id as $i | $known | index($i) | not)]),
            workflows: [
                ($wf | {id, version, description, startPointLayout, loopedTransitionContainerLayout}
                     | with_entries(select(.value != null)))
                + (if $p.rename then {name: $p.name} else {} end)
                + {
                    statuses: ($wf.statuses + [$p.addStatuses[] | {statusReference}]),
                    transitions: (
                        ($wf.transitions | map(. as $t
                            | [$p.addValidators[] | select(.id == $t.id) | .validators[]] as $add
                            | [$p.addActions[] | select(.id == $t.id) | .actions[]] as $addA
                            | if ($add | length) > 0 then .validators = ((.validators // []) + $add) else . end
                            | if ($addA | length) > 0 then .actions = ((.actions // []) + $addA) else . end))
                        + [$p.addTransitions[] | del(._label, ._rules)])
                  }
            ]
          }'
}

# A status declaration needs id AND statusReference set to the same global
# status id, or Jira reads it as a create and 400s NON_UNIQUE_STATUS_NAME.

# validate_body BODY — POST /workflows/update/validation, which runs even under
# --dry-run. The endpoint needs a {payload, validationOptions} envelope.
validate_body() {
    local envelope resp errors_json error_count warning_count
    envelope=$(jq -cn --argjson payload "$1" \
        '{payload: $payload, validationOptions: {levels: ["ERROR", "WARNING"]}}') \
        || die "could not build the /workflows/update/validation envelope"
    resp=$(http_post /workflows/update/validation "$envelope") \
        || die "POST /workflows/update/validation failed outright: $(http_err)"
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

print_plan() {
    printf '%s' "$1" | jq -r '
        "workflow \"\(.name)\" (id \(.id), version \(.version.versionNumber // "?")):",
        (if .rename then "  rename:           \"\(.current)\" -> \"\(.name)\"" else empty end),
        (.addStatuses[] | "  add status:       \(.name)"),
        (.addTransitions[] | "  add transition:   \(._label)  [id \(.id)]\(if (._rules | length) > 0 then "  " + (._rules | join(", ")) else "" end)"),
        (.addValidators[] | "  add validator:    \(._label): \(._rules | join(", "))"),
        (.addActions[] | "  add action:       \(._label): \(._rules | join(", "))"),
        (.notInSpec[] | "  not in spec (left alone): \(.)"),
        "  \(.changes) change\(if .changes == 1 then "" else "s" end)"'
}

TOTAL=0
PLANS=()
CURS=()
BODIES=()

i=0
while [ "$i" -lt "$WF_COUNT" ]; do
    SWF=$(printf '%s' "$RESOLVED" | jq -c --argjson i "$i" '.[$i]')
    SNAME=$(printf '%s' "$SWF" | jq -r '.name')
    SFROM=$(printf '%s' "$SWF" | jq -r '.renamed_from // empty')
    locate_workflow "$SNAME" "$SFROM"
    PLAN=$(plan_workflow "$SWF") || die "could not compare '$SPEC' against workflow '$CUR_NAME'"
    ERRS=$(printf '%s' "$PLAN" | jq -r '.errors[]') || die "could not read the plan for '$CUR_NAME'"
    [ -z "$ERRS" ] || die "workflow '$CUR_NAME': $(printf '%s' "$ERRS" | tr '\n' ';' | sed 's/;$//; s/;/; /g')"
    print_plan "$PLAN"
    N=$(printf '%s' "$PLAN" | jq '.changes')
    TOTAL=$((TOTAL + N))
    BODY=""
    if [ "$N" -gt 0 ]; then
        BODY=$(build_body "$PLAN") || die "could not render the /workflows/update body for '$CUR_NAME'"
    fi
    PLANS[i]="$PLAN"
    CURS[i]="$CUR_NAME"
    BODIES[i]="$BODY"
    i=$((i + 1))
done

# ---- the scheme ------------------------------------------------------------

SCHEME_NAME=$(printf '%s' "$SPEC_JSON" | jq -r '.scheme.name')

# list_schemes — every workflow scheme on the site as one JSON array, paging
# GET /workflowscheme until isLast.
list_schemes() {
    local start=0 page all='[]' n last
    while :; do
        page=$(http_get "/workflowscheme?startAt=$start&maxResults=50") || return 1
        all=$(jq -cn --argjson a "$all" --argjson p "$page" '$a + ($p.values // [])') || return 1
        n=$(printf '%s' "$page" | jq '(.values // []) | length') || return 1
        last=$(printf '%s' "$page" | jq -r '.isLast // true') || return 1
        if [ "$last" = "true" ] || [ "$n" = "0" ]; then break; fi
        start=$((start + n))
    done
    printf '%s' "$all"
}

ISSUETYPES=$(http_get /issuetype) || die "could not read /issuetype: $(http_err)"

# Each mapped issue-type name resolves to every company-managed type of that
# name at the spec's hierarchy level; a team-managed type (scope PROJECT) is
# never mappable in a company-managed scheme.
DESIRED=$(jq -cn --argjson spec "$SPEC_JSON" --argjson types "$ISSUETYPES" '
    $spec.scheme as $s
    | [$s.issueTypeMappings | to_entries[] | .key as $n | .value as $wf
        | ($s.issueTypeHierarchyLevels[$n]) as $lvl
        | [$types[] | select(.name == $n and .hierarchyLevel == $lvl and ((.scope.type // "GLOBAL") != "PROJECT"))] as $m
        | if ($m | length) == 0 then {unresolved: "\($n) (hierarchyLevel \($lvl // "unset"))"}
          else ($m[] | {id, name, workflow: $wf}) end]') \
    || die "could not resolve the scheme's issue types"
UNRES_TYPES=$(printf '%s' "$DESIRED" | jq -r '[.[] | .unresolved // empty] | join(", ")')
[ -z "$UNRES_TYPES" ] || die "no company-managed issue type matches: $UNRES_TYPES"

SCHEMES=$(list_schemes) || die "could not list workflow schemes: $(http_err)"

# scheme_plan SCHEMES — the scheme half of the plan: create, or which mappings
# to add, plus drift and not-in-spec lines.
scheme_plan() {
    jq -cn --argjson all "$1" --argjson spec "$SPEC_JSON" --argjson desired "$DESIRED" --argjson types "$ISSUETYPES" '
        $spec.scheme as $s
        | def tname($id): ([$types[] | select(.id == $id) | .name][0] // "issue type") + " (" + $id + ")";
        [$all[] | select(.name == $s.name)] as $found
        | if ($found | length) > 1 then {errors: ["\($found | length) workflow schemes are named \"\($s.name)\""]}
          elif ($found | length) == 0 then {
            errors: [], exists: false, changes: 1,
            create: {name: $s.name, description: ($s.description // ""), defaultWorkflow: $s.defaultWorkflow,
                     issueTypeMappings: ($desired | map({key: .id, value: .workflow}) | from_entries)}}
          else $found[0] as $e | ($e.issueTypeMappings // {}) as $have
            | [$desired[] | select($have[.id] == null)] as $add
            | {
                errors: [], exists: true, id: $e.id, changes: ($add | length), add: $add,
                drift: (
                    (if $e.defaultWorkflow != $s.defaultWorkflow
                     then ["default workflow is \"\($e.defaultWorkflow)\", spec says \"\($s.defaultWorkflow)\" (left alone)"] else [] end)
                    + [$desired[] | select($have[.id] != null and $have[.id] != .workflow)
                        | "\(.name) (\(.id)) maps to \"\($have[.id])\", spec says \"\(.workflow)\" (left alone)"]),
                notInSpec: [$have | to_entries[] | select(.key as $k | [$desired[].id] | index($k) | not)
                    | "mapping \(tname(.key)) -> \"\(.value)\""]
              }
          end'
}

SPLAN=$(scheme_plan "$SCHEMES") || die "could not compare the spec's scheme against the site's"
SERRS=$(printf '%s' "$SPLAN" | jq -r '.errors[]')
[ -z "$SERRS" ] || die "scheme: $SERRS"
printf '%s' "$SPLAN" | jq -r --arg n "$SCHEME_NAME" '
    "workflow scheme \"\($n)\":",
    (if .exists | not then "  create: default \"\(.create.defaultWorkflow)\", " + (.create.issueTypeMappings | to_entries | map("\(.key) -> \"\(.value)\"") | join(", "))
     else (.add[] | "  add mapping:      \(.name) (\(.id)) -> \"\(.workflow)\""),
          (.drift[] | "  differs: \(.)"),
          (.notInSpec[] | "  not in spec (left alone): \(.)") end),
    "  \(.changes) change\(if .changes == 1 then "" else "s" end)"'
SN=$(printf '%s' "$SPLAN" | jq '.changes')
TOTAL=$((TOTAL + SN))

# ---- screens, screen schemes, issue type schemes ---------------------------

# list_all PATH MAX — every .values entry of a startAt-paged GET as one array.
list_all() {
    local start=0 page all='[]' n last sep='?'
    case "$1" in *\?*) sep='&' ;; esac
    while :; do
        page=$(http_get "$1${sep}startAt=$start&maxResults=$2") || return 1
        all=$(jq -cn --argjson a "$all" --argjson p "$page" '$a + ($p.values // [])') || return 1
        n=$(printf '%s' "$page" | jq '(.values // []) | length') || return 1
        last=$(printf '%s' "$page" | jq -r '.isLast // true') || return 1
        if [ "$last" = "true" ] || [ "$n" = "0" ]; then break; fi
        start=$((start + n))
    done
    printf '%s' "$all"
}

HAS_LAYOUT=$(printf '%s' "$SPEC_JSON" | jq -r 'if ((.screens // []) + (.project_categories // [])) | length > 0 then 1 else 0 end')

# read_layout — the site's screens (with each spec-named screen's tab fields),
# screen schemes, issue type screen schemes and issue type schemes, with their
# mappings, as one JSON object in $LAYOUT.
LAYOUT='{}'
read_layout() {
    local scr ss itss itssm its itsm cats state='{}' name sid tabs tid fields
    scr=$(list_all /screens 100) || die "could not list screens: $(http_err)"
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        sid=$(printf '%s' "$scr" | jq -r --arg n "$name" '[.[] | select(.name == $n)] | if length == 1 then .[0].id | tostring else empty end')
        [ -n "$sid" ] || continue
        tabs=$(http_get "/screens/$sid/tabs") || die "could not read GET /screens/$sid/tabs: $(http_err)"
        state=$(jq -cn --argjson s "$state" --arg n "$name" --arg id "$sid" '$s + {($n): {id: $id, tabs: []}}')
        for tid in $(printf '%s' "$tabs" | jq -r '.[].id'); do
            fields=$(http_get "/screens/$sid/tabs/$tid/fields") || die "could not read GET /screens/$sid/tabs/$tid/fields: $(http_err)"
            state=$(jq -cn --argjson s "$state" --arg n "$name" --arg t "$tid" --argjson f "$fields" \
                '$s | .[$n].tabs += [{id: $t, fields: [$f[].id]}]')
        done
    done <<EOF
$(printf '%s' "$SPEC_JSON" | jq -r '.screens[].name')
EOF
    ss=$(list_all /screenscheme 50) || die "could not list screen schemes: $(http_err)"
    itss=$(list_all /issuetypescreenscheme 50) || die "could not list issue type screen schemes: $(http_err)"
    itssm=$(list_all /issuetypescreenscheme/mapping 100) || die "could not list issue type screen scheme mappings: $(http_err)"
    its=$(list_all /issuetypescheme 50) || die "could not list issue type schemes: $(http_err)"
    itsm=$(list_all /issuetypescheme/mapping 100) || die "could not list issue type scheme mappings: $(http_err)"
    cats=$(http_get /projectCategory) || die "could not list project categories: $(http_err)"
    LAYOUT=$(jq -cn --argjson scr "$scr" --argjson state "$state" --argjson ss "$ss" --argjson itss "$itss" \
        --argjson itssm "$itssm" --argjson its "$its" --argjson itsm "$itsm" --argjson cats "$cats" \
        '{screens: $scr, state: $state, ss: $ss, itss: $itss, itssm: $itssm, its: $its, itsm: $itsm, cats: $cats}')
}

# layout_plan — compare the spec's layout sections with $LAYOUT and $SCHEMES.
# Prints {errors, lines, actions, changes}; a reference to an object this run
# creates is left as {"$screen": NAME} or {"$screenscheme": NAME}.
layout_plan() {
    jq -cn --argjson spec "$SPEC_JSON" --argjson l "$LAYOUT" --argjson fields "$FIELDS" \
        --argjson types "$ISSUETYPES" --argjson wfs "$SCHEMES" '
        def uniq: reduce .[] as $x ([]; if index([$x]) then . else . + [$x] end);
        def fid($f): if ($f | test("^\\{field:.+\\}$")) then
                ($f | capture("^\\{field:(?<n>.+)\\}$").n) as $n | [$fields[] | select(.name == $n)]
                | if length == 1 then .[0].id else "UNRESOLVED:field:" + $n end
            elif any($fields[]; .id == $f) then $f else "UNRESOLVED:field:" + $f end;
        def fname($id): ([$fields[] | select(.id == $id) | .name][0] // $id) + " (" + $id + ")";
        def tids($n): [$types[] | select(.name == $n and ((.scope.type // "GLOBAL") != "PROJECT")) | .id | tostring]
            | if length == 0 then ["UNRESOLVED:issuetype:" + $n] else . end;
        def tname($id): if $id == "default" then "default" else ([$types[] | select((.id | tostring) == $id) | .name][0] // "issue type") + " (" + $id + ")" end;
        def named($list; $n): [$list[] | select(.name == $n)];
        def idof($list; $n): (named($list; $n) | if length == 1 then .[0].id | tostring else null end);
        def many($kind; $n; $m): "\($m | length) \($kind) are named \"\($n)\"";

        [($spec.project_categories // [])[] | . as $c | named($l.cats; $c.name) as $m
            | if ($m | length) > 1 then {errors: [many("project categories"; $c.name; $m)]}
              elif ($m | length) == 0 then {kind: "category", name: $c.name, create: true, changes: 1,
                  body: {name: $c.name, description: ($c.description // "")}, lines: ["  create"]}
              else {kind: "category", name: $c.name, id: ($m[0].id | tostring), changes: 0,
                  lines: (if ($m[0].description // "") != ($c.description // "") then ["  differs: description (left alone)"] else [] end)}
              end
            | . + {title: "project category \"\($c.name)\""}] as $cats

        | [($spec.screens // [])[] | . as $s
            | ([$s.field_sets[] as $k | ($spec.field_sets[$k] // error("unknown field set " + $k))[] | fid(.)] | uniq) as $want
            | named($l.screens; $s.name) as $m
            | if ($m | length) > 1 then {errors: [many("screens"; $s.name; $m)]}
              elif ($m | length) == 0 then
                {kind: "screen", name: $s.name, create: true, description: ($s.description // ""), fields: $want, changes: 1,
                 lines: ["  create: \($want | length) fields: \($want | map(fname(.)) | join(", "))"]}
              else ($l.state[$s.name] // {id: ($m[0].id | tostring), tabs: []}) as $st
                | ([$st.tabs[].fields[]]) as $have
                | [$want[] | select(. as $f | $have | index([$f]) | not)] as $add
                | {kind: "screen", name: $s.name, id: $st.id, tab: ($st.tabs[0].id // null), add: $add, changes: ($add | length),
                   errors: (if ($st.tabs | length) == 0 and ($add | length) > 0 then ["screen \"\($s.name)\" has no tab to add fields to"] else [] end),
                   lines: ([$add[] | "  add field:        \(fname(.))"]
                           + [$have[] | select(. as $f | $want | index([$f]) | not) | "  not in spec (left alone): field \(fname(.))"])}
              end
            | . + {title: "screen \"\($s.name)\""}] as $screens

        | [($spec.screen_schemes // [])[] | . as $s
            | named($l.ss; $s.name) as $m
            | if ($m | length) > 1 then {errors: [many("screen schemes"; $s.name; $m)]}
              elif ($m | length) == 0 then
                {kind: "screenscheme", name: $s.name, create: true, description: ($s.description // ""), changes: 1,
                 screens: ($s.screens | map_values({"$screen": .})),
                 lines: ["  create: " + ($s.screens | to_entries | map("\(.key) -> \"\(.value)\"") | join(", "))]}
              else {kind: "screenscheme", name: $s.name, id: ($m[0].id | tostring), changes: 0,
                    lines: [$s.screens | to_entries[] | . as $e | ($m[0].screens[$e.key] // null) as $have
                        | idof($l.screens; $e.value) as $w
                        | select($have == null or ($w != null and ($have | tostring) != $w))
                        | "  differs: \($e.key) screen is \($have // "unset"), spec says \"\($e.value)\" (left alone)"]}
              end
            | . + {title: "screen scheme \"\($s.name)\""}] as $sschemes

        | [($spec.issue_type_screen_schemes // [])[] | . as $s
            | [$s.mappings | to_entries[] | .value as $v
                | (if .key == "default" then ["default"] else tids(.key) end)[] | {issueTypeId: ., screenScheme: $v}] as $desired
            | named($l.itss; $s.name) as $m
            | if ($m | length) > 1 then {errors: [many("issue type screen schemes"; $s.name; $m)]}
              elif ($m | length) == 0 then
                {kind: "itss", name: $s.name, create: true, description: ($s.description // ""), changes: 1,
                 mappings: [$desired[] | {issueTypeId, screenSchemeId: {"$screenscheme": .screenScheme}}],
                 lines: ["  create: " + ($desired | map("\(tname(.issueTypeId)) -> \"\(.screenScheme)\"") | join(", "))]}
              else ($m[0].id | tostring) as $id
                | [$l.itssm[] | select((.issueTypeScreenSchemeId | tostring) == $id)] as $have
                | [$desired[] | select(.issueTypeId as $t | any($have[]; .issueTypeId == $t) | not)] as $add
                | {kind: "itss", name: $s.name, id: $id, changes: ($add | length),
                   add: [$add[] | {issueTypeId, screenSchemeId: {"$screenscheme": .screenScheme}}],
                   lines: ([$add[] | "  add mapping:      \(tname(.issueTypeId)) -> \"\(.screenScheme)\""]
                     + [$desired[] | . as $d | idof($l.ss; $d.screenScheme) as $w
                         | $have[] | select(.issueTypeId == $d.issueTypeId and $w != null and (.screenSchemeId | tostring) != $w)
                         | "  differs: \(tname(.issueTypeId)) maps to screen scheme \(.screenSchemeId), spec says \"\($d.screenScheme)\" (left alone)"]
                     + [$have[] | select(.issueTypeId as $t | any($desired[]; .issueTypeId == $t) | not)
                         | "  not in spec (left alone): mapping \(tname(.issueTypeId)) -> screen scheme \(.screenSchemeId)"])}
              end
            | . + {title: "issue type screen scheme \"\($s.name)\""}] as $itss

        | [($spec.issue_type_schemes // [])[] | . as $s
            | ([$s.issueTypes[] | tids(.)[]] | uniq) as $want
            | (tids($s.defaultIssueType) | if length == 1 then .[0] else "UNRESOLVED:default issue type:" + $s.defaultIssueType end) as $def
            | named($l.its; $s.name) as $m
            | if ($m | length) > 1 then {errors: [many("issue type schemes"; $s.name; $m)]}
              elif ($m | length) == 0 then
                {kind: "its", name: $s.name, create: true, changes: 1,
                 body: {name: $s.name, description: ($s.description // ""), defaultIssueTypeId: $def, issueTypeIds: $want},
                 lines: ["  create: " + ($want | map(tname(.)) | join(", ")) + "; default \(tname($def))"]}
              else ($m[0].id | tostring) as $id
                | [$l.itsm[] | select((.issueTypeSchemeId | tostring) == $id) | .issueTypeId | tostring] as $have
                | [$want[] | select(. as $t | $have | index([$t]) | not)] as $add
                | {kind: "its", name: $s.name, id: $id, changes: ($add | length), add: $add,
                   lines: ([$add[] | "  add issue type:   \(tname(.))"]
                     + (if (($m[0].defaultIssueTypeId // "") | tostring) != $def
                        then ["  differs: default issue type is \(tname(($m[0].defaultIssueTypeId // "none") | tostring)), spec says \(tname($def)) (left alone)"] else [] end)
                     + [$have[] | select(. as $t | $want | index([$t]) | not) | "  not in spec (left alone): issue type \(tname(.))"])}
              end
            | . + {title: "issue type scheme \"\($s.name)\""}] as $itschemes

        | [($spec.declared_workflow_schemes // [])[] | . as $d | named($wfs; $d.name) as $m
            | {title: "declared workflow scheme \"\($d.name)\"", changes: 0,
               lines: (if ($m | length) == 0 then ["  absent: this script declares it and never creates it"]
                       elif ($m | length) > 1 then ["  \($m | length) workflow schemes carry this name"]
                       elif $m[0].defaultWorkflow != $d.defaultWorkflow then ["  differs: default workflow is \"\($m[0].defaultWorkflow)\", spec says \"\($d.defaultWorkflow)\" (left alone)"]
                       else ["  present, default \"\($d.defaultWorkflow)\""] end)}] as $declared

        | ($cats + $screens + $sschemes + $itss + $itschemes + $declared) as $all
        | {errors: ([$all[] | (.errors // [])[]] + [$all | .. | strings | select(startswith("UNRESOLVED:"))] | unique),
           lines: [$all[] | .title + ":", (.lines // [])[], "  \(.changes) change\(if .changes == 1 then "" else "s" end)"],
           actions: [$all[] | select(.changes > 0) | del(.lines, .title, .errors)],
           changes: ([$all[].changes] | add // 0)}'
}

LPLAN='{"errors":[],"lines":[],"actions":[],"changes":0}'
if [ "$HAS_LAYOUT" = "1" ]; then
    read_layout
    LPLAN=$(layout_plan) || die "could not compare the spec's screens and schemes against the site's"
    LERRS=$(printf '%s' "$LPLAN" | jq -r '.errors | join("; ")')
    [ -z "$LERRS" ] || die "screens and schemes: $LERRS"
    printf '%s' "$LPLAN" | jq -r '.lines[]'
    LN=$(printf '%s' "$LPLAN" | jq '.changes')
    TOTAL=$((TOTAL + LN))
fi

# IDS maps each kind to {name: id} for the objects this run can reference.
IDS=$(printf '%s' "$LAYOUT" | jq -c '{screen: ((.screens // []) | map({key: .name, value: (.id | tostring)}) | from_entries),
    screenscheme: ((.ss // []) | map({key: .name, value: (.id | tostring)}) | from_entries)}')

# resolve_refs JSON — replace each {"$screen": N} / {"$screenscheme": N} with
# the id IDS holds, or a readable placeholder when the object is not made yet.
resolve_refs() {
    jq -c --argjson ids "$IDS" 'walk(if type == "object" and has("$screen") then ($ids.screen[.["$screen"]] // ("<id of screen \"" + .["$screen"] + "\">"))
        elif type == "object" and has("$screenscheme") then ($ids.screenscheme[.["$screenscheme"]] // ("<id of screen scheme \"" + .["$screenscheme"] + "\">"))
        else . end)' <<EOF
$1
EOF
}

# action_requests ACTION — the writes one layout action sends, one per line as
# "METHOD PATH BODY", with references resolved as far as IDS allows.
action_requests() {
    local a
    a=$(resolve_refs "$1") || return 1
    printf '%s' "$a" | jq -r '
        def num: if type == "string" and test("^[0-9]+$") then tonumber else . end;
        if .kind == "category" then "POST /projectCategory " + (.body | tojson)
        elif .kind == "screen" and .create then
            "POST /screens " + ({name, description} | tojson),
            (.fields[] | "POST /screens/<new id>/tabs/<its first tab>/fields " + ({fieldId: .} | tojson))
        elif .kind == "screen" then (.add[] as $f | "POST /screens/\(.id)/tabs/\(.tab)/fields " + ({fieldId: $f} | tojson))
        elif .kind == "screenscheme" then "POST /screenscheme " + ({name, description, screens: (.screens | map_values(num))} | tojson)
        elif .kind == "itss" and .create then "POST /issuetypescreenscheme " + ({name, description, issueTypeMappings: (.mappings | map(.screenSchemeId |= tostring))} | tojson)
        elif .kind == "itss" then "PUT /issuetypescreenscheme/\(.id)/mapping " + ({issueTypeMappings: (.add | map(.screenSchemeId |= tostring))} | tojson)
        elif .kind == "its" and .create then "POST /issuetypescheme " + (.body | tojson)
        elif .kind == "its" then "PUT /issuetypescheme/\(.id)/issuetype " + ({issueTypeIds: .add} | tojson)
        else error("unknown layout action " + .kind) end'
}

echo
if [ "$TOTAL" -eq 0 ]; then
    echo "0 changes: every workflow, transition, validator, scheme mapping, project category, screen, screen scheme and issue type scheme in '$SPEC' is already in Jira."
    exit 0
fi
echo "$TOTAL changes planned."

i=0
while [ "$i" -lt "$WF_COUNT" ]; do
    if [ -n "${BODIES[i]}" ]; then
        validate_body "${BODIES[i]}"
        echo
        echo "validation passed. Exact request body for POST /rest/api/3/workflows/update ('${CURS[i]}'):"
        printf '%s\n' "${BODIES[i]}" | jq .
    fi
    i=$((i + 1))
done
if [ "$(printf '%s' "$SPLAN" | jq -r '.exists')" = "false" ]; then
    echo
    echo "Exact request body for POST /rest/api/3/workflowscheme:"
    printf '%s' "$SPLAN" | jq '.create'
else
    printf '%s' "$SPLAN" | jq -r '.id as $id | .add[] | "\nPUT /rest/api/3/workflowscheme/\($id)/issuetype/\(.id)\n" + ({issueType: .id, workflow} | tojson)'
fi
LACTIONS=$(printf '%s' "$LPLAN" | jq -c '.actions[]')
if [ -n "$LACTIONS" ]; then
    echo
    echo "Screen and scheme requests, in order (<...> is an id Jira assigns on create):"
    while IFS= read -r a; do
        [ -n "$a" ] || continue
        action_requests "$a" | sed 's#^\([A-Z]*\) #\1 /rest/api/3#' \
            || die "could not render the requests for $(printf '%s' "$a" | jq -r '.kind + " " + .name')"
    done <<EOF
$LACTIONS
EOF
fi

if [ "$DRY_RUN" = "1" ]; then
    warn "--dry-run: nothing was written (every call above is read-only by semantics)."
    exit 0
fi
if [ "$ASSUME_YES" != "1" ]; then
    warn "not confirmed (no --yes) — nothing was written."
    exit 3
fi

STORED_DIFFERS=0

# assert_rules_stored SENT_BODY STORED_BULK NAME — compare each transition's
# rules as sent against what Jira stored, ignoring the rule uuids it assigns.
assert_rules_stored() {
    local diff changed
    diff=$(jq -cn --argjson sent "$1" --argjson after "$2" --arg n "$3" '
        def without_ids: map(del(.id));
        def rules: {actions: ((.actions // []) | without_ids), validators: ((.validators // []) | without_ids),
                    triggers: ((.triggers // []) | without_ids), links: ((.links // []) | without_ids)};
        ($sent.workflows[0].transitions | map({id, r: rules})) as $s
        | ($after.workflows[] | select(.name == $n) | .transitions | map({id, r: rules})) as $a
        | [$s[] as $x | ([$a[] | select(.id == $x.id)][0]) as $y
            | select($y == null or $x.r != $y.r) | {id: $x.id, sent: $x.r, stored: ($y.r // null)}]') \
        || die "could not compute the per-transition rule diff for '$3'"
    changed=$(printf '%s' "$diff" | jq -r '.[0].id // empty')
    if [ -n "$changed" ]; then
        printf '%s\n' "$diff" | jq . >&2
        warn "workflow '$3': stored rules differ from what the update sent, starting at transition $changed"
        STORED_DIFFERS=1
        return 0
    fi
    echo "workflow '$3': rule diff is empty — Jira stored exactly the rules that were sent."
}

i=0
while [ "$i" -lt "$WF_COUNT" ]; do
    if [ -n "${BODIES[i]}" ]; then
        PLAN="${PLANS[i]}"
        WANT=$(printf '%s' "$PLAN" | jq -r '.name')
        OLD="${CURS[i]}"
        RESP=$(http_post /workflows/update "${BODIES[i]}") \
            || die "POST /workflows/update for '$OLD' failed outright: $(http_err) — check the workflow's actual state before retrying"
        echo
        echo "/workflows/update response for '$OLD':"
        printf '%s\n' "$RESP" | jq . 2>/dev/null || printf '%s\n' "$RESP"
        if AFTER=$(bulkget "$WANT"); then
            assert_rules_stored "${BODIES[i]}" "$AFTER" "$WANT"
        elif http_404 && [ "$OLD" != "$WANT" ] && AFTER=$(bulkget "$OLD"); then
            warn "Jira applied the update but NOT the rename: '$OLD' still has its old name. Rename it by hand (Jira settings > Issues > Workflows > '$OLD' > edit name) to '$WANT', then re-run."
            assert_rules_stored "${BODIES[i]}" "$AFTER" "$OLD"
            STORED_DIFFERS=1
        else
            die "the update returned, but the post-write re-read failed: $(http_err) — check the workflow's actual state by hand"
        fi
    fi
    i=$((i + 1))
done

if [ "$STORED_DIFFERS" = "1" ]; then
    warn "stopping before the scheme: a workflow did not store what was sent, and the scheme names workflows by name."
    exit 2
fi

SID=$(printf '%s' "$SPLAN" | jq -r '.id // empty')
if [ "$(printf '%s' "$SPLAN" | jq -r '.exists')" = "false" ]; then
    CREATE=$(printf '%s' "$SPLAN" | jq -c '.create')
    RESP=$(http_post /workflowscheme "$CREATE") \
        || die "POST /workflowscheme failed: $(http_err)"
    echo
    echo "created workflow scheme '$SCHEME_NAME': $(printf '%s' "$RESP" | jq -c '{id, name}' 2>/dev/null || printf '%s' "$RESP")"
else
    ADDS=$(printf '%s' "$SPLAN" | jq -c '.add[]')
    while IFS= read -r a; do
        [ -n "$a" ] || continue
        TID=$(printf '%s' "$a" | jq -r '.id')
        PUTB=$(printf '%s' "$a" | jq -c '{issueType: .id, workflow}')
        http_put "/workflowscheme/$SID/issuetype/$TID" "$PUTB" >/dev/null \
            || die "PUT /workflowscheme/$SID/issuetype/$TID failed: $(http_err) — an active scheme only accepts draft edits: add the mapping in Jira and publish the draft"
        echo "scheme '$SCHEME_NAME': mapped issue type $TID -> $(printf '%s' "$a" | jq -r '.workflow')"
    done <<EOF
$ADDS
EOF
fi

# remember KIND NAME ID — record an id this run created so later references resolve.
remember() {
    IDS=$(jq -cn --argjson ids "$IDS" --arg k "$1" --arg n "$2" --arg id "$3" '$ids | .[$k][$n] = $id') \
        || die "could not record the id of $1 '$2'"
}

# create_screen ACTION — POST /screens, then its default tab (created when
# Jira made none), then each field in spec order.
create_screen() {
    local name body resp sid tabs tab have f
    name=$(printf '%s' "$1" | jq -r '.name')
    body=$(printf '%s' "$1" | jq -c '{name, description}')
    resp=$(http_post /screens "$body") || die "POST /screens for '$name' failed: $(http_err)"
    sid=$(printf '%s' "$resp" | jq -r '.id // empty | tostring')
    [ -n "$sid" ] || die "POST /screens for '$name' returned no id: $resp"
    echo "created screen '$name' (id $sid)"
    remember screen "$name" "$sid"
    tabs=$(http_get "/screens/$sid/tabs") || die "could not read the tabs of new screen $sid: $(http_err)"
    tab=$(printf '%s' "$tabs" | jq -r '.[0].id // empty | tostring')
    if [ -z "$tab" ]; then
        resp=$(http_post "/screens/$sid/tabs" '{"name":"Field Tab"}') || die "POST /screens/$sid/tabs failed: $(http_err)"
        tab=$(printf '%s' "$resp" | jq -r '.id // empty | tostring')
        [ -n "$tab" ] || die "POST /screens/$sid/tabs returned no id: $resp"
    fi
    have=$(http_get "/screens/$sid/tabs/$tab/fields") || die "could not read the fields of new screen $sid: $(http_err)"
    for f in $(printf '%s' "$1" | jq -r --argjson have "$have" '.fields[] | select(. as $f | [$have[].id] | index([$f]) | not)'); do
        http_post "/screens/$sid/tabs/$tab/fields" "$(jq -cn --arg f "$f" '{fieldId: $f}')" >/dev/null \
            || die "POST /screens/$sid/tabs/$tab/fields for $f failed: $(http_err)"
    done
    echo "screen '$name': added $(printf '%s' "$1" | jq '.fields | length') fields to tab $tab"
}

# run_action ACTION — send one layout action's writes.
run_action() {
    local kind name reqs req method path body resp id
    kind=$(printf '%s' "$1" | jq -r '.kind')
    name=$(printf '%s' "$1" | jq -r '.name')
    if [ "$kind" = "screen" ] && [ "$(printf '%s' "$1" | jq -r '.create // false')" = "true" ]; then
        create_screen "$1"
        return 0
    fi
    reqs=$(action_requests "$1") || die "could not render the requests for $kind '$name'"
    while IFS= read -r req; do
        [ -n "$req" ] || continue
        method=${req%% *}; req=${req#* }; path=${req%% *}; body=${req#* }
        case "$body" in *'"<id of '*) die "$kind '$name' still references an object that was not created: $body" ;; esac
        if [ "$method" = "PUT" ]; then
            resp=$(http_put "$path" "$body") || die "PUT $path failed: $(http_err)"
        else
            resp=$(http_post "$path" "$body") || die "POST $path failed: $(http_err)"
        fi
        case "$kind" in
            screenscheme)
                id=$(printf '%s' "$resp" | jq -r '.id // empty | tostring')
                [ -n "$id" ] || die "POST /screenscheme for '$name' returned no id: $resp"
                remember screenscheme "$name" "$id"
                echo "created screen scheme '$name' (id $id)" ;;
            *) echo "$kind '$name': $method $path" ;;
        esac
    done <<EOF
$reqs
EOF
}

LACTIONS=$(printf '%s' "$LPLAN" | jq -c '.actions[]')
while IFS= read -r a; do
    [ -n "$a" ] || continue
    run_action "$a"
done <<EOF
$LACTIONS
EOF

# ---- read-back -------------------------------------------------------------

REMAINING=0
i=0
while [ "$i" -lt "$WF_COUNT" ]; do
    SWF=$(printf '%s' "$RESOLVED" | jq -c --argjson i "$i" '.[$i]')
    locate_workflow "$(printf '%s' "$SWF" | jq -r '.name')" "$(printf '%s' "$SWF" | jq -r '.renamed_from // empty')"
    PLAN=$(plan_workflow "$SWF") || die "could not re-read workflow '$CUR_NAME'"
    N=$(printf '%s' "$PLAN" | jq '.changes')
    [ "$N" = "0" ] || { warn "read-back: workflow '$CUR_NAME' still needs $N change(s)"; REMAINING=$((REMAINING + N)); }
    i=$((i + 1))
done
SCHEMES=$(list_schemes) || die "could not re-list workflow schemes: $(http_err)"
SPLAN=$(scheme_plan "$SCHEMES") || die "could not re-read the scheme"
N=$(printf '%s' "$SPLAN" | jq '.changes')
[ "$N" = "0" ] || { warn "read-back: scheme '$SCHEME_NAME' still needs $N change(s)"; REMAINING=$((REMAINING + N)); }
if [ "$HAS_LAYOUT" = "1" ]; then
    read_layout
    LPLAN=$(layout_plan) || die "could not re-read the screens and schemes"
    N=$(printf '%s' "$LPLAN" | jq '.changes')
    [ "$N" = "0" ] || { warn "read-back: screens and schemes still need $N change(s)"; REMAINING=$((REMAINING + N)); }
fi

if [ "$REMAINING" -ne 0 ]; then
    warn "the writes returned, but the read-back still finds $REMAINING change(s) outstanding"
    exit 2
fi
echo "read-back confirms: 0 changes outstanding."
