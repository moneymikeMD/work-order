---
id: CF-003
title: The committed example env file carries no live bucket key
created: 2026-09-12
updated: 2026-09-14
executor: agent
tags: [export, ops]
blocked_by: []
touches:
  - config/export.env.example
verify: |
  grep -c '^EX_EXPORT_BUCKET_KEY=$' config/export.env.example >/dev/null
  test "$(grep -c AKIA config/export.env.example)" = 0
  # Today the file names no bucket key and carries a live one, so the first check fails.
---

## Problem

The committed example env file carries a real bucket key rather than an empty placeholder.

## Solution

Reduce the committed example to an empty placeholder and assert no key-shaped string remains in it.

## Out of scope

Moving the credential to a workload identity, and any other credential.
