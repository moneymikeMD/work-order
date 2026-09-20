---
id: IV-001
title: The published column list matches what the exporter emits
created: 2026-09-12
updated: 2026-09-14
executor: agent
tags: [export, docs]
blocked_by: []
touches:
  - docs/export.md
verify: |
  test -f docs/export.md
  python3 -m ex.cli export --format csv --limit 1
  Then type the code the console shows into the prompt to release the check.
  # Today docs/export.md does not exist, so the first check fails.
---

## Problem

Operators read the export's column list out of the writer's source, because nothing else states it.

## Solution

Write the column table in `docs/export.md`, one row per column, and check it against the header the writer emits.

## Out of scope

Any other endpoint's documentation, and the format's stability guarantee.
