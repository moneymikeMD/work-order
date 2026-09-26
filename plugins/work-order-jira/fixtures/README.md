# Fixtures

Every file here is a response **recorded from a live Jira Cloud site**, not
authored to match what the API was expected to return. That distinction is the
point: the `searcherKey` values in `provision.sh` and its screen walk were
derived from these recordings after earlier guesses turned out wrong.

Each file keeps the header it was captured with, naming the request, the date,
and the scratch project it came from. Hosts, emails, account ids and avatar
URLs are scrubbed to placeholders; keys, ids and response shapes are exactly
what the API returned.

`.txt` files are transcripts: comment lines, then in some cases an `HTTP <code>`
line, then the body. `.json` files are bodies alone.

## What each one records

| Fixture | Request |
| --- | --- |
| `field.list.txt` | `GET /field` — the site-wide field list step 4 resolves names against |
| `field.create.txt` | `POST /field` for a textarea field created with no `searcherKey` |
| `search.jql.not-searchable.txt` | `GET /search/jql` probing that field — the HTTP 400 that carries **no** "not searchable" text anywhere in its body |
| `field.searcherkey-put.txt` | `PUT /field/<id>` repairing it with a `searcherKey` |
| `search.jql.searchable.txt` | the same probe after the repair — the only evidence the repair worked |
| `issuetypescreenscheme.project.txt` | `GET /issuetypescreenscheme/project?projectId=...` |
| `issuetypescreenscheme.mapping.txt` | `GET /issuetypescreenscheme/mapping?...` — three distinct screen schemes, because the template gives Bug and Epic their own |
| `screenscheme.txt` | `GET /screenscheme?id=&id=&id=` — the repeated-`id` bulk form, because there is no per-id GET |
| `screens.<id>.tabs.txt` | `GET /screens/<id>/tabs` |
| `screens.<id>.tab.<tab>.fields.txt` | `GET /screens/<id>/tabs/<tab>/fields` — none of the work-order fields present, which is why step 5 exists |
| `issue.create.json` | `POST /issue` response |
| `issue.fetch.json` | `GET /issue/<key>` response |
| `issue.transitions.json` | `GET /issue/<key>/transitions` response |
| `issue.status.json` | `GET /issue/<key>?fields=status` response |

### `universal/`

Read-only responses recorded 2026-09-26 for `universal-apply.sh`, before any
write: both Universal workflows at version 1 with no validators, and no
Universal scheme yet.

| Fixture | Request |
| --- | --- |
| `workflows.bulkget.task.txt` | `POST /workflows` for `Universal Managed Workflow` |
| `workflows.bulkget.epic.txt` | `POST /workflows` for `Universal Managed Epic Workflow`, before its rename |
| `workflows.bulkget.absent.txt` | `POST /workflows` naming an absent workflow — the whole request 404s, even when other listed names exist |
| `statuses.search.txt`, `field.list.txt`, `issuetype.list.txt` | the site-wide lists names are resolved against |
| `workflowscheme.list.txt` | `GET /workflowscheme?startAt=0&maxResults=50` |
| `workflows.update.validation.ok.txt` | `POST /workflows/update/validation`, no errors |
| `workflows.update.validation.error.txt` | the same with a transition to a status that does not exist |

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

## `switch/`

Read-only responses recorded 2026-09-26 from project LAB for
`universal-switch-selftest.sh`: the workflow scheme list (trimmed to LAB, NWM
and WO), a project's scheme and its usages, workflow searches with statuses,
a workflow's scheme and project usages, three `POST /search/jql` pages of To Do
issues (verify text replaced with a placeholder), and an issue's transitions.
The `switch.400.*` files are deliberately invalid bodies sent to
`POST /workflowscheme/project/switch` with a target scheme id that does not
exist; Jira's validation messages confirm the body's field names. No valid
switch, GET /task or delete was recorded, so the stub builds those inline.
