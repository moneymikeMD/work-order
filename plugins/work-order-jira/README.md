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
- **`provision.sh`** — create or converge a conforming Space.
- **`provider.sh`** — `fetch`, `position`, `transition`, `comment`, `create`.
- **`workflow-apply.sh`** — provisioning step 3 on its own.
- **`fixtures/`** — responses recorded from a live Jira site.
- **`selftest.sh`** — offline; stubs the HTTP client and reaches no network.

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
it creates a project, seven site-wide custom fields, and statuses and
validators on a shared workflow.

## Running tickets

```sh
./provider.sh fetch PROJ-12
./provider.sh position PROJ-12                    # -> in-progress
./provider.sh transition PROJ-12 awaiting-deployment
./provider.sh comment PROJ-12 -                   # body on stdin
./provider.sh create PROJ Task "What will be true when this is done"
```

`transition` takes a lifecycle position, not a Jira transition id, and resolves
it against the live issue. A transition that a validator refuses fails loudly
rather than moving the ticket somewhere else.

## Tests

```sh
./selftest.sh
```

No network, no Jira site, no credential: the tests either exercise a `--dry-run`
path or pass `--http` pointing at a stub, and a stub that is never reached is
a failure rather than a pass.
