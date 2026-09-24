# decision-list: the mining/authoring seam

`decision-list` is the intermediate format between the two halves of
`to-issues`: a **producer** mines a settled conversation (a grilling session,
a planning thread) for decisions, and an **authoring** step turns each
decision into a ticket conforming to `SPEC.md`. This document specifies the
format that crosses that seam, so both halves can be built and tested against
a written contract rather than against each other.

A decision list is one JSON document. `decision-list/validate.py` checks it
against this document; `skills/emit-tickets/` consumes a
valid one and emits tickets.

## Why JSON, and why a separate field per concern

The producer half (night-watchman's mining step, WO-011) and the authoring
half (this ticket) are different processes running at different times,
sometimes different sessions. A format loose enough to let either side infer
structure from prose reintroduces exactly the coupling the split exists to
remove — see the "Decisions" section of this ticket. JSON keeps the schema
mechanically checkable and keeps the two sides honest about what they hand
each other.

Each field below exists because a numbered requirement in `SPEC.md` needs it
to produce a ticket at the **`full`** profile — not because it seemed useful.
Where a field maps directly to a requirement, the requirement is cited.

## Top-level shape

```json
{
  "decision_list_version": "0.1.0",
  "source": "free-text pointer to where this list came from (optional)",
  "decisions": [ /* one object per decision, see below */ ]
}
```

| Field | Type | Required |
| --- | --- | --- |
| `decision_list_version` | string | yes — this document's version, `MAJOR.MINOR.PATCH` |
| `source` | string | no — a decision-record id, a session summary title, anything a reader can use to trace the list back to where the decisions were made |
| `decisions` | array of decision objects | yes — may be empty |

## A decision object

Every field below is required unless marked optional. `decision-list/validate.py`
rejects a list missing any of them, naming the field and the index.

| Field | Type | Maps to | Carries |
| --- | --- | --- | --- |
| `id` | string | `[MUST-1]` | Identity. `SHOULD-1` recommends `PREFIX-NNN`; the validator does not enforce the shape, only that it is non-empty and has no whitespace. |
| `title` | string | `[MUST-3]` | The outcome — what will be true when the work is done. |
| `problem` | string | `[MUST-30]` | The problem, from whoever has it. |
| `solution` | string | `[MUST-30]` | The solution. |
| `rationale` | array of `{choice, rejected}` | — | The decisions made and what was rejected. `choice` is a string; `rejected` is a list of strings (may be empty, but the key must be present — a decision with nothing rejected is still worth stating so). Not itself a numbered `SPEC.md` field, but it is exactly what the parent ticket's Problem statement asks every entry to carry, and `emit-tickets` renders it into the ticket body's Decisions section. |
| `out_of_scope` | string | `[MUST-31]` | The boundary — what this deliberately does not cover. |
| `executor` | `"agent"` \| `"human"` \| `"mixed"` | `[MUST-22]` | Who must execute it. |
| `human_steps` | array of strings | `[MUST-23]` | Required, and must be non-empty, when `executor` is `"mixed"`. Ignored otherwise. |
| `tags` | array of strings | `[MUST-6]` | May be empty. |
| `blocked_by` | array of strings | `[MUST-18]` | Ids this decision depends on. May be empty. **Scoped to this decision list only** — `decision-list/validate.py` does not check that an id resolves; `[MUST-19]` (every `blocked_by` id resolves in the set) is checked once the emitted tickets join the real ticket set, by the conformance validator or the tracker binding, not here. A decision list produced from one conversation is rarely the whole set its tickets will join. |
| `blocked_by_external` | array of strings | `[MUST-48]` | Optional. Dependencies on work outside the set, each naming what is waited on and optionally ending in a URL. A non-empty list makes the emitted ticket not startable until cleared. Passed through to the ticket unchanged. |
| `touches` | array of strings | `[MUST-13]`, `[MUST-14]` | Paths this decision's ticket owns. May be empty (e.g. for a `human` ticket), but the key must be present — `SHOULD-7` prefers an explicit empty list over an absent field. |
| `appends` | array of strings | `[MUST-16]` | Optional; defaults to empty. A path MUST NOT appear in both `touches` and `appends` (`[MUST-17]`) — the validator rejects a list that violates this. |
| `verify` | string | `[MUST-7]`, `[MUST-8]` | The command or commands that prove the work is done, and what counts as passing. |
| `verify_fails_today` | string | `[MUST-9]`, `[MUST-10]` | The specific, concrete observation that fails at the base state — named plainly enough that a reader can confirm the claim without running anything. Kept as its own field (rather than folded into `verify`'s prose) so it is impossible to omit without the validator noticing. `emit-tickets` renders it as the trailing comment line of the emitted `verify:` block. |
| `created` | string, `YYYY-MM-DD` | `[MUST-4]` | RFC 3339 full-date. |
| `updated` | string, `YYYY-MM-DD` | `[MUST-4]` | Optional; `emit-tickets` defaults it to `created` for a freshly emitted ticket. |

### What this format deliberately leaves out

**Lifecycle position.** A decision list describes work not yet started — every
entry becomes a ticket at the `open` position, which the binding represents
however it represents `open` (`[MUST-25]`, `[MUST-26]`). The format carries no
status field because there is only ever one status a freshly emitted ticket
can have.

**`defer_until` and `epic`.** Reserved names (`SPEC.md` section 9). A producer
that needs them can add them to a decision object; `emit-tickets` passes any
field it does not recognise straight through to the ticket's frontmatter,
rather than dropping it, so a decision list is forward-compatible with fields
this version of the format does not yet name.

**Anything the `unattended` profile adds** (`[MUST-34]`–`[MUST-38]`). This
format targets `full`, matching what `emit-tickets`' own end-to-end check
validates against. A decision list that happens to satisfy `unattended` too
(no field citing a conversation, every artefact locator-resolvable) produces a
ticket that does; the format does not require it.

## Validating a decision list

```
python3 decision-list/validate.py decision-list/examples/worked-example.json
```

Exits `0` and prints a one-line summary on a well-formed list. Exits `1` and
prints one line per problem, each naming the field and the entry, on a
malformed one — for example, a decision missing `verify` prints a line
containing `missing required field 'verify'`.

`decision-list/examples/worked-example.json` is a complete, valid decision
list with one entry. `decision-list/examples/invalid-missing-verify.json` is
the same entry with `verify` removed, kept as a fixture that proves the
validator actually rejects a malformed list rather than accepting anything
JSON-shaped.

## Emitting tickets

`skills/emit-tickets/` consumes a valid decision list and
writes one ticket file per decision into an output directory:

```
python3 skills/emit-tickets/emit.py \
  decision-list/examples/worked-example.json --out /tmp/out/
```

See that skill's `SKILL.md` for the file binding it emits against and what it
does with a decision list `decision-list/validate.py` rejects.
