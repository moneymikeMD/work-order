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

`.github/workflows/ci.yml` runs one job, `validate`, on push to `main` and on
every pull request. It parses every JSON and YAML file in the tree and compiles
every Python file. `validate` is the required status check on `main`.

## Releases

`release-please` maintains `CHANGELOG.md`, `version.txt` and
`.release-please-manifest.json` through a release PR. Nothing in those three
files is edited by hand.

Known quirk: a commit pushed with the default `GITHUB_TOKEN` does not trigger
other workflows, so the release PR's rebases do not re-run CI and its checks go
stale. `gh pr close <n> && gh pr reopen <n>` re-triggers them.

## Dependencies

Dependabot watches the `github-actions` ecosystem weekly. Its PRs are reviewed
by hand — there is no auto-merge. Add a `pip` ecosystem entry once the reference
implementation ships a dependency manifest.
