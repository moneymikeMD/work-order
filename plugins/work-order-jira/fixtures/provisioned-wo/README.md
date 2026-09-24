# provisioned-wo

`createmeta.json` is a response recorded from a Jira Space provisioned by
`provision.sh --project WO` at the `full` profile, on 2026-09-20. It is the
shape a conforming Space presents to a caller about to create an issue, and it
exists so the selftests can assert against a real provisioned project without
reaching a site.

**The site name is redacted.** Every `https://<site>.atlassian.net` became
`https://example.atlassian.net`. This repository is public and names no host,
vault or other personal infrastructure. Nothing else was altered, so the
structure, the field ids and the issue types are exactly what the site returned.

The seven custom fields the binding provisions appear here with the ids that
site assigned. **Ids are per-site**: a different site assigns different ones,
which is why every script resolves them by name at run time rather than reading
them from this file.
