---
id: SD-002
title: The export endpoint answers with a CSV a spreadsheet opens unaided
created: 2026-09-12
updated: 2026-09-14
verify: |
  test -f src/export/csv.py
  grep -c '^| `id` ' src/export/csv.py >/dev/null
  # Today src/export/csv.py does not exist, so the checks above fail.
---

## Problem

The export has no CSV writer.

## Solution

Add one behind the existing export command.

## Out of scope

Any other endpoint's documentation, and the format's stability guarantee.
