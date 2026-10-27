"""Real checkout/archive fixtures for the documentation acceptance boundary."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
CHECKER = ROOT / "scripts/check-source-policy.py"
REPORT = "docs/I01-kernel-index-permissions-20261021.md"


class SourcePolicyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ro-source-policy-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "source"
        self.root.mkdir()
        self.documents(self.root)
        self.environment = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}

    def documents(self, root):
        (root / "docs").mkdir(parents=True)
        (root / "README.md").write_text("architecture\n")
        (root / REPORT).write_text("retained I01 evidence\n")

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.root), *args],
                              env=self.environment, capture_output=True, text=True, check=True)

    def checkout(self):
        self.git("init", "-q")
        self.git("add", "README.md", REPORT)

    def run_check(self, root=None, mode="auto", environment=None):
        return subprocess.run([sys.executable, str(CHECKER), "--root", str(root or self.root),
                               "--mode", mode], env=environment or self.environment,
                              capture_output=True, text=True)

    def test_checkout_preserves_exact_historical_report(self):
        self.checkout()
        result = self.run_check(mode="checkout")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("(checkout)", result.stdout)
        self.assertEqual((self.root / REPORT).read_text(), "retained I01 evidence\n")

    def test_untracked_local_evidence_is_not_source_policy_input(self):
        self.checkout()
        (self.root / "local.md").write_text("operator notes")
        self.assertEqual(self.run_check().returncode, 0)

    def test_unexpected_tracked_markdown_is_rejected(self):
        self.checkout()
        (self.root / "extra.MD").write_text("unexpected")
        self.git("add", "extra.MD")
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("extra.MD", result.stderr)

    def test_missing_required_tracked_report_is_rejected(self):
        self.checkout()
        self.git("rm", "--cached", REPORT)
        self.assertNotEqual(self.run_check().returncode, 0)

    def test_empty_git_index_is_not_success(self):
        self.git("init", "-q")
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("empty tracked source list", result.stderr)

    def fake_git(self, body):
        tools = Path(self.temp.name) / "tools"
        tools.mkdir()
        executable = tools / "git"
        executable.write_text("#!/bin/sh\n" + body)
        executable.chmod(0o700)
        return {**self.environment, "PATH": str(tools)}

    def test_git_listing_error_is_not_silently_accepted(self):
        self.checkout()
        env = self.fake_git(f'case "$*" in *rev-parse*) printf "%s\\n" "{self.root}";; *) exit 55;; esac\n')
        result = self.run_check(environment=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("55", result.stderr)

    def test_git_detection_error_does_not_fall_back_to_archive(self):
        self.checkout()
        result = self.run_check(environment=self.fake_git("exit 56\n"))
        self.assertNotEqual(result.returncode, 0)

    def test_explicit_archive_cannot_bypass_checkout_git_errors(self):
        self.checkout()
        result = self.run_check(mode="archive")
        self.assertNotEqual(result.returncode, 0)

    def test_standalone_source_archive_is_checked_without_git(self):
        result = self.run_check(environment=self.fake_git("exit 99\n"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("(archive)", result.stdout)

    def test_archive_unexpected_markdown_is_rejected(self):
        (self.root / "docs/unreviewed.md").write_text("unexpected")
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unreviewed.md", result.stderr)

    def test_archive_below_git_parent_does_not_use_empty_parent_index(self):
        self.checkout()
        archive = self.root / "outputs/rpmbuild/source"
        self.documents(archive)
        # Reproduce the old failure mode: Git succeeds but lists no archive files.
        empty = subprocess.run(["git", "ls-files", "*.md"], cwd=archive,
                               env=self.environment, capture_output=True, text=True, check=True)
        self.assertEqual(empty.stdout, "")
        self.assertEqual(self.run_check(root=archive).returncode, 0)
        (archive / "unexpected.md").write_text("must not silently pass")
        self.assertNotEqual(self.run_check(root=archive).returncode, 0)
        self.assertNotEqual(self.run_check(root=archive, mode="checkout").returncode, 0)

    def test_generated_archive_outputs_are_not_shipped_sources(self):
        generated = self.root / "build/docs"
        generated.mkdir(parents=True)
        (generated / "generated.md").write_text("generated")
        self.assertEqual(self.run_check().returncode, 0)

    def test_missing_or_symlinked_required_document_is_rejected(self):
        (self.root / REPORT).unlink()
        self.assertNotEqual(self.run_check().returncode, 0)
        (self.root / REPORT).symlink_to(self.root / "README.md")
        self.assertNotEqual(self.run_check().returncode, 0)

    def test_git_worktree_file_marker_is_supported(self):
        self.checkout()
        external = Path(self.temp.name) / "git-data"
        shutil.move(self.root / ".git", external)
        (self.root / ".git").write_text(f"gitdir: {external}\n")
        self.assertEqual(self.run_check().returncode, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
