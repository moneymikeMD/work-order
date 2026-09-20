#!/bin/bash
#
# jira-http.sh — the one credentialed HTTP client in this binding, and the
# seam every other script in it talks to. `provider.sh` and `provision.sh`
# both take `--http PATH` so a test can substitute a stub of this shape and
# reach no network at all.
#
# Usage:
#   jira-http.sh [--dry-run] GET    /path
#   jira-http.sh [--dry-run] DELETE /path
#   jira-http.sh [--dry-run] POST   /path 'JSON'
#   jira-http.sh [--dry-run] PUT    /path 'JSON'
#
# /path is relative to the Jira Cloud REST v3 root (/rest/api/3) and must
# start with a slash.
#
# Contract, relied on by every caller and therefore by every stub:
#   - a 2xx prints the response body on stdout and exits 0. An empty body
#     (204) prints nothing and still exits 0.
#   - any other status prints "HTTP <code>" on the FIRST line of stderr,
#     then the response body, and exits 1. Callers distinguish an expected
#     404 or 400 from a real failure by grepping stderr for that line, so
#     its wording is part of the contract.
#   - --dry-run prints the request it would have made and exits 0 without
#     resolving a credential or opening a socket.
#
# Environment:
#   WORK_ORDER_JIRA_BASE_URL   https://your-site.atlassian.net (required)
#   WORK_ORDER_JIRA_EMAIL      Atlassian account email (required)
#   WORK_ORDER_JIRA_TOKEN      Atlassian API token (required)
#   WORK_ORDER_JIRA_TIMEOUT    curl timeout in seconds, default 30
#
# The credential reaches curl on a config file fed to its stdin, never on
# argv, which any process running as the same user can read.
#
# Response bodies are returned verbatim: callers parse them, and blanking a
# credential-shaped key inside a workflow rule destroys the rule on the
# round-trip back. This client's job is to never print the credential; it
# is not a redactor for bodies the caller then re-sends.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$DIR/common.sh"

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=1
    shift
fi

METHOD="${1:-}"
PATH_REL="${2:-}"
BODY="${3:-}"

case "$METHOD" in
    GET|DELETE)
        [ $# -eq 2 ] || die "usage: ${0##*/} [--dry-run] $METHOD /path"
        ;;
    POST|PUT)
        [ $# -eq 3 ] || die "usage: ${0##*/} [--dry-run] $METHOD /path 'JSON'"
        ;;
    "")
        die "usage: ${0##*/} [--dry-run] GET|POST|PUT|DELETE /path ['JSON']"
        ;;
    *)
        die "unsupported method '$METHOD' (GET, POST, PUT, DELETE)"
        ;;
esac

case "$PATH_REL" in
    /*) ;;
    *) die "path must start with '/' and be relative to /rest/api/3, got '$PATH_REL'" ;;
esac

if [ -n "$BODY" ]; then
    need jq
    printf '%s' "$BODY" | jq -e . >/dev/null 2>&1 \
        || die "$METHOD $PATH_REL: request body is not valid JSON"
fi

if [ "$DRY_RUN" = "1" ]; then
    printf 'WOULD %s %s%s\n' "$METHOD" "${WORK_ORDER_JIRA_BASE_URL:-<WORK_ORDER_JIRA_BASE_URL>}" "/rest/api/3$PATH_REL"
    [ -n "$BODY" ] && printf '%s\n' "$BODY"
    exit 0
fi

need curl

BASE_URL="${WORK_ORDER_JIRA_BASE_URL:-}"
EMAIL="${WORK_ORDER_JIRA_EMAIL:-}"
TOKEN="${WORK_ORDER_JIRA_TOKEN:-}"
TIMEOUT="${WORK_ORDER_JIRA_TIMEOUT:-30}"

[ -n "$BASE_URL" ] || die "WORK_ORDER_JIRA_BASE_URL is not set (e.g. https://your-site.atlassian.net)"
[ -n "$EMAIL" ]    || die "WORK_ORDER_JIRA_EMAIL is not set"
[ -n "$TOKEN" ]    || die "WORK_ORDER_JIRA_TOKEN is not set"
case "$BASE_URL" in
    https://*) ;;
    *) die "WORK_ORDER_JIRA_BASE_URL must be an https:// URL, got '$BASE_URL'" ;;
esac
BASE_URL="${BASE_URL%/}"

trap tmpclean EXIT
OUT=$(tmpfile) || die "could not create a scratch file for the response body"

URL="$BASE_URL/rest/api/3$PATH_REL"

set +e
if [ -n "$BODY" ]; then
    CODE=$(printf 'user = "%s:%s"\n' "$EMAIL" "$TOKEN" \
        | curl -sS -m "$TIMEOUT" --config - -X "$METHOD" \
            -H 'Accept: application/json' -H 'Content-Type: application/json' \
            --data-binary "$BODY" -o "$OUT" -w '%{http_code}' "$URL")
else
    CODE=$(printf 'user = "%s:%s"\n' "$EMAIL" "$TOKEN" \
        | curl -sS -m "$TIMEOUT" --config - -X "$METHOD" \
            -H 'Accept: application/json' -o "$OUT" -w '%{http_code}' "$URL")
fi
CURL_RC=$?
set -e

[ "$CURL_RC" -eq 0 ] \
    || die "$METHOD $PATH_REL: could not reach $BASE_URL (curl exit $CURL_RC)"

case "$CODE" in
    2??)
        cat "$OUT"
        exit 0
        ;;
esac

printf 'HTTP %s\n' "$CODE" >&2
cat "$OUT" >&2
exit 1
