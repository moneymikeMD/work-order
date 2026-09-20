#!/usr/bin/env python3
"""Validate and plan a set of frontmatter tickets.

    issues.py lint     <dir>   errors that make a ticket unworkable
    issues.py waves    <dir>   parallel execution plan + worktree commands
    issues.py preflight <dir>  files two or more startable tickets would
                                write, before the wave is dispatched; exit 0
                                no collisions, 1 collisions found, 2 no plan
    issues.py board    <dir>   what is where
    issues.py next     <dir>   tickets startable right now
    issues.py scope    <ticket-id> <base-ref> [<dir>] [--repo PATH]
                                classify git diff --name-only <base-ref>...HEAD
                                paths, run in --repo (default: cwd), vs the
                                ticket's touches/appends -- a leading
                                <repo-name>/ component is stripped from each
                                glob, scoped to --repo's basename, before
                                matching; exit 0 all declared, 1 any
                                UNDECLARED, 2 unresolved ticket or ref
    issues.py selftest         run built-in fixture checks, no <dir> needed

    --landing serial | parallel        (`waves` and `preflight` only)
        Which landing path this wave will use. Default `serial`: branches
        merge one at a time behind a lock, so two tickets appending the same
        file produce a small merge and `appends` overlap stays a warning.
        `parallel`: nothing serialises the merges, so a shared `appends`
        path collides exactly the way a shared `touches` path does and
        splits the wave. The mode is an input because the planner cannot
        infer it, and assuming the serialised one is what put five pull
        requests into DIRTY on 2026-09-19.

A ticket with no executor (missing/None/empty) is never startable: it is
excluded from `next` and from every wave in `waves`, and shown in `board`
under its real stage with a `[?]` marker and the suffix "not startable: no
executor" — regardless of source (files or jira). This is the tool-side
safety net for a ticket captured with a title/description only and no
executor set (e.g. one pasted in from a chat conversation with no frontmatter
review).

The default source is the filesystem: <dir> is a directory of stage
subdirectories full of frontmatter Markdown (open/, in-progress/,
awaiting-deployment/, completed/, cancelled/ — see the to-issues skill).

    --source jira | ISSUES_SOURCE=jira
        Read the ticket set from Jira instead of the filesystem. <dir> is not
        needed and is ignored. One JQL fetch per invocation (never per
        ticket): `project = <PROJECT_KEY> AND status not in (Completed,
        Cancelled)`, run through a caller-supplied jira-api.sh-shaped wrapper
        (this plugin does not ship one — see --jira-api below). A failed
        or empty fetch is a loud, non-zero exit — see fetch_jira_json below.

        --jira-api PATH | ISSUES_JIRA_API=PATH   path to jira-api.sh.
        --jira-project KEY | ISSUES_JIRA_PROJECT=KEY
            the Jira project key to query (default: PROJ — override this
            for your own project).
        --fixture PATH                            read this JSON file
            instead of calling jira-api.sh (its shape: the body of a
            GET /rest/api/3/search/jql response — {"issues": [...]}).

Whichever source is used, lint/waves/board/next run the SAME wave-grouping,
glob-overlap collision check, and defer_until logic against the same
in-memory ticket shape (id, title, executor, touches, verify, human_steps,
appends, blocked_by, defer_until, epic, _stage, _path, _body). That sharing is the
point: the touches-overlap check is what stops two parallel agents colliding,
and it must behave identically regardless of where the tickets came from.

Stdlib only, and the frontmatter parser is hand-rolled rather than PyYAML, so
this runs anywhere python3 does. Tickets get read by agents on machines nobody
prepared in advance; a dependency is one more reason for that to fail.
"""

import sys
import os
import re
import json
import subprocess
import tempfile
import glob as globmod
import urllib.parse
from datetime import date
from fnmatch import fnmatch
from collections import defaultdict

STAGES = ["open", "in-progress", "awaiting-deployment", "completed", "cancelled"]
DONE = ["completed", "cancelled"]
# awaiting-deployment still has work left (the deploy itself); leaving it
# out of PENDING strands dependents and waves() reports a phantom cycle.
PENDING = ["open", "in-progress", "awaiting-deployment"]
# Dispatchable stages. awaiting-deployment is deliberately not one: the branch
# already landed and was deleted, so the branch-exists refusal does not fire
# and a re-dispatch redoes merged work on a fresh branch.
WORKABLE = ["open", "in-progress"]
# Stages that satisfy a blocked_by. awaiting-deployment counts — its code is
# merged, only the deploy is owed — and it must, now that it is no longer
# scheduled into a wave to unblock its dependents as a side effect.
RESOLVING = DONE + ["awaiting-deployment"]


def die(msg):
    """Loud, non-zero exit. Used for source-fetch failures — the ticket's
    'fail fast at the start' decision: an outage or an empty result must stop
    a wave dispatch before it half-completes, not surface as a confusing
    partial run."""
    print(f"issues.py: {msg}", file=sys.stderr)
    sys.exit(1)


def parse_frontmatter(text):
    """Return (dict, body). Handles the subset tickets actually use: scalars,
    inline lists, block lists, and block scalars (| and >-)."""
    lines = text.split("\n")
    if not lines or lines[0] != "---":
        return {}, text
    # Line-anchored: a block scalar's body can legitimately contain a bare
    # "---" line, and text.split("---", 2) would take THAT as the fence.
    end_idx = None
    for i in range(1, len(lines)):
        if lines[i] == "---":
            end_idx = i
            break
    if end_idx is None:
        return {}, text
    raw = "\n".join(lines[1:end_idx])
    body = "\n".join(lines[end_idx + 1:])

    data, key, mode, buf = {}, None, None, []

    def flush():
        if key is None:
            return
        if mode == "block":
            data[key] = "\n".join(buf).strip()
        elif mode == "list":
            data[key] = [x for x in buf if x]

    for line in raw.split("\n"):
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
        m = re.match(r"^([A-Za-z_][\w-]*):\s*(.*)$", line)
        if not m:
            continue
        k, v = m.group(1), m.group(2).strip()
        if v in ("|", ">-", ">", "|-"):
            key, mode, buf = k, "block", []
        elif v == "":
            key, mode, buf = k, "list", []
            data[k] = []          # an empty list unless block items follow
        elif v.startswith("[") and v.endswith("]"):
            inner = v[1:-1].strip()
            data[k] = [x.strip() for x in inner.split(",") if x.strip()]
        else:
            data[k] = v.strip().strip('"').strip("'")
    flush()
    return data, body


def load_files(root):
    """The original filesystem source: issues/<stage>/*.md. Excludes a
    `<id>.notes.md` progress note by suffix (see `[FILE-4]` of the file
    binding) so a ticket legitimately named e.g. `T-009-notes-format.md`
    still loads. Excluded here, not in `lint`, so `board`/`waves`/`next`
    see the same set."""
    tickets = []
    for stage in STAGES:
        for path in sorted(globmod.glob(os.path.join(root, stage, "*.md"))):
            if path.endswith(".notes.md"):
                continue
            fm, body = parse_frontmatter(open(path).read())
            fm["_path"], fm["_stage"], fm["_body"] = path, stage, body
            tickets.append(fm)
    return tickets


# Placeholder ids — Jira custom field ids are per-site. An adopting project
# must create these fields itself and update these constants to match.
JIRA_FIELD_TOUCHES = "customfield_10043"
JIRA_FIELD_VERIFY = "customfield_10044"
JIRA_FIELD_HUMAN_STEPS = "customfield_10045"
JIRA_FIELD_APPENDS = "customfield_10046"
JIRA_FIELD_EXECUTOR = "customfield_10047"
JIRA_FIELD_DEFER_UNTIL = "customfield_10048"

JIRA_FIELDS = ",".join([
    "summary", "status", "labels", "issuelinks", "created", "updated", "parent",
    "issuetype",
    JIRA_FIELD_TOUCHES, JIRA_FIELD_VERIFY, JIRA_FIELD_HUMAN_STEPS,
    JIRA_FIELD_APPENDS, JIRA_FIELD_EXECUTOR, JIRA_FIELD_DEFER_UNTIL,
])

# The legacy /rest/api/3/search is 410 Gone on newer sites; /search/jql
# returns no "total" and paginates by nextPageToken, not startAt.
def _jira_jql(project_key):
    """The one JQL fetch (see JIRA_SEARCH_PATH's docstring): excludes
    Completed/Cancelled, and Done — the closed status a template-derived
    Space (LAB and others) ships instead of Completed. A project on that
    template still needs Done excluded here or every closed ticket comes
    back and lint()/board() flag it as jira-unknown-status:Done."""
    return f"project = {project_key} AND status not in (Completed, Cancelled, Done) ORDER BY key ASC"


JIRA_PROJECT_KEY = os.environ.get("ISSUES_JIRA_PROJECT", "PROJ")
JIRA_JQL = _jira_jql(JIRA_PROJECT_KEY)
JIRA_SEARCH_PATH = "/search/jql"
JIRA_MAX_RESULTS = 500

# Triage and Deferred are deliberately absent from WORKABLE/PENDING/DONE:
# both are parked until someone moves them, never startable.
JIRA_STATUS_TO_STAGE = {
    "Triage": "triage",
    "To Do": "open",
    "Open": "open",
    "In Progress": "in-progress",
    "Awaiting Deployment": "awaiting-deployment",
    "Deferred": "deferred",
    "Completed": "completed",
    "Cancelled": "cancelled",
    # Template Spaces ship Done, not Completed, as the closed status; it must
    # also be excluded in _jira_jql() or every closed ticket comes back.
    "Done": "completed",
}


def _adf_text(node):
    """Flatten an Atlassian Document Format node to plain text. Jira's v3 API
    returns textarea (paragraph) custom fields as ADF documents, not strings
    — and rejects a plain string written to one of these fields. Paragraphs
    and code-block lines become lines; hardBreak becomes a newline. A plain
    string passes through."""
    if node is None:
        return ""
    if isinstance(node, str):
        return node
    if not isinstance(node, dict):
        return str(node)
    t = node.get("type")
    if t == "text":
        return node.get("text", "")
    if t == "hardBreak":
        return "\n"
    inner = "".join(_adf_text(c) for c in node.get("content") or [])
    if t in ("paragraph", "heading", "codeBlock", "listItem"):
        return inner + "\n"
    return inner


def _lines(text):
    """A Jira textarea custom field back into the list shape the frontmatter
    versions of touches/human_steps/appends use: one item per line."""
    text = _adf_text(text)
    if not text:
        return []
    return [l.strip() for l in text.splitlines() if l.strip()]


def fetch_jira_json(jira_api, fixture):
    """Return the parsed JSON body of the one JQL fetch. Dies loudly (see
    die()) on any failure or empty/malformed result — never returns a
    partial or best-guess result for the caller to limp along with."""
    if fixture:
        try:
            with open(fixture) as f:
                text = f.read()
        except OSError as e:
            die(f"could not read fixture '{fixture}': {e}")
        if not text.strip():
            die(f"fixture '{fixture}' is empty")
        try:
            return json.loads(text)
        except json.JSONDecodeError as e:
            die(f"fixture '{fixture}' is not valid JSON: {e}")

    if not jira_api:
        die("--source jira needs --jira-api PATH or ISSUES_JIRA_API=PATH "
            "pointing at a jira-api.sh-shaped wrapper (raw GET <path> on "
            "stdout) — this plugin does not ship one; bring your own, or "
            "pass --fixture PATH with a captured response for testing")
    if not os.path.exists(jira_api):
        die(f"jira-api script not found at '{jira_api}'")

    # --show-secrets: a wrapper that redacts bare "key" fields would blank every
    # issue key. Safe only because JIRA_FIELDS names no credential-shaped field.
    issues = []
    token = None
    while True:
        params = {
            "jql": JIRA_JQL,
            "maxResults": JIRA_MAX_RESULTS,
            "fields": JIRA_FIELDS,
        }
        if token:
            params["nextPageToken"] = token
        path = f"{JIRA_SEARCH_PATH}?{urllib.parse.urlencode(params)}"
        try:
            proc = subprocess.run([jira_api, "--show-secrets", "raw", "GET", path],
                                   capture_output=True, text=True, timeout=60)
        except (OSError, subprocess.SubprocessError) as e:
            die(f"could not run '{jira_api}': {e}")
        if proc.returncode != 0:
            err = (proc.stderr or "").strip()
            die(f"jira fetch failed (exit {proc.returncode}): {err or '(no error output)'}")
        out = (proc.stdout or "").strip()
        if not out:
            die("jira fetch returned no output")
        try:
            page = json.loads(out)
        except json.JSONDecodeError as e:
            die(f"jira fetch did not return valid JSON: {e}")
        if page.get("issues") is None:
            die("jira fetch response has no 'issues' array — unexpected shape "
                "from /rest/api/3/search/jql")
        issues.extend(page["issues"])
        if page.get("isLast", True) or not page.get("nextPageToken"):
            break
        token = page["nextPageToken"]
    return {"issues": issues, "isLast": True}


def jira_issue_to_ticket(issue):
    """One Jira issue -> the same dict shape load_files() produces."""
    f = issue.get("fields") or {}
    key = issue.get("key")

    status = (f.get("status") or {}).get("name", "")
    stage = JIRA_STATUS_TO_STAGE.get(status)
    if stage is None:
        # Schema drift, not something to guess at: never-startable rather than
        # defaulting into WORKABLE, where a mis-mapped status would dispatch.
        stage = f"jira-unknown-status:{status or '(none)'}"

    executor_field = f.get(JIRA_FIELD_EXECUTOR)
    executor = executor_field.get("value") if isinstance(executor_field, dict) else executor_field

    # Jira serves an Epic as the Task's ordinary `parent`, not the legacy
    # "Epic Link". Epic status is not read from here — see compute_epic_rollup.
    parent_field = f.get("parent") or {}
    epic = None
    if parent_field.get("key"):
        epic = {
            "key": parent_field["key"],
            "title": (parent_field.get("fields") or {}).get("summary", ""),
        }

    blocked_by = []
    for link in f.get("issuelinks") or []:
        if (link.get("type") or {}).get("name") != "Blocks":
            continue
        inward = link.get("inwardIssue")
        if inward and inward.get("key"):
            blocked_by.append(inward["key"])

    return {
        "id": key,
        "title": f.get("summary", ""),
        "created": (f.get("created") or "")[:10],
        "updated": (f.get("updated") or "")[:10],
        "tags": f.get("labels") or [],
        "blocked_by": blocked_by,
        "touches": _lines(f.get(JIRA_FIELD_TOUCHES)),
        "verify": _adf_text(f.get(JIRA_FIELD_VERIFY)).strip(),
        "human_steps": _lines(f.get(JIRA_FIELD_HUMAN_STEPS)),
        "appends": _lines(f.get(JIRA_FIELD_APPENDS)),
        "executor": executor,
        "epic": epic,
        # An Epic has no parent by construction, so "orphan" would be a false alarm.
        "_is_epic": (f.get("issuetype") or {}).get("name") == "Epic",
        "defer_until": f.get(JIRA_FIELD_DEFER_UNTIL),
        "_path": key,
        "_stage": stage,
        "_body": "",
    }


def _jira_project_of(key):
    """The project prefix of a Jira key: 'LAB-227' -> 'LAB'."""
    key = str(key or "")
    return key.rsplit("-", 1)[0] if "-" in key else ""


def _jira_shadow_for_blocker(inward_issue, fetched_projects):
    """A blocked_by target that the one JQL fetch excluded on purpose — it
    only asks for status not in (Completed, Cancelled), so a blocker that IS
    completed/cancelled never appears as its own issue in `issues`. Without
    something standing in for it, the shared waves()/nxt() logic would see
    an unresolvable dependency and block its dependents forever.

    Jira's issuelinks payload nests a slim `fields` (including status) on
    the linked issue by default, with no extra fetch — so this reads that
    nested status rather than issuing a second call (one fetch per
    invocation, per the ticket contract). Only built when that nested status
    maps to a DONE stage; anything else is left alone and surfaces through
    lint's normal "blocked_by '...' does not exist" check rather than being
    guessed at, since the nested fields are not guaranteed complete for a
    live (not-Completed/Cancelled) issue outside the fetch scope.

    A blocker in a project the fetch never asked for is the other case: the
    JQL is project-scoped, so its key cannot be in `issues` whatever its
    status, and the nested status is the only evidence there is. It is taken
    as-is rather than left to lint's "does not exist", which is wrong about
    it. statusCategory settles Done-ness because another project's workflow
    may name its statuses anything; a non-Done external blocker gets a stage
    outside both WORKABLE and DONE, so it blocks without ever dispatching."""
    key = inward_issue.get("key")
    if not key:
        return None
    jira_status = (inward_issue.get("fields") or {}).get("status") or {}
    status = jira_status.get("name", "")
    stage = JIRA_STATUS_TO_STAGE.get(status)
    external = _jira_project_of(key) not in fetched_projects
    if external:
        done = stage in DONE or (jira_status.get("statusCategory") or {}).get("key") == "done"
        stage = "completed" if done else f"jira-external:{status or '(none)'}"
    elif stage not in DONE:
        return None
    return {
        "id": key, "title": "", "created": "", "updated": "",
        "tags": [], "blocked_by": [], "touches": [], "verify": "",
        "human_steps": [], "appends": [], "executor": None, "epic": None,
        "defer_until": None, "_path": key, "_stage": stage, "_body": "",
        # Resolution stand-in only: lint()/board() skip it, and its stage is
        # never in WORKABLE, so waves()/nxt() need no special case.
        "_shadow": True,
        "_external": external,
    }


def load_jira(jira_api, fixture):
    data = fetch_jira_json(jira_api, fixture)
    issues = data.get("issues")
    if issues is None:
        die("jira fetch response has no 'issues' array — unexpected shape "
            "from /rest/api/3/search/jql")
    if not issues:
        die("jira fetch returned zero issues for "
            f"'{JIRA_JQL}' — refusing to silently proceed as if there were "
            "nothing to do (fail fast at the start)")

    tickets = [jira_issue_to_ticket(i) for i in issues]
    have = {t["id"] for t in tickets}
    # Derived from what came back, not from JIRA_PROJECT_KEY: it is the fetch's
    # actual reach that decides whether a blocker could have been in it.
    fetched_projects = {_jira_project_of(t["id"]) for t in tickets if t.get("id")}
    shadows = {}
    for issue in issues:
        for link in (issue.get("fields") or {}).get("issuelinks") or []:
            if (link.get("type") or {}).get("name") != "Blocks":
                continue
            inward = link.get("inwardIssue")
            if not inward or inward.get("key") in have:
                continue
            shadow = _jira_shadow_for_blocker(inward, fetched_projects)
            if shadow:
                shadows[shadow["id"]] = shadow
    tickets.extend(shadows.values())
    return tickets


def _numeric_id(ticket_id):
    """PROJ-014 and PROJ-14 sort as 14; anything unparseable sorts last."""
    m = re.search(r"(\d+)$", str(ticket_id))
    return int(m.group(1)) if m else 10**9


def has_executor(t):
    """True only for a real, non-empty executor value. A missing/None/empty
    executor means nobody has said who can pick the ticket up, so it is
    never startable — see nxt()/waves()/board() and the lint warning below.
    This is the tool-side safety net for any ticket (either source) that
    reaches a workable stage with the field still unset — the case that
    matters most is a ticket captured from a chat conversation with only a
    title and description, before anyone reviewed its frontmatter."""
    return bool(t.get("executor"))


_PATH_LIKE = re.compile(r"^[\w.@-]+\.\w+$")


def _path_like(s):
    """Could this name a file? A separator, a glob metacharacter, or a bare
    filename with an extension. A prose annotation has none of the three."""
    s = s.strip()
    return bool(s) and ("/" in s or "*" in s or "?" in s or bool(_PATH_LIKE.match(s)))


def _comma_joined_paths(entry):
    """The paths in a touches item written as one comma-separated line, or []
    for an ordinary single path. A path with a parenthetical annotation ("a/b
    (untracked, outside every repo)") has one path-like piece, not two, so it
    is not mistaken for a list."""
    if "," not in entry:
        return []
    parts = [p.strip() for p in entry.split(",")]
    paths = [p for p in parts if _path_like(p)]
    return paths if len(paths) > 1 else []


def overlap(a, b):
    """Do two touch-globs refer to any common path? Checked both directions so
    a literal path is caught by a glob that would match it."""
    return a == b or fnmatch(a, b) or fnmatch(b, a)


def _strip_repo_prefix(globs, repo):
    """Drop a leading `<repo>/` component from each glob that has one, so a
    ~/code-relative touches/appends entry (`work-order/SPEC.md`) compares
    against a single-repo `git diff`'s repo-relative paths (`SPEC.md`). A
    glob for a different repo is returned unchanged and therefore never
    matches — stripping is scoped to `repo` so a `night-watchman/` glob
    never matches inside `work-order`."""
    if not repo:
        return list(globs)
    prefix = f"{repo}/"
    return [g[len(prefix):] if g.startswith(prefix) else g for g in globs]


def overlap_declared(ticket, path, repo=None):
    """Is `path` (repo-relative, as `git diff` in a single checkout emits
    it) declared in ticket's touches or appends, once each glob's leading
    `<repo>/` component is stripped, scoped to `repo`?"""
    touches = _strip_repo_prefix(ticket.get("touches") or [], repo)
    appends = _strip_repo_prefix(ticket.get("appends") or [], repo)
    return (any(overlap(path, g) for g in touches) or
            any(overlap(path, g) for g in appends))


_ISO_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def parse_iso_date(s):
    """Return a date for a strict YYYY-MM-DD string, or None if malformed —
    including a well-formed-looking string with an out-of-range month/day.
    Deliberately not date.fromisoformat: its accepted grammar has widened
    across Python versions, and this parser has to agree with itself on
    whatever python3 a ticket happens to be read with."""
    if not isinstance(s, str) or not _ISO_DATE.match(s):
        return None
    y, m, d = (int(p) for p in s.split("-"))
    try:
        return date(y, m, d)
    except ValueError:
        return None


def is_deferred(t, today=None):
    """True only for a *valid, future* defer_until. A bad value is lint()'s
    problem, not schedulability's — treating it as deferred here would hide
    the very ticket whose frontmatter needs fixing. Absent or past dates are
    not deferred, per the field's contract."""
    d = parse_iso_date(t.get("defer_until") or "")
    return d is not None and d > (today or date.today())


def _where(t, root):
    """Display label for a ticket in messages. A filesystem ticket's _path is
    under root, so relpath reads naturally; a Jira ticket's _path is just its
    key, which is already the right thing to show."""
    path = t.get("_path") or ""
    if root and isinstance(path, str) and path.startswith(root):
        return os.path.relpath(path, root)
    return path


def scope(ticket_id, base_ref, tickets, cwd=None, repo=None):
    """Classify every path in `git diff --name-only <base_ref>...HEAD`,
    run in `cwd` (the repo checkout being diffed — never the ticket
    directory, which is not a git repo), against ticket_id's touches/appends
    globs via overlap_declared(). Prints one "<class>\tpath" line per
    changed path and returns 0 when every path is declared, 1 when any path
    is UNDECLARED, 2 when the ticket or ref cannot be resolved. `repo`
    scopes the `<repo>/` prefix stripped from touches/appends before
    matching; if omitted, it is the basename of `cwd` (or the process cwd).
    Adapted from mattpocock/skills code-review (spec axis), 2026-09-14."""
    ticket = next((t for t in tickets if t.get("id") == ticket_id), None)
    if ticket is None:
        print(f"issues.py: unknown ticket '{ticket_id}'", file=sys.stderr)
        return 2
    try:
        proc = subprocess.run(
            ["git", "diff", "--name-only", f"{base_ref}...HEAD"],
            capture_output=True, text=True, timeout=30, cwd=cwd,
        )
    except (OSError, subprocess.SubprocessError) as e:
        print(f"issues.py: could not run git diff: {e}", file=sys.stderr)
        return 2
    if proc.returncode != 0:
        err = (proc.stderr or "").strip()
        print(f"issues.py: could not resolve ref '{base_ref}' (git diff "
              f"exit {proc.returncode}): {err or '(no error output)'}",
              file=sys.stderr)
        return 2
    paths = [p for p in (proc.stdout or "").splitlines() if p]
    effective_repo = repo
    if effective_repo is None:
        effective_repo = os.path.basename(
            os.path.abspath(cwd or os.getcwd()).rstrip(os.sep))
    touches = _strip_repo_prefix(ticket.get("touches") or [], effective_repo)
    appends = _strip_repo_prefix(ticket.get("appends") or [], effective_repo)
    undeclared = 0
    for path in paths:
        if any(overlap(path, g) for g in touches):
            cls = "touches"
        elif any(overlap(path, g) for g in appends):
            cls = "appends"
        else:
            cls = "UNDECLARED"
            undeclared += 1
        print(f"{cls}\t{path}")
    if not paths:
        print(f"no changes {base_ref}...HEAD")
    return 1 if undeclared else 0


def lint(tickets, root):
    if not tickets:
        print(f"no tickets under {root}")
        return 1
    ids = {t.get("id") for t in tickets if t.get("id")}
    errs, warns = [], []

    seen = defaultdict(list)
    for t in tickets:
        tid, stage = t.get("id"), t["_stage"]
        where = _where(t, root)

        if not tid:
            errs.append(f"{where}: no id")
            continue
        seen[tid].append(where)

        # A shadow stand-in has no title/verify/executor by construction — skip
        # the checks that would otherwise flag it as a broken real ticket.
        if t.get("_shadow"):
            continue

        required = ["title", "created", "updated"]
        for f in required:
            if not t.get(f):
                errs.append(f"{tid}: missing `{f}`")

        ex = t.get("executor")
        is_epic = t.get("_is_epic")
        # Epics are containers and cancelled tickets need no executor; a missing
        # executor elsewhere is a warning, not an error (Jira can carry a null).
        if stage != "cancelled" and not is_epic and not ex:
            warns.append(f"{tid}: no executor — blocks dispatch: excluded from "
                         f"`next` and every wave in `waves`, shown as [?] "
                         f"'not startable: no executor' in `board`")
        if ex and ex not in ("agent", "human", "mixed"):
            errs.append(f"{tid}: executor '{ex}' is not agent/human/mixed")
        if ex == "mixed" and not t.get("human_steps"):
            errs.append(f"{tid}: executor is mixed but human_steps is empty — "
                        f"an agent cannot tell where to stop")

        for dep in t.get("blocked_by") or []:
            if dep not in ids:
                errs.append(f"{tid}: blocked_by '{dep}' does not exist")
            dept = next((x for x in tickets if x.get("id") == dep), {})
            if dept.get("_external") and dept["_stage"] not in RESOLVING:
                warns.append(f"{tid}: blocked_by '{dep}' is in another project, "
                             f"outside this fetch, and is not Done — not startable")
            if dep == tid:
                errs.append(f"{tid}: blocked by itself")

        defer = t.get("defer_until")
        if defer and parse_iso_date(defer) is None:
            errs.append(f"{tid}: defer_until '{defer}' is not an ISO date "
                        f"(YYYY-MM-DD)")

        if stage == "cancelled":
            if not t.get("outcome"):
                errs.append(f"{tid}: cancelled with no outcome — the reader "
                            f"learns it lost but not why, and re-proposes it")
        elif not is_epic:
            if not t.get("verify"):
                errs.append(f"{tid}: no verify — nobody can prove this is done")
            if ex in ("agent", "mixed") and t.get("touches") is None:
                errs.append(f"{tid}: executor is {ex} but touches is unset — "
                            f"parallel safety cannot be checked")

        for path in t.get("touches") or []:
            joined = _comma_joined_paths(path)
            if joined:
                errs.append(f"{tid}: touches entry '{path}' is {len(joined)} "
                            f"comma-separated paths on one line, not one path — "
                            f"split it, or nothing matches it and every changed "
                            f"file reads UNDECLARED")

        if stage == "completed" and t.get("blocked_by"):
            unresolved = [d for d in t["blocked_by"]
                          if next((x for x in tickets if x.get("id") == d), {}).get("_stage") not in DONE]
            if unresolved:
                warns.append(f"{tid}: completed but blocked_by {unresolved} is not")

        body = (t.get("_body") or "").lower()
        for phrase in ("as discussed", "as we agreed", "see above", "per our conversation"):
            if phrase in body:
                warns.append(f"{tid}: body says '{phrase}' — the conversation "
                             f"will not exist when this is picked up")

    for tid, paths in seen.items():
        if len(paths) > 1:
            errs.append(f"{tid}: duplicated across {', '.join(paths)}")

    startable = [t for t in tickets if t["_stage"] in WORKABLE
                 and all(next((x for x in tickets if x.get("id") == d), {}).get("_stage") in RESOLVING
                         for d in (t.get("blocked_by") or []))]
    for i, a in enumerate(startable):
        for b in startable[i + 1:]:
            clash = {x for x in (a.get("touches") or [])
                     for y in (b.get("touches") or []) if overlap(x, y)}
            if clash:
                errs.append(f"{a['id']} and {b['id']} are both startable and both "
                            f"touch {sorted(clash)} — add a blocked_by or merge them")
            # Shared append-mostly files are touched by nearly every ticket; hard
            # collisions there would serialise everything, so they are warnings.
            soft = {x for x in (a.get("appends") or [])
                    for y in (b.get("appends") or []) if overlap(x, y)}
            if soft:
                warns.append(f"{a['id']} and {b['id']} both append to {sorted(soft)} "
                             f"— expect a small merge, not a conflict")

    for e in errs:
        print(f"  ERROR  {e}")
    for w in warns:
        print(f"  warn   {w}")
    # Shadows excluded so this total agrees with board()'s.
    real = [t for t in tickets if not t.get("_shadow")]
    print(f"\n{len(real)} tickets, {len(errs)} errors, {len(warns)} warnings")
    return 1 if errs else 0


def compute_epic_rollup(tickets):
    """epic key -> {title, status}, derived ONLY from the children present in
    `tickets` right now. Status rules are tickets-protocol/SKILL.md's:
      - all children Done/Cancelled  -> Epic Done
      - any child In Progress/Done   -> Epic In Progress
      - else                          -> Epic To Do

    One real limitation, inherent to the one-JQL-fetch-per-invocation
    contract this file already documents (JIRA_JQL excludes Completed/
    Cancelled): a child that finished is invisible here unless it happens to
    also be a shadow (a blocked_by target — see _jira_shadow_for_blocker),
    which is rare and not general epic coverage. So "Done" essentially never
    fires from live data; an epic whose open children have all finished
    simply stops appearing in this rollup at all (it has no visible
    children this run), rather than being reported wrongly as Done. Treat
    "In Progress"/"To Do" here as accurate for VISIBLE children, and silence
    on an epic as "nothing open under it right now", not as "Done"."""
    rollup = {}
    for t in tickets:
        if t.get("_shadow"):
            continue
        epic = t.get("epic")
        if not epic or not epic.get("key"):
            continue
        entry = rollup.setdefault(epic["key"], {"title": epic.get("title") or "", "stages": []})
        entry["stages"].append(t["_stage"])
    for entry in rollup.values():
        stages = entry["stages"]
        if all(s in DONE for s in stages):
            entry["status"] = "Done"
        elif any(s in DONE or s in ("in-progress", "awaiting-deployment") for s in stages):
            entry["status"] = "In Progress"
        else:
            entry["status"] = "To Do"
    return rollup


def epic_label(t, rollup):
    """Trailing per-ticket string for board()/waves()/next() output. Empty
    for a shadow stand-in or for a ticket whose source never carries epic
    data at all (the filesystem source has no epic concept). Otherwise: the
    assigned epic + its rolled-up status, or an explicit orphan flag when
    the ticket has no parent in Jira."""
    if t.get("_shadow") or "epic" not in t or t.get("_is_epic"):
        return ""
    epic = t.get("epic")
    if not epic:
        return "  orphan: no epic link in Jira"
    key = epic["key"]
    title = epic.get("title") or ""
    status = rollup.get(key, {}).get("status", "unknown")
    return f"  epic {key} ({status}){(' ' + title) if title else ''}"


def _claims(t, landing):
    """The paths a ticket claims for a wave slot. Under `serial` landing only
    `touches` claims one; under `parallel` an `appends` path does too, because
    no lock serialises the merges that made appending safe."""
    paths = list(t.get("touches") or [])
    if landing == "parallel":
        paths += list(t.get("appends") or [])
    return paths


def _plan_waves(tickets, landing="serial"):
    """Group the dispatchable tickets into waves, without printing anything.
    Returns {waves, stalled, unresolvable, no_progress, deferred_ids, by_id}.
    waves() renders this and preflight() counts it, so the two can never
    disagree about what a wave is."""
    by_id = {t["id"]: t for t in tickets if t.get("id")}
    # Deferred tickets are dropped from `pending` so they never count as a
    # stalled dependency; their ids stay in by_id so dependents still resolve.
    deferred_ids = {t["id"] for t in tickets if is_deferred(t)}
    # Epics and executor-less tickets are excluded the same way: never
    # dispatched, but still real nodes in by_id for blocked_by resolution.
    pending = [t for t in tickets
               if t["_stage"] in WORKABLE and not is_deferred(t) and not t.get("_is_epic")
               and has_executor(t)]

    def resolved(dep):
        return by_id.get(dep, {}).get("_stage") in RESOLVING

    remaining = list(pending)
    done = {t["id"] for t in tickets if t["_stage"] in DONE}
    plan, stalled, unresolvable, no_progress = [], [], [], False

    while remaining:
        ready = [t for t in remaining
                 if all(d in done or resolved(d) for d in (t.get("blocked_by") or []))]
        if not ready:
            # Two stuck cases are distinguished here and print differently in
            # waves(): a real cycle (exit 1) vs blocked only by a deferral
            # (exit 0). Fixpoint, since deferral is transitive.
            blocked_via_deferral = set()
            changed = True
            while changed:
                changed = False
                for t in remaining:
                    if t["id"] in blocked_via_deferral:
                        continue
                    unresolved = [d for d in (t.get("blocked_by") or [])
                                  if d not in done and not resolved(d)]
                    if unresolved and all(d in deferred_ids or d in blocked_via_deferral
                                           for d in unresolved):
                        blocked_via_deferral.add(t["id"])
                        changed = True

            unresolvable = [t for t in remaining if t["id"] not in blocked_via_deferral]
            if not unresolvable:
                stalled = list(remaining)
            break

        wave, deferred, claimed = [], [], []
        # Sort by numeric id so the first-come tie-break does not depend on
        # the source's iteration order (files ascending, Jira newest-first).
        ready = sorted(ready, key=lambda t: _numeric_id(t["id"]))
        for t in ready:
            paths = _claims(t, landing)
            if any(overlap(p, c) for p in paths for c in claimed):
                deferred.append(t)
            else:
                wave.append(t)
                claimed.extend(paths)

        plan.append(wave)
        if not wave:
            no_progress = True
            break
        for t in wave:
            done.add(t["id"])
        remaining = deferred + [t for t in remaining if t not in wave and t not in deferred]

    return {"waves": plan, "stalled": stalled, "unresolvable": unresolvable,
            "no_progress": no_progress, "deferred_ids": deferred_ids, "by_id": by_id}


def waves(tickets, root, landing="serial"):
    rollup = compute_epic_rollup(tickets)
    plan = _plan_waves(tickets, landing)
    by_id, deferred_ids = plan["by_id"], plan["deferred_ids"]

    for wave_no, wave in enumerate(plan["waves"], 1):
        agents = [t for t in wave if t.get("executor") == "agent"]
        print(f"\nWave {wave_no} — {len(wave)} ticket(s), "
              f"{len(agents)} agent-workable in parallel")
        for t in wave:
            mark = {"agent": "  ", "human": " *", "mixed": " ~"}.get(t.get("executor"), " ?")
            print(f" {mark} {t['id']}  {t.get('title','')}{epic_label(t, rollup)}")
        if agents:
            print("\n    worktrees:")
            for t in agents:
                print(f"      git worktree add ../wt-{t['id'].lower()} -b {t['id'].lower()}")

    if plan["no_progress"]:
        print("  no progress possible")
        return 1
    if plan["unresolvable"]:
        print("  cycle or unresolvable dependency among: "
              + ", ".join(t["id"] for t in plan["unresolvable"]))
        return 1

    if plan["stalled"]:
        print("\nBlocked by a deferred dependency (not a cycle — resolves once "
              "the date passes):")
        for t in plan["stalled"]:
            direct = [d for d in (t.get("blocked_by") or []) if d in deferred_ids]
            if direct:
                labels = ", ".join(
                    f"{d} until {by_id[d].get('defer_until')}" for d in direct)
                print(f"    {t['id']}  {t.get('title','')}  blocked by deferred {labels}")
            else:
                print(f"    {t['id']}  {t.get('title','')}  blocked transitively "
                      f"via a deferred dependency")

    print("\n  * needs a human   ~ agent works it, human finishes it")
    return 0


def _decl_paths(t):
    """Every path a ticket declares, paired with the field it was declared in."""
    return ([(p, "touches") for p in (t.get("touches") or [])]
            + [(p, "appends") for p in (t.get("appends") or [])])


_GLOB_META = re.compile(r"[*?\[]")


def _hotspot_key(x, y):
    """One heading for a colliding glob pair: the more literal side, so
    `reference/*` and `reference/issues.py` read as one hotspot, not two."""
    xg, yg = bool(_GLOB_META.search(x)), bool(_GLOB_META.search(y))
    if xg != yg:
        return y if xg else x
    return min(x, y)


def startable_now(tickets):
    """The tickets a dispatcher could hand out right now — wave 1 as it would
    be if nothing collided. Same exclusions waves() applies (a deferred, epic,
    or executor-less ticket is never dispatched) plus every blocked_by already
    resolved."""
    by_id = {t["id"]: t for t in tickets if t.get("id")}
    done = {t["id"] for t in tickets if t["_stage"] in DONE}
    return [t for t in tickets
            if t["_stage"] in WORKABLE and not is_deferred(t)
            and not t.get("_is_epic") and has_executor(t)
            and all(d in done or by_id.get(d, {}).get("_stage") in RESOLVING
                    for d in (t.get("blocked_by") or []))]


def preflight(tickets, root, landing="serial"):
    """Report every file two or more startable tickets would write, before the
    wave is dispatched rather than after the pull requests go DIRTY. Returns 0
    when nothing collides under `landing`, 1 when something does, and 2 when
    no wave plan exists at all — so a caller can tell "collisions found" from
    "the planner broke"."""
    ready = startable_now(tickets)

    hotspots = {}
    for i, a in enumerate(ready):
        for b in ready[i + 1:]:
            for x, kx in _decl_paths(a):
                for y, ky in _decl_paths(b):
                    if not overlap(x, y):
                        continue
                    h = hotspots.setdefault(
                        _hotspot_key(x, y),
                        {"ids": set(), "kinds": set(), "hard": False})
                    h["ids"].update((a["id"], b["id"]))
                    h["kinds"].update((kx, ky))
                    if kx == "touches" and ky == "touches":
                        h["hard"] = True

    plans = {}
    for mode in ("serial", "parallel"):
        p = _plan_waves(tickets, mode)
        if p["unresolvable"] or p["no_progress"]:
            stuck = ", ".join(t["id"] for t in p["unresolvable"]) or "(no progress)"
            print(f"issues.py: no {mode} wave plan — cycle or unresolvable "
                  f"dependency among: {stuck}", file=sys.stderr)
            return 2
        plans[mode] = p

    print(f"preflight — {len(ready)} startable ticket(s), landing={landing}")
    collisions = 0
    for key in sorted(hotspots):
        h = hotspots[key]
        # A touches overlap collides under either landing path. Anything
        # reached through `appends` collides only when nothing serialises the
        # merges — which is the whole distinction this verb exists to make.
        blocking = h["hard"] or landing == "parallel"
        collisions += 1 if blocking else 0
        kinds = "+".join(sorted(h["kinds"]))
        ids = ", ".join(sorted(h["ids"], key=_numeric_id))
        print(f"  {'COLLISION' if blocking else 'warn     '}  {key}  "
              f"via {kinds} — {ids}")
    if not hotspots:
        print("  no file is written by more than one startable ticket")

    print(f"\n  waves: {len(plans['serial']['waves'])} under serial landing, "
          f"{len(plans['parallel']['waves'])} under parallel")
    print(f"\n{len(hotspots)} shared file(s), {collisions} collision(s) under "
          f"{landing} landing")
    return 1 if collisions else 0


def board(tickets, root):
    # Unknown stages are appended after the fixed STAGES order, so board() shows
    # everything without reordering the familiar output.
    tickets = [t for t in tickets if not t.get("_shadow")]
    rollup = compute_epic_rollup(tickets)
    # Epics get their own heading, with the same status epic_label() shows.
    epics = [t for t in tickets if t.get("_is_epic")]
    tickets = [t for t in tickets if not t.get("_is_epic")]
    extra_stages = sorted(set(t["_stage"] for t in tickets) - set(STAGES))
    for stage in STAGES + extra_stages:
        rows = [t for t in tickets if t["_stage"] == stage]
        if not rows:
            continue
        print(f"\n{stage}  ({len(rows)})")
        for t in sorted(rows, key=lambda x: x.get("id", "")):
            if not has_executor(t):
                ex = "  [?] not startable: no executor"
            else:
                ex = {"agent": "", "human": "  [human]", "mixed": "  [mixed]"}.get(t.get("executor"), "")
            blocked = t.get("blocked_by") or []
            b = f"  blocked_by {','.join(blocked)}" if blocked and stage in PENDING else ""
            defer = f"  deferred until {t['defer_until']}" if is_deferred(t) else ""
            print(f"  {t.get('id','?'):<10} {t.get('title','')}{ex}{b}{defer}{epic_label(t, rollup)}")

    if epics:
        print(f"\nEpics  ({len(epics)})")
        for t in sorted(epics, key=lambda x: x.get("id", "")):
            # No rollup entry means no visible child this fetch — NOT evidence
            # the epic is Done; JIRA_JQL excludes Completed/Cancelled.
            status = rollup.get(t["id"], {}).get("status", "unknown (no visible children this run)")
            print(f"  {t.get('id','?'):<10} {t.get('title','')}  [{status}]")
    tickets = tickets + epics
    print(f"\n{len(tickets)} total")
    return 0


def nxt(tickets, root):
    by_id = {t["id"]: t for t in tickets if t.get("id")}
    rollup = compute_epic_rollup(tickets)
    out = []
    for t in tickets:
        if t["_stage"] not in WORKABLE:
            continue
        if is_deferred(t):
            continue
        if t.get("_is_epic"):
            continue
        if not has_executor(t):
            continue
        if all(by_id.get(d, {}).get("_stage") in RESOLVING for d in (t.get("blocked_by") or [])):
            out.append(t)
    if not out:
        print("nothing startable — every open ticket is blocked")
        return 0
    for t in sorted(out, key=lambda x: (x.get("executor") or "", x.get("id", ""))):
        print(f"  [{t.get('executor') or '?':<5}] {t.get('id'):<10} {t.get('title','')}{epic_label(t, rollup)}")
    return 0


CMDS = {"lint": lint, "waves": waves, "board": board, "next": nxt,
        "preflight": preflight}
# Commands that take --landing. Everything else rejects the flag rather than
# accepting it and quietly planning for the wrong landing path.
LANDING_CMDS = ("waves", "preflight")


def _no_executor_fixture():
    """Two in-memory tickets in the ticket shape load_files()/load_jira()
    both produce: one with executor unset (title/body only, no executor
    custom field — the shape a ticket captured from a chat conversation
    tends to have), one a normal control with executor set. Built by hand
    rather than round-tripped through a file or Jira JSON so the check
    exercises nxt()/waves()/board() directly and has no external
    dependency."""
    base = {
        "created": "2026-01-01", "updated": "2026-01-01", "tags": [],
        "blocked_by": [], "human_steps": [], "appends": [], "epic": None,
        "defer_until": None, "_is_epic": False, "_body": "",
    }
    no_exec = dict(base, id="ZZ-900", title="captured with no executor",
                   executor=None, touches=["scratch/zz900/*"], verify="true",
                   _path="ZZ-900", _stage="open")
    control = dict(base, id="ZZ-901", title="normal agent ticket",
                   executor="agent", touches=["scratch/zz901/*"], verify="true",
                   _path="ZZ-901", _stage="open")
    return [no_exec, control]


def _done_status_fixture():
    """A ticket whose Jira status is the template's `Done` (not `Completed`)
    plus a shadow stand-in (see _jira_shadow_for_blocker), the shape
    load_jira() actually produces when a blocked_by target is excluded from
    the fetch. Exercises two things found together on 2026-09-11: `Done`
    must map to the `completed` stage, and lint()'s summary count must
    exclude the shadow the same way board()'s total already does — the two
    disagreed by exactly the shadow count before this fixture existed."""
    base = {
        "created": "2026-01-01", "updated": "2026-01-01", "tags": [],
        "blocked_by": [], "human_steps": [], "appends": [], "epic": None,
        "defer_until": None, "_is_epic": False, "_body": "",
    }
    done = dict(base, id="ZZ-902", title="closed via template's Done status",
                executor="agent", touches=["scratch/zz902/*"], verify="true",
                _path="ZZ-902", _stage=JIRA_STATUS_TO_STAGE["Done"])
    shadow = {
        "id": "ZZ-903", "title": "", "created": "", "updated": "",
        "tags": [], "blocked_by": [], "touches": [], "verify": "",
        "human_steps": [], "appends": [], "executor": None, "epic": None,
        "defer_until": None, "_path": "ZZ-903", "_stage": "completed",
        "_body": "", "_shadow": True,
    }
    return [done, shadow]


def selftest():
    """Fixture-based checks, no <dir>, Jira, or network access needed:
    1. a ticket captured with only a title/description and no executor set
       must never land in `next` or a wave.
    2. a Jira `Done` status lands in the `completed` stage, and lint()'s
       "N tickets" summary agrees with board()'s "N total" once a shadow
       stand-in is in play (see _done_status_fixture).
    Prints PASS/FAIL and returns an exit code."""
    import io
    import contextlib

    def capture(fn, tickets, *args):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            fn(tickets, *args)
        return buf.getvalue()

    failures = []

    tickets = _no_executor_fixture()
    next_out = capture(nxt, tickets, "selftest")
    waves_out = capture(waves, tickets, "selftest")
    board_out = capture(board, tickets, "selftest")

    if "ZZ-900" in next_out:
        failures.append("next: no-executor ticket ZZ-900 appeared in `next` output")
    if "ZZ-901" not in next_out:
        failures.append("next: control ticket ZZ-901 (has executor) missing from `next`")
    if "ZZ-900" in waves_out:
        failures.append("waves: no-executor ticket ZZ-900 appeared in a wave")
    if "ZZ-901" not in waves_out:
        failures.append("waves: control ticket ZZ-901 missing from wave output")

    board_line = next((l for l in board_out.splitlines() if "ZZ-900" in l), None)
    if board_line is None:
        failures.append("board: no-executor ticket ZZ-900 missing from board output")
    else:
        if "[?]" not in board_line:
            failures.append(f"board: ZZ-900 row missing '[?]' marker: {board_line!r}")
        if "not startable: no executor" not in board_line:
            failures.append(f"board: ZZ-900 row missing 'not startable: no executor': {board_line!r}")

    done_tickets = _done_status_fixture()
    done_ticket = next(t for t in done_tickets if t["id"] == "ZZ-902")
    if done_ticket["_stage"] != "completed":
        failures.append(f"Done status mapped to stage '{done_ticket['_stage']}', not 'completed'")

    lint_out = capture(lint, done_tickets, "selftest")
    board_out2 = capture(board, done_tickets, "selftest")
    lint_count = next((int(l.split()[0]) for l in lint_out.splitlines()
                        if l.strip().endswith("errors, 0 warnings") or " tickets, " in l), None)
    board_count = next((int(l.split()[0]) for l in board_out2.splitlines()
                         if l.strip().endswith(" total")), None)
    if lint_count != board_count:
        failures.append(f"lint reports {lint_count} tickets but board reports "
                         f"{board_count} total — shadow stand-in counted inconsistently")

    failures.extend(_scope_selftest())
    failures.extend(_jira_fixture_selftest())
    failures.extend(_notes_md_selftest())
    failures.extend(_preflight_selftest())

    if failures:
        print("SELFTEST FAILED")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("SELFTEST OK — no-executor ticket excluded from next/waves, "
          "flagged [?] not startable: no executor in board; Done status "
          "maps to completed; lint/board ticket counts agree; scope "
          "classifies touches/appends/UNDECLARED and exits 0/1/2; "
          "awaiting-deployment is not dispatched but still resolves a "
          "blocked_by; a cross-project blocker is external, not missing; "
          "a comma-separated touches line is rejected; load_files excludes "
          "a .notes.md suffix but not a notes-in-slug id; a shared `appends` "
          "file splits a wave under --landing parallel and only warns under "
          "serial, and preflight exits 0/1/2")
    return 0


FIXTURES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "tests", "fixtures")


def _jira_fixture_selftest():
    """The three jira-mode defects of WO-021, each against a fixture derived
    from a captured /rest/api/3 response rather than hand-typed. Offline:
    load_jira() reads the file and never runs the jira-api wrapper."""
    import io
    import contextlib

    def capture(fn, tickets):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            code = fn(tickets, "selftest")
        return code, buf.getvalue()

    failures = []

    def load(name):
        path = os.path.join(FIXTURES, name)
        if not os.path.exists(path):
            failures.append(f"fixture missing: {path}")
            return None
        return load_jira(None, path)

    tickets = load("awaiting-deployment.json")
    if tickets:
        _, next_out = capture(nxt, tickets)
        _, waves_out = capture(waves, tickets)
        _, board_out = capture(board, tickets)
        if "PROJ-42" in next_out:
            failures.append("next: awaiting-deployment PROJ-42 is startable")
        if "PROJ-42" in waves_out:
            failures.append("waves: awaiting-deployment PROJ-42 was dispatched")
        if "PROJ-43" not in next_out:
            failures.append("next: open control PROJ-43 missing")
        if "PROJ-44" not in next_out:
            failures.append("next: PROJ-44 stranded behind awaiting-deployment "
                            "PROJ-42, whose code is already merged")
        if "cycle" in waves_out:
            failures.append(f"waves: phantom cycle reported: {waves_out!r}")
        if "PROJ-42" not in board_out:
            failures.append("board: awaiting-deployment PROJ-42 stopped showing")

    tickets = load("cross-project-blocked-by.json")
    if tickets:
        code, lint_out = capture(lint, tickets)
        _, next_out = capture(nxt, tickets)
        if "does not exist" in lint_out:
            failures.append(f"lint: cross-project blocker read as a dangling "
                            f"id: {lint_out!r}")
        if code != 0:
            failures.append(f"lint: cross-project fixture exited {code}, want 0")
        if "PROJ-45" in next_out:
            failures.append("next: PROJ-45 is startable although external "
                            "blocker LAB-227 is In Progress")
        if "PROJ-46" not in next_out:
            failures.append("next: PROJ-46 not startable although external "
                            "blocker LAB-228 is Done")

    tickets = load("comma-separated-touches.json")
    if tickets:
        code, lint_out = capture(lint, tickets)
        if code != 1 or "comma-separated" not in lint_out:
            failures.append(f"lint: comma-separated touches accepted "
                            f"(exit {code}): {lint_out!r}")

    # The narrowing: only ANOTHER project's blocker is taken on its nested
    # status. A same-project non-Done key is still a genuine dangling id.
    same = {"key": "PROJ-99", "fields": {"status": {
        "name": "In Progress", "statusCategory": {"key": "indeterminate"}}}}
    if _jira_shadow_for_blocker(same, {"PROJ"}) is not None:
        failures.append("shadow: a same-project non-Done blocker became a "
                        "shadow instead of a 'does not exist' error")

    return failures


def _scope_selftest():
    """Build a scratch git repo (structurally offline — no network, no
    fixture on disk) with a base commit and a follow-on commit that adds
    one declared file (matches the ticket's touches glob) and one
    undeclared file. Exercises scope()'s three exit codes directly rather
    than mocking git."""
    import io
    import contextlib

    def capture(fn, *args, **kwargs):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            code = fn(*args, **kwargs)
        return code, buf.getvalue()

    failures = []
    ticket = {
        "id": "ZZ-904", "touches": ["scratch/zz904/*"], "appends": [],
    }

    with tempfile.TemporaryDirectory() as repo:
        def git(*args):
            subprocess.run(["git", *args], cwd=repo, check=True,
                            capture_output=True, text=True)

        git("init", "-q")
        git("config", "user.email", "selftest@example.com")
        git("config", "user.name", "selftest")
        os.makedirs(os.path.join(repo, "scratch", "zz904"))
        with open(os.path.join(repo, "scratch", "zz904", "keep.txt"), "w") as f:
            f.write("base\n")
        git("add", "-A")
        git("commit", "-q", "-m", "base")
        git("branch", "base")

        with open(os.path.join(repo, "scratch", "zz904", "keep.txt"), "w") as f:
            f.write("declared change\n")
        with open(os.path.join(repo, "elsewhere.txt"), "w") as f:
            f.write("undeclared change\n")
        git("add", "-A")
        git("commit", "-q", "-m", "work")

        code, _ = capture(scope, "ZZ-904", "base", [dict(ticket, touches=[
            "scratch/zz904/*", "elsewhere.txt",
        ])], cwd=repo)
        if code != 0:
            failures.append(f"scope: all-declared case exited {code}, want 0")

        code, out = capture(scope, "ZZ-904", "base", [ticket], cwd=repo)
        if code != 1:
            failures.append(f"scope: one-undeclared case exited {code}, want 1")
        if "UNDECLARED\telsewhere.txt" not in out:
            failures.append(f"scope: elsewhere.txt not reported UNDECLARED: {out!r}")
        if "touches\tscratch/zz904/keep.txt" not in out:
            failures.append(f"scope: keep.txt not reported touches: {out!r}")

        code, _ = capture(scope, "ZZ-NOPE", "base", [ticket], cwd=repo)
        if code != 2:
            failures.append(f"scope: unknown-ticket case exited {code}, want 2")

        code, _ = capture(scope, "ZZ-904", "no-such-ref", [ticket], cwd=repo)
        if code != 2:
            failures.append(f"scope: unresolved-ref case exited {code}, want 2")

    return failures


def _notes_md_selftest():
    """load_files() must exclude a `<id>.notes.md` progress note by suffix
    (see `[FILE-4]`, WO-046) without swallowing a ticket whose slug merely
    contains "notes". Built as real files on disk, since this exercises the
    glob in load_files() directly rather than the in-memory ticket shape the
    other fixtures use."""
    failures = []
    minimal = ("---\nid: {id}\ntitle: {id} fixture\ncreated: 2026-01-01\n"
               "updated: 2026-01-01\nexecutor: agent\ntouches:\n  - x\n"
               "verify: |\n  true\n---\n")

    with tempfile.TemporaryDirectory() as root:
        stage_dir = os.path.join(root, "open")
        os.makedirs(stage_dir)
        with open(os.path.join(stage_dir, "T-001-thing.md"), "w") as f:
            f.write(minimal.format(id="T-001"))
        with open(os.path.join(stage_dir, "T-001.notes.md"), "w") as f:
            f.write("## 2026-01-01\nprogress note, no frontmatter\n")
        with open(os.path.join(stage_dir, "T-009-notes-format.md"), "w") as f:
            f.write(minimal.format(id="T-009"))

        ids = sorted(t.get("id") for t in load_files(root))
        if ids != ["T-001", "T-009"]:
            failures.append(f"load_files: expected ids ['T-001', 'T-009'], "
                             f"got {ids} — .notes.md suffix exclusion or "
                             f"notes-in-slug loading is broken")
    return failures


def _preflight_fixture(hard=False):
    """The 2026-09-19 wave in miniature: three tickets that touch different
    files and all append one shared `docs/decisions.md`. Serial landing packs
    them into a single wave and the shared append is a small merge; parallel
    landing has no lock, so the first merge wins and the rest go DIRTY. With
    hard=True a fourth ticket collides on `touches` instead, which is a
    collision under either landing path."""
    base = {"created": "2026-01-01", "updated": "2026-01-01", "tags": [],
            "blocked_by": [], "human_steps": [], "epic": None,
            "defer_until": None, "_is_epic": False, "_body": "",
            "executor": "agent", "verify": "true", "_stage": "open"}

    def t(n, touches, appends):
        return dict(base, id=f"ZZ-{n}", title=f"preflight fixture {n}",
                    _path=f"ZZ-{n}", touches=touches, appends=appends)

    out = [t(910, ["reference/a.py"], ["docs/decisions.md"]),
           t(911, ["reference/b.py"], ["docs/decisions.md"]),
           t(912, ["reference/c.py"], ["docs/decisions.md"])]
    if hard:
        out.append(t(913, ["reference/a.py"], []))
    return out


def _preflight_selftest():
    """WO-041: a shared `appends` path is benign only because landing is
    serialized, and the planner has to be told which landing path a wave will
    use instead of assuming the safe one."""
    import io
    import contextlib
    failures = []

    def run(fn, tickets, **kw):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            code = fn(tickets, "selftest", **kw)
        return code, buf.getvalue()

    soft = _preflight_fixture()
    s, p = _plan_waves(soft, "serial"), _plan_waves(soft, "parallel")

    if len(s["waves"]) != 1:
        failures.append(f"waves: serial landing put three appenders into "
                        f"{len(s['waves'])} waves, want 1 (today's behaviour)")
    if len(p["waves"]) <= len(s["waves"]):
        failures.append(f"waves: parallel landing did not split a shared "
                        f"`appends` file — {len(p['waves'])} waves vs "
                        f"{len(s['waves'])} serial")
    if p["waves"] and len(p["waves"][0]) != 1:
        failures.append(f"waves: parallel wave 1 holds {len(p['waves'][0])} "
                        f"tickets that all append one file, want 1")
    if (sorted(t["id"] for w in s["waves"] for t in w)
            != sorted(t["id"] for w in p["waves"] for t in w)):
        failures.append("waves: landing mode changed WHICH tickets are "
                        "scheduled, not just when — it must only reorder")

    code, out = run(preflight, soft, landing="serial")
    if code != 0:
        failures.append(f"preflight: serial landing exited {code} on an "
                        f"appends-only overlap, want 0 (a warning)")
    if "docs/decisions.md" not in out:
        failures.append(f"preflight: serial run did not name the shared "
                        f"file: {out!r}")
    if "COLLISION" in out:
        failures.append(f"preflight: serial run called an appends overlap a "
                        f"COLLISION: {out!r}")

    code, out = run(preflight, soft, landing="parallel")
    if code != 1:
        failures.append(f"preflight: parallel landing exited {code} on an "
                        f"appends overlap, want 1")
    hot = next((l for l in out.splitlines() if "docs/decisions.md" in l), "")
    if "COLLISION" not in hot:
        failures.append(f"preflight: docs/decisions.md not flagged COLLISION "
                        f"under parallel landing: {out!r}")
    missing = [i for i in ("ZZ-910", "ZZ-911", "ZZ-912") if i not in hot]
    if missing:
        failures.append(f"preflight: hotspot line omits {missing}: {hot!r}")
    if "under serial landing" not in out or "under parallel" not in out:
        failures.append(f"preflight: wave count under each landing mode not "
                        f"reported: {out!r}")

    code, out = run(preflight, _preflight_fixture(hard=True), landing="serial")
    if code != 1:
        failures.append(f"preflight: a `touches` overlap exited {code} under "
                        f"serial landing, want 1")
    if "via touches —" not in out:
        failures.append(f"preflight: touches overlap not labelled "
                        f"'via touches': {out!r}")

    cyc = [dict(soft[0], blocked_by=["ZZ-911"]), dict(soft[1], blocked_by=["ZZ-910"])]
    buf = io.StringIO()
    with contextlib.redirect_stderr(buf):
        code, _ = run(preflight, cyc, landing="serial")
    if code != 2:
        failures.append(f"preflight: an unresolvable dependency exited "
                        f"{code}, want 2 — 'the planner broke' must not read "
                        f"as 'collisions found'")
    return failures


def parse_args(argv):
    """issues.py <cmd> [dir] [--source files|jira] [--jira-api PATH]
    [--jira-project KEY] [--fixture PATH]. Flags may appear in any order
    after the command; the first bare positional is the directory (files
    source only). `selftest` takes no directory and ignores
    --source/--jira-api/--jira-project/--fixture.

    `scope <ticket-id> <base-ref> [<dir>|--source jira]` takes two leading
    positionals instead of one: the ticket id, then the base ref for
    `git diff --name-only <base-ref>...HEAD`. A third positional (files
    source only) is the ticket directory, same as every other command — it
    is where tickets are loaded from, and is NOT a git repo, so it is never
    used as `git diff`'s cwd.

    `--repo PATH` (scope only) is the checkout `git diff` runs in and whose
    basename scopes the `<repo>/` prefix stripped from touches/appends
    before matching. Defaults to the current directory when omitted, so
    `issues.py scope <id> <base-ref>` run from inside the repo being
    reviewed needs no flag.

    `--landing serial|parallel` applies to `waves` and `preflight`; any other
    command rejects it rather than planning for a landing path it does not
    use. `--help` prints this and exits 0, so the flag list is discoverable
    without reading the file."""
    if len(argv) > 1 and argv[1] in ("-h", "--help", "help"):
        print(__doc__)
        sys.exit(0)
    if len(argv) < 2 or (argv[1] not in CMDS and argv[1] not in ("selftest", "scope")):
        print(__doc__)
        sys.exit(2)
    cmd = argv[1]
    rest = argv[2:]

    source = os.environ.get("ISSUES_SOURCE", "files")
    jira_api = os.environ.get("ISSUES_JIRA_API")
    fixture = None
    landing = "serial"
    repo_path = None
    positional = []

    i = 0
    while i < len(rest):
        a = rest[i]
        if a == "--source":
            if i + 1 >= len(rest):
                die("--source needs a value (files or jira)")
            source = rest[i + 1]
            i += 2
        elif a == "--jira-api":
            if i + 1 >= len(rest):
                die("--jira-api needs a path")
            jira_api = rest[i + 1]
            i += 2
        elif a == "--jira-project":
            if i + 1 >= len(rest):
                die("--jira-project needs a value (e.g. PROJ)")
            global JIRA_PROJECT_KEY, JIRA_JQL
            JIRA_PROJECT_KEY = rest[i + 1]
            JIRA_JQL = _jira_jql(JIRA_PROJECT_KEY)
            i += 2
        elif a == "--fixture":
            if i + 1 >= len(rest):
                die("--fixture needs a path")
            fixture = rest[i + 1]
            i += 2
        elif a == "--landing":
            if i + 1 >= len(rest):
                die("--landing needs a value (serial or parallel)")
            landing = rest[i + 1]
            i += 2
        elif a == "--repo":
            if i + 1 >= len(rest):
                die("--repo needs a path")
            repo_path = rest[i + 1]
            i += 2
        elif a in ("-h", "--help"):
            print(__doc__)
            sys.exit(0)
        else:
            positional.append(a)
            i += 1

    if source not in ("files", "jira"):
        die(f"--source must be 'files' or 'jira' (got '{source}')")

    if landing not in ("serial", "parallel"):
        die(f"--landing must be 'serial' or 'parallel' (got '{landing}')")
    if landing != "serial" and cmd not in LANDING_CMDS:
        die(f"--landing applies to {' and '.join(LANDING_CMDS)} only, not '{cmd}'")
    if repo_path is not None and cmd != "scope":
        die(f"--repo applies to scope only, not '{cmd}'")

    if cmd == "scope":
        if len(positional) < 2:
            print(__doc__)
            sys.exit(2)
        ticket_id, base_ref = positional[0], positional[1]
        root = positional[2].rstrip("/") if len(positional) > 2 else None
        if source == "files" and not root:
            print(__doc__)
            sys.exit(2)
        return cmd, source, root, jira_api, fixture, landing, (ticket_id, base_ref), repo_path

    root = positional[0].rstrip("/") if positional else None
    if cmd != "selftest" and source == "files" and not root:
        print(__doc__)
        sys.exit(2)

    return cmd, source, root, jira_api, fixture, landing, None, repo_path


def main(argv):
    cmd, source, root, jira_api, fixture, landing, scope_args, repo_path = parse_args(argv)
    if cmd == "selftest":
        return selftest()
    if source == "jira":
        tickets = load_jira(jira_api, fixture)
        label = root or f"jira:{JIRA_PROJECT_KEY}"
    else:
        tickets = load_files(root)
        label = root
    if cmd == "scope":
        ticket_id, base_ref = scope_args
        # cwd is the checkout git diff runs in: --repo when given, else the
        # process's own cwd. NEVER `root` -- in files mode that is the
        # ticket directory (e.g. ~/code/issues), which is not a git repo
        # and made every `scope` call here exit 128.
        return scope(ticket_id, base_ref, tickets, cwd=repo_path)
    if cmd in LANDING_CMDS:
        return CMDS[cmd](tickets, label, landing=landing)
    return CMDS[cmd](tickets, label)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
