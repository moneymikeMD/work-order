---
date: 2026-09-20
slug: the-work-order-plugin-publishes-from-the-repo-is-the-plugin
title: "The work-order plugin publishes from './': the repo is the plugin"
---

# The work-order plugin publishes from './': the repo is the plugin

## Decision

The work-order plugin uses source './' with .claude-plugin/marketplace.json and plugin.json together at the repo root, instead of copying or moving issues.py into plugins/work-order/ (WO-048, 2026-09-20). The plugin is versioned by the repository release; release-please's '.' package gained extra-files for plugin.json.

## Why

plugin.json promises the spec, reference implementation, file binding and validator, all at the repo root; copying would give a quarter of the promise or four drifting copies. emit.py also resolved decision-list/ outside the installed plugin.

## Cost

The plugin leaves its own work-order--v0.2.0 tag line and follows repo releases; a source './' mixed with subtree-source entries is UNVERIFIED in the memory.
