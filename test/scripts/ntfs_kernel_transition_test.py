#!/usr/bin/env python3
"""Owned source lifecycle and kernel transition on normal-file block models."""
from contextlib import contextmanager
import fcntl
import os
from pathlib import Path
import sys
import unittest
from unittest import mock

import ntfs_transaction_test as fixturetest
from ntfs_gpt_preservation_test import ROOT_GUID

core=fixturetest.core


class KernelTests(unittest.TestCase):
    case=fixturetest.TransactionTests.case

    @contextmanager
    def adapter(self,sector=512,delay=0,timeout=False,rescan_error=False,identity_drift=False,filesystem_drift=False,table_drift=False,open_error=None,close_error=None):
        with self.case(sector) as c:
            path=Path(os.readlink('/proc/self/fd/'+str(c.reader)))
            events=[];opened=[];rescans=[];context=mock.Mock(return_value=True)
            whole_inode=os.fstat(c.io.fd).st_ino
            def geometry(fd,device):
                self.assertEqual(device,c.io.device);self.assertEqual(os.fstat(fd).st_ino,whole_inode)
                return 4096 if identity_drift and rescans and sector==512 else sector
            def partition(snapshot,binding,fd=None):
                self.assertEqual(binding['number'],2)
                self.assertEqual(snapshot['device'],c.p['snapshot']['device'])
                if rescans:self.assertEqual(binding['endSector'],core.gpt.ntfs_shrink_plan(c.p)['source']['newEndSector'])
                else:self.assertEqual(binding['endSector'],core.gpt.ntfs_shrink_plan(c.p)['source']['endSector'])
                if fd is not None:
                    self.assertEqual(os.fstat(fd).st_ino,os.fstat(c.reader).st_ino)
                    if fd not in c.dups:c.dups.append(fd)
                return '/fixture-source','10:2'
            def open_source(name,flags,*args,**kwargs):
                self.assertEqual(name,'/fixture-source')
                self.assertTrue(flags&os.O_NOFOLLOW);self.assertTrue(flags&os.O_CLOEXEC);self.assertTrue(flags&os.O_NONBLOCK)
                if len(opened)+1==open_error:raise OSError('private source open')
                fd=os.open(path,flags,*args,**kwargs);opened.append((fd,flags));events.append('open');return fd
            def close(fd):
                if any(fd==item[0] for item in opened):events.append('close')
                os.close(fd)
                if close_error=='original' and len(opened)==2 and any(fd==item[0] for item in opened) and c.adapter._state=='running':
                    raise OSError('private original close')
                if close_error=='fresh' and len(opened)==3 and fd==opened[-1][0]:
                    raise OSError('private refreshed close')
            def ioctl(fd,command,*args):
                if command==0x1268:return sector.to_bytes(4,sys.byteorder)
                self.assertEqual(command,0x125f);self.assertEqual(os.fstat(fd).st_ino,whole_inode)
                self.assertEqual(c.io.read(0,1),b'{')
                for old,flags in opened:
                    with self.assertRaises(OSError):os.fstat(old)
                self.assertEqual(len(opened),2)
                self.assertEqual(c.resize.call_count,1)
                rescans.append(fd);events.append('reread')
                if rescan_error:raise OSError('private rescan detail')
                if table_drift:os.pwrite(c.io.fd,b'!',0)
                return 0
            polls=[]
            def kernel(snapshot):
                if not rescans:
                    self.assertEqual(snapshot,c.p['snapshot']);return
                polls.append(snapshot)
                if timeout or len(polls)<=delay:raise ValueError('not ready')
            def post(fd,old,target,sec,boot,**kwargs):
                self.assertEqual(boot,b'original-boot')
                c.events.append('post')
                if rescans:self.assertEqual(kwargs,{'partition_bytes':target})
                else:self.assertEqual(kwargs,{})
                return {'schemaVersion':1,'volumeBytes':target-sec,'clusterBytes':4096,
                        'minimumBytes':1024**3+(sec if filesystem_drift and rescans else 0),
                        'targetBytes':target,'deviceBytes':target if rescans else old,
                        'inspectionFingerprint':('e' if rescans else 'c')*64}
            c.inspect.side_effect=post
            with mock.patch.object(core.manual,'partition_descriptor',side_effect=partition), \
                 mock.patch.object(core.gpt,'fd_geometry',side_effect=geometry), \
                 mock.patch.object(core.gpt,'verify_kernel_layout',side_effect=kernel), \
                 mock.patch.object(core,'fcntl',fixturetest.proxy(fcntl,ioctl=ioctl)), \
                 mock.patch.object(core,'os',fixturetest.proxy(os,open=open_source,close=close)), \
                 mock.patch.object(core,'KERNEL_TIMEOUT',.02 if timeout else .5):
                with core.BlockNtfsTransaction(c.io.fd,c.p,context) as io:
                    c.adapter=io;c.opened=opened;c.events_io=events;c.rescans=rescans;c.polls=polls;c.context=context
                    yield c
                for fd,flags in opened:
                    with self.assertRaises(OSError):os.fstat(fd)
                with self.assertRaises(ValueError):_ = io.fd

    def invoke(self,c):return c.adapter.run(ROOT_GUID,c.initial['preservationFingerprint'],fixturetest.FP,fixturetest.PREP,c.lease)

    def test_owned_source_opens_close_before_single_reread_and_exact_postcheck(self):
        for sector in (512,4096):
            with self.adapter(sector) as c:
                result=self.invoke(c)
                self.assertEqual(len(c.rescans),1);self.assertEqual(c.inspect.call_count,2)
                self.assertEqual([flags&os.O_ACCMODE for fd,flags in c.opened],[os.O_RDWR,os.O_RDONLY,os.O_RDONLY])
                self.assertTrue(c.opened[0][1]&os.O_EXCL);self.assertFalse(c.opened[1][1]&os.O_EXCL)
                self.assertTrue(c.opened[2][1]&os.O_EXCL)
                self.assertLess(c.events_io.index('close'),c.events_io.index('reread'))
                self.assertEqual(c.events_io[-1],'close')
                proof=core.gpt.verified_ntfs_snapshot(c.io.read,c.io.device,sector,2,3)
                self.assertEqual(result,proof['snapshot']);self.assertEqual(c.adapter._state,'ready')
                with self.assertRaises(core.NtfsTransactionError) as error:self.invoke(c)
                self.assertTrue(error.exception.source_may_have_changed);self.assertTrue(error.exception.gpt_write_started)
                self.assertEqual(error.exception.verified_gpt_copies,2);self.assertEqual(c.resize.call_count,1)

    def test_delayed_kernel_inventory_is_bounded_and_verified_before_open(self):
        with self.adapter(delay=2) as c:
            self.invoke(c);self.assertGreaterEqual(len(c.polls),3);self.assertEqual(len(c.opened),3)
        with self.adapter(timeout=True) as c:
            with self.assertRaises(core.NtfsTransactionError) as error:self.invoke(c)
            self.assertEqual(error.exception.phase,'kernel.ready');self.assertEqual(error.exception.verified_gpt_copies,2)
            self.assertEqual(len(c.opened),2);self.assertEqual(len(c.rescans),1)

    def test_reread_failure_never_retries_or_opens_new_source(self):
        with self.adapter(rescan_error=True) as c:
            with self.assertRaises(core.NtfsTransactionError) as error:self.invoke(c)
            self.assertEqual(error.exception.phase,'kernel.reread');self.assertTrue(error.exception.source_may_have_changed)
            self.assertTrue(error.exception.gpt_write_started);self.assertEqual(error.exception.verified_gpt_copies,2)
            self.assertEqual(str(error.exception),'NTFS_TRANSACTION_FAILED')
            self.assertEqual(len(c.rescans),1);self.assertEqual(len(c.opened),2)
            with self.assertRaises(core.NtfsTransactionError) as again:self.invoke(c)
            self.assertTrue(again.exception.source_may_have_changed);self.assertEqual(again.exception.verified_gpt_copies,2)
            self.assertEqual(c.resize.call_count,1)

    def test_identity_and_raw_gpt_drift_refuse_before_reopen(self):
        for fault in ('identity_drift','table_drift'):
            with self.adapter(**{fault:True}) as c:
                with self.assertRaises(core.NtfsTransactionError) as error:self.invoke(c)
                self.assertEqual(error.exception.phase,'kernel.ready')
                self.assertEqual(error.exception.verified_gpt_copies,2);self.assertEqual(len(c.opened),2)

    def test_refreshed_filesystem_drift_fails_and_closes_reader(self):
        with self.adapter(filesystem_drift=True) as c:
            with self.assertRaises(core.NtfsTransactionError) as error:self.invoke(c)
            self.assertEqual(error.exception.phase,'kernel.source');self.assertEqual(error.exception.verified_gpt_copies,2)
            for fd,flags in c.opened:
                with self.assertRaises(OSError):os.fstat(fd)

    def test_core_failure_never_rereads_or_exposes_targets(self):
        with self.adapter() as c:
            c.resize.side_effect=core.ntfs.NativeResizeError(True,'native')
            with self.assertRaises(core.NtfsTransactionError) as error:self.invoke(c)
            self.assertEqual(error.exception.phase,'native');self.assertTrue(error.exception.source_may_have_changed)
            self.assertFalse(error.exception.gpt_write_started);self.assertEqual(c.rescans,[])
            for fd,flags in c.opened:
                with self.assertRaises(OSError):os.fstat(fd)
            with self.assertRaises(core.NtfsTransactionError) as again:self.invoke(c)
            self.assertTrue(again.exception.source_may_have_changed);self.assertEqual(c.resize.call_count,1)

    def test_source_open_failure_closes_partial_binding_without_mutation(self):
        for number in (1,2):
            before=len(os.listdir('/proc/self/fd'))
            with self.assertRaises(OSError):
                with self.adapter(open_error=number):self.fail('Constructor must refuse')
            self.assertEqual(len(os.listdir('/proc/self/fd')),before)

    def test_source_close_failure_is_truthful_and_never_returns_ready(self):
        for kind,phase in (('original','kernel.close'),('fresh','kernel.cleanup')):
            with self.adapter(close_error=kind) as c:
                with self.assertRaises(core.NtfsTransactionError) as error:self.invoke(c)
                self.assertEqual(error.exception.phase,phase);self.assertTrue(error.exception.cleanup_failed)
                self.assertTrue(error.exception.source_may_have_changed);self.assertEqual(error.exception.verified_gpt_copies,2)
                self.assertEqual(len(c.rescans),0 if kind=='original' else 1)
                with self.assertRaises(core.NtfsTransactionError) as again:self.invoke(c)
                self.assertTrue(again.exception.cleanup_failed)

    def test_context_refusal_prevents_initial_source_open(self):
        with self.case() as c:
            with mock.patch.object(core.gpt,'fd_geometry',return_value=512), \
                 mock.patch.object(core,'os',fixturetest.proxy(os,open=mock.Mock())):
                with self.assertRaises(ValueError):core.BlockNtfsTransaction(c.io.fd,c.p,lambda:False)
                core.os.open.assert_not_called();c.resize.assert_not_called()

    def test_production_adapter_refuses_regular_whole_fd_without_source_open_or_leak(self):
        with self.case() as c:
            before=len(os.listdir('/proc/self/fd'))
            with mock.patch.object(core,'os',fixturetest.proxy(os,open=mock.Mock())):
                with self.assertRaises(ValueError):core.BlockNtfsTransaction(c.io.fd,c.p,lambda:True)
                core.os.open.assert_not_called()
            os.fstat(c.io.fd)
            self.assertEqual(len(os.listdir('/proc/self/fd')),before)


if __name__=='__main__':unittest.main()
