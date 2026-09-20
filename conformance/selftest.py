#!/usr/bin/env python3
"""Fixture checks for validate.py, run as `validate.py --selftest`.

This is what makes the validator trustworthy rather than merely present: it
asserts that every mechanically checkable MUST has a negative fixture, that
each fixture fails exactly the requirement its directory name declares, and
that nothing in SPEC.md has moved ahead of the checks without saying so.
"""
import io
import re
import sys
from pathlib import Path

from validate import CHECKS, PROFILES, SOURCE_DISPOSITION, UNCHECKABLE, parse_spec, run

FIXTURE_RE = re.compile(r"^violates-MUST-(\d+)(?:-.*)?$")


class Results:
    def __init__(self):
        self.failures = 0
        self.total = 0

    def check(self, ok, label, detail=""):
        self.total += 1
        if ok:
            print(f"ok   {label}")
        else:
            self.failures += 1
            print(f"FAIL {label}{': ' + detail if detail else ''}")


def _validate(set_dir, profile, spec_path, version_path, source="file"):
    sink = io.StringIO()
    kwargs = {"source": source, "fixture": set_dir} if source == "jira" else {}
    rc, rows = run(None if source == "jira" else set_dir, profile, spec_path, version_path,
                   quiet=True, out=sink, err=sink, **kwargs)
    failed = [r[0] for r in rows if r[2] == "FAIL"]
    reported = [r[0] for r in rows if r[2] == "report"]
    unchecked = [r[0] for r in rows if r[2] == "UNCHECKED"]
    return rc, failed, reported, unchecked, sink.getvalue()


def _inventory(res, reqs):
    for kind in ("MUST", "SHOULD"):
        nums = sorted(r.num for r in reqs if r.kind == kind)
        expected = list(range(1, len(nums) + 1))
        res.check(nums == expected, f"SPEC.md {kind} identifiers are contiguous from 1",
                  f"got {nums[:5]}...{nums[-3:]}")
    undisposed = [r.key for r in reqs if r.key not in CHECKS and r.key not in UNCHECKABLE]
    res.check(not undisposed, "every requirement has a check or a recorded reason for not having one",
              f"missing: {undisposed}")
    stale = [k for k in list(CHECKS) + list(UNCHECKABLE) if k not in {r.key for r in reqs}]
    res.check(not stale, "no check names a requirement SPEC.md does not contain", f"stale: {stale}")


def _fixture_coverage(res, fixtures, reqs):
    by_key = {r.key: r for r in reqs}
    present = {}
    for path in sorted(fixtures.iterdir()):
        if not path.is_dir():
            continue
        m = FIXTURE_RE.match(path.name)
        if m:
            present[f"MUST-{m.group(1)}"] = path
        elif path.name not in ("conforming", "violates-SHOULD-only", "jira"):
            res.check(False, f"fixture directory '{path.name}' follows the naming convention",
                      "expected conforming/, violates-SHOULD-only/, jira/ or violates-MUST-<n>-<slug>/")

    gating = sorted(k for k in CHECKS if k.startswith("MUST-"))
    missing = [k for k in gating if k not in present]
    res.check(not missing, "every gating MUST check has a negative fixture", f"missing: {missing}")
    orphans = [k for k in present if k not in CHECKS]
    res.check(not orphans, "every negative fixture names a requirement this program checks",
              f"orphans: {orphans}")
    return {k: (v, by_key[k].profile) for k, v in present.items() if k in by_key}


def _jira(res, root, reqs, spec_path, version_path):
    """The Jira binding reads the same specification through recorded API
    responses, so the same two properties must hold there: a conforming set
    passes, and each negative fixture fails exactly the requirement it names."""
    by_key = {r.key: r for r in reqs}
    if not root.is_dir():
        res.check(False, "fixtures/jira/ exists")
        return

    for profile in PROFILES:
        rc, failed, _, unchecked, _ = _validate(
            root / "conforming", profile, spec_path, version_path, source="jira"
        )
        res.check(rc == 0 and not failed,
                  f"fixtures/jira/conforming/ conforms at profile `{profile}`",
                  f"MUST violated: {failed}")
        res.check(not unchecked, f"no requirement is UNCHECKED for jira at profile `{profile}`",
                  f"unchecked: {unchecked}")

    disposed = set(SOURCE_DISPOSITION.get("jira", {}))
    res.check(disposed <= set(CHECKS),
              "every jira disposition names a requirement the file binding checks",
              f"stray: {sorted(disposed - set(CHECKS))}")

    negatives = sorted(p for p in root.iterdir() if p.is_dir() and FIXTURE_RE.match(p.name))
    res.check(bool(negatives), "fixtures/jira/ ships at least one negative fixture")
    for path in negatives:
        key = f"MUST-{FIXTURE_RE.match(path.name).group(1)}"
        if key not in by_key:
            res.check(False, f"{path.name} names a requirement SPEC.md contains")
            continue
        profile = by_key[key].profile
        rc, failed, _, _, _ = _validate(path, profile, spec_path, version_path, source="jira")
        res.check(failed == [key] and rc == 1,
                  f"jira/{path.name} fails exactly {key} at profile `{profile}`",
                  f"gating failures were {failed} (rc {rc})")

    # The body is what issues.py's adapter drops, so prove it survived rather
    # than inferring it from a passing set.
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from jira_source import load_jira_set
    from validate import STAGES
    tickets, _, _, _, _ = load_jira_set(root / "conforming", STAGES)
    bodiless = [t["_where"] for t in tickets if "# " not in (t["_body"] or "")]
    res.check(not bodiless, "every jira ticket carries its description as a Markdown body",
              f"empty or heading-less: {bodiless}")


def selftest(spec_path, version_path):
    here = Path(__file__).resolve().parent
    fixtures = here / "fixtures"
    reqs = parse_spec(spec_path)
    res = Results()

    _inventory(res, reqs)

    if not fixtures.is_dir():
        res.check(False, "conformance/fixtures/ exists")
        print(f"\n{res.total - res.failures}/{res.total} checks passed", file=sys.stdout)
        return 1

    for profile in PROFILES:
        rc, failed, _, unchecked, _ = _validate(
            fixtures / "conforming", profile, spec_path, version_path
        )
        res.check(rc == 0 and not failed, f"fixtures/conforming/ conforms at profile `{profile}`",
                  f"MUST violated: {failed}")
        res.check(not unchecked, f"no requirement is UNCHECKED at profile `{profile}`",
                  f"unchecked: {unchecked}")

    for key, (path, profile) in sorted(_fixture_coverage(res, fixtures, reqs).items(),
                                       key=lambda kv: int(kv[0].split("-")[1])):
        rc, failed, _, _, _ = _validate(path, profile, spec_path, version_path)
        res.check(failed == [key] and rc == 1,
                  f"{path.name} fails exactly {key} at profile `{profile}`",
                  f"gating failures were {failed} (rc {rc})")

    _jira(res, fixtures / "jira", reqs, spec_path, version_path)

    should_only = fixtures / "violates-SHOULD-only"
    if should_only.is_dir():
        rc, failed, reported, _, _ = _validate(should_only, "full", spec_path, version_path)
        res.check(rc == 0 and not failed, "violates-SHOULD-only/ exits 0 with no MUST violated",
                  f"rc {rc}, failures {failed}")
        res.check(bool(reported), "violates-SHOULD-only/ reports at least one SHOULD finding")
    else:
        res.check(False, "fixtures/violates-SHOULD-only/ exists")

    print(f"\n{res.total - res.failures}/{res.total} selftest checks passed")
    return 1 if res.failures else 0


if __name__ == "__main__":
    root = Path(__file__).resolve().parent.parent
    sys.exit(selftest(root / "SPEC.md", root / "VERSION-spec"))
