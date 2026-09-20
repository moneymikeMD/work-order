---
name: emit-tickets
description: Consume a decision-list JSON file (decision-list/FORMAT.md) and emit one ticket file per decision, conforming to SPEC.md's `full` profile. Use after a mining step (such as night-watchman's to-issues) has produced a decision list and the settled decisions need to become tickets on disk.
---

# emit-tickets

This is the authoring half of the seam `decision-list/FORMAT.md` defines. It
does one thing: turn a valid decision list into ticket files, and refuse to
turn an invalid one into anything.

## Use

```
python3 emit.py DECISION_LIST.json --out DIR
```

Writes one Markdown ticket file per decision into `DIR`, named
`<id>-<slug-of-title>.md`. Each file carries YAML frontmatter (`id`, `title`,
`created`, `updated`, `executor`, `tags`, `blocked_by`, `touches`, `appends`
when non-empty, `human_steps` when `executor` is `mixed`, `verify`) and a body
with `## Problem`, `## Solution`, `## Decisions` and `## Out of scope`
sections — the file-shaped convention this repository's own tickets already
use.

## Validation is not optional

Before writing anything, `emit.py` runs the decision list through
`decision-list/validate.py`'s schema check. A decision list that fails it
produces **no files** — emit-tickets refuses partial output rather than
writing some tickets and silently skipping the malformed ones, because a
ticket set with an unexplained gap is worse than a run that stopped and said
why. Each rejection line names the field and the decision index, exactly as
running the validator directly would.

## What it does not do

- It does not check the emitted tickets against `SPEC.md` beyond what
  `decision-list/validate.py` already checks on the input — that is
  `conformance/validate.py`'s job (WO-006), run separately over the output
  directory.
- It does not check `blocked_by` ids against a wider ticket set, or detect
  `touches` overlap between tickets — both are properties of the whole set a
  decision list's tickets join, not of one emit run.
- It does not decide lifecycle position. Every emitted ticket represents
  `open`; moving it through the lifecycle is the tracker binding's concern.
- It never invents a value a decision list did not supply. A decision missing
  a required field is a refusal, not a guess.

## Extending the format

A decision object may carry fields beyond those `decision-list/FORMAT.md`
names — the reserved `defer_until` and `epic` fields, for instance. `emit.py`
passes any field it does not recognise straight into the ticket's
frontmatter unchanged, so a producer ahead of this skill's own field list
does not lose data.
