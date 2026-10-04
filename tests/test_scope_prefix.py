#!/usr/bin/env python3
"""Regression tests for WO-044: scope()'s ~/code-relative repo-name prefix
stripped against a single-repo diff's repo-relative paths.

Stdlib unittest, not pytest: this repo has no dependency manifest yet (see
CLAUDE.md's Dependencies section), so nothing here can assume pytest is
installed. Run directly (`python3 tests/test_scope_prefix.py`) or via
`python3 -m unittest`.
"""
import contextlib
import copy
import io
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "reference"))
import issues  # noqa: E402


class TestStripRepoPrefix(unittest.TestCase):
    def test_strips_leading_repo_component(self):
        self.assertEqual(
            issues._strip_repo_prefix(["work-order/SPEC.md"], "work-order"),
            ["SPEC.md"],
        )

    def test_leaves_other_repo_globs_unchanged(self):
        globs = ["night-watchman/hooks/**"]
        self.assertEqual(issues._strip_repo_prefix(globs, "work-order"), globs)

    def test_no_repo_returns_globs_unchanged(self):
        globs = ["work-order/SPEC.md"]
        self.assertEqual(issues._strip_repo_prefix(globs, None), globs)


class TestOverlapDeclared(unittest.TestCase):
    def setUp(self):
        self.ticket = {
            "touches": ["work-order/SPEC.md", "work-order/plugins/**"],
            "appends": [],
        }

    def test_prefixed_glob_matches_bare_path(self):
        self.assertTrue(issues.overlap_declared(
            self.ticket, "SPEC.md", repo="work-order"))

    def test_prefixed_star_glob_matches_nested_bare_path(self):
        self.assertTrue(issues.overlap_declared(
            self.ticket, "plugins/work-order/README.md", repo="work-order"))

    def test_undeclared_path_is_still_reported(self):
        self.assertFalse(issues.overlap_declared(
            self.ticket, "CHANGELOG.md", repo="work-order"))

    def test_stripping_is_scoped_to_the_named_repo(self):
        self.assertFalse(issues.overlap_declared(
            self.ticket, "SPEC.md", repo="night-watchman"))


class TestScopeCwdArgument(unittest.TestCase):
    """The other WO-044 defect: scope() must diff in an explicit repo
    checkout, never a non-git ticket directory (that was the exit-128 bug).
    """

    def test_scope_signature_takes_repo_and_cwd(self):
        import inspect
        params = inspect.signature(issues.scope).parameters
        self.assertIn("cwd", params)
        self.assertIn("repo", params)


MAIN = ("/code/work-order", ["work-order", "wo-remote"])
NESTED = ("/code/home_thirdparty_workspace/memory-graph", ["memory-graph"])


def strip(glob, ident):
    return issues._strip_repo_prefix([glob], ident)[0]


class TestRepoQualifiers(unittest.TestCase):
    """WO-94: `repo:path` is canonical; `repo/path` strips the same way."""

    def test_colon_form_strips(self):
        self.assertEqual(strip("work-order:SPEC.md", MAIN), "SPEC.md")

    def test_slash_form_strips(self):
        self.assertEqual(strip("work-order/SPEC.md", MAIN), "SPEC.md")

    def test_nested_checkout_prefix_matches_by_path_suffix(self):
        self.assertEqual(strip("home_thirdparty_workspace/memory-graph:ts/src/**", NESTED),
                         "ts/src/**")
        self.assertEqual(strip("memory-graph:ts/src/**", NESTED), "ts/src/**")
        self.assertEqual(strip("home_thirdparty_workspace/memory-graph/ts/**", NESTED),
                         "ts/**")

    def test_remote_repo_name_matches_when_directory_differs(self):
        self.assertEqual(strip("wo-remote:conformance/**", MAIN), "conformance/**")

    def test_plain_path_is_left_alone(self):
        self.assertEqual(strip("docs/**", MAIN), "docs/**")

    def test_branch_like_entry_strips_to_a_glob_that_matches_nothing(self):
        self.assertEqual(strip("memory-graph:upstream-pr-branch", NESTED),
                         "upstream-pr-branch")
        self.assertEqual(strip("memory-graph-fork:upstream-pr-branch", NESTED),
                         "memory-graph-fork:upstream-pr-branch")

    def test_other_repo_prefix_is_not_stripped(self):
        for g in ("other-repo:SPEC.md", "other-repo/SPEC.md"):
            self.assertEqual(strip(g, MAIN), g)

    def test_drive_path_and_url_are_left_alone(self):
        for g in ("C:/foo/**", "C:foo", "https://x.y/z", "work-order://x"):
            self.assertEqual(strip(g, MAIN), g)

    def test_overlap_declared_uses_the_colon_form(self):
        ticket = {"touches": ["work-order:SPEC.md"], "appends": []}
        self.assertTrue(issues.overlap_declared(ticket, "SPEC.md", repo="work-order"))
        self.assertFalse(issues.overlap_declared(ticket, "SPEC.md", repo="night-watchman"))


def _ticket(tid, touches):
    return {"id": tid, "title": tid, "created": "2026-01-01", "updated": "2026-01-01",
            "tags": [], "blocked_by": [], "human_steps": [], "appends": [],
            "epic": None, "defer_until": None, "_is_epic": False, "_body": "",
            "executor": "agent", "_stage": "open", "verify": "true",
            "touches": touches, "_path": tid}


def run_lint(tickets, **kw):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        code = issues.lint(tickets, "selftest", **kw)
    return code, buf.getvalue()


class TestLintSlashWarning(unittest.TestCase):
    def test_slash_form_warns_and_cites_the_requirement(self):
        _, out = run_lint([_ticket("T-1", ["work-order/SPEC.md"])], repo=MAIN)
        self.assertIn("T-1", out)
        self.assertIn("'work-order:SPEC.md'", out)
        self.assertIn("SHOULD-13", out)

    def test_colon_form_and_plain_path_do_not_warn(self):
        _, out = run_lint([_ticket("T-1", ["work-order:SPEC.md"]),
                           _ticket("T-2", ["docs/**"])], repo=MAIN)
        self.assertNotIn("slash", out)

    def test_slash_prefix_of_another_repo_is_a_literal_path(self):
        _, out = run_lint([_ticket("T-1", ["dotfiles:a/**"]),
                           _ticket("T-2", ["dotfiles/b/**"])], repo=MAIN)
        self.assertNotIn("slash", out)

    def test_colon_entry_elsewhere_does_not_make_a_local_directory_a_repo(self):
        code, out = run_lint([_ticket("T-1", ["tools:a/**"]),
                              _ticket("T-2", ["tools/b/**"]),
                              _ticket("T-3", ["tools/a/**"])], repo=MAIN)
        self.assertEqual(code, 0, out)
        self.assertNotIn("slash", out)
        self.assertNotIn("both startable", out)

    def test_output_does_not_depend_on_cwd_or_neighbouring_directories(self):
        tickets = [_ticket("T-1", ["work-order/b/**"]), _ticket("T-2", ["docs/**"]),
                   _ticket("T-3", ["sibling/x/**"])]
        outs = []
        old = os.getcwd()
        try:
            for make_sibling in (False, True):
                with tempfile.TemporaryDirectory() as d:
                    if make_sibling:
                        os.makedirs(os.path.join(d, "sibling", ".git"))
                    os.chdir(d)
                    outs.append(run_lint(copy.deepcopy(tickets), repo=MAIN))
        finally:
            os.chdir(old)
        self.assertEqual(outs[0], outs[1])
        self.assertIn("T-1", outs[0][1])
        self.assertNotIn("T-3", outs[0][1])


class TestLintOverlapAcrossSpellings(unittest.TestCase):
    def test_colon_and_slash_spelling_of_one_path_collide(self):
        code, out = run_lint([_ticket("T-1", ["work-order:SPEC.md"]),
                              _ticket("T-2", ["work-order/SPEC.md"])], repo=MAIN)
        self.assertEqual(code, 1)
        self.assertIn("both startable and both touch", out)

    def test_same_path_in_another_repo_does_not_collide(self):
        code, out = run_lint([_ticket("T-1", ["other-repo:SPEC.md"]),
                              _ticket("T-2", ["SPEC.md"])])
        self.assertEqual(code, 0, out)


if __name__ == "__main__":
    unittest.main()
