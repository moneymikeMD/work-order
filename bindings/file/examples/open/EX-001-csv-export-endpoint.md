---
id: EX-001
title: The export endpoint answers with a CSV a spreadsheet opens unaided
created: 2026-09-12
updated: 2026-09-12
executor: agent
tags: [export, api]
blocked_by: []
touches:
  - src/export/csv.py
  - tests/test_export_csv.py
appends:
  - CHANGELOG.md
verify: |
  python3 -m pytest tests/test_export_csv.py -q
  python3 -m ex.cli export --format csv --limit 1 | head -1 | grep -c '^id,name,created$'
  # Today src/export/csv.py does not exist, `--format csv` exits 2 with
  # "unknown format", and the pytest file is absent, so both commands fail.
---

## Problem

Operators export data by copying it out of the admin page, one screen at a
time. Anything past the first page is silently missing, and the file they end
up with has no header row, so nobody downstream can tell which column is which.

## Solution

Add a CSV writer behind the existing export command, emitting a header row
followed by every matching record. Cover it with a test that asserts the header
line and the row count for a two-record fixture.

## Out of scope

The XLSX format, scheduled exports, and any change to which records the export
selects. This ticket changes the serialisation only.
