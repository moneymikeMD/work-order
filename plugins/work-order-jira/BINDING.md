# The Jira binding

This document is a **binding** in the sense of `SPEC.md` section 11: a normative
mapping of the work-order ticket contract onto one substrate, here Jira Cloud
company-managed projects.

Specification bound: work-order **0.1**, as published in `SPEC.md` and
`VERSION-spec` at the root of this repository.

This binding is versioned independently of the specification and of the
`work-order` plugin. Its version is the one in
`plugins/work-order-jira/.claude-plugin/plugin.json`, released under the tag
`work-order-jira--vMAJOR.MINOR.PATCH`. Atlassian's API changes on its own
schedule; the core contract does not re-release because an endpoint moved.

Requirements added by this binding are numbered `[JIRA-N]`, per `[MUST-44]`, so
a citation is never ambiguous about which document it came from. This binding
adds no requirement that weakens or contradicts the core.

## 1. Substrate

A **ticket set** is one Jira project. Identifiers are unique within it and
`blocked_by` resolves within it.

The project must be **company-managed** (`style: "classic"`,
`projectTypeKey: "software"`) and created from the
`com.pyxis.greenhopper.jira:gh-simplified-scrum-classic` template. A
team-managed project has no shared workflow to place validators on, so the
lifecycle requirements below cannot be enforced in one.

`provision.sh` asserts that shape on the project readback rather than trusting
the template key it sent. `style` is computed from the template and has no
request-time equivalent, so a stale template key silently produces a Business
project instead.

## 2. Field representations — `[MUST-41]`

Every field named anywhere in the specification, and the concrete
representation it takes here.

| Field | Representation | Notes |
| --- | --- | --- |
| `id` | the issue key, `PROJECT-123` | Jira assigns it; not settable |
| `title` | `fields.summary` | |
| `created` | date part of `fields.created` | maintained by Jira |
| `updated` | date part of `fields.updated` | maintained by Jira |
| `verify` | custom field `verify`, `textarea` | free text, multi-line |
| `outcome` | custom field `outcome`, `textarea` | required to reach `cancelled` |
| `executor` | custom field `executor`, single `select` | options exactly `agent`, `human`, `mixed` |
| `tags` | `fields.labels` | Jira labels cannot contain spaces |
| `blocked_by` | inward `Blocks` issue links | "is blocked by" on the ticket |
| `touches` | custom field `touches`, `textarea` | one path or glob per line |
| `appends` | custom field `appends`, `textarea` | one path or glob per line |
| `human_steps` | custom field `human_steps`, `textarea` | one step per line |
| `defer_until` | custom field `defer_until`, `datepicker` | `[MUST-39]` meaning |
| `epic` | `fields.parent`, an issue type at `hierarchyLevel` 1 | `[MUST-39]` meaning |
| problem, solution, decisions, out-of-scope — `[MUST-30]`, `[MUST-31]` | `fields.description`, one heading per part | |

`created` and `updated` are RFC 3339 date-times in Jira and RFC 3339 full-dates
in the specification. The full-date is the date part in the project's own
timezone; the extra precision is carried, not discarded.

[JIRA-8] Custom field ids (`customfield_NNNNN`) are assigned per Jira site. An
implementation MUST resolve every field id by name at runtime and MUST NOT
carry a hardcoded id. A field id copied from one site is a wrong field, not a
missing one, on the next.

## 3. Lifecycle — `[MUST-42]`

**The single representation of a ticket's lifecycle position is the issue's
`status`.** Nothing else carries it.

| Position | Status | |
| --- | --- | --- |
| `open` | `Open` | |
| `in-progress` | `In Progress` | |
| `awaiting-deployment` | `Awaiting Deployment` | |
| `completed` | `Completed` | terminal |
| `cancelled` | `Cancelled` | terminal |

Jira offers several other places a position could appear to live, and none of
them is one: `fields.resolution`, the `statusCategory` (three values, not five),
a board column, a sprint, a label. An implementation MUST NOT read or write a
position anywhere but `status`, per `[MUST-26]`. `statusCategory` in particular
collapses `Open` and `Awaiting Deployment` differently than the lifecycle does
and cannot be derived back.

[JIRA-3] A ticket whose status is not one of the five above has no lifecycle
position under this binding. An implementation MUST report that as an error and
MUST NOT guess a position from the status name, its category, or its position on
a board. A project MAY carry other statuses for work outside the set.

[JIRA-4] The transition into each of the five statuses MUST be `GLOBAL`, so
every position is reachable from every other without a transition matrix. The
lifecycle's ordering is enforced by validators, named below, not by which
transitions exist.

## 4. Enforcement

These validators are what makes the contract gate rather than describe. They
are applied by `workflow-apply.sh` from `workflow-rules.json`, additively: a
rule already present is left alone, a missing one is appended, nothing is
removed.

| Transition | Validator | Serves |
| --- | --- | --- |
| `In Progress` | `verify` is required | `[MUST-7]`, `[MUST-8]` |
| `In Progress` | `touches` is required | `[MUST-13]`, tightened by `[JIRA-6]` |
| `Completed` | `verify` is required | `[MUST-7]` |
| `Completed` | previous status includes `Awaiting Deployment` | `[MUST-27]`, per `[JIRA-5]` |
| `Cancelled` | `outcome` is required | `[MUST-28]`, per `[JIRA-7]` |

[JIRA-5] The `Completed` transition MUST carry a previous-status validator
naming `Awaiting Deployment`. `[MUST-27]` says a ticket must occupy that
position before reaching `completed`; a tracker that merely offers the status
does not satisfy it, because the position that is skippable is the position that
gets skipped.

[JIRA-6] The `In Progress` transition MUST require `touches` for every ticket,
not only for the `agent` and `mixed` executors `[MUST-13]` names. Jira's
field-required validator cannot be made conditional on another field's value, so
the choice is between requiring it of everyone and requiring it of nobody. This
is stricter than the core, which `[MUST-44]` permits, and it is stated here
rather than left as a surprise: a `human` ticket in a conforming Space must
declare `touches`, or an empty `touches` per `[SHOULD-7]`.

[JIRA-7] The `Cancelled` transition MUST require `outcome`, per `[MUST-28]`.
`outcome` is not a Jira field; this binding defines it as a custom field, and a
Space without it cannot represent a cancelled ticket at all.

[JIRA-1] Every custom field this binding defines MUST be present on every tab
of every screen reachable from the project's issue-type screen scheme.

This is the single most expensive thing to get wrong here, and it has already
happened twice in production. A custom field that exists globally but is not on
a screen accepts no value: the API write returns a success the UI never shows,
so the Space looks conforming from every angle a spot check reaches and holds no
`verify` at all. `provision.sh` walks
`issuetypescreenscheme/project` → `issuetypescreenscheme/mapping` →
`screenscheme` → `screens/<id>/tabs` → `screens/<id>/tabs/<tab>/fields` and adds
what is missing. A provisioner that skips step 5 produces a Space that is not
conforming.

[JIRA-2] Every custom field this binding defines MUST be JQL-searchable, and
searchability MUST be proven with a JQL query rather than read from the field's
definition. `GET /field` reports `searcherKey` as `null` whether or not a
searcher is attached, and the failing query's HTTP 400 body contains no text
saying "not searchable" — the status code is the whole signal. Unsearchable
fields are not a cosmetic problem: the startability and overlap checks below are
JQL queries, and they return quietly wrong answers over a field JQL cannot see.

## 5. What this binding cannot satisfy — `[MUST-43]`

Stated, not omitted. A requirement silently left out would be a false
conformance claim.

**`[MUST-9]`, `[MUST-10]` — `verify` capable of failing at the base state, and
recording the observation that fails.** No tracker can evaluate either. A
validator can require the field to be non-empty and nothing more. These two
requirements are satisfied by review and by running the check at the base state,
outside Jira.

**`[MUST-12]` — no `completed` unless `verify` has been executed and passed.**
The `Completed` transition requires the field, and `[JIRA-5]` requires the
ticket to have passed through `awaiting-deployment`. Neither is evidence the
command ran. Jira cannot supply that evidence.

**`[MUST-15]` — simultaneously startable tickets MUST NOT share a `touches`
path, and an overlap MUST be reported as an error.** Jira has no validator that
can see another issue's field values, so the check runs outside the tracker over
a JQL query. `[JIRA-2]` exists to keep that query possible. Jira will not report
the overlap on its own.

**`[MUST-16]` — an `appends` overlap MUST be reported as a warning.** Same
reason, same place.

**`[MUST-19]`, `[MUST-20]` — every `blocked_by` resolves, and no ticket blocks
itself directly or transitively.** Jira creates a `Blocks` link between any two
issues without checking for a cycle, and will happily link across projects,
which a set boundary forbids. External check.

**`[MUST-21]` — startability, and an implementation MUST NOT present any other
ticket as available.** Startability is derived, not stored:

```
project = KEY AND status = Open
  AND (defer_until is EMPTY OR defer_until <= now())
  AND issueFunction not in linkedIssuesOf("...")   -- blockers not terminal
```

Jira's own boards and backlogs present tickets by rank and sprint and know
nothing about `blocked_by`, so a board is not a startable list. The set's
startable query is authoritative; the board is a view.

**`[MUST-32]` — a startable ticket's body MUST NOT change except when its
acceptance contract changes.** Jira permits any edit at any position. This is
enforced by review, and the edit history makes a violation visible after the
fact rather than preventing it.

**`[MUST-33]` — progress narration MUST NOT be written into the body.** Jira
comments are the substrate's place for commentary, and this binding directs
progress there. Nothing stops someone appending to `description` instead. A
dated section that reaches `description` anyway is caught by the conformance
check in section 9, after the fact.

**`[MUST-13]` — a ticket whose `executor` is `agent` or `mixed` MUST declare
`touches`.** A Jira textarea holds the same bytes for a list declared empty and
a field nobody filled in, so whether the ticket *declared* anything cannot be
read back off it. The requirement is enforced at the `In Progress` transition
instead, per `[JIRA-6]`, and more strictly than the core asks: every executor,
not only `agent` and `mixed`. The conformance check in section 9 reports it
`not-checkable` rather than passing a ticket it did not inspect.

**`[MUST-26]` — exactly one representation of the lifecycle position.** This is
a property of the binding, stated in section 3 and satisfied there, not
something a ticket set can present a violation of: `fields.status` is the only
place an implementation reads, so no ticket carries a second copy for a checker
to find. Reported `not-checkable` for the same reason.

## 6. What Jira satisfies without help

Worth stating, because each is a requirement an implementation might otherwise
try to enforce a second time.

**`[MUST-1]`, `[MUST-2]` — unique, never-reused identifiers.** Jira issue keys
are unique within a project and are never reissued, including after an issue is
deleted. A deleted project's key stays reserved site-wide, so the set's prefix
cannot be recycled either.

**`[MUST-4]`, `[MUST-5]` — `created` and `updated`.** Jira maintains both.
`updated` advances on every edit, which is at least as often as `[MUST-5]`
requires.

**`[MUST-6]`, `[MUST-18]` — `tags` and `blocked_by` may be empty.** Both
representations are naturally absent-or-empty.

## 7. Conformance claims

A claim names the specification version and one profile, per `[MUST-40]`, and
belongs to the ticket set rather than to this document.

[JIRA-9] A Space claiming conformance MUST carry the claim in the project's
description, naming the specification MAJOR.MINOR, the profile, and the version
of this binding the Space was provisioned with. Three artefacts version
separately here, and a claim naming only one of them cannot be checked.

A Space provisioned by `provision.sh` carries every field and every lifecycle
position the specification names, so it can support a claim at `minimal`, `full`
or `unattended`. Which profile a set actually claims depends on the content of
its tickets, not on the Space: the `unattended` requirements
(`[MUST-34]`–`[MUST-38]`) are properties of a ticket's text, which this
substrate stores and cannot check.

## 8. Checking conformance

A Space's tickets are checked against the specification by
`conformance/validate.py --source jira --fixture DIR`, where `DIR` is a
directory of **recorded** API responses:

```
jira-api.sh raw GET '/search/jql?jql=...&fields=...,description' > DIR/search.jql.json
jira-api.sh raw GET /field                                       > DIR/field.list.json
jira-api.sh raw GET /project/KEY                                 > DIR/project.json
python3 conformance/validate.py --source jira --fixture DIR --profile full
```

Recorded, not live, for two reasons. A check that needs a credential cannot run
in CI, which is where a conformance claim has to hold rather than in someone's
shell; and a recording is the artefact a claim can be re-checked against later,
which a query against a mutable Space is not.

`description` must be among the requested fields. It carries the ticket body,
and `[MUST-30]`, `[MUST-31]`, `[MUST-33]`, `[MUST-36]`, `[MUST-37]` and
`[MUST-38]` are checks on body text. `reference/issues.py` does not request it,
because its own checks never read a body.

Custom field ids resolve by name from `field.list.json`, per `[JIRA-8]`. Without
that file the reference implementation's ids are the fallback and `outcome`,
which has no id there, reads as absent — so a cancelled ticket would be reported
as violating `[MUST-28]` when the field is merely unresolved.

`[MUST-13]` and `[MUST-26]` are reported `not-checkable` under this binding, for
the reasons in section 5. Every other requirement the file binding checks is
checked here too.

## 9. Scripts

| Script | Does |
| --- | --- |
| `provision.sh` | creates or converges a conforming Space, `--dry-run` first |
| `workflow-apply.sh` | provisioning step 3 on its own: statuses, transitions, validators |
| `provider.sh` | the tracker verbs — `fetch`, `position`, `transition`, `comment`, `create` |
| `lib/jira-http.sh` | the one credentialed HTTP client, and the seam a test stubs |
| `selftest.sh` | offline; stubs the client and asserts on the decisions the scripts reach |

`provider.sh transition KEY <position>` takes a lifecycle position, not a
transition id, and resolves it against the live issue. That is the lifecycle
table in section 3 made executable: if the table and the Space disagree, the
call fails instead of moving the ticket somewhere else.
