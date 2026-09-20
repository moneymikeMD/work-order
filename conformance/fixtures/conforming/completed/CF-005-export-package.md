---
id: CF-005
title: The export writers live in a package of their own, not in the CLI module
created: 2026-09-12
updated: 2026-09-14
executor: agent
tags: [export, api]
blocked_by: []
touches:
  - src/export/__init__.py
  - src/ex/cli.py
appends:
  - CHANGELOG.md
verify: |
  test -f src/export/__init__.py
  test "$(grep -c 'def write_' src/ex/cli.py)" = 0
  # Today there is no src/export/ and every writer is a function in src/ex/cli.py,
  # so the first check fails and the second finds four matches.
outcome: |
  Landed as one commit. The writers moved verbatim; the only edit was the
  import line in src/ex/cli.py.
---

## Problem

Every output format is a function in the CLI module, the longest file in the project.

## Solution

Create a package for the export code and move the existing writers into it unchanged.

## Out of scope

Adding or changing any format, and the CLI's argument grammar.
