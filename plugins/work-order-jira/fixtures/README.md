# Fixtures

Every file here is a response **recorded from a live Jira Cloud site**, not
authored to match what the API was expected to return. That distinction is the
point: the parameter shapes in `workflow-rules.json`, the `searcherKey` values
in `provision.sh`, and the screen walk in step 5 were all derived from these
recordings after earlier guesses turned out wrong.

Each file keeps the header it was captured with, naming the request, the date,
and the scratch project it came from. Hosts, emails, account ids and avatar
URLs are scrubbed to placeholders; keys, ids and response shapes are exactly
what the API returned.

`.txt` files are transcripts: comment lines, then in some cases an `HTTP <code>`
line, then the body. `.json` files are bodies alone.

## What each one records

| Fixture | Request |
| --- | --- |
| `statuses.search.txt` | `GET /statuses/search?maxResults=100` — the site-wide status list step 3 resolves names against |
| `field.list.txt` | `GET /field` — the site-wide field list step 4 resolves names against |
| `field.create.txt` | `POST /field` for a textarea field created with no `searcherKey` |
| `search.jql.not-searchable.txt` | `GET /search/jql` probing that field — the HTTP 400 that carries **no** "not searchable" text anywhere in its body |
| `field.searcherkey-put.txt` | `PUT /field/<id>` repairing it with a `searcherKey` |
| `search.jql.searchable.txt` | the same probe after the repair — the only evidence the repair worked |
| `workflow.search.txt` | `GET /workflow/search?workflowName=...&expand=transitions,statuses` |
| `workflows.bulkget.rules-before.txt` | `POST /workflows` bulk-get, baseline: version 1, no validators |
| `workflows.bulkget.rules-after.txt` | the same bulk-get after `/workflows/update`, version 2 — the recorded shape of `system:validate-field-value` and `system:previous-status-validator` as Jira stores them |
| `workflows.update.validation.txt` | `POST /workflows/update/validation` and its `errors` array |
| `issuetypescreenscheme.project.txt` | `GET /issuetypescreenscheme/project?projectId=...` |
| `issuetypescreenscheme.mapping.txt` | `GET /issuetypescreenscheme/mapping?...` — three distinct screen schemes, because the template gives Bug and Epic their own |
| `screenscheme.txt` | `GET /screenscheme?id=&id=&id=` — the repeated-`id` bulk form, because there is no per-id GET |
| `screens.<id>.tabs.txt` | `GET /screens/<id>/tabs` |
| `screens.<id>.tab.<tab>.fields.txt` | `GET /screens/<id>/tabs/<tab>/fields` — none of the work-order fields present, which is why step 5 exists |
| `issue.create.json` | `POST /issue` response |
| `issue.fetch.json` | `GET /issue/<key>` response |
| `issue.transitions.json` | `GET /issue/<key>/transitions` response |
| `issue.status.json` | `GET /issue/<key>?fields=status` response |

## Requests, not responses

Two files here are inputs rather than recordings, and are marked as such
because the rule above is what makes the rest of this directory worth
trusting.

| Fixture | Is |
| --- | --- |
| `ticket-full.json` | a decision list (`decision-list/FORMAT.md`) carrying every field `provider.sh create --ticket` writes, so the selftest can prove each one survives a create and a fetch. `decision-list/validate.py` accepts it |
| `ticket-minimal.json` | one bare decision object, most fields absent, and a `blocked_by` the create path declares it does not write |

## Provenance

These were captured during the night-watchman work that this binding was
extracted from, against scratch projects created for that purpose and removed
afterwards. The originals live in that repository's
`providers/tracker/jira/fixtures/`; the files here are the same bytes under
endpoint-shaped names.

`selftest.sh` reads these fixtures and composes stub responses from them. Where
no live capture exists for a request — a fresh project's readback, `GET /myself`,
a `POST /field` response for a named field — the stub builds one inline and says
so. Nothing synthetic is filed here.
