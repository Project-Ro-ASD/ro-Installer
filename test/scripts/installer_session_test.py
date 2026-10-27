"""Session supervisor boundaries. No real /mnt or physical disk operations."""
import importlib.machinery
import importlib.util
import os
import json
import socket
import threading
import time
from types import SimpleNamespace
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


class TransportLeaseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory(prefix='session-native-')
        cls.binary=str(Path(cls.temp.name)/'engine')
        result=subprocess.run(['dart','compile','exe',str(ROOT/'test/fixtures/session_transport.dart'),'-o',cls.binary],capture_output=True,text=True)
        if result.returncode:raise AssertionError(result.stdout+result.stderr)
        helper_loader=importlib.machinery.SourceFileLoader('session_test_helper',str(ROOT/'linux/ro-installer-helper'))
        helper_spec=importlib.util.spec_from_loader(helper_loader.name,helper_loader)
        cls.gate=importlib.util.module_from_spec(helper_spec)
        sys.modules[helper_loader.name]=cls.gate
        helper_loader.exec_module(cls.gate)
    @classmethod
    def tearDownClass(cls):cls.temp.cleanup()

    def run_fixture(self,crash=False):
        with tempfile.TemporaryDirectory(prefix='session-ipc-') as td:
            directory=str(Path(td)/'runtime')
            result_file=str(Path(td)/'result.json')
            command_pid=str(Path(td)/'command.pid')
            with self.gate.InstallerLock(directory,os.geteuid()) as lock:
                supervisor=session.Supervisor(self.gate,lock.fd,'synthetic-before','synthetic-test',td)
                env={**session.ROOT_ENV,'FIXTURE_SOCKET':supervisor.path,'LOCK_FILE':directory+'/install.lock','RESULT_FILE':result_file}
                if crash:env['COMMAND_PID']=command_pid
                statuses=[]
                with mock.patch.object(session,'verify_private'):
                    thread=threading.Thread(target=lambda:statuses.append(supervisor.run((self.binary,),env)))
                    thread.start()
                    try:
                        deadline=time.monotonic()+15
                        if crash:
                            while not Path(command_pid).exists() and time.monotonic()<deadline:time.sleep(.02)
                            self.assertTrue(Path(command_pid).exists())
                            with self.assertRaises(self.gate.HelperError):
                                with self.gate.InstallerLock(directory,os.geteuid()):pass
                            auto_gate=SimpleNamespace(InstallerLock=lambda:self.gate.InstallerLock(directory,os.geteuid()))
                            with self.assertRaises(self.gate.HelperError):
                                with session.session_lock(auto_gate,'--auto'):pass
                            intruder=socket.socket(socket.AF_UNIX)
                            try:
                                intruder.connect(supervisor.path)
                                intruder.sendall(b'{"op":"describe"}\n')
                                self.assertEqual(json.loads(intruder.makefile('rb').readline()),{'error':'SESSION_ERROR'})
                            finally:intruder.close()
                            supervisor.engine.kill()
                        thread.join(20)
                        self.assertFalse(thread.is_alive(),'session did not drain children')
                    finally:
                        if thread.is_alive():
                            if supervisor.engine:supervisor.engine.kill()
                            session.kill_owned_children()
                            thread.join(5)
                self.assertEqual(statuses,[9] if crash else [0])
                if not crash:
                    report=json.loads(Path(result_file).read_text())
                    self.assertEqual(report['stdout'],'lease-held:18')
                    self.assertEqual(report['exit'],0)
                    self.assertNotIn('stdin-private-test',str(report['logs']))
                    self.assertFalse(report['namespace_test'])
            with self.gate.InstallerLock(directory,os.geteuid()):pass

    def test_native_dart_commands_inherit_original_kernel_lease(self):self.run_fixture()
    def test_engine_crash_kills_owned_command_before_releasing_lock(self):self.run_fixture(crash=True)

if __name__=='__main__':unittest.main(verbosity=2)
