---
id: NB-001
title: The published column list matches what the exporter emits
created: 2026-09-12
updated: 2026-09-14
executor: agent
tags: [export, docs]
touches:
  - docs/export.md
verify: |
  test -f docs/export.md
  grep -c '^| `id` ' docs/export.md >/dev/null
  # Today docs/export.md does not exist, so the checks above fail.
---

## Problem

Operators read the export's column list out of the writer's source, because nothing else states it.

## Solution

Write the column table in `docs/export.md`, one row per column, and check it against the header the writer emits.

## Out of scope

Any other endpoint's documentation, and the format's stability guarantee.
