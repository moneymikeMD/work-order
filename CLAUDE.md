# work-order — working notes

## What this repo is

A public specification of the ticket-as-contract layer extracted from
night-watchman. The specification text, the conformance validator, the file
binding and the Jira binding land as separate pieces of work; this file records
how the repository itself is worked.

## Workflow

- `main` is protected by a ruleset named `main`: every change lands through a
  pull request, deletion and force-pushes are rejected, `validate` is the one
  required status check, and one approving review is required. The repository
  admin role is a bypass actor, so the owner's own PRs merge without waiting —
  `ai-toolkit/scripts/pr-land.sh` takes that path when every required check is
  green and nothing else on the head SHA has failed.
- Squash merge, branch deleted on merge.
- Conventional Commits are required, not optional: `release-please` derives the
  version bump and `CHANGELOG.md` from the commit subjects. A non-conforming
  subject silently drops out of the changelog.

## CI

`.github/workflows/ci.yml` runs **four** jobs on push to `main` and on every
pull request: `selftests`, `validate`, `no-major` and `no-personal-paths`.

`validate` parses every JSON and YAML file in the tree and compiles every Python
file. `selftests` discovers every `*selftest*.sh` by glob and runs it, then
runs the Python selftest entry points — `reference/issues.py selftest` and
`conformance/validate.py --selftest`, which a filename glob cannot find. A
selftest added later is covered with no workflow edit. `no-major` is the version
cap, described below. `no-personal-paths` consumes an ai-toolkit action.

Only `validate` is a required status check; the other three report. A red
selftest suite therefore does not block a merge by itself.

Every selftest here is offline by construction: each stubs its HTTP client on
`PATH` and reaches no network, site or credential, which is what lets them run
on a public repository with no secret.

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
the repository is the plugin. `work-order-jira` carries a separate
`work-order-jira--vX.Y.Z` tag line.

The plugin's dependents pin it with a semver range, and Claude Code resolves that
against `work-order--vX.Y.Z` tags on this repository, not against release-please's
`vX.Y.Z`. The `release-please` workflow therefore adds a `work-order--v` tag on the
release commit whenever the root package releases. Without the prefixed tag, an
install through `moneymike-plugins` leaves the dependency unresolved.

A commit pushed with the default `GITHUB_TOKEN` does not trigger other
workflows, so a release PR pushed with it carries no checks. The
`release-please` workflow therefore runs with the `RELEASE_PLEASE_TOKEN`
repository secret, a fine-grained PAT with Contents and Pull requests
read/write, so its pushes run CI like any other. That PAT expires within a
year of 2026-09-26; once it does, release PRs come back with no checks, and
the fix is a new PAT in the same secret. Until then, `gh pr close <n> && gh pr
reopen <n>` is the one-off remedy for a release PR already sitting with no
checks.

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

The `no-major` job in `.github/workflows/ci.yml` reports on every pull request
and on every push to `main`; ai-toolkit and night-watchman run the same job.
It is not a required status check in any of the three, so a `feat!:` subject
or a `BREAKING CHANGE:` footer goes red on a check nobody has to wait for. The
cap rests on this rule and on review. Making the job required is NWM-163,
approved by the owner and not yet applied to the rulesets. Lifting the cap is
one commit per repo: delete the job.

## Dependencies

Dependabot watches the `github-actions` ecosystem weekly. Its PRs are reviewed
by hand — there is no auto-merge. Add a `pip` ecosystem entry once the reference
implementation ships a dependency manifest.
