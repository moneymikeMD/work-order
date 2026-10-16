---
date: 2026-10-03
slug: repo-path-is-the-canonical-cross-repo-form-for-touches-and-appends-slash-form-only-for-the-ticket-set-s-own-repo
title: "repo:path is the canonical cross-repo form for touches and appends; slash form only for the ticket set's own repo"
---

# repo:path is the canonical cross-repo form for touches and appends; slash form only for the ticket set's own repo

## Decision

repo:path is canonical (prefix matches a checkout by directory basename, trailing path or git remote repo name). repo/path is a legacy spelling recognised only when it names the ticket set's own repo, where lint warns citing SHOULD-13; a foreign slash prefix is read as a literal path (WO-94, owner 2026-10-03, work-order 3b0d94a).

## Why

Two rules for recognising foreign slash prefixes both failed review: probing sibling dirs for .git made lint depend on cwd, and deriving prefixes from colon forms produced a false gating overlap error.

## Cost

Reaches reviewers only after a work-order release newer than v1.9.0 plus a plugin update.
