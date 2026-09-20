---
id: EX-003
title: The export bucket key is one nobody has pasted into a chat window
created: 2026-09-13
updated: 2026-09-16
executor: mixed
tags: [export, security]
blocked_by: []
touches:
  - config/export.env.example
human_steps: |
  1. Issue a new bucket key in the storage console and store it in the
     password manager as `ex/export-bucket`. The console has no API for key
     issuance, which is where the automated part stops.
  2. Paste the key into the deployment's secret store under
     `EX_EXPORT_BUCKET_KEY`.
  3. Revoke the previous key in the same console, after the check below passes.
verify: |
  grep -c '^EX_EXPORT_BUCKET_KEY=$' config/export.env.example >/dev/null
  test "$(grep -c AKIA config/export.env.example)" = 0
  python3 -m ex.cli export --format csv --limit 1 --destination bucket
  # Today config/export.env.example names no bucket key at all, so the first
  # check fails. The second is not a formality: the file it replaces carried a
  # live key in a committed example.
---

## Problem

The export writes to a bucket using a key that was pasted into a chat window
while someone was debugging it, and the committed example env file carries a
real key rather than an empty placeholder.

## Solution

Issue a fresh key, put it in the deployment's secret store, and reduce the
committed example to an empty placeholder. The old key is revoked only once a
real export has been written with the new one.

## Out of scope

Moving the credential to a workload identity, which removes the rotation
entirely and is a larger change than this ticket. Rotating any other credential.
