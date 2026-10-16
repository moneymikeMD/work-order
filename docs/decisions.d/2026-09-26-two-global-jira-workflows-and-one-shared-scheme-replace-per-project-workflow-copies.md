---
date: 2026-09-26
slug: two-global-jira-workflows-and-one-shared-scheme-replace-per-project-workflow-copies
title: "Two global Jira workflows and one shared scheme replace per-project workflow copies"
---

# Two global Jira workflows and one shared scheme replace per-project workflow copies

## Decision

Work-order owns two global workflows, Universal Managed Workflow (tasks, directed transitions with validators) and Universal Managed Grouping Workflow (Epic and Sub-task, zero validators), in one shared scheme. Directed transitions are the gate, reversing NWM-110's 2026-09-14 cancellation of the previous-status validator; the repo's spec JSON converges them additively (2026-09-26).

## Why

Directed transitions replace the previous-status validator, which makes the land-branch hop (WO-68 trap) unnecessary.

## Cost

unrecorded in memory 5f180241
