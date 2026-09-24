# work-order

work-order is a public specification of the ticket-as-contract layer extracted
from night-watchman: a ticket is a contract an agent can pick up cold and
execute, carrying the problem, a binding solution, the decisions already
settled, and a hard out-of-scope boundary. This repository publishes that
contract as a specification, with `issues.py` as its reference implementation, a
conformance validator that sorts requirements into MUST and SHOULD levels and
groups them into named profiles, a file binding for tickets that live as
Markdown on disk, and a separately versioned Jira binding for teams whose
tickets live in a tracker instead.

## Install

```
/plugin marketplace add moneymikeMD/moneymike-plugins
/plugin install work-order@moneymike-plugins
```

The [moneymike-plugins](https://github.com/moneymikeMD/moneymike-plugins)
marketplace publishes the `work-order` plugin from this repository's root, so
installing it copies the whole tree — a Claude Code plugin install carries
exactly the subtree its marketplace entry names and nothing else. The Jira
binding installs separately as `work-order-jira@moneymike-plugins`.

## What installing it gets you

| Path | What it is |
| --- | --- |
| `SPEC.md` | The specification text, versioned independently by `VERSION-spec`. |
| `reference/issues.py` | The reference implementation. |
| `bindings/file/` | The file binding: tickets as Markdown on disk, with worked examples. |
| `conformance/` | The conformance validator and the fixtures that prove it fails. |
| `decision-list/` | The decision-list format and its schema validator. |
| `extensions/sprint/` | The sprint mechanism, as an optional extension. |
| `skills/emit-tickets/` | Turns a validated decision list into ticket files. |
| `plugins/work-order-jira/` | The Jira binding, published as its own plugin. |

## Versions

Five numbers move independently. `VERSION-spec` is the specification's own
version and `bindings/file/VERSION` the file binding's. `version.txt` is this
repository's release version, and the `work-order` plugin ships at that same
number because the plugin is this repository. `plugins/work-order-jira/`
carries its own, and `decision-list/` its `decision_list_version`.

## License

MIT. See [LICENSE](LICENSE).
