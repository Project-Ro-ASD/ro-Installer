#!/usr/bin/env python3
"""Native writer lifecycle on owned child processes and new regular files only."""
from contextlib import contextmanager
import ctypes
import hashlib
import os
from pathlib import Path
import signal
import struct
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest import mock
import installer_helper_test as legacy
from ntfs_bound_io_test import build_adapter, environment
from ntfs_target_preparation_test import VERSION, PACKAGES

worker = legacy.load_module('ntfs_native_runner', legacy.ROOT/'linux/ro_installer_ntfs.py')
OLD, TARGET = 512*1024**2, 256*1024**2


def proxy(module, **changes):
    return SimpleNamespace(**{**{name:getattr(module,name) for name in dir(module)}, **changes})


class NativeRunnerTests(unittest.TestCase):
    @contextmanager
    def source(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'new-normal.img'
            with path.open('xb') as stream: stream.truncate(OLD)
            fd = os.open(path, os.O_RDWR|os.O_CLOEXEC)
            with tempfile.TemporaryFile() as lease:
                try:
                    with mock.patch.dict(os.environ, {'RO_INSTALLER_LEASE_FD':str(lease.fileno())}):
                        yield path, fd, lease.fileno()
                finally: os.close(fd)

    @contextmanager
    def qualified(self):
        def query(kind, fd):
            self.assertIsNone(fd)
            return {'resize-version':VERSION, 'resize-packages':PACKAGES}[kind]
        with mock.patch.object(worker, 'run_tool', side_effect=query), \
             mock.patch.object(worker, 'bound_io_environment', side_effect=lambda fd:environment('/unused',fd)):
            yield

    @contextmanager
    def child(self, code, check=None, before_wait=None):
        children = []
        def spawn(argv, **kwargs):
            self.assertEqual(argv, ('/usr/bin/ntfsresize','-P','--size',str(TARGET),worker.BOUND_ALIAS))
            self.assertTrue(kwargs['start_new_session']); self.assertTrue(kwargs['close_fds'])
            self.assertEqual(len(kwargs['pass_fds']), 2)
            owned, lease = kwargs['pass_fds']
            self.assertEqual(kwargs['env']['RO_INSTALLER_NTFS_BOUND_FD'],str(owned))
            self.assertEqual(kwargs['env']['RO_INSTALLER_LEASE_FD'],str(lease))
            self.assertFalse(os.get_inheritable(owned))
            if check: check(owned, lease)
            # Substitute only the executable. All inherited descriptors, pipes,
            # environment and session options are the production invocation.
            kwargs['env'] = {**kwargs['env'], 'LD_PRELOAD':''}
            process = subprocess.Popen([sys.executable,'-I','-c',code],**kwargs)
            if before_wait:
                real_wait = process.wait
                def wait(*args, **options):
                    before_wait(process)
                    return real_wait(*args, **options)
                process.wait = wait
            children.append(process)
            return process
        with mock.patch.object(worker,'subprocess',proxy(subprocess,Popen=spawn)):
            try: yield children
            finally:
                # Test-owned fallback cleanup must not mask an un-reaped child.
                for process in children:
                    if process.returncode is None:
                        try: os.killpg(process.pid,signal.SIGKILL)
                        except ProcessLookupError: pass
                        process.wait(timeout=2)

    def invoke(self, fd, lease):
        return worker.run_native_resize(fd,OLD,512,TARGET,lease)

    def test_fixed_invocation_flushes_then_closes_only_owned_duplicate(self):
        events, duplicated = [], []
        def check(owned, lease):
            duplicated.append(owned); events.append('spawn')
            self.assertEqual(os.fstat(owned).st_ino,os.fstat(source).st_ino)
        def killpg(pid, sig):
            events.append('kill'); return os.killpg(pid,sig)
        def flush(fd):
            self.assertEqual(fd,duplicated[0]);events.append('flush');os.fsync(fd)
        def before_wait(process):
            self.assertIn('kill',events);events.append('wait')
        with self.source() as (_,source,lease), self.qualified(), \
             self.child('import os,sys; assert sys.stdin.buffer.read() == b"y\\n"; '
                        'os.fstat(int(os.environ["RO_INSTALLER_NTFS_BOUND_FD"])); '
                        'os.fstat(int(os.environ["RO_INSTALLER_LEASE_FD"]))',check,before_wait) as children, \
             mock.patch.object(worker,'os',proxy(os,killpg=killpg,fsync=flush)):
            self.assertIs(self.invoke(source,lease),True)
            self.assertEqual(events,['spawn','kill','wait','flush'])
            os.fstat(source);os.fstat(lease)
            with self.assertRaises(OSError):os.fstat(duplicated[0])
            self.assertEqual(children[0].returncode,0)
            self.assertTrue(all(stream.closed for stream in (children[0].stdin,children[0].stdout,children[0].stderr)))

    def test_invalid_bindings_refuse_before_native_process(self):
        with self.source() as (path,fd,lease), self.qualified(),mock.patch.object(worker.subprocess,'Popen') as spawn:
            args = (fd,OLD,512,TARGET,lease)
            for index,value in [(0,True),(0,2),(1,True),(1,OLD+512),(2,True),(2,1024),
                                (3,True),(3,OLD),(3,TARGET+1),(4,True),(4,fd),(4,2)]:
                bad = list(args);bad[index]=value
                with self.assertRaises(worker.NativeResizeError) as failure:worker.run_native_resize(*bad)
                self.assertFalse(failure.exception.started)
            with mock.patch.dict(os.environ,{'RO_INSTALLER_LEASE_FD':'999999'}):
                with self.assertRaises(worker.NativeResizeError):self.invoke(fd,lease)
            for mode in (os.O_RDONLY,os.O_WRONLY,os.O_RDWR|os.O_APPEND,os.O_PATH):
                other=os.open(path,mode)
                try:
                    with self.assertRaises(worker.NativeResizeError) as failure:self.invoke(other,lease)
                    self.assertFalse(failure.exception.started)
                finally:os.close(other)
            spawn.assert_not_called()

    def test_spawn_failure_closes_duplicate_without_claiming_write_start(self):
        duplicates=[]
        def fail(argv,**kwargs):
            duplicates.append(kwargs['pass_fds'][0]);raise OSError('private path')
        with self.source() as (_,fd,lease),self.qualified(), \
             mock.patch.object(worker,'subprocess',proxy(subprocess,Popen=fail)):
            with self.assertRaises(worker.NativeResizeError) as failure:self.invoke(fd,lease)
            self.assertFalse(failure.exception.started);self.assertEqual(failure.exception.phase,'native')
            self.assertEqual(str(failure.exception),'NTFS_RESIZE_FAILED')
            with self.assertRaises(OSError):os.fstat(duplicates[0])
            os.fstat(fd);os.fstat(lease)

    def test_old_toolchain_and_missing_adapter_refuse_before_mutation(self):
        with self.source() as (_,fd,lease),mock.patch.object(worker.subprocess,'Popen') as spawn:
            def old(kind, source):return VERSION.replace(b'2026.9.28',b'2026.2.25') if kind=='resize-version' else PACKAGES
            with mock.patch.object(worker,'run_tool',side_effect=old):
                with self.assertRaises(worker.NativeResizeError) as failure:self.invoke(fd,lease)
                self.assertFalse(failure.exception.started)
            with self.qualified(),mock.patch.object(worker,'bound_io_environment',side_effect=ValueError('private detail')):
                with self.assertRaises(worker.NativeResizeError) as failure:self.invoke(fd,lease)
                self.assertFalse(failure.exception.started)
                self.assertEqual(str(failure.exception),'NTFS_RESIZE_FAILED')
            spawn.assert_not_called()

    def test_nonzero_overflow_deadline_and_signal_never_flush(self):
        codes = ['import sys; sys.stdin.buffer.read(); sys.exit(7)',
                 'import sys; sys.stdin.buffer.read(); sys.stdout.buffer.write(b"x"*70000)',
                 'import time; time.sleep(5)',
                 'import os,signal; os.kill(os.getpid(),signal.SIGTERM)']
        for code in codes:
            with self.subTest(code=code),self.source() as (_,fd,lease),self.qualified(),self.child(code) as children, \
                 mock.patch.object(worker,'RESIZE_TIMEOUT',0.1),mock.patch.object(worker,'os',proxy(os,fsync=mock.Mock())):
                with self.assertRaises(worker.NativeResizeError) as failure:self.invoke(fd,lease)
                self.assertTrue(failure.exception.started)
                self.assertEqual(failure.exception.phase,'native')
                worker.os.fsync.assert_not_called()
                self.assertIsNotNone(children[0].returncode)
                self.assertTrue(children[0].stdout.closed);os.fstat(fd)

    def test_unexpected_descendant_is_killed_and_retains_lease_until_death(self):
        libc=ctypes.CDLL(None,use_errno=True);previous=ctypes.c_int()
        self.assertEqual(libc.prctl(37,ctypes.byref(previous),0,0,0),0)
        self.assertEqual(libc.prctl(36,1,0,0,0),0)
        self.addCleanup(lambda:libc.prctl(36,previous.value,0,0,0))
        with self.source() as (path,fd,lease),self.qualified():
            pidfile=path.with_name('child-pid')
            code = ('import os,time; child=os.fork(); '
                    '\nif child == 0:\n os.close(0);os.close(1);os.close(2);time.sleep(30);os._exit(0)'
                    f'\nopen({str(pidfile)!r},"w").write(str(child));os._exit(0)')
            with self.child(code),mock.patch.object(worker,'os',proxy(os,fsync=mock.Mock())):
                with self.assertRaises(worker.NativeResizeError) as failure:self.invoke(fd,lease)
                self.assertTrue(failure.exception.started);worker.os.fsync.assert_not_called()
            pid=int(pidfile.read_text())
            deadline=time.monotonic()+2
            reaped=False
            try:
                while time.monotonic()<deadline:
                    observed,status=os.waitpid(pid,os.WNOHANG)
                    if observed==pid:
                        reaped=True
                        self.assertTrue(os.WIFSIGNALED(status));self.assertEqual(os.WTERMSIG(status),signal.SIGKILL)
                        break
                    time.sleep(.01)
                self.assertTrue(reaped,'Owned descendant survived native cleanup')
            finally:
                if not reaped:
                    # Still our unreaped child, so its PID cannot be reused.
                    os.kill(pid,signal.SIGKILL);os.waitpid(pid,0)

    def test_flush_failure_reports_started_and_retains_callers_descriptors(self):
        with self.source() as (_,fd,lease),self.qualified(),self.child('pass'), \
             mock.patch.object(worker,'os',proxy(os,fsync=mock.Mock(side_effect=OSError('raw path')))):
            with self.assertRaises(worker.NativeResizeError) as failure:self.invoke(fd,lease)
            self.assertTrue(failure.exception.started);self.assertEqual(failure.exception.phase,'flush')
            self.assertEqual(str(failure.exception),'NTFS_RESIZE_FAILED');os.fstat(fd);os.fstat(lease)

    def test_cleanup_failure_cannot_be_reported_as_success(self):
        def denied(pid,sig):raise PermissionError('raw detail')
        with self.source() as (_,fd,lease),self.qualified(),self.child('pass'), \
             mock.patch.object(worker,'os',proxy(os,killpg=denied,fsync=mock.Mock())):
            with self.assertRaises(worker.NativeResizeError) as failure:self.invoke(fd,lease)
            self.assertEqual(failure.exception.phase,'cleanup');self.assertTrue(failure.exception.cleanup_failed)
            worker.os.fsync.assert_not_called()

    def test_native_bound_resize_of_new_regular_images_and_independent_postcheck(self):
        with tempfile.TemporaryDirectory() as directory:
            adapter=build_adapter(directory)
            for sector in (512,4096):
                with self.subTest(sector=sector),self.source() as (path,fd,lease):
                    subprocess.run(['/usr/bin/mkntfs','-F','-Q','-s',str(sector),'-c','4096',str(path)],
                                   capture_output=True,check=True,timeout=20)
                    original,cluster=worker.boot_sector(fd,OLD,sector)
                    self.assertLess(max(struct.unpack_from('<QQ',original,48))*cluster,TARGET)
                    moved=path.with_name('held-image');path.rename(moved)
                    path.write_bytes(b'unrelated replacement')
                    # Only package metadata is substituted. This fixture tests
                    # FD/native command semantics, not toolchain qualification
                    # or the MFT relocation fixed in the newer native release.
                    with self.qualified(),mock.patch.object(worker,'bound_io_environment',side_effect=lambda owned:environment(adapter,owned)):
                        self.assertTrue(worker.run_native_resize(fd,OLD,sector,TARGET,lease))
                    self.assertEqual(path.read_bytes(),b'unrelated replacement')
                    self.assertEqual(moved.stat().st_size,OLD)
                    reader=os.open(moved,os.O_RDONLY|os.O_CLOEXEC)
                    try:
                        with moved.open('rb') as stream:before=hashlib.file_digest(stream,'sha256').hexdigest()
                        result=worker.inspect_resized_fd(reader,OLD,TARGET,sector,original)
                        self.assertEqual(result['targetBytes'],TARGET)
                        with moved.open('rb') as stream:self.assertEqual(hashlib.file_digest(stream,'sha256').hexdigest(),before)
                    finally:os.close(reader)


if __name__=='__main__':unittest.main()
