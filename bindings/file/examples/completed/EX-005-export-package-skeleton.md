---
id: EX-005
title: The export writers live in a package of their own, not in the CLI module
created: 2026-09-10
updated: 2026-09-11
executor: agent
tags: [export, refactor]
blocked_by: []
touches:
  - src/export/__init__.py
  - src/ex/cli.py
appends:
  - CHANGELOG.md
verify: |
  test -f src/export/__init__.py
  python3 -c "import export; print(export.__name__)" | grep -c '^export$' >/dev/null
  test "$(grep -c 'def write_' src/ex/cli.py)" = 0
  # Today there is no src/export/ at all and every writer is a function in
  # src/ex/cli.py, so the first check fails and the third finds four matches.
outcome: |
  Landed as one commit. The writers moved verbatim; the only edit was the
  import line in src/ex/cli.py. EX-001 now has somewhere to put a second
  format without growing the CLI module further.
---

## Problem

Every output format is a function in the CLI module, which is now the longest
file in the project and the one most likely to be edited by two people at once.

## Solution

Create a package for the export code and move the existing writers into it
unchanged, leaving the CLI module holding argument parsing and dispatch.

## Out of scope

Adding or changing any format — this ticket moves code and changes no
behaviour. The CLI's argument grammar stays as it is.
