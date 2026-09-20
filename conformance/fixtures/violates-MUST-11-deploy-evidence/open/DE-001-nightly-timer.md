---
id: DE-001
title: The nightly export runs without anyone triggering it
created: 2026-09-12
updated: 2026-09-14
verify: |
  systemctl is-active ex-export.timer
  # Today no unit named ex-export is known to systemd, so this fails.
---

## Problem

The export runs only when somebody remembers to run it.

## Solution

Ship a timer unit that runs the export nightly.

## Out of scope

Any other endpoint's documentation, and the format's stability guarantee.
