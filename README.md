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

## Status

Early. The specification text, the conformance validator and the bindings are
tracked as separate pieces of work. This repository currently holds its
scaffolding only.

## License

MIT. See [LICENSE](LICENSE).
