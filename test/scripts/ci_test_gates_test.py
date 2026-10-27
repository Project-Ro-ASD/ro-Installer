"""Reject green I01 runner exits with skipped/missing/failed regression events."""

import importlib.util
import io
import json
from pathlib import Path
import subprocess
import unittest
from unittest import mock
from contextlib import redirect_stderr, redirect_stdout


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("kernel_gate", ROOT / "scripts/check-kernel-index-tests.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


def events():
    result = []
    for identifier, name in enumerate(sorted(gate.EXPECTED_TESTS)):
        result.extend([
            {"type": "testStart", "test": {"id": identifier, "name": name}},
            {"type": "testDone", "testID": identifier, "result": "success", "skipped": False},
        ])
    return [*result, {"type": "done", "success": True}]


def output(data):
    return "\n".join(json.dumps(event) for event in data)


class I01GateTests(unittest.TestCase):
    def test_four_successful_tests_are_accepted(self):
        gate.validate_report(output(events()))

    def test_skip_is_rejected_even_with_successful_final_event(self):
        data = events()
        data[1]["skipped"] = True
        with self.assertRaisesRegex(ValueError, "skipped"):
            gate.validate_report(output(data))

    def test_test_failure_is_rejected(self):
        data = events()
        data[1]["result"] = "failure"
        with self.assertRaises(ValueError):
            gate.validate_report(output(data))

    def test_zero_tests_or_missing_test_is_rejected(self):
        for data in [[{"type": "done", "success": True}], events()[2:]]:
            with self.subTest(data=data), self.assertRaises(ValueError):
                gate.validate_report(output(data))

    def test_missing_or_unsuccessful_runner_completion_is_rejected(self):
        for data in [events()[:-1], [*events()[:-1], {"type": "done", "success": False}]]:
            with self.subTest(data=data), self.assertRaises(ValueError):
                gate.validate_report(output(data))

    def test_duplicate_test_or_completion_is_rejected(self):
        for extra in [events()[0], events()[1]]:
            data = events()
            data.insert(2, extra)
            with self.subTest(extra=extra), self.assertRaises(ValueError):
                gate.validate_report(output(data))

    def test_loader_error_and_malformed_json_are_rejected(self):
        for raw in [output([{"type": "error"}, *events()]), "not json"]:
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                gate.validate_report(raw)

    def test_unexpected_test_or_premature_done_is_rejected(self):
        for data in [
            [*events()[:-1], {"type": "testDone", "testID": 99, "result": "success", "skipped": False}, events()[-1]],
            [events()[-1], *events()[:-1]],
            [*events(), events()[0]],
        ]:
            with self.subTest(data=data), self.assertRaises(ValueError):
                gate.validate_report(output(data))

    def test_missing_real_tool_fails_before_flutter_is_started(self):
        for tool in ["depmod", "modprobe"]:
            with self.subTest(tool=tool), mock.patch.object(gate.shutil, "which", side_effect=lambda name: None if name == tool else "/fixture/tool"), \
                    mock.patch.object(gate.subprocess, "run") as run, \
                    redirect_stderr(io.StringIO()):
                self.assertEqual(gate.main(), 1)
                run.assert_not_called()

    def test_nonzero_flutter_exit_cannot_pass_a_successful_report(self):
        result = subprocess.CompletedProcess([], 7, output(events()), "fixture error")
        with mock.patch.object(gate.shutil, "which", return_value="/fixture/tool"), \
                mock.patch.object(gate.subprocess, "run", return_value=result), \
                redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            self.assertEqual(gate.main(), 1)

    def test_both_fedora_workflows_install_real_tools_and_check_checkout(self):
        for path in [".github/workflows/rpm-fedora44.yml", ".github/workflows/release.yml"]:
            with self.subTest(path=path):
                source = (ROOT / path).read_text()
                dependencies = source.split("Install Fedora 44 build dependencies", 1)[1].split("- name:", 1)[0]
                self.assertRegex(dependencies, r"(?m)^\s+kmod\s+\\$")
                check = "python3 scripts/check-source-policy.py --mode checkout"
                build = "scripts/01-build-rpm.sh --source-mode git --require-clean-git"
                self.assertIn(check, source)
                self.assertLess(source.index(check), source.index(build))
                self.assertIn("FLUTTER_TAG: 3.47.6", source)
        self.assertRegex((ROOT / "ro-installer.spec").read_text(), r"(?m)^BuildRequires:\s+kmod$")
        self.assertRegex((ROOT / "ro-installer.spec").read_text(), r"(?m)^BuildRequires:\s+git$")
        self.assertIn("python3 scripts/check-kernel-index-tests.py", (ROOT / "scripts/check-stable.sh").read_text())


if __name__ == "__main__":
    unittest.main(verbosity=2)
