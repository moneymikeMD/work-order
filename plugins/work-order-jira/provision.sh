#!/bin/bash
#
# provision.sh — create or converge a Jira Space that conforms to the
# work-order specification at the `full` profile: the project, the five
# lifecycle statuses and their validators, the seven custom fields, and
# those fields on every screen the project's issue types use. Each step is
# idempotent; a re-run converges.
#
# Usage:
#   provision.sh --dry-run --project KEY [--name "Name"]
#   provision.sh --yes     --project KEY [--name "Name"] [--lead ACCOUNT_ID]
#                          [--http PATH] [--workflow-apply PATH]
#                          [--rules PATH]
#
#   --project KEY   2-10 uppercase letters and digits, starting with a letter.
#                   A deleted project's key stays reserved site-wide.
#   --name "Name"   the project's display name. Default: the key.
#   --dry-run       print every planned request and exit 0, reaching no
#                   network and resolving no credential.
#   --yes           actually run it. Without --yes, on a terminal, this asks
#                   once up front, before any write.
#   --lead ID       the project lead's Jira accountId. Default: GET /myself.
#   --http PATH     a jira-http.sh-shaped client. Default: lib/jira-http.sh.
#   --workflow-apply PATH   step 3's script. Default: beside this file.
#   --rules PATH    validators for step 3. Default: workflow-rules.json.
#
# Step 2 ASSERTS on the readback that the project is a classic software
# project with an Epic issue type: `style` is computed from the template and
# has no request-time equivalent, so a stale template key silently yields a
# Business project instead.
#
# Step 5 exists because of a live incident: a field created but never placed
# on a screen accepts no value at all, so API writes succeed while the UI
# shows nothing. A Space provisioned without it looks conforming and is not.
#
# Boards and sprints are out of scope.
#
# Exit status:
#   0  every step converged, or --dry-run completed.
#   1  a read failed, the step-2 assert failed, a later step failed, or a
#      field name already exists under the wrong type.
#   3  no --yes and no terminal to ask on, or the answer was not yes.
#      Nothing was sent: a refusal, not a failure.
#
# bash 3.2 compatible.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$DIR/lib/common.sh"

# Parallel newline-separated lists in one table order: bash 3.2 has no
# associative arrays.
FIELD_NAMES='touches
executor
verify
human_steps
appends
defer_until
outcome'
FIELD_TYPE_KEYS='com.atlassian.jira.plugin.system.customfieldtypes:textarea
com.atlassian.jira.plugin.system.customfieldtypes:select
com.atlassian.jira.plugin.system.customfieldtypes:textarea
com.atlassian.jira.plugin.system.customfieldtypes:textarea
com.atlassian.jira.plugin.system.customfieldtypes:textarea
com.atlassian.jira.plugin.system.customfieldtypes:datepicker
com.atlassian.jira.plugin.system.customfieldtypes:textarea'
# executor's searcherKey is multiselectsearcher, not selectsearcher: a select
# field's PUT with selectsearcher is HTTP 400, measured live.
FIELD_SEARCHER_KEYS='com.atlassian.jira.plugin.system.customfieldtypes:textsearcher
com.atlassian.jira.plugin.system.customfieldtypes:multiselectsearcher
com.atlassian.jira.plugin.system.customfieldtypes:textsearcher
com.atlassian.jira.plugin.system.customfieldtypes:textsearcher
com.atlassian.jira.plugin.system.customfieldtypes:textsearcher
com.atlassian.jira.plugin.system.customfieldtypes:daterange
com.atlassian.jira.plugin.system.customfieldtypes:textsearcher'
EXECUTOR_OPTIONS='agent
human
mixed'
PROJECT_TEMPLATE_KEY='com.pyxis.greenhopper.jira:gh-simplified-scrum-classic'

PROJECT_KEY=""
PROJECT_NAME=""
DRY_RUN=0
ASSUME_YES=0
LEAD_ACCOUNT_ID=""
HTTP=""
WORKFLOW_APPLY=""
RULES_PATH=""

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            sed -n '3,44p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        --project)
            [ $# -ge 2 ] || die "--project needs a KEY"
            PROJECT_KEY="$2"; shift 2 ;;
        --name)
            [ $# -ge 2 ] || die "--name needs a value"
            PROJECT_NAME="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --yes|-y)  ASSUME_YES=1; shift ;;
        --lead)
            [ $# -ge 2 ] || die "--lead needs an accountId"
            LEAD_ACCOUNT_ID="$2"; shift 2 ;;
        --http)
            [ $# -ge 2 ] || die "--http needs a path"
            HTTP="$2"; shift 2 ;;
        --workflow-apply)
            [ $# -ge 2 ] || die "--workflow-apply needs a path"
            WORKFLOW_APPLY="$2"; shift 2 ;;
        --rules)
            [ $# -ge 2 ] || die "--rules needs a path, or 'none'"
            RULES_PATH="$2"; shift 2 ;;
        --) shift; break ;;
        -*) die "unknown flag '$1' — run with --help" ;;
        *) die "unexpected positional argument '$1' — the project is named with --project KEY" ;;
    esac
done

[ -n "$PROJECT_KEY" ] || die "--project KEY is required, e.g. ${0##*/} --dry-run --project ZZPROBE"
require_project_key "$PROJECT_KEY" || die "$WO_JIRA_KEY_ERR"
[ -n "$PROJECT_NAME" ] || PROJECT_NAME="$PROJECT_KEY"

[ -n "$HTTP" ] || HTTP="$DIR/lib/jira-http.sh"
[ -x "$HTTP" ] || die "--http path is not an executable file: '$HTTP'"
[ -n "$WORKFLOW_APPLY" ] || WORKFLOW_APPLY="$DIR/workflow-apply.sh"
[ -x "$WORKFLOW_APPLY" ] || die "--workflow-apply path is not an executable file: '$WORKFLOW_APPLY'"
[ -n "$RULES_PATH" ] || RULES_PATH="$DIR/workflow-rules.json"

need jq
trap tmpclean EXIT

field_triples() {
    paste <(printf '%s\n' "$FIELD_NAMES") <(printf '%s\n' "$FIELD_TYPE_KEYS") <(printf '%s\n' "$FIELD_SEARCHER_KEYS")
}

# ---- the plan ------------------------------------------------------------

if [ "$DRY_RUN" = "1" ]; then
    echo "PLANNED — provision.sh --project $PROJECT_KEY --name \"$PROJECT_NAME\""
    echo "nothing below was sent, no credential was resolved."
    echo
    echo "1. would read-or-create the project:"
    "$HTTP" --dry-run GET "/project/$PROJECT_KEY"
    if [ -n "$LEAD_ACCOUNT_ID" ]; then
        echo "   lead: $LEAD_ACCOUNT_ID (given)"
    else
        echo "   lead: would resolve via:"
        "$HTTP" --dry-run GET /myself
    fi
    CREATE_BODY=$(jq -cn --arg key "$PROJECT_KEY" --arg name "$PROJECT_NAME" \
        --arg lead "${LEAD_ACCOUNT_ID:-<accountId from /myself>}" --arg tpl "$PROJECT_TEMPLATE_KEY" \
        '{key: $key, name: $name, projectTypeKey: "software", projectTemplateKey: $tpl, leadAccountId: $lead}') \
        || die "could not render the planned create-project body"
    "$HTTP" --dry-run POST /project "$CREATE_BODY"
    echo
    echo "2. would ASSERT on the readback: .style == \"classic\", .projectTypeKey == \"software\", an issue type at .hierarchyLevel == 1."
    echo "3. would discover-or-create these custom fields (ids are per-site and never hardcoded):"
    "$HTTP" --dry-run GET /field
    while IFS="$(printf '\t')" read -r fname ftype fsearcher; do
        [ -n "$fname" ] || continue
        FIELD_BODY=$(jq -cn --arg name "$fname" --arg type "$ftype" --arg searcher "$fsearcher" \
            '{name: $name, type: $type, searcherKey: $searcher}') \
            || die "could not render the planned field body for '$fname'"
        "$HTTP" --dry-run POST /field "$FIELD_BODY"
    done <<EOF
$(field_triples)
EOF
    echo "   executor would also get options: $(printf '%s' "$EXECUTOR_OPTIONS" | tr '\n' '/' | sed 's#/$##')"
    echo
    echo "   then would probe each field's JQL-searchability (id not yet known, shown against the name):"
    while IFS= read -r fname; do
        [ -n "$fname" ] || continue
        probe_enc=$(jq -rn --arg v "project = $PROJECT_KEY AND \"$fname\" is EMPTY" '$v|@uri') \
            || die "could not url-encode the planned probe JQL for '$fname'"
        "$HTTP" --dry-run GET "/search/jql?jql=$probe_enc&fields=key&maxResults=1"
    done <<EOF
$FIELD_NAMES
EOF
    echo "   on HTTP 400 — the only signal, the 400 body carries no 'not searchable' text — would repair with:"
    while IFS="$(printf '\t')" read -r fname fsearcher; do
        [ -n "$fname" ] || continue
        put_body=$(jq -cn --arg s "$fsearcher" '{searcherKey: $s}') \
            || die "could not render the planned searcherKey PUT body for '$fname'"
        "$HTTP" --dry-run PUT "/field/<id-of-$fname>" "$put_body"
    done <<EOF
$(paste <(printf '%s\n' "$FIELD_NAMES") <(printf '%s\n' "$FIELD_SEARCHER_KEYS"))
EOF
    echo
    echo
    # Announced, never invoked: workflow-apply.sh's reads are not gated by its
    # own --dry-run, so calling it here would issue real credentialed GETs.
    echo "4. would run (announced, not invoked here):"
    echo "   $WORKFLOW_APPLY $PROJECT_KEY --http $HTTP --rules $RULES_PATH --yes"
    echo "   statuses: Open, In Progress, Awaiting Deployment, Completed, Cancelled"
    echo "   validators: from $RULES_PATH"
    echo
    echo "5. would add each field to every screen of the project's issue-type screen scheme (screen and tab ids are only knowable from a live read):"
    echo "   GET /issuetypescreenscheme/project?projectId=<project id>"
    echo "   GET /issuetypescreenscheme/mapping?issueTypeScreenSchemeId=<id>"
    echo "   GET /screenscheme?id=<a>&id=<b>  (one call, repeated id= params — there is no per-id GET)"
    echo "   GET /screens/<id>/tabs"
    echo "   POST /screens/<id>/tabs/<tab>/fields  {fieldId: <customfield id>}  (skipped when already present)"
    echo
    echo "6. would print the resolved customfield ids."
    exit 0
fi

# ---- one gate, before any write -----------------------------------------

if [ "$ASSUME_YES" != "1" ]; then
    if [ ! -t 0 ] || [ ! -r /dev/tty ]; then
        warn "no --yes and no terminal to confirm on — refusing to provision a Jira Space unattended. Re-run with --yes."
        exit 3
    fi
    warn "About to provision Jira Space '$PROJECT_KEY' (\"$PROJECT_NAME\"): create-or-verify the project, apply five statuses and their validators, create seven custom fields, and add them to every project screen. Proceed? [y/N]"
    ANSWER=""
    IFS= read -r ANSWER < /dev/tty || die "could not read the confirmation"
    case "$ANSWER" in
        y|Y|yes|YES) ;;
        *) warn "not confirmed — nothing was sent."; exit 3 ;;
    esac
fi

jira_get() { "$HTTP" GET "$1"; }
jira_write() { "$HTTP" "$1" "$2" "$3"; }

# jira_get_soft PATH — a GET treating HTTP 404 as "not found": prints the
# body and returns 0 when found, prints nothing and returns 1 on a 404,
# returns 2 on anything else for the caller to die on.
jira_get_soft() {
    local out err
    out=$(tmpfile) || return 2
    err=$(tmpfile) || return 2
    if "$HTTP" GET "$1" >"$out" 2>"$err"; then
        cat "$out"
        return 0
    fi
    # `if`, not `grep ... && return 1`: a failing left side of && sets the
    # list's status, and under set -e that exits the script.
    if grep -q "^HTTP 404" "$err"; then
        return 1
    fi
    cat "$err" >&2
    return 2
}

resolve_lead() {
    [ -n "$LEAD_ACCOUNT_ID" ] && return 0
    local who
    who=$(jira_get /myself) || die "could not resolve the project lead: GET /myself failed and no --lead was given"
    LEAD_ACCOUNT_ID=$(printf '%s' "$who" | jq -r '.accountId // empty') \
        || die "could not parse accountId from /myself"
    [ -n "$LEAD_ACCOUNT_ID" ] || die "/myself returned no accountId — pass --lead"
}

assert_project_shape() {
    local proj_json="$1" style ptype epic_ok
    style=$(printf '%s' "$proj_json" | jq -r '.style // empty') || die "could not parse .style from the project readback"
    ptype=$(printf '%s' "$proj_json" | jq -r '.projectTypeKey // empty') || die "could not parse .projectTypeKey from the project readback"
    epic_ok=$(printf '%s' "$proj_json" | jq -r '[.issueTypes[]? | select(.hierarchyLevel == 1)] | length > 0') \
        || die "could not parse .issueTypes from the project readback"
    [ "$style" = "classic" ] \
        || die "project '$PROJECT_KEY' has style '$style', not 'classic' — a wrong or stale projectTemplateKey silently yields a Business project, which this recipe does not apply to"
    [ "$ptype" = "software" ] \
        || die "project '$PROJECT_KEY' has projectTypeKey '$ptype', not 'software'"
    [ "$epic_ok" = "true" ] \
        || die "project '$PROJECT_KEY' has no issue type at hierarchyLevel 1 — this recipe does not apply to it"
}

PROJECT_ID=""
ensure_project() {
    local existing rc create_body created
    # `cmd && rc=0 || rc=$?`, not two statements: after a closing `fi`, `rc=$?`
    # reads the if-compound's status, not the command's.
    existing=$(jira_get_soft "/project/$PROJECT_KEY") && rc=0 || rc=$?
    if [ "$rc" = "0" ]; then
        echo "project '$PROJECT_KEY' already exists — verifying, no create needed."
        assert_project_shape "$existing"
        PROJECT_ID=$(printf '%s' "$existing" | jq -r '.id // empty') || die "could not parse .id from the existing project"
        [ -n "$PROJECT_ID" ] || die "the existing project '$PROJECT_KEY' readback carried no .id"
        return 0
    fi
    [ "$rc" = "1" ] || die "GET /project/$PROJECT_KEY failed unexpectedly — refusing to guess whether it exists"

    resolve_lead
    create_body=$(jq -cn --arg key "$PROJECT_KEY" --arg name "$PROJECT_NAME" --arg lead "$LEAD_ACCOUNT_ID" --arg tpl "$PROJECT_TEMPLATE_KEY" \
        '{key: $key, name: $name, projectTypeKey: "software", projectTemplateKey: $tpl, leadAccountId: $lead}') \
        || die "could not render the create-project body"
    echo "project '$PROJECT_KEY' does not exist — creating it."
    created=$(jira_write POST /project "$create_body") || die "POST /project failed"
    PROJECT_ID=$(printf '%s' "$created" | jq -r '.id // empty') || die "could not parse .id from the create-project response"
    [ -n "$PROJECT_ID" ] || die "POST /project succeeded but returned no .id"

    existing=$(jira_get "/project/$PROJECT_KEY") || die "could not read back the just-created project '$PROJECT_KEY'"
    assert_project_shape "$existing"
}

apply_workflow() {
    echo "applying the lifecycle statuses and validators via ${WORKFLOW_APPLY##*/} ..."
    "$WORKFLOW_APPLY" "$PROJECT_KEY" --http "$HTTP" --rules "$RULES_PATH" --yes \
        || die "${WORKFLOW_APPLY##*/} failed for '$PROJECT_KEY' — see its own output above"
}

# probe_field_searchable NAME — one JQL search: returns 0 searchable, 1 not,
# 2 for the caller to die on. The 400 body carries no "not searchable" text,
# so any 400 here IS that case.
probe_field_searchable() {
    local name="$1" enc out err
    enc=$(jq -rn --arg v "project = $PROJECT_KEY AND \"$name\" is EMPTY" '$v|@uri') || return 2
    out=$(tmpfile) || return 2
    err=$(tmpfile) || return 2
    if "$HTTP" GET "/search/jql?jql=$enc&fields=key&maxResults=1" >"$out" 2>"$err"; then
        if jq -e '.issues | type == "array"' "$out" >/dev/null 2>&1; then
            return 0
        fi
        warn "HTTP 2xx probing '$name' but the body has no .issues array — refusing to call that searchable:"
        cat "$out" >&2
        return 2
    fi
    if grep -q "^HTTP 400" "$err"; then
        return 1
    fi
    cat "$err" >&2
    return 2
}

# ensure_field_searchable NAME ID SEARCHER — probe, then PUT the searcherKey
# and re-probe once. The probe is the only evidence: GET /field's searcherKey
# always reads null.
ensure_field_searchable() {
    local name="$1" field_id="$2" searcher="$3" rc put_body
    probe_field_searchable "$name" && rc=0 || rc=$?
    if [ "$rc" = "0" ]; then
        echo "field '$name' ($field_id) is JQL-searchable."
        return 0
    fi
    [ "$rc" = "1" ] || die "could not evaluate JQL-searchability for '$name' ($field_id)"
    put_body=$(jq -cn --arg s "$searcher" '{searcherKey: $s}') \
        || die "could not render the searcherKey PUT body for '$name'"
    echo "field '$name' ($field_id) is NOT searchable (confirmed via HTTP 400) — repairing with searcherKey=$searcher."
    jira_write PUT "/field/$field_id" "$put_body" >/dev/null \
        || die "PUT /field/$field_id failed for '$name'"
    probe_field_searchable "$name" && rc=0 || rc=$?
    [ "$rc" = "0" ] \
        || die "field '$name' ($field_id) is still not JQL-searchable after the repair — refusing to guess further"
    echo "field '$name' ($field_id) is JQL-searchable after repair."
}

ALL_FIELDS_JSON=""

# field_lookup NAME — "id<TAB>schema.custom" and 0 for exactly one match,
# nothing and 0 for none, 1 for several. Jira does not enforce unique custom
# field names, so this refuses to guess.
field_lookup() {
    local name="$1" count ids
    count=$(printf '%s' "$ALL_FIELDS_JSON" | jq -r --arg n "$name" '[.[] | select(.custom == true and .name == $n)] | length') || return 1
    if [ "$count" -gt 1 ]; then
        ids=$(printf '%s' "$ALL_FIELDS_JSON" | jq -r --arg n "$name" '[.[] | select(.custom == true and .name == $n)] | map(.id) | join(", ")')
        warn "'$name' matches $count custom fields (ids: $ids) — refusing to guess which one"
        return 1
    fi
    printf '%s' "$ALL_FIELDS_JSON" | jq -r --arg n "$name" \
        '[.[] | select(.custom == true and .name == $n)][0] | select(. != null) | "\(.id)\t\(.schema.custom // "")"'
}

RESOLVED_FIELD_IDS=""

ensure_fields() {
    ALL_FIELDS_JSON=$(jira_get /field) || die "could not read /field — cannot discover custom field ids by name"
    local name type searcher lookup found_id found_type new_json ids=""
    while IFS="$(printf '\t')" read -r name type searcher; do
        [ -n "$name" ] || continue
        lookup=$(field_lookup "$name") || die "could not look up field '$name'"
        if [ -n "$lookup" ]; then
            found_id="${lookup%%$'\t'*}"
            found_type="${lookup#*$'\t'}"
            [ "$found_type" = "$type" ] \
                || die "a custom field named '$name' already exists ($found_id) with type '$found_type', not '$type' — refusing to reuse it"
            echo "field '$name' already present: $found_id"
        else
            new_json=$(jq -cn --arg name "$name" --arg type "$type" --arg searcher "$searcher" \
                '{name: $name, type: $type, searcherKey: $searcher}') || die "could not render the field body for '$name'"
            echo "field '$name' absent — creating."
            new_json=$(jira_write POST /field "$new_json") || die "POST /field failed for '$name'"
            found_id=$(printf '%s' "$new_json" | jq -r '.id // empty') || die "could not parse .id from the create-field response for '$name'"
            [ -n "$found_id" ] || die "POST /field succeeded for '$name' but returned no .id"
            ALL_FIELDS_JSON=$(jira_get /field) || die "could not re-read /field after creating '$name'"
        fi
        ensure_field_searchable "$name" "$found_id" "$searcher"
        ids="$ids$found_id
"
    done <<EOF
$(field_triples)
EOF
    RESOLVED_FIELD_IDS="$ids"
    local executor_lookup
    executor_lookup=$(field_lookup executor) || die "could not look up the 'executor' field"
    ensure_executor_options "${executor_lookup%%$'\t'*}"
}

# ensure_executor_options FIELD_ID — add agent/human/mixed, only the missing
# ones, to the field's default context.
ensure_executor_options() {
    local field_id="$1" contexts ctx_id have_json opt body
    [ -n "$field_id" ] || die "could not resolve the executor field's id — cannot set its options"
    contexts=$(jira_get "/field/$field_id/context") || die "could not read /field/$field_id/context"
    ctx_id=$(printf '%s' "$contexts" | jq -r '.values[0].id // empty') || die "could not parse the executor field's default context id"
    [ -n "$ctx_id" ] || die "the executor field ($field_id) has no context to attach options to"
    have_json=$(jira_get "/field/$field_id/context/$ctx_id/option") || die "could not read the executor field's existing options"
    while IFS= read -r opt; do
        [ -n "$opt" ] || continue
        if printf '%s' "$have_json" | jq -e --arg v "$opt" '[.values[]? | select(.value == $v)] | length > 0' >/dev/null 2>&1; then
            echo "executor option '$opt' already present."
        else
            body=$(jq -cn --arg v "$opt" '{options: [{value: $v}]}') || die "could not render the option body for '$opt'"
            echo "executor option '$opt' absent — adding."
            jira_write POST "/field/$field_id/context/$ctx_id/option" "$body" >/dev/null \
                || die "POST /field/$field_id/context/$ctx_id/option failed for '$opt'"
        fi
    done <<EOF
$EXECUTOR_OPTIONS
EOF
}

SCREEN_IDS=""
collect_screen_ids() {
    local itss_project itss_id mapping scheme_ids scheme_id qs scheme_json ids_here sid
    itss_project=$(jira_get "/issuetypescreenscheme/project?projectId=$PROJECT_ID") \
        || die "could not read /issuetypescreenscheme/project?projectId=$PROJECT_ID"
    itss_id=$(printf '%s' "$itss_project" | jq -r '.values[0].issueTypeScreenScheme.id // empty') \
        || die "could not parse the project's issueTypeScreenScheme id"
    [ -n "$itss_id" ] || die "project '$PROJECT_KEY' (id $PROJECT_ID) has no issueTypeScreenScheme — cannot place fields on any screen"

    mapping=$(jira_get "/issuetypescreenscheme/mapping?issueTypeScreenSchemeId=$itss_id") \
        || die "could not read the issue-type-screen-scheme mapping"
    scheme_ids=$(printf '%s' "$mapping" | jq -r '[.values[].screenSchemeId] | unique[]') \
        || die "could not parse the screenSchemeId list from the mapping"
    [ -n "$scheme_ids" ] || die "issueTypeScreenScheme '$itss_id' has no screen scheme mappings at all"

    # One call with repeated `id=` params. A per-id GET /screenscheme/<id> is
    # HTTP 405 and a comma-joined id=a,b,c is HTTP 400 — both confirmed.
    qs=""
    while IFS= read -r scheme_id; do
        [ -n "$scheme_id" ] || continue
        qs="$qs&id=$(jq -rn --arg v "$scheme_id" '$v|@uri')" || die "could not url-encode screen scheme id '$scheme_id'"
    done <<EOF
$scheme_ids
EOF
    qs="${qs#&}"
    scheme_json=$(jira_get "/screenscheme?$qs") || die "could not read /screenscheme?$qs"

    SCREEN_IDS=""
    ids_here=$(printf '%s' "$scheme_json" | jq -r '[.values[] | (.screens // {}) | to_entries[] | .value] | unique[]') \
        || die "could not parse screen ids out of the screen scheme response"
    while IFS= read -r sid; do
        [ -n "$sid" ] || continue
        in_list "$sid" "$SCREEN_IDS" || SCREEN_IDS="$SCREEN_IDS$sid
"
    done <<EOF
$ids_here
EOF
    [ -n "$SCREEN_IDS" ] || die "no screen ids resolved for '$PROJECT_KEY' — nothing to add fields to"
}

add_fields_to_screens() {
    collect_screen_ids
    local screen_id tabs tab_ids tab_id tab_name have_fields name field_id
    while IFS= read -r screen_id; do
        [ -n "$screen_id" ] || continue
        tabs=$(jira_get "/screens/$screen_id/tabs") || die "could not read /screens/$screen_id/tabs"
        # Assign and guard, never inline into the heredoc word: a command
        # substitution there discards its exit status and loops zero times.
        tab_ids=$(printf '%s' "$tabs" | jq -r '.[].id') || die "could not parse tab ids for screen $screen_id"
        while IFS= read -r tab_id; do
            [ -n "$tab_id" ] || continue
            tab_name=$(printf '%s' "$tabs" | jq -r --arg id "$tab_id" '[.[] | select((.id|tostring) == $id)][0].name // "?"')
            have_fields=$(jira_get "/screens/$screen_id/tabs/$tab_id/fields") \
                || die "could not read /screens/$screen_id/tabs/$tab_id/fields"
            while IFS="$(printf '\t')" read -r name field_id; do
                [ -n "$name" ] || continue
                if printf '%s' "$have_fields" | jq -e --arg id "$field_id" '[.[] | select((.id|tostring) == $id)] | length > 0' >/dev/null 2>&1; then
                    echo "field '$name' already on screen $screen_id / tab '$tab_name'."
                else
                    echo "field '$name' absent from screen $screen_id / tab '$tab_name' — adding."
                    jira_write POST "/screens/$screen_id/tabs/$tab_id/fields" "$(jq -cn --arg id "$field_id" '{fieldId: $id}')" >/dev/null \
                        || die "POST /screens/$screen_id/tabs/$tab_id/fields failed for '$name'"
                fi
            done <<EOF
$(paste <(printf '%s\n' "$FIELD_NAMES") <(printf '%s\n' "$RESOLVED_FIELD_IDS"))
EOF
        done <<EOF
$tab_ids
EOF
    done <<EOF
$SCREEN_IDS
EOF
}

print_field_table() {
    local name field_id ftype rows=""
    while IFS="$(printf '\t')" read -r name field_id ftype; do
        [ -n "$name" ] || continue
        rows="$rows$(printf '%s\t%s\t%s' "$field_id" "$name" "$ftype")
"
    done <<EOF
$(paste <(printf '%s\n' "$FIELD_NAMES") <(printf '%s\n' "$RESOLVED_FIELD_IDS") <(printf '%s\n' "$FIELD_TYPE_KEYS"))
EOF
    printf '%s' "$rows" | table "$(printf 'ID\tNAME\tTYPE')"
}

# Fields before the workflow: workflow-rules.json resolves {field:NAME}
# placeholders against the site, so a validator naming a field that does not
# exist yet fails the whole step.
ensure_project
ensure_fields
apply_workflow
add_fields_to_screens
echo
echo "Jira Space '$PROJECT_KEY' now conforms to work-order at the 'full' profile. Custom fields:"
print_field_table
