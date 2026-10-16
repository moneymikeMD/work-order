---
date: 2026-09-19
slug: work-order-spec-profile-membership-is-one-inline-token-per-requirement-not-a-per-profile-list
title: "work-order SPEC profile membership is one inline token per requirement, not a per-profile list"
---

# work-order SPEC profile membership is one inline token per requirement, not a per-profile list

## Decision

2026-09-19, SPEC.md 0.1.0: each requirement carries one inline token naming the lowest profile it applies at, profiles nest (minimal 26, full +25, unattended +6), and a validator computes membership by parsing the tokens. Identifiers are permanent. Appendix B is a substrate-neutral field listing, not YAML.

## Why

A duplicated per-profile list would drift from the requirements; YAML in the core would read as endorsing the file binding.

## Cost

unrecorded in memory 2edea6ee
