# The reference implementation

`issues.py` reads a ticket set and answers the questions that decide whether it
can be worked on: is every ticket well formed, what is startable right now, and
did a branch change anything its ticket did not declare.

It is the executable account of [the file binding](../bindings/file/BINDING.md),
and it also reads a set out of Jira, which is why the same grouping and
collision logic has to behave identically for both.

```
python3 reference/issues.py lint   <dir>   errors that make a ticket unworkable
python3 reference/issues.py board  <dir>   what is where
python3 reference/issues.py next   <dir>   tickets startable right now
python3 reference/issues.py scope  <id> <base-ref> [<dir>]
                                           declared vs undeclared changed paths
python3 reference/issues.py selftest       built-in fixture checks, no <dir>
```

## Wave computation is not here

`waves` and `preflight`, and their `--landing serial|parallel` flag, were
removed on 2026-09-24 (WO-73). Work-order owns the contract — what a ticket
must carry to be workable — and not the dispatch plan built on top of it.
That plan, grouping startable tickets into parallel waves and reporting the
files two of them would both write, lives one layer down in night-watchman's
`scripts/waves.py`, which reads the same ticket set and applies the same
`touches`/`appends` overlap rule `lint` already enforces.

`<dir>` is a set root in the file binding: the directory holding `open/`,
`in-progress/`, `awaiting-deployment/`, `completed/` and `cancelled/`. To read a
set out of Jira instead, pass `--source jira --jira-api <path>`; the wrapper
script that talks to the tracker is not shipped here.

```
python3 reference/issues.py lint bindings/file/examples/
python3 reference/issues.py selftest
```

## An unworkable ticket is an error, not an omission

`lint` used to pass a ticket that could never be worked. On 2026-09-19 three
tickets in one set were unworkable while it reported the set clean: a contract
written as prose in the description with both structured fields empty, so the
ticket was excluded from `next` and every wave and could never be dispatched; a
`touches` field written as one comma-separated line, so a collision with two
siblings was invisible; and a blocker declared only as a prose `Blocked_by:`
line, so the ticket showed as startable.

One property, not three typos. A ticket has two representations — the body and
the structured fields — and nothing enforced that they agree or that the fields
exist. Absence was indistinguishable from correctness, so silence read as a
pass. `lint` now errors on each shape:

| Shape | What it reports |
| --- | --- |
| `verify:` / `executor:` / `touches:` / `blocked_by:` / `human_steps:` as a body line over an empty field | the prose line **and** the empty field |
| a prose `Blocked_by:` line naming ids the field does not carry, or saying "none" when it does | which side carries what |
| `executor` is `agent`/`mixed` and `touches` is empty | parallel safety cannot be checked |
| no executor, past `triage` and not closed | declared but undispatchable |
| a `touches` item holding two or more comma-separated paths | split it, one path per line |

A body line that says the value is *absent* — `Blocked_by: none`, `Human_steps:
n/a` — agrees with an empty field and is silent. The two are only in conflict
when the field carries something the prose denies, or denies something the
prose names.

`blocked_by` is the only field whose prose is compared against the field's
value, because ticket ids are the only machine-comparable thing a contract line
carries. Every id on that line is read as a claimed blocker, a parenthetical
aside included, so keep other tickets off it. An id written in lower case is
recognised only when the field already declares it, because `utf-8` and
`http-2` have the same shape as a key.

The prose rules run exactly where the field rules run. `triage` keeps its
`[MUST-46]` exemption throughout — it is the entry state, before the ticket is
a contract, and a ticket there with no executor is still only a warning — and
`cancelled` tickets and epics are excused in the same way and for the same
reason they are excused from `verify`.

Each rule is pinned by a fixture in `selftest` that asserts the **specific**
error rather than a non-zero exit, so a rule that fires for the wrong reason
cannot pass, and by a contracted control ticket whose body names the same
fields and must stay silent.

## Stdlib only, on purpose

`issues.py` imports nothing outside the Python standard library, and its
frontmatter parser is hand-rolled rather than PyYAML. That is what lets the file
be adopted by copying it, with no install step and no manifest: tickets get read
on machines nobody prepared in advance, and a dependency is one more reason for
that to fail. A change that adds a third-party import is a change to what this
file is for.

## Status

Moved here unchanged from night-watchman's `to-issues` skill, deliberately: a
move and a behaviour change in one step makes a regression impossible to
attribute. Known defects travel with it and are fixed in follow-up tickets
rather than in the move — `lint` under `--source jira` and the `scope` verb's
handling of repository-prefixed globs are the two known areas.

The loader excludes a `<id>.notes.md` progress note by its file suffix, per
`[FILE-4]` of the file binding — every consumer (`lint`, `board`, `next`)
sees the same ticket set, and a ticket legitimately named e.g.
`T-009-notes-format.md` still loads.

`lint` is not the conformance validator. It answers "can this set be worked
on", not "does this set conform to `SPEC.md` at profile X".

## Gating a transition on its own ticket

`lint --scope KEY[,KEY...]` prints the same full report and narrows only the
exit code: it is 1 when an error belongs to a listed ticket, 0 otherwise. A
collision error belongs to both tickets in the pair. Without the flag the
exit code covers the whole set, as before.

The reason is the tickets-protocol rule that a transition is blocked by a
lint error on the ticket being moved, or on one in the active sprint — not
by ungroomed intake elsewhere in the project. That narrowing used to live in
prose a reader could skip; the tool now enforces it while keeping every error
visible.

```
python3 reference/issues.py lint --source jira --scope PROJ-51
```
