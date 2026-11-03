#!/usr/bin/env python3
"""Commit failures on exclusive-created normal files; production IO stays block-only."""
import copy
import fcntl
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import installer_helper_test as legacy
from ntfs_gpt_update_plan_test import fixture
from ntfs_gpt_preservation_test import ROOT_GUID,proof
from gpt_probe_test import gpt

commit=legacy.load_module('ntfs_gpt_commit',legacy.ROOT/'linux/ro_installer_ntfs_commit.py')


class FileIo:
    def __init__(self,fd,image,short=None,write_error=None,flush_error=None,guard_error=None,drift=None):
        self.fd=fd;self.device=copy.deepcopy(image.data['device']);self.sector=image.sector
        self.short=short;self.write_error=write_error;self.flush_error=flush_error;self.guard_error=guard_error;self.drift=drift
        self.events=[];self.writes=self.flushes=self.guards=0
        self.anchor=os.fstat(fd)
        if not stat.S_ISREG(self.anchor.st_mode) or self.anchor.st_size!=self.device['size']:raise AssertionError('normal fixture required')
    def guard(self):
        self.guards+=1;info=os.fstat(self.fd)
        return ((info.st_dev,info.st_ino,info.st_size)==(self.anchor.st_dev,self.anchor.st_ino,self.anchor.st_size)
                and self.guards!=self.guard_error)
    def read(self,offset,length):return os.pread(self.fd,length,offset)
    def write(self,offset,data):
        self.writes+=1;self.events.append(('write',offset))
        if self.writes==self.write_error:raise OSError('PRIVATE_SENTINEL')
        return os.pwrite(self.fd,data[:len(data)//2] if self.writes==self.short else data,offset)
    def flush(self):
        self.flushes+=1;self.events.append(('flush',))
        if self.flushes==self.flush_error:raise OSError('PRIVATE_SENTINEL')
        os.fsync(self.fd)
        if self.flushes==1 and self.drift:os.pwrite(self.fd,b'!',0)


class CommitTests(unittest.TestCase):
    def run_case(self,sector=512,**fault):
        p,image,initial=fixture(sector,64,128)
        groups=gpt.ntfs_gpt_update_plan(image.read,p,ROOT_GUID,initial['preservationFingerprint'])
        with tempfile.TemporaryDirectory() as td:
            path=Path(td)/'new-regular-gpt.img'
            with path.open('xb') as stream:
                stream.truncate(p['snapshot']['device']['size'])
                for offset,raw in image.blocks.items():stream.seek(offset);stream.write(raw)
            fd=os.open(path,os.O_RDWR|os.O_CLOEXEC)
            try:
                io=FileIo(fd,image,**fault)
                if fault:
                    with self.assertRaises(commit.GptCommitError) as error:
                        commit.commit_ntfs_gpt(io,p,ROOT_GUID,initial['preservationFingerprint'])
                    result=error.exception
                    self.assertEqual(str(result),'NTFS_GPT_COMMIT_FAILED')
                    self.assertNotIn('PRIVATE_SENTINEL',str(result))
                else:
                    result=commit.commit_ntfs_gpt(io,p,ROOT_GUID,initial['preservationFingerprint'])
                    parsed=json.loads(subprocess.run(['/usr/sbin/sfdisk','--sector-size',str(sector),'--json',str(path)],
                        capture_output=True,text=True,check=True,timeout=10).stdout)['partitiontable']
                    planned=gpt.ntfs_shrink_plan(p)
                    for guid,start,end in [(ROOT_GUID,planned['root']['startSector'],planned['root']['endSector']),
                        (planned['source']['partitionGuid'],planned['source']['startSector'],planned['source']['newEndSector'])]:
                        row=next(row for row in parsed['partitions'] if row['uuid'].lower()==guid)
                        self.assertEqual((row['start'],row['size']),(start,end-start+1))
                    observed=gpt.verified_ntfs_snapshot(io.read,p['snapshot']['device'],sector,2,3)
                    self.assertEqual(result,gpt.verify_ntfs_created_layout(p,ROOT_GUID,initial['preservationFingerprint'],observed))
                if fault.get('short',99)<=2 or fault.get('write_error',99)<=2 or fault.get('flush_error')==1 or fault.get('guard_error') in (1,2,3) or fault.get('drift'):
                    for offset,old,new in groups[1]:self.assertEqual(io.read(offset,len(old)),old)
                if io.writes>2:
                    for offset,old,new in groups[0]:self.assertEqual(io.read(offset,len(new)),new)
                self.assertEqual(io.read(0,sector),b'!'+image.blocks[0][1:] if fault.get('drift') else image.blocks[0])
                return io,result,groups
            finally:os.close(fd)

    def test_both_copies_are_verified_with_flush_barrier_before_primary(self):
        for sector in (512,4096):
            io,result,groups=self.run_case(sector)
            self.assertEqual(io.events,[('write',groups[0][0][0]),('write',groups[0][1][0]),('flush',),
                                        ('write',groups[1][0][0]),('write',groups[1][1][0]),('flush',)])
            self.assertEqual(io.guards,4)

    def test_every_short_write_and_write_error_stops_without_rollback(self):
        for sector in (512,4096):
            for kind in ('short','write_error'):
                for number in (1,2,3,4):
                    with self.subTest(sector=sector,kind=kind,number=number):
                        io,error,_=self.run_case(sector,**{kind:number})
                        self.assertTrue(error.write_started)
                        self.assertEqual(error.phase,'backup' if number<=2 else 'primary')
                        self.assertEqual(error.verified_copies,0 if number<=2 else 1)
                        self.assertEqual(io.writes,number)
                        self.assertEqual(io.flushes,0 if number<=2 else 1)

    def test_flush_errors_and_intermediate_unowned_drift_never_advance(self):
        for sector in (512,4096):
            for number in (1,2):
                io,error,_=self.run_case(sector,flush_error=number)
                self.assertEqual(error.verified_copies,number-1)
                self.assertEqual(io.writes,number*2)
            io,error,_=self.run_case(sector,drift=True)
            self.assertEqual((io.writes,io.flushes,error.phase,error.verified_copies),(2,1,'backup',0))

    def test_identity_refusal_before_each_copy_and_final_verification_is_truthful(self):
        for number in (1,2,3,4):
            io,error,_=self.run_case(guard_error=number)
            self.assertEqual(io.writes,{1:0,2:0,3:2,4:4}[number])
            self.assertEqual(error.verified_copies,{1:0,2:0,3:1,4:2}[number])
            self.assertEqual(error.write_started,number>=3)

    def test_bound_device_sector_and_stale_proof_refuse_without_writes(self):
        p,image,initial=fixture()
        for field,value in [('device',{**p['snapshot']['device'],'diskSequence':99}),('sector',4096),('sector',512.0)]:
            io=mock.Mock();io.device=p['snapshot']['device'];io.sector=512;setattr(io,field,value)
            with self.assertRaises(commit.GptCommitError) as error:
                commit.commit_ntfs_gpt(io,p,ROOT_GUID,initial['preservationFingerprint'])
            self.assertFalse(error.exception.write_started);io.guard.assert_not_called();io.write.assert_not_called()
        io=mock.Mock(device=p['snapshot']['device'],sector=512);io.guard.return_value=None
        with self.assertRaises(commit.GptCommitError):commit.commit_ntfs_gpt(io,p,ROOT_GUID,initial['preservationFingerprint'])
        io.read.assert_not_called();io.write.assert_not_called()
        io=mock.Mock(device=p['snapshot']['device'],sector=512);io.guard.return_value=True;io.read.side_effect=image.read
        with self.assertRaises(commit.GptCommitError):commit.commit_ntfs_gpt(io,p,ROOT_GUID,'b'*64)
        io.write.assert_not_called()

    def test_adapter_owns_cloexec_duplicate_and_defensively_copies_device_binding(self):
        p,_,_=fixture();device=copy.deepcopy(p['snapshot']['device']);expected=copy.deepcopy(device)
        with tempfile.TemporaryDirectory() as td:
            path=Path(td)/'original';path.write_bytes(b'original')
            fd=os.open(path,os.O_RDWR);owned=None
            try:
                # Only block geometry is synthetic. FD duplication, close,
                # positional writes and flushing use this new normal file.
                with mock.patch.object(commit.gpt,'fd_geometry',return_value=512) as geometry:
                    with commit.BlockGptIo(fd,device,512,lambda:True) as io:
                        owned=io.fd;self.assertNotEqual(owned,fd);self.assertFalse(os.get_inheritable(owned))
                        device['size']=1;copy_of_binding=io.device;copy_of_binding['diskSequence']=99
                        self.assertEqual(io.device,expected)
                        os.close(fd);fd=None
                        self.assertTrue(io.guard())
                        self.assertEqual(geometry.call_args.args[1],expected)
                        self.assertEqual(io.write(0,b'changed!'),8);io.flush()
                        self.assertEqual(io.read(0,8),b'changed!')
                    with self.assertRaises(OSError):os.fstat(owned)
                    with self.assertRaises(ValueError):_ = io.fd
                    io.close()
            finally:
                if fd is not None:os.close(fd)

    def test_append_flag_change_on_shared_description_refuses_before_source_guard(self):
        p,_,_=fixture()
        with tempfile.TemporaryDirectory() as td:
            path=Path(td)/'new';path.write_bytes(b'original');fd=os.open(path,os.O_RDWR)
            try:
                guard=mock.Mock(return_value=True)
                with mock.patch.object(commit.gpt,'fd_geometry',return_value=512):
                    with commit.BlockGptIo(fd,p['snapshot']['device'],512,guard) as io:
                        fcntl.fcntl(fd,fcntl.F_SETFL,fcntl.fcntl(fd,fcntl.F_GETFL)|os.O_APPEND)
                        with self.assertRaises(ValueError):io.guard()
                        guard.assert_not_called()
                self.assertEqual(path.read_bytes(),b'original')
            finally:os.close(fd)

    def test_descriptor_cleanup_preserves_primary_failure_and_prevents_false_success(self):
        io=object.__new__(commit.BlockGptIo)
        error=commit.GptCommitError('backup',True,0)
        with mock.patch.object(io,'close',side_effect=OSError('PRIVATE_SENTINEL')):
            with self.assertRaises(commit.GptCommitError) as raised:
                with io:raise error
            self.assertIs(raised.exception,error);self.assertTrue(error.cleanup_failed)
            with self.assertRaises(OSError):
                with io:pass

    def test_production_adapter_refuses_regular_and_readonly_fds_without_leaks(self):
        p,image,initial=fixture()
        with tempfile.TemporaryDirectory() as td:
            path=Path(td)/'new';path.write_bytes(b'fixture')
            for flags in (os.O_RDONLY,os.O_RDWR,os.O_RDWR|os.O_APPEND,os.O_PATH):
                fd=os.open(path,flags)
                try:
                    before=len(os.listdir('/proc/self/fd'));guard=mock.Mock(return_value=True)
                    with self.assertRaises(ValueError):commit.BlockGptIo(fd,p['snapshot']['device'],512,guard)
                    guard.assert_not_called();os.fstat(fd)
                    self.assertEqual(len(os.listdir('/proc/self/fd')),before)
                finally:os.close(fd)
            result=subprocess.run([sys.executable,'-I',str(legacy.ROOT/'linux/ro_installer_ntfs_commit.py'),'--apply'],capture_output=True)
            self.assertEqual(result.returncode,2);self.assertEqual(result.stdout,b'');self.assertEqual(result.stderr,b'')


if __name__=='__main__':unittest.main()
