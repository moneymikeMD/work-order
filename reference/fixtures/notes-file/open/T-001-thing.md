---
id: T-001
title: A minimal fixture ticket for WO-046, with a progress file beside it
created: 2026-09-20
updated: 2026-09-20
executor: agent
tags: [fixture]
blocked_by: []
touches:
  - reference/fixtures/notes-file/**
appends: []
verify: |
  true
---

## Problem

Fixture only, for WO-046: `load_files()` must exclude a `<id>.notes.md`
progress note beside this ticket, not read it as a second ticket.
