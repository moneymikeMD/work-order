#!/usr/bin/env python3
"""A second conformance validator for the file binding, written only from
SPEC.md and bindings/file/BINDING.md.

It exists to test the specification, not the tickets: every place it disagrees
with conformance/validate.py is a place the documents did not say enough.
See DISAGREEMENTS.md beside this file. Deliberately minimal and stdlib-only.

Usage: minimal-validate.py <set-root> [--profile minimal|full|unattended]
Exit 0 when no MUST at the chosen profile is violated, 1 when one is.
"""

import argparse
import fnmatch
import os
import re
import sys

STAGES = ("open", "in-progress", "awaiting-deployment", "completed", "cancelled")
TERMINAL = ("completed", "cancelled")
PROFILES = ("minimal", "full", "unattended")

DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
KEY_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_-]*):(.*)$")
HEADING_RE = re.compile(r"^#{1,6}\s+(.*?)\s*#*\s*$")
BLOCK_SCALAR_RE = re.compile(r"^[|>][+-]?$")

PROBLEM_RE = re.compile(r"problem|the\s+situation|background", re.I)
SOLUTION_RE = re.compile(r"solution|approach|what\s+to\s+(do|build)|the\s+fix", re.I)
BOUNDARY_RE = re.compile(r"out[\s_-]*of[\s_-]*scope|not\s+in\s+scope|boundar", re.I)
PROGRESS_RE = re.compile(r"progress|work\s*log|session\s*log|status\s*update|journal|timeline", re.I)

CONVERSATION_RE = re.compile(
    r"as\s+discussed|as\s+we\s+(agreed|decided|discussed)|see\s+above|"
    r"per\s+our\s+(conversation|call|chat|discussion)|"
    r"in\s+(the|our)\s+(meeting|standup|call|thread)|"
    r"(he|she|they|we)\s+(said|told\s+me|mentioned)|as\s+agreed",
    re.I,
)
DEPLOY_EVIDENCE_RE = re.compile(
    r"systemctl\s+(is-(active|enabled)|status)|"
    r"docker\s+(ps|compose\s+ps)|"
    r"kubectl\s+get\s+pods|"
    r"reports?\s+(itself\s+)?healthy|is\s+healthy|"
    r"the\s+(build|deploy(ment)?)\s+(succeed|pass|is\s+green)|"
    r"(build|deploy(ment)?)\s+succeed|"
    r"unit\s+is\s+(active|running)|service\s+is\s+running|"
    r"exit(s|ed)?\s+0\s+means\s+(it\s+)?deployed",
    re.I,
)
INTERACTIVE_RE = re.compile(
    r"^\s*read\s+-|^\s*read\s+[A-Za-z_][A-Za-z0-9_]*\s*$|"
    r"\bvipe\b|\$EDITOR|\bvim?\b\s|\bnano\b|\bless\b\s|"
    r"paste\s+(it|the|in)|type\s+(it|the|in)\b|"
    r"satisfy\s+yourself|to\s+your\s+satisfaction|judge\s+whether|"
    r"(confirm|check|eyeball|look\s+at|observe|inspect)\s+(that\s+)?(the\s+)?"
    r"(page|screen|dashboard|render|output|graph|browser|by\s+eye)|"
    r"open\s+.*\bin\s+(a\s+)?(the\s+)?browser|"
    r"by\s+hand|manually\s+(confirm|check|verify)|"
    r"prompts?\s+for|when\s+prompted|answer\s+the\s+prompt",
    re.I,
)
UNSETTLED_RE = re.compile(
    r"\bTBD\b|\bTODO\b|\bFIXME\b|\bdecide\s+(later|which|whether|at\s+run)|"
    r"to\s+be\s+(decided|determined)|"
    r"(we|the\s+executor|whoever\s+picks\s+this\s+up)\s+(will|can|should)\s+"
    r"(decide|choose|pick|work\s+out|figure)|"
    r"(pick|choose)\s+(one|either|whichever)|"
    r"open\s+question|still\s+undecided|not\s+yet\s+decided|"
    r"either\s+\S+\s+or\s+\S+\s*[-—]?\s*(whichever|we\s+have\s+not)",
    re.I,
)
VAGUE_LOCATOR_RE = re.compile(
    r"\bthe\s+(usual|existing|other|relevant|appropriate|right|same)\s+"
    r"(place|file|script|directory|repo|repository|one|config|endpoint|doc|document)\b|"
    r"\bthat\s+(file|script|repo|repository|document|doc|config)\b|"
    r"\bsomewhere\s+(in|under)\b|"
    r"\bwherever\s+(it|they|that)\b|"
    r"\b(the|that|a)\s+"
    r"(screenshot|mockup|sketch|attachment|recording|diagram|wireframe|"
    r"whiteboard|slide|deck)\b|"
    r"\b(I|we|you|they|he|she)\s+(sent|shared|attached|showed|posted|emailed)\b|"
    r"\bthe\s+(script|config|helper|module|table|dashboard)\s+we\s+\w+",
    re.I,
)
COMMAND_RE = re.compile(
    r"^\s*(\S*/)?(test|\[|python3?|bash|sh|zsh|grep|rg|curl|jq|git|gh|make|npm|pnpm|yarn|"
    r"node|go|cargo|pytest|diff|cmp|awk|sed|find|ls|cat|head|tail|wc|stat|tar|"
    r"docker|kubectl|systemctl|shellcheck|ruff|mypy|terraform|ansible|psql|sqlite3|"
    r"\./|\S+\.(sh|py|pl|rb)\b)",
    re.I,
)
TAUTOLOGY_RE = re.compile(
    r"^\s*(true|:|exit\s+0)\s*$|"
    r"^\s*echo\b|"
    r"\|\|\s*(true|:|echo\b|exit\s+0)",
)


class Ticket:
    def __init__(self, path, stage, fields, body):
        self.path = path
        self.stage = stage
        self.fields = fields
        self.body = body
        self.tid = fields.get("id") if isinstance(fields.get("id"), str) else None

    def get(self, name):
        return self.fields.get(name)

    def label(self):
        return self.tid or os.path.basename(self.path)


def strip_quotes(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def parse_frontmatter(lines):
    """The four value forms [FILE-13] permits, and nothing else."""
    if not lines or lines[0].rstrip("\n") != "---":
        return None, None
    end = None
    for i in range(1, len(lines)):
        if lines[i].rstrip("\n") == "---":
            end = i
            break
    if end is None:
        return None, None

    fields = {}
    i = 1
    while i < end:
        raw = lines[i].rstrip("\n")
        match = KEY_RE.match(raw)
        if not match:
            i += 1
            continue
        key, rest = match.group(1), match.group(2)
        tail = rest.strip()
        if BLOCK_SCALAR_RE.match(tail):
            i += 1
            collected = []
            while i < end:
                nxt = lines[i].rstrip("\n")
                if nxt.strip() == "":
                    collected.append("")
                    i += 1
                    continue
                if not nxt.startswith("  "):
                    break
                collected.append(nxt[2:])
                i += 1
            fields[key] = "\n".join(collected).strip("\n")
            continue
        if tail == "":
            i += 1
            items = []
            while i < end:
                nxt = lines[i].rstrip("\n")
                if nxt.strip() == "":
                    i += 1
                    continue
                stripped = nxt.strip()
                if nxt.startswith(" ") and stripped.startswith("- "):
                    items.append(strip_quotes(stripped[2:]))
                    i += 1
                    continue
                break
            fields[key] = items
            continue
        if tail.startswith("[") and tail.endswith("]"):
            inner = tail[1:-1].strip()
            fields[key] = [strip_quotes(p) for p in inner.split(",") if p.strip()] if inner else []
            i += 1
            continue
        fields[key] = strip_quotes(tail)
        i += 1
    return fields, "".join(lines[end + 1:])


def load_set(root):
    tickets, errors, stray = [], [], []
    try:
        entries = sorted(os.listdir(root))
    except OSError as exc:
        return [], [f"cannot read set root {root}: {exc}"], []
    for entry in entries:
        full = os.path.join(root, entry)
        if not os.path.isdir(full) or entry.startswith("."):
            continue
        if entry not in STAGES:
            stray.append(entry)
            continue
        for name in sorted(os.listdir(full)):
            fpath = os.path.join(full, name)
            if not os.path.isfile(fpath) or not name.endswith(".md"):
                continue
            if name.endswith(".notes.md"):
                continue
            with open(fpath, encoding="utf-8") as handle:
                lines = handle.readlines()
            fields, body = parse_frontmatter(lines)
            if fields is None:
                errors.append(f"[FILE-11] {os.path.join(entry, name)}: no frontmatter block")
                continue
            tickets.append(Ticket(fpath, entry, fields, body))
    return tickets, errors, stray


def headings(body):
    return [HEADING_RE.match(ln).group(1) for ln in body.splitlines() if HEADING_RE.match(ln)]


def as_list(value):
    if value is None:
        return None
    return value if isinstance(value, list) else None


def normalise(path):
    return path.strip().rstrip("/")


def paths_overlap(a, b):
    a, b = normalise(a), normalise(b)
    if not a or not b:
        return False
    if a == b:
        return True
    if fnmatch.fnmatch(a, b) or fnmatch.fnmatch(b, a):
        return True
    for wide, other in ((a, b), (b, a)):
        if wide.endswith("/**") and other.startswith(wide[:-2]):
            return True
        if wide.endswith("*") and other.startswith(wide[:-1]):
            return True
    return False


def profile_at_least(requirement_profile, chosen):
    return PROFILES.index(requirement_profile) <= PROFILES.index(chosen)


class Report:
    def __init__(self, profile):
        self.profile = profile
        self.errors = []
        self.warnings = []

    def must(self, number, req_profile, condition, where, message):
        """Record a MUST violation when `condition` is true at this profile."""
        if condition and profile_at_least(req_profile, self.profile):
            self.errors.append(f"[MUST-{number}] {where}: {message}")

    def should(self, number, req_profile, condition, where, message):
        if condition and profile_at_least(req_profile, self.profile):
            self.warnings.append(f"[SHOULD-{number}] {where}: {message}")


def check_conformance_claim(root, report):
    """MUST-40, under the only reading that makes the shipped fixture a
    violation: the claim must be well formed AND true at the profile it names.
    Neither SPEC.md nor BINDING.md states where a claim lives; see
    DISAGREEMENTS.md, D-1."""
    claim_path = None
    for candidate in ("CONFORMANCE", "CONFORMANCE.md", "CONFORMANCE.txt"):
        full = os.path.join(root, candidate)
        if os.path.isfile(full):
            claim_path = full
            break
    if claim_path is None:
        return
    with open(claim_path, encoding="utf-8") as handle:
        text = handle.read()
    named = [p for p in PROFILES if re.search(rf"\b{p}\b", text)]
    has_version = bool(re.search(r"\b\d+\.\d+(\.\d+)?\b", text))
    where = os.path.basename(claim_path)
    report.must(
        40, "minimal", not has_version, where,
        "a conformance claim must cite the specification's MAJOR and MINOR version",
    )
    report.must(
        40, "minimal", len(named) != 1, where,
        f"a conformance claim must name exactly one profile, found {len(named)}: {named or 'none'}",
    )
    if has_version and len(named) == 1:
        claimed = validate(root, named[0])
        report.must(
            40, "minimal", bool(claimed.errors), where,
            f"the set does not conform at the claimed profile `{named[0]}`: "
            f"{len(claimed.errors)} error(s), first is {claimed.errors[0]}",
        )


def check_ticket(ticket, report, by_id, startable_ids):
    where = f"{ticket.stage}/{os.path.basename(ticket.path)}"
    fields, body = ticket.fields, ticket.body
    cancelled = ticket.stage == "cancelled"

    report.must(1, "minimal", not ticket.tid, where, "no `id`")
    report.must(3, "minimal", not fields.get("title"), where, "no `title`")

    for name in ("created", "updated"):
        value = fields.get(name)
        report.must(
            4, "minimal",
            not isinstance(value, str) or not DATE_RE.match(value or ""),
            where, f"`{name}` is not an RFC 3339 full-date: {value!r}",
        )

    tags = fields.get("tags")
    report.must(
        6, "full", "tags" not in fields or as_list(tags) is None, where,
        f"`tags` must be a flat list, got {tags!r}",
    )
    report.must(
        6, "full",
        as_list(tags) is not None and any(not isinstance(t, str) for t in tags),
        where, "`tags` must contain only strings",
    )

    verify = fields.get("verify")
    report.must(7, "minimal", not cancelled and not verify, where, "no `verify`")

    if isinstance(verify, str) and verify.strip():
        vlines = [ln for ln in verify.splitlines() if ln.strip()]
        effective = [ln for ln in vlines if not ln.lstrip().startswith("#")]
        report.must(
            8, "minimal", not any(COMMAND_RE.match(ln) for ln in vlines), where,
            "`verify` states no command, only prose",
        )
        report.must(
            9, "minimal",
            bool(effective) and all(TAUTOLOGY_RE.search(ln) for ln in effective), where,
            "`verify` cannot fail: every command swallows its own exit status",
        )
        report.must(
            10, "minimal",
            not re.search(r"\btoday\b|\bright now\b|\bat the base\b|\bcurrently\b|"
                          r"\bbefore this ticket\b|\bdoes not exist\b|\bnot yet\b",
                          verify, re.I),
            where, "`verify` records no observation that fails at the base state",
        )
        report.must(
            11, "minimal", bool(DEPLOY_EVIDENCE_RE.search(verify)), where,
            "`verify` accepts deployment, a build, or a healthy report as evidence",
        )
        report.must(
            35, "unattended", bool(INTERACTIVE_RE.search(verify)), where,
            "`verify` needs interaction: a prompt, a typed value, or a human observation",
        )

    executor = fields.get("executor")
    report.must(
        22, "full", executor not in ("agent", "human", "mixed"), where,
        f"`executor` must be exactly agent, human or mixed, got {executor!r}",
    )
    report.must(
        23, "full", executor == "mixed" and not fields.get("human_steps"), where,
        "`executor: mixed` without `human_steps`",
    )
    report.must(
        24, "full", executor == "agent" and bool(fields.get("human_steps")), where,
        "`executor: agent` but the ticket enumerates `human_steps`, so it needs a person",
    )
    report.must(34, "unattended", executor != "agent", where,
                f"the unattended profile requires `executor: agent`, got {executor!r}")

    touches = as_list(fields.get("touches"))
    appends = as_list(fields.get("appends")) or []
    if executor in ("agent", "mixed"):
        report.must(13, "full", touches is None, where, "`agent`/`mixed` ticket declares no `touches`")
    for path in touches or []:
        report.must(
            14, "full", path.startswith("/") or path.startswith("~"), where,
            f"`touches` path is not relative to the set's root: {path}",
        )
    for path in appends:
        report.must(
            14, "full", path.startswith("/") or path.startswith("~"), where,
            f"`appends` path is not relative to the set's root: {path}",
        )
    shared = {normalise(p) for p in (touches or [])} & {normalise(p) for p in appends}
    report.must(
        17, "full", bool(shared), where,
        f"path in both `touches` and `appends`: {sorted(shared)}",
    )

    blocked_by = as_list(fields.get("blocked_by"))
    report.must(18, "full", "blocked_by" not in fields or blocked_by is None, where,
                "`blocked_by` must be a list, which may be empty")
    for dep in blocked_by or []:
        report.must(19, "full", dep not in by_id, where, f"`blocked_by` names no ticket in the set: {dep}")
    report.must(20, "full", ticket.tid is not None and ticket.tid in (blocked_by or []),
                where, "a ticket may not block itself")

    report.must(26, "minimal", "status" in fields, where,
                "a `status` field restates the position the stage directory already carries")
    report.must(28, "minimal", cancelled and not fields.get("outcome"), where,
                "a cancelled ticket carries no `outcome`")

    defer = fields.get("defer_until")
    report.must(
        39, "minimal",
        defer is not None and (not isinstance(defer, str) or not DATE_RE.match(defer)),
        where, f"`defer_until` must be an RFC 3339 full-date, got {defer!r}",
    )

    heads = headings(body)
    report.must(30, "minimal", not any(PROBLEM_RE.search(h) for h in heads), where,
                "the body states no problem")
    report.must(30, "minimal", not any(SOLUTION_RE.search(h) for h in heads), where,
                "the body states no solution")
    report.must(31, "full", not any(BOUNDARY_RE.search(h) for h in heads), where,
                "the body names no out-of-scope boundary")
    report.must(
        33, "full",
        any(PROGRESS_RE.search(h) or DATE_RE.match(h.strip()) for h in heads), where,
        "progress narration belongs in <id>.notes.md, not the body",
    )

    report.must(36, "unattended", bool(CONVERSATION_RE.search(body)), where,
                "the body cites a conversation, a message or a person as its source")
    report.must(37, "unattended", bool(VAGUE_LOCATOR_RE.search(body)), where,
                "an artefact is named by something other than a resolvable locator")
    report.must(38, "unattended", bool(UNSETTLED_RE.search(body)), where,
                "a choice the solution depends on is left unsettled")

    report.should(1, "minimal", bool(ticket.tid) and not re.match(r"^[A-Za-z][A-Za-z0-9]*-\d+$", ticket.tid),
                  where, "an id should take the form PREFIX-NNN")
    report.should(7, "full", executor in ("agent", "mixed") and touches == [],
                  where, "an empty `touches` should name what the ticket changes elsewhere")
    report.should(11, "minimal", len(body.splitlines()) > 200, where,
                  "a ticket should be short enough to read before starting it")


def validate(root, profile):
    """Every check except the conformance claim, which re-enters this."""
    report = Report(profile)
    tickets, load_errors, stray = load_set(root)
    report.errors.extend(load_errors)

    for name in stray:
        report.must(25, "minimal", True, name + "/",
                    "not one of the five lifecycle positions")

    by_id, duplicates = {}, set()
    for ticket in tickets:
        if ticket.tid is None:
            continue
        if ticket.tid in by_id:
            duplicates.add(ticket.tid)
        else:
            by_id[ticket.tid] = ticket
    for dup in sorted(duplicates):
        report.must(1, "minimal", True, dup, "the same id appears on more than one ticket")

    startable = []
    for ticket in tickets:
        if ticket.stage != "open":
            continue
        deps = as_list(ticket.fields.get("blocked_by")) or []
        if all(dep in by_id and by_id[dep].stage in TERMINAL for dep in deps):
            startable.append(ticket)
    startable_ids = {t.tid for t in startable}

    for ticket in tickets:
        check_ticket(ticket, report, by_id, startable_ids)

    for i, left in enumerate(startable):
        for right in startable[i + 1:]:
            lt = as_list(left.fields.get("touches")) or []
            rt = as_list(right.fields.get("touches")) or []
            clash = sorted({f"{a} ~ {b}" for a in lt for b in rt if paths_overlap(a, b)})
            report.must(
                15, "full", bool(clash),
                f"{left.label()} + {right.label()}",
                f"two simultaneously startable tickets own the same path: {clash}",
            )
            la = as_list(left.fields.get("appends")) or []
            ra = as_list(right.fields.get("appends")) or []
            if any(paths_overlap(a, b) for a in la for b in ra):
                report.should(0, "full", False, "", "")
                report.warnings.append(
                    f"[MUST-16] {left.label()} + {right.label()}: shared `appends` path (warning, not blocking)"
                )

    return report


def check_set(root, profile):
    report = validate(root, profile)
    check_conformance_claim(root, report)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root")
    parser.add_argument("--profile", choices=PROFILES, default="unattended")
    args = parser.parse_args()

    if not os.path.isdir(args.root):
        print(f"minimal-validate: not a directory: {args.root}", file=sys.stderr)
        return 2

    report = check_set(args.root, args.profile)
    for warning in report.warnings:
        print(f"warning  {warning}")
    for error in report.errors:
        print(f"ERROR    {error}")
    print(
        f"{args.root}: {len(report.errors)} error(s), {len(report.warnings)} warning(s) "
        f"at profile `{args.profile}`"
    )
    return 1 if report.errors else 0


if __name__ == "__main__":
    sys.exit(main())
