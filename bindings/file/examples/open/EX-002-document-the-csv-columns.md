---
id: EX-002
title: The published column list matches what the exporter emits
created: 2026-09-12
updated: 2026-09-12
executor: agent
tags: [export, docs]
blocked_by: [EX-001]
touches:
  - docs/export.md
appends:
  - CHANGELOG.md
verify: |
  test -f docs/export.md
  grep -c '^| `id` ' docs/export.md >/dev/null
  grep -c '^| `name` ' docs/export.md >/dev/null
  grep -c '^| `created` ' docs/export.md >/dev/null
  python3 -m ex.cli export --format csv --limit 1 | head -1 | grep -c '^id,name,created$'
  # Today docs/export.md does not exist, so the first four checks fail. The
  # last line is what keeps the table honest: it fails if the writer's header
  # and the documented columns ever disagree.
---

## Problem

A consumer of the export has no way to learn what a column means without
reading the writer's source, and no way to tell a renamed column from a
reordered one.

## Solution

Write the column table in `docs/export.md`: one row per column, with its name,
its type and one sentence of meaning. The verify greps for each documented
column and then re-reads the header the exporter actually emits, so the table
and the writer cannot drift apart unnoticed.

## Out of scope

Documenting any other endpoint, and the format's stability guarantee, which is
a decision nobody has made yet.
