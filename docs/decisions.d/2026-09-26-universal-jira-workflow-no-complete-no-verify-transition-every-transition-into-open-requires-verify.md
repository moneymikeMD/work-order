---
date: 2026-09-26
slug: universal-jira-workflow-no-complete-no-verify-transition-every-transition-into-open-requires-verify
title: "Universal Jira workflow: no 'complete (no verify)' transition; every transition into Open requires verify"
---

# Universal Jira workflow: no 'complete (no verify)' transition; every transition into Open requires verify

## Decision

The 'complete (no verify)' In Progress to Completed transition is removed from Universal Managed Workflow because SPEC.md MUST-27 requires occupying awaiting-deployment first; every transition into Open, including the three re-open transitions, requires verify (2026-09-26, WO-79 review). The defer_until automation now targets Open.

## Why

The spec wins over the shortcut; gating all re-open paths closes the Triage to Cancelled to re-open to Open hole in MUST-7.

## Cost

The additive converge script cannot delete, so the transition is deleted by hand in Jira once.
