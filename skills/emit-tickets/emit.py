#!/usr/bin/env python3
"""Consume a decision list (decision-list/FORMAT.md) and emit one ticket file
per decision, conforming to SPEC.md at the `full` profile.

Usage: emit.py DECISION_LIST.json --out DIR

Refuses to emit anything if the decision list fails
decision-list/validate.py's schema check, reporting the same field-naming
errors that script would. Stdlib only.
"""
import argparse
import importlib.util
import json
import re
import sys
from pathlib import Path

# Fields this version of the format names. Anything else in a decision
# object is passed through to the ticket's frontmatter unchanged, so a
# producer can carry a reserved field (defer_until, epic) without emit-tickets
# dropping it.
KNOWN_FIELDS = {
    "id", "title", "problem", "solution", "rationale", "out_of_scope",
    "executor", "human_steps", "tags", "blocked_by", "touches", "appends",
    "verify", "verify_fails_today", "created", "updated",
}


def _load_validator():
    """Load decision-list/validate.py as a module, located relative to this
    file rather than the caller's cwd, so emit.py works from any directory."""
    plugin_root = Path(__file__).resolve().parents[2]
    validate_path = plugin_root / "decision-list" / "validate.py"
    spec = importlib.util.spec_from_file_location("decision_list_validate", validate_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _slug(text):
    slug = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return slug or "ticket"


def _yaml_str_list(name, values, indent="  "):
    if not values:
        return f"{name}: []\n"
    lines = [f"{name}:\n"]
    for v in values:
        lines.append(f"{indent}- {v}\n")
    return "".join(lines)


def render_ticket(entry):
    updated = entry.get("updated") or entry["created"]
    lines = [
        "---\n",
        f"id: {entry['id']}\n",
        f"title: {entry['title']}\n",
        f"created: {entry['created']}\n",
        f"updated: {updated}\n",
        f"executor: {entry['executor']}\n",
        _yaml_str_list("tags", entry.get("tags") or []),
        _yaml_str_list("blocked_by", entry.get("blocked_by") or []),
        _yaml_str_list("touches", entry.get("touches") or []),
    ]

    appends = entry.get("appends") or []
    if appends:
        lines.append(_yaml_str_list("appends", appends))

    if entry["executor"] == "mixed":
        lines.append(_yaml_str_list("human_steps", entry.get("human_steps") or []))

    verify_lines = [ln for ln in entry["verify"].splitlines() if ln.strip()]
    lines.append("verify: |\n")
    for ln in verify_lines:
        lines.append(f"  {ln}\n")
    lines.append(f"  # {entry['verify_fails_today']}\n")

    extra = {k: v for k, v in entry.items() if k not in KNOWN_FIELDS}
    for k, v in extra.items():
        if isinstance(v, list):
            lines.append(_yaml_str_list(k, v))
        else:
            lines.append(f"{k}: {v}\n")

    lines.append("---\n\n")
    lines.append("## Problem\n\n")
    lines.append(f"{entry['problem']}\n\n")
    lines.append("## Solution\n\n")
    lines.append(f"{entry['solution']}\n\n")
    lines.append("## Decisions\n\n")
    for item in entry["rationale"]:
        piece = f"**{item['choice']}**"
        rejected = item.get("rejected") or []
        if rejected:
            piece += " Rejected: " + " ".join(rejected)
        lines.append(piece + "\n\n")
    lines.append("## Out of scope\n\n")
    lines.append(f"{entry['out_of_scope']}\n")

    return "".join(lines)


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("decision_list", help="path to a decision-list JSON file")
    parser.add_argument("--out", required=True, help="directory to write ticket files into")
    args = parser.parse_args(argv[1:])

    try:
        with open(args.decision_list, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"emit-tickets: {args.decision_list}: {exc}", file=sys.stderr)
        return 1

    validator = _load_validator()
    errors = validator.validate(data)
    if errors:
        for e in errors:
            print(f"emit-tickets: refusing to emit — decision-list validate: {e}", file=sys.stderr)
        return 1

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    written = []
    for entry in data["decisions"]:
        text = render_ticket(entry)
        path = out_dir / f"{entry['id']}-{_slug(entry['title'])}.md"
        path.write_text(text, encoding="utf-8")
        written.append(str(path))

    for p in written:
        print(f"emit-tickets: wrote {p}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
