#!/bin/bash
#
# universal-switch.sh — move one company-managed Jira project off its own
# "<KEY>: Software Simplified Workflow Scheme" and onto the shared Universal
# workflow scheme that universal-apply.sh creates, then delete the project's
# old per-project workflows and scheme. Idempotent: a project already switched
# and cleaned up reports "0 changes".
#
# Usage:
#   universal-switch.sh PROJECT_KEY [--http PATH] [--scheme NAME]
#                                   [--dry-run] [--yes]
#
#   --http PATH    a jira-http.sh-shaped client. Default: lib/jira-http.sh.
#   --scheme NAME  the target workflow scheme. Default:
#                  'Universal Managed Workflow Scheme'.
#   --dry-run      run every read, print every write it would send, send none.
#   --yes          actually send the writes. This flag is the only gate.
#
# Steps:
#   1. refuse unless the target scheme exists;
#   2. if the project is already on it, go straight to 5;
#   3. pre-drain: every Task/Story/Bug in To Do whose verify field is set is
#      moved to Open through its current workflow;
#   4. switch the scheme, mapping To Do -> Triage (Task/Story/Bug) or Open
#      (Epic/Sub-task) and Done -> Completed, and wait for Jira's async task;
#      any other in-use status the target workflow lacks stops the run;
#   5. verify the project is on the target scheme and nothing is left in
#      To Do or Done;
#   6. delete the old workflows and scheme, each only once no scheme or
#      project uses it.
#
# Exit status:
#   0  done, nothing to do, or --dry-run completed.
#   1  a failure.
#   3  writes were needed and --yes was not given. A refusal, not a failure.
#
# Environment:
#   WO_SWITCH_POLL_SECONDS    seconds between task polls, default 2
#   WO_SWITCH_TIMEOUT_SECONDS give up waiting on the task after this, default 600
#
# bash 3.2 compatible.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$DIR/lib/common.sh"

PROJECT_KEY=""
HTTP=""
TARGET_SCHEME_NAME="Universal Managed Workflow Scheme"
DRY_RUN=0
ASSUME_YES=0
POLL_SECONDS="${WO_SWITCH_POLL_SECONDS:-2}"
TIMEOUT_SECONDS="${WO_SWITCH_TIMEOUT_SECONDS:-600}"

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            sed -n '3,41p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        --http)
            [ $# -ge 2 ] || die "--http needs a path"
            HTTP="$2"; shift 2 ;;
        --scheme)
            [ $# -ge 2 ] && [ -n "$2" ] || die "--scheme needs a workflow scheme name"
            TARGET_SCHEME_NAME="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --yes|-y)  ASSUME_YES=1; shift ;;
        --) shift; break ;;
        -*) die "unknown flag '$1' — run with --help" ;;
        *)
            [ -z "$PROJECT_KEY" ] || die "unexpected extra argument '$1' (project key already given: '$PROJECT_KEY')"
            PROJECT_KEY="$1"; shift ;;
    esac
done

[ -n "$PROJECT_KEY" ] || die "a PROJECT_KEY is required, e.g. ${0##*/} WO --dry-run"
require_project_key "$PROJECT_KEY" || die "$WO_JIRA_KEY_ERR"

[ -n "$HTTP" ] || HTTP="$DIR/lib/jira-http.sh"
[ -x "$HTTP" ] || die "--http path is not an executable file: '$HTTP'"

case "$POLL_SECONDS" in ''|*[!0-9]*) die "WO_SWITCH_POLL_SECONDS must be a whole number, got '$POLL_SECONDS'" ;; esac
case "$TIMEOUT_SECONDS" in ''|*[!0-9]*) die "WO_SWITCH_TIMEOUT_SECONDS must be a whole number, got '$TIMEOUT_SECONDS'" ;; esac

need jq
trap tmpclean EXIT

OLD_SCHEME_NAME="$PROJECT_KEY: Software Simplified Workflow Scheme"
OLD_WORKFLOW_NAMES="Software Simplified Workflow for Project $PROJECT_KEY
Epic Software Simplified Workflow for Project $PROJECT_KEY"
[ "$TARGET_SCHEME_NAME" != "$OLD_SCHEME_NAME" ] \
    || die "the target scheme '$TARGET_SCHEME_NAME' is the one this script deletes for $PROJECT_KEY"

# Plan mode: --dry-run, or no --yes. Every read runs; no write is sent.
PLAN=0
if [ "$DRY_RUN" = "1" ] || [ "$ASSUME_YES" != "1" ]; then PLAN=1; fi
CHANGES=0

http_get()  { "$HTTP" GET "$1"; }
http_post() { "$HTTP" POST "$1" "$2"; }
http_delete() { "$HTTP" DELETE "$1"; }

uri() { jq -rn --arg v "$1" '$v|@uri'; }

# show_write METHOD PATH [BODY] — print a write this run sends or, in plan
# mode, would send.
show_write() {
    if [ "$PLAN" = "1" ]; then printf 'WOULD %s /rest/api/3%s\n' "$1" "$2"
    else printf '%s /rest/api/3%s\n' "$1" "$2"; fi
    [ -z "${3:-}" ] || printf '%s\n' "$3" | jq -c .
}

# ---- reads -------------------------------------------------------------

SCHEMES_JSON="[]"

# load_schemes — every workflow scheme on the site, all pages.
load_schemes() {
    local start=0 page last
    SCHEMES_JSON="[]"
    while :; do
        page=$(http_get "/workflowscheme?startAt=$start&maxResults=50") \
            || die "could not read GET /workflowscheme"
        SCHEMES_JSON=$(jq -cn --argjson a "$SCHEMES_JSON" --argjson p "$page" '$a + ($p.values // [])') \
            || die "could not parse GET /workflowscheme"
        last=$(printf '%s' "$page" | jq -r '(.isLast // true) or ((.values // []) | length == 0)')
        [ "$last" = "true" ] && break
        start=$(printf '%s' "$SCHEMES_JSON" | jq 'length')
    done
}

# scheme_by_name NAME — the one scheme object with that exact name. Prints
# nothing and returns 1 when absent; returns 2 when the name is ambiguous.
scheme_by_name() {
    local n
    n=$(printf '%s' "$SCHEMES_JSON" | jq --arg n "$1" '[.[] | select(.name == $n)] | length') || return 1
    [ "$n" = "0" ] && return 1
    [ "$n" = "1" ] || return 2
    printf '%s' "$SCHEMES_JSON" | jq -c --arg n "$1" '.[] | select(.name == $n)'
}

# workflow_statuses NAME — the workflow's statuses as [{id,name}]. Returns 1
# when no workflow has that name.
workflow_statuses() {
    local resp out
    resp=$(http_get "/workflow/search?workflowName=$(uri "$1")&expand=statuses") || return 1
    out=$(printf '%s' "$resp" | jq -c --arg n "$1" \
        '[.values[] | select(.id.name == $n)][0].statuses // empty | map({id: (.id | tostring), name})') || return 1
    [ -n "$out" ] || return 1
    printf '%s' "$out"
}

# workflow_entity_id NAME — the workflow's entityId, or nothing when absent.
workflow_entity_id() {
    local resp
    resp=$(http_get "/workflow/search?workflowName=$(uri "$1")") || return 1
    printf '%s' "$resp" | jq -r --arg n "$1" '[.values[] | select(.id.name == $n)][0].id.entityId // empty'
}

# jql_page JQL FIELDS_JSON TOKEN — one POST /search/jql page.
jql_page() {
    local body
    body=$(jq -cn --arg j "$1" --argjson f "$2" --arg t "$3" \
        '{jql: $j, fields: $f, maxResults: 100} + (if $t == "" then {} else {nextPageToken: $t} end)') || return 1
    http_post /search/jql "$body"
}

# jql_all JQL FIELDS_JSON — every matching issue as one JSON array.
jql_all() {
    local token="" page all="[]"
    while :; do
        page=$(jql_page "$1" "$2" "$token") || return 1
        all=$(jq -cn --argjson a "$all" --argjson p "$page" '$a + ($p.issues // [])') || return 1
        token=$(printf '%s' "$page" | jq -r 'if .isLast == true then "" else (.nextPageToken // "") end') || return 1
        [ -n "$token" ] || break
    done
    printf '%s' "$all"
}

# jql_any JQL — "yes" when at least one issue matches, else "no".
jql_any() {
    local page
    page=$(http_post /search/jql "$(jq -cn --arg j "$1" '{jql: $j, fields: ["key"], maxResults: 1}')") || return 1
    printf '%s' "$page" | jq -r 'if ((.issues // []) | length) > 0 then "yes" else "no" end'
}

# ---- 1. target scheme and project --------------------------------------

load_schemes
TARGET_SCHEME=$(scheme_by_name "$TARGET_SCHEME_NAME") && rc=0 || rc=$?
case "$rc" in
    0) ;;
    2) die "more than one workflow scheme is named '$TARGET_SCHEME_NAME' — refusing to guess" ;;
    *) die "workflow scheme '$TARGET_SCHEME_NAME' does not exist on this site — create it first (universal-apply.sh)" ;;
esac
TARGET_SCHEME_ID=$(printf '%s' "$TARGET_SCHEME" | jq -r '.id | tostring')
echo "target scheme: '$TARGET_SCHEME_NAME' (id $TARGET_SCHEME_ID)"

PROJECT_JSON=$(http_get "/project/$PROJECT_KEY") || die "could not read project '$PROJECT_KEY'"
PROJECT_ID=$(printf '%s' "$PROJECT_JSON" | jq -r '.id // empty')
[ -n "$PROJECT_ID" ] || die "GET /project/$PROJECT_KEY returned no id"
[ "$(printf '%s' "$PROJECT_JSON" | jq -r '.style // ""')" = "classic" ] \
    || die "project '$PROJECT_KEY' is not company-managed (classic): workflow schemes cannot be assigned to it"
ISSUE_TYPES=$(printf '%s' "$PROJECT_JSON" | jq -c '[.issueTypes[] | {id: (.id | tostring), name, level: (.hierarchyLevel // 0)}]')

# current_scheme — the project's workflow scheme object, from Jira.
current_scheme() {
    local resp
    resp=$(http_get "/workflowscheme/project?projectId=$PROJECT_ID") || return 1
    printf '%s' "$resp" | jq -c --arg p "$PROJECT_ID" \
        '[.values[] | select((.projectIds // []) | map(tostring) | index($p))][0].workflowScheme // empty'
}

CURRENT_SCHEME=$(current_scheme) || die "could not read the workflow scheme of project $PROJECT_KEY"
[ -n "$CURRENT_SCHEME" ] || die "GET /workflowscheme/project named no scheme for project $PROJECT_KEY (id $PROJECT_ID)"
CURRENT_SCHEME_ID=$(printf '%s' "$CURRENT_SCHEME" | jq -r '.id // "" | tostring')
CURRENT_SCHEME_NAME=$(printf '%s' "$CURRENT_SCHEME" | jq -r '.name // ""')

SWITCHED=0

# ---- 3-4. plan, pre-drain, switch --------------------------------------

# workflow_for SCHEME_JSON ISSUE_TYPE_ID — the workflow the scheme gives the type.
workflow_for() {
    printf '%s' "$1" | jq -r --arg t "$2" '(.issueTypeMappings // {})[$t] // .defaultWorkflow // empty'
}

# build_plan — per issue type: its old and new workflow, the status mappings
# the switch sends, and the old statuses the target lacks that no rule covers.
build_plan() {
    local plan="[]" tid level old_wf new_wf old_st new_st entry
    while IFS="$(printf '\t')" read -r tid level; do
        [ -n "$tid" ] || continue
        old_wf=$(workflow_for "$CURRENT_SCHEME" "$tid")
        new_wf=$(workflow_for "$TARGET_SCHEME" "$tid")
        [ -n "$old_wf" ] || die "scheme '$CURRENT_SCHEME_NAME' gives issue type $tid no workflow"
        [ -n "$new_wf" ] || die "scheme '$TARGET_SCHEME_NAME' gives issue type $tid no workflow"
        old_st=$(workflow_statuses "$old_wf") || die "could not read the statuses of workflow '$old_wf'"
        new_st=$(workflow_statuses "$new_wf") || die "could not read the statuses of workflow '$new_wf'"
        entry=$(jq -cn --arg tid "$tid" --argjson level "$level" --arg ow "$old_wf" --arg nw "$new_wf" \
            --argjson old "$old_st" --argjson new "$new_st" '
            (if $level == 0 then {"To Do": "Triage", "Done": "Completed"}
             else {"To Do": "Open", "Done": "Completed",
                   "Awaiting Deployment": "In Progress", "Deferred": "Open"} end) as $rules
            | ($new | map(.name)) as $newNames
            | [$old[] | select(.name as $n | $newNames | index($n) | not)] as $gone
            | ([$new[] | select(.name == "Triage")][0].id // null) as $fallback
            | {issueTypeId: $tid, level: $level, oldWorkflow: $ow, newWorkflow: $nw,
               mappings: ([$gone[] | select($rules[.name] != null) | . as $o
                   | {oldStatusId: $o.id, old: $o.name, new: $rules[$o.name],
                      newStatusId: ([$new[] | select(.name == $rules[$o.name])][0].id // null)}]
                 + [$gone[] | select($rules[.name] == null)
                   | {oldStatusId: .id, old: .name, new: "Triage", newStatusId: $fallback, unused: true}]),
               unmapped: [$gone[] | select($rules[.name] == null)]}') \
            || die "could not compute the status mappings for issue type $tid"
        plan=$(jq -cn --argjson p "$plan" --argjson e "$entry" '$p + [$e]')
    done <<EOF
$(printf '%s' "$ISSUE_TYPES" | jq -r '.[] | "\(.id)\t\(.level)"')
EOF
    printf '%s' "$plan"
}

# check_unmapped PLAN — die naming every status the target workflow lacks,
# not covered by a mapping rule, that an issue of that type is in.
check_unmapped() {
    local bad="" tid sid sname tname miss
    miss=$(printf '%s' "$1" | jq -r '.[] | .issueTypeId as $t | .mappings[] | select(.newStatusId == null) | "\($t): \(.new)"') \
        || die "could not read the computed mappings"
    [ -z "$miss" ] || die "the target workflow lacks the status a mapping rule needs — issue type $(printf '%s' "$miss" | tr '\n' ',' | sed 's/,$//')"
    while IFS="$(printf '\t')" read -r tid sid sname; do
        [ -n "$tid" ] || continue
        case "$(jql_any "project = $PROJECT_KEY AND issuetype = $tid AND status = $sid")" in
            yes)
                tname=$(printf '%s' "$ISSUE_TYPES" | jq -r --arg t "$tid" '.[] | select(.id == $t) | .name')
                bad="$bad'$sname' ($tname), " ;;
            no) ;;
            *) die "could not check whether any $PROJECT_KEY issue of type $tid is in status '$sname'" ;;
        esac
    done <<EOF
$(printf '%s' "$1" | jq -r '.[] | .issueTypeId as $t | .unmapped[] | "\($t)\t\(.id)\t\(.name)"')
EOF
    [ -z "$bad" ] || die "issues in $PROJECT_KEY sit in statuses the target workflow does not have and no mapping rule covers: ${bad%, } — move them first"
}

# verify_field_id — the one custom field named verify.
verify_field_id() {
    local fields
    fields=$(http_get /field) || return 1
    printf '%s' "$fields" | jq -r '[.[] | select(.name == "verify" and (.custom // false))] | if length == 1 then .[0].id else empty end'
}

# pre_drain PLAN — move Task/Story/Bug issues in To Do with verify set to
# Open through their current workflow. Dies if any cannot be moved.
pre_drain() {
    local ids vf issues keys key trans tid body failed="" moved=0
    ids=$(printf '%s' "$1" | jq -r '[.[] | select(.level == 0) | select(.mappings[] | .old == "To Do") | .issueTypeId] | unique | join(", ")')
    if [ -z "$ids" ]; then
        echo "pre-drain: no Task/Story/Bug status maps from To Do — nothing to drain"
        return 0
    fi
    vf=$(verify_field_id) || die "could not read GET /field"
    [ -n "$vf" ] || die "no single custom field named 'verify' exists — cannot tell which To Do issues to pre-drain"
    issues=$(jql_all "project = $PROJECT_KEY AND status = \"To Do\" AND issuetype in ($ids) ORDER BY key" \
        "$(jq -cn --arg f "$vf" '["issuetype", "status", $f]')") \
        || die "could not search $PROJECT_KEY for To Do issues"
    keys=$(printf '%s' "$issues" | jq -r --arg f "$vf" '
        def filled: if . == null then false
            elif type == "string" then test("\\S")
            elif type == "object" then ([.. | objects | select(.type == "text") | .text // ""] | join("") | test("\\S"))
            else true end;
        .[] | select(.fields[$f] | filled) | .key') || die "could not read the To Do search results"
    if [ -z "$keys" ]; then
        echo "pre-drain: no To Do issue in $PROJECT_KEY has verify set — nothing to drain"
        return 0
    fi
    while IFS= read -r key; do
        [ -n "$key" ] || continue
        require_issue_key "$key" || { failed="$failed$key ($WO_JIRA_KEY_ERR), "; continue; }
        if ! trans=$(http_get "/issue/$key/transitions"); then
            echo "pre-drain: FAILED $key — could not read its transitions"
            failed="$failed$key, "; continue
        fi
        tid=$(printf '%s' "$trans" | jq -r '[.transitions[] | select(.to.name == "Open")][0].id // empty')
        if [ -z "$tid" ]; then
            echo "pre-drain: FAILED $key — its current workflow offers no transition into Open"
            failed="$failed$key, "; continue
        fi
        body=$(jq -cn --arg t "$tid" '{transition: {id: $t}}')
        show_write POST "/issue/$key/transitions" "$body"
        CHANGES=$((CHANGES + 1))
        [ "$PLAN" = "1" ] && continue
        if http_post "/issue/$key/transitions" "$body" >/dev/null; then
            echo "pre-drain: moved $key To Do -> Open"
            moved=$((moved + 1))
        else
            echo "pre-drain: FAILED $key — the transition was rejected"
            failed="$failed$key, "
        fi
    done <<EOF
$keys
EOF
    [ -z "$failed" ] || die "pre-drain could not move ${failed%, } to Open — refusing to switch, which would map them to Triage"
    [ "$PLAN" = "1" ] || echo "pre-drain: moved $moved issue(s)"
}

# task_json_from_switch STDOUT STDERR_FILE — the task a switch started. Jira
# answers 303 with the task in the body, which jira-http.sh reports as a failure.
task_json_from_switch() {
    if [ -n "$1" ]; then printf '%s' "$1"; return 0; fi
    [ "$(head -1 "$2")" = "HTTP 303" ] || return 1
    tail -n +2 "$2"
}

# wait_for_task ID — poll GET /task/ID until it finishes; die unless COMPLETE.
wait_for_task() {
    local waited=0 resp status
    while :; do
        resp=$(http_get "/task/$1") || die "could not read GET /task/$1 — check the switch by hand"
        status=$(printf '%s' "$resp" | jq -r '.status // ""')
        case "$status" in
            COMPLETE) echo "switch task $1: COMPLETE"; return 0 ;;
            FAILED|CANCELLED|DEAD)
                printf '%s\n' "$resp" | jq -c '{status, message, result}' >&2 || true
                die "switch task $1 ended $status — the project may be half-switched; check it by hand" ;;
        esac
        [ "$waited" -lt "$TIMEOUT_SECONDS" ] || die "switch task $1 still '$status' after ${TIMEOUT_SECONDS}s — check it by hand"
        sleep "$POLL_SECONDS"
        waited=$((waited + (POLL_SECONDS > 0 ? POLL_SECONDS : 1)))
    done
}

# wait_for_scheme — poll the project's scheme until it is the target. Jira's
# 303 carries the task only in a Location header, which the client drops.
wait_for_scheme() {
    local waited=0 now
    while :; do
        now=$(current_scheme | jq -r '.id // "" | tostring') || die "could not read the workflow scheme of project $PROJECT_KEY while waiting on the switch"
        [ "$now" = "$TARGET_SCHEME_ID" ] && { echo "project $PROJECT_KEY is now on '$TARGET_SCHEME_NAME'"; return 0; }
        [ "$waited" -lt "$TIMEOUT_SECONDS" ] || die "project $PROJECT_KEY is still not on '$TARGET_SCHEME_NAME' after ${TIMEOUT_SECONDS}s — check it by hand"
        sleep "$POLL_SECONDS"
        waited=$((waited + (POLL_SECONDS > 0 ? POLL_SECONDS : 1)))
    done
}

do_switch() {
    local plan body out errf rc task task_id
    echo "project $PROJECT_KEY is on '$CURRENT_SCHEME_NAME' (id $CURRENT_SCHEME_ID)"
    plan=$(build_plan) || exit 1
    printf '%s' "$plan" | jq -r '.[] | "  issue type \(.issueTypeId): \(.oldWorkflow) -> \(.newWorkflow)\(if (.mappings | length) > 0 then "; " + ([.mappings[] | "\(.old) -> \(.new)"] | join(", ")) else "" end)"'
    check_unmapped "$plan"
    pre_drain "$plan"

    body=$(jq -cn --arg p "$PROJECT_ID" --arg t "$TARGET_SCHEME_ID" --argjson plan "$plan" '
        [$plan[] | select((.mappings | length) > 0)
            | {issueTypeId, statusMappings: [.mappings[] | {oldStatusId, newStatusId}]}] as $m
        | {projectId: $p, targetSchemeId: $t}
          + (if ($m | length) > 0 then {mappingsByIssueTypeOverride: $m} else {} end)') \
        || die "could not build the switch request body"
    show_write POST /workflowscheme/project/switch "$body"
    CHANGES=$((CHANGES + 1))
    [ "$PLAN" = "1" ] && return 0

    errf=$(tmpfile) || die "could not create a scratch file"
    set +e
    out=$(http_post /workflowscheme/project/switch "$body" 2>"$errf")
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
        task=$(task_json_from_switch "$out" "$errf") || task=""
    elif grep -q '^HTTP 303' "$errf"; then
        task=$(task_json_from_switch "" "$errf") || task=""
    else
        cat "$errf" >&2; die "POST /workflowscheme/project/switch failed"
    fi
    task_id=$(printf '%s' "$task" | jq -r '[(.id // empty | tostring), ((.self // "") | capture("/task/(?<i>[0-9]+)").i)] | .[0] // empty' 2>/dev/null) || task_id=""
    if [ -n "$task_id" ]; then
        echo "switch task $task_id started"
        wait_for_task "$task_id"
    else
        echo "the switch answered with no task id; waiting for the project's scheme to change"
        wait_for_scheme
    fi
    SWITCHED=1
}

if [ "$CURRENT_SCHEME_ID" = "$TARGET_SCHEME_ID" ]; then
    echo "project $PROJECT_KEY is already on '$TARGET_SCHEME_NAME'"
else
    do_switch
fi

# ---- 5. verify ---------------------------------------------------------

if [ "$PLAN" = "1" ] && [ "$CURRENT_SCHEME_ID" != "$TARGET_SCHEME_ID" ]; then
    echo "verify: runs after the switch (skipped: nothing was sent)"
else
    NOW=$(current_scheme) || die "could not re-read the workflow scheme of project $PROJECT_KEY"
    [ "$(printf '%s' "$NOW" | jq -r '.name // ""')" = "$TARGET_SCHEME_NAME" ] \
        || die "project $PROJECT_KEY is on '$(printf '%s' "$NOW" | jq -r '.name // "?"')', not '$TARGET_SCHEME_NAME'"
    case "$(jql_any "project = $PROJECT_KEY AND status in (\"To Do\", Done)")" in
        no)  echo "verify: $PROJECT_KEY is on '$TARGET_SCHEME_NAME' and no issue is in To Do or Done" ;;
        yes) die "project $PROJECT_KEY still has issues in To Do or Done after the switch" ;;
        *)   die "could not count $PROJECT_KEY issues in To Do or Done" ;;
    esac
fi

# ---- 6. delete the old scheme and workflows ----------------------------

BLOCKED=""
PENDING_SWITCH=0
[ "$SWITCHED" = "1" ] || [ "$CURRENT_SCHEME_ID" = "$TARGET_SCHEME_ID" ] || PENDING_SWITCH=1

# ids_of JSON PATH — the ids listed under PATH (".projects" etc.), one per line.
ids_of() { printf '%s' "$1" | jq -r "($2.values // [])[] | .id | tostring"; }

# drop_line VALUE — copy stdin to stdout without lines equal to VALUE.
drop_line() { awk -v v="$1" '$0 != v'; }

EXPECT_PROJECT=""
[ "$PENDING_SWITCH" = "0" ] || EXPECT_PROJECT="$PROJECT_ID"
EXPECT_SCHEME=""

if OLD_SCHEME=$(scheme_by_name "$OLD_SCHEME_NAME"); then
    OLD_SCHEME_ID=$(printf '%s' "$OLD_SCHEME" | jq -r '.id | tostring')
    USAGE=$(http_get "/workflowscheme/$OLD_SCHEME_ID/projectUsages") \
        || die "could not read the projects using scheme '$OLD_SCHEME_NAME'"
    USERS=$(ids_of "$USAGE" .projects | drop_line "$EXPECT_PROJECT")
    if [ -n "$USERS" ]; then
        BLOCKED="${BLOCKED}scheme '$OLD_SCHEME_NAME' (used by project id(s) $(printf '%s' "$USERS" | tr '\n' ' ')), "
    else
        show_write DELETE "/workflowscheme/$OLD_SCHEME_ID"
        CHANGES=$((CHANGES + 1))
        if [ "$PLAN" = "1" ]; then
            EXPECT_SCHEME="$OLD_SCHEME_ID"
        else
            http_delete "/workflowscheme/$OLD_SCHEME_ID" >/dev/null || die "DELETE /workflowscheme/$OLD_SCHEME_ID failed"
            echo "deleted scheme '$OLD_SCHEME_NAME'"
        fi
    fi
else
    [ $? -eq 1 ] || die "more than one workflow scheme is named '$OLD_SCHEME_NAME' — refusing to guess which to delete"
fi

while IFS= read -r WF; do
    [ -n "$WF" ] || continue
    WF_ID=$(workflow_entity_id "$WF") || die "could not look up workflow '$WF'"
    [ -n "$WF_ID" ] || continue
    WFS=$(http_get "/workflow/$WF_ID/workflowSchemes") || die "could not read the schemes using workflow '$WF'"
    WFP=$(http_get "/workflow/$WF_ID/projectUsages") || die "could not read the projects using workflow '$WF'"
    S_USERS=$(ids_of "$WFS" .workflowSchemes | drop_line "$EXPECT_SCHEME")
    P_USERS=$(ids_of "$WFP" .projects | drop_line "$EXPECT_PROJECT")
    if [ -n "$S_USERS" ] || [ -n "$P_USERS" ]; then
        BLOCKED="${BLOCKED}workflow '$WF' (schemes: $(printf '%s' "$S_USERS" | tr '\n' ' ')projects: $(printf '%s' "$P_USERS" | tr '\n' ' ')), "
        continue
    fi
    show_write DELETE "/workflow/$WF_ID"
    CHANGES=$((CHANGES + 1))
    if [ "$PLAN" != "1" ]; then
        http_delete "/workflow/$WF_ID" >/dev/null || die "DELETE /workflow/$WF_ID ('$WF') failed"
        echo "deleted workflow '$WF'"
    fi
done <<EOF
$OLD_WORKFLOW_NAMES
EOF

[ -z "$BLOCKED" ] || die "still in use, so not deleted: ${BLOCKED%, }"

# ---- summary -----------------------------------------------------------

if [ "$CHANGES" = "0" ]; then
    echo "0 changes: $PROJECT_KEY is on '$TARGET_SCHEME_NAME' and its old workflows and scheme are gone."
    exit 0
fi
if [ "$DRY_RUN" = "1" ]; then
    warn "--dry-run: $CHANGES change(s) planned, none sent."
    exit 0
fi
if [ "$ASSUME_YES" != "1" ]; then
    warn "not confirmed (no --yes): $CHANGES change(s) planned, none sent."
    exit 3
fi
echo "$CHANGES change(s) applied."
