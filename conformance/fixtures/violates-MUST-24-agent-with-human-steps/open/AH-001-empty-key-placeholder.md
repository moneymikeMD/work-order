---
id: AH-001
title: The committed example env file carries no live bucket key
created: 2026-09-12
updated: 2026-09-14
executor: agent
tags: [export, ops]
blocked_by: []
touches:
  - config/export.env.example
human_steps: |
  1. Issue a new bucket key in the storage console, which has no API
     for key issuance, and store it where the deployment reads it.
verify: |
  test -f config/export.env.example
  grep -c '^| `id` ' config/export.env.example >/dev/null
  # Today config/export.env.example does not exist, so the checks above fail.
---

## Problem

The committed example env file carries a real bucket key.

## Solution

Issue a fresh key, store it where the deployment reads secrets, and empty the example.

## Out of scope

Moving the credential to a workload identity.
