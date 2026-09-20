#!/bin/bash
#
# provider.sh — the work-order tracker provider for Jira Cloud: the four
# verbs a ticket set needs against a tracker, plus the two that make the
# lifecycle mapping in BINDING.md executable rather than documentary.
#
# Usage:
#   provider.sh [--dry-run] [--http PATH] fetch KEY
#   provider.sh [--dry-run] [--http PATH] position KEY
#   provider.sh [--dry-run] [--http PATH] transition KEY POSITION|TRANSITION_ID
#   provider.sh [--dry-run] [--http PATH] comment KEY TEXT
#   provider.sh [--dry-run] [--http PATH] create PROJECT ISSUETYPE SUMMARY
#                                                [--ticket PATH]
#
#   POSITION       one of open, in-progress, awaiting-deployment, completed,
#                  cancelled. Resolved to a transition by the status name
#                  BINDING.md binds it to, read live from the issue.
#   TEXT           '-' reads the comment from stdin.
#   --ticket PATH  a decision-list document (decision-list/FORMAT.md): one
#                  decision object, or a list holding exactly one. Its fields
#                  become the issue's description, labels and custom fields.
#                  SUMMARY may then be empty, and the title comes from it.
#   --http PATH    a jira-http.sh-shaped client. Default: lib/jira-http.sh.
#   --dry-run      print the requests and exit 0, reaching no network.
#
# create resolves every custom field id by name from GET /field at run time
# ([JIRA-8]), over the one field table in lib/common.sh that provision.sh
# creates them from. --dry-run resolves nothing and prints <name> in each
# id's place. blocked_by and epic are not written — see BINDING.md section 5.
#
# transition, comment and create are live writes with no interactive
# confirmation, so the provider works unattended; --dry-run or
# WORK_ORDER_JIRA_DRY_RUN=1 turns every call into a printed request.
#
# bash 3.2 compatible.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$DIR/lib/common.sh"

POSITIONS='open
in-progress
awaiting-deployment
completed
cancelled'
POSITION_STATUSES='Open
In Progress
Awaiting Deployment
Completed
Cancelled'

DRY_RUN=0
[ "${WORK_ORDER_JIRA_DRY_RUN:-0}" = "1" ] && DRY_RUN=1
HTTP=""

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --http)
            [ $# -ge 2 ] || die "--http needs a path"
            HTTP="$2"; shift 2 ;;
        -h|--help)
            sed -n '3,35p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        --) shift; break ;;
        -*) die "unknown flag '$1' — run with --help" ;;
        *) break ;;
    esac
done

[ -n "$HTTP" ] || HTTP="$DIR/lib/jira-http.sh"
[ -x "$HTTP" ] || die "--http path is not an executable file: '$HTTP'"

need jq

# http METHOD PATH [BODY] — the client, with --dry-run threaded through.
http() {
    if [ "$DRY_RUN" = "1" ]; then
        "$HTTP" --dry-run "$@"
    else
        "$HTTP" "$@"
    fi
}

# status_for_position POSITION — print the Jira status name BINDING.md binds
# POSITION to, or return 1 when POSITION is not one of the five.
status_for_position() {
    local want="$1" i=1 p s
    while IFS= read -r p; do
        s=$(printf '%s\n' "$POSITION_STATUSES" | sed -n "${i}p")
        i=$((i + 1))
        [ "$p" = "$want" ] || continue
        printf '%s' "$s"
        return 0
    done <<EOF
$POSITIONS
EOF
    return 1
}

# position_for_status STATUS — the inverse: print the lifecycle position a
# Jira status name represents, or return 1 for a status outside the binding.
position_for_status() {
    local want="$1" i=1 s p
    while IFS= read -r s; do
        p=$(printf '%s\n' "$POSITIONS" | sed -n "${i}p")
        i=$((i + 1))
        [ "$s" = "$want" ] || continue
        printf '%s' "$p"
        return 0
    done <<EOF
$POSITION_STATUSES
EOF
    return 1
}

verb="${1:-}"
[ -n "$verb" ] && shift

case "$verb" in
    fetch)
        [ $# -eq 1 ] || die "usage: provider.sh [--dry-run] fetch KEY"
        require_issue_key "$1" || die "$WO_JIRA_KEY_ERR"
        http GET "/issue/$1"
        ;;

    position)
        [ $# -eq 1 ] || die "usage: provider.sh [--dry-run] position KEY"
        require_issue_key "$1" || die "$WO_JIRA_KEY_ERR"
        if [ "$DRY_RUN" = "1" ]; then
            http GET "/issue/$1?fields=status"
            exit 0
        fi
        ISSUE=$(http GET "/issue/$1?fields=status") \
            || die "could not read issue '$1'"
        STATUS_NAME=$(printf '%s' "$ISSUE" | jq -r '.fields.status.name // empty') \
            || die "could not parse .fields.status.name from the issue readback"
        [ -n "$STATUS_NAME" ] || die "issue '$1' readback carried no status name"
        POS=$(position_for_status "$STATUS_NAME") \
            || die "issue '$1' is in status '$STATUS_NAME', which this binding does not map to a lifecycle position — see BINDING.md [JIRA-3]"
        printf '%s\n' "$POS"
        ;;

    transition)
        [ $# -eq 2 ] || die "usage: provider.sh [--dry-run] transition KEY POSITION|TRANSITION_ID"
        require_issue_key "$1" || die "$WO_JIRA_KEY_ERR"
        TARGET="$2"
        case "$TARGET" in
            *[!0-9]*)
                WANT_STATUS=$(status_for_position "$TARGET") \
                    || die "'$TARGET' is not a lifecycle position (open, in-progress, awaiting-deployment, completed, cancelled) and is not a numeric transition id"
                if [ "$DRY_RUN" = "1" ]; then
                    http GET "/issue/$1/transitions"
                    printf 'WOULD then POST the transition whose .to.name is %s\n' "$WANT_STATUS"
                    exit 0
                fi
                AVAILABLE=$(http GET "/issue/$1/transitions") \
                    || die "could not read the available transitions for '$1'"
                TRANSITION_ID=$(printf '%s' "$AVAILABLE" | jq -r --arg n "$WANT_STATUS" \
                    '[.transitions[]? | select(.to.name == $n)][0].id // empty') \
                    || die "could not parse the transitions response for '$1'"
                [ -n "$TRANSITION_ID" ] \
                    || die "no transition into '$WANT_STATUS' is available on '$1' right now — a workflow validator may be blocking it, or the status is not on this project's workflow (run provision.sh)"
                ;;
            *)
                TRANSITION_ID="$TARGET"
                ;;
        esac
        BODY=$(jq -cn --arg id "$TRANSITION_ID" '{transition: {id: $id}}') \
            || die "could not build the transition request body"
        http POST "/issue/$1/transitions" "$BODY"
        ;;

    comment)
        [ $# -eq 2 ] || die "usage: provider.sh [--dry-run] comment KEY TEXT ('-' reads stdin)"
        require_issue_key "$1" || die "$WO_JIRA_KEY_ERR"
        TEXT="$2"
        if [ "$TEXT" = "-" ]; then
            TEXT=$(cat) || die "could not read the comment text from stdin"
        fi
        [ -n "$TEXT" ] || die "refusing to post an empty comment on '$1'"
        BODY=$(jira_comment_body "$TEXT") \
            || die "could not build the comment ADF document"
        http POST "/issue/$1/comment" "$BODY"
        ;;

    create)
        [ $# -ge 3 ] || die "usage: provider.sh [--dry-run] create PROJECT ISSUETYPE SUMMARY [--ticket PATH]"
        PROJ="$1"; ISSUETYPE="$2"; SUMMARY="$3"
        shift 3
        TICKET_PATH=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --ticket)
                    [ $# -ge 2 ] || die "--ticket needs a path"
                    TICKET_PATH="$2"; shift 2 ;;
                *) die "unexpected argument '$1' after create's three positional arguments" ;;
            esac
        done
        require_project_key "$PROJ" || die "$WO_JIRA_KEY_ERR"

        if [ -z "$TICKET_PATH" ]; then
            [ -n "$SUMMARY" ] || die "a ticket needs a title — SUMMARY was empty (work-order MUST-3)"
            BODY=$(jq -cn --arg proj "$PROJ" --arg type "$ISSUETYPE" --arg summary "$SUMMARY" \
                '{fields: {project: {key: $proj}, issuetype: {name: $type}, summary: $summary}}') \
                || die "could not build the create-issue request body"
            http POST "/issue" "$BODY"
            exit 0
        fi

        [ -f "$TICKET_PATH" ] || die "--ticket path is not a readable file: '$TICKET_PATH'"
        jq -e . "$TICKET_PATH" >/dev/null 2>&1 \
            || die "--ticket '$TICKET_PATH' is not valid JSON"
        COUNT=$(jq -r 'if (type == "object" and has("decisions")) then (.decisions | length) else -1 end' "$TICKET_PATH") \
            || die "could not read '$TICKET_PATH' as a decision list"
        case "$COUNT" in
            -1) TICKET=$(jq -c . "$TICKET_PATH") ;;
            1)  TICKET=$(jq -c '.decisions[0]' "$TICKET_PATH") ;;
            *)  die "'$TICKET_PATH' is a decision list of $COUNT decisions; create writes one issue, so pass one decision object or a one-entry list" ;;
        esac
        [ -n "$TICKET" ] || die "could not read a decision from '$TICKET_PATH'"

        if [ -z "$SUMMARY" ]; then
            SUMMARY=$(printf '%s' "$TICKET" | jq -r '.title // ""') \
                || die "could not read 'title' from '$TICKET_PATH'"
        fi
        [ -n "$SUMMARY" ] || die "a ticket needs a title — SUMMARY was empty and '$TICKET_PATH' carries no 'title' (work-order MUST-3)"

        BADTAG=$(printf '%s' "$TICKET" | jq -r '[(.tags // [])[] | select(test("[[:space:]]"))][0] // empty') \
            || die "could not read 'tags' from '$TICKET_PATH'"
        [ -z "$BADTAG" ] \
            || die "tag '$BADTAG' contains whitespace and a Jira label cannot — see BINDING.md section 2"

        TEXECUTOR=$(printf '%s' "$TICKET" | jq -r '.executor // ""') \
            || die "could not read 'executor' from '$TICKET_PATH'"
        if [ -n "$TEXECUTOR" ] && ! in_list "$TEXECUTOR" "$WO_JIRA_EXECUTOR_OPTIONS"; then
            die "executor '$TEXECUTOR' is not one of: $(printf '%s' "$WO_JIRA_EXECUTOR_OPTIONS" | tr '\n' ' ')"
        fi

        NLINKS=$(printf '%s' "$TICKET" | jq -r '(.blocked_by // []) | length') \
            || die "could not read 'blocked_by' from '$TICKET_PATH'"
        [ "$NLINKS" = "0" ] \
            || warn "blocked_by carries $NLINKS id(s) that create does not write: a Jira issue link needs its target to exist already, so link in a second pass (BINDING.md section 5)"

        if [ "$DRY_RUN" = "1" ]; then
            FIELD_JSON=""
            http GET "/field"
        else
            FIELD_JSON=$(http GET "/field") \
                || die "could not read this site's field list to resolve the custom field ids by name ([JIRA-8])"
        fi

        DESC=$(printf '%s' "$TICKET" | jq -c '
            def para($s): ($s | gsub("\r"; "") | sub("\n+$"; "") | split("\n")
                | map(if . == "" then {type: "paragraph", content: []}
                      else {type: "paragraph", content: [{type: "text", text: .}]} end));
            def head($s): {type: "heading", attrs: {level: 2}, content: [{type: "text", text: $s}]};
            def section($h; $s): if (($s // "") | gsub("[[:space:]]"; "")) == "" then []
                                 else [head($h)] + para($s) end;
            def decisions: if ((.rationale // []) | length) == 0 then []
                else [head("Decisions")] + ([(.rationale // [])[] | para(
                    .choice + (if ((.rejected // []) | length) > 0
                               then " Rejected: " + ((.rejected // []) | join(" ")) else "" end))] | add)
                end;
            (section("Problem"; .problem) + section("Solution"; .solution)
             + decisions + section("Out of scope"; .out_of_scope)) as $c
            | if ($c | length) == 0 then null else {type: "doc", version: 1, content: $c} end') \
            || die "could not build the description document"

        FIELDS=$(printf '%s' "$TICKET" | jq -c --arg proj "$PROJ" --arg type "$ISSUETYPE" --arg summary "$SUMMARY" \
            '{project: {key: $proj}, issuetype: {name: $type}, summary: $summary, labels: (.tags // [])}') \
            || die "could not build the create-issue fields"
        if [ "$DESC" != "null" ]; then
            FIELDS=$(printf '%s' "$FIELDS" | jq -c --argjson d "$DESC" '. + {description: $d}') \
                || die "could not add the description to the create-issue fields"
        fi

        i=1
        while IFS= read -r FNAME; do
            FTYPE=$(list_nth "$WO_JIRA_FIELD_TYPE_KEYS" "$i") || die "the field table in lib/common.sh is malformed"
            i=$((i + 1))
            HAS=$(printf '%s' "$TICKET" | jq -r --arg n "$FNAME" '
                .[$n] as $v
                | if $v == null then "no"
                  elif ($v | type) == "array" then (if ($v | length) > 0 then "yes" else "no" end)
                  elif ($v | type) == "string" then (if ($v | gsub("[[:space:]]"; "")) == "" then "no" else "yes" end)
                  else "yes" end') \
                || die "could not read '$FNAME' from '$TICKET_PATH'"
            [ "$HAS" = "yes" ] || continue
            case "$FTYPE" in
                *:textarea)
                    FTEXT=$(printf '%s' "$TICKET" | jq -r --arg n "$FNAME" '.[$n] | if type == "array" then join("\n") else . end') \
                        || die "could not read '$FNAME' from '$TICKET_PATH'"
                    FVALUE=$(jira_adf_doc "$FTEXT") \
                        || die "could not build the ADF document for '$FNAME'" ;;
                *:select)
                    FVALUE=$(printf '%s' "$TICKET" | jq -c --arg n "$FNAME" '{value: .[$n]}') \
                        || die "could not encode '$FNAME'" ;;
                *:datepicker)
                    FVALUE=$(printf '%s' "$TICKET" | jq -c --arg n "$FNAME" '.[$n]') \
                        || die "could not encode '$FNAME'" ;;
                *)  die "lib/common.sh gives '$FNAME' the type '$FTYPE', which create has no value encoding for" ;;
            esac
            if [ "$DRY_RUN" = "1" ]; then
                FID="<$FNAME>"
            else
                FID=$(printf '%s' "$FIELD_JSON" | jq -r --arg n "$FNAME" '[.[] | select(.custom == true and .name == $n)][0].id // empty') \
                    || die "could not parse this site's field list"
                [ -n "$FID" ] \
                    || die "this site has no custom field named '$FNAME', so the ticket's '$FNAME' cannot be written — run provision.sh ([JIRA-8])"
            fi
            FIELDS=$(printf '%s' "$FIELDS" | jq -c --arg k "$FID" --argjson v "$FVALUE" '. + {($k): $v}') \
                || die "could not add '$FNAME' to the create-issue fields"
        done <<EOF
$WO_JIRA_FIELD_NAMES
EOF

        BODY=$(printf '%s' "$FIELDS" | jq -c '{fields: .}') \
            || die "could not build the create-issue request body"
        if [ "$DRY_RUN" = "1" ]; then
            printf 'WOULD resolve each <name> below to the id this site assigns it, by name, from that listing ([JIRA-8])\n'
        fi
        http POST "/issue" "$BODY"
        ;;

    "")
        die "usage: provider.sh [--dry-run] VERB [ARG...] (verbs: fetch, position, transition, comment, create)"
        ;;
    *)
        die "unknown tracker verb '$verb' (fetch, position, transition, comment, create)"
        ;;
esac
