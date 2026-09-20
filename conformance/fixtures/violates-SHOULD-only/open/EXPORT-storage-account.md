---
id: EXPORT
title: The export has a storage account of its own
created: 2026-09-12
updated: 2026-09-14
executor: human
tags: [export, ops]
blocked_by: []
verify: |
  test -f config/export.env.example
  # Today config/export.env.example does not exist.
---

## Problem

The export writes to a bucket owned by an account shared with three other jobs.

## Solution

Register a storage account for the export alone and write its name into the example env file.

## Out of scope

Migrating the existing objects, and any other job's account.
