---
id: CF-004
title: The nightly export runs without anyone triggering it
created: 2026-09-12
updated: 2026-09-14
executor: agent
tags: [export, ops]
blocked_by: []
touches:
  - deploy/export.timer
  - deploy/export.service
verify: |
  systemd-analyze verify deploy/export.service
  test -s "$(ls -t /var/log/ex/export-*.csv | head -1)"
  # Today deploy/export.service does not exist, so the first check fails. The
  # second is the one that matters after deployment: a timer that fired and
  # wrote nothing is the ordinary failure.
---

## Problem

The export runs when somebody remembers, so the file consumers read is between one and nine days old.

## Solution

Ship a timer and service unit that run the export nightly and write the result where consumers already look.

## Out of scope

Alerting on a missed run, and any change to the export's contents.
