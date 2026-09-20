# The conformance validator

`validate.py` answers one question: **does this ticket set satisfy
[`SPEC.md`](../SPEC.md)'s numbered requirements at a declared profile?**

```
validate.py --profile minimal|full|unattended SET_DIR
validate.py --selftest
```

It reads a set in the [file binding](../bindings/file/BINDING.md) — one stage
directory per lifecycle position, tickets as Markdown files with frontmatter —
and prints one row per requirement in the profile. Stdlib only, no install
step, no network.

**Only MUST failures gate.** A violated MUST exits 1. SHOULD findings are
printed and exit 0, which is what lets a set adopt the specification
incrementally instead of facing a cliff. A usage or setup error exits 2.

```
$ validate.py --profile full ~/code/issues/
MUST-9     minimal     FAIL
    completed/WO-026-dispatch-adapter.md: a check ends in '|| echo', which always exits 0
SHOULD-1   minimal     report
    cancelled/WO-C01-work-order-inside-ai-toolkit.md: id 'WO-C01' is not of the form PREFIX-NNN

40 MUST and 11 SHOULD in profile `full`: 32 pass, 1 FAIL, 1 SHOULD reported, ...
FAIL: 1 MUST violated at profile `full`: MUST-9
```

## This is not `issues.py lint`

[`reference/issues.py`](../reference/issues.py) answers "can this set be worked
on": the errors that make a ticket unworkable inside one repository. This
program answers "does this set conform to the specification, at which profile".
They are deliberately separate programs — folding conformance into the
reference implementation would make that implementation the definition of
conformance, and the specification would stop being the thing that decides.

The two overlap on a handful of checks and disagree on emphasis everywhere
else. Neither is derived from the other, and this one has its own frontmatter
parser, so a change to `issues.py` cannot silently move what conformance means.

## Profiles come from `SPEC.md`, not from a list in here

Each requirement in `SPEC.md` carries one inline token naming the lowest
profile it applies at, and the profiles nest (`minimal` ⊂ `full` ⊂
`unattended`). `validate.py` parses those tokens and computes membership. There
is no second copy of the membership in this directory to drift out of step with
the document, which is the same reason `SPEC.md` has no per-profile identifier
list.

## What each status means

| Status | Meaning |
| --- | --- |
| `pass` | checked against the set, no findings |
| `FAIL` | a MUST in the profile is violated; the program exits 1 |
| `report` | a SHOULD finding; printed, never gates |
| `not-checkable` | not a property of the tree — history, execution, or a judgement. The row names the reason |
| `implementation` | constrains an implementation rather than a set; this program's own behaviour satisfies it |
| `document` | constrains a binding document or the specification itself, not a ticket set |
| `UNCHECKED` | `SPEC.md` carries a requirement this program neither checks nor explains. `--selftest` fails on it |

`not-checkable` is the honest half of the report. `bindings/file/BINDING.md` §4
lists the requirements a directory tree cannot answer — whether `updated` was
advanced, whether `verify` was executed before a ticket reached `completed`,
whether an identifier was reused after its file was deleted — and this program
says so per requirement rather than passing them silently.

The one that matters most is `[MUST-9]`, a `verify` capable of failing at the
base state. Whether a check genuinely fails at the base commit is established
by running it there, which
[`ai-toolkit/scripts/verify-run.sh --against`](https://github.com/moneymikeMD/ai-toolkit)
does and a file cannot record. What this program checks is the structural half:
a block whose every command is incapable of failing, a check ending in
`|| echo` (which always exits 0), and a PCRE construct inside a `grep -E`
pattern, which is invalid in POSIX ERE and makes a negated check pass
unconditionally.

## How a set claims a profile

`--profile` is itself the claim, so a set needs nothing on disk to be
validated. A set that wants to record its claim writes one line in a
`CONFORMANCE` file, or anywhere in its `README.md`, in this shape:

```
work-order SPEC.md 0.1 profile full
```

`[MUST-40]` then checks that the written claim cites this document's MAJOR.MINOR
and the profile actually being validated. A claim that disagrees with the flag
is a failure: the interesting case is a set that claims `unattended` in its
README and is only ever validated at `minimal`.

## Layouts

**Staged** — the file binding's layout, and the normal case. Stage directories
that are absent are treated as empty, per `[FILE-2]`. A ticket found outside the
five stage directories, or nested below one, is reported under `[MUST-25]`.

**Flat** — a directory holding ticket files and no stage directories at all is
read as a set of `open` tickets. This is what a generator such as the
`emit-tickets` skill writes into an output directory, and validating that output
is how a producer proves what it emits conforms. `[MUST-25]` is reported
`not-checkable` in this layout: a flat directory represents no lifecycle
position, so there is nothing to check it against.

`<id>.notes.md` files are progress notes, not tickets, per `[FILE-4]`.

## Fixtures

`fixtures/` is the evidence that the validator has teeth. A validator nobody has
watched fail is indistinguishable from one that passes everything.

- **`conforming/`** — a six-ticket set, one ticket in each of the five
  lifecycle positions, that passes at `minimal`, `full` **and** `unattended`
  with no MUST violated.
- **`violates-MUST-<n>-<slug>/`** — one directory per mechanically checkable
  MUST. Each is `conforming/` with exactly one edit, and fails exactly that one
  requirement at the profile the requirement itself declares.
- **`violates-SHOULD-only/`** — reports SHOULD findings and exits 0.

The headline fixture is `violates-MUST-9-verify-can-fail/`: a ticket whose only
check ends `|| true`, so it cannot fail at the base state, states an observation
that makes it look thorough, and would read as done on the day it was written.
That is the most frequently violated requirement in the specification and the
easiest to write a convincing fake check for.

## `--selftest`

`validate.py --selftest` is what keeps the fixtures and the checks honest. It
asserts:

1. `SPEC.md`'s MUST and SHOULD identifiers are contiguous from 1, with no
   duplicates.
2. Every requirement in `SPEC.md` has either a check or a recorded reason for
   not having one — so a requirement added to the specification reports
   `UNCHECKED` and fails the selftest, rather than being silently passed.
3. No check names a requirement `SPEC.md` does not contain.
4. `conforming/` conforms at all three profiles.
5. Every gating MUST check has a negative fixture, and every negative fixture
   names a requirement this program checks. A check cannot be added without a
   fixture that proves it fires.
6. Each negative fixture fails **exactly** the requirement its directory name
   declares — the set of gating failures is precisely that one requirement.
   SHOULD findings alongside it are allowed and expected.
7. `violates-SHOULD-only/` exits 0 and still reports.

Run it after any change to the checks or the fixtures.

## Adding a check

1. Write the check and register it in `CHECKS` under its requirement's
   identifier.
2. Add `fixtures/violates-MUST-<n>-<slug>/`: a copy of a conforming set with
   the single edit that violates it, and nothing else.
3. Run `--selftest`. It will tell you if the fixture trips a second requirement
   as well, which means the fixture is testing two things and the report would
   not be able to name the cause.

A requirement with no mechanical check goes in `UNCHECKABLE` with the reason it
has none, in one sentence a reader of the report can act on.
