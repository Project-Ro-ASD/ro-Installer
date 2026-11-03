#!/usr/bin/env python3
"""Private transaction ordering on normal files with synthetic block identity."""
import copy
from contextlib import contextmanager
import fcntl
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

import installer_helper_test as legacy
from ntfs_gpt_update_plan_test import fixture
from ntfs_gpt_preservation_test import ROOT_GUID
from ntfs_gpt_commit_test import FileIo

core=legacy.load_module('ntfs_transaction_core',legacy.ROOT/'linux/ro_installer_ntfs_commit.py')
FP='a'*64; PREP='b'*64


def proxy(module,**changes):return SimpleNamespace(**{**{name:getattr(module,name) for name in dir(module)},**changes})


class TransactionTests(unittest.TestCase):
    @contextmanager
    def case(self,sector=512,**fault):
        p,image,initial=fixture(sector,64,128)
        with tempfile.TemporaryDirectory() as directory:
            disk=Path(directory)/'new-normal-gpt.img'
            with disk.open('xb') as stream:
                stream.truncate(p['snapshot']['device']['size'])
                for offset,raw in image.blocks.items():stream.seek(offset);stream.write(raw)
            source=Path(directory)/'new-normal-source'
            source.write_bytes(b'original')
            whole=os.open(disk,os.O_RDWR|os.O_CLOEXEC)
            reader=os.open(source,os.O_RDONLY|os.O_CLOEXEC);writer=os.open(source,os.O_RDWR|os.O_CLOEXEC)
            with tempfile.TemporaryFile() as lease:
                try:
                    io=FileIo(whole,image,**fault)
                    events=[];dups=[]
                    def partition(snapshot,binding,fd):
                        self.assertEqual(snapshot,p['snapshot'])
                        self.assertEqual(binding['number'],2)
                        self.assertEqual(os.fstat(fd).st_ino,os.fstat(reader).st_ino)
                        if fd not in dups:dups.append(fd)
                        return '/fixture-source','10:2'
                    def ioctl(fd,command,arg):
                        self.assertEqual(command,0x1268);return sector.to_bytes(4,sys.byteorder)
                    def prepare(fd,size,sec,target,fp):
                        events.append('prepare');self.assertEqual(fp,FP)
                        self.assertEqual(fcntl.fcntl(fd,fcntl.F_GETFL)&os.O_ACCMODE,os.O_RDONLY)
                        return {'preparationFingerprint':PREP}
                    def native(fd,size,sec,target,lease_fd):
                        events.append('native');self.assertEqual(lease_fd,lease.fileno())
                        self.assertEqual(fcntl.fcntl(fd,fcntl.F_GETFL)&os.O_ACCMODE,os.O_RDWR)
                        os.pwrite(fd,b'resized!',0);return True
                    def post(*args):events.append('post');return {'inspectionFingerprint':'c'*64}
                    write=io.write
                    def write_gpt(offset,data):events.append('gpt');return write(offset,data)
                    io.write=write_gpt
                    with mock.patch.dict(os.environ,{'RO_INSTALLER_LEASE_FD':str(lease.fileno())}), \
                         mock.patch.object(core.manual,'partition_descriptor',side_effect=partition), \
                         mock.patch.object(core,'fcntl',proxy(fcntl,ioctl=ioctl)), \
                         mock.patch.object(core.ntfs,'boot_sector',return_value=(b'original-boot',4096)) as boot, \
                         mock.patch.object(core.ntfs,'prepare_resize_target',side_effect=prepare) as preparation, \
                         mock.patch.object(core.ntfs,'run_native_resize',side_effect=native) as resize, \
                         mock.patch.object(core.ntfs,'inspect_resized_fd',side_effect=post) as inspect:
                        args=[io,p,ROOT_GUID,initial['preservationFingerprint'],FP,PREP,reader,writer,lease.fileno()]
                        yield SimpleNamespace(io=io,p=p,image=image,initial=initial,args=args,events=events,dups=dups,
                            boot=boot,preparation=preparation,resize=resize,inspect=inspect,reader=reader,writer=writer,lease=lease.fileno())
                    for fd in dups:
                        with self.assertRaises(OSError):os.fstat(fd)
                    for fd in (reader,writer,whole,lease.fileno()):os.fstat(fd)
                finally:
                    for fd in (reader,writer,whole):os.close(fd)

    def invoke(self,c):return core.resize_and_commit_ntfs(*c.args)

    def test_supported_order_and_exact_raw_gpt_preservation(self):
        for sector in (512,4096):
            with self.case(sector) as c:
                result=self.invoke(c)
                self.assertEqual(c.events,['prepare','native','post']+['gpt']*4)
                self.assertEqual(c.io.flushes,2)
                self.assertEqual(result.original_boot,b'original-boot')
                self.assertEqual(result.filesystem,{'inspectionFingerprint':'c'*64})
                self.assertEqual(os.pread(c.reader,8,0),b'resized!')
                final=core.gpt.verified_ntfs_snapshot(c.io.read,c.io.device,sector,2,3)
                self.assertEqual(result.snapshot,core.gpt.verify_ntfs_created_layout(c.p,ROOT_GUID,c.initial['preservationFingerprint'],final))
                self.assertEqual(final['preservationFingerprint'],c.initial['preservationFingerprint'])
                target=core.gpt.ntfs_shrink_plan(c.p)['source']['retainedBytes']
                self.assertEqual(c.resize.call_args.args[3],target)
                self.assertEqual(c.inspect.call_args.args[2],target)

    def test_stale_inspection_preparation_and_boot_refuse_without_native_start(self):
        for kind in ('inspection','preparation','boot'):
            with self.case() as c:
                if kind=='inspection':c.preparation.side_effect=ValueError('raw inspection')
                elif kind=='preparation':c.preparation.side_effect=None;c.preparation.return_value={'preparationFingerprint':'d'*64}
                else:c.boot.side_effect=[(b'old',4096),(b'changed',4096)]
                with self.assertRaises(core.NtfsTransactionError) as error:self.invoke(c)
                self.assertEqual(error.exception.phase,'prepare');self.assertFalse(error.exception.source_may_have_changed)
                self.assertFalse(error.exception.gpt_write_started);c.resize.assert_not_called();self.assertEqual(c.io.writes,0)

    def test_invalid_identity_guid_proof_and_lease_refuse_before_preparation(self):
        for kind in ('identity','sector','guid','proof','lease','reader','fingerprint'):
            with self.case() as c:
                if kind=='identity':c.io.device={**c.io.device,'diskSequence':99}
                elif kind=='sector':c.io.sector=4096
                elif kind=='guid':c.args[2]=c.p['snapshot']['diskGuid']
                elif kind=='proof':c.args[3]='f'*64
                elif kind=='lease':c.args[8]=c.reader
                elif kind=='reader':c.args[6]=True
                else:c.args[4]=None
                with self.assertRaises(core.NtfsTransactionError) as error:self.invoke(c)
                self.assertFalse(error.exception.source_may_have_changed);c.preparation.assert_not_called()
                c.resize.assert_not_called();self.assertEqual(c.io.writes,0)

    def test_source_modes_must_be_exact_and_appending_is_rejected(self):
        for kind in ('read-write','write-read','append'):
            with self.case() as c:
                if kind=='read-write':c.args[6]=os.dup(c.writer)
                elif kind=='write-read':c.args[7]=os.dup(c.reader)
                else:fcntl.fcntl(c.writer,fcntl.F_SETFL,os.O_APPEND)
                try:
                    with self.assertRaises(core.NtfsTransactionError) as error:self.invoke(c)
                    self.assertFalse(error.exception.source_may_have_changed);c.preparation.assert_not_called()
                finally:
                    if kind!='append':os.close(c.args[6] if kind=='read-write' else c.args[7])

    def test_native_failure_is_conservative_and_never_writes_gpt(self):
        for failure,changed in [(core.ntfs.NativeResizeError(False,'native'),False),
                                (core.ntfs.NativeResizeError(True,'flush',True),True),
                                (ValueError('private path'),True)]:
            with self.case() as c:
                c.resize.side_effect=failure
                with self.assertRaises(core.NtfsTransactionError) as error:self.invoke(c)
                self.assertEqual(error.exception.phase,'native');self.assertEqual(error.exception.source_may_have_changed,changed)
                self.assertEqual(error.exception.cleanup_failed,getattr(failure,'cleanup_failed',False))
                self.assertEqual(str(error.exception),'NTFS_TRANSACTION_FAILED');self.assertEqual(c.io.writes,0)
                c.inspect.assert_not_called()

    def test_failed_postcheck_never_advances_gpt_or_restores_source(self):
        with self.case() as c:
            c.inspect.side_effect=ValueError('post drift')
            with self.assertRaises(core.NtfsTransactionError) as error:self.invoke(c)
            self.assertEqual(error.exception.phase,'filesystem');self.assertTrue(error.exception.source_may_have_changed)
            self.assertEqual(c.io.writes,0);self.assertEqual(os.pread(c.reader,8,0),b'resized!')

    def test_gpt_partial_fault_details_are_preserved_without_retry_or_rollback(self):
        for kind in ('short','write_error','flush_error'):
            for number in range(1,3 if kind=='flush_error' else 5):
                with self.case(**{kind:number}) as c:
                    with self.assertRaises(core.NtfsTransactionError) as error:self.invoke(c)
                    self.assertTrue(error.exception.source_may_have_changed);self.assertTrue(error.exception.gpt_write_started)
                    self.assertEqual(error.exception.verified_gpt_copies,number-1 if kind=='flush_error' else int(number>2))
                    self.assertEqual(c.resize.call_count,1);self.assertEqual(c.inspect.call_count,1)
                    self.assertEqual(c.io.writes,number*2 if kind=='flush_error' else number)

    def test_gpt_changes_during_preparation_refuse_before_native(self):
        with self.case() as c:
            def drift(*args):os.pwrite(c.io.fd,b'!',0);return {'preparationFingerprint':PREP}
            c.preparation.side_effect=drift
            with self.assertRaises(core.NtfsTransactionError) as error:self.invoke(c)
            self.assertFalse(error.exception.source_may_have_changed);c.resize.assert_not_called()
            self.assertEqual(c.io.writes,0);self.assertEqual(c.io.read(0,1),b'!')

    def test_guard_refusal_at_every_boundary_stops_with_truthful_state(self):
        for number in range(1,10):
            with self.case(guard_error=number) as c:
                with self.assertRaises(core.NtfsTransactionError) as error:self.invoke(c)
                self.assertEqual(error.exception.source_may_have_changed,number>=4)
                self.assertEqual(c.io.writes,0 if number<=7 else 2 if number==8 else 4)
                self.assertEqual(error.exception.gpt_write_started,number>=8)
                self.assertEqual(error.exception.verified_gpt_copies,0 if number<=7 else number-7)
                self.assertLessEqual(c.resize.call_count,1)

    def test_source_binding_drift_after_native_refuses_gpt(self):
        with self.case() as c:
            native=c.resize.side_effect
            def change(*args):
                result=native(*args)
                core.fcntl.ioctl=lambda *args:(4096).to_bytes(4,sys.byteorder)
                return result
            c.resize.side_effect=change
            with self.assertRaises(core.NtfsTransactionError) as error:self.invoke(c)
            self.assertEqual(error.exception.phase,'filesystem')
            self.assertTrue(error.exception.source_may_have_changed)
            self.assertEqual(c.io.writes,0);c.inspect.assert_not_called()

    def test_duplicate_close_failure_preserves_phase_and_copy_progress(self):
        for earlier_error in (False,True):
            with self.case() as c:
                def close(fd):
                    os.close(fd)
                    if fd in c.dups:raise OSError('private close detail')
                if earlier_error:c.inspect.side_effect=ValueError('private post failure')
                with mock.patch.object(core,'os',proxy(os,close=close)):
                    with self.assertRaises(core.NtfsTransactionError) as error:self.invoke(c)
                self.assertTrue(error.exception.cleanup_failed)
                self.assertEqual(error.exception.phase,'filesystem' if earlier_error else 'cleanup')
                self.assertTrue(error.exception.source_may_have_changed)
                self.assertEqual(error.exception.verified_gpt_copies,0 if earlier_error else 2)
                self.assertEqual(error.exception.gpt_write_started,not earlier_error)

    def test_gpt_drift_after_filesystem_validation_does_not_start_table_writes(self):
        with self.case() as c:
            def drift(*args):os.pwrite(c.io.fd,b'!',0);return {}
            c.inspect.side_effect=drift
            with self.assertRaises(core.NtfsTransactionError) as error:self.invoke(c)
            self.assertEqual(error.exception.phase,'gpt.prepare')
            self.assertTrue(error.exception.source_may_have_changed)
            self.assertFalse(error.exception.gpt_write_started);self.assertEqual(c.io.writes,0)
            self.assertEqual(c.io.read(0,1),b'!')

    def test_intermediate_unowned_gpt_drift_preserves_partial_failure(self):
        with self.case(drift=True) as c:
            with self.assertRaises(core.NtfsTransactionError) as error:self.invoke(c)
            self.assertEqual(error.exception.phase,'gpt.backup')
            self.assertTrue(error.exception.source_may_have_changed);self.assertTrue(error.exception.gpt_write_started)
            self.assertEqual(error.exception.verified_gpt_copies,0);self.assertEqual(c.io.writes,2)
            self.assertEqual(c.io.read(0,1),b'!')

    def test_caller_mutation_cannot_replace_copied_intent(self):
        with self.case() as c:
            approved=copy.deepcopy(c.p);prepare=c.preparation.side_effect
            def mutate(*args):
                result=prepare(*args);c.p['rootBytes']+=1048576
                c.p['snapshot']['device']['diskSequence']=999
                return result
            c.preparation.side_effect=mutate
            # The fake source identity check also uses the original immutable
            # approved data rather than the deliberately changed caller object.
            def partition(snapshot,binding,fd):
                self.assertEqual(snapshot,approved['snapshot']);return '/fixture-source','10:2'
            with mock.patch.object(core.manual,'partition_descriptor',side_effect=partition):
                result=self.invoke(c)
            final=core.gpt.verified_ntfs_snapshot(c.io.read,c.io.device,c.io.sector,2,3)
            self.assertEqual(result.snapshot,core.gpt.verify_ntfs_created_layout(approved,ROOT_GUID,c.initial['preservationFingerprint'],final))


if __name__=='__main__':unittest.main()
