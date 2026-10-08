# work-order-jira

The Jira binding for the [work-order](https://github.com/moneymikeMD/work-order/blob/main/SPEC.md) ticket-as-contract
specification: a normative mapping of the contract onto Jira Cloud
company-managed projects, the provider that runs tickets against it, and a
provisioner that creates a conforming Space.

Versioned independently of the specification and of the `work-order` plugin.
Atlassian's API changes on its own schedule; the core contract does not
re-release because an endpoint moved.

- **[BINDING.md](BINDING.md)** — the binding itself. Every field's
  representation, the single representation of the lifecycle, the validators
  that make the contract gate rather than describe, and what Jira cannot
  satisfy.
- **`provision.sh`** — create or converge a Space on a tier; the default,
  `--tier managed`, is a conforming Space.
- **`provider.sh`** — `fetch`, `position`, `transition`, `comment`, `create`, `update`, `link`, `unlink`, `parent`.
- **[GOLDEN-FLOWS.md](GOLDEN-FLOWS.md)** — the closed list of jobs this binding does, each as the commands that do it. Feature-complete means all of them pass live.
- **`issues-api.sh`** — the read-only wrapper `reference/issues.py --source jira` calls, over `lib/jira-http.sh`.
- **`universal-apply.sh`** — converge the site-wide Universal workflows, their
  shared workflow scheme, and both tiers' screens, screen schemes, issue type
  screen schemes and issue type schemes towards `universal-workflows.json`,
  additively. `--dry-run` first; it validates against Jira and writes nothing.
- **`universal-switch.sh`** — move a project onto its tier's shared workflow
  scheme, issue type scheme, issue type screen scheme and category, and delete
  its old per-project workflows, schemes and screens.
- **`fixtures/`** — responses recorded from a live Jira site.
- **`selftest.sh`**, **`universal-apply-selftest.sh`**,
  **`universal-switch-selftest.sh`** — offline; stub the HTTP client and reach
  no network.

## Requirements

`bash` (3.2 is enough), `curl`, `jq`, `column`. Nothing else.

## Credentials

Three environment variables, read only by `lib/jira-http.sh`:

```sh
export WORK_ORDER_JIRA_BASE_URL=https://your-site.atlassian.net
export WORK_ORDER_JIRA_EMAIL=you@example.com
export WORK_ORDER_JIRA_TOKEN=...          # an Atlassian API token
```

The token reaches `curl` on a config file fed to its stdin, never on argv,
where any process running as the same user could read it.

## Provisioning a Space

Read the plan before running anything. `--dry-run` prints every request it
would make, reaches no network and resolves no credential:

```sh
./provision.sh --dry-run --project ZZPROBE --name "Probe"
```

Then, against a scratch project first:

```sh
./provision.sh --yes --project ZZPROBE --name "Probe"
```

It is idempotent — a second run reports what is already in place and changes
nothing. Rehearse on a throwaway key before pointing it at a Space that matters:
it creates a project and the site-wide custom fields, converges the global
workflows, schemes and screens every project shares, and switches the project
onto them.

No project gets a workflow, scheme or screen of its own. The last step runs
`universal-apply.sh`, which converges `Universal Managed Workflow` (Task,
Story, Bug) and `Universal Managed Grouping Workflow` (Epic, Sub-task) under
`Universal Managed Workflow Scheme`, and the shared screens and issue type
schemes of `BINDING.md` section 3.3. Then `universal-switch.sh KEY --tier
managed` moves the project onto them, maps its `To Do` and `Done` issues onto
the lifecycle, and deletes the workflows, schemes and screens the Jira template
gave it. Both workflows create issues at `Triage`, the entry state — see
`[JIRA-12]`. `--tier simplified` puts a project that is not a ticket set on
`Open`, `In Progress`, `Done` and a screen with no contract field.

## Running tickets

```sh
./provider.sh fetch PROJ-12
./provider.sh position PROJ-12                    # -> in-progress; exit 4 if unmapped
./provider.sh transition PROJ-12 awaiting-deployment
./provider.sh transition PROJ-12 cancelled --outcome "Superseded by PROJ-14"
./provider.sh comment PROJ-12 -                   # body on stdin
./provider.sh create PROJ Task "What will be true when this is done"   # exit 3 if an open issue has this title
./provider.sh create PROJ Task "" --ticket decision.json   # its epic, when filed, becomes the parent
./provider.sh link PROJ-13 --blocked-by PROJ-12
./provider.sh parent PROJ-13 --epic PROJ-10             # --replace to move it from another epic
./provider.sh update PROJ-13 --ticket contract.json      # rewrite fields; an empty value clears one
printf '{"defer_until":"2026-12-01"}' | ./provider.sh update PROJ-13 --ticket -
python3 ../../reference/issues.py next --source jira --jira-api ./issues-api.sh --jira-project PROJ
```

`transition` takes a lifecycle position, not a Jira transition id, and resolves
it against the live issue. A transition that a validator refuses fails loudly
rather than moving the ticket somewhere else. `--outcome` writes the cancelled
ticket's outcome in its own request first; `create` refuses, exit 3, to file a
second open issue with the same summary unless given `--allow-duplicate`.
`parent` sets a ticket's epic and reads it back; `create --ticket` does the
same in the create request when the decision's `epic` already exists. `update`
rewrites the fields a decision carries, clears the ones it carries empty, and
reads each back. A transition to the position a ticket already holds is a
no-op, so a filing sequence can be re-run after a partial failure.

## Tests

```sh
./selftest.sh
```

No network, no Jira site, no credential: the tests either exercise a `--dry-run`
path or pass `--http` pointing at a stub, and a stub that is never reached is
a failure rather than a pass.
