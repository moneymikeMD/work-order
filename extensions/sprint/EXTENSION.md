# Extension: sprint

Status: optional. Nothing in `SPEC.md` requires this extension, cites it, or
changes meaning in its presence. A conformance claim under `[MUST-40]` names a
profile only; a set that also implements this extension states that
separately, alongside the profile claim, never in place of it.

This document defines the extension by citing the core specification's
numbered requirements. It does not restate them.

## What a sprint is in this model

A sprint is a named, bounded container that groups tickets by **when they are
meant to be worked**, not by what they are about. It exists to answer one
question an owner asks of a large set: how much goes into this run. That is a
batching policy, not a fact about any single ticket, which is why it sits here
and not in the core.

This is a different axis from `epic` (`§9`, reserved by the core): an epic
groups tickets by subject and has no notion of being open or closed for new
work; a sprint groups by timing and does.

## Relationship to `blocked_by` and startability

Sprint membership adds no new blocking semantics. `startable` is defined
exactly by `[MUST-21]` — lifecycle position `open` and every identifier in
`blocked_by` (`[MUST-18]`–`[MUST-20]`) at a terminal position — and this
extension leaves that computation untouched. A ticket in a later sprint that
must wait on one in an earlier sprint is expressed the ordinary way: as an
edge in `blocked_by`. Sprint order is never read as an implicit dependency; an
implementation MUST NOT infer a `blocked_by` edge from sprint membership or
sprint order.

What sprint membership adds is a second, narrower question asked *after*
`[MUST-21]` has answered the first: of the tickets that are startable, which
are in view for this run. An implementation supporting this extension answers
that by filtering the startable set to the active sprint, the same scope
already proven in this project as touched-ticket/active-sprint lint scoping.
Narrowing to a sprint MUST NOT be implemented by giving a ticket a second
lifecycle representation (`[MUST-26]`) — it is a filter over the existing
`startable` set, not a competing status.

## Relationship to wave computation

A wave — a batch of startable tickets grouped for parallel dispatch by
disjoint `touches` (`[MUST-15]`) — is computed over whatever set is in view.
Under this extension, that set is the active sprint's startable tickets rather
than the whole set. The grouping itself, and the dispatch that acts on it, are
not properties of a ticket and do not belong here; per this ticket's own
out-of-scope boundary, they stay in night-watchman as its layer-2 concern.
This extension defines only the input wave computation is scoped to, not how
it computes.

## What an implementation must do

[MUST-SPRINT-1] `sprint` — An implementation declaring this extension MUST
represent a sprint's own lifecycle — at least `planned`, `active`, and
`closed` — separately from a ticket's lifecycle (`[MUST-25]`). A ticket's
lifecycle position is unaffected by its sprint's.

[MUST-SPRINT-2] `sprint` — A ticket set implementing this extension MUST carry
`sprint` on every ticket that has one, as an identifier resolving to exactly
one sprint in the set. A ticket with no `sprint` field is not overdue or
unplanned by that omission alone; it is simply outside this extension's
bookkeeping for that ticket.

[MUST-SPRINT-3] `sprint` — At most one sprint SHOULD be `active` at a time.
Where an implementation departs from this — mirroring a tracker that permits
several — it MUST state which sprint (or sprints) "the active sprint" resolves
to wherever this extension's scoping (see above) is applied.

[MUST-SPRINT-4] `sprint` — Narrowing the startable set to the active sprint
MUST be additive: it changes what is *presented*, never what `[MUST-21]`
computes as startable. A ticket outside the active sprint that is startable by
`[MUST-21]` remains startable; an implementation MAY choose not to surface it
in a given view, but MUST NOT report it as blocked or not-yet-open on that
basis alone.

[SHOULD-SPRINT-1] `sprint` — A closed sprint SHOULD be immutable: tickets
SHOULD NOT be added to it after closing. A ticket discovered after the fact
belongs to the sprint underway, not retroactively to one already closed.

## Out of scope

Wave computation and dispatch (night-watchman's layer-2 concern, unchanged by
this extension). How a sprint is provisioned or represented in a given
tracker — that is a binding's concern, per `[MUST-41]`–`[MUST-44]`, for
whichever binding chooses to support this extension. A required cadence,
duration, or naming convention for sprints — this extension defines the
mechanism, not a policy for using it.
