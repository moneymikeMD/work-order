---
date: 2026-09-20
slug: jira-status-open-stays-position-open-binds-to-open-to-do-and-done-are-read-only-legacy-aliases
title: "Jira status Open stays: position open binds to Open, To Do and Done are read-only legacy aliases"
---

# Jira status Open stays: position open binds to Open, To Do and Done are read-only legacy aliases

## Decision

The open lifecycle position binds to the provisioned Jira status Open, defined as a ticket ready to be worked on and startable (owner wording recorded in SPEC.md MUST-25 and JIRA-15). To Do joins Done as a read-only legacy alias accepted on read, never written or provisioned. Version bump is 0.2.0, not 1.0.0 (2026-09-20).

## Why

The first branch retired Open on a live count (Open held zero issues, To Do the backlog); the owner reversed it twice, since a live count is evidence about a moment, not a contract.

## Cost

unrecorded in memory 1317abe5
