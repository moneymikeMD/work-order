# The file binding

This document binds [`SPEC.md`](../../SPEC.md) onto a directory tree: tickets as
Markdown files with YAML frontmatter, the lifecycle position carried by the
directory a file sits in.

It is the binding that needs no tracker, no credential and no network. Anyone
with a directory and a text editor can conform to it, which is why it is
written first even though the specification it binds is substrate-neutral.

## Status of this document

Binds specification version **0.2** (`VERSION-spec`), profile **`unattended`**:
this binding states a representation for every field and every lifecycle
position the specification names at any profile.

Binding version: `VERSION`, beside this file. A binding versions independently
of the specification it binds and of any implementation of it.

## How to read a requirement

This binding numbers its own requirements in its own namespace, as
`[SPEC.md MUST-44]` requires, so a citation is never ambiguous about which
document it came from:

```
[FILE-N] `minimal` — the obligation, stated in one paragraph.
```

The identifier is permanent and is never renumbered or reused. Each requirement
states its own RFC 2119 keyword. The profile token means what it means in
`SPEC.md`: the lowest profile at which the requirement applies, with the
profiles nesting `minimal` ⊂ `full` ⊂ `unattended`.

Nothing here weakens or contradicts a core requirement. Where this binding is
stricter than the core — `[FILE-9]` on terminal transitions, for instance — the
core requirement still holds as written.

## 1. The substrate

[FILE-1] `minimal` — A ticket set is one directory, the **set root**, holding
one subdirectory per lifecycle position. A ticket is a single Markdown file
directly inside exactly one of those subdirectories. Nesting a ticket deeper is
not a conforming layout: the position is the directory, and a ticket two levels
down has two candidate answers.

[FILE-2] `minimal` — The stage directory names MUST be exactly `triage/`,
`open/`, `in-progress/`, `awaiting-deployment/`, `deferred/`, `completed/` and
`cancelled/`, one per lifecycle position of `[SPEC.md MUST-25]`. A directory MAY
be absent while it is empty, and an implementation MUST treat an absent
directory as empty rather than as an error.

`open/` keeps its name and its meaning. Specification 0.2 added two positions
either side of it — `triage/` before, `deferred/` beside — and renamed nothing:
the position `open` is the ready-to-work position it always was, and a set that
predates 0.2 needs no directory moved. What 0.2 changed for an existing set is
that two positions it had nowhere to put now have a directory each.

That is a statement about directories, not about positions: an absent
`awaiting-deployment/` means no ticket is in that position right now, and
`[SPEC.md MUST-27]` still requires a ticket to occupy it before `completed`.

[FILE-3] `minimal` — A ticket file's name MUST begin with the ticket's `id` and
MUST end `.md`. Anything between is a slug for readers and carries no meaning.
An implementation MUST resolve a ticket by the `id` in its frontmatter and MUST
NOT depend on the rest of the name. A progress note (`[FILE-4]`) shares both the
prefix and the suffix and is not a ticket.

The slug exists so that a directory listing is readable, and the prefix exists
so that `ls open/WO-004*` finds one file. A tool that resolves `<id>.md`
exactly cannot find `WO-004-file-binding.md`, which is why resolution is
specified on the frontmatter and not on the path.

[FILE-4] `minimal` — A file in a stage directory whose name ends `.notes.md` is
a progress note, not a ticket, and MUST NOT be read as one. See `[FILE-14]`.

## 2. Lifecycle: the directory is the position

[FILE-5] `minimal` — The one representation of a ticket's lifecycle position,
which `[SPEC.md MUST-26]` requires there to be exactly one of, is **the stage
directory containing the ticket's file**.

[FILE-6] `minimal` — A ticket MUST NOT carry a `status` field, and no index,
marker, tag or second file may restate its position. A field and a location
eventually disagree, and then neither can be trusted: each reader consults
whichever supports what they already believe.

All seven positions of `[SPEC.md MUST-25]` are represented, one directory
each, as `[SPEC.md MUST-42]` requires of a binding, and `[FILE-5]` is the single
representation it names to satisfy `[SPEC.md MUST-26]`. That includes
`awaiting-deployment/` as a position distinct from `completed/`, per
`[SPEC.md MUST-27]`.

[FILE-16] `minimal` — A ticket file created on request MUST be written into
`triage/`, which is the entry state of `[SPEC.md MUST-46]`. Moving it to `open/`
is the assertion that the rest of the contract is now in the file, and in this
substrate that assertion is a rename — there is no field to set and nothing else
to write.

[FILE-17] `minimal` — A ticket in `deferred/` MUST carry `defer_until` in its
frontmatter, per `[SPEC.md MUST-47]`. The directory says the ticket is parked;
the field says until when, and a `deferred/` ticket without one is the case this
binding cannot distinguish from an abandoned ticket.

Nothing moves a ticket out of `deferred/` on its own here. A file tree has no
scheduler, so the date is read by whatever lists the set, and in the
reference implementation it is `issues.py` refusing to call the ticket
startable until the date has passed. A substrate that does have a scheduler —
the Jira binding, where a global automation moves the issue — is where the
transition happens without a person.

[FILE-7] `full` — A lifecycle transition MUST be performed as a **rename** of
the ticket file from one stage directory to another. A copy-then-delete, or a
delete and a fresh write, MUST NOT be used: the file loses its history, and in a
version-controlled set the transition stops being visible to
`git log --follow`.

[FILE-8] `full` — In a version-controlled set, both halves of the rename — the
removal and the addition — MUST land in a single commit. Half a rename leaves a
staged deletion behind, and the next tool to inspect the tree sees a dirty
state it cannot attribute.

A pathspec-limited commit is the usual way to land half of one: `git mv` stages
a rename as two index entries, and committing with a pathspec takes only the
addition.

[FILE-9] `full` — A transition into `completed/` or `cancelled/` MUST advance
`updated:` to the transition's date and MUST write `outcome:`, and both edits
MUST be made **before** the rename.

This is stricter than `[SPEC.md MUST-28]`, which requires `outcome` only in
`cancelled`. A completed ticket's outcome is what the next reader consults when
the same problem comes back, and writing it at the moment of completion is the
only time anyone knows it.

[FILE-10] `full` — After a transition, an implementation MUST read the
committed state back and assert it: that the ticket exists at its new path, that
it no longer exists at the old one, and that the new content carries the fields
just written. A successful write call is not evidence that a commit contains
what the writer intended.

## 3. Fields

[FILE-11] `minimal` — A ticket's fields live in a frontmatter block. The file's
first line MUST be exactly `---`, the block ends at the next line that is
exactly `---`, and everything after that line is the body.

[FILE-12] `minimal` — A field MUST be written inside the frontmatter block. A
key written after the closing `---` is body text: it reads as a field to a
person and is invisible to every implementation, which is the failure mode of
appending a field to a ticket that already exists.

[FILE-13] `minimal` — A key MUST begin at column zero and match
`^[A-Za-z_][A-Za-z0-9_-]*:`. A value MUST take one of exactly four forms, and a
set MUST NOT depend on any other YAML construct:

| Form | Syntax | Yields |
| --- | --- | --- |
| Scalar | `key: value` | a string; surrounding quotes are stripped |
| Inline list | `key: [a, b]` | a list, split on commas |
| Block list | `key:` then `  - item` lines | a list, empty when no items follow |
| Block scalar | `key: \|` then lines indented two spaces | a string, dedented and stripped |

`|`, `|-`, `>` and `>-` all introduce a block scalar and are not distinguished:
this binding does not depend on YAML's folding or chomping semantics. Nested
mappings, anchors, aliases, flow mappings, multi-document streams and tags are
outside the subset. The restriction is deliberate — it is what lets a ticket be
read by a parser small enough to carry no dependency, on a machine nobody
prepared in advance.

[FILE-14] `minimal` — Progress narration, which `[SPEC.md MUST-33]` keeps out of
the body, MUST be written to `<id>.notes.md` beside the ticket in the same stage
directory: a Markdown file of dated entries, appended to and never rewritten.

```markdown
## 2026-09-16
Rotated the key; the console has no API for issuance, so step 1 stays manual.
```

### Field representation

Every field the specification names, and the concrete representation it takes
here, as `[SPEC.md MUST-41]` requires:

| Field | Representation |
| --- | --- |
| lifecycle position | the stage directory — not a field (`[FILE-5]`) |
| `id` | scalar, and the leading component of the file name (`[FILE-3]`) |
| `title` | scalar |
| `created` | scalar, `YYYY-MM-DD` |
| `updated` | scalar, `YYYY-MM-DD` |
| `executor` | scalar, exactly `agent`, `human` or `mixed` |
| `tags` | inline list, or block list; `[]` when empty |
| `blocked_by` | inline list of ids in the same set; `[]` when empty |
| `touches` | block list of paths or globs (`[FILE-15]`) |
| `appends` | block list of paths or globs (`[FILE-15]`) |
| `verify` | block scalar |
| `human_steps` | block scalar |
| `outcome` | block scalar (`[FILE-9]`) |
| `defer_until` | scalar, `YYYY-MM-DD` |
| `epic` | scalar, the grouping's id |
| problem, solution, out-of-scope | headed sections of the Markdown body |

`defer_until` and `epic` carry the meanings `[SPEC.md MUST-39]` reserves for
them and no others.

[FILE-15] `full` — `touches` and `appends` globs are relative to the root the
set names, which is the root `[SPEC.md MUST-14]` requires a set to define. A set
whose work spans more than one repository MUST make the repository's directory
name the first component of every glob, and MUST say so in the set's `README`.

The set root and the work root are different directories, and conflating them is
the common mistake. A set at `~/code/issues/` whose tickets change three
repositories under `~/code/` declares `night-watchman/scripts/land-branch.sh`,
not `scripts/land-branch.sh`: the glob is resolved against `~/code/`, where the
work happens, not against the directory the tickets live in.

## 4. What this binding cannot enforce

Every requirement in `SPEC.md` is representable in this substrate, so there is
no requirement this binding cannot satisfy in the sense of
`[SPEC.md MUST-43]`. Several are satisfiable but not **checkable** from the tree
alone, and a reader should know which:

- **`[SPEC.md MUST-2]`, an id is never reused.** A directory tree keeps no
  registry of retired identifiers. A duplicate among the files present is
  detectable; reuse of an id whose file was deleted is not. What keeps the
  detection possible is `[SPEC.md MUST-29]` — a dropped ticket is cancelled, not
  removed, so its file stays in the set and its id stays taken.

- **`[SPEC.md MUST-5]`, `updated` is advanced on every change.** Nothing in the
  filesystem enforces it, and file mtime is not `updated`: a fresh clone
  rewrites every mtime in the tree. The claim is checkable only against version
  history, never against the tree.

- **`[SPEC.md MUST-9]` and `[SPEC.md MUST-10]`, a verification capable of
  failing at the base state.** A ticket can state the observation that fails
  today, and the presence of that statement is mechanically checkable;
  whether the check genuinely fails at the base commit is not a property of
  the file. It is established by running the block at the base ref, which a
  version-controlled set makes possible and the ticket cannot record on its
  own.

- **`[SPEC.md MUST-12]`, no ticket reaches `completed` unless `verify` passed.**
  The substrate records no execution. The rename into `completed/` is an
  assertion by whoever performed it, and the evidence lives in whatever ran the
  block.

- **`[SPEC.md MUST-32]`, a startable ticket's body does not change.** A file
  carries no record of when it became startable. Only version history can
  answer this.

## 5. The reference implementation

[`reference/issues.py`](../../reference/issues.py) reads a set in this binding
and is the executable account of it: `lint`, `board`, `next`, `waves` and
`scope`, stdlib-only, no install step. See
[`reference/README.md`](../../reference/README.md).

`lint` gates on the errors that make a ticket unworkable — a missing `id`,
`title`, `created`, `updated` or `verify`, an `executor` outside the three
values, `mixed` without `human_steps`, an unresolvable or self-referential
`blocked_by`, a `defer_until` that is not an ISO date, a `deferred/` ticket with
no `defer_until` (`[FILE-17]`), a duplicated id, a cancelled ticket with no
`outcome`, an `agent`/`mixed` ticket with no `touches`, and two simultaneously
startable tickets that own the same path.

A ticket in `triage/` is held only to `id`, `title`, `created` and `updated`,
per `[SPEC.md MUST-46]`. Linting the entry state against the whole contract
would report every newly written ticket as broken, which is the opposite of what
the entry state is for.

It reports, without gating, the cases that are usually a mistake and sometimes
deliberate: no `executor`, a shared `appends` path, a completed ticket whose
blockers are not, and a body that cites a conversation.

`lint` is not the conformance validator. It answers "can this set be worked
on"; a conformance claim against `SPEC.md`'s numbered requirements and profiles
is a different program.

## 6. Examples

[`examples/`](examples/) is a complete six-ticket set in this binding, one
ticket in each of five of the seven positions, that `reference/issues.py lint`
reports with zero errors and zero warnings. `triage/` and `deferred/` are absent
from it, which `[FILE-2]` reads as "no ticket is in that position right now" and
not as an omission. It is the executable half of this document:

- `open/EX-001` — the ordinary shape: `agent`, owned paths, a `verify` naming
  what fails today.
- `open/EX-002` — blocked by `EX-001`, and sharing its `appends` path without
  sharing an owned one.
- `in-progress/EX-003` — `mixed`, with `human_steps` saying where the automated
  part stops.
- `awaiting-deployment/EX-004` — landed and not yet live, with a `verify` that
  reads the written artefact rather than the unit's state.
- `completed/EX-005` — terminal, carrying the `outcome` `[FILE-9]` requires.
- `cancelled/EX-006` — a false premise kept rather than deleted, with no
  `verify` and an `outcome` that names why it lost.
