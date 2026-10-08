#!/bin/bash
#
# provider.sh — the work-order tracker provider for Jira Cloud: the verbs a
# ticket set needs against a tracker, including the two (position, transition)
# that make the lifecycle mapping in BINDING.md executable rather than
# documentary.
#
# Usage:
#   provider.sh [--dry-run] [--http PATH] fetch KEY
#   provider.sh [--dry-run] [--http PATH] position KEY
#   provider.sh [--dry-run] [--http PATH] transition KEY POSITION|TRANSITION_ID
#                                                [--outcome TEXT]
#   provider.sh [--dry-run] [--http PATH] comment KEY TEXT
#   provider.sh [--dry-run] [--http PATH] create PROJECT ISSUETYPE SUMMARY
#                                                [--ticket PATH|-] [--allow-duplicate]
#   provider.sh [--dry-run] [--http PATH] update KEY --ticket PATH|-
#   provider.sh [--dry-run] [--http PATH] link   KEY --blocked-by BLOCKER
#                                                [--replace]
#   provider.sh [--dry-run] [--http PATH] unlink KEY --blocked-by BLOCKER
#   provider.sh [--dry-run] [--http PATH] parent KEY --epic EPIC [--replace]
#
#   POSITION       one of triage, open, in-progress, awaiting-deployment,
#                  deferred, completed, cancelled. Resolved to a transition by
#                  the status name BINDING.md binds it to, read live from the
#                  issue.
#   TEXT           '-' reads the comment from stdin.
#   --outcome TEXT transition only: the ticket's outcome ('-' reads stdin).
#                  Written in its own PUT before the transition, because Jira
#                  ignores a field in a transition body here ([JIRA-7]).
#   --ticket PATH  a decision-list document (decision-list/FORMAT.md): one
#                  decision object, or a list holding exactly one; '-' reads
#                  stdin. Its fields become the issue's description, labels
#                  and custom fields, and verify_fails_today becomes verify's
#                  last line, '# <observation>' ([MUST-10]). For create,
#                  SUMMARY may then be empty, and the title comes from it.
#   --allow-duplicate  create only: skip the duplicate check below.
#   --blocked-by   the issue that blocks KEY, named for the direction so the
#                  call reads like the ticket's blocked_by field.
#   --replace      link: delete a Blocks link in the reversed direction first,
#                  instead of refusing. parent: move KEY from the epic it
#                  already has, instead of refusing.
#   --epic EPIC    the epic KEY belongs to: an issue at hierarchyLevel 1.
#   --http PATH    a jira-http.sh-shaped client. Default: lib/jira-http.sh.
#   --dry-run      print the requests and exit 0, reaching no network.
#
# create resolves every custom field id by name from GET /field at run time
# ([JIRA-8]), over the one field table in lib/common.sh that provision.sh
# creates them from. --dry-run resolves nothing and prints <name> in each
# id's place. blocked_by is not written — see BINDING.md section 5; `link`
# writes the Blocks links in a second pass, once both issues exist. A ticket's
# epic is written as fields.parent when it names an existing issue at
# hierarchyLevel 1, and the created issue is read back; an epic that does not
# exist yet is warned about and left to `parent`; one at any other level is
# refused before any write ([JIRA-20]).
#
# parent reads EPIC and refuses unless it is at hierarchyLevel 1, and refuses a
# KEY that is not a ticket (level 0). A KEY already under EPIC is a no-op, exit
# 0; a KEY under another epic is refused, exit 1, naming it, unless --replace.
# It then writes fields.parent and exits 1 unless KEY reads back under EPIC.
#
# transition to a position the issue already holds is a no-op, exit 0.
# transition --outcome resolves the transition first, so a refusal writes
# nothing; then PUTs outcome as an ADF document, reads the field back, takes the
# transition and reads the status back. A move to cancelled with no --outcome
# and an empty outcome field exits 1 naming --outcome before any write.
#
# update writes each key the decision carries, clears (explicit null) each it
# carries empty, and leaves the rest alone; the description is rewritten only
# from problem, solution and out_of_scope together. epic and blocked_by are not
# written (parent, link). Every written field is read back and compared.
#
# create first searches PROJECT for an open issue (statusCategory not Done)
# whose summary equals SUMMARY exactly. JQL summary matching is fuzzy, so the
# exact comparison is made client-side. A match writes nothing, exits 3 and
# prints the existing issue as {id,key,self}, so a retry is told from a fresh
# create by the exit code.
#
# link reads KEY's issuelinks first. A Blocks link from BLOCKER to KEY already
# there is a no-op, exit 0. The reversed link makes it refuse, exit 1, naming
# the link id, unless --replace deletes it first. After writing it reads KEY
# back and exits 1 unless an inward Blocks entry names BLOCKER. unlink deletes
# the matching link by the id read from KEY and reads back that it is gone.
#
# transition, comment, create, update, link, unlink and parent are live writes
# with no interactive confirmation, so the provider works unattended; --dry-run or
# WORK_ORDER_JIRA_DRY_RUN=1 turns every call into a printed request.
#
# Exit status:
#   0  the verb succeeded.
#   1  a read, a write or an argument failed.
#   3  `create` only: an open issue with this exact summary exists; nothing was
#      written. --allow-duplicate skips the check.
#
# create stdout: a JSON object carrying `.id`, `.key` and `.self` on exit 0 (the
# issue created) and on exit 3 (the existing issue), so `jq -r .key` reads the
# issue either way and the exit code says which it is.
#   4  `position` only: the issue's status is not one this binding binds.
#      Distinct from 1 on purpose, per BINDING.md [JIRA-11]: stdout carries
#      `unmapped-status<TAB><name>` and a caller must not have to match prose
#      to tell this from a failed read.
#
# bash 3.2 compatible.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$DIR/lib/common.sh"

# The seven lifecycle positions of SPEC.md MUST-25 and the status BINDING.md
# section 3 binds each to, in one order.
POSITIONS='triage
open
in-progress
awaiting-deployment
deferred
completed
cancelled'
POSITION_STATUSES='Triage
Open
In Progress
Awaiting Deployment
Deferred
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
            awk 'NR >= 3 && /^# bash 3\.2 compatible/ { exit } NR >= 3' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        --) shift; break ;;
        -*) die "unknown flag '$1' — run with --help" ;;
        *) break ;;
    esac
done

[ -n "$HTTP" ] || HTTP="$DIR/lib/jira-http.sh"
[ -x "$HTTP" ] || die "--http path is not an executable file: '$HTTP'"

need jq
trap tmpclean EXIT
tmpinit || die "could not create a scratch directory"

# http METHOD PATH [BODY] — the client, with --dry-run threaded through.
http() {
    if [ "$DRY_RUN" = "1" ]; then
        "$HTTP" --dry-run "$@"
    else
        "$HTTP" "$@"
    fi
}

# status_for_position POSITION — print the Jira status name BINDING.md binds
# POSITION to, or return 1 when POSITION is not one of the seven.
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

# blocks_ids KEY_JSON DIRECTION BLOCKER — print the ids of the Blocks links on
# an issue's readback. On read, an entry carrying inwardIssue is "is blocked
# by": DIRECTION `inward` selects the BLOCKER-blocks-KEY links, `outward` the
# reversed ones.
blocks_ids() {
    printf '%s' "$1" | jq -r --arg d "$2" --arg b "$3" '
        .fields.issuelinks[]?
        | select(.type.name == "Blocks" and (.[$d + "Issue"].key // "") == $b)
        | .id'
}

# read_links KEY — print the issue readback carrying issuelinks.
read_links() {
    http GET "/issue/$1?fields=issuelinks"
}

# hierarchy_level ISSUE_JSON — print the issue type's hierarchyLevel; only when
# the readback omits it does the type name decide ([JIRA-16]).
hierarchy_level() {
    printf '%s' "$1" | jq -r '
        .fields.issuetype as $t
        | (($t.name // "") | ascii_downcase) as $n
        | if ($t.hierarchyLevel | type) == "number" then $t.hierarchyLevel
          elif $n == "epic" then 1
          elif $n == "sub-task" or $n == "subtask" then -1
          else 0 end'
}

# epic_level EPIC — print EPIC's hierarchyLevel. Returns 3 when EPIC does not
# exist (HTTP 404), and 1 after reporting any other failed read. Call it as
# `x=$(epic_level E) && rc=0 || rc=$?`: inside $( ) a die exits only the
# subshell, so the status is the only signal.
epic_level() {
    local out err
    if ! out=$(tmpfile) || ! err=$(tmpfile); then
        warn "could not create a scratch file"
        return 1
    fi
    if http GET "/issue/$1?fields=issuetype" >"$out" 2>"$err"; then
        hierarchy_level "$(cat "$out")" || { warn "could not parse the issue type of '$1'"; return 1; }
        return 0
    fi
    if grep -q '^HTTP 404' "$err"; then
        return 3
    fi
    cat "$err" >&2
    warn "could not read '$1' to check that it is an epic"
    return 1
}

# adf_text JSON — print every text node of an ADF document, one per line.
adf_text() {
    printf '%s' "$1" | jq -r '[.. | objects | select(.type == "text") | .text] | join("\n")'
}

# outcome_field_id — print this site's id for the custom field named outcome
# ([JIRA-8]); under --dry-run print <outcome> and read nothing.
outcome_field_id() {
    local fields id
    if [ "$DRY_RUN" = "1" ]; then
        http GET "/field" >&2
        printf '<outcome>'
        return 0
    fi
    fields=$(http GET "/field") || die "could not read this site's field list to resolve the outcome field id ([JIRA-8])"
    id=$(printf '%s' "$fields" | jq -r '[.[] | select(.custom == true and .name == "outcome")][0].id // empty') \
        || die "could not parse this site's field list"
    [ -n "$id" ] || die "this site has no custom field named 'outcome' — run provision.sh ([JIRA-7], [JIRA-8])"
    printf '%s' "$id"
}

# open_duplicate PROJECT SUMMARY — print {id,key,self} of an issue in PROJECT
# whose summary equals SUMMARY exactly and whose statusCategory is not Done, or
# nothing. JQL's ~ is fuzzy, so the equality is tested here. The summary is
# escaped for Lucene (backslash before each special character), then for the
# JQL string literal (every backslash doubled, quotes escaped).
open_duplicate() {
    local proj="$1" summary="$2" esc jql page token url hit
    esc=$(printf '%s' "$summary" | jq -Rr 'gsub("(?<c>[-+&|!(){}^~*?:/\\[\\]\\\\])"; "\\" + .c) | gsub("\\\\"; "\\\\") | gsub("\""; "\\\"")')
    jql="project = \"$proj\" AND statusCategory != Done AND summary ~ \"$esc\""
    url="/search/jql?jql=$(printf '%s' "$jql" | jq -sRr @uri)&fields=summary,status&maxResults=100"
    token=""
    if [ "$DRY_RUN" = "1" ]; then
        http GET "$url" >&2
        return 0
    fi
    while :; do
        page=$(http GET "$url${token:+&nextPageToken=$token}") \
            || die "could not search '$proj' for an existing issue titled '$summary'; pass --allow-duplicate to create without the check"
        hit=$(printf '%s' "$page" | jq -r --arg s "$summary" \
            '[.issues[]? | select(.fields.summary == $s and ((.fields.status.statusCategory.key // "") != "done"))][0] | if . == null then empty else {id, key, self} end') \
            || die "could not parse the duplicate-check search response"
        if [ -n "$hit" ]; then printf '%s' "$hit"; return 0; fi
        [ "$(printf '%s' "$page" | jq -r '.isLast // true')" = "false" ] || return 0
        token=$(printf '%s' "$page" | jq -r '.nextPageToken // empty')
        [ -n "$token" ] || return 0
    done
}

# refuse_duplicate PROJECT SUMMARY — print the existing issue as JSON, exit 3.
refuse_duplicate() {
    local dup
    dup=$(open_duplicate "$1" "$2") || exit 1
    [ -z "$dup" ] && return 0
    printf '%s\n' "$dup"
    dup=$(printf '%s' "$dup" | jq -r '.key')
    warn "'$dup' is already open in $1 with the summary '$2'; nothing written (exit 3). Pass --allow-duplicate to create anyway."
    exit 3
}

# read_ticket PATH VERB — set TICKET to the one decision PATH holds: a decision
# object, or a decision list of exactly one ('-' reads stdin).
read_ticket() {
    local path="$1" verb="$2" raw count
    if [ "$path" = "-" ]; then
        raw=$(cat) || die "could not read the decision from stdin"
    else
        [ -f "$path" ] || die "--ticket path is not a readable file: '$path'"
        raw=$(cat "$path") || die "could not read '$path'"
    fi
    printf '%s' "$raw" | jq -e . >/dev/null 2>&1 || die "--ticket '$path' is not valid JSON"
    count=$(printf '%s' "$raw" | jq -r 'if (type == "object" and has("decisions")) then (.decisions | length) else -1 end') \
        || die "could not read '$path' as a decision list"
    case "$count" in
        -1) TICKET=$(printf '%s' "$raw" | jq -c .) ;;
        1)  TICKET=$(printf '%s' "$raw" | jq -c '.decisions[0]') ;;
        *)  die "'$path' is a decision list of $count decisions; $verb writes one issue, so pass one decision object or a one-entry list" ;;
    esac
    [ "$(printf '%s' "$TICKET" | jq -r 'type')" = "object" ] || die "'$path' does not hold a decision object"
}

# check_ticket_values — die on a TICKET value Jira cannot hold: a tag with
# whitespace, an executor outside the three options.
check_ticket_values() {
    local badtag executor
    badtag=$(printf '%s' "$TICKET" | jq -r '[(.tags // [])[] | select(test("[[:space:]]"))][0] // empty') \
        || die "could not read 'tags' from the decision"
    [ -z "$badtag" ] || die "tag '$badtag' contains whitespace and a Jira label cannot — see BINDING.md section 2"
    executor=$(printf '%s' "$TICKET" | jq -r '.executor // ""') || die "could not read 'executor' from the decision"
    if [ -n "$executor" ] && ! in_list "$executor" "$WO_JIRA_EXECUTOR_OPTIONS"; then
        die "executor '$executor' is not one of: $(printf '%s' "$WO_JIRA_EXECUTOR_OPTIONS" | tr '\n' ' ')"
    fi
}

# field_state NAME — absent (TICKET has no such key), empty (null, blank, or an
# empty list) or set.
field_state() {
    printf '%s' "$TICKET" | jq -r --arg n "$1" '
        if has($n) | not then "absent"
        else .[$n] as $v
        | if $v == null then "empty"
          elif ($v | type) == "array" then (if ($v | length) > 0 then "set" else "empty" end)
          elif ($v | type) == "string" then (if ($v | gsub("[[:space:]]"; "")) == "" then "empty" else "set" end)
          else "set" end
        end'
}

# field_value NAME TYPE — print the JSON value TICKET's NAME takes in a field
# of lib/common.sh's TYPE. verify carries verify_fails_today as its last line,
# `# <observation>`, as the file binding's emit-tickets writes it ([MUST-10]).
field_value() {
    local text d
    case "$2" in
        *:textarea)
            text=$(printf '%s' "$TICKET" | jq -r --arg n "$1" '
                . as $t
                | ($t[$n] | if type == "array" then join("\n") else tostring end)
                + (if $n == "verify" and (($t.verify_fails_today // "") | tostring | gsub("[[:space:]]"; "")) != ""
                   then "\n# " + ($t.verify_fails_today | tostring) else "" end)') || return 1
            jira_adf_doc "$text" ;;
        *:select)     printf '%s' "$TICKET" | jq -c --arg n "$1" '{value: .[$n]}' ;;
        *:datepicker)
            d=$(printf '%s' "$TICKET" | jq -r --arg n "$1" '.[$n] | tostring') || return 1
            case "$d" in
                [0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]) ;;
                *) warn "'$1' must be an RFC 3339 full-date, YYYY-MM-DD; got '$d'"; return 1 ;;
            esac
            # Measured on Jira Cloud: a date picker parses the year with a
            # two-digit pivot, and 2046-01-01 reads back as 1946-01-01.
            if [ "${d%%-*}" -ge $(( $(date +%Y) + 20 )) ]; then
                warn "'$1' $d is 20 or more years out, and Jira would store it as 19${d:2:2}; refused"
                return 1
            fi
            printf '"%s"' "$d" ;;
        *) return 1 ;;
    esac
}

# ticket_description — print TICKET's problem, solution, decisions and out of
# scope as one ADF document, one heading per part, or null when it has none.
ticket_description() {
    printf '%s' "$TICKET" | jq -c '
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
        | if ($c | length) == 0 then null else {type: "doc", version: 1, content: $c} end'
}

# read_field_list — set FIELD_JSON to this site's GET /field; under --dry-run
# print the request instead.
read_field_list() {
    if [ "$DRY_RUN" = "1" ]; then
        FIELD_JSON=""
        http GET "/field"
    else
        FIELD_JSON=$(http GET "/field") \
            || die "could not read this site's field list to resolve the custom field ids by name ([JIRA-8])"
    fi
}

# custom_field_id NAME — print the id this site gives the custom field NAME
# ([JIRA-8]), <NAME> under --dry-run. Call as `x=$(custom_field_id N) || exit 1`.
custom_field_id() {
    local id
    if [ "$DRY_RUN" = "1" ]; then
        printf '<%s>' "$1"
        return 0
    fi
    id=$(printf '%s' "$FIELD_JSON" | jq -r --arg n "$1" '[.[] | select(.custom == true and .name == $n)][0].id // empty') \
        || die "could not parse this site's field list"
    [ -n "$id" ] || die "this site has no custom field named '$1', so the ticket's '$1' cannot be written — run provision.sh ([JIRA-8])"
    printf '%s' "$id"
}

# add_contract_fields MODE — add to FIELDS, under its site id, each field of
# lib/common.sh's table TICKET sets, and append its name to WROTE. MODE update
# also clears, with an explicit null, a field TICKET gives as empty: Jira keeps
# the stored value of a key a PUT omits.
add_contract_fields() {
    local i=1 name type value fid
    while IFS= read -r name; do
        type=$(list_nth "$WO_JIRA_FIELD_TYPE_KEYS" "$i") || die "the field table in lib/common.sh is malformed"
        i=$((i + 1))
        case "$1:$(field_state "$name")" in
            *:set)
                value=$(field_value "$name" "$type") \
                    || die "could not encode '$name' as lib/common.sh's '$type'" ;;
            update:empty) value=null ;;
            *) continue ;;
        esac
        fid=$(custom_field_id "$name") || exit 1
        FIELDS=$(printf '%s' "$FIELDS" | jq -c --arg k "$fid" --argjson v "$value" '. + {($k): $v}') \
            || die "could not add '$name' to the request fields"
        WROTE="$WROTE $name"
    done <<EOF
$WO_JIRA_FIELD_NAMES
EOF
}

# comparable JSON — a field value as the text a write and its read-back are
# compared on: an ADF document's text, a select's value, a sorted list, and
# null as empty.
comparable() {
    printf '%s' "$1" | jq -r '
        if . == null then ""
        elif type == "object" and .type == "doc" then [.. | objects | select(.type == "text") | .text] | join("\n")
        elif type == "object" and has("value") then .value
        elif type == "array" then (map(tostring) | sort | join(","))
        else tostring end'
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
        # Exit 4, not 1: an unmapped status is a report about the issue, and a
        # caller must be able to tell it from a read that failed without
        # matching this message. BINDING.md [JIRA-11].
        if POS=$(position_for_status "$STATUS_NAME"); then
            printf '%s\n' "$POS"
        else
            printf 'unmapped-status\t%s\n' "$STATUS_NAME"
            warn "issue '$1' is in status '$STATUS_NAME', which this binding does not bind to a lifecycle position — see BINDING.md [JIRA-3]. Reported, not failed: exit 4."
            exit 4
        fi
        ;;

    transition)
        [ $# -ge 2 ] || die "usage: provider.sh [--dry-run] transition KEY POSITION|TRANSITION_ID [--outcome TEXT]"
        require_issue_key "$1" || die "$WO_JIRA_KEY_ERR"
        TKEY="$1"; TARGET="$2"; shift 2
        OUTCOME=""; HAVE_OUTCOME=0
        while [ $# -gt 0 ]; do
            case "$1" in
                --outcome)
                    [ $# -ge 2 ] || die "--outcome needs a text ('-' reads stdin)"
                    OUTCOME="$2"; HAVE_OUTCOME=1; shift 2 ;;
                *) die "unexpected argument '$1' after transition's KEY and target" ;;
            esac
        done
        if [ "$HAVE_OUTCOME" = "1" ]; then
            if [ "$OUTCOME" = "-" ]; then
                OUTCOME=$(cat) || die "could not read the outcome from stdin"
            fi
            [ -n "$OUTCOME" ] || die "refusing an empty --outcome for '$TKEY'"
        fi
        WANT_STATUS=""
        case "$TARGET" in
            *[!0-9]*)
                WANT_STATUS=$(status_for_position "$TARGET") \
                    || die "'$TARGET' is not a lifecycle position (triage, open, in-progress, awaiting-deployment, deferred, completed, cancelled) and is not a numeric transition id"
                if [ "$DRY_RUN" = "1" ]; then
                    http GET "/issue/$TKEY?fields=status"
                    printf 'WOULD stop there, exit 0, if %s is already %s\n' "$TKEY" "$WANT_STATUS"
                    http GET "/issue/$TKEY/transitions"
                    printf 'WOULD then POST the transition whose .to.name is %s\n' "$WANT_STATUS"
                    TRANSITION_ID="<id>"
                else
                    BEFORE=$(http GET "/issue/$TKEY?fields=status") || die "could not read the status of '$TKEY'"
                    if [ "$(printf '%s' "$BEFORE" | jq -r '.fields.status.name // empty')" = "$WANT_STATUS" ]; then
                        printf '%s is already %s\n' "$TKEY" "$WANT_STATUS"
                        exit 0
                    fi
                    AVAILABLE=$(http GET "/issue/$TKEY/transitions") \
                        || die "could not read the available transitions for '$TKEY'"
                    TRANSITION_ID=$(printf '%s' "$AVAILABLE" | jq -r --arg n "$WANT_STATUS" \
                        '[.transitions[]? | select(.to.name == $n)][0].id // empty') \
                        || die "could not parse the transitions response for '$TKEY'"
                    [ -n "$TRANSITION_ID" ] \
                        || die "no transition into '$WANT_STATUS' is available on '$TKEY' right now — a workflow validator may be blocking it, or the status is not on this project's workflow (run provision.sh)"
                fi
                ;;
            *)
                TRANSITION_ID="$TARGET"
                ;;
        esac

        OFID=""
        if [ "$HAVE_OUTCOME" = "1" ] || [ "$WANT_STATUS" = "Cancelled" ]; then
            OFID=$(outcome_field_id) || exit 1
        fi

        if [ "$HAVE_OUTCOME" = "0" ] && [ "$WANT_STATUS" = "Cancelled" ]; then
            if [ "$DRY_RUN" = "1" ]; then
                http GET "/issue/$TKEY?fields=$OFID"
                printf 'WOULD refuse, exit 1, unless that field is already set or --outcome is given\n'
            else
                CURRENT=$(http GET "/issue/$TKEY?fields=$OFID") \
                    || die "could not read the outcome field of '$TKEY'"
                HAVE=$(printf '%s' "$CURRENT" | jq -r --arg f "$OFID" '(.fields[$f] // null) | if . == null then "" else tostring end')
                [ -n "$HAVE" ] && [ -n "$(adf_text "$(printf '%s' "$CURRENT" | jq -c --arg f "$OFID" '.fields[$f]')" | tr -d '[:space:]')" ] \
                    || die "cancelling '$TKEY' needs an outcome ([JIRA-7]) and its outcome field is empty; nothing written. Pass --outcome TEXT"
            fi
        fi

        if [ "$HAVE_OUTCOME" = "1" ]; then
            ODOC=$(jira_adf_doc "$OUTCOME") || die "could not build the outcome ADF document"
            OBODY=$(jq -cn --arg f "$OFID" --argjson d "$ODOC" '{fields: {($f): $d}}') \
                || die "could not build the outcome request body"
            if [ "$DRY_RUN" = "1" ]; then
                http PUT "/issue/$TKEY" "$OBODY"
                http GET "/issue/$TKEY?fields=$OFID"
            else
                http PUT "/issue/$TKEY" "$OBODY" >/dev/null || die "could not write the outcome of '$TKEY'; no transition was taken"
                BACK=$(http GET "/issue/$TKEY?fields=$OFID") || die "could not read the outcome of '$TKEY' back; no transition was taken"
                GOT=$(adf_text "$(printf '%s' "$BACK" | jq -c --arg f "$OFID" '.fields[$f] // {}')") \
                    || die "could not parse the outcome read-back of '$TKEY'"
                [ "$GOT" = "$(adf_text "$ODOC")" ] \
                    || die "read-back of '$TKEY' does not show the outcome that was written; no transition was taken"
            fi
        fi

        BODY=$(jq -cn --arg id "$TRANSITION_ID" '{transition: {id: $id}}') \
            || die "could not build the transition request body"
        http POST "/issue/$TKEY/transitions" "$BODY"
        if [ "$DRY_RUN" = "1" ]; then
            http GET "/issue/$TKEY?fields=status"
        else
            AFTER=$(http GET "/issue/$TKEY?fields=status") || die "could not read '$TKEY' back after the transition"
            NOW=$(printf '%s' "$AFTER" | jq -r '.fields.status.name // empty') \
                || die "could not parse the status read-back of '$TKEY'"
            if [ -n "$WANT_STATUS" ] && [ "$NOW" != "$WANT_STATUS" ]; then
                die "read-back of '$TKEY' shows status '$NOW', not '$WANT_STATUS'; the transition did not take"
            fi
            printf '%s is now %s\n' "$TKEY" "$NOW"
        fi
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
        [ $# -ge 3 ] || die "usage: provider.sh [--dry-run] create PROJECT ISSUETYPE SUMMARY [--ticket PATH|-] [--allow-duplicate]"
        PROJ="$1"; ISSUETYPE="$2"; SUMMARY="$3"
        shift 3
        TICKET_PATH=""; ALLOW_DUP=0
        while [ $# -gt 0 ]; do
            case "$1" in
                --allow-duplicate) ALLOW_DUP=1; shift ;;
                --ticket)
                    [ $# -ge 2 ] || die "--ticket needs a path ('-' reads stdin)"
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
            [ "$ALLOW_DUP" = "1" ] || refuse_duplicate "$PROJ" "$SUMMARY"
            http POST "/issue" "$BODY"
            exit 0
        fi

        read_ticket "$TICKET_PATH" create
        if [ -z "$SUMMARY" ]; then
            SUMMARY=$(printf '%s' "$TICKET" | jq -r '.title // ""') \
                || die "could not read 'title' from '$TICKET_PATH'"
        fi
        [ -n "$SUMMARY" ] || die "a ticket needs a title — SUMMARY was empty and '$TICKET_PATH' carries no 'title' (work-order MUST-3)"

        [ "$ALLOW_DUP" = "1" ] || refuse_duplicate "$PROJ" "$SUMMARY"

        check_ticket_values

        NLINKS=$(printf '%s' "$TICKET" | jq -r '(.blocked_by // []) | length') \
            || die "could not read 'blocked_by' from '$TICKET_PATH'"
        [ "$NLINKS" = "0" ] \
            || warn "blocked_by carries $NLINKS id(s) that create does not write: a Jira issue link needs its target to exist already, so run 'provider.sh link KEY --blocked-by BLOCKER' for each in a second pass (BINDING.md section 5)"

        TEPIC=$(printf '%s' "$TICKET" | jq -r '.epic | if type == "object" then (.key // "") elif type == "string" then . else "" end') \
            || die "could not read 'epic' from '$TICKET_PATH'"
        PARENT=""
        if [ -n "$TEPIC" ]; then
            if ! require_issue_key "$TEPIC"; then
                warn "epic '$TEPIC' is not a Jira issue key, so create writes no parent; once the epic is filed, run 'provider.sh parent KEY --epic EPIC'"
            elif [ "$DRY_RUN" = "1" ]; then
                http GET "/issue/$TEPIC?fields=issuetype"
                printf 'WOULD send fields.parent %s if it reads back at hierarchyLevel 1, leave it out with a warning if it does not exist, and refuse at any other level\n' "$TEPIC"
                PARENT="$TEPIC"
            else
                LEVEL=$(epic_level "$TEPIC") && rc=0 || rc=$?
                case "$rc" in
                    0)  [ "$LEVEL" = "1" ] \
                            || die "the ticket's epic '$TEPIC' is at hierarchyLevel $LEVEL, not an epic (1); nothing written ([JIRA-20])"
                        PARENT="$TEPIC" ;;
                    3)  warn "epic '$TEPIC' does not exist yet, so create writes no parent; once it does, run 'provider.sh parent KEY --epic $TEPIC'" ;;
                    *)  exit 1 ;;
                esac
            fi
        fi

        read_field_list

        DESC=$(ticket_description) || die "could not build the description document"
        FIELDS=$(printf '%s' "$TICKET" | jq -c --arg proj "$PROJ" --arg type "$ISSUETYPE" --arg summary "$SUMMARY" \
            '{project: {key: $proj}, issuetype: {name: $type}, summary: $summary, labels: (.tags // [])}') \
            || die "could not build the create-issue fields"
        if [ "$DESC" != "null" ]; then
            FIELDS=$(printf '%s' "$FIELDS" | jq -c --argjson d "$DESC" '. + {description: $d}') \
                || die "could not add the description to the create-issue fields"
        fi
        if [ -n "$PARENT" ]; then
            FIELDS=$(printf '%s' "$FIELDS" | jq -c --arg p "$PARENT" '. + {parent: {key: $p}}') \
                || die "could not add the epic to the create-issue fields"
        fi
        WROTE=""
        add_contract_fields create

        BODY=$(printf '%s' "$FIELDS" | jq -c '{fields: .}') \
            || die "could not build the create-issue request body"
        if [ "$DRY_RUN" = "1" ]; then
            printf 'WOULD resolve each <name> below to the id this site assigns it, by name, from that listing ([JIRA-8])\n'
            http POST "/issue" "$BODY"
            [ -z "$PARENT" ] || http GET "/issue/<created key>?fields=parent"
            exit 0
        fi
        CREATED=$(http POST "/issue" "$BODY") || exit 1
        printf '%s\n' "$CREATED"
        if [ -n "$PARENT" ]; then
            NEWKEY=$(printf '%s' "$CREATED" | jq -r '.key // empty') \
                || die "could not parse the created issue's key to read its epic back"
            [ -n "$NEWKEY" ] || die "the create response carried no key, so its epic '$PARENT' could not be read back"
            BACK=$(http GET "/issue/$NEWKEY?fields=parent") \
                || die "created '$NEWKEY' but could not read its epic back; run 'provider.sh parent $NEWKEY --epic $PARENT'"
            [ "$(printf '%s' "$BACK" | jq -r '.fields.parent.key // empty')" = "$PARENT" ] \
                || die "created '$NEWKEY' but its read-back shows no epic '$PARENT'; run 'provider.sh parent $NEWKEY --epic $PARENT'"
        fi
        ;;

    update)
        [ $# -ge 1 ] || die "usage: provider.sh [--dry-run] update KEY --ticket PATH|-"
        UKEY="$1"; shift
        require_issue_key "$UKEY" || die "$WO_JIRA_KEY_ERR"
        TICKET_PATH=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --ticket)
                    [ $# -ge 2 ] || die "--ticket needs a path ('-' reads stdin)"
                    TICKET_PATH="$2"; shift 2 ;;
                *) die "unexpected argument '$1' after update's KEY" ;;
            esac
        done
        [ -n "$TICKET_PATH" ] || die "update needs --ticket PATH|-: the fields to write come from a decision document"
        read_ticket "$TICKET_PATH" update
        check_ticket_values

        for k in epic blocked_by; do
            if [ "$(printf '%s' "$TICKET" | jq -r --arg k "$k" 'has($k)')" = "true" ]; then
                case "$k" in
                    epic) warn "update does not write epic; run 'provider.sh parent $UKEY --epic EPIC'" ;;
                    *)    warn "update does not write blocked_by; run 'provider.sh link $UKEY --blocked-by BLOCKER' or unlink" ;;
                esac
            fi
        done
        [ "$(field_state verify_fails_today)" = "absent" ] || [ "$(field_state verify)" = "set" ] \
            || die "verify_fails_today is written as verify's last line, so it needs verify beside it; nothing written"

        FIELDS='{}'
        WROTE=""
        case "$(field_state title)" in
            set)   FIELDS=$(printf '%s' "$TICKET" | jq -c '{summary: .title}') || die "could not encode 'title'"
                   WROTE=" title" ;;
            empty) die "a ticket needs a title — 'title' is empty (work-order MUST-3); nothing written" ;;
        esac
        if [ "$(field_state tags)" != "absent" ]; then
            FIELDS=$(printf '%s' "$FIELDS" | jq -c --argjson t "$TICKET" '. + {labels: ($t.tags // [])}') \
                || die "could not encode 'tags'"
            WROTE="$WROTE tags"
        fi
        DPARTS=$(printf '%s' "$TICKET" | jq -r '. as $t | [("problem", "solution", "rationale", "out_of_scope") | select(. as $k | $t | has($k))] | join(" ")') \
            || die "could not read the description parts from the decision"
        if [ -n "$DPARTS" ]; then
            for k in problem solution out_of_scope; do
                [ "$(field_state "$k")" = "set" ] \
                    || die "update rewrites the description whole, so it needs problem, solution and out_of_scope together; '$k' is missing or empty; nothing written"
            done
            DESC=$(ticket_description) || die "could not build the description document"
            FIELDS=$(printf '%s' "$FIELDS" | jq -c --argjson d "$DESC" '. + {description: $d}') \
                || die "could not add the description"
            WROTE="$WROTE description"
        fi

        read_field_list
        add_contract_fields update
        [ "$FIELDS" != '{}' ] \
            || die "the decision carries no field update writes (title, tags, the description parts, or a field of lib/common.sh's table); nothing written"

        BODY=$(printf '%s' "$FIELDS" | jq -c '{fields: .}') || die "could not build the update request body"
        if [ "$DRY_RUN" = "1" ]; then
            printf 'WOULD resolve each <name> below to the id this site assigns it, by name, from that listing ([JIRA-8])\n'
            http PUT "/issue/$UKEY" "$BODY"
            http GET "/issue/$UKEY?fields=$(printf '%s' "$FIELDS" | jq -r 'keys | join(",")')"
            exit 0
        fi
        http PUT "/issue/$UKEY" "$BODY" >/dev/null || die "could not update '$UKEY'"
        BACK=$(http GET "/issue/$UKEY?fields=$(printf '%s' "$FIELDS" | jq -r 'keys | join(",")')") \
            || die "updated '$UKEY' but could not read it back"
        BAD=""
        for k in $(printf '%s' "$FIELDS" | jq -r 'keys[]'); do
            SENT=$(printf '%s' "$FIELDS" | jq -c --arg k "$k" '.[$k]')
            GOT=$(printf '%s' "$BACK" | jq -c --arg k "$k" '.fields[$k] // null')
            [ "$(comparable "$SENT")" = "$(comparable "$GOT")" ] \
                || BAD="$BAD $(printf '%s' "$FIELD_JSON" | jq -r --arg k "$k" '[.[] | select(.id == $k)][0].name // $k')"
        done
        [ -z "$BAD" ] || die "read-back of '$UKEY' does not show what was written for:$BAD"
        printf '%s updated:%s\n' "$UKEY" "$WROTE"
        ;;

    link|unlink)
        [ $# -ge 1 ] || die "usage: provider.sh [--dry-run] $verb KEY --blocked-by BLOCKER$([ "$verb" = link ] && printf ' [--replace]')"
        LKEY="$1"; shift
        require_issue_key "$LKEY" || die "$WO_JIRA_KEY_ERR"
        BLOCKER=""; REPLACE=0
        while [ $# -gt 0 ]; do
            case "$1" in
                --blocked-by)
                    [ $# -ge 2 ] || die "--blocked-by needs an issue key"
                    BLOCKER="$2"; shift 2 ;;
                --replace)
                    [ "$verb" = "link" ] || die "--replace belongs to link, not $verb"
                    REPLACE=1; shift ;;
                *) die "unexpected argument '$1' after $verb's KEY" ;;
            esac
        done
        [ -n "$BLOCKER" ] || die "$verb needs --blocked-by BLOCKER: the direction is named, never taken from argument order"
        require_issue_key "$BLOCKER" || die "$WO_JIRA_KEY_ERR"
        [ "$BLOCKER" != "$LKEY" ] || die "an issue cannot block itself: '$LKEY'"

        LBODY=$(jq -cn --arg k "$LKEY" --arg b "$BLOCKER" \
            '{type: {name: "Blocks"}, inwardIssue: {key: $b}, outwardIssue: {key: $k}}') \
            || die "could not build the issue link request body"

        if [ "$DRY_RUN" = "1" ]; then
            read_links "$LKEY"
            if [ "$verb" = "link" ]; then
                [ "$REPLACE" = "0" ] || printf 'WOULD first DELETE /issueLink/<id> for any Blocks link where %s blocks %s\n' "$LKEY" "$BLOCKER"
                http POST "/issueLink" "$LBODY"
            else
                printf 'WOULD DELETE /issueLink/<id> for each Blocks link where %s blocks %s\n' "$BLOCKER" "$LKEY"
            fi
            read_links "$LKEY"
            exit 0
        fi

        CURRENT=$(read_links "$LKEY") || die "could not read the issue links of '$LKEY'"
        SAME=$(blocks_ids "$CURRENT" inward "$BLOCKER") || die "could not parse the issue links of '$LKEY'"
        REVERSED=$(blocks_ids "$CURRENT" outward "$BLOCKER") || die "could not parse the issue links of '$LKEY'"

        if [ "$verb" = "unlink" ]; then
            if [ -z "$SAME" ]; then
                [ -z "$REVERSED" ] \
                    || warn "'$LKEY' blocks '$BLOCKER' (link id $(printf '%s' "$REVERSED" | tr '\n' ' ')), which is the reverse of what was asked; left alone"
                printf '%s is not blocked by %s; nothing to unlink\n' "$LKEY" "$BLOCKER"
                exit 0
            fi
            for LID in $SAME; do
                http DELETE "/issueLink/$LID" >/dev/null || die "could not delete issue link $LID"
            done
            AFTER=$(read_links "$LKEY") || die "could not read '$LKEY' back after unlinking"
            [ -z "$(blocks_ids "$AFTER" inward "$BLOCKER")" ] \
                || die "read-back of '$LKEY' still shows a Blocks link from '$BLOCKER' after the delete"
            printf 'unlinked %s from blocked-by %s\n' "$LKEY" "$BLOCKER"
            exit 0
        fi

        if [ -n "$SAME" ]; then
            printf '%s is already blocked by %s\n' "$LKEY" "$BLOCKER"
            exit 0
        fi
        if [ -n "$REVERSED" ]; then
            [ "$REPLACE" = "1" ] \
                || die "'$LKEY' already blocks '$BLOCKER' (link id $(printf '%s' "$REVERSED" | tr '\n' ' ')), the reverse of what was asked; Jira accepts a second link without correcting the first, so pass --replace to delete it first"
            for LID in $REVERSED; do
                http DELETE "/issueLink/$LID" >/dev/null || die "could not delete the reversed issue link $LID"
            done
        fi
        http POST "/issueLink" "$LBODY" >/dev/null || die "could not create the Blocks link"
        AFTER=$(read_links "$LKEY") || die "could not read '$LKEY' back after linking"
        [ -n "$(blocks_ids "$AFTER" inward "$BLOCKER")" ] \
            || die "read-back of '$LKEY' shows no inward Blocks link naming '$BLOCKER'; the link was not written"
        printf 'linked %s blocked-by %s\n' "$LKEY" "$BLOCKER"
        ;;

    parent)
        [ $# -ge 1 ] || die "usage: provider.sh [--dry-run] parent KEY --epic EPIC [--replace]"
        PKEY="$1"; shift
        require_issue_key "$PKEY" || die "$WO_JIRA_KEY_ERR"
        EPIC=""; REPLACE=0
        while [ $# -gt 0 ]; do
            case "$1" in
                --epic)
                    [ $# -ge 2 ] || die "--epic needs an issue key"
                    EPIC="$2"; shift 2 ;;
                --replace) REPLACE=1; shift ;;
                *) die "unexpected argument '$1' after parent's KEY" ;;
            esac
        done
        [ -n "$EPIC" ] || die "parent needs --epic EPIC: the epic is named, never taken from argument order"
        require_issue_key "$EPIC" || die "$WO_JIRA_KEY_ERR"
        [ "$EPIC" != "$PKEY" ] || die "an issue cannot be its own epic: '$PKEY'"
        PBODY=$(jq -cn --arg e "$EPIC" '{fields: {parent: {key: $e}}}') \
            || die "could not build the parent request body"

        if [ "$DRY_RUN" = "1" ]; then
            http GET "/issue/$EPIC?fields=issuetype"
            http GET "/issue/$PKEY?fields=parent,issuetype"
            printf 'WOULD refuse unless %s is at hierarchyLevel 1 and %s at 0, and unless %s is under no other epic or --replace is given\n' "$EPIC" "$PKEY" "$PKEY"
            http PUT "/issue/$PKEY" "$PBODY"
            http GET "/issue/$PKEY?fields=parent"
            exit 0
        fi

        LEVEL=$(epic_level "$EPIC") && rc=0 || rc=$?
        case "$rc" in
            0) [ "$LEVEL" = "1" ] || die "'$EPIC' is at hierarchyLevel $LEVEL, not an epic (1); nothing written ([JIRA-20])" ;;
            3) die "epic '$EPIC' does not exist; nothing written" ;;
            *) exit 1 ;;
        esac
        CURRENT=$(http GET "/issue/$PKEY?fields=parent,issuetype") || die "could not read '$PKEY'"
        LEVEL=$(hierarchy_level "$CURRENT") || die "could not parse the issue type of '$PKEY'"
        [ "$LEVEL" = "0" ] \
            || die "'$PKEY' is at hierarchyLevel $LEVEL; only a ticket (0) belongs to an epic ([JIRA-16], [JIRA-20])"
        HAVE=$(printf '%s' "$CURRENT" | jq -r '.fields.parent.key // empty') \
            || die "could not parse the parent of '$PKEY'"
        if [ "$HAVE" = "$EPIC" ]; then
            printf '%s is already under epic %s\n' "$PKEY" "$EPIC"
            exit 0
        fi
        [ -z "$HAVE" ] || [ "$REPLACE" = "1" ] \
            || die "'$PKEY' is already under epic '$HAVE'; pass --replace to move it to '$EPIC'"
        http PUT "/issue/$PKEY" "$PBODY" >/dev/null || die "could not write the epic of '$PKEY'"
        AFTER=$(http GET "/issue/$PKEY?fields=parent") || die "could not read '$PKEY' back after setting its epic"
        GOT=$(printf '%s' "$AFTER" | jq -r '.fields.parent.key // empty') \
            || die "could not parse the parent read-back of '$PKEY'"
        [ "$GOT" = "$EPIC" ] \
            || die "read-back of '$PKEY' shows epic '${GOT:-none}', not '$EPIC'; the parent was not written"
        printf '%s is now under epic %s\n' "$PKEY" "$EPIC"
        ;;

    "")
        die "usage: provider.sh [--dry-run] VERB [ARG...] (verbs: fetch, position, transition, comment, create, update, link, unlink, parent)"
        ;;
    *)
        die "unknown tracker verb '$verb' (fetch, position, transition, comment, create, update, link, unlink, parent)"
        ;;
esac
