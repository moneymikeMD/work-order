#!/bin/bash
#
# issues-api.sh — the jira-api.sh-shaped wrapper `reference/issues.py --source
# jira` calls, over this binding's own client, so the reference implementation
# can read a Space with nothing but this repository and the three
# WORK_ORDER_JIRA_* variables lib/jira-http.sh reads.
#
# Usage:
#   issues-api.sh [--show-secrets] raw GET /path
#
#   python3 reference/issues.py next --source jira \
#       --jira-api plugins/work-order-jira/issues-api.sh --jira-project KEY
#
# GET is the only method forwarded: issues.py only reads. --show-secrets is
# accepted and ignored, because lib/jira-http.sh redacts nothing.
#
# Env: ISSUES_API_HTTP overrides the client (a jira-http.sh-shaped stub, for
# tests). Exit status and output are the client's.

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$DIR/lib/common.sh"

USAGE="usage: ${0##*/} [--show-secrets] raw GET /path"
[ "${1:-}" != "--show-secrets" ] || shift
if [ $# -ne 3 ] || [ "$1" != "raw" ]; then die "$USAGE"; fi
[ "$2" = "GET" ] || die "only GET is forwarded: issues.py reads and never writes, got '$2'"
exec "${ISSUES_API_HTTP:-$DIR/lib/jira-http.sh}" GET "$3"
