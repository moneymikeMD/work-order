---
id: AP-001
title: The exporter reads its destination from one configuration file
created: 2026-09-12
updated: 2026-09-14
executor: agent
tags: [export, docs]
blocked_by: []
touches:
  - /etc/ex/export.conf
verify: |
  test -f /etc/ex/export.conf
  grep -c '^| `id` ' /etc/ex/export.conf >/dev/null
  # Today /etc/ex/export.conf does not exist, so the checks above fail.
---

## Problem

The export's destination is hardcoded in three places.

## Solution

Read the destination from one configuration file the deployment writes.

## Out of scope

Any other endpoint's documentation, and the format's stability guarantee.
