#!/usr/bin/env python3
"""Read a ticket set from recorded Jira API responses, in the shape
validate.py's checks already expect.

The field mapping is not written twice: reference/issues.py already carries a
live-proven `--source jira` reader (the custom fields, the status map, the
`/search/jql` response shape), and this module normalises a site's field ids
onto that reader's constants and then calls its `jira_issue_to_ticket()`.

What it adds is the body. `jira_issue_to_ticket()` sets `_body` to the empty
string, because issues.py's own checks never read it — and six of the
specification's MUSTs are checks on a ticket's body text, so an adapter that
discards the body cannot feed this validator. `fields.description` is an
Atlassian Document Format tree; `adf_to_markdown()` below renders it with its
heading markers intact, which is what the body checks match against.

Nothing here reaches a network or reads a credential. The input is a directory
of recorded responses, which is the only shape an adopter can run in CI.
See conformance/fixtures/jira/README.md for the layout.
"""
import json
import sys
from pathlib import Path

_issues = None


def _reference():
    """Import reference/issues.py, the one place the Jira field mapping
    lives."""
    global _issues
    if _issues is None:
        ref = Path(__file__).resolve().parent.parent / "reference"
        if str(ref) not in sys.path:
            sys.path.insert(0, str(ref))
        import issues
        _issues = issues
    return _issues


def adf_to_markdown(node):
    """Render an Atlassian Document Format node as Markdown, keeping heading
    levels and code fences. issues.py's `_adf_text()` deliberately strips
    heading markers, which the body checks need."""
    if node is None:
        return ""
    if isinstance(node, str):
        return node
    if not isinstance(node, dict):
        return str(node)
    kind = node.get("type")
    content = node.get("content") or []
    if kind == "text":
        return node.get("text", "")
    if kind == "hardBreak":
        return "\n"
    if kind == "heading":
        level = (node.get("attrs") or {}).get("level", 2)
        return "#" * level + " " + "".join(adf_to_markdown(c) for c in content)
    if kind == "codeBlock":
        return "```\n" + "".join(adf_to_markdown(c) for c in content).rstrip("\n") + "\n```"
    if kind in ("bulletList", "orderedList"):
        return "\n".join(
            "- " + "".join(adf_to_markdown(c) for c in (item.get("content") or [])).strip()
            for item in content
        )
    if kind == "doc":
        blocks = [adf_to_markdown(b) for b in content]
        return "\n\n".join(b for b in blocks if b.strip())
    return "".join(adf_to_markdown(c) for c in content)


class FixtureError(Exception):
    """A fixture directory this module cannot read as a Jira ticket set."""


def _read_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise FixtureError(f"could not read {path}: {exc}")
    except json.JSONDecodeError as exc:
        raise FixtureError(f"{path} is not valid JSON: {exc}")


def resolve_field_ids(field_list):
    """Map each field this binding defines to the id it has on the recorded
    site, resolving by name per [JIRA-8]. Names absent from the listing keep
    the reference implementation's id, which is a fallback and not a default —
    a field id copied from one site is a wrong field on the next."""
    issues = _reference()
    ids = {
        "touches": issues.JIRA_FIELD_TOUCHES,
        "verify": issues.JIRA_FIELD_VERIFY,
        "human_steps": issues.JIRA_FIELD_HUMAN_STEPS,
        "appends": issues.JIRA_FIELD_APPENDS,
        "executor": issues.JIRA_FIELD_EXECUTOR,
        "defer_until": issues.JIRA_FIELD_DEFER_UNTIL,
        "outcome": None,
    }
    for entry in field_list or []:
        if not isinstance(entry, dict):
            continue
        name = (entry.get("name") or "").strip()
        if name in ids and entry.get("id"):
            ids[name] = entry["id"]
    return ids


def _canonical_ids():
    issues = _reference()
    return {
        "touches": issues.JIRA_FIELD_TOUCHES,
        "verify": issues.JIRA_FIELD_VERIFY,
        "human_steps": issues.JIRA_FIELD_HUMAN_STEPS,
        "appends": issues.JIRA_FIELD_APPENDS,
        "executor": issues.JIRA_FIELD_EXECUTOR,
        "defer_until": issues.JIRA_FIELD_DEFER_UNTIL,
    }


def _normalised_fields(issue, ids):
    fields = dict(issue.get("fields") or {})
    for name, canonical in _canonical_ids().items():
        site_id = ids.get(name)
        if site_id and site_id != canonical and site_id in fields:
            fields[canonical] = fields.pop(site_id)
    return fields


def _present(ticket, fields, raw_outcome):
    names = set()
    for name in ("id", "title", "created", "updated"):
        if ticket.get(name):
            names.add(name)
    # Jira returns labels and issuelinks as arrays whenever they are asked
    # for, so absent and empty are the same state here ([MUST-6], [MUST-18]).
    if "labels" in fields:
        names.add("tags")
    if "issuelinks" in fields:
        names.add("blocked_by")
    for name in ("touches", "appends", "human_steps", "verify", "executor", "epic"):
        if ticket.get(name):
            names.add(name)
    if ticket.get("defer_until") is not None:
        names.add("defer_until")
    if raw_outcome:
        names.add("outcome")
    return names


def issue_to_ticket(issue, ids):
    """One recorded Jira issue as the dict shape validate.py's checks read."""
    issues = _reference()
    fields = _normalised_fields(issue, ids)
    ticket = issues.jira_issue_to_ticket({"key": issue.get("key"), "fields": fields})
    ticket["_body"] = adf_to_markdown(fields.get("description"))
    outcome_id = ids.get("outcome")
    raw_outcome = fields.get(outcome_id) if outcome_id else None
    ticket["outcome"] = issues._adf_text(raw_outcome).strip()
    epic = ticket.get("epic")
    if isinstance(epic, dict):
        ticket["epic"] = epic.get("key")
    ticket.pop("_is_epic", None)
    ticket["_where"] = ticket.get("id") or "(an issue with no key)"
    ticket["_fields"] = _present(ticket, fields, raw_outcome)
    return ticket


def _pages(root):
    reserved = {"field.list.json", "project.json"}
    if root.is_file():
        return [_read_json(root)]
    if not root.is_dir():
        raise FixtureError(f"not a directory: {root}")
    out = []
    for path in sorted(root.glob("*.json")):
        if path.name in reserved:
            continue
        out.append(_read_json(path))
    if not out:
        raise FixtureError(
            f"{root} holds no recorded search response — expected a JSON file "
            "with an 'issues' array (the body of GET /rest/api/3/search/jql)"
        )
    return out


def load_jira_set(root, stages):
    """Read a recorded Jira set from ROOT. Returns (tickets, strays, layout,
    claim_text, claim_source): a ticket per issue in a mapped lifecycle
    position, and a stray per issue in any other status, per [JIRA-3]."""
    root = Path(root)
    listing = root / "field.list.json" if root.is_dir() else None
    ids = resolve_field_ids(_read_json(listing) if listing and listing.is_file() else None)
    status_to_stage = {
        status: stage
        for status, stage in _reference().JIRA_STATUS_TO_STAGE.items()
        if stage in stages
    }

    tickets, strays, seen = [], [], set()
    for page in _pages(root):
        if not isinstance(page, dict) or page.get("issues") is None:
            raise FixtureError(
                "a recorded response has no 'issues' array — this is not the "
                "body of a GET /rest/api/3/search/jql call"
            )
        for issue in page["issues"]:
            key = issue.get("key") or "(an issue with no key)"
            if key in seen:
                continue
            seen.add(key)
            status = ((issue.get("fields") or {}).get("status") or {}).get("name", "")
            stage = status_to_stage.get(status)
            if stage is None:
                strays.append((key, f"status '{status or '(none)'}' is not one of the "
                                    "five lifecycle positions, so the ticket has none ([JIRA-3])"))
                continue
            ticket = issue_to_ticket(issue, ids)
            ticket["_stage"] = stage
            tickets.append(ticket)

    if not tickets:
        raise FixtureError(f"no tickets found in {root}")

    claim_text, claim_source = "", ""
    project = root / "project.json" if root.is_dir() else None
    if project is not None and project.is_file():
        claim_text = adf_to_markdown((_read_json(project) or {}).get("description"))
        claim_source = "the project description"
    return tickets, strays, "jira", claim_text, claim_source
