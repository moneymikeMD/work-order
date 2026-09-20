---
id: CF-006
title: The export also offers XLSX, so finance stops re-saving the CSV by hand
created: 2026-09-12
updated: 2026-09-14
executor: agent
tags: [export, api]
blocked_by: []
touches: []
outcome: |
  Dropped. The premise was that finance needed a native workbook, and the
  premise was false: they re-save the CSV to set column widths a generated
  workbook would not have set either. Replaced by nothing.
---

## Problem

Finance receives a CSV and re-saves it as a workbook before using it.

## Solution

Add an XLSX writer alongside the CSV one, behind `--format xlsx`.

## Out of scope

Which records are exported, and the CSV format itself.
