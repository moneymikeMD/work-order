# The Jira binding

This document is a **binding** in the sense of `SPEC.md` section 11: a normative
mapping of the work-order ticket contract onto one substrate, here Jira Cloud
company-managed projects.

Specification bound: work-order **0.2**, as published in `SPEC.md` and
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
| `blocked_by_external` | custom field `blocked_by_external`, `textarea` | one dependency outside the set per line, `[MUST-48]` meaning |
| `touches` | custom field `touches`, `textarea` | one path or glob per line |
| `appends` | custom field `appends`, `textarea` | one path or glob per line |
| `human_steps` | custom field `human_steps`, `textarea` | one step per line |
| `defer_until` | custom field `defer_until`, `datepicker` | `[MUST-39]` meaning |
| `epic` | `fields.parent`, an issue type at `hierarchyLevel` 1 | `[MUST-39]` meaning, written per `[JIRA-20]` |
| problem, solution, decisions, out-of-scope — `[MUST-30]`, `[MUST-31]` | `fields.description`, one heading per part | |

`created` and `updated` are RFC 3339 date-times in Jira and RFC 3339 full-dates
in the specification. The full-date is the date part in the project's own
timezone; the extra precision is carried, not discarded.

[JIRA-8] Custom field ids (`customfield_NNNNN`) are assigned per Jira site. An
implementation MUST resolve every field id by name at runtime and MUST NOT
carry a hardcoded id. A field id copied from one site is a wrong field, not a
missing one, on the next.

### 2.1 Groupings

[JIRA-16] An issue whose type sits at `hierarchyLevel` 1 (Epic) or -1
(Sub-task) is not a ticket. An Epic is a grouping, the thing a ticket's `epic`
field names; a Sub-task is a step of its parent, and the parent carries the
contract. A reader MUST skip both when it assembles the ticket set, so no
ticket requirement, startability rule or `touches` collision check applies to
them. The level is read from `fields.issuetype.hierarchyLevel`; only when a
response omits it does the type name decide (`Epic`, `Sub-task`, `Subtask`).
Both types run the Grouping workflow, which carries no validators.

[JIRA-20] A ticket's `epic` is written as `fields.parent`, naming an issue at
`hierarchyLevel` 1, and only on a ticket (level 0). An implementation MUST read
the target's level before it writes and MUST NOT write a parent at any other
level, and MUST read the ticket back after writing and fail unless the parent
took. The epic need not exist when the ticket is written: a ticket filed before
its epic is written without one, and given it once the epic exists. An epic is
set apart from a link here because it is a field: a ticket has one, so moving it
to another epic replaces the old value rather than adding a second.

## 3. Lifecycle — `[MUST-42]`

**The single representation of a ticket's lifecycle position is the issue's
`status`.** Nothing else carries it.

| Position | Status | |
| --- | --- | --- |
| `triage` | `Triage` | the entry state, `[MUST-46]` |
| `open` | `Open` | ready to work |
| `in-progress` | `In Progress` | |
| `awaiting-deployment` | `Awaiting Deployment` | |
| `deferred` | `Deferred` | exit is time-based, `[MUST-47]` |
| `completed` | `Completed` | terminal |
| `cancelled` | `Cancelled` | terminal |

[JIRA-15] Retired (WO-81). It bound the `open` position to the Jira status
`Open` and defined two legacy aliases, `To Do` → `open` and `Done` →
`completed`, so a Space still on the Jira project template stayed readable.
The Universal Managed Workflow Scheme now used by every contract project has
no `To Do` and no `Done` status, so there is nothing left for an alias to
translate; `open` binding to `Open` is stated once, plainly, in the table
above, with no special requirement number needed.

Jira offers several other places a position could appear to live, and none of
them is one: `fields.resolution`, the `statusCategory` (three values, not
seven), a board column, a sprint, a label. An implementation MUST NOT read or
write a position anywhere but `status`, per `[MUST-26]`. `statusCategory` in
particular collapses `Triage`, `Open` and `Deferred` into one value and cannot
be derived back.

The workflows still keep `fields.resolution` accurate for Jira's own reports and
filters: `complete` sets it to `Done`, every `cancel` to `Won't Do`, and
`re-open`, `re-work` and the grouping workflow's `Continue Progress` clear it.
These are `system:update-field` actions in `universal-workflows.json`. They
record the outcome for Jira; they do not make resolution a second
representation of the position, and no implementation reads it.

[JIRA-3] A ticket whose status is not one of the seven above has no lifecycle
position under this binding. An implementation MUST report that as an error
and MUST NOT guess a position from the status name, its category, or its
position on a board. A project MAY carry other statuses for work outside the
set. A ticket found in `To Do` or `Done` — the scrum template's own ready and
closed statuses — is a stray under this rule like any other unmapped status;
the read-only aliases that used to translate them were retired in WO-81 once
every contract project moved onto the Universal Managed Workflow Scheme,
which carries neither status.

[JIRA-11] An implementation reporting a ticket's position MUST distinguish "the
status is not one this binding binds" from "the position could not be read",
with an exit status or a parseable token of its own — not with prose a caller
has to match. A conforming Space produces no unmapped status; a caller reading a
Space that is not conforming still has to tell a ticket parked outside the
lifecycle apart from a broken read, and matching an error message is not a
contract. `provider.sh position` exits **4** and prints
`unmapped-status<TAB><status name>` for the first, and exits 1 for the second.

[JIRA-4] Retired (WO-79). It required every lifecycle transition to be
`GLOBAL` and left the ordering to validators. The shared workflow of section 3.1
uses directed transitions instead, so the ordering is carried by which
transitions exist, per `[JIRA-18]`.

### 3.1 The shared workflows and scheme

The lifecycle lives in two **global** workflows under one shared workflow
scheme. No project carries a copy of its own.

| Workflow | Issue types | Statuses | Validators |
| --- | --- | --- | --- |
| `Universal Managed Workflow` | `Task`, `Story`, `Bug` | all seven above | section 4 |
| `Universal Managed Grouping Workflow` | `Epic`, `Sub-task` | `Triage`, `Open`, `In Progress`, `Completed`, `Cancelled` | none |

[JIRA-17] Every project in a conforming Space MUST use the workflow scheme
`Universal Managed Workflow Scheme`, mapping `Task`, `Story` and `Bug` to
`Universal Managed Workflow` and `Epic` and `Sub-task` to
`Universal Managed Grouping Workflow`. A project MUST NOT carry a workflow or a
workflow scheme of its own for these issue types. A per-project copy is a second
place the validators can drift, and a Space whose projects each carry one has as
many lifecycles as projects.

A ticket is an issue on `Universal Managed Workflow`. The issue types on the
grouping workflow are not tickets, per `[JIRA-16]`.

The grouping workflow runs `Triage` → `Open` → `In Progress` → `Completed`, with
`Cancelled` reachable from `Triage` and `Open`, and carries no validator on any
transition.

[JIRA-12] Each workflow's **initial transition** — the one Jira runs when an
issue is created, `"type": "initial"` — MUST target the status bound to the
entry state, `Triage`. An implementation MUST select that transition by its
type and MUST resolve the target status id by name, per `[JIRA-8]`; both the
transition id and the status id are per-site.

The Jira project template targets it at `To Do`, so a project left on the
template's workflow creates every issue at the ready-to-work position and skips
triage entirely. On the shared workflows the target is set once, globally;
switching a project onto the shared scheme is what brings it under that target.

### 3.2 The deferral automation

A **global Jira automation**, configured on the site and owned by the site's
administrator, scans `defer_until` daily and transitions an issue from
`Deferred` to `Open`, through `open`, once the date has passed. It is recorded here because two things in
this binding depend on it and would otherwise look arbitrary:

- An automation that parks issues in a status the binding cannot read is worse
  than no automation, so the status it moves an issue into MUST be one section 3
  binds. `Open` is. A project not yet on the shared scheme, still on the
  template's own workflow, is not a conforming Space and this binding makes no
  claim about it.
- The `defer` transition requires `verify` as well as `defer_until` (section
  4), so that an issue the automation later moves out through `open` can always
  satisfy that transition's own validator. The gate is placed on the way in,
  where a person is present, rather than on the way out, where one is not.

This binding does not create, edit, inspect or manage that automation, and no
script here does either. It states that it exists and what it depends on.

### 3.3 The shared issue type and screen schemes

Issue types and screens are shared the same way the workflows are. No project
carries an issue type scheme, a screen scheme or a screen of its own.

| Object | Name | Holds |
| --- | --- | --- |
| issue type scheme | `Universal Managed Issue Type Scheme` | `Task`, `Story`, `Bug`, `Epic`, `Sub-task`; default `Task` |
| issue type screen scheme | `Universal Managed Issue Type Screen Scheme` | default → `Universal Managed Ticket Screen Scheme`; `Epic`, `Sub-task` → `Universal Managed Grouping Screen Scheme` |
| screen | `Universal Managed Ticket Screen` | the standard fields and every custom field of section 2 |
| screen | `Universal Managed Grouping Screen` | the standard fields only |

Each screen scheme maps its one screen as the default for create, edit and
view. The standard fields are the ones the Jira Scrum template puts on its
default issue screen; `universal-workflows.json` lists them.

[JIRA-19] Every project in a conforming Space MUST use the issue type scheme
`Universal Managed Issue Type Scheme` and the issue type screen scheme
`Universal Managed Issue Type Screen Scheme`, and MUST NOT carry an issue type
scheme, issue type screen scheme, screen scheme or screen of its own. The
reason is the one `[JIRA-17]` gives for workflows, and it has been measured
here: before the shared screens, the per-project copies had drifted until four
of five contract projects had no `outcome` on their screens while every
`cancel` required it.

A second tier, **Universal Simplified**, serves projects that are not ticket
sets: one `Universal Simplified Workflow` (`Open`, `In Progress`, `Done`), its
own issue type scheme with the same five types, and one
`Universal Simplified Screen` with no custom field of section 2. A project on
it is not a conforming Space and this binding makes no claim about it. It is
named here only because the same scripts converge it. Each project's Jira
project category, `Universal Managed` or `Universal Simplified`, records which
tier it is on.

## 4. Enforcement

These validators are what makes the contract gate rather than describe. They
live on `Universal Managed Workflow` and are converged by `universal-apply.sh`
from `universal-workflows.json`, additively: a rule already present is left
alone, a missing one is added, nothing is removed, and a stored rule that
differs from the file is reported rather than overwritten.

Every validator below is a field-required validator. A transition not in this
table does not exist on the workflow.

| Transition | From → To | Required | Serves |
| --- | --- | --- | --- |
| `Create` (initial) | → `Triage` | nothing — deliberately | `[MUST-46]`, per `[JIRA-12]`, `[JIRA-13]` |
| `refine to work` | `Triage` → `Open` | `verify` | `[MUST-7]`, `[MUST-46]`, per `[JIRA-13]` |
| `defer` | `Triage`, `Open` → `Deferred` | `defer_until`, `verify` | `[MUST-47]`, `[MUST-7]`, per `[JIRA-14]` |
| `open` | `Deferred` → `Open` | `verify` | `[MUST-7]`, per `[JIRA-14]` |
| `start work` | `Open` → `In Progress` | `verify`, `touches` | `[MUST-7]`, `[MUST-8]`, `[MUST-13]` tightened by `[JIRA-6]` |
| `ready for verification` | `In Progress` → `Awaiting Deployment` | nothing | |
| `re-work` | `Awaiting Deployment` → `In Progress` | nothing | |
| `complete` | `Awaiting Deployment` → `Completed` | `verify` | `[MUST-7]`, `[MUST-27]`, per `[JIRA-18]` |
| `cancel` | `Triage`, `Open`, `Deferred`, `In Progress`, `Awaiting Deployment` → `Cancelled` | `outcome` | `[MUST-28]`, per `[JIRA-7]` |
| `re-open` | `In Progress`, `Completed`, `Cancelled` → `Open` | `verify` | `[MUST-7]`, per `[JIRA-13]` |

[JIRA-13] The initial transition into `Triage` MUST carry no validator, every
transition out of `Triage` other than `cancel` MUST require `verify`, and every
transition into `Open`, from any status, MUST require `verify`. Together those
are the entry state made executable: anything may enter `Triage`, leaving it for
the lifecycle is the assertion `[MUST-46]` describes, and no route back to the
ready-to-work position skips that assertion. A validator on the way in would reject the ticket at the one moment
nobody has written the contract yet; no validator on the way out would leave
the entry state a formality.

[JIRA-14] The `defer` transition MUST require `defer_until`, per `[MUST-47]`,
and MUST also require `verify`. The first is what makes `Deferred` bounded. The
second is what keeps the automation of section 3.2 able to move the issue back
out: the only way out of `Deferred` other than `cancel` is `open`, which
requires `verify`, and an automation running unattended cannot fill a field in.

[JIRA-5] Retired (WO-79). It required a previous-status validator naming
`Awaiting Deployment` on the transition into `Completed`. Jira's previous-status
validator reads the *from* side of the changelog, so a ticket that hopped out of
`Awaiting Deployment` and back passed it on the wrong evidence. `[JIRA-18]`
replaces it with structure.

[JIRA-18] `Completed` MUST be reachable only through `complete`, from
`Awaiting Deployment`, and that transition MUST NOT carry a previous-status
validator. Passage through `Awaiting Deployment` is then a property of the
workflow's shape, which `[MUST-27]` asks for, rather than a check on history.

[JIRA-6] The `start work` transition MUST require `touches` for every ticket,
not only for the `agent` and `mixed` executors `[MUST-13]` names. Jira's
field-required validator cannot be made conditional on another field's value, so
the choice is between requiring it of everyone and requiring it of nobody. This
is stricter than the core, which `[MUST-44]` permits, and it is stated here
rather than left as a surprise: a `human` ticket in a conforming Space must
declare `touches`, or an empty `touches` per `[SHOULD-7]`.

[JIRA-7] Every transition into `Cancelled` MUST require `outcome`, per
`[MUST-28]`. `outcome` is not a Jira field; this binding defines it as a custom
field, and a Space without it cannot represent a cancelled ticket at all.

[JIRA-1] Every custom field this binding defines MUST be on the screen every
ticket issue type (`Task`, `Story`, `Bug`) uses for create, edit and view: the
`Universal Managed Ticket Screen` of section 3.3. The screen `Epic` and
`Sub-task` use carries none of them, because neither is a ticket, per
`[JIRA-16]`.

This is the single most expensive thing to get wrong here, and it has already
happened twice in production. A custom field that exists globally but is not on
a screen accepts no value: the API write returns a success the UI never shows,
so the Space looks conforming from every angle a spot check reaches and holds no
`verify` at all. `universal-apply.sh` adds any missing field to the shared
ticket screen, and `[JIRA-19]` puts every project on that one screen, so the
fields are placed once for the site rather than once per project.

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
The one transition into `Completed` requires the field, and `[JIRA-18]` makes
`awaiting-deployment` the only way there. Neither is evidence the command ran.
Jira cannot supply that evidence.

**`[MUST-15]` — simultaneously startable tickets MUST NOT share a `touches`
path, and an overlap MUST be reported as an error.** Jira has no validator that
can see another issue's field values, so the check runs outside the tracker over
a JQL query. `[JIRA-2]` exists to keep that query possible. Jira will not report
the overlap on its own.

**`[MUST-16]` — an `appends` overlap MUST be reported as a warning.** Same
reason, same place.

**`[MUST-18]` — `blocked_by` written at create time.** A Jira issue link names
an issue that must already exist, so the first pass over a ticket set cannot
carry the dependencies in. `provider.sh create` warns and writes the rest; the
links are a second pass over the keys the first one returned.

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

A blocker outside the set has no issue a `Blocks` link can name — another
project's release, a vendor, an approval held elsewhere. It goes in the
`blocked_by_external` textarea, one per line, and the reference
implementation's `next` and `board` read it exactly as an unsatisfied
`Blocks` link (`[MUST-48]`). Add `blocked_by_external is EMPTY` to the
startable query above. Cross-project `Blocks` links stay what they were: a
blocker in a project the fetch never asked for is read on its nested status,
not as an external dependency.

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

A Space provisioned by `provision.sh` on the managed tier carries every field
and every lifecycle position the specification names, so it can support a
claim at `minimal`, `full` or `unattended`. Which profile a set actually claims depends on the content of
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
| `provision.sh` | creates or converges a Space on a tier (`--tier managed`, the default, is a conforming Space), `--dry-run` first; its last step runs the two scripts below |
| `universal-apply.sh` | converges, from `universal-workflows.json`, the shared workflows of section 3.1, their scheme, and both tiers' screens, screen schemes, issue type screen schemes and issue type schemes of section 3.3; takes no project |
| `universal-switch.sh` | moves one project onto its tier's workflow scheme, issue type scheme, issue type screen scheme and category, mapping its issues' old statuses onto the tier's, then deletes the workflows, schemes and screens it had |
| `provider.sh` | the tracker verbs — `fetch`, `position`, `transition`, `comment`, `create`, `update`, `link`, `unlink`, `parent` |
| `issues-api.sh` | the read-only wrapper `reference/issues.py --source jira` calls, over `lib/jira-http.sh` |
| `lib/jira-http.sh` | the one credentialed HTTP client, and the seam a test stubs |
| `selftest.sh` | offline; stubs the client and asserts on the decisions the scripts reach |

`provider.sh transition KEY <position>` takes a lifecycle position, not a
transition id, and resolves it against the live issue. That is the lifecycle
table in section 3 made executable: if the table and the Space disagree, the
call fails instead of moving the ticket somewhere else. Since transitions are
directed (`[JIRA-18]`), a position the issue's current status has no transition
into fails the same way. A position the issue already holds is a no-op, exit 0,
so a command sequence that files and opens a set can be run again after a
partial failure.

Jira Cloud can answer a read made just after a write from before the write:
measured on the acceptance run of 2026-10-08, the transition list read right
after `open` still offered `Triage`'s transitions, so the next move was
refused. Every read-back in `provider.sh`, and its lookup of a transition, is
therefore retried within a short window (`WORK_ORDER_JIRA_SETTLE_TRIES`,
default 5, `WORK_ORDER_JIRA_SETTLE_DELAY`, default 1 second) before it reports
a failure, and a no-op is believed only when two reads that delay apart agree.
The same lag applies to search: an issue created a moment ago may not yet be
found by `create`'s duplicate check.

On the managed tier, `universal-switch.sh` first moves every `To Do` issue that
already carries `verify` to `Open`, then maps what remains: `To Do` to `Triage`
for tickets and to `Open` for `Epic` and `Sub-task`, and `Done` to `Completed`.
It deletes an old object only once nothing uses it, and a screen a workflow
transition still names is refused by Jira and stops the run. Both universal
scripts share `provision.sh`'s exit statuses — 0 done, already complete or
`--dry-run`; 1 failure; 3 not confirmed — and `universal-apply.sh` adds 2, for
a stored rule that differs from `universal-workflows.json`.

## 10. Writing a ticket — `provider.sh create`

```
provider.sh [--dry-run] create PROJECT ISSUETYPE SUMMARY [--ticket PATH|-] [--allow-duplicate]
```

Without `--ticket`, `create` writes a title and nothing else. With it, `PATH` is
a decision-list document (`decision-list/FORMAT.md`) — one decision object, or a
list holding exactly one, read from stdin when `PATH` is `-` — and the whole
ticket is written in that one request:

| Ticket field | Written as |
| --- | --- |
| `title` | `fields.summary`. `SUMMARY` wins; leave it empty to use the ticket's |
| `problem`, `solution`, `rationale`, `out_of_scope` | `fields.description`, one `##` heading per part |
| `tags` | `fields.labels`, always sent, empty or not |
| `touches`, `verify`, `human_steps`, `appends`, `outcome`, `blocked_by_external` | the custom field of that name, as an ADF document — a `textarea` rejects a plain string |
| `verify_fails_today` | the last line of `verify`, as `# <observation>`, the way the file binding's `emit-tickets` writes it: `[MUST-10]` asks `verify` to record it |
| `executor` | the `executor` field, `{"value": ...}`, checked against the three options |
| `defer_until` | the `defer_until` field, an RFC 3339 full-date |
| `epic` | `fields.parent`, when it names an issue that exists at `hierarchyLevel` 1 — see `parent` below |

A field the ticket gives no value is not sent at all.

[JIRA-10] `create` MUST resolve every custom field id by name from `GET /field`
at run time, per `[JIRA-8]`, and MUST fail naming the field when the site has
none by that name rather than writing an issue missing part of the contract.
`--dry-run` resolves nothing and prints `<name>` in each id's place.

The field list is not restated here: `lib/common.sh` holds the one table, and
`provision.sh` creates exactly the fields `provider.sh` fills.

**Retrying a create.** A create that fails after Jira accepted it, then retried,
files a second issue. Before its POST, `create` searches PROJECT for an issue
whose `statusCategory` is not `Done` and whose summary matches, and compares the
summary client-side for exact equality, because JQL's `~` is fuzzy. On a match
it writes nothing, exits 3 and prints the existing issue as `{id, key, self}`,
the same shape a successful create prints, so `jq -r .key` reads either and the
exit code tells a retry from a fresh create. `--allow-duplicate` skips the check. A summary
that only resembles an open one is created.

**`transition --outcome`.** `provider.sh transition KEY POSITION --outcome TEXT`
(`-` reads stdin) satisfies `[JIRA-7]` for a move to `Cancelled`. Jira ignores a
field placed in a transition body here, so the verb resolves the transition
first, then PUTs `outcome` as an ADF document in its own request, reads the field
back, takes the transition and reads the status back. Moving to `cancelled`
with `--outcome` absent and the field empty exits 1 naming the flag, before any
write. `--outcome` is accepted on any target.

**`link` and `unlink`.** `provider.sh link KEY --blocked-by BLOCKER` writes
the `Blocks` link; `unlink` removes it. The flag names the direction, so the
call reads like the ticket's `blocked_by` field, and argument order never
decides it. Three behaviours of the Jira API, measured on dipuce.atlassian.net
2026-09-30, shape the verbs:

- On write, `inwardIssue` is the blocker and `outwardIssue` is the blocked
  ticket. On read, from the blocked ticket's `issuelinks`, an entry carrying
  `inwardIssue` means "is blocked by", so the read runs opposite to the write.
- Posting a link that already exists returns 2xx and creates nothing, so a
  reversed link cannot be fixed by posting the right one on top.
- The endpoint is `POST /issueLink`; `/issuelinks` is a 404.

`link` reads KEY first. A link already in the right direction is a no-op, exit
0. A reversed link is refused, exit 1, naming its id, unless `--replace`
deletes it before the write. After writing, `link` reads KEY back and exits 1
unless an inward `Blocks` entry names BLOCKER. `unlink` deletes each matching
link by the id read from KEY and reads back that it is gone; when only the
reversed link exists it warns and leaves it alone. Link types other than
`Blocks` are not handled.

**`update`.** `provider.sh update KEY --ticket PATH|-` rewrites an existing
issue from a decision document with the encodings `create` uses. It is how a
ticket filed bare into `triage` receives its contract, how a contract that
changed is rewritten (`[MUST-32]` permits exactly that), and how `defer_until`
is set before `defer` and cleared after an early `open`: Jira ignores a field in
a transition body, so a date can only arrive by its own write.

- A key the document carries is written; a key it carries empty — `null`, a
  blank string or an empty list — clears the field, sent as an explicit `null`
  because Jira keeps the stored value of a key a PUT omits; a key it does not
  carry is left alone.
- `title` becomes the summary and is refused empty (`[MUST-3]`). `tags` become
  the labels.
- The description is rewritten whole: `problem`, `solution` and `out_of_scope`
  come together or not at all, so one part can never silently replace the rest.
- `verify_fails_today` is written only beside `verify`, as its last line.
- `epic` and `blocked_by` are not written here; `update` warns and names
  `parent` and `link`.

Every written field is read back and compared on its text; a mismatch exits 1
naming the field. A document that carries nothing `update` writes is refused.

**`parent`.** `provider.sh parent KEY --epic EPIC [--replace]` sets a ticket's
epic after the fact: for a ticket filed before its epic, or moved between
epics. It refuses, before any write, an EPIC that does not exist or is not at
`hierarchyLevel` 1, and a KEY that is not a ticket. A KEY already under EPIC is a
no-op, exit 0. A KEY under another epic is refused, exit 1, naming that epic,
unless `--replace`. It then writes `fields.parent` and exits 1 unless KEY reads
back under EPIC.

**What `create` does not write.** `blocked_by` names other tickets, and a Jira
link needs both ends to exist already, so a set imported in one pass cannot
carry its links on the way in. `create` warns when a ticket carries `blocked_by`
and leaves it to a second pass, which `provider.sh link KEY --blocked-by
BLOCKER` performs (below). `id`, `created` and `updated` are Jira's to assign
(section 2); a ticket's own `id` survives only if the caller puts it in `tags`.

**The epic, at create.** Epics are filed before their tickets, so `create`
writes a ticket's `epic` in the create request itself, per `[JIRA-20]`: it reads
the epic first, sends `fields.parent` when the epic exists at `hierarchyLevel`
1, and reads the created issue back, exiting 1 with the `parent` command to run
if the parent did not take — after printing the created issue, so the key is
not lost. An `epic` that is not a Jira key, or names an issue that does not
exist yet, is warned about and left out; everything else is written. One that
exists at any other level is refused before any write.
