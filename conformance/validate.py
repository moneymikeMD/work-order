#!/usr/bin/env python3
"""Conformance validator for SPEC.md: does a ticket set satisfy the numbered
requirements at a declared profile?

    validate.py --profile minimal|full|unattended SET_DIR
    validate.py --selftest

SET_DIR is a ticket set in the file binding (bindings/file/BINDING.md): one
stage directory per lifecycle position, tickets as Markdown files with
frontmatter. A directory holding ticket files and no stage directories at all
is read as a flat set of `open` tickets, which is what a generator writing
fresh tickets into an output directory produces.

Profile membership is computed from SPEC.md itself — each requirement carries
one inline token naming the lowest profile it applies at, and the profiles
nest — so this program has no second copy of the membership to drift out of
step with the document.

Only MUST failures gate: exit 1 when a MUST in the profile is violated, 0
otherwise, 2 on a usage or setup error. SHOULD findings are reported and never
gate, which is what lets a set adopt the specification incrementally.

Stdlib only, and the frontmatter parser is hand-rolled, so this runs anywhere
python3 does. See conformance/README.md.
"""
import argparse
import re
import sys
from datetime import date
from fnmatch import fnmatch
from pathlib import Path

STAGES = ("open", "in-progress", "awaiting-deployment", "completed", "cancelled")
TERMINAL = ("completed", "cancelled")
PROFILES = ("minimal", "full", "unattended")
EXECUTORS = ("agent", "human", "mixed")

REQ_RE = re.compile(r"^\[(MUST|SHOULD)-(\d+)\] `(minimal|full|unattended)`")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
ID_FORM_RE = re.compile(r"^[A-Za-z][A-Za-z0-9]*-\d+$")
KEY_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_-]*):\s*(.*)$")

# Statuses other than pass/FAIL/report. Each says why a requirement is not
# something this program can decide, so a reader is never left guessing
# whether silence means checked or skipped.
NOT_CHECKABLE = "not-checkable"
IMPLEMENTATION = "implementation"
DOCUMENT = "document"
UNCHECKED = "UNCHECKED"

COMMANDS = set("""
test grep egrep ls cat tac curl wget python python3 pytest make npm npx node git jq yq
diff docker podman systemctl systemd-analyze journalctl ssh scp bash sh zsh awk sed head
tail wc find sort uniq tr cut printf echo true false kubectl helm terraform psql mysql
redis-cli gh pip pip3 go cargo rustc rg mvn gradle ansible shellcheck yamllint ruff mypy
tox dig nc openssl stat readlink shasum md5sum sha256sum tar unzip mkdir rm mv cp chmod
chown env xargs seq date uname id whoami timeout tee column base64 pgrep pkill lsof
""".split())

META_RE = re.compile(r"(\|\||&&|[|;<>]|\$\(|`|^\S+=\S)")
ARGISH_RE = re.compile(r"(\s-{1,2}\w|[/*]|\.\w{1,4}\b)")
FIRST_TOKEN_RE = re.compile(r"^[a-z_./~][A-Za-z0-9_./~-]*$")

CANNOT_FAIL_RE = re.compile(r"\|\|\s*(echo|printf|true|:)\b|\|\|\s*exit\s+0\b|;\s*true\s*$")
OR_ECHO_RE = re.compile(r"\|\|\s*(echo|printf)(\s|$)")
GREP_ERE_RE = re.compile(r"\bgrep\b[^|;&]*(-\w*E\w*|--extended-regexp)")

BASE_STATE_RE = re.compile(
    r"\b(today|currently|right now|at the base|before the work|before this"
    r"|pre-work|does not exist|doesn't exist|is absent|are absent|is missing"
    r"|are missing|has no|have no|not yet|no such|returns 404|exits non-zero"
    r"|fails now|not accepted|unknown flag|no matches)\b",
    re.I,
)

DEPLOY_EVIDENCE_RE = re.compile(
    r"(systemctl\s+(--\S+\s+)?(is-active|is-enabled|status|show)"
    r"|docker\s+(ps|inspect)|docker\s+compose\s+(ps|up)|kubectl\s+get\s+pods?"
    r"|curl[^|]*/(health|healthz|readyz|ready)\b"
    r"|\b(is|reports?|reported)\s+healthy\b"
    r"|\bdeploy(ed|ment)?\s+(succeeded|was\s+green|is\s+green|completed)"
    r"|\bbuild\s+(succeeded|passed|is\s+green)\b"
    r"|\bgh\s+run\s+(view|list)\b"
    r"|\bthe\s+(service|container|unit|pod|process)\s+(started|is\s+up|is\s+running)\b)",
    re.I,
)

INTERACTIVE_RE = re.compile(
    r"\b(read -p|you will be prompted|will prompt|type the|type in the|enter the"
    r"|paste the|paste it|click|approve (it|the|on)|confirm in|in the browser"
    r"|one-time code|2fa|observe|look at|by eye|visually|on screen|on-screen)\b",
    re.I,
)

OBSERVATION_RE = re.compile(
    r"\b(observe|look at|by eye|visually|on screen|on-screen|renders|physical"
    r"|the LED|indicator|by hand, that)\b",
    re.I,
)

CONVERSATION_RE = re.compile(
    r"\b(as discussed|as we discussed|as we agreed|as agreed|as previously agreed"
    r"|see above|as above|per our conversation|in our conversation|we talked about"
    r"|in the meeting|on the call|in the thread|in standup|as mentioned earlier"
    r"|as you said|as I said|ask (me|him|her|them) (about|for))\b",
    re.I,
)

UNRESOLVABLE_RE = re.compile(
    r"\b(attached|the attachment|the screenshot I sent|the screenshot I shared"
    r"|the link I sent|the file I pasted|the doc I shared|the paste I sent"
    r"|see the screenshot|the usual place|you know the one)\b",
    re.I,
)

UNSETTLED_RE = re.compile(
    r"(\bTBD\b|\bTODO\b|\bto be decided\b|\bto be determined\b|\bdecide later\b"
    r"|\bwe need to decide\b|\bsomeone needs to decide\b|\bopen question\b"
    r"|\bstill deciding\b|\bnot sure (whether|which|if)\b|\bpick one\b)",
    re.I,
)

EXTERNAL_LOG_RE = re.compile(
    r"\b(see the decision log|in the decision log|the decision record"
    r"|docs/decisions|memory-?graph|the wave plan|see the handoff"
    r"|the session summary|recorded elsewhere)\b",
    re.I,
)

SECRET_RE = re.compile(r"\b(password|passphrase|token|secret|api key|credential|private key)\b", re.I)

PROGRESS_RE = re.compile(
    r"^#{1,6}\s*(\d{4}-\d{2}-\d{2}|progress|status update|work log|session (log|notes)"
    r"|update \d{4}-|log\b)",
    re.I | re.M,
)
PROGRESS_BOLD_RE = re.compile(r"^\*\*\d{4}-\d{2}-\d{2}\*\*", re.M)
CLAIM_RE = re.compile(
    r"work-order\s+SPEC\.md\s+(\d+)\.(\d+)(?:\.\d+)?\s+profile\s+[`'\"]?([a-z]+)", re.I
)


def die(msg):
    print(f"conformance validate: {msg}", file=sys.stderr)
    sys.exit(2)


def parse_frontmatter(text):
    """Return (fields, body) for the four value forms bindings/file/BINDING.md
    FILE-13 admits: scalar, inline list, block list, block scalar."""
    lines = text.split("\n")
    if not lines or lines[0] != "---":
        return None, text
    end = None
    for i in range(1, len(lines)):
        if lines[i] == "---":
            end = i
            break
    if end is None:
        return None, text

    data, body = {}, "\n".join(lines[end + 1:])
    key, mode, buf = None, None, []

    def flush():
        if key is None:
            return
        if mode == "block":
            data[key] = "\n".join(buf).strip()
        elif mode == "list":
            data[key] = [x for x in buf if x]

    for line in lines[1:end]:
        if mode == "block" and (line.startswith("  ") or not line.strip()):
            buf.append(line[2:] if line.startswith("  ") else "")
            continue
        if mode == "list" and line.strip().startswith("- "):
            buf.append(line.strip()[2:].strip())
            continue
        flush()
        key, mode, buf = None, None, []
        if not line.strip() or line.strip().startswith("#"):
            continue
        m = KEY_RE.match(line)
        if not m:
            continue
        k, v = m.group(1), m.group(2).strip()
        if v in ("|", "|-", ">", ">-"):
            key, mode, buf = k, "block", []
        elif v == "":
            key, mode, buf = k, "list", []
            data[k] = []
        elif v.startswith("[") and v.endswith("]"):
            data[k] = [x.strip() for x in v[1:-1].split(",") if x.strip()]
        else:
            data[k] = v.strip().strip('"').strip("'")
    flush()
    return data, body


class Requirement:
    def __init__(self, kind, num, profile):
        self.kind = kind
        self.num = num
        self.profile = profile
        self.key = f"{kind}-{num}"

    def in_profile(self, profile):
        return PROFILES.index(self.profile) <= PROFILES.index(profile)


def parse_spec(path):
    """Return the requirement inventory SPEC.md declares, in document order."""
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        die(f"cannot read the specification: {exc}")
    reqs, seen = [], {}
    for line in text.split("\n"):
        m = REQ_RE.match(line)
        if not m:
            continue
        req = Requirement(m.group(1), int(m.group(2)), m.group(3))
        if req.key in seen:
            die(f"{path}: duplicate requirement identifier {req.key}")
        seen[req.key] = True
        reqs.append(req)
    if not reqs:
        die(f"{path}: no numbered requirements found — is this SPEC.md?")
    return reqs


def spec_version(path):
    try:
        raw = path.read_text(encoding="utf-8").strip()
    except OSError as exc:
        die(f"cannot read VERSION-spec: {exc}")
    parts = raw.split(".")
    if len(parts) < 2:
        die(f"VERSION-spec is not MAJOR.MINOR.PATCH: {raw!r}")
    return raw, f"{parts[0]}.{parts[1]}"


def _is_ticket(path):
    try:
        fields, _ = parse_frontmatter(path.read_text(encoding="utf-8"))
    except OSError:
        return False
    return bool(fields) and "id" in fields


def _read_ticket(path, stage, root):
    fields, body = parse_frontmatter(path.read_text(encoding="utf-8"))
    if fields is None:
        fields = {}
    t = dict(fields)
    t["_fields"] = set(fields)
    t["_body"] = body
    t["_stage"] = stage
    t["_path"] = path
    try:
        t["_where"] = str(path.relative_to(root))
    except ValueError:
        t["_where"] = str(path)
    return t


def load_set(root):
    """Read a ticket set from ROOT. Returns (tickets, strays, layout)."""
    if not root.is_dir():
        die(f"not a directory: {root}")
    present = [s for s in STAGES if (root / s).is_dir()]
    tickets, strays = [], []

    if present:
        for stage in present:
            for path in sorted((root / stage).glob("*.md")):
                if path.name.endswith(".notes.md"):
                    continue
                tickets.append(_read_ticket(path, stage, root))
        for path in sorted(root.glob("*.md")):
            if _is_ticket(path):
                strays.append((path.name, "sits at the set root, outside every stage directory"))
        for sub in sorted(p for p in root.iterdir() if p.is_dir()):
            if sub.name in STAGES or sub.name.startswith("."):
                continue
            for path in sorted(sub.rglob("*.md")):
                if not path.name.endswith(".notes.md") and _is_ticket(path):
                    rel = path.relative_to(root)
                    strays.append((str(rel), f"'{sub.name}/' is not one of the five stage directories"))
        for stage in present:
            for path in sorted((root / stage).rglob("*.md")):
                if path.parent != root / stage and _is_ticket(path):
                    strays.append((str(path.relative_to(root)), "nested below its stage directory"))
        layout = "staged"
    else:
        for path in sorted(root.glob("*.md")):
            if path.name.endswith(".notes.md") or not _is_ticket(path):
                continue
            tickets.append(_read_ticket(path, "open", root))
        layout = "flat"

    if not tickets:
        die(f"no tickets found in {root}")
    return tickets, strays, layout


def read_claim(root):
    """Return (major_minor, profile, source) for the set's written conformance
    claim, or None when it makes none on disk."""
    for name in ("CONFORMANCE", "CONFORMANCE.txt", "README.md"):
        path = root / name
        if not path.is_file():
            continue
        m = CLAIM_RE.search(path.read_text(encoding="utf-8"))
        if m:
            return f"{m.group(1)}.{m.group(2)}", m.group(3).lower(), name
    return None


def _lines(value):
    return [ln for ln in (value or "").split("\n") if ln.strip()]


def _strip_quotes(line):
    return re.sub(r"'[^']*'", "", re.sub(r'"[^"]*"', "", line))


def is_command(line):
    """True when a verify line reads as a command rather than as prose."""
    s = line.strip()
    if not s or s.startswith("#"):
        return False
    if META_RE.search(s):
        return True
    tokens = s.split()
    if tokens[0] in COMMANDS:
        return True
    return bool(
        FIRST_TOKEN_RE.match(tokens[0]) and len(tokens) > 1 and ARGISH_RE.search(s)
    )


def verify_commands(t):
    return [ln for ln in _lines(t.get("verify")) if is_command(ln)]


def verify_assertions(t):
    cmds = verify_commands(t)
    return cmds or [ln for ln in _lines(t.get("verify")) if not ln.strip().startswith("#")]


def as_list(value):
    return value if isinstance(value, list) else None


def paths_of(t, field):
    return as_list(t.get(field)) or []


def overlap(a, b):
    return a == b or fnmatch(a, b) or fnmatch(b, a)


def shared_paths(a, b, field="touches"):
    return sorted({x for x in paths_of(a, field) for y in paths_of(b, field) if overlap(x, y)})


def parse_iso(value):
    if not isinstance(value, str) or not DATE_RE.match(value):
        return None
    try:
        return date.fromisoformat(value)
    except ValueError:
        return None


def is_startable(t, by_id, today):
    if t["_stage"] != "open":
        return False
    defer = t.get("defer_until")
    if isinstance(defer, str) and defer:
        when = parse_iso(defer)
        if when and when > today:
            return False
    for dep in paths_of(t, "blocked_by"):
        other = by_id.get(dep)
        if other is None or other["_stage"] not in TERMINAL:
            return False
    return True


class Context:
    def __init__(self, tickets, strays, layout, root, profile, claim, version_mm):
        self.tickets = tickets
        self.strays = strays
        self.layout = layout
        self.root = root
        self.profile = profile
        self.claim = claim
        self.version_mm = version_mm
        self.by_id = {}
        for t in tickets:
            tid = t.get("id")
            if isinstance(tid, str) and tid and tid not in self.by_id:
                self.by_id[tid] = t
        today = date.today()
        self.startable = [t for t in tickets if is_startable(t, self.by_id, today)]


def per_ticket(fn):
    def run(ctx):
        out = []
        for t in ctx.tickets:
            msg = fn(t, ctx)
            if msg:
                out.append(f"{t['_where']}: {msg}")
        return out
    return run


def each_pair(tickets):
    for i, a in enumerate(tickets):
        for b in tickets[i + 1:]:
            yield a, b


def check_ids(ctx):
    out, seen = [], {}
    for t in ctx.tickets:
        tid = t.get("id")
        if not isinstance(tid, str) or not tid.strip():
            out.append(f"{t['_where']}: no 'id'")
            continue
        if tid in seen:
            out.append(f"{t['_where']}: id '{tid}' is already used by {seen[tid]}")
        else:
            seen[tid] = t["_where"]
    return out


def check_dates(t, _ctx):
    missing = [f for f in ("created", "updated") if f not in t["_fields"]]
    if missing:
        return f"no {' and no '.join(missing)}"
    bad = [f for f in ("created", "updated") if not parse_iso(t.get(f))]
    if bad:
        return f"{', '.join(bad)} is not an RFC 3339 full-date (YYYY-MM-DD)"
    return None


def check_verify_present(t, _ctx):
    if t["_stage"] == "cancelled":
        return None
    if not str(t.get("verify") or "").strip():
        return "no 'verify', and the ticket is not cancelled"
    return None


def check_verify_commands(t, _ctx):
    if t["_stage"] == "cancelled" or not str(t.get("verify") or "").strip():
        return None
    if verify_commands(t):
        return None
    if t.get("executor") in ("human", "mixed"):
        return None
    return "'verify' states no command, and the executor is not human or mixed"


def check_can_fail(t, _ctx):
    if t["_stage"] == "cancelled":
        return None
    cmds = verify_commands(t)
    if cmds and all(CANNOT_FAIL_RE.search(_strip_quotes(ln)) for ln in cmds):
        return "every command in 'verify' is incapable of failing (an unconditional-success fallback)"
    for ln in cmds:
        if OR_ECHO_RE.search(_strip_quotes(ln)):
            return f"a check ends in '|| echo', which always exits 0: {ln.strip()}"
        if GREP_ERE_RE.search(ln) and "(?" in ln:
            return f"a PCRE construct '(?' in a grep -E pattern is invalid in POSIX ERE: {ln.strip()}"
    return None


def check_base_observation(t, _ctx):
    if t["_stage"] == "cancelled":
        return None
    verify = str(t.get("verify") or "")
    if not verify.strip():
        return None
    if BASE_STATE_RE.search(verify):
        return None
    return "'verify' records no observation that fails at the base state"


def check_not_deploy_evidence(t, _ctx):
    if t["_stage"] == "cancelled":
        return None
    lines = verify_assertions(t)
    if lines and all(DEPLOY_EVIDENCE_RE.search(ln) for ln in lines):
        return "'verify' accepts a deployment, a build or a healthy process as the evidence of completion"
    return None


def check_touches_declared(t, _ctx):
    if t.get("executor") not in ("agent", "mixed"):
        return None
    if "touches" not in t["_fields"]:
        return f"executor is '{t.get('executor')}' and 'touches' is absent"
    if as_list(t.get("touches")) is None:
        return "'touches' is not a list"
    return None


def check_touches_paths(t, _ctx):
    entries = as_list(t.get("touches"))
    if entries is None:
        return None
    bad = [p for p in entries if p.startswith("/") or p.startswith("~") or ".." in p.split("/")]
    if bad:
        return f"'touches' entries are not relative to a set root: {bad}"
    return None


def check_startable_touches_overlap(ctx):
    out = []
    for a, b in each_pair(ctx.startable):
        shared = shared_paths(a, b)
        if shared:
            out.append(
                f"{a['_where']} and {b['_where']} are both startable and both own {shared}"
            )
    return out


def check_touches_appends_disjoint(t, _ctx):
    shared = sorted({x for x in paths_of(t, "touches") for y in paths_of(t, "appends") if overlap(x, y)})
    if shared:
        return f"{shared} appear in both 'touches' and 'appends'"
    return None


def check_blocked_by_present(t, _ctx):
    if "blocked_by" not in t["_fields"]:
        return "no 'blocked_by' (an empty list is how a ticket with no blockers declares it)"
    if as_list(t.get("blocked_by")) is None:
        return "'blocked_by' is not a list"
    return None


def check_blocked_by_resolves(t, ctx):
    missing = [d for d in paths_of(t, "blocked_by") if d not in ctx.by_id]
    if missing:
        return f"'blocked_by' names {missing}, which resolve to no ticket in the set"
    return None


def check_no_cycles(ctx):
    out = []
    for t in ctx.tickets:
        tid = t.get("id")
        if not isinstance(tid, str):
            continue
        seen, stack = set(), [tid]
        cyclic = False
        while stack:
            cur = stack.pop()
            if cur in seen:
                continue
            seen.add(cur)
            for dep in paths_of(ctx.by_id.get(cur, {}), "blocked_by"):
                if dep == tid:
                    cyclic = True
                stack.append(dep)
        if cyclic:
            out.append(f"{t['_where']}: '{tid}' is in its own blocked_by, directly or transitively")
    return out


def check_executor_value(t, _ctx):
    if "executor" not in t["_fields"]:
        return "no 'executor'"
    if t.get("executor") not in EXECUTORS:
        return f"'executor' is {t.get('executor')!r}, not one of {list(EXECUTORS)}"
    return None


def check_human_steps(t, _ctx):
    if t.get("executor") != "mixed":
        return None
    if not str(t.get("human_steps") or "").strip():
        return "executor is 'mixed' and 'human_steps' is absent or empty"
    return None


def check_agent_classification(t, _ctx):
    if t.get("executor") != "agent":
        return None
    if str(t.get("human_steps") or "").strip():
        return "executor is 'agent' and the ticket carries 'human_steps'"
    return None


def check_tags_list(t, _ctx):
    if "tags" not in t["_fields"]:
        return "no 'tags' (an empty list is how a ticket with no tags declares it)"
    if as_list(t.get("tags")) is None:
        return "'tags' is not a list — write it as [a, b] or as a block list"
    return None


def check_positions(ctx):
    return [f"{where}: {why}" for where, why in ctx.strays]


def check_one_representation(t, _ctx):
    duplicated = sorted(t["_fields"] & {"status", "state", "stage", "lifecycle", "position"})
    if duplicated:
        return f"carries {duplicated}, a second representation of the lifecycle position"
    return None


def check_cancelled_outcome(t, _ctx):
    if t["_stage"] != "cancelled":
        return None
    if not str(t.get("outcome") or "").strip():
        return "is cancelled and carries no 'outcome'"
    return None


def _headings(body):
    return re.findall(r"^#{1,6}\s*(.+?)\s*$", body or "", re.M)


def check_problem_solution(t, _ctx):
    heads = " | ".join(_headings(t["_body"])).lower()
    missing = [n for n, pat in (("problem", "problem"), ("solution", "solution")) if pat not in heads]
    if missing:
        return f"body has no {' and no '.join(missing)} section"
    return None


def check_out_of_scope(t, _ctx):
    heads = " | ".join(_headings(t["_body"])).lower()
    if re.search(r"out[ -]of[ -]scope|non-goals", heads):
        return None
    return "body states no out-of-scope boundary"


def check_no_progress_narration(t, _ctx):
    body = t["_body"] or ""
    if PROGRESS_RE.search(body) or PROGRESS_BOLD_RE.search(body):
        return "body carries progress narration (a dated or progress-headed section)"
    return None


def check_unattended_executor(t, _ctx):
    if t.get("executor") != "agent":
        return f"executor is {t.get('executor')!r}; an unattended ticket needs 'agent'"
    return None


def check_non_interactive_verify(t, _ctx):
    if t["_stage"] == "cancelled":
        return None
    m = INTERACTIVE_RE.search(str(t.get("verify") or ""))
    if m:
        return f"'verify' needs a person: {m.group(0)!r}"
    return None


def _text_of(t):
    return "\n".join(
        [str(t.get("verify") or ""), str(t.get("human_steps") or ""), t["_body"] or ""]
    )


def check_no_conversation_citation(t, _ctx):
    m = CONVERSATION_RE.search(_text_of(t))
    if m:
        return f"cites a conversation as the source of something it needs: {m.group(0)!r}"
    return None


def check_locators(t, _ctx):
    m = UNRESOLVABLE_RE.search(_text_of(t))
    if m:
        return f"names an artefact by something that will not exist when it is picked up: {m.group(0)!r}"
    return None


def check_settled(t, _ctx):
    m = UNSETTLED_RE.search(_text_of(t))
    if m:
        return f"leaves a choice unsettled: {m.group(0)!r}"
    return None


def check_reserved_fields(t, _ctx):
    if "defer_until" in t["_fields"] and not parse_iso(t.get("defer_until")):
        return "'defer_until' is not an RFC 3339 full-date, so it cannot carry its reserved meaning"
    if "epic" in t["_fields"] and not isinstance(t.get("epic"), str):
        return "'epic' is not a scalar identifier, so it cannot carry its reserved meaning"
    return None


def check_claim(ctx):
    if ctx.claim is None:
        return []
    mm, profile, source = ctx.claim
    out = []
    if profile not in PROFILES:
        out.append(f"{source}: claims profile '{profile}', which this specification does not define")
    elif profile != ctx.profile:
        out.append(f"{source}: claims profile '{profile}' but was validated at '{ctx.profile}'")
    if mm != ctx.version_mm:
        out.append(f"{source}: claims specification {mm}, and this document is {ctx.version_mm}")
    return out


def should_id_form(t, _ctx):
    tid = t.get("id")
    if isinstance(tid, str) and tid and not ID_FORM_RE.match(tid):
        return f"id '{tid}' is not of the form PREFIX-NNN"
    return None


def should_tag_vocabulary(ctx):
    vocab = {tag for t in ctx.tickets for tag in paths_of(t, "tags")}
    if len(ctx.tickets) >= 3 and len(vocab) > len(ctx.tickets):
        return [f"{len(vocab)} distinct tags across {len(ctx.tickets)} tickets filters nothing"]
    return []


def should_say_manual(t, _ctx):
    m = OBSERVATION_RE.search(str(t.get("verify") or ""))
    if m and t.get("executor") == "agent":
        return f"'verify' asks for a human observation ({m.group(0)!r}) and the executor is 'agent'"
    return None


def should_declare_touches(t, _ctx):
    if "touches" in t["_fields"] or t.get("executor") in ("agent", "mixed"):
        return None
    return "no 'touches' at all — an empty list says 'this changes nothing under the root'"


def should_serialise_shared_paths(ctx):
    out = []
    live = [t for t in ctx.tickets if t["_stage"] not in TERMINAL]
    for a, b in each_pair(live):
        shared = shared_paths(a, b)
        if not shared:
            continue
        if a.get("id") in paths_of(b, "blocked_by") or b.get("id") in paths_of(a, "blocked_by"):
            continue
        out.append(f"{a['_where']} and {b['_where']} both own {shared} and neither blocks the other")
    return out


def should_guided_flow(t, _ctx):
    steps = str(t.get("human_steps") or "")
    if not steps.strip():
        return None
    numbered = len(re.findall(r"^\s*(\d+\.|-)\s", steps, re.M))
    if numbered > 4:
        return f"'human_steps' runs to {numbered} actions — deliver a flow the person runs instead"
    m = SECRET_RE.search(steps)
    if m:
        return f"'human_steps' asks the person to handle a secret ({m.group(0)!r})"
    return None


def should_be_short(t, _ctx):
    words = len((t["_body"] or "").split())
    if words > 900:
        return f"body runs to {words} words — move extended rationale to a decision record"
    return None


def should_settle_in_ticket(t, _ctx):
    m = EXTERNAL_LOG_RE.search(_text_of(t))
    if m:
        return f"refers a settled choice to an external log ({m.group(0)!r})"
    return None


CHECKS = {
    "MUST-1": check_ids,
    "MUST-3": per_ticket(lambda t, c: None if str(t.get("title") or "").strip() else "no 'title'"),
    "MUST-4": per_ticket(check_dates),
    "MUST-6": per_ticket(check_tags_list),
    "MUST-7": per_ticket(check_verify_present),
    "MUST-8": per_ticket(check_verify_commands),
    "MUST-9": per_ticket(check_can_fail),
    "MUST-10": per_ticket(check_base_observation),
    "MUST-11": per_ticket(check_not_deploy_evidence),
    "MUST-13": per_ticket(check_touches_declared),
    "MUST-14": per_ticket(check_touches_paths),
    "MUST-15": check_startable_touches_overlap,
    "MUST-17": per_ticket(check_touches_appends_disjoint),
    "MUST-18": per_ticket(check_blocked_by_present),
    "MUST-19": per_ticket(check_blocked_by_resolves),
    "MUST-20": check_no_cycles,
    "MUST-22": per_ticket(check_executor_value),
    "MUST-23": per_ticket(check_human_steps),
    "MUST-24": per_ticket(check_agent_classification),
    "MUST-25": check_positions,
    "MUST-26": per_ticket(check_one_representation),
    "MUST-28": per_ticket(check_cancelled_outcome),
    "MUST-30": per_ticket(check_problem_solution),
    "MUST-31": per_ticket(check_out_of_scope),
    "MUST-33": per_ticket(check_no_progress_narration),
    "MUST-34": per_ticket(check_unattended_executor),
    "MUST-35": per_ticket(check_non_interactive_verify),
    "MUST-36": per_ticket(check_no_conversation_citation),
    "MUST-37": per_ticket(check_locators),
    "MUST-38": per_ticket(check_settled),
    "MUST-39": per_ticket(check_reserved_fields),
    "MUST-40": check_claim,
    "SHOULD-1": per_ticket(should_id_form),
    "SHOULD-2": should_tag_vocabulary,
    "SHOULD-4": per_ticket(should_say_manual),
    "SHOULD-7": per_ticket(should_declare_touches),
    "SHOULD-8": should_serialise_shared_paths,
    "SHOULD-9": per_ticket(should_guided_flow),
    "SHOULD-11": per_ticket(should_be_short),
    "SHOULD-12": per_ticket(should_settle_in_ticket),
}

# Requirements with no mechanical check, each with the reason. Nothing may be
# absent from both this table and CHECKS: an unlisted requirement reports
# UNCHECKED, which --selftest treats as a failure.
UNCHECKABLE = {
    "MUST-2": (NOT_CHECKABLE, "an id retired with its file leaves no record in the tree"),
    "MUST-5": (NOT_CHECKABLE, "whether 'updated' was advanced is a fact about history, not the tree"),
    "MUST-12": (NOT_CHECKABLE, "the substrate records no execution of 'verify'"),
    "MUST-16": (NOT_CHECKABLE, "whether a path merges without reasoning is a judgement; overlaps are reported as warnings under SHOULD-8"),
    "MUST-21": (IMPLEMENTATION, "constrains an implementation; this program computes startability exactly as stated"),
    "MUST-27": (NOT_CHECKABLE, "the positions are distinct by construction; the transition through them is history"),
    "MUST-29": (NOT_CHECKABLE, "a ticket removed rather than cancelled leaves nothing to inspect"),
    "MUST-32": (NOT_CHECKABLE, "a file carries no record of when it became startable"),
    "MUST-41": (DOCUMENT, "constrains a binding document, not a ticket set"),
    "MUST-42": (DOCUMENT, "constrains a binding document, not a ticket set"),
    "MUST-43": (DOCUMENT, "constrains a binding document, not a ticket set"),
    "MUST-44": (DOCUMENT, "constrains a binding document, not a ticket set"),
    "MUST-45": (DOCUMENT, "constrains this specification's own revisions"),
    "SHOULD-3": (NOT_CHECKABLE, "whether 'verify' was run at the base state is not recorded in the tree"),
    "SHOULD-5": (NOT_CHECKABLE, "re-running 'verify' is the only way to learn this"),
    "SHOULD-6": (NOT_CHECKABLE, "whether 'touches' is generous enough is a judgement"),
    "SHOULD-10": (NOT_CHECKABLE, "which change carried a transition is a fact about history"),
}

LIFECYCLE_DEPENDENT = ("MUST-25",)


def evaluate(ctx, reqs):
    """Return one row per in-profile requirement: (key, profile, status, note,
    findings)."""
    rows = []
    for req in reqs:
        if not req.in_profile(ctx.profile):
            continue
        if req.key in CHECKS:
            if ctx.layout == "flat" and req.key in LIFECYCLE_DEPENDENT:
                rows.append((req.key, req.profile, NOT_CHECKABLE,
                             "a flat directory represents no lifecycle position", []))
                continue
            findings = CHECKS[req.key](ctx)
            if findings:
                rows.append((req.key, req.profile, "FAIL" if req.kind == "MUST" else "report",
                             "", findings))
            else:
                rows.append((req.key, req.profile, "pass", "", []))
        elif req.key in UNCHECKABLE:
            status, note = UNCHECKABLE[req.key]
            rows.append((req.key, req.profile, status, note, []))
        else:
            rows.append((req.key, req.profile, UNCHECKED,
                         "no check and no recorded reason — SPEC.md has moved ahead of this validator", []))
    return rows


def report(rows, ctx, version, quiet, out=sys.stdout, err=None):
    err = err if err is not None else sys.stderr
    print(f"work-order conformance — SPEC.md {version}, profile `{ctx.profile}`", file=out)
    claimed = f", claim in {ctx.claim[2]}" if ctx.claim else ", claim from the command line"
    print(f"set: {ctx.root} — {len(ctx.tickets)} ticket(s), {ctx.layout} layout{claimed}", file=out)
    print("", file=out)
    for key, profile, status, note, findings in rows:
        if quiet and status in ("pass", NOT_CHECKABLE, IMPLEMENTATION, DOCUMENT):
            continue
        tail = f"  {note}" if note else ""
        print(f"{key:<10} {profile:<11} {status}{tail}", file=out)
        for f in findings:
            print(f"    {f}", file=out)
    print("", file=out)

    counts = {}
    for _, _, status, _, _ in rows:
        counts[status] = counts.get(status, 0) + 1
    musts = [r for r in rows if r[0].startswith("MUST-")]
    shoulds = [r for r in rows if r[0].startswith("SHOULD-")]
    failed = [r[0] for r in musts if r[2] == "FAIL"]
    reported = [r[0] for r in shoulds if r[2] == "report"]
    print(
        f"{len(musts)} MUST and {len(shoulds)} SHOULD in profile `{ctx.profile}`: "
        f"{counts.get('pass', 0)} pass, {len(failed)} FAIL, {len(reported)} SHOULD reported, "
        f"{counts.get(NOT_CHECKABLE, 0)} not checkable from the tree, "
        f"{counts.get(UNCHECKED, 0)} unchecked",
        file=out,
    )
    if reported:
        print(f"SHOULD reported (does not gate): {', '.join(reported)}", file=out)
    if failed:
        print(f"FAIL: {len(failed)} MUST violated at profile `{ctx.profile}`: {', '.join(failed)}",
              file=err)
        return 1
    print(f"PASS: conforms to SPEC.md {version} at profile `{ctx.profile}`", file=out)
    return 0


def run(set_dir, profile, spec_path, version_path, quiet=False, out=sys.stdout, err=None):
    reqs = parse_spec(spec_path)
    version, version_mm = spec_version(version_path)
    root = Path(set_dir)
    tickets, strays, layout = load_set(root)
    ctx = Context(tickets, strays, layout, root, profile, read_claim(root), version_mm)
    rows = evaluate(ctx, reqs)
    return report(rows, ctx, version, quiet, out, err), rows


def _repo_root():
    return Path(__file__).resolve().parent.parent


def main(argv):
    parser = argparse.ArgumentParser(
        prog="validate.py", description="Check a ticket set against SPEC.md at one profile."
    )
    parser.add_argument("set_dir", nargs="?", help="the ticket set's root directory")
    parser.add_argument("--profile", choices=PROFILES, help="the profile to validate at")
    parser.add_argument("--spec", default=None, help="path to SPEC.md (default: beside this program)")
    parser.add_argument("--version-file", default=None, help="path to VERSION-spec")
    parser.add_argument("--quiet", action="store_true", help="print only failures and the summary")
    parser.add_argument("--selftest", action="store_true", help="run the fixture checks and exit")
    args = parser.parse_args(argv[1:])

    root = _repo_root()
    spec_path = Path(args.spec) if args.spec else root / "SPEC.md"
    version_path = Path(args.version_file) if args.version_file else root / "VERSION-spec"

    if args.selftest:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        from selftest import selftest
        return selftest(spec_path, version_path)
    if not args.set_dir or not args.profile:
        parser.error("a set directory and --profile are both required (or use --selftest)")

    rc, _ = run(args.set_dir, args.profile, spec_path, version_path, args.quiet)
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))
