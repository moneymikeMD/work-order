# work-order — working notes

## What this repo is

A public specification of the ticket-as-contract layer extracted from
night-watchman. The specification text, the conformance validator, the file
binding and the Jira binding land as separate pieces of work; this file records
how the repository itself is worked.

## Workflow

- `main` is protected by a ruleset named `main`: every change lands through a
  pull request, and deletion and force-pushes are rejected. Confirm it is
  actually in place with `gh api repos/moneymikeMD/work-order/rulesets` — the
  ruleset is the last step of the landing script, so a run that stopped early
  leaves this paragraph describing an intention rather than a fact.
- Outside contributors need one approving review. The owner is a bypass actor,
  so the owner's own PRs merge without waiting. That makes the review and the
  required check advisory for the owner and gating for everyone else.
- Squash merge, branch deleted on merge.
- Conventional Commits are required, not optional: `release-please` derives the
  version bump and `CHANGELOG.md` from the commit subjects. A non-conforming
  subject silently drops out of the changelog.

## CI

`.github/workflows/ci.yml` runs two jobs on push to `main` and on every pull
request. `validate` parses every JSON and YAML file in the tree and compiles
every Python file. `selftests` **discovers** every `*selftest*.sh` by glob and
runs it, then runs the Python selftest entry points — `reference/issues.py
selftest` and `conformance/validate.py --selftest`, which a filename glob cannot
find. A selftest added later is covered with no workflow edit.

Every selftest here is offline by construction: each stubs its HTTP client on
`PATH` and reaches no network, site or credential, which is what lets them run
on a public repository with no secret.

`validate` is a required status check on `main`; add `selftests` to the ruleset
so a red suite blocks a merge.

Why the second job exists: `validate` alone was green while 14 assertions in
`plugins/work-order-jira/selftest.sh` were failing, because nothing ran them
(WO-052).

## Packaging

A Claude Code marketplace plugin installs exactly the subtree its marketplace
entry's `source` names and nothing else. This repository has no marketplace of
its own: `moneymikeMD/moneymike-plugins` lists both plugins, with no `ref` or
`sha`, so installs track this repository's default branch.

The `work-order` plugin is a `github` source for the whole repository, so the
repository *is* the plugin and `.claude-plugin/plugin.json` sits at its root.
Anything the plugin claims to ship must therefore live in the tree, not merely be
referenced by it.

`plugins/work-order-jira/` is a `git-subdir` source, because everything it needs
is inside it. Its `work-order` dependency is resolved by git tag, so a pin no tag
satisfies fails the install outright.

## Releases

`release-please` maintains `CHANGELOG.md`, `version.txt`,
`.claude-plugin/plugin.json`'s version and `.release-please-manifest.json`
through a release PR. Nothing in those files is edited by hand.

The `work-order` plugin is versioned by the repository's own release, because
the repository is the plugin: it moved from its own `work-order--v0.2.0` line
onto `version.txt`'s line at 1.2.0. Only `work-order-jira` still carries a
separate `work-order-jira--vX.Y.Z` tag.

The plugin's dependents pin it with a semver range, and Claude Code resolves that
against `work-order--vX.Y.Z` tags on this repository, not against release-please's
`vX.Y.Z`. The `release-please` workflow therefore adds a `work-order--v` tag on the
release commit whenever the root package releases; `work-order--v1.3.0` through
`--v1.5.0` were created by hand at the same commits as their `v` twins. Without the
prefixed tag, an install through `moneymike-plugins` leaves the dependency
unresolved.

Known quirk: a commit pushed with the default `GITHUB_TOKEN` does not trigger
other workflows, so the release PR's rebases do not re-run CI and its checks go
stale. `gh pr close <n> && gh pr reopen <n>` re-triggers them.

### No repo here goes past v1.x

Owner decision, 2026-09-20 (WO-060): no repo in this ecosystem moves beyond
`v1.x.x` until the owner says the final resting stance has arrived. Nobody
outside consumes these repos, and a version number in the fives would record
indecision rather than compatibility.

So a change that would be breaking ships as a **minor**, and explains the
incompatibility in the commit body as prose. What is banned is the *marker*
release-please reads as a major bump — a `!` after the type or scope, and a
`BREAKING CHANGE:` / `BREAKING-CHANGE:` footer — not the change itself. This
applies to the pull request title too, because `pr-land.sh` squash-merges and
the squash subject comes from the title.

The `no-major` job in `.github/workflows/ci.yml` enforces it on every pull
request and on every push to `main`; ai-toolkit and night-watchman run the same
job. Lifting the cap is one commit per repo: delete the job.

## Dependencies

Dependabot watches the `github-actions` ecosystem weekly. Its PRs are reviewed
by hand — there is no auto-merge. Add a `pip` ecosystem entry once the reference
implementation ships a dependency manifest.
