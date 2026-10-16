---
date: 2026-09-19
slug: work-order-sprint-is-a-filter-over-startable-tickets-never-a-blocked-by-inference
title: "work-order sprint is a filter over startable tickets, never a blocked_by inference"
---

# work-order sprint is a filter over startable tickets, never a blocked_by inference

## Decision

2026-09-19: the sprint extension groups tickets by timing, orthogonal to epic, and adds no blocking semantics; startable stays MUST-21. A later sprint waiting on an earlier one needs an explicit blocked_by edge (MUST-SPRINT-4). Wave computation stays out of scope.

## Why

Sprint groups by when and epic by what; narrowing must be additive so core startable semantics are never redefined.

## Cost

unrecorded in memory d737f1cd
