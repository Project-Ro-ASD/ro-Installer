"""Session supervisor boundaries. No real /mnt or physical disk operations."""
import importlib.machinery
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT=Path(__file__).resolve().parents[2]
loader=importlib.machinery.SourceFileLoader('session',str(ROOT/'linux/ro-installer-session'))
spec=importlib.util.spec_from_loader(loader.name,loader)
session=importlib.util.module_from_spec(spec)
loader.exec_module(session)

class NamespaceTests(unittest.TestCase):
    def test_unshare_failure_has_no_fallback_or_mount(self):
        with mock.patch.object(session.os,'unshare',side_effect=PermissionError), mock.patch.object(session.ctypes,'CDLL') as libc:
            with self.assertRaises(PermissionError):session.private_namespace()
            libc.assert_not_called()

    def test_private_propagation_failure_prevents_verification_and_engine(self):
        libc=mock.Mock();libc.mount.return_value=-1
        with mock.patch.object(session.os,'unshare'), mock.patch.object(session.ctypes,'CDLL',return_value=libc), mock.patch.object(session,'verify_private') as verify:
            with self.assertRaises(OSError):session.private_namespace()
            verify.assert_not_called()

    def test_same_namespace_is_rejected(self):
        libc=mock.Mock();libc.mount.return_value=0
        with mock.patch.object(session.os,'unshare'),mock.patch.object(session.os,'readlink',return_value='mnt:[1]'),mock.patch.object(session.ctypes,'CDLL',return_value=libc):
            with self.assertRaises(RuntimeError):session.private_namespace()

    def test_shared_or_slave_propagation_is_rejected(self):
        for flags in ['shared:1','master:2','propagate_from:4']:
            with self.subTest(flags=flags),mock.patch.object(session.os,'readlink',return_value='mnt:[2]'),mock.patch.object(session.Path,'read_text',return_value=f'1 0 8:1 / / rw {flags} - ext4 /dev/fixture rw\n'):
                with self.assertRaises(RuntimeError):session.verify_private('mnt:[2]')

    def test_missing_inventory_or_namespace_change_is_rejected(self):
        with mock.patch.object(session.os,'readlink',return_value='mnt:[2]'),mock.patch.object(session.Path,'read_text',return_value=''):
            with self.assertRaises(RuntimeError):session.verify_private('mnt:[2]')
        with mock.patch.object(session.os,'readlink',return_value='mnt:[3]'):
            with self.assertRaises(RuntimeError):session.verify_private('mnt:[2]')

    def test_private_setup_uses_recursive_private_and_subreaper(self):
        libc=mock.Mock();libc.mount.return_value=libc.prctl.return_value=0
        with mock.patch.object(session.os,'unshare') as unshare,mock.patch.object(session.os,'readlink',side_effect=['mnt:[1]','mnt:[2]']),mock.patch.object(session.ctypes,'CDLL',return_value=libc),mock.patch.object(session,'verify_private') as verify:
            self.assertEqual(session.private_namespace(),('mnt:[1]','mnt:[2]'))
            unshare.assert_called_once_with(os.CLONE_NEWNS)
            libc.mount.assert_called_once_with(None,b'/',None,16384|262144,None)
            verify.assert_called_once_with('mnt:[2]')

    def test_gui_protocol_remains_fixed_and_auto_uses_same_lock(self):
        gate=mock.MagicMock();gate.InstallerLock.return_value.__enter__.return_value.fd=41
        with session.session_lock(gate,'--auto') as fd:self.assertEqual(fd,41)
        gate.InstallerLock.assert_called_once_with()
        self.assertIn('with session_lock(gate,mode)',(ROOT/'linux/ro-installer-session').read_text())
        self.assertIn('pass_fds=(self.lease,)',(ROOT/'linux/ro-installer-session').read_text())

    def test_real_namespace_capability_is_reported_separately(self):
        # Probe only: do NOT create a namespace here. Dedicated real test does that.
        result=subprocess.run([sys.executable,'-c','import os; print(hasattr(os,"unshare"))'],capture_output=True,text=True)
        self.assertEqual(result.stdout.strip(),'True')

if __name__=='__main__':unittest.main(verbosity=2)
