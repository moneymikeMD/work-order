---
date: 2026-09-19
slug: work-order-jira-binding-uses-seven-custom-fields-outcome-added-and-a-five-status-set
title: "work-order Jira binding uses seven custom fields (outcome added) and a five-status set"
---

# work-order Jira binding uses seven custom fields (outcome added) and a five-status set

## Decision

2026-09-19: the binding ships at plugins/work-order-jira, not bindings/jira. It provisions seven custom fields, adding outcome because MUST-28 needs it on cancelled tickets and Jira has no native field. Statuses are five; Triage and Deferred stay out. Completed requires previous status Awaiting Deployment (MUST-27).

## Why

A Space without outcome cannot represent a cancelled ticket at the minimal profile; the validator set follows the spec, not night-watchman's.

## Cost

unrecorded in memory d1eb325b
