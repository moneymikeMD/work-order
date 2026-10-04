---
id: CROSS-1
title: Cross-repo path in the colon form
created: 2026-10-03
updated: 2026-10-03
executor: human
tags: [fixture]
blocked_by: []
touches:
  - dotfiles:dot_config/a/**
verify: |
  test -f a.txt
  # Today a.txt does not exist.
---

## Problem

Names the dotfiles checkout as repo:path.

## Solution

Write the file.

## Out of scope

Anything else.
