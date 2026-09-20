#!/usr/bin/env python3
"""Run minimal-validate.py over every shipped fixture and assert it reaches the
verdict the fixture's name claims.

Each `violates-MUST-N` fixture is validated at the profile SPEC.md gives
MUST-N, read from the requirement's own inline profile token. That token is the
specification's only statement of profile membership, so this harness is also a
test of that design. Exit 0 when every fixture agrees, 1 otherwise.

Usage: sweep.py [--repo-root PATH]
"""

import argparse
import os
import re
import subprocess
import sys

VALIDATOR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "minimal-validate.py")
FIXTURE_RE = re.compile(r"^violates-MUST-(\d+)-")
REQUIREMENT_RE = re.compile(r"^\[MUST-(\d+)\]\s+`(minimal|full|unattended)`", re.M)
FIRED_RE = re.compile(r"^ERROR\s+\[MUST-(\d+)\]", re.M)


def requirement_profiles(spec_path):
    with open(spec_path, encoding="utf-8") as handle:
        return {int(n): p for n, p in REQUIREMENT_RE.findall(handle.read())}


def run(root, profile):
    result = subprocess.run(
        [sys.executable, VALIDATOR, root, "--profile", profile],
        capture_output=True, text=True,
    )
    return result.returncode, sorted({int(n) for n in FIRED_RE.findall(result.stdout)})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    default_root = os.path.abspath(os.path.join(os.path.dirname(VALIDATOR), "..", ".."))
    parser.add_argument("--repo-root", default=default_root)
    args = parser.parse_args()

    spec = os.path.join(args.repo_root, "SPEC.md")
    fixtures = os.path.join(args.repo_root, "conformance", "fixtures")
    profiles = requirement_profiles(spec)
    if not profiles:
        print(f"sweep: no numbered requirements found in {spec}", file=sys.stderr)
        return 1

    failures = []

    code, fired = run(os.path.join(fixtures, "conforming"), "unattended")
    print(f"{'conforming':<44} unattended  rc={code} fired={fired}")
    if code != 0:
        failures.append(f"conforming/ must pass at every profile, fired {fired}")

    should_only = os.path.join(fixtures, "violates-SHOULD-only")
    if os.path.isdir(should_only):
        code, fired = run(should_only, "full")
        print(f"{'violates-SHOULD-only':<44} full        rc={code} fired={fired}")
        if code != 0:
            failures.append(f"violates-SHOULD-only/ must not gate at `full`, fired {fired}")

    for name in sorted(os.listdir(fixtures)):
        match = FIXTURE_RE.match(name)
        if not match:
            continue
        want = int(match.group(1))
        profile = profiles.get(want)
        if profile is None:
            failures.append(f"{name}: SPEC.md carries no MUST-{want}")
            continue
        code, fired = run(os.path.join(fixtures, name), profile)
        print(f"{name:<44} {profile:<11} rc={code} fired={fired}")
        if code == 0:
            failures.append(f"{name}: validator passed a fixture that violates MUST-{want}")
        elif want not in fired:
            failures.append(f"{name}: fired {fired}, never MUST-{want}")
        elif fired != [want]:
            failures.append(f"{name}: fired {fired}, expected only MUST-{want}")

    print()
    if failures:
        for failure in failures:
            print(f"DISAGREEMENT  {failure}")
        print(f"sweep: {len(failures)} fixture(s) disagree with the independent validator")
        return 1
    print("sweep: every fixture reaches the verdict its name claims")
    return 0


if __name__ == "__main__":
    sys.exit(main())
