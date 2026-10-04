---
id: CROSS-2
title: Cross-repo path in the slash form
created: 2026-10-03
updated: 2026-10-03
executor: human
tags: [fixture]
blocked_by: []
touches:
  - dotfiles/dot_config/b/**
verify: |
  test -f b.txt
  # Today b.txt does not exist.
---

## Problem

Names the same checkout as repo/path, which SHOULD-13 reports.

## Solution

Write the file.

## Out of scope

Anything else.
