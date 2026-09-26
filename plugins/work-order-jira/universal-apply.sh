#!/bin/bash
#
# universal-apply.sh — converge the site-wide Universal workflows and their
# shared workflow scheme towards universal-workflows.json. Both workflows are
# GLOBAL and serve every contract project, so this script takes no project.
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
# from -> to, never by name) or validator (matched by ruleKey + parameters) is
# added; a missing scheme mapping is added. Nothing is ever changed or removed,
# and whatever Jira holds that the spec does not name is printed as
# "not in spec (left alone)".
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
            sed -n '3,31p' "$0" | sed 's/^# \{0,1\}//'
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
            | .validators[] |= need((.ruleKey | type) == "string" and (.parameters | type) == "object";
                 "each validator needs a ruleKey string and a parameters object")))
    | .scheme |= need((.name | type) == "string" and (.defaultWorkflow | type) == "string"
                      and (.issueTypeMappings | type) == "object" and (.issueTypeHierarchyLevels | type) == "object";
                      "the scheme needs name, defaultWorkflow, issueTypeMappings and issueTypeHierarchyLevels")
    ' "$SPEC") || die "'$SPEC' is not a valid spec (see universal-workflows.json for the shape)"

STATUSES=$(http_get "/statuses/search?maxResults=100") \
    || die "could not read /statuses/search: $(http_err)"
FIELDS=$(http_get "/field") || die "could not read /field: $(http_err)"

# Every status name becomes {name, id, category}, every transition end a status
# id, and every {field:NAME} a custom field id. Anything that resolves to zero
# or several site objects is left as UNRESOLVED:... and fatal below.
RESOLVED=$(jq -cn --argjson spec "$SPEC_JSON" --argjson statuses "$STATUSES" --argjson fields "$FIELDS" '
    def one($kind; $n; $m): if ($m | length) == 1 then $m[0].id else "UNRESOLVED:" + $kind + ":" + $n end;
    def sid($n): if $n == null then null else one("status"; $n; [$statuses.values[] | select(.name == $n)]) end;
    def field_ph:
        if type == "string" and test("^\\{field:.+\\}$") then
            capture("^\\{field:(?<n>.+)\\}$").n as $n | one("field"; $n; [$fields[] | select(.name == $n)])
        else . end;
    $spec.workflows | map(
        .statuses |= map(. as $n | {name: $n, id: sid($n),
            category: ([$statuses.values[] | select(.name == $n) | .statusCategory][0] // null)})
        | .transitions |= map(.fromName = .from | .toName = .to | .from = sid(.from) | .to = sid(.to)
            | .validators |= map({ruleKey, parameters: (.parameters | map_values(field_ph))})))
    ') || die "could not resolve the names in '$SPEC'"
UNRESOLVED=$(printf '%s' "$RESOLVED" | jq -r '[.. | strings | select(startswith("UNRESOLVED:"))] | unique | join(", ")') \
    || die "could not scan the resolved spec"
[ -z "$UNRESOLVED" ] || die "'$SPEC' names something this site does not have exactly once: $UNRESOLVED"
if printf '%s' "$RESOLVED" | grep -Eiq '\{[[:space:]]*field[[:space:]]*:'; then
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
    jq -cn --argjson s "$1" --argjson bulk "$BULK" --arg cur "$CUR_NAME" --argjson fields "$FIELDS" --argjson statuses "$STATUSES" '
        def sname($id): if $id == null then "(create)" else ([$statuses.values[] | select(.id == $id) | .name][0] // ("status " + $id)) end;
        def rule_label: if .parameters.fieldsRequired then
                (.parameters.fieldsRequired as $f | "requires " + ([$fields[] | select(.id == $f) | .name][0] // $f))
            else .ruleKey end;
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
               actions: [], validators, triggers: [], properties: {},
               _label: "\(.name)  \(.fromName) -> \(.toName)", _rules: (.validators | map(rule_label))}
          ] as $addT
        | [$pairs[] | select((.m | length) == 1)
            | .m[0] as $e | .t as $t
            | (($e.validators // []) | map({ruleKey, parameters})) as $hv
            | [$t.validators[] | select(. as $v | any($hv[]; . == $v) | not)] as $add
            | select(($add | length) > 0)
            | {id: $e.id, validators: $add, _label: "\($e.name) (\($e.id))  \($t.fromName // "(create)") -> \($t.toName)", _rules: ($add | map(rule_label))}
          ] as $addV
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
            notInSpec: (
                [$wf.statuses[] | select(.statusReference as $r | $specSids | index($r) | not) | "status \(sname(.statusReference))"]
                + [$have[] | select(.id as $i | $matchedIds | index($i) | not)
                    | "transition \(.id) \"\(.name)\"  \(if is_initial then "(create)" elif (froms | length) == 0 then "(any)" else (froms | map(sname(.)) | join(",")) end) -> \(sname(.toStatusReference))"]
                + [$pairs[] | select((.m | length) == 1) | .m[0] as $e | .t as $t
                    | (($e.validators // [])[] | select(({ruleKey, parameters}) as $v | any($t.validators[]; . == $v) | not)
                        | "validator \(.ruleKey) (\(rule_label)) on transition \($e.id) \"\($e.name)\""),
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
                        + ([.addValidators[].validators | length] | add // 0))
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
                            | if ($add | length) > 0 then .validators = ((.validators // []) + $add) else . end))
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

echo
if [ "$TOTAL" -eq 0 ]; then
    echo "0 changes: every workflow, transition, validator and scheme mapping in '$SPEC' is already in Jira."
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

if [ "$REMAINING" -ne 0 ]; then
    warn "the writes returned, but the read-back still finds $REMAINING change(s) outstanding"
    exit 2
fi
echo "read-back confirms: 0 changes outstanding."
