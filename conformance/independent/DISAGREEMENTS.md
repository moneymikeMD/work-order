# Disagreements: what a second implementer had to guess

`minimal-validate.py` beside this file is a second conformance validator for
the file binding, written to test the specification rather than the tickets.
The result that matters is not that it agrees with `conformance/validate.py` —
it is the list below of places where `SPEC.md` and `bindings/file/BINDING.md`
did not say enough, and the reading that was chosen instead.

WO-020 expected this list to be non-empty on a first attempt. It is.

## What was read, and what was not

Read: `SPEC.md`, `bindings/file/BINDING.md`, and the fixture trees under
`conformance/fixtures/`. The fixtures were read only *after* the validator was
written and run, and only for the cases where it disagreed with the verdict the
fixture's name claims. Every such read is recorded below as the disagreement
that forced it.

Not read, at any point: `reference/issues.py`, `reference/README.md`,
`conformance/validate.py`, `conformance/selftest.py`, `conformance/README.md`,
the compiled `conformance/__pycache__/*.pyc`, and the worked examples under
`bindings/file/examples/`.

**The independence of this exercise is already partially compromised by the
specification itself.** `BINDING.md` §5 summarises in prose exactly what the
reference `lint` gates on and what it merely reports. Reading the binding —
which is unavoidable, since `SPEC.md` alone states no syntax — hands a second
implementer a paraphrase of the reference implementation's behaviour. That
paragraph is useful documentation and it is also a leak. It contributed
directly to **D-4**, where it turned out to be *wrong* about the requirement it
describes.

## Result

At the profile `SPEC.md` gives each requirement, the independent validator
fires exactly the requirement each fixture is named for: 32 of 32, no misses
and no extras, with `conforming/` passing at `unattended` and
`violates-SHOULD-only/` not gating at `full`. `sweep.py` reproduces this.

That is a genuinely good result for the specification. The list below is what
it cost to reach.

---

## D-1 — The file binding gives a conformance claim no representation

`[SPEC.md MUST-40]` requires a conformance claim to cite MAJOR and MINOR and
exactly one profile. `BINDING.md` §3 gives a representation for every *field*
the specification names, as `[SPEC.md MUST-41]` requires — but a conformance
claim is not a field, and the binding never says where one lives in a directory
tree, what it is called, or what grammar it takes.

The shipped fixture answers all three: a file named `CONFORMANCE` at the set
root, containing one line, `work-order SPEC.md 0.1 profile full`. None of that
is derivable from the two documents. This validator could not check MUST-40 at
all until the fixture was opened, and it now accepts `CONFORMANCE`,
`CONFORMANCE.md` or `CONFORMANCE.txt` and parses them loosely, because the real
grammar is unknown.

**Resolution: spec clarified.** The file binding needs a `[FILE-N]` giving the
claim a path and a grammar. Until it has one, two implementations of MUST-40
will look for different files and both will be right.

## D-2 — A conformance claim can be well formed and false

`violates-MUST-40-claim-mismatch` ships a claim that satisfies MUST-40 as
written: it cites `0.1`, and it names exactly one profile. The fixture is a
violation only under a reading MUST-40 does not state — that the claim must
also be **true**, which means re-validating the set at the profile it claims.

This validator implements that reading, because it is the only one under which
the fixture is a violation at all.

**Resolution: spec clarified.** MUST-40, or a new requirement, should say that
a claim MUST NOT name a profile the set does not satisfy. As written, MUST-40
is a grammar rule and the fixture tests a semantic one.

## D-3 — `BINDING.md` §4 says MUST-9 is uncheckable; a fixture requires it to be checked

§4 is explicit: for `[SPEC.md MUST-9]` and `[MUST-10]`, "whether the check
genuinely fails at the base commit is not a property of the file". An
implementer who reads that sentence and believes it writes no MUST-9 check at
all — and then fails `violates-MUST-9-verify-can-fail`, whose `verify` is a
single `grep ... || true`.

That is not the general case §4 correctly calls uncheckable. It is a small,
closed set of syntactic forms that make a block incapable of failing whatever
the world looks like: a trailing `|| true`, `|| :`, `|| echo`, or a body of
nothing but `true`, `:` or `echo`. Those *are* properties of the file. This
validator flags a `verify` whose every non-comment line swallows its own exit
status.

This is the single largest gap found. It is also the requirement `SPEC.md`
itself calls "the most frequently violated requirement in this document and the
most expensive".

**Resolution: spec clarified.** §4 should keep its statement about the general
case and add that the named syntactic tautologies MUST be rejected, so that the
checkable part of MUST-9 is not lost inside a true statement about the
uncheckable part.

## D-4 — Whether an absent field violates the requirement that names it

`[MUST-6]` says a ticket "MUST carry `tags` as a flat list". `[MUST-22]` says
`executor` "MUST be exactly one of" three values. Neither says what an *absent*
field means, and the sources disagree:

- `violates-MUST-18-no-blocked-by` proves absence of `blocked_by` is a
  violation of the requirement that names it.
- `violates-MUST-6-tags-scalar` and `violates-MUST-22-bad-executor` prove only
  that a *wrong value* is one.
- Appendix A lists `executor` as "Required at: `full`", but Appendix A is
  explicitly non-normative.
- `BINDING.md` §5 says the reference `lint` reports "no `executor`" **without
  gating** — the opposite reading.
- Fifteen fixtures that isolate `minimal` requirements omit `tags`,
  `blocked_by` and `executor` entirely.

This validator treats absence as a violation at `full`. The deciding evidence
is `violates-MUST-40-claim-mismatch`: its ticket is conforming at `full` in
every respect *except* that `tags`, `blocked_by` and `executor` are absent, so
the claim of `full` is a mismatch only if absence violates. Under the reading
`BINDING.md` §5 describes, that fixture would pass and the suite would be
wrong.

**Resolution: spec clarified.** Say plainly, once, that a field a profile
requires is violated by absence as well as by a bad value — and correct §5,
which currently describes reference behaviour that contradicts the fixture set.

## D-5 — The requirements are not orthogonal, so a fixture cannot isolate one

Two shipped fixtures violate two requirements each with a single sentence:

- `violates-MUST-8-no-command` has the `verify` "Read docs/export.md and
  satisfy yourself that the column table is right." That is prose with no
  command (MUST-8) *and* a human observation as the deciding step (MUST-35).
- `violates-MUST-37-unresolvable-locator` says "following the screenshot I
  sent". That is an artefact with no locator (MUST-37) *and* a citation of a
  person as the source (MUST-36).

No implementation can be required to attribute that text to one requirement
rather than the other. This validator happens to fire only the named one at
each fixture's own profile, which is luck in the tuning, not a property of the
documents.

**Resolution: accepted as permitted latitude.** But a conformance suite should
assert "at least MUST-N fired", not "exactly MUST-N fired", unless the fixtures
are rewritten to be orthogonal. `sweep.py` asserts the stricter form
deliberately, so that this stops being true loudly rather than quietly.

## D-6 — No fixture states the profile it is meant to be read at

A fixture isolating a `minimal` requirement necessarily omits the `full` fields,
so validating it at `unattended` fires four or five unrelated requirements
alongside the one it is named for. Before profiles were derived, every
`minimal` fixture reported MUST-6, MUST-18, MUST-22 and MUST-34 as collateral.

Getting this right means parsing the requirement number out of the directory
name and looking its profile token up in `SPEC.md`. That works — and it is a
direct vindication of the specification's "this is the only statement of
profile membership in the document; there is no second list to drift out of
step with it". The token was machine-readable on the first attempt.

**Resolution: fixture corrected (suggested).** Give each fixture directory a
`CONFORMANCE` claim naming the profile it is written at. It states the intent
in the tree instead of leaving it to be reconstructed, and it exercises D-1 at
the same time.

## D-7 — `conforming/` states no profile either

It conforms at `unattended`, which this validator confirms. Nothing in the tree
says that was the intent rather than an accident of how it was written. Same
resolution as D-6.

## D-8 — "Headed sections of the Markdown body" names no headings

`BINDING.md` §3 maps problem, solution and out-of-scope to "headed sections of
the Markdown body" and stops there. This validator matches any ATX heading
whose text contains `problem`, `solution`, or `out of scope`/`boundary`,
case-insensitively. A different implementer could reasonably require exactly
`## Problem`, `## Solution` and `## Out of scope`, and would be equally
conformant.

Every shipped fixture uses exactly those three headings, so the suite cannot
tell the two readings apart and a ticket set written to the other one would
pass one validator and fail the other.

**Resolution: spec clarified.** Name the headings, or state that the match is
on heading text and is case-insensitive.

## D-9 — MUST-8's second clause has no syntactic signature

MUST-8 requires `verify` to state the commands "**and the result that counts as
passing**". Only the first half has a detectable shape. This validator reduces
MUST-8 to "at least one line looks like a command", which a `verify` full of
commands and silent about what passing means would satisfy.

No fixture covers the second clause.

**Resolution: accepted, with the gap recorded.** Either add a fixture, or say
in the binding that the second clause is not mechanically checkable — the same
courtesy §4 extends to MUST-9 and MUST-12.

## D-10 — MUST-10 is recognised only by vocabulary

MUST-10 requires `verify` to record the specific observation that fails at the
base state. There is no way to detect that except by looking for the words
people use to write it. This validator matches `today`, `right now`,
`currently`, `does not exist`, `not yet`, `at the base`, `before this ticket`.

Every shipped fixture that satisfies MUST-10 uses the word "today", including
the illustrative ticket in Appendix B. A conforming ticket that states the
observation in other words is failed here and would presumably pass a validator
keyed on something else.

**Resolution: spec clarified, or the heuristic acknowledged.** The binding
should either name a convention for stating the observation or say that the
check is a heuristic and that two implementations are not expected to agree on
it.

## D-11 — MUST-37 and MUST-38 are open-vocabulary and cannot be made to agree

"Every artefact named by a locator resolvable from the ticket alone" and "every
choice already settled in the ticket" are not decidable from text. The
detectors here are keyword lists — `TBD`, `decide later`, `the usual place`,
`the screenshot I sent` — extended until the shipped fixtures fired. Any other
implementer's list differs on every ticket outside this suite.

**Resolution: accepted as permitted latitude.** The specification should say so,
though: as written, MUST-37 and MUST-38 read like checkable obligations, and a
conformance claim that includes them implies an agreement between
implementations that cannot exist.

## D-12 — Nothing says an extra stage directory is an error

`[MUST-25]` requires five positions be represented. `[FILE-2]` says the stage
directory names "MUST be exactly" those five, and that an absent one is not an
error. Neither says what an *extra* directory at the set root means, though
"exactly" implies it is one, and `violates-MUST-25-stray-stage` confirms it by
shipping `backlog/`.

The related question is also unanswered: is a non-stage directory that is
obviously not a stage — `.git/`, `docs/`, `scripts/` — an error too? This
validator exempts dot-directories and flags everything else. Nothing authorises
that exemption; a set root holding a `README` directory would be rejected here
and might not be elsewhere.

**Resolution: binding clarified.** `[FILE-2]` should say that a directory at
the set root which is not one of the five MUST be reported, and say which, if
any, are exempt.

## D-13 — MUST-15 gives no rule for comparing two paths

MUST-14 allows `touches` entries to be "literal paths or globs". MUST-15 then
forbids two simultaneously startable tickets from sharing "a `touches` path",
without saying when a glob and a path, or two globs, count as the same path.
Whether `docs/**` collides with `docs/export.md` is left open.

This validator treats a glob as overlapping any path it matches, in either
direction, plus prefix containment for `dir/**` and `dir/*`. The shipped
fixture uses two identical literal paths and so does not discriminate between
this reading and the narrowest possible one.

**This is the most consequential ambiguity in the list.** Two implementations
differing here disagree about which tickets may be worked in parallel, which is
the entire purpose of section 3 — and `[SHOULD-6]` actively encourages the
generous globs that make the question bite.

**Resolution: spec clarified.** State the comparison rule, and add a fixture
where a glob and a literal path collide.

## D-14 — Some requirements a claim covers cannot be checked by any validator

`BINDING.md` §4 already names five: MUST-2, MUST-5, MUST-9's runtime half,
MUST-12 and MUST-32. Two more belong with them: MUST-16 (an `appends` overlap
is a warning) and MUST-21 (startability) constrain what an implementation
*does*, not what a ticket carries, so a set validator can implement them and
they can never fail a set. MUST-41 to MUST-45 constrain a binding document
rather than a ticket set, and are outside a set validator's reach entirely.

Section 10 says a profile's membership is "every requirement marked X", which
means a conformance claim at `minimal` covers MUST-41 through MUST-45 and
MUST-2 alongside the ones a validator actually tests.

**Resolution: accepted.** Worth a sentence in section 10 distinguishing the
requirements a claim is *checked* on from the ones it is merely *asserted* on,
so that "passes the validator" and "conforms" are not read as the same claim.

---

## What this did not find

No disagreement was found on the mechanical core: the frontmatter subset of
`[FILE-13]`, the five positions, the identity and date fields, `blocked_by`
resolution and cycles, the `touches`/`appends` split, or the executor
classification. All of those were implementable from the documents on the first
attempt, with no fixture consulted. That is the part of the specification that
carries its meaning without its author.
