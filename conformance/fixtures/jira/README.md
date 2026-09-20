# Jira fixtures

`validate.py --source jira --fixture <one of these directories>` reads a ticket
set through the [Jira binding](../../../plugins/work-order-jira/BINDING.md)
instead of the file binding.

**The input is always a directory of recorded responses, never a live site.** A
conformance check that needs a credential cannot run in anyone's CI, and this
repository is public. An adopter records their own project's responses once and
checks them as often as they like.

## What a fixture directory holds

| File | Is | Needed |
| --- | --- | --- |
| `search.jql.json` | the body of `GET /rest/api/3/search/jql` — `{"issues": [...]}` | yes |
| `field.list.json` | the body of `GET /rest/api/3/field` | no |
| `project.json` | the body of `GET /rest/api/3/project/<KEY>` | no |

Any `.json` file other than the two named ones is read as another page of
search results, so a paginated fetch can be recorded page by page.

`field.list.json` is how custom field ids resolve **by name**, per `[JIRA-8]`:
the ids in these fixtures are `customfield_110NN`, deliberately not the ones
`reference/issues.py` carries, because a field id copied from one site is a
wrong field on the next. Without it the reference implementation's ids are the
fallback, and `outcome` — which has no id there — reads as absent.

`project.json` carries the conformance claim, per `[JIRA-9]`: a Space states it
in the project description. A directory with a `CONFORMANCE` file is read too,
which is what an exporter that writes one produces.

## Recording your own

```
jira-api.sh raw GET '/search/jql?jql=project%20%3D%20LAB&fields=summary,status,labels,issuelinks,created,updated,description,customfield_10043,...' > search.jql.json
jira-api.sh raw GET /field                                                     > field.list.json
jira-api.sh raw GET /project/LAB                                               > project.json
```

`description` is the field to remember: it carries the ticket body, and six of
the specification's MUSTs are checks on body text. `reference/issues.py` does
not ask for it, because its own checks never read a body.

Scrub the site's hostname, account ids and email addresses before committing a
recording. The issues here are **authored** to the shape of the responses
recorded in `plugins/work-order-jira/fixtures/`, not captured from a live site;
they carry no `self` links for the same reason.

## The sets

| Directory | Is |
| --- | --- |
| `conforming/` | the six tickets of `fixtures/conforming/`, as Jira issues; passes at all three profiles |
| `violates-MUST-25-unmapped-status/` | one issue in `Build Broken`, a status with no lifecycle position (`[JIRA-3]`) |
| `violates-MUST-31-no-boundary/` | one issue whose description has no out-of-scope heading |
| `violates-MUST-40-claim-mismatch/` | a project description claiming a profile the set was not validated at |

`violates-MUST-31-no-boundary/` is the one that matters most. It can only fail
if the ADF description survived the conversion into a body with its heading
markers intact — the thing `jira_issue_to_ticket()` alone does not do.
