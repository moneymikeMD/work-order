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
#
#   POSITION       one of open, in-progress, awaiting-deployment, completed,
#                  cancelled. Resolved to a transition by the status name
#                  BINDING.md binds it to, read live from the issue.
#   TEXT           '-' reads the comment from stdin.
#   --http PATH    a jira-http.sh-shaped client. Default: lib/jira-http.sh.
#   --dry-run      print the requests and exit 0, reaching no network.
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
            sed -n '3,27p' "$0" | sed 's/^# \{0,1\}//'
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
        [ $# -eq 3 ] || die "usage: provider.sh [--dry-run] create PROJECT ISSUETYPE SUMMARY"
        require_project_key "$1" || die "$WO_JIRA_KEY_ERR"
        [ -n "$3" ] || die "a ticket needs a title — SUMMARY was empty (work-order MUST-3)"
        BODY=$(jq -cn --arg proj "$1" --arg type "$2" --arg summary "$3" \
            '{fields: {project: {key: $proj}, issuetype: {name: $type}, summary: $summary}}') \
            || die "could not build the create-issue request body"
        http POST "/issue" "$BODY"
        ;;

    "")
        die "usage: provider.sh [--dry-run] VERB [ARG...] (verbs: fetch, position, transition, comment, create)"
        ;;
    *)
        die "unknown tracker verb '$verb' (fetch, position, transition, comment, create)"
        ;;
esac
