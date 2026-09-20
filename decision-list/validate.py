#!/usr/bin/env python3
"""Schema validator for decision-list/FORMAT.md.

Usage: validate.py PATH

Exits 0 and prints a one-line summary when PATH is a well-formed decision
list. Exits 1 and prints one error per line, each naming the offending field,
otherwise. Stdlib only.
"""
import json
import re
import sys

DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
ID_RE = re.compile(r"^\S+$")
EXECUTORS = ("agent", "human", "mixed")

# field -> (required, type check) for a single decision entry. "list[str]"
# fields default to [] when absent unless required=True.
STRING_FIELDS = ("id", "title", "problem", "solution", "out_of_scope", "verify", "verify_fails_today")
LIST_OF_STR_FIELDS = ("tags", "blocked_by", "touches", "appends")


def _err(errors, where, msg):
    errors.append(f"{where}: {msg}")


def _is_list_of_str(value):
    return isinstance(value, list) and all(isinstance(v, str) for v in value)


def validate_decision(entry, where, errors):
    if not isinstance(entry, dict):
        _err(errors, where, "must be an object")
        return

    for field in STRING_FIELDS:
        if field not in entry:
            _err(errors, where, f"missing required field '{field}'")
        elif not isinstance(entry[field], str) or not entry[field].strip():
            _err(errors, where, f"'{field}' must be a non-empty string")

    if "id" in entry and isinstance(entry["id"], str) and not ID_RE.match(entry["id"]):
        _err(errors, where, "'id' must not be empty or contain whitespace")

    for field in ("tags", "blocked_by", "touches"):
        if field not in entry:
            _err(errors, where, f"missing required field '{field}'")
        elif not _is_list_of_str(entry[field]):
            _err(errors, where, f"'{field}' must be a list of strings")

    if "appends" in entry and not _is_list_of_str(entry["appends"]):
        _err(errors, where, "'appends' must be a list of strings")

    overlap = set(entry.get("touches") or []) & set(entry.get("appends") or [])
    if overlap:
        _err(errors, where, f"path(s) {sorted(overlap)} appear in both 'touches' and 'appends'")

    executor = entry.get("executor")
    if "executor" not in entry:
        _err(errors, where, "missing required field 'executor'")
    elif executor not in EXECUTORS:
        _err(errors, where, f"'executor' must be one of {EXECUTORS}, got {executor!r}")

    if executor == "mixed":
        steps = entry.get("human_steps")
        if not _is_list_of_str(steps) or not steps:
            _err(errors, where, "'human_steps' must be a non-empty list of strings when executor is 'mixed'")

    for field in ("created", "updated"):
        if field in entry and not (isinstance(entry[field], str) and DATE_RE.match(entry[field])):
            _err(errors, where, f"'{field}' must be an RFC 3339 full-date (YYYY-MM-DD)")
    if "created" not in entry:
        _err(errors, where, "missing required field 'created'")

    rationale = entry.get("rationale")
    if "rationale" not in entry:
        _err(errors, where, "missing required field 'rationale'")
    elif not isinstance(rationale, list) or not rationale:
        _err(errors, where, "'rationale' must be a non-empty list")
    else:
        for j, item in enumerate(rationale):
            rwhere = f"{where}.rationale[{j}]"
            if not isinstance(item, dict):
                _err(errors, rwhere, "must be an object with 'choice' and 'rejected'")
                continue
            if not isinstance(item.get("choice"), str) or not item["choice"].strip():
                _err(errors, rwhere, "'choice' must be a non-empty string")
            if "rejected" not in item or not _is_list_of_str(item.get("rejected")):
                _err(errors, rwhere, "'rejected' must be a list of strings (may be empty)")


def validate(data):
    errors = []
    if not isinstance(data, dict):
        return ["root: decision list must be a JSON object"]

    if "decision_list_version" not in data or not isinstance(data["decision_list_version"], str):
        errors.append("root: missing required field 'decision_list_version'")

    decisions = data.get("decisions")
    if "decisions" not in data:
        errors.append("root: missing required field 'decisions'")
        return errors
    if not isinstance(decisions, list):
        errors.append("root: 'decisions' must be a list")
        return errors

    seen_ids = {}
    for i, entry in enumerate(decisions):
        where = f"decisions[{i}]"
        validate_decision(entry, where, errors)
        if isinstance(entry, dict) and isinstance(entry.get("id"), str):
            dup = seen_ids.get(entry["id"])
            if dup is not None:
                errors.append(f"{where}: duplicate id '{entry['id']}' also used at decisions[{dup}]")
            else:
                seen_ids[entry["id"]] = i

    return errors


def main(argv):
    if len(argv) != 2:
        print("usage: validate.py PATH", file=sys.stderr)
        return 2
    path = argv[1]
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"decision-list validate: {path}: {exc}", file=sys.stderr)
        return 1

    errors = validate(data)
    if errors:
        for e in errors:
            print(f"decision-list validate: {e}", file=sys.stderr)
        return 1

    print(f"decision-list validate: OK — {len(data.get('decisions', []))} decision(s) valid")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
