---
date: 2026-09-24
slug: an-external-blocker-is-a-reserved-blocked-by-external-field-not-a-placeholder-ticket
title: "An external blocker is a reserved blocked_by_external field, not a placeholder ticket"
---

# An external blocker is a reserved blocked_by_external field, not a placeholder ticket

## Decision

work-order SPEC.md 0.3.0 reserves blocked_by_external (a list of free-text dependencies, each optionally ending in a URL); MUST-48 at profile full makes a non-empty list mean not startable (WO-70, 2026-09-24).

## Why

Chosen over a placeholder-ticket convention because it makes the dependency visible to the tool without inventing tickets for work the set does not own.

## Cost

A new MUST in an existing profile is MAJOR per SPEC section 12, demoted to MINOR under the WO-060 cap; implemented across issues.py, validate.py, Jira field table, both BINDING.md files and FORMAT.md; waves.py must honour it later.
