# Golden flows

The closed list of jobs this binding does. It is the definition of
feature-complete: every flow below runs, end to end, against a live Space, and
`acceptance.sh` runs each one before every release of `work-order-jira`. A verb
that serves no flow here is not added; a flow that fails is a defect.

Each flow is written as the commands that do it and the read-back that proves
it. `PROJ`, `EPIC`, `A`, `B` and `KEY` stand for a project key and issue keys.
`transition`, `update`, `link`, `unlink` and `parent` read their own write back
and exit non-zero when it did not take; `create` reads back the epic it writes,
and the suite reads back the rest.

## 1. File a set of tickets under an epic

Epics are filed first, then their tickets, then the links between them.

```
provider.sh create PROJ Epic '' --ticket epic.json      # -> EPIC
provider.sh create PROJ Task '' --ticket a.json         # "epic": "EPIC" -> A, under EPIC at create
provider.sh create PROJ Task '' --ticket b.json         # -> B
provider.sh link B --blocked-by A
provider.sh transition A open
provider.sh transition B open
```

Read back: `provider.sh fetch` shows each ticket's `parent` and `Blocks` links;
`issues.py board` shows both tickets under `EPIC`, `B` blocked by `A`; `lint`
is clean.

The sequence is safe to run again after a partial failure, and a second run
writes nothing: `create` finds the open issue with that summary and exits 3
with its key, `link` and `parent` are no-ops when already true, and a
transition to the position a ticket already holds exits 0. One limit: Jira's
search index can lag a fresh issue by a few seconds, and inside that window
`create`'s duplicate check cannot see it, so a re-run seconds after the first
can still file a second copy.

A ticket filed before its epic is given it afterwards with `provider.sh parent
KEY --epic EPIC`; moving it to another epic takes `--replace`.

## 2. Walk a ticket through the lifecycle

```
provider.sh create PROJ Task "title"                    # -> KEY, at triage, no contract yet
provider.sh transition KEY open                         # refused: no verify ([JIRA-13])
provider.sh update KEY --ticket contract.json           # verify, touches, executor, description
provider.sh transition KEY open
provider.sh transition KEY in-progress
provider.sh transition KEY awaiting-deployment
provider.sh transition KEY completed
```

`position KEY` reads back each step. Deferral and the way back:

```
printf '{"defer_until":"YYYY-MM-DD"}' | provider.sh update KEY --ticket -
provider.sh transition KEY deferred                     # refused without the date ([JIRA-14])
provider.sh transition KEY open                         # back early
printf '{"defer_until":null}' | provider.sh update KEY --ticket -
provider.sh transition KEY in-progress
provider.sh transition KEY open                         # re-open
```

While `defer_until` is in the future, `issues.py next` holds the ticket back at
any position; clearing it is what an early return means. A completed or
cancelled ticket comes back through `re-open` the same way.

## 3. Cancel with an outcome

```
provider.sh transition KEY cancelled --outcome "why it lost"
```

With no `--outcome` and an empty `outcome` field this is refused before any
write ([JIRA-7]). An epic is cancelled the same way, and completed once its
work is done:

```
provider.sh transition EPIC in-progress
provider.sh transition EPIC completed
```

## 4. The landing path completes a ticket

A landing script — night-watchman's `land-branch.sh` and homelab's fork of it,
driving ai-toolkit's `land-core.sh` hooks — moves a ticket in two hops, and
this flow pins the Jira side both rely on:

```
provider.sh transition KEY awaiting-deployment          # before the merge
provider.sh transition KEY completed                    # after the push
provider.sh transition KEY in-progress                  # re-work, when the second hop must be undone
```

From `In Progress`, `completed` is refused: `Completed` is reachable only
through `complete`, from `Awaiting Deployment` ([JIRA-18]). `complete` requires
`verify`.

## 5. Read the set back

```
issues.py lint  --source jira --jira-api issues-api.sh --jira-project PROJ
issues.py board --source jira --jira-api issues-api.sh --jira-project PROJ
issues.py next  --source jira --jira-api issues-api.sh --jira-project PROJ
```

`lint` is clean; `board` shows each ticket at its position with its epic and
the epic's rolled-up state; `next` offers exactly the startable tickets — none
blocked by an open ticket, deferred to a future date, or waiting on
`blocked_by_external`. The same decision list emitted to files by
`emit-tickets`, with the epic as a file-binding scalar, gives the same `next`
through the file binding. night-watchman's `waves.py`, which loads tickets
through `issues.py`, plans the same startable set.

## What is not a flow

Link types other than `Blocks`; Sub-tasks; removing a ticket's epic; boards and
sprints; the deferral automation of BINDING.md section 3.2. Each is left out on
purpose; adding one is a decision for the owner, made by adding a flow here.

## Gaps found and closed

The audit of 2026-10-08 (WO-103, WO-104, under epic WO-102) walked each flow
against `provider.sh`, BINDING.md and `reference/issues.py`, then confirmed
each gap live in a scratch project before fixing it.

| Flow | Gap | Fix |
| --- | --- | --- |
| 1 | No verb set a ticket's epic, and `create` dropped the decision's `epic` without a word | `provider.sh parent`; `create` writes an existing epic as `fields.parent` ([JIRA-20]) |
| 1 | `create` dropped `verify_fails_today`, so a filed ticket lost the observation `[MUST-10]` asks `verify` to record | written as `verify`'s last line, `# <observation>` |
| 1 | A transition to the position a ticket already held exited 1, so a filing sequence could not be run again | a no-op, exit 0 |
| 2 | No verb wrote a field of an existing ticket: a date could not be set before `defer` or cleared after an early `open`, a triage ticket could not receive its contract, and a changed contract could only be edited by hand | `provider.sh update` |
| 2 | Jira stores a date picker's year of 2046 or later as 19xx, so a far `defer_until` silently became a past one | refused before any write; `update` reads every field back |
| 5 | `issues.py` read custom fields under placeholder ids; on the live site `blocked_by_external` has another id, so `next` offered tickets waiting on external work | ids resolved by name from `GET /field` ([JIRA-8]) |
| 5 | `issues.py --source jira` needs a `jira-api.sh`-shaped wrapper and this binding shipped none | `issues-api.sh` |
| all | Every `lib/jira-http.sh` call left a temporary directory holding the response body: `$(tmpfile)` created it in a subshell the cleanup trap never saw | `tmpinit` creates it in the main shell |
| 4 | A read made just after a write can come back from before it: the acceptance suite's first live run had `in-progress` refused straight after `open`, because the transition list still showed `Triage`'s | every read-back and transition lookup retries within a settle window; a no-op takes two agreeing reads |
