# work-order: the ticket contract

This document specifies what a **ticket** is: a unit of work that carries enough
with it to be picked up by someone, or something, that was not present when it
was written, executed to completion, and proven done.

It specifies the contract, not a file format and not a tracker. Where a ticket
lives — as a file on disk, as an issue in a tracker, as a row in a database — is
the concern of a **binding**, and bindings are specified separately against the
numbered requirements below.

## Status of this document

Specification version: see `VERSION-spec`, alongside this file.

The specification versions independently of any implementation that satisfies
it. A claim of conformance cites the specification version and a profile, not a
package version.

The key words MUST, MUST NOT, REQUIRED, SHOULD, SHOULD NOT and MAY are to be
interpreted as described in RFC 2119 and RFC 8174, and only when they appear in
capitals.

## How to read a requirement

Every normative requirement is one paragraph beginning at the left margin with
its identifier and the lowest profile at which it applies:

```
[MUST-N] `minimal` — the obligation, stated in one paragraph.
```

The identifier is permanent. A requirement is never renumbered and an
identifier is never reused, so `MUST-9` cites the same obligation in every
version of this document that contains it. A withdrawn requirement keeps its
identifier and is marked withdrawn in place.

The profile token is the *lowest* profile at which the requirement applies.
Profiles nest — `minimal` ⊂ `full` ⊂ `unattended` — so a requirement marked
`full` also applies at `unattended`, and a requirement marked `minimal` applies
everywhere. This is the only statement of profile membership in the document;
there is no second list to drift out of step with it.

MUST requirements gate conformance at any profile that includes them. SHOULD
requirements are reported and never gate.

## Terminology

**Ticket** — one unit of work with an identity, a problem, a solution, and a
means of proving it done.

**Ticket set** — the collection of tickets a single implementation manages
together. Identifiers are unique within a set and dependencies resolve within
it.

**Substrate** — where the tickets physically live. A directory tree, a tracker,
a database.

**Binding** — a normative mapping from this specification onto one substrate.

**Base state** — the state of the world immediately before any of a ticket's
work is applied. Where the substrate is a version-controlled tree this is the
base commit.

**Executor** — whatever performs the work: a person, an automated agent, or
both in turn.

**Startable** — a ticket that may be picked up right now, defined precisely by
`[MUST-21]`.

**Entry state** — the lifecycle position a ticket occupies when it is
written, before it is a contract: `triage`.

**Terminal** — a lifecycle position from which a ticket does not move again:
`completed` or `cancelled`.

## 1. Identity and metadata

[MUST-1] `minimal` — Every ticket MUST carry an `id` that is unique within its
set.

[MUST-2] `minimal` — An `id` MUST NOT be reused, including after the ticket it
named was cancelled or removed. Identifiers are cited from commits, from other
tickets and from documentation that outlives the ticket, and a reused identifier
silently redirects every one of those citations.

[MUST-3] `minimal` — Every ticket MUST carry a `title` stating what will be
true when the work is done.

[MUST-4] `minimal` — Every ticket MUST carry `created` and `updated` as RFC
3339 full-dates (`YYYY-MM-DD`).

[MUST-5] `full` — `updated` MUST be advanced whenever the ticket's lifecycle
position or acceptance contract changes.

[MUST-6] `full` — A ticket MUST carry `tags` as a flat list of strings, which
MAY be empty.

[SHOULD-1] `minimal` — An `id` SHOULD take the form `PREFIX-NNN`, where the
prefix names the project or repository the set belongs to.

[SHOULD-2] `full` — The tag vocabulary of a set SHOULD stay small enough that a
reader can hold it in mind. Tags exist to filter a set, and a vocabulary as
large as the set filters nothing.

## 2. The acceptance contract

This section is the reason the specification exists. Everything else describes
how work is organised; this describes how work is proven.

[MUST-7] `minimal` — Every ticket whose lifecycle position is not `triage` and
not `cancelled` MUST carry `verify`. `triage` is excused by `[MUST-46]`: a
ticket there is not yet a contract.

[MUST-8] `minimal` — `verify` MUST state the command or sequence of commands
that proves the work is done, and the result that counts as passing.

[MUST-9] `minimal` — **`verify` MUST be capable of failing at the base state.**

A check that already passes before the work starts grades nothing. It will read
as done on the day the ticket is written, and it will keep reading as done
whether or not anything was built. This is the most frequently violated
requirement in this document and the most expensive, because a ticket carrying
one looks finished from every angle an audit can reach.

[MUST-10] `minimal` — `verify` MUST record the specific observation that fails
at the base state, so that the same command turning green is evidence the ticket
changed something.

The observation is part of the check, not commentary on it. "The file does not
exist today", "the endpoint returns 404 today", "the flag is not accepted
today" — named concretely enough that a reader can confirm the claim without
running anything.

[MUST-11] `minimal` — `verify` MUST NOT accept, as evidence of completion, that
something was deployed, that a build succeeded, or that a process started and
reported itself healthy.

A service that starts, reports healthy and does nothing is the ordinary failure,
not an exotic one. A collector with a bad credential does exactly this.

[MUST-12] `minimal` — A ticket MUST NOT reach `completed` unless its `verify`
has been executed and passed.

[SHOULD-3] `minimal` — `verify` SHOULD be executed at the base state before the
work begins, and the failure recorded. Reasoning that it would fail is weaker
evidence than watching it fail, and costs more later.

[SHOULD-4] `minimal` — Where a person must genuinely observe something — a
rendered page, a physical indicator — `verify` SHOULD say so plainly, and
`executor` SHOULD be `human` or `mixed`. An honest manual check is worth more
than a command that appears to test something it does not.

[SHOULD-5] `minimal` — `verify` SHOULD yield the same result when run a second
time on an unchanged state.

## 3. Parallel safety

Two executors working a set at the same time is the case this section exists
for. The declarations below are what make that safe rather than merely
attempted.

[MUST-13] `full` — A ticket whose `executor` is `agent` or `mixed` MUST declare
`touches`.

[MUST-14] `full` — `touches` MUST enumerate every path the ticket creates or
modifies, as literal paths or globs, relative to a root the set defines.

[MUST-15] `full` — Two tickets that are simultaneously startable MUST NOT share
a `touches` path. An implementation MUST report such an overlap as an error.

`touches` means "this ticket owns edits to that path". Two owners of one path,
both startable, is a merge conflict scheduled in advance, and the cost lands on
whoever untangles it rather than on whoever created it.

[MUST-16] `full` — `appends` MUST be used only for paths whose concurrent
modification merges without human reasoning: registers, decision logs,
changelogs. An overlap in `appends` between startable tickets MUST be reported
as a warning and MUST NOT block them.

The distinction is the whole mechanism. Nearly every ticket writes to the same
few shared logs; treating those as owned paths would serialise the entire set
and remove the reason for declaring paths at all. The test is what two
simultaneous edits produce. If it is a conflict someone has to reason about, the
path is `touches`. If it is two entries in different places, it is `appends`.

[MUST-17] `full` — A path MUST NOT appear in both `touches` and `appends` on
the same ticket.

[SHOULD-6] `full` — `touches` SHOULD be generous. An unlisted path becomes a
conflict a person resolves; an over-listed one costs a little unnecessary
serialisation, which is cheaper by a wide margin.

[SHOULD-7] `full` — A ticket that modifies nothing under the set's root SHOULD
declare an empty `touches` and name what it changes elsewhere, rather than
leaving the field absent.

[SHOULD-8] `full` — Two tickets that cannot avoid sharing an owned path SHOULD
be merged into one, or serialised by a `blocked_by` edge.

## 4. Dependencies and startability

[MUST-18] `full` — A ticket MUST carry `blocked_by` as a list of identifiers in
the same set, which MAY be empty.

[MUST-19] `full` — Every identifier in `blocked_by` MUST resolve to a ticket in
the set. An unresolvable identifier MUST be reported as an error.

[MUST-20] `full` — A ticket MUST NOT appear in its own `blocked_by`, directly or
transitively.

[MUST-21] `full` — A ticket is **startable** exactly when its lifecycle
position is `open`, every ticket named in its `blocked_by` has reached a
terminal position, and it carries no `defer_until` still in the future. An
implementation MUST NOT present any other ticket as available to pick up.

The three other positions a live ticket can occupy are each excluded for their
own reason: `triage` because the ticket is not yet a contract (`[MUST-46]`),
`deferred` because its own date has not passed (`[MUST-47]`), and
`in-progress` because somebody already picked it up.

## 5. Executor

[MUST-22] `full` — `executor` MUST be exactly one of `agent`, `human` or
`mixed`.

**`agent`** — an automated executor can complete it end to end, verification
included.

**`human`** — impossible for an automated executor. Creating an account,
approving a prompt on a device, paying for something, plugging in a cable,
clicking through a console with no API, deciding something only the owner can
decide. These tickets belong in the set; they are frequently what blocks
everything else.

**`mixed`** — an automated executor does the work and a person performs listed
steps. The common shape is that the automated part prepares a change and the
person applies it somewhere the automation cannot reach.

[MUST-23] `full` — A ticket declaring `executor: mixed` MUST carry
`human_steps`, enumerating each action the person performs and therefore where
the automated part stops.

[MUST-24] `full` — A ticket whose completion requires an action no automated
executor can perform MUST NOT declare `executor: agent`.

Misclassification is expensive in both directions, which is why this is a
requirement rather than a hint. An `agent` ticket that secretly needs a person
occupies an executor until it gives up, and produces nothing. A `human` ticket
an automated executor could have finished waits for a person who has better
things to do.

[SHOULD-9] `full` — Where `human_steps` runs past a few actions, or asks the
person to handle a secret value, the ticket SHOULD deliver a guided flow the
person runs instead of prose they follow.

## 6. Lifecycle

Status is a **position in a lifecycle**, not an opinion recorded in a field. The
positions are fixed; how a substrate represents them is a binding's concern.

[MUST-25] `minimal` — An implementation MUST represent seven lifecycle
positions, in this order: `triage`, `open`, `in-progress`,
`awaiting-deployment`, `deferred`, `completed` and `cancelled`. `triage` is the
entry state. `completed` and `cancelled` are terminal.

| Position | Is |
| --- | --- |
| `triage` | written, not yet a contract — the entry state (`[MUST-46]`) |
| `open` | a contract, ready to be picked up |
| `in-progress` | somebody has it |
| `awaiting-deployment` | landed, not yet running (`[MUST-27]`) |
| `deferred` | parked until a date, not until an event (`[MUST-47]`) |
| `completed` | terminal |
| `cancelled` | terminal (`[MUST-28]`) |

`open` is the position `[MUST-21]` turns on, and it has one definition: a ticket
that is ready to be worked on; it meets the set's criteria as something that is
startable. It is reached when the contract is written, not when somebody intends
to start it.

Five of these were in version 0.1 of this document. `triage` and `deferred` were
not, and both were already running in the practice this specification was
extracted from — measured on its prototype project on 2026-09-20, `triage` held
the second-largest share of the set. A specification that omits a position its
own prototype runs is not describing a simpler lifecycle; it is describing one
that does not exist.

[MUST-26] `minimal` — A ticket's lifecycle position MUST have exactly one
representation. No second field, location or marker may also carry it.

Two representations of one position drift, and the drift is silent: each reader
consults whichever one supports what they already believe. A binding chooses a
single representation — a directory, a tracker status, a column — and derives
everything else from it.

[MUST-27] `full` — `awaiting-deployment` MUST be distinct from `completed`, and
a ticket MUST occupy it before reaching `completed`.

Nothing deploys itself because code merged. "Landed" and "running" are different
facts, and collapsing them is how a set fills with work that is believed
finished and is not. Where the landing itself is the deployment, the position is
brief; it is not optional.

[MUST-28] `minimal` — A ticket in `cancelled` MUST carry `outcome`, stating why
the work was dropped and naming its replacement if there is one.

An empty `outcome` is worse than no ticket: the reader learns the idea was
considered and not why it lost, so they derive it again.

[MUST-29] `full` — A ticket whose premise turns out to be false MUST be
cancelled rather than removed. The false premise is the part worth keeping.

[MUST-46] `minimal` — `triage` is the **entry state**: the position a ticket
occupies when it is written and before it is a contract. A ticket at `triage`
MUST NOT be presented as startable, and no requirement of this document other
than `[MUST-1]`, `[MUST-3]` and `[MUST-4]` binds a ticket while it is there.

This is what `triage` is for. A ticket written on request has an identity, a
title and a date; it does not yet have a verification capable of failing, a
boundary, or a settled set of owned paths. Without an entry state the ticket is
either instantly non-conforming or instantly workable, and both are wrong: the
first makes the set red for doing the ordinary thing, and the second hands an
executor a contract nobody wrote. `triage` is the interval in which the rest of
this document is satisfied, and leaving it is the assertion that it has been.

[MUST-47] `minimal` — A ticket at `deferred` MUST carry `defer_until`, and MUST
NOT be presented as startable. `deferred` is the one position whose exit is
time-based rather than caused by work: a ticket leaves it for `open` when
`defer_until` has passed.

A parked ticket carrying no date is indistinguishable from an abandoned one,
and it is nobody's job to look at it again. `defer_until` is what makes
`deferred` a position rather than a hole — it states when the ticket becomes
workable, which is what lets something other than a person move it back out.
`deferred` is not terminal and does not satisfy a `blocked_by`.

[SHOULD-10] `full` — A lifecycle transition SHOULD be recorded together with
the change that caused it, or on its own. Batching a transition with unrelated
work forges a connection in the history that nobody made.

## 7. The body

[MUST-30] `minimal` — A ticket MUST carry a statement of the problem, from the
point of view of whoever has it, and a statement of the solution.

[MUST-31] `full` — A ticket MUST carry an explicit out-of-scope boundary,
naming what it deliberately does not cover.

The boundary is not documentation. It is the instruction that tells an executor
where to stop, and without it the executor decides, which is how a bounded
ticket becomes a refactor nobody asked for.

[MUST-32] `full` — Once a ticket is startable, its body MUST NOT change except
when its acceptance contract changes — `verify`, `human_steps`, `blocked_by`,
`touches`, or the solution itself.

[MUST-33] `full` — Progress narration MUST NOT be written into a ticket's body.
Progress belongs wherever the substrate records commentary, or in the project's
decision log.

The body is what a fresh executor reads to learn what done means. A body that
grows a section per working session buries that contract under the narration of
sessions that are over.

[SHOULD-11] `minimal` — A ticket SHOULD be short enough to read before starting
it. Extended rationale SHOULD live in a decision record the ticket names.

## 8. Starting cold

This section is what the `unattended` profile adds, and it is written to one
test: everything here is a property of the ticket, describing what the ticket
must carry in order to be started with nobody present. Nothing here describes
what an executor, a scheduler or a dispatcher does. A requirement that cannot be
written as a property of the ticket does not belong in this specification.

[MUST-34] `unattended` — A ticket conforming at this profile MUST declare
`executor: agent`. A ticket that needs a person at any point cannot be started
without one.

[MUST-35] `unattended` — Its `verify` MUST be executable without interaction:
no prompt, no value typed in by a person, no human observation as the deciding
step.

[MUST-36] `unattended` — It MUST NOT cite a conversation, a message, a meeting
or a person as the source of anything needed to execute it. Phrases of the form
"as discussed", "as we agreed", "see above" and "per our conversation" name
something that will not exist when the ticket is picked up.

[MUST-37] `unattended` — Every artefact it depends on MUST be named by a
locator resolvable from the ticket alone: a path, an identifier, a URL.

[MUST-38] `unattended` — Every choice the solution depends on MUST already be
settled in the ticket. With nobody present there is nobody to ask, and an
unsettled choice becomes either a stall or a guess nobody can audit.

[SHOULD-12] `unattended` — Settled choices SHOULD be stated in the ticket
rather than referenced in an external log, because an executor starting cold may
not be able to reach the log.

## 9. Reserved field names

An implementation MAY carry fields beyond those specified here. The following
names are reserved by this specification, so that two implementations do not
give one name two meanings.

`defer_until` — an RFC 3339 full-date before which the ticket is not startable,
regardless of `blocked_by`. It is required of a ticket at `deferred`
(`[MUST-47]`) and permitted at any other position.

`epic` — the identifier of a grouping the ticket belongs to.

[MUST-39] `minimal` — An implementation that carries a field named
`defer_until` or `epic` MUST give it the meaning stated in this section. No
profile requires either field.

## 10. Conformance profiles

A conformance claim names this specification's version and exactly one profile.
The profiles nest, so a claim at a higher profile implies the ones below it.

[MUST-40] `minimal` — A conformance claim MUST cite the specification's MAJOR
and MINOR version and exactly one profile name.

### Profile: minimal

**A ticket is a contract.** An identity, a problem, a solution, and a
verification capable of failing. This is the floor below which a ticket proves
nothing, and it assumes no automation, no parallelism and no tracker.

Membership: every requirement marked `minimal`.

### Profile: full

**A set is workable by more than one executor at once.** Adds path ownership,
dependencies and startability, the executor classification, the complete
lifecycle, and the discipline that keeps a body readable as a contract.

Membership: every requirement marked `minimal` or `full`.

### Profile: unattended

**A ticket is startable cold, with nobody present.** Adds
self-containedness, non-interactive verification, and decisions settled in
advance.

Membership: every requirement in this document.

## 11. Bindings

A binding maps this specification onto one substrate. The core above says
nothing about syntax, storage or transport, and a binding says nothing that
contradicts the core.

[MUST-41] `minimal` — A binding MUST state, for every field it supports, the
concrete representation that field takes in its substrate.

[MUST-42] `minimal` — A binding MUST represent all seven lifecycle positions
of `[MUST-25]`, and MUST name the single representation it uses to satisfy
`[MUST-26]`.

[MUST-43] `minimal` — A binding MUST state each core requirement it cannot
satisfy, and why. A requirement a substrate cannot meet is a documented
limitation; a requirement silently omitted is a false conformance claim.

[MUST-44] `minimal` — A binding MUST NOT weaken or contradict a core
requirement. It MAY add requirements of its own, numbered in its own namespace
so that a citation is never ambiguous about which document it came from.

## 12. Versioning this specification

`VERSION-spec` carries this document's version as `MAJOR.MINOR.PATCH`. It is
advanced deliberately, by hand. It is not derived from commit messages and it
does not move because an implementation released.

**MAJOR** — any change that can turn a conforming implementation
non-conforming: a new MUST inside an existing profile, a tightened requirement,
a widened profile, a withdrawn identifier.

**MINOR** — an addition that cannot invalidate an existing claim: a new SHOULD,
a new profile, a new reserved field name, prose that narrows nothing.

**PATCH** — editorial only, with no normative effect.

While the version cap recorded in WO-060 is in force, a change this section
makes MAJOR is released as a MINOR instead, and the demotion is stated in the
change's own prose rather than carried as a marker. The cap is lifted by the
owner of this document, not by this section.

[MUST-45] `minimal` — A requirement identifier MUST NOT be renumbered or
reused. A withdrawn requirement MUST remain in the document, marked withdrawn,
so that an existing citation stays readable.

## Appendix A: field summary

Non-normative. The requirements above are authoritative where this table is
shorter than they are.

| Field | Required at | Carries |
| --- | --- | --- |
| `id` | `minimal` | Identity, unique in the set, never reused |
| `title` | `minimal` | What will be true when it is done |
| `created` | `minimal` | RFC 3339 full-date |
| `updated` | `minimal` | RFC 3339 full-date, advanced on every change |
| `verify` | `minimal`, unless cancelled | The proof, and what counts as passing |
| `outcome` | `minimal`, in `cancelled` | Why it was dropped, and what replaced it |
| `executor` | `full` | `agent`, `human` or `mixed` |
| `tags` | `full` | Flat list, possibly empty |
| `blocked_by` | `full` | Identifiers in the same set, possibly empty |
| `touches` | `full`, for `agent` and `mixed` | Paths this ticket owns |
| `appends` | optional | Shared paths that merge without reasoning |
| `human_steps` | `full`, when `mixed` | What the person does, and where automation stops |
| `defer_until` | `minimal`, in `deferred`; otherwise optional | Date before which it is not startable |
| `epic` | optional, reserved | Identifier of a grouping |

## Appendix B: an illustrative ticket

Non-normative, and deliberately not written in any binding's syntax — a core
example in one substrate's notation would read as the specification endorsing
that substrate. What follows is the field content a conforming ticket carries at
`unattended`.

```
id           WO-003
title        Write the tracker-agnostic ticket contract
created      2026-09-19
updated      2026-09-19
executor     agent
tags         spec, core
blocked_by   WO-001
touches      SPEC.md, VERSION-spec
appends      CHANGELOG.md
verify       test -f SPEC.md && test -f VERSION-spec
             grep -c '^\[MUST-[0-9]*\]' SPEC.md      # expect at least 10
             Today neither file exists, so both checks fail.

problem      The contract exists as working practice and no document owns it.
solution     Write it down, numbered, with profiles.
decisions    The specification is the product; a script is one implementation.
out of scope Bindings, the validator, packaging.
```

The `verify` block is the part worth studying. It names commands, it names what
counts as passing, and it names the observation that fails today. The last line
is what `[MUST-10]` requires and what most tickets omit.
