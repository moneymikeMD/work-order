#!/bin/bash
#
# acceptance.sh — the live acceptance suite for this binding: every flow in
# GOLDEN-FLOWS.md, run end to end against a scratch Jira project, the way a
# session runs it. Run before every work-order-jira release; the offline
# selftests stay the unit tests.
#
# Usage:
#   acceptance.sh --project KEY [--keep] [--http PATH]
#
#   --project KEY  the scratch project. Refused unless its description carries
#                  the line "work-order-jira acceptance scratch project" and it
#                  is on the Universal Managed tier: the suite files, moves and
#                  closes issues, and must never reach a project that matters.
#   --keep         leave this run's issues open, for a look after a failure.
#   --http PATH    a jira-http.sh-shaped client. Default: lib/jira-http.sh,
#                  which reads WORK_ORDER_JIRA_BASE_URL, _EMAIL and _TOKEN.
#
# Every issue it files is labelled wo-acceptance and wo-acc-<run>. Before the
# flows it closes anything an earlier run left open; after them it deletes this
# run's issues when the credential holds DELETE_ISSUES in KEY, and otherwise
# cancels each one still open, with an outcome. Its last check is that nothing in
# KEY is left open.
#
# Flow 5 runs night-watchman's waves.py when a checkout is found, at
# $NIGHT_WATCHMAN_ROOT or beside this repository, and reports a skip otherwise.
#
# Exit status: 0 every flow passed; 1 a flow failed; 2 a precondition failed
# and no flow ran.
#
# bash 3.2 compatible. Named so CI's *selftest* glob never runs it: it needs a
# credential and a live site.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

# stop MESSAGE — report MESSAGE and exit 2: nothing was run.
stop() { warn "$1"; exit 2; }

MARKER="work-order-jira acceptance scratch project"
PROJ=""; KEEP=0; HTTP="$HERE/lib/jira-http.sh"
while [ $# -gt 0 ]; do
    case "$1" in
        --project) [ $# -ge 2 ] || stop "--project needs a KEY"; PROJ="$2"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        --http) [ $# -ge 2 ] || stop "--http needs a path"; HTTP="$2"; shift 2 ;;
        -h|--help) awk 'NR >= 3 && /^# bash 3\.2 compatible/ { exit } NR >= 3' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) stop "unknown argument '$1' — run with --help" ;;
    esac
done
[ -n "$PROJ" ] || stop "--project KEY is required"
require_project_key "$PROJ" || stop "$WO_JIRA_KEY_ERR"
for c in jq python3; do command -v "$c" >/dev/null 2>&1 || stop "required command not found: $c"; done
[ -x "$HTTP" ] || stop "--http path is not an executable file: '$HTTP'"

trap tmpclean EXIT
tmpinit || stop "could not create a scratch directory"
WORK="$WO_JIRA_TMPDIR"

PROVIDER="$HERE/provider.sh"
ISSUES_PY="$ROOT/reference/issues.py"
EMIT_PY="$ROOT/skills/emit-tickets/emit.py"
ISSUES_API="$HERE/issues-api.sh"
export ISSUES_API_HTTP="$HTTP"

RUN="$(date +%Y%m%d%H%M%S)-$$"
LABEL="wo-acc-$RUN"
SOON=$(jq -rn 'now + 45 * 86400 | strftime("%Y-%m-%d")')
MADE=""

# ---- helpers ---------------------------------------------------------------

# run CMD... — run CMD; its stdout lands in OUT, its stderr in ERR, status in RC.
run() {
    local o e
    o=$(tmpfile) && e=$(tmpfile) || die "could not create a scratch file"
    RC=0
    "$@" >"$o" 2>"$e" || RC=$?
    OUT=$(cat "$o"); ERR=$(cat "$e")
}

pv() { "$PROVIDER" --http "$HTTP" "$@"; }
api() { "$HTTP" "$@"; }

ERR=""; N_FLOWS=0; N_PASSED=0; FLOW_FAILS=""; FLOW_CHECKS=0; FLOW_NAME=""; FAILED_ANY=0
flow() { FLOW_NAME="$1"; FLOW_FAILS=""; FLOW_CHECKS=0; N_FLOWS=$((N_FLOWS + 1)); }
check() {
    FLOW_CHECKS=$((FLOW_CHECKS + 1))
    [ "$2" = "$3" ] && return 0
    FLOW_FAILS="$FLOW_FAILS
    not ok - $1
        want: $(printf '%s' "$2" | head -3)
        got:  $(printf '%s' "$3" | head -3)"
    [ -z "$ERR" ] || FLOW_FAILS="$FLOW_FAILS
        last stderr: $(printf '%s' "$ERR" | head -2)"
    return 1
}
end_flow() {
    if [ -z "$FLOW_FAILS" ]; then
        N_PASSED=$((N_PASSED + 1))
        printf 'ok %s - %s (%s checks)\n' "$N_FLOWS" "$FLOW_NAME" "$FLOW_CHECKS"
    else
        FAILED_ANY=1
        printf 'not ok %s - %s%s\n' "$N_FLOWS" "$FLOW_NAME" "$FLOW_FAILS"
    fi
}

# decision FILE TITLE [JQ_ASSIGNMENTS] — write a full-contract decision, tagged
# for this run, with TITLE and any extra fields jq assigns.
decision() {
    jq -n --arg t "$2" --arg l "$LABEL" --arg run "$RUN" '{
        title: $t,
        problem: "Acceptance run \($run) needs a ticket to act on.",
        solution: "The suite files it, moves it and closes it.",
        out_of_scope: "Anything outside this acceptance run.",
        rationale: [{choice: "File it through the suite, the way a session does.", rejected: []}],
        executor: "agent", tags: ["wo-acceptance", $l],
        touches: ["acc/\($run)/\($t | gsub("[^A-Za-z0-9]+"; "-")).txt"],
        verify: "true", verify_fails_today: "the ticket does not exist yet"
    } '"${3:+| $3}" > "$1"
}

made() { MADE="$MADE $1"; }
key_of() { printf '%s' "$1" | jq -r '.key // empty' 2>/dev/null; }
position() { pv position "$1" 2>/dev/null; }
parent_of() { api GET "/issue/$1?fields=parent" | jq -r '.fields.parent.key // "none"'; }
blockers_of() {
    api GET "/issue/$1?fields=issuelinks" \
        | jq -r '[.fields.issuelinks[]? | select(.type.name == "Blocks" and .inwardIssue) | .inwardIssue.key] | sort | join(" ")'
}
text_of() {
    api GET "/issue/$1?fields=$2" \
        | jq -r --arg f "$2" '[.fields[$f] // {} | .. | objects | select(.type == "text") | .text] | join("\n")'
}
field_id() { api GET /field | jq -r --arg n "$1" '[.[] | select(.custom == true and .name == $n)][0].id // empty'; }
issues() { python3 "$ISSUES_PY" "$1" --source jira --jira-api "$ISSUES_API" --jira-project "$PROJ" 2>&1; }
# row_keys — the ticket key heading each row on stdin (the first field matching
# a key), sorted and space-joined; an epic named later on the row is not one.
row_keys() {
    awk -v re="^$PROJ-[0-9]+\$" '{ for (i = 1; i <= 2 && i <= NF; i++) if ($i ~ re) { print $i; break } }' \
        | sort -u | tr '\n' ' ' | sed 's/ $//'
}
next_keys() { issues next | grep '^  \[' | row_keys; }
# has KEY LIST — print KEY when it is a whole entry of the space-joined LIST.
has() { case " $2 " in *" $1 "*) printf '%s' "$1" ;; esac; }
open_count() {
    local jql
    jql=$(printf '%s' "project = \"$PROJ\" AND statusCategory != Done" | jq -sRr @uri)
    api GET "/search/jql?jql=$jql&fields=key&maxResults=100" | jq -r '.issues | length'
}
open_keys() {
    local jql
    jql=$(printf '%s' "project = \"$PROJ\" AND statusCategory != Done ORDER BY key ASC" | jq -sRr @uri)
    api GET "/search/jql?jql=$jql&fields=key&maxResults=100" | jq -r '.issues[].key'
}
sorted() { printf '%s\n' "$@" | sort | tr '\n' ' ' | sed 's/ $//'; }

# close KEY WHY — delete KEY when this credential may, else cancel it with WHY
# as the outcome unless it is already Completed or Cancelled.
close() {
    if [ "$CAN_DELETE" = "1" ]; then
        api DELETE "/issue/$1" >/dev/null 2>&1 && return 0
    fi
    case "$(position "$1")" in
        completed|cancelled) return 0 ;;
    esac
    pv transition "$1" cancelled --outcome "$2" >/dev/null 2>&1
}

# ---- preconditions -----------------------------------------------------------

PROJECT_JSON=$(api GET "/project/$PROJ" 2>/dev/null) \
    || { warn "could not read project '$PROJ' — is it there, and are WORK_ORDER_JIRA_* set?"; exit 2; }
if ! printf '%s' "$PROJECT_JSON" | jq -r '.description // ""' | grep -qF "$MARKER"; then
    warn "project '$PROJ' does not carry the scratch marker in its description, so the suite will not touch it; only a project made for this suite carries it (README, Releasing)"
    exit 2
fi
CATEGORY=$(printf '%s' "$PROJECT_JSON" | jq -r '.projectCategory.name // ""')
[ "$CATEGORY" = "Universal Managed" ] \
    || { warn "project '$PROJ' is in category '${CATEGORY:-none}', not 'Universal Managed'; run provision.sh --project $PROJ first"; exit 2; }
CAN_DELETE=0
[ "$(api GET "/mypermissions?projectKey=$PROJ&permissions=DELETE_ISSUES" | jq -r '.permissions.DELETE_ISSUES.havePermission')" = "true" ] && CAN_DELETE=1
printf 'acceptance: project %s, run %s, closing issues by %s\n' "$PROJ" "$RUN" \
    "$([ "$CAN_DELETE" = 1 ] && echo delete || echo cancel)"

for k in $(open_keys); do
    close "$k" "Left open by an earlier acceptance run; closed by run $RUN."
done
[ "$(open_count)" = "0" ] || { warn "could not close the issues an earlier run left open in '$PROJ'"; exit 2; }

finish() {
    local k
    if [ "$KEEP" = "1" ]; then
        printf 'kept this run'"'"'s issues:%s\n' "$MADE"
    else
        for k in $MADE; do close "$k" "Filed by acceptance run $RUN; closed by the run itself."; done
        flow "leave nothing open in $PROJ"
        check "no issue in $PROJ is left open" "0" "$(open_count)"
        end_flow
    fi
    printf '%s flows, %s passed\n' "$N_FLOWS" "$N_PASSED"
    tmpclean
    [ "$FAILED_ANY" = "0" ]
}

# ---- flow 1: file a set of tickets under an epic ---------------------------------

flow "file a set of tickets under an epic"
jq -n --arg l "$LABEL" --arg run "$RUN" '{title: "acc \($run) epic",
    problem: "Acceptance run \($run) files a set under an epic.",
    solution: "The epic groups the run'"'"'s tickets.", out_of_scope: "Anything else.",
    tags: ["wo-acceptance", $l]}' > "$WORK/epic.json"
run pv create "$PROJ" Epic '' --ticket "$WORK/epic.json"
E=$(key_of "$OUT"); made "$E"
check "the epic is created" "0" "$RC"
decision "$WORK/a.json" "acc $RUN A" ". + {epic: \"$E\"}"
decision "$WORK/b.json" "acc $RUN B" ". + {epic: \"$E\", blocked_by: [\"A\"]}"
run pv create "$PROJ" Task '' --ticket "$WORK/a.json"; A=$(key_of "$OUT"); made "$A"
check "A is created" "0" "$RC"
run pv create "$PROJ" Task '' --ticket "$WORK/b.json"; B=$(key_of "$OUT"); made "$B"
check "B is created" "0" "$RC"
run pv link "$B" --blocked-by "$A";  check "B is linked as blocked by A" "0" "$RC"
run pv transition "$A" open;         check "A opens" "0" "$RC"
run pv transition "$B" open;         check "B opens" "0" "$RC"
check "A is under the epic, written at create" "$E" "$(parent_of "$A")"
check "B is under the epic" "$E" "$(parent_of "$B")"
check "B reads back blocked by A" "$A" "$(blockers_of "$B")"
check "A reads back at open" "open" "$(position "$A")"
check "A's verify carries the base-state observation" "true
# the ticket does not exist yet" "$(text_of "$A" "$(field_id verify)")"

before=$(open_count)
run pv create "$PROJ" Epic '' --ticket "$WORK/epic.json"
check "a second run finds the epic: exit 3" "3 $E" "$RC $(key_of "$OUT")"
run pv create "$PROJ" Task '' --ticket "$WORK/a.json"
check "  and A" "3 $A" "$RC $(key_of "$OUT")"
run pv link "$B" --blocked-by "$A"; check "  the link is a no-op" "0 $B is already blocked by $A" "$RC $OUT"
run pv transition "$A" open;        check "  the transition is a no-op" "0 $A is already Open" "$RC $OUT"
check "  and nothing new was filed" "$before" "$(open_count)"

decision "$WORK/c.json" "acc $RUN C"
run pv create "$PROJ" Task '' --ticket "$WORK/c.json"; C=$(key_of "$OUT"); made "$C"
check "C is filed before it has an epic" "none" "$(parent_of "$C")"
run pv parent "$C" --epic "$E";  check "parent puts C under the epic" "0 $E" "$RC $(parent_of "$C")"
run pv parent "$C" --epic "$E";  check "  and a second parent is a no-op" "0 $C is already under epic $E" "$RC $OUT"
run pv transition "$C" open;     check "C opens" "0" "$RC"
end_flow

# ---- flow 2: walk a ticket through the lifecycle --------------------------------

flow "walk a ticket through the lifecycle"
run pv create "$PROJ" Task "acc $RUN T"; T=$(key_of "$OUT"); made "$T"
check "a bare ticket enters triage" "triage" "$(position "$T")"
run pv transition "$T" open;     check "open is refused without verify" "1" "$RC"
decision "$WORK/t.json" "acc $RUN T" 'del(.title)'
run pv update "$T" --ticket "$WORK/t.json"; check "update gives it its contract" "0" "$RC"
run pv parent "$T" --epic "$E";             check "and parent puts it under the epic" "0 $E" "$RC $(parent_of "$T")"
run pv transition "$T" open;     check "then it opens" "0 open" "$RC $(position "$T")"
run pv transition "$T" deferred; check "defer is refused without a date" "1" "$RC"
printf '{"defer_until":"%s"}' "$SOON" > "$WORK/defer.json"
run pv update "$T" --ticket "$WORK/defer.json"; check "update writes the date" "0" "$RC"
run pv transition "$T" deferred; check "then it defers" "0 deferred" "$RC $(position "$T")"
check "next holds a deferred ticket back" "" "$(has "$T" "$(next_keys)")"
run pv transition "$T" open;     check "it comes back early" "0 open" "$RC $(position "$T")"
check "  and next still holds it back while the date is ahead" "" "$(has "$T" "$(next_keys)")"
printf '{"defer_until":null}' > "$WORK/undefer.json"
run pv update "$T" --ticket "$WORK/undefer.json"; check "update clears the date" "0" "$RC"
check "  and next offers it again" "$T" "$(has "$T" "$(next_keys)")"
run pv transition "$T" in-progress;         check "it starts" "0 in-progress" "$RC $(position "$T")"
run pv transition "$T" open;                check "it re-opens from in-progress" "0 open" "$RC $(position "$T")"
run pv transition "$T" in-progress;         check "it starts again" "0" "$RC"
run pv transition "$T" awaiting-deployment; check "it lands" "0 awaiting-deployment" "$RC $(position "$T")"
run pv transition "$T" completed;           check "it completes" "0 completed" "$RC $(position "$T")"
run pv transition "$T" open;                check "a completed ticket re-opens" "0 open" "$RC $(position "$T")"
end_flow

# ---- flow 3: cancel with an outcome ---------------------------------------------

flow "cancel with an outcome"
decision "$WORK/x.json" "acc $RUN X"
run pv create "$PROJ" Task '' --ticket "$WORK/x.json"; X=$(key_of "$OUT"); made "$X"
run pv transition "$X" cancelled
check "cancel is refused with no outcome, before any write" "1 triage" "$RC $(position "$X")"
run pv transition "$X" cancelled --outcome "Superseded in acceptance run $RUN."
check "cancel with an outcome" "0 cancelled" "$RC $(position "$X")"
check "  the outcome reads back" "Superseded in acceptance run $RUN." "$(text_of "$X" "$(field_id outcome)")"
jq --arg t "acc $RUN epic two" '.title = $t' "$WORK/epic.json" > "$WORK/epic2.json"
run pv create "$PROJ" Epic '' --ticket "$WORK/epic2.json"; E2=$(key_of "$OUT"); made "$E2"
run pv transition "$E2" cancelled --outcome "Dropped in acceptance run $RUN."
check "an epic cancels with an outcome" "0 cancelled" "$RC $(position "$E2")"
end_flow

# ---- flow 4: the landing path completes a ticket --------------------------------

flow "the landing path completes a ticket"
decision "$WORK/l.json" "acc $RUN L"
run pv create "$PROJ" Task '' --ticket "$WORK/l.json"; L=$(key_of "$OUT"); made "$L"
run pv transition "$L" open;        check "the ticket opens" "0" "$RC"
run pv transition "$L" in-progress; check "and starts" "0 in-progress" "$RC $(position "$L")"
run pv transition "$L" completed
check "completed is refused from in-progress ([JIRA-18])" "1 in-progress" "$RC $(position "$L")"
run pv transition "$L" awaiting-deployment; check "the pre-merge hop" "0 awaiting-deployment" "$RC $(position "$L")"
run pv transition "$L" in-progress;         check "re-work undoes it" "0 in-progress" "$RC $(position "$L")"
run pv transition "$L" awaiting-deployment; check "the pre-merge hop again" "0" "$RC"
printf '{"verify":null}' > "$WORK/noverify.json"
run pv update "$L" --ticket "$WORK/noverify.json"
run pv transition "$L" completed
check "complete is refused while verify is empty" "1 awaiting-deployment" "$RC $(position "$L")"
decision "$WORK/l2.json" "acc $RUN L" '{verify}'
run pv update "$L" --ticket "$WORK/l2.json"
run pv transition "$L" completed;           check "the post-push hop completes it" "0 completed" "$RC $(position "$L")"
end_flow

# ---- flow 5: read the set back ---------------------------------------------------

flow "read the set back"
run python3 "$ISSUES_PY" lint --source jira --jira-api "$ISSUES_API" --jira-project "$PROJ"
check "lint is clean" "0" "$RC"
BOARD=$(issues board)
check "board lists the open tickets" "$(sorted "$A" "$B" "$C" "$T")" "$(printf '%s\n' "$BOARD" | sed -n '/^open /,/^$/p' | row_keys)"
check "  B shown blocked by A" "1" "$(printf '%s\n' "$BOARD" | grep -c "^  $B .*blocked_by $A")"
check "  each under the epic" "4" "$(printf '%s\n' "$BOARD" | grep -c "epic $E ")"
check "  and the epic with its rolled-up state" "1" "$(printf '%s\n' "$BOARD" | grep -c "^  $E .*\[To Do\]")"
check "next offers exactly the startable tickets" "$(sorted "$A" "$C" "$T")" "$(next_keys)"
printf '{"blocked_by_external":["acceptance run %s waits on a vendor"]}' "$RUN" > "$WORK/ext.json"
run pv update "$A" --ticket "$WORK/ext.json"
check "next holds back a ticket waiting on external work" "$(sorted "$C" "$T")" "$(next_keys)"
printf '{"blocked_by_external":[]}' > "$WORK/noext.json"
run pv update "$A" --ticket "$WORK/noext.json"
check "  and offers it once that clears" "$(sorted "$A" "$C" "$T")" "$(next_keys)"

FILES="$WORK/files"
jq -n --arg e "$E" --arg a "$A" --arg b "$B" --arg c "$C" --arg t "$T" \
    --slurpfile da "$WORK/a.json" --slurpfile db "$WORK/b.json" --slurpfile dc "$WORK/c.json" --slurpfile dt "$WORK/t.json" '
    def ticket($d; $id; $title): $d + {id: $id, title: $title, epic: $e, blocked_by: [], created: "2026-10-08"};
    {decision_list_version: "0.1.0", decisions: [
        ticket($da[0]; $a; $da[0].title),
        ticket($db[0]; $b; $db[0].title) + {blocked_by: [$a]},
        ticket($dc[0]; $c; $dc[0].title) + {epic: $e},
        ticket($dt[0]; $t; "the same T")]}' > "$WORK/set.json"
run python3 "$EMIT_PY" "$WORK/set.json" --out "$FILES/open"
check "the same set emits to files" "0" "$RC"
FNEXT=$(python3 "$ISSUES_PY" next "$FILES" 2>&1 | grep '^  \[' | row_keys)
check "  and next through the file binding, with a scalar epic, agrees" "$(sorted "$A" "$C" "$T")" "$FNEXT"
check "  labelling each row with the scalar epic" "1" "$(python3 "$ISSUES_PY" next "$FILES" 2>&1 | grep -c "^  \[agent\] $A .*epic $E ")"

NW="${NIGHT_WATCHMAN_ROOT:-$(cd "$ROOT/.." && pwd)/night-watchman}"
if [ -f "$NW/scripts/waves.py" ]; then
    WAVES=$(WAVES_ISSUES_PY="$ISSUES_PY" python3 "$NW/scripts/waves.py" waves --source jira \
            --jira-api "$ISSUES_API" --jira-project "$PROJ" 2>&1)
    check "waves puts the startable tickets in wave 1" "$(sorted "$A" "$C" "$T")" \
        "$(printf '%s\n' "$WAVES" | sed -n '/^Wave 1 /,/^Wave 2 /p' | row_keys)"
    check "  and B after A" "$B" "$(printf '%s\n' "$WAVES" | sed -n '/^Wave 2 /,/^$/p' | row_keys)"
else
    printf '  skip - waves: no night-watchman checkout at %s\n' "$NW"
fi

run pv transition "$E" open;        check "the epic opens" "0" "$RC"
run pv transition "$E" in-progress; check "the epic starts" "0" "$RC"
run pv transition "$E" completed;   check "the epic completes" "0 completed" "$RC $(position "$E")"
end_flow

finish
