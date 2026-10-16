---
date: 2026-09-26
slug: jira-issue-type-schemes-and-screens-consolidate-into-two-shared-tiers-managed-simplified
title: "Jira issue type schemes and screens consolidate into two shared tiers (Managed, Simplified)"
---

# Jira issue type schemes and screens consolidate into two shared tiers (Managed, Simplified)

## Decision

All four per-project layers (issue type scheme, issue type screen scheme, screen schemes, screens) consolidate into two tiers: Universal Managed (WO, LAB, NWM, CHR, CMB) with a Ticket Screen carrying the 7 contract fields and a standard-only Grouping Screen, and Universal Simplified (EBS, TDA, TDO) with one screen and no contract fields (2026-09-26). The repo declares them and universal-apply.sh and universal-switch.sh assign them.

## Why

The tiers match the consolidated workflows; the grill found outcome missing from several per-project screens.

## Cost

Rollout needs a pilot on WO then the other 7 projects, and deletion of old per-project objects.
