# The reference implementation

`issues.py` reads a ticket set and answers the questions that decide whether it
can be worked on: is every ticket well formed, what is startable right now, what
can run in parallel without two executors colliding, and did a branch change
anything its ticket did not declare.

It is the executable account of [the file binding](../bindings/file/BINDING.md),
and it also reads a set out of Jira, which is why the same grouping and
collision logic has to behave identically for both.

```
python3 reference/issues.py lint   <dir>   errors that make a ticket unworkable
python3 reference/issues.py board  <dir>   what is where
python3 reference/issues.py next   <dir>   tickets startable right now
python3 reference/issues.py waves  <dir>   a parallel execution plan
python3 reference/issues.py scope  <id> <base-ref> [<dir>]
                                           declared vs undeclared changed paths
python3 reference/issues.py selftest       built-in fixture checks, no <dir>
```

`<dir>` is a set root in the file binding: the directory holding `open/`,
`in-progress/`, `awaiting-deployment/`, `completed/` and `cancelled/`. To read a
set out of Jira instead, pass `--source jira --jira-api <path>`; the wrapper
script that talks to the tracker is not shipped here.

```
python3 reference/issues.py lint bindings/file/examples/
python3 reference/issues.py selftest
```

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
`[FILE-4]` of the file binding — every consumer (`lint`, `board`, `waves`,
`next`) sees the same ticket set, and a ticket legitimately named e.g.
`T-009-notes-format.md` still loads.

`lint` is not the conformance validator. It answers "can this set be worked
on", not "does this set conform to `SPEC.md` at profile X".
