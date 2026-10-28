"""The real-kernel gate must distinguish unavailable capabilities from errors."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('namespace_acceptance', ROOT / 'test/scripts/namespace_acceptance.py')
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class AcceptanceStatusTests(unittest.TestCase):
    def run_result(self, completed):
        output = io.StringIO()
        with mock.patch.object(probe, 'rows', return_value='unchanged'), mock.patch.object(probe.shutil, 'which', return_value='/usr/bin/unshare'), mock.patch.object(probe.subprocess, 'run', return_value=completed), contextlib.redirect_stdout(output):
            status = probe.main()
        return status, json.loads(output.getvalue())

    def test_kernel_bootstrap_denial_is_explicit_no_go(self):
        status, report = self.run_result(subprocess.CompletedProcess([], 1, '', 'unshare: operation not permitted'))
        self.assertEqual(status, 77)
        self.assertEqual(report['status'], 'UNAVAILABLE')
        self.assertEqual(report['security_acceptance'], 'NO-GO')

    def test_failure_after_worker_started_is_never_capability_skip(self):
        status, report = self.run_result(subprocess.CompletedProcess([], 1, '', 'RO_NAMESPACE_WORKER_STARTED\nPermissionError'))
        self.assertEqual(status, 1)
        self.assertEqual(report['status'], 'FAIL')
        self.assertEqual(report['security_acceptance'], 'NO-GO')

    def test_only_worker_success_is_accepted(self):
        status, report = self.run_result(subprocess.CompletedProcess([], 0, json.dumps({'status': 'PASS', 'real_mounts': 4}), 'RO_NAMESPACE_WORKER_STARTED'))
        self.assertEqual(status, 0)
        self.assertTrue(report['parent_unchanged'])


if __name__ == '__main__':
    unittest.main()
