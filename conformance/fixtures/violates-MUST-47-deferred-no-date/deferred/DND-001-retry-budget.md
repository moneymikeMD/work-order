---
id: DND-001
title: The uploader gives up after a bounded number of retries
created: 2026-09-02
updated: 2026-09-11
verify: |
  test -f src/uploader/retry.py
  grep -c '^MAX_ATTEMPTS = ' src/uploader/retry.py >/dev/null
  # Today src/uploader/retry.py does not exist, so both checks fail.
---

## Problem

The uploader retries until the process is killed, so a bad credential looks like a slow night rather than a failure.

## Solution

Read a bounded attempt count from one constant and stop there, reporting the last error.

## Out of scope

Backoff timing, and every other caller of the transport.
