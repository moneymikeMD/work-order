---
id: XB-001
title: The export endpoint answers with a CSV a spreadsheet opens unaided
created: 2026-09-12
updated: 2026-09-14
executor: agent
tags: [export, api]
blocked_by: []
blocked_by_external: the vendor publishing its rate-limit headers
touches:
  - src/export/csv.py
  - tests/test_export_csv.py
appends:
  - CHANGELOG.md
verify: |
  python3 -m pytest tests/test_export_csv.py -q
  python3 -m ex.cli export --format csv --limit 1 | head -1 | grep -c '^id,name,created$'
  # Today src/export/csv.py does not exist and --format csv exits 2, so both fail.
---

## Problem

Operators export data by copying it out of the admin page one screen at a time, and the file has no header row.

## Solution

Add a CSV writer behind the existing export command, emitting a header row followed by every matching record.

## Out of scope

The XLSX format, scheduled exports, and which records the export selects.
