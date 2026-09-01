"""Tests for scripts/check_changie_length.py — the per-fragment body cap.

Changie has no ``lint`` subcommand; ``.changie.yaml`` ``body.maxLength`` only
guards ``changie new``. This checker re-reads fragment files on disk so
directly-written fragments can't slip past. Scope is strictly
``.changes/unreleased/*.yaml`` — released ``.changes/<version>.md`` files (and
the GitHub release body) are immutable and out of scope.
"""

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

import check_changie_length  # noqa: E402


def unreleased(tmp, name, body, kind="Added"):
    """Write .changes/unreleased/<name>.yaml with the given body; return its path."""
    d = Path(tmp) / ".changes" / "unreleased"
    d.mkdir(parents=True, exist_ok=True)
    p = d / f"{name}.yaml"
    p.write_text(f"kind: {kind}\nbody: {body!r}\ntime: 2026-07-02T00:00:00Z\n")
    return p


class TestChangieLength(unittest.TestCase):
    def test_under_limit_passes(self):
        with tempfile.TemporaryDirectory() as t:
            p = unreleased(t, "Added-1", "short and sweet")
            self.assertEqual(check_changie_length.find_length_issues([str(p)], 200), [])

    def test_at_limit_passes(self):
        # Exactly max_len is allowed; only strictly-greater is a violation.
        with tempfile.TemporaryDirectory() as t:
            p = unreleased(t, "Added-1", "x" * 200)
            self.assertEqual(check_changie_length.find_length_issues([str(p)], 200), [])

    def test_over_limit_flagged(self):
        with tempfile.TemporaryDirectory() as t:
            p = unreleased(t, "Added-1", "x" * 201)
            issues = check_changie_length.find_length_issues([str(p)], 200)
            self.assertEqual(len(issues), 1)
            self.assertIn("201 chars", issues[0])
            self.assertIn("limit 200", issues[0])

    def test_released_md_out_of_scope(self):
        # A released .changes/<version>.md is never linted, even if passed
        # explicitly — it lives in the GitHub release body and is immutable.
        with tempfile.TemporaryDirectory() as t:
            md = Path(t) / ".changes" / "0.13.0.md"
            md.parent.mkdir(parents=True)
            md.write_text("## 0.13.0\n\n* " + "x" * 500 + "\n")
            self.assertEqual(check_changie_length.find_length_issues([str(md)], 200), [])

    def test_non_unreleased_yaml_out_of_scope(self):
        # A .yaml that isn't under .changes/unreleased/ is ignored.
        with tempfile.TemporaryDirectory() as t:
            other = Path(t) / "config.yaml"
            other.write_text("body: " + ("x" * 500) + "\n")
            self.assertEqual(check_changie_length.find_length_issues([str(other)], 200), [])

    def test_scan_mode_finds_unreleased(self):
        # With no explicit paths, scan mode globs .changes/unreleased/*.yaml
        # relative to cwd.
        import os

        with tempfile.TemporaryDirectory() as t:
            unreleased(t, "Added-ok", "fine")
            unreleased(t, "Added-bad", "y" * 300)
            cwd = os.getcwd()
            try:
                os.chdir(t)
                issues = check_changie_length.find_length_issues([], 200)
            finally:
                os.chdir(cwd)
            self.assertEqual(len(issues), 1)
            self.assertIn("Added-bad", issues[0])

    def test_gitkeep_and_empty_skipped(self):
        with tempfile.TemporaryDirectory() as t:
            keep = Path(t) / ".changes" / "unreleased" / ".gitkeep"
            keep.parent.mkdir(parents=True)
            keep.write_text("")
            # .gitkeep has no .yaml suffix -> out of scope; an empty .yaml parses
            # to None -> skipped.
            empty = Path(t) / ".changes" / "unreleased" / "empty.yaml"
            empty.write_text("")
            self.assertEqual(
                check_changie_length.find_length_issues([str(keep), str(empty)], 200), []
            )

    def test_env_override(self):
        import os

        with tempfile.TemporaryDirectory() as t:
            p = unreleased(t, "Added-1", "z" * 150)
            prev = os.environ.get("CHANGIE_MAX_BODY_LENGTH")
            try:
                os.environ["CHANGIE_MAX_BODY_LENGTH"] = "100"
                self.assertEqual(check_changie_length.main([str(p)]), 1)
                os.environ["CHANGIE_MAX_BODY_LENGTH"] = "200"
                self.assertEqual(check_changie_length.main([str(p)]), 0)
            finally:
                if prev is None:
                    os.environ.pop("CHANGIE_MAX_BODY_LENGTH", None)
                else:
                    os.environ["CHANGIE_MAX_BODY_LENGTH"] = prev

    def test_cli_max_beats_env(self):
        import os

        with tempfile.TemporaryDirectory() as t:
            p = unreleased(t, "Added-1", "q" * 150)
            prev = os.environ.get("CHANGIE_MAX_BODY_LENGTH")
            try:
                os.environ["CHANGIE_MAX_BODY_LENGTH"] = "100"  # would fail...
                self.assertEqual(check_changie_length.main(["--max", "200", str(p)]), 0)  # ...but --max wins
            finally:
                if prev is None:
                    os.environ.pop("CHANGIE_MAX_BODY_LENGTH", None)
                else:
                    os.environ["CHANGIE_MAX_BODY_LENGTH"] = prev


if __name__ == "__main__":
    unittest.main()
