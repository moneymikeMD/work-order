---
id: NOC-001
title: The export also offers XLSX, so finance stops re-saving the CSV by hand
created: 2026-09-12
updated: 2026-09-14
---

## Problem

Finance receives a CSV and re-saves it as a workbook before using it.

## Solution

Add an XLSX writer alongside the CSV one, behind `--format xlsx`.

## Out of scope

Which records are exported, and the CSV format itself.
