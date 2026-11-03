#!/usr/bin/env python3
"""Private worker boundaries with new normal-file leases and fake media/context."""
from contextlib import contextmanager
import fcntl
import io
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
import installer_helper_test as legacy
from ntfs_native_runner_test import proxy

worker=legacy.load_module('ntfs_private_worker_proto',legacy.ROOT/'linux/ro_installer_ntfs_transaction.py')
BASE=json.loads((legacy.ROOT/'test/fixtures/ntfs_approvals_v1.json').read_text())['bases'][0]
FRAME={'namespace':'mnt:[42]','parentNamespace':'mnt:[41]','approvedPlan':BASE['input']}


class WorkerTests(unittest.TestCase):
    def test_parser_is_canonical_and_rejects_duplicate_nonfinite_oversize_and_wrong_context(self):
        raw=json.dumps(FRAME).encode();parsed=worker.parse_frame(raw)
        self.assertEqual(parsed,FRAME)
        for bad in [b'{',b'\xff',raw+b'x',b' '*worker.MAX_INPUT+b'{}',
                    raw.replace(b'"rootGuid":',b'"rootGuid":"x","rootGuid":'),
                    raw.replace(b'"namespace": "mnt:[42]"',b'"namespace":NaN'),
                    raw.replace(b'mnt:[42]',b'mnt:[41]'),raw.replace(b'mnt:[42]',b'mnt:[0]')]:
            with self.assertRaises((ValueError,UnicodeError)):worker.parse_frame(bad)
        for field,value in [('namespace',True),('parentNamespace','mnt:[abc]'),('command','arbitrary')]:
            with self.assertRaises(ValueError):worker.parse_frame(json.dumps({**FRAME,field:value}).encode())

    @contextmanager
    def context(self,mode=0o600,linked=False,namespace_error=False,parent_changed=False,device_changed=False,inherited=True):
        with tempfile.TemporaryDirectory() as td:
            directory=Path(td)/'ro-installer';directory.mkdir(mode=0o700)
            path=directory/'install.lock';lease=os.open(path,os.O_RDWR|os.O_CREAT|os.O_EXCL|os.O_CLOEXEC,mode)
            fcntl.flock(lease,fcntl.LOCK_EX|fcntl.LOCK_NB)
            if linked:os.link(path,directory/'extra-link')
            if not inherited:os.close(lease);lease=None
            lock_type=worker.gate.InstallerLock
            def lock():return lock_type(owner_uid=os.geteuid())
            def fstat(fd):
                observed=os.fstat(fd)
                return SimpleNamespace(**{name:getattr(observed,name) for name in dir(observed) if name.startswith('st_') and name!='st_uid'},st_uid=0)
            system=SimpleNamespace(platform_supported=lambda:True)
            expected=FRAME['approvedPlan']['proposal']['snapshot']['device']
            identity=SimpleNamespace(public=lambda:{**expected,'diskSequence':99} if device_changed else dict(expected))
            try:
                with mock.patch.object(worker.gate,'LOCK_DIRECTORY',str(directory)),mock.patch.object(worker.gate,'InstallerLock',side_effect=lock), \
                     mock.patch.object(worker.gate,'System',return_value=system),mock.patch.object(worker.gate,'validate_device',return_value=identity), \
                     mock.patch.object(worker.session,'verify_private',side_effect=ValueError('private namespace') if namespace_error else None), \
                     mock.patch.object(worker,'os',proxy(os,geteuid=lambda:0,fstat=fstat,
                        readlink=lambda _: 'mnt:[99]' if parent_changed else FRAME['namespace'])):
                    yield directory,path,lease
            finally:
                if lease is not None:os.close(lease)

    def test_inherited_lease_duplicate_is_cloexec_and_context_is_rechecked(self):
        with self.context() as (directory,path,lease):
            with worker.TrustedContext(FRAME) as context:
                duplicate=context.lease
                self.assertNotEqual(duplicate,lease);self.assertFalse(os.get_inheritable(duplicate))
                self.assertEqual(os.fstat(duplicate).st_ino,os.fstat(lease).st_ino)
                self.assertTrue(context.guard())
                self.assertEqual(context.system.lease_fd,duplicate)
                with path.open('r+b') as other:
                    with self.assertRaises(BlockingIOError):fcntl.flock(other.fileno(),fcntl.LOCK_EX|fcntl.LOCK_NB)
                path.rename(directory/'old-lock')
                with path.open('xb') as stream:stream.write(b'new inode')
                path.chmod(0o600)
                self.assertFalse(context.guard())
            with self.assertRaises(OSError):os.fstat(duplicate)
            os.fstat(lease)

    def test_lease_modes_links_namespace_parent_and_device_refuse_without_fd_leaks(self):
        for fault in ({'mode':0o644},{'linked':True},{'namespace_error':True},{'parent_changed':True},{'device_changed':True},{'inherited':False}):
            with self.context(**fault):
                before=len(os.listdir('/proc/self/fd'))
                with self.assertRaises(Exception):worker.TrustedContext(FRAME)
                self.assertEqual(len(os.listdir('/proc/self/fd')),before)

    def test_symlink_runtime_directory_and_duplicate_failure_refuse_without_leaks(self):
        with self.context() as (directory,path,lease):
            before=len(os.listdir('/proc/self/fd'))
            def denied(fd,command,*args):
                if command==fcntl.F_DUPFD_CLOEXEC:raise OSError('private duplicate failure')
                return fcntl.fcntl(fd,command,*args)
            with mock.patch.object(worker,'fcntl',proxy(fcntl,fcntl=denied)):
                with self.assertRaises(OSError):worker.TrustedContext(FRAME)
            self.assertEqual(len(os.listdir('/proc/self/fd')),before)
            moved=directory.with_name('old-runtime');directory.rename(moved);directory.symlink_to(moved,target_is_directory=True)
            with self.assertRaises(OSError):worker.TrustedContext(FRAME)
            self.assertEqual(len(os.listdir('/proc/self/fd')),before)

    def test_replaced_runtime_directory_is_refused(self):
        with self.context() as (directory,path,lease):
            with worker.TrustedContext(FRAME) as context:
                directory.rename(directory.with_name('old-runtime'));directory.mkdir(mode=0o700)
                self.assertFalse(context.guard())

    def test_parent_process_or_parent_permissions_drift_refuses(self):
        with self.context() as (directory,path,lease):
            with worker.TrustedContext(FRAME) as context:
                real_parent=worker.os.getppid
                worker.os.getppid=lambda:real_parent()+1
                self.assertFalse(context.guard())
                worker.os.getppid=real_parent
                directory.parent.chmod(0o777)
                self.assertFalse(context.guard())
                directory.parent.chmod(0o700)
                self.assertTrue(context.guard())

    def test_process_local_native_lease_environment_always_restores(self):
        for before in (None,'original'):
            with mock.patch.dict(os.environ,{},clear=False):
                if before is None:os.environ.pop('RO_INSTALLER_LEASE_FD',None)
                else:os.environ['RO_INSTALLER_LEASE_FD']=before
                with self.assertRaises(ValueError):
                    with worker.native_lease(17):
                        self.assertEqual(os.environ['RO_INSTALLER_LEASE_FD'],'17');raise ValueError()
                self.assertEqual(os.environ.get('RO_INSTALLER_LEASE_FD'),before)

    def test_execute_owns_only_fixed_whole_path_and_emits_no_boot_provenance(self):
        with tempfile.TemporaryFile() as normal, tempfile.TemporaryFile() as lease:
            context=SimpleNamespace(lease=lease.fileno(),guard=lambda:True)
            ctx=mock.MagicMock();ctx.__enter__.return_value=context
            adapter=mock.MagicMock();adapter.__enter__.return_value=adapter;adapter.run.return_value=BASE['created']
            def fixed_open(path,flags):
                self.assertEqual(path,BASE['input']['proposal']['snapshot']['device']['path'])
                self.assertEqual(flags,os.O_RDWR|os.O_CLOEXEC|os.O_NOFOLLOW|os.O_NONBLOCK)
                return os.dup(normal.fileno())
            with mock.patch.object(worker,'TrustedContext',return_value=ctx), \
                 mock.patch.object(worker.session,'power_inhibitor',return_value=mock.MagicMock()), \
                 mock.patch.object(worker.core,'BlockNtfsTransaction',return_value=adapter), \
                 mock.patch.object(worker,'os',proxy(os,open=fixed_open)):
                result=worker.execute(FRAME)
                self.assertEqual(result,{'status':'success','snapshot':BASE['created'],'preservationFingerprint':BASE['proof']})
                self.assertEqual(adapter.run.call_args.args,(
                    BASE['input']['approval']['rootGuid'],BASE['input']['approval']['preservationFingerprint'],
                    BASE['input']['approval']['inspectionFingerprint'],BASE['input']['approval']['preparationFingerprint'],lease.fileno()))
                passed_fd=worker.core.BlockNtfsTransaction.call_args.args[0]
                with self.assertRaises(OSError):os.fstat(passed_fd)
                os.fstat(normal.fileno());os.fstat(lease.fileno())

    def test_execute_preserves_typed_partial_progress_and_unknown_call_failure(self):
        for failure in (worker.core.NtfsTransactionError('gpt.backup',True,True,0,True),ValueError('SECRET_DEVICE_LABEL')):
            with tempfile.TemporaryFile() as normal:
                context=SimpleNamespace(lease=normal.fileno(),guard=lambda:True)
                ctx=mock.MagicMock();ctx.__enter__.return_value=context
                adapter=mock.MagicMock();adapter.__enter__.return_value=adapter;adapter.run.side_effect=failure
                with mock.patch.object(worker,'TrustedContext',return_value=ctx), \
                     mock.patch.object(worker.session,'power_inhibitor',return_value=mock.MagicMock()), \
                     mock.patch.object(worker.core,'BlockNtfsTransaction',return_value=adapter), \
                     mock.patch.object(worker,'os',proxy(os,open=lambda *args:os.dup(normal.fileno()))):
                    result=worker.execute(FRAME)
                self.assertEqual(result['status'],'failed');self.assertTrue(result['sourceMayHaveChanged'])
                self.assertTrue(result['gptWriteStarted']);self.assertNotIn('SECRET',json.dumps(result))
                self.assertEqual(result['progressKnown'],isinstance(failure,worker.core.NtfsTransactionError))

    def test_post_success_context_cleanup_failure_retains_complete_table_progress(self):
        with tempfile.TemporaryFile() as normal:
            context=SimpleNamespace(lease=normal.fileno(),guard=lambda:True)
            ctx=mock.MagicMock();ctx.__enter__.return_value=context;ctx.__exit__.side_effect=OSError('private close')
            adapter=mock.MagicMock();adapter.__enter__.return_value=adapter;adapter.run.return_value=BASE['created']
            with mock.patch.object(worker,'TrustedContext',return_value=ctx), \
                 mock.patch.object(worker.session,'power_inhibitor',return_value=mock.MagicMock()), \
                 mock.patch.object(worker.core,'BlockNtfsTransaction',return_value=adapter), \
                 mock.patch.object(worker,'os',proxy(os,open=lambda *args:os.dup(normal.fileno()))):
                result=worker.execute(FRAME)
            self.assertEqual(result['phase'],'cleanup');self.assertTrue(result['cleanupFailed'])
            self.assertTrue(result['progressKnown']);self.assertTrue(result['sourceMayHaveChanged'])
            self.assertTrue(result['gptWriteStarted']);self.assertEqual(result['verifiedGptCopies'],2)

    def test_power_failure_occurs_before_whole_open(self):
        context=SimpleNamespace(lease=17,guard=lambda:True);ctx=mock.MagicMock();ctx.__enter__.return_value=context
        with mock.patch.object(worker,'TrustedContext',return_value=ctx), \
             mock.patch.object(worker.session,'power_inhibitor',side_effect=ValueError('private power error')), \
             mock.patch.object(worker,'os',proxy(os,open=mock.Mock())):
            result=worker.execute(FRAME);worker.os.open.assert_not_called()
        self.assertEqual(result['phase'],'power');self.assertFalse(result['sourceMayHaveChanged']);self.assertTrue(result['progressKnown'])

    def test_main_is_root_fixed_mode_and_bounded_data_only(self):
        output=io.StringIO()
        for root,args in ((False,['--execute']),(True,['--other']),(True,['--execute','/dev/sda'])):
            with mock.patch.object(worker,'os',proxy(os,geteuid=lambda:0 if root else 1000)), \
                 mock.patch.object(worker,'sys',proxy(sys,argv=['worker',*args],stdout=output)),mock.patch.object(worker,'execute') as execute:
                self.assertEqual(worker.main(),2);execute.assert_not_called()
        self.assertEqual(output.getvalue(),'')
        for raw,status in ((json.dumps(FRAME).encode(),0),(b'{',2)):
            output=io.StringIO()
            with mock.patch.object(worker,'os',proxy(os,geteuid=lambda:0)), \
                 mock.patch.object(worker,'sys',proxy(sys,argv=['worker','--execute'],stdin=SimpleNamespace(buffer=io.BytesIO(raw)),stdout=output)), \
                 mock.patch.object(worker.core.ntfs,'restrict_limit') as limits, \
                 mock.patch.object(worker,'execute',return_value={'status':'success','snapshot':BASE['created'],'preservationFingerprint':BASE['proof']}) as execute:
                self.assertEqual(worker.main(),status);self.assertEqual(limits.call_count,3)
                result=json.loads(output.getvalue());self.assertEqual(result['schemaVersion'],1)
                if status:execute.assert_not_called();self.assertFalse(result['sourceMayHaveChanged'])
                self.assertLess(len(output.getvalue().encode()),8192)

    def test_unexpected_execute_exception_never_claims_no_source_change(self):
        output=io.StringIO()
        with mock.patch.object(worker,'os',proxy(os,geteuid=lambda:0)), \
             mock.patch.object(worker,'sys',proxy(sys,argv=['worker','--execute'],
                 stdin=SimpleNamespace(buffer=io.BytesIO(json.dumps(FRAME).encode())),stdout=output)), \
             mock.patch.object(worker.core.ntfs,'restrict_limit'), \
             mock.patch.object(worker,'execute',side_effect=ValueError('PRIVATE_NATIVE_DETAIL')):
            self.assertEqual(worker.main(),2)
        result=json.loads(output.getvalue())
        self.assertFalse(result['progressKnown']);self.assertTrue(result['sourceMayHaveChanged'])
        self.assertTrue(result['gptWriteStarted']);self.assertNotIn('PRIVATE_NATIVE_DETAIL',output.getvalue())


if __name__=='__main__':unittest.main()
