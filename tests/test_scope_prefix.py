#!/usr/bin/env python3
"""Regression tests for WO-044: scope()'s ~/code-relative repo-name prefix
stripped against a single-repo diff's repo-relative paths.

Stdlib unittest, not pytest: this repo has no dependency manifest yet (see
CLAUDE.md's Dependencies section), so nothing here can assume pytest is
installed. Run directly (`python3 tests/test_scope_prefix.py`) or via
`python3 -m unittest`.
"""
import os
import sys
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


if __name__ == "__main__":
    unittest.main()
