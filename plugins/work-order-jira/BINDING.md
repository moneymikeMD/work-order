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
| `triage` | `Triage` | the entry state, `[MUST-46]` |
| `open` | `Open` | ready to work, `[JIRA-15]` |
| `in-progress` | `In Progress` | |
| `awaiting-deployment` | `Awaiting Deployment` | |
| `deferred` | `Deferred` | exit is time-based, `[MUST-47]` |
| `completed` | `Completed` | terminal |
| `cancelled` | `Cancelled` | terminal |

[JIRA-15] The `open` position MUST bind to the Jira status `Open`. `Open` is
*a ticket that is ready to be worked on; it meets our criteria as something that
is startable* — `[MUST-25]`'s definition of the position, and what the file
binding's `open/` directory has always meant. An implementation MUST NOT bind
the position to any other status, and MUST NOT retire `Open` on the evidence
that it is holding no issues: how many issues sit in a status is a fact about
one moment, and this binding is a contract.

### Legacy statuses, read only

| Status | Read as | |
| --- | --- | --- |
| `To Do` | `open` | the scrum template's default ready-to-work status |
| `Done` | `completed` | the scrum template's closed status |

An implementation MAY accept these two on read, and MUST NOT write either, MUST
NOT provision either, and MUST NOT accept any status outside this table and the
one above. The alias is one-way, and it is here so that a Space provisioned from
the Jira project template — which ships `To Do` and `Done` and neither of the
statuses those two alias — stays readable rather than reporting every issue as
having no position at all. That is what happened to all 58 issues of one import.
This is not the guess `[JIRA-3]` forbids: an alias is stated here by name, and
the set of them is closed.

Whether `To Do` survives on the prototype's board is a separate question, open
in WO-058, and it is the owner's to answer. Nothing in this binding decides it.

Jira offers several other places a position could appear to live, and none of
them is one: `fields.resolution`, the `statusCategory` (three values, not
seven), a board column, a sprint, a label. An implementation MUST NOT read or
write a position anywhere but `status`, per `[MUST-26]`. `statusCategory` in
particular collapses `Triage`, `Open` and `Deferred` into one value and cannot
be derived back.

[JIRA-3] A ticket whose status is not one of the seven above, or one of the two
legacy aliases, has no lifecycle position under this binding. An implementation
MUST report that as an error and MUST NOT guess a position from the status name,
its category, or its position on a board. A project MAY carry other statuses for
work outside the set.

[JIRA-11] An implementation reporting a ticket's position MUST distinguish "the
status is not one this binding binds" from "the position could not be read",
with an exit status or a parseable token of its own — not with prose a caller
has to match. A conforming Space produces no unmapped status; a caller reading a
Space that is not conforming still has to tell a ticket parked outside the
lifecycle apart from a broken read, and matching an error message is not a
contract. `provider.sh position` exits **4** and prints
`unmapped-status<TAB><status name>` for the first, and exits 1 for the second.

[JIRA-4] The transition into each of the seven statuses MUST be `GLOBAL`, so
every position is reachable from every other without a transition matrix. The
lifecycle's ordering is enforced by validators, named below, not by which
transitions exist.

[JIRA-12] The workflow's **initial transition** — the one Jira runs when an
issue is created, `"type": "initial"` — MUST target the status bound to the
entry state, `Triage`. An implementation MUST select that transition by its
type and MUST resolve the target status id by name, per `[JIRA-8]`; both the
transition id and the status id are per-site.

The Jira project template targets it at `To Do`, so a Space provisioned without
this step creates every issue at the ready-to-work position and skips triage
entirely. The prototype project was corrected by hand and the replication path
was not: same workflow shape, same transition id `1` named `Create`, different
target. `workflow-apply.sh` already rewrites this workflow through
`POST /workflows/update`, so this is a step the provisioner never asked for
rather than something Jira will not do.

### 3.1 The deferral automation

A **global Jira automation**, configured on the site and owned by the site's
administrator, scans `defer_until` daily and transitions an issue out of
`Deferred` into `To Do` once the date has passed. It is recorded here because
two things in this binding depend on it and would otherwise look arbitrary:

- `To Do` MUST stay readable (it is, as the one-way alias above). An automation
  that parks issues in a status the binding cannot read is worse than no
  automation.
- The `Deferred` transition requires `verify` as well as `defer_until` (section
  4), so that an issue the automation later moves into `To Do` can always
  satisfy that transition's own validator. The gate is placed on the way in,
  where a person is present, rather than on the way out, where one is not.

This binding does not create, edit, inspect or manage that automation, and no
script here does either. It states that it exists and what it depends on.

## 4. Enforcement

These validators are what makes the contract gate rather than describe. They
are applied by `workflow-apply.sh` from `workflow-rules.json`, additively: a
rule already present is left alone, a missing one is appended, nothing is
removed.

| Transition | Validator | Serves |
| --- | --- | --- |
| `Triage` | none — deliberately | `[MUST-46]`, per `[JIRA-13]` |
| `Open` | `verify` is required | `[MUST-7]`, per `[JIRA-13]` |
| `To Do` | `verify` is required, where the transition exists | `[MUST-7]`, per `[JIRA-13]` |
| `In Progress` | `verify` is required | `[MUST-7]`, `[MUST-8]` |
| `In Progress` | `touches` is required | `[MUST-13]`, tightened by `[JIRA-6]` |
| `Deferred` | `defer_until` is required | `[MUST-47]`, per `[JIRA-14]` |
| `Deferred` | `verify` is required | `[MUST-7]`, per `[JIRA-14]` |
| `Completed` | `verify` is required | `[MUST-7]` |
| `Completed` | previous status includes `Awaiting Deployment` | `[MUST-27]`, per `[JIRA-5]` |
| `Cancelled` | `outcome` is required | `[MUST-28]`, per `[JIRA-7]` |

[JIRA-13] The `Triage` transition MUST carry no validator, and the transition
into the ready-to-work position MUST require `verify`. Together those two are
the entry state made executable: anything may enter `Triage`, and leaving it is
the assertion `[MUST-46]` describes. A validator on `Triage` would reject the
ticket at the one moment nobody has written the contract yet; no validator on
the way out would leave the entry state a formality.

The requirement covers **both** `Open` and the `To Do` alias, and an
implementation MUST apply it to the `To Do` transition wherever that transition
exists on the workflow. `To Do` is never provisioned, so on a Space this binding
built there is nothing to apply it to; on a Space provisioned from the Jira
project template the transition is already there, and the deferral automation of
section 3.1 uses it. Leaving that one ungated would make the alias a way in
around the gate.

[JIRA-14] The `Deferred` transition MUST require `defer_until`, per
`[MUST-47]`, and MUST also require `verify`. The first is what makes `Deferred`
bounded. The second is what keeps the automation of section 3.1 able to move
the issue back out: it transitions into `To Do`, whose own validator requires
`verify` per `[JIRA-13]`, and an automation running unattended cannot fill a
field in.

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
project = KEY AND status in (Open, "To Do")
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

## 10. Writing a ticket — `provider.sh create`

```
provider.sh [--dry-run] create PROJECT ISSUETYPE SUMMARY [--ticket PATH]
```

Without `--ticket`, `create` writes a title and nothing else. With it, `PATH` is
a decision-list document (`decision-list/FORMAT.md`) — one decision object, or a
list holding exactly one — and the whole ticket is written in that one request:

| Ticket field | Written as |
| --- | --- |
| `title` | `fields.summary`. `SUMMARY` wins; leave it empty to use the ticket's |
| `problem`, `solution`, `rationale`, `out_of_scope` | `fields.description`, one `##` heading per part |
| `tags` | `fields.labels`, always sent, empty or not |
| `touches`, `verify`, `human_steps`, `appends`, `outcome` | the custom field of that name, as an ADF document — a `textarea` rejects a plain string |
| `executor` | the `executor` field, `{"value": ...}`, checked against the three options |
| `defer_until` | the `defer_until` field, an RFC 3339 full-date |

A field the ticket gives no value is not sent at all.

[JIRA-10] `create` MUST resolve every custom field id by name from `GET /field`
at run time, per `[JIRA-8]`, and MUST fail naming the field when the site has
none by that name rather than writing an issue missing part of the contract.
`--dry-run` resolves nothing and prints `<name>` in each id's place.

The field list is not restated here: `lib/common.sh` holds the one table, and
`provision.sh` creates exactly the fields `provider.sh` fills.

**What `create` does not write.** `blocked_by` and `epic` both name another
issue, and a Jira link or parent needs its target to exist already, so a set
imported in one pass cannot carry them on the way in. `create` warns when a
ticket carries `blocked_by` and leaves it to a second pass. `id`, `created` and
`updated` are Jira's to assign (section 2); a ticket's own `id` survives only if
the caller puts it in `tags`.
