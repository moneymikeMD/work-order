---
id: EX-006
title: The export also offers XLSX, so finance stops re-saving the CSV by hand
created: 2026-09-12
updated: 2026-09-17
executor: agent
tags: [export, cancelled]
blocked_by: []
touches: []
outcome: |
  Dropped. The premise was that finance needed a native workbook, and the
  premise was false: they re-save the CSV to set the column widths their
  template expects, which a generated workbook would not have set either.
  The column widths are the actual requirement and nobody has asked for them.

  Replaced by nothing. EX-001 already gives them the file; if the widths come
  up again the ticket to write is about the template, not the format.
---

## Problem

Finance receives a CSV and re-saves it as a workbook before using it, which is
a manual step on a file that is produced automatically.

## Solution

Add an XLSX writer alongside the CSV one, behind `--format xlsx`.

## Out of scope

Any change to which records are exported, and the CSV format itself.
