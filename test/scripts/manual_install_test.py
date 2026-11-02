"""Manual admission, real pipe gate and read-only checks; no block-device IO."""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import uuid
from unittest import mock
import installer_helper_test as legacy
from manual_probe_test import System as ReadSystem, worker

helper=legacy.helper


def fixture(index=0):
    return json.loads((legacy.ROOT/'test/fixtures/manual_ownership_v1.json').read_text())[index]


def request(index=0):
    f=fixture(index);dev=f['snapshot']['device']
    return {'protocolVersion':2,'operation':'install-manual','disk':dev['path'],
            'expectedDevice':{k:v for k,v in dev.items() if k!='path'},
            'confirmDestructive':True,'confirmedPlan':f['approval']['intent']}


class System(ReadSystem):
    def __init__(self,index=0):
        super().__init__();self.index=index;self.calls=0;self.drift=False;self.dirty=False
    def gpt_snapshot(self,device,manual_roles=None,layout_slots=None,admit_manual=False):
        self.calls+=1;value=fixture(self.index)
        if self.dirty:raise helper.HelperError('AMBIGUOUS_TOPOLOGY','unsafe filesystem')
        snapshot=value['snapshot']
        if self.drift and self.calls>=3:snapshot['tableFingerprint']='b'*64
        if manual_roles is not None:
            assert admit_manual is True
            return {'snapshot':snapshot,'plan':helper.gpt_module().manual_plan(snapshot,manual_roles)}
        return {'snapshot':snapshot,'preservationFingerprint':value['approval']['preservationFingerprint']}


class ManualTests(unittest.TestCase):
    def parse(self,value=None,version=2):return helper.parse_request(json.dumps(value or request()).encode(),version)
    def error(self,code,action,*args,**kwargs):
        with self.assertRaises(helper.HelperError) as caught:action(*args,**kwargs)
        self.assertEqual(caught.exception.code,code)
    def test_public_request_is_explicit_v2_and_rejects_private_overrides(self):
        self.assertEqual(self.parse().operation,'install-manual')
        for change in [{'confirmDestructive':1},{'confirmDestructive':False},{'sourceSnapshot':fixture()['snapshot']},
                       {'allocationGuids':{}},{'preservationFingerprint':'a'*64},{'manualPartitions':[]},
                       {'confirmedPlan':fixture()['approval']}]:
            self.error('INVALID_REQUEST',self.parse,{**request(),**change})
        for mutate in [lambda p:p.update(schemaVersion=True),lambda p:p.update(diskSwap=1),
                       lambda p:p['root'].update(formatOnInstall=False),lambda p:p['root'].update(path='/dev/vdb2')]:
            r=request();mutate(r['confirmedPlan']);self.error('INVALID_REQUEST',self.parse,r)
        self.error('INVALID_REQUEST',self.parse,{**request(),'protocolVersion':1},1)
    def run_child(self,system):
        f=fixture(system.index)
        body=legacy.BackendBridgeTests.prefix+'''
assert request['operation']=='install-manual'
assert request['sourceSnapshot']['device']['path']=='/dev/vda'
print(json.dumps({'protocolVersion':1,'type':'ready','confirmedPlan':request['confirmedPlan']}),flush=True)
gate=json.loads(sys.stdin.readline())
assert gate['confirmedPlan']==request['confirmedPlan']
print(json.dumps({'protocolVersion':1,'type':'result','ok':True,'code':'OK'}),flush=True)
'''
        with tempfile.TemporaryDirectory() as td:
            path=Path(td)/'backend.py';path.write_text(body)
            ids=[uuid.UUID(f['approval']['allocationGuids'][role]) for role in ('esp','root') if role in f['approval']['allocationGuids']]
            with mock.patch.object(helper.os,'geteuid',return_value=0),mock.patch.object(helper,'InstallerLock') as lock, \
                 mock.patch.object(helper,'BACKEND_ARGV',(sys.executable,'-I',str(path))),mock.patch.object(helper.uuid,'uuid4',side_effect=ids):
                lock.return_value.__enter__.return_value.fd=None
                return helper.handle(self.parse(request(system.index)),system)
    def test_all_role_combinations_are_revalidated_at_real_ready_continue_gate(self):
        for index in range(4):
            system=System(index)
            self.assertEqual(self.run_child(system),{'installed':True});self.assertEqual(system.calls,4)
            self.assertFalse(hasattr(system,'lease_fd'))
    def test_dirty_filesystem_or_stale_gate_never_grants_continue(self):
        system=System();system.dirty=True
        self.error('AMBIGUOUS_TOPOLOGY',self.run_child,system)
        system=System();system.drift=True
        self.error('DEVICE_CHANGED',self.run_child,system)
        self.assertFalse(hasattr(system,'lease_fd'))
    def test_uuid_collision_is_rejected_before_backend_spawn(self):
        system=System(3)
        with mock.patch.object(helper.os,'geteuid',return_value=0),mock.patch.object(helper,'InstallerLock'), \
             mock.patch.object(helper.uuid,'uuid4',return_value=uuid.UUID(fixture(3)['snapshot']['diskGuid'])),mock.patch.object(helper,'run_backend') as backend:
            self.error('SYSTEM_ERROR',helper.handle,self.parse(request(3)),system);backend.assert_not_called()


class ReadonlyChecks(unittest.TestCase):
    def test_btrfs_super_requires_single_nonseeding_device_and_matching_checksum(self):
        good=b'num_devices 1\nbytenr 65536\nflags 0x1\ncsum 0x1234 [match]\nmagic _BHRfS_M [match]\n'
        worker.require_single_btrfs(good)
        for bad in [good.replace(b'num_devices 1',b'num_devices 2'),good.replace(b'flags 0x1',b'flags 0x101'),
                    good.replace(b'[match]',b'[bad]'),good+b'num_devices 1\n',good.replace(b'65536',b'0')]:
            with self.assertRaises(ValueError):worker.require_single_btrfs(bad)
    def test_real_normal_file_btrfs_super_and_fat_readonly_check(self):
        with tempfile.TemporaryDirectory() as td:
            paths=[Path(td)/name for name in ('a.img','b.img','fat.img')]
            for p in paths:
                with p.open('wb') as stream:stream.truncate(256*1024*1024)
            subprocess.run(['mkfs.btrfs','-q','-f',str(paths[0])],capture_output=True,check=True,timeout=15)
            fd=os.open(paths[0],os.O_RDONLY)
            try:worker.require_single_btrfs(worker.run_probe('btrfs-super',fd,(fd,)))
            finally:os.close(fd)
            subprocess.run(['mkfs.btrfs','-q','-f','-d','raid1','-m','raid1',str(paths[0]),str(paths[1])],capture_output=True,check=True,timeout=15)
            fd=os.open(paths[0],os.O_RDONLY)
            try:
                with self.assertRaises(ValueError):worker.require_single_btrfs(worker.run_probe('btrfs-super',fd,(fd,)))
            finally:os.close(fd)
            subprocess.run(['mkfs.fat','-F32',str(paths[2])],capture_output=True,check=True,timeout=10)
            fd=os.open(paths[2],os.O_RDONLY)
            try:worker.run_probe('fat-check',fd,(fd,))
            finally:os.close(fd)
    def test_fat_clean_and_uuid_uniqueness_use_same_verified_readonly_descriptor(self):
        with tempfile.TemporaryDirectory() as td:
            path=Path(td)/'file';path.touch()
            binding={'mountPoint':'/boot/efi','formatOnInstall':False}
            raw=b'TYPE=vfat\nVERSION=FAT32\nUSAGE=filesystem\nUUID=1234-ABCD\n'
            for duplicates in [False,True]:
                calls=[]
                def probe(kind,fd,inherited,uuid=None):
                    calls.append((kind,fd))
                    if kind=='signature':return raw
                    if kind=='fat-check':return b''
                    self.assertEqual(uuid,'1234-ABCD')
                    return (str(path)+'\n'+('/dev/other\n' if duplicates else '')).encode()
                with mock.patch.object(worker,'partition_descriptor',return_value=(str(path),'8:1')),mock.patch.object(worker,'run_probe',side_effect=probe):
                    if duplicates:
                        with self.assertRaises(ValueError):worker.probe_filesystem({},binding,admission=True)
                    else:self.assertEqual(worker.probe_filesystem({},binding,admission=True),'vfat')
                self.assertEqual([kind for kind,fd in calls],['signature','fat-check','uuid'])
                self.assertEqual(len({fd for kind,fd in calls}),1)
                with self.assertRaises(OSError):os.fstat(calls[0][1])


if __name__=='__main__':unittest.main(verbosity=2)
