---
id: EX-004
title: The nightly export runs without anyone triggering it
created: 2026-09-14
updated: 2026-09-18
executor: agent
tags: [export, scheduling]
blocked_by: []
touches:
  - deploy/export.timer
  - deploy/export.service
verify: |
  systemd-analyze verify deploy/export.service
  systemctl --user list-timers ex-export.timer | grep -c ex-export.timer >/dev/null
  test -s "$(ls -t /var/log/ex/export-*.csv | head -1)"
  # Today deploy/export.timer does not exist and no timer named ex-export is
  # known to systemd, so the first two checks fail. The third is the one that
  # matters after deployment: a timer that fired and wrote nothing is the
  # ordinary failure, and an active unit is not evidence against it.
---

## Problem

The export is run by hand whenever somebody remembers, which means the file
consumers read is between one and nine days old and nobody can tell which.

## Solution

Ship a systemd timer and service unit that run the export nightly and write the
result where consumers already look. The check reads the written file rather
than the unit's state.

## Out of scope

Alerting on a missed run, which needs the monitoring stack this project does
not have yet, and any change to the export's contents.
