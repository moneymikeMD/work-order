#!/bin/bash
# shellcheck disable=SC2034  # WO_JIRA_KEY_ERR is read by sourcing scripts, never here
#
# common.sh — the shell helpers every script in this binding shares: failure
# reporting, a scratch-file pool, list membership, and the two Jira value
# shapes (issue key, comment ADF document). Source it, never execute it.
#
# Targets bash 3.2 (macOS /bin/bash): no associative arrays, no ${var^^}, no
# readarray.
#
# Convention: a fallible helper prints NOTHING and returns non-zero; the
# caller decides how to die.

WO_JIRA_TMPDIR=""

warn() { printf '%s: %s\n' "${0##*/}" "$1" >&2; }

# die MESSAGE — report MESSAGE on stderr and exit 1.
die() { warn "$1"; exit 1; }

# need CMD... — die naming every listed command that is not on PATH.
need() {
    local missing="" c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
    done
    [ -z "$missing" ] || die "required command(s) not found:$missing"
}

# tmpfile — print the path of a fresh scratch file inside a per-run directory
# created on first use. The caller installs the cleanup trap.
tmpfile() {
    if [ -z "$WO_JIRA_TMPDIR" ]; then
        WO_JIRA_TMPDIR=$(mktemp -d) || return 1
    fi
    mktemp "$WO_JIRA_TMPDIR/f.XXXXXX"
}

# tmpclean — remove every scratch file tmpfile handed out in this run.
tmpclean() {
    [ -n "$WO_JIRA_TMPDIR" ] && rm -rf "$WO_JIRA_TMPDIR"
    WO_JIRA_TMPDIR=""
    return 0
}

# in_list VALUE NEWLINE_LIST — true when VALUE is one whole line of the list.
in_list() { printf '%s\n' "$2" | grep -qxF "$1"; }

WO_JIRA_KEY_ERR=""

# require_project_key KEY — validate a Jira project key: 2-10 characters,
# uppercase letters and digits, leading letter. Sets $WO_JIRA_KEY_ERR.
require_project_key() {
    local key="$1" len
    WO_JIRA_KEY_ERR=""
    case "$key" in
        [A-Z]*) ;;
        *) WO_JIRA_KEY_ERR="project key '$key' must start with an uppercase letter"; return 1 ;;
    esac
    case "$(printf '%s' "$key" | tr -d 'A-Z0-9')" in
        "") ;;
        *) WO_JIRA_KEY_ERR="project key '$key' must be uppercase letters and digits only"; return 1 ;;
    esac
    len=${#key}
    if [ "$len" -lt 2 ] || [ "$len" -gt 10 ]; then
        WO_JIRA_KEY_ERR="project key '$key' must be 2-10 characters, got $len"
        return 1
    fi
    return 0
}

# require_issue_key KEY — validate the PROJECT-123 shape. Sets
# $WO_JIRA_KEY_ERR. A guard, not a typo check: an unvalidated key reaches a
# URL path the request printer never showed.
require_issue_key() {
    local key="$1"
    WO_JIRA_KEY_ERR=""
    case "$key" in
        *[!A-Za-z0-9_-]*)
            WO_JIRA_KEY_ERR="issue key '$key' contains characters that are not letters, digits, '_' or '-'"
            return 1 ;;
    esac
    case "$key" in
        [A-Za-z]*-[0-9]*) ;;
        *) WO_JIRA_KEY_ERR="issue key '$key' is not a Jira key (PROJECT-123)"; return 1 ;;
    esac
    case "${key#*-}" in
        *[!0-9]*)
            WO_JIRA_KEY_ERR="issue key '$key' is not a Jira key — the part after the first dash must be digits only"
            return 1 ;;
    esac
    return 0
}

# jira_comment_body TEXT — print the ADF document Jira Cloud's v3 comment
# endpoint requires, one paragraph per input line. Returns jq's status.
jira_comment_body() {
    jq -cn --arg t "$1" '{
        body: {
            type: "doc", version: 1,
            content: ($t | gsub("\r"; "") | sub("\n+$"; "") | split("\n") | map(
                if . == "" then {type: "paragraph", content: []}
                else {type: "paragraph", content: [{type: "text", text: .}]} end
            ))
        }
    }'
}

# table HEADER — read tab-separated rows on stdin, print them aligned under
# the tab-separated HEADER.
table() {
    { printf '%s\n' "$1"; cat; } | column -t -s"$(printf '\t')"
}
