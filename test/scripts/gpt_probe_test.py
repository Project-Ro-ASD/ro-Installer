#!/usr/bin/env python3
"""Synthetic GPT bytes and fake child/sysfs tests; no block-device access."""
import ast
import copy
import io
import json
import os
from pathlib import Path
import stat
import struct
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
import zlib
from contextlib import redirect_stdout, redirect_stderr
from types import SimpleNamespace
from unittest import mock
import installer_helper_test as legacy

helper=legacy.helper
gpt=legacy.load_module('gpt_probe_worker',legacy.ROOT/'linux/ro_installer_gpt.py')


class Image:
    def __init__(self,sector=512,name='PRIVATE_PARTITION_NAME',data=None):
        self.data=copy.deepcopy(data or json.loads((legacy.ROOT/'test/fixtures/gpt_disk_snapshot_v1.json').read_text()))
        s=self.data;old=s['logicalSectorBytes']
        for p in s['partitions']:
            p['startSector']=p['startSector']*old//sector;p['endSector']=(p['endSector']+1)*old//sector-1
        s['logicalSectorBytes']=sector;self.sector=sector;total=s['device']['size']//sector
        reserved=(max(16384,s['entryCount']*s['entryBytes'])+sector-1)//sector
        s['firstUsableSector']=1048576//sector;s['lastUsableSector']=total-reserved-2;s['backupEntriesLba']=total-reserved-1
        array=bytearray(reserved*sector)
        for p in s['partitions']:
            offset=(p['number']-1)*s['entryBytes']
            array[offset:offset+16]=uuid.UUID(p['typeGuid']).bytes_le
            array[offset+16:offset+32]=uuid.UUID(p['partitionGuid']).bytes_le
            struct.pack_into('<QQQ',array,offset+32,p['startSector'],p['endSector'],int(p['attributesHex'],16))
            label=name.encode('utf-16-le')[:72];array[offset+56:offset+56+len(label)]=label
        crc=zlib.crc32(array[:s['entryCount']*s['entryBytes']])
        def header(own,other,lba):
            raw=bytearray(sector)
            gpt.HEADER.pack_into(raw,0,b'EFI PART',0x10000,92,0,0,own,other,s['firstUsableSector'],s['lastUsableSector'],uuid.UUID(s['diskGuid']).bytes_le,lba,s['entryCount'],s['entryBytes'],crc)
            struct.pack_into('<I',raw,16,zlib.crc32(raw[:92]));return bytes(raw)
        mbr=bytearray(sector);mbr[510:512]=b'\x55\xaa';mbr[450]=0xee
        struct.pack_into('<II',mbr,454,1,min(total-1,0xffffffff))
        self.blocks={0:bytes(mbr),sector:header(1,total-1,s['primaryEntriesLba']),
            (total-1)*sector:header(total-1,1,s['backupEntriesLba']),
            s['primaryEntriesLba']*sector:bytes(array),s['backupEntriesLba']*sector:bytes(array)}
        self.reads=[]
    def read(self,offset,length):
        self.reads.append((offset,length))
        return self.blocks.get(offset,b'')[:length]
    def snapshot(self):return gpt.verified_snapshot(self.read,self.data['device'],self.sector)
    def header_change(self,index,value,backup=False):
        offset=(self.data['device']['size']//self.sector-1)*self.sector if backup else self.sector
        raw=bytearray(self.blocks[offset]);fields=list(gpt.HEADER.unpack_from(raw));fields[index]=value;fields[3]=0
        gpt.HEADER.pack_into(raw,0,*fields);struct.pack_into('<I',raw,16,zlib.crc32(raw[:min(fields[2],self.sector)]));self.blocks[offset]=bytes(raw)


class OsProxy:
    def __getattr__(self,name):return getattr(os,name)


class SysPath:
    def __init__(self,path,files,children):self.path=path;self.files=files;self.children=children
    def __str__(self):return self.path
    def resolve(self,strict=True):return self
    def __truediv__(self,name):return SysPath(self.path+'/'+name,self.files,self.children)
    def read_text(self):
        if self.path not in self.files:raise FileNotFoundError(self.path)
        if isinstance(self.files[self.path],Exception):raise self.files[self.path]
        return self.files[self.path]
    def exists(self):return self.path in self.files
    def iterdir(self):return iter(SysPath(self.path+'/'+name,self.files,self.children) for name in self.children)


class GptBytesTests(unittest.TestCase):
    def test_independent_sfdisk_gpt_in_a_sparse_regular_file(self):
        with tempfile.TemporaryDirectory() as td:
            path=Path(td)/'regular-file.img';size=2*1024**3
            with path.open('wb') as stream:stream.truncate(size)
            created=subprocess.run(['sfdisk','--no-reread','--no-tell-kernel','--wipe','never',str(path)],
                input='label: gpt\nunit: sectors\n\nstart=2048,size=1048576,type=U,name="EFI"\nstart=1050624,size=1048576,type=L,name="Root"\n',
                text=True,capture_output=True,timeout=10,check=True)
            self.assertEqual(created.returncode,0)
            expected={**Image().data['device'],'size':size}
            fd=os.open(path,os.O_RDONLY)
            try:snapshot=gpt.verified_snapshot(lambda off,n:os.pread(fd,n,off),expected,512)
            finally:os.close(fd)
            self.assertEqual(len(snapshot['partitions']),2)
            self.assertEqual(snapshot['partitions'][0]['typeGuid'],'c12a7328-f81f-11d2-ba4b-00a0c93ec93b')
            self.assertEqual((snapshot['partitions'][0]['startSector'],snapshot['partitions'][0]['endSector']),(2048,1050623))
            self.assertEqual(snapshot['partitions'][1]['typeGuid'],'0fc63daf-8483-4772-8e79-3d69d8477de4')
            self.assertNotIn('Root',json.dumps(snapshot))
    def test_valid_512_and_4kn_match_normalized_inventory(self):
        for sector in (512,4096):
            image=Image(sector);snapshot=image.snapshot()
            expected=copy.deepcopy(image.data);expected['tableFingerprint']=snapshot['tableFingerprint']
            self.assertEqual(snapshot,expected)
            self.assertNotIn('PRIVATE_PARTITION_NAME',json.dumps(snapshot))
            self.assertEqual(len(snapshot['tableFingerprint']),64)
            self.assertTrue(all(n<=4*1024*1024 and off+n<=snapshot['device']['size'] for off,n in image.reads))
    def test_shared_compact_intent_fixture(self):
        snapshot=Image().snapshot();sector=snapshot['logicalSectorBytes']
        extent={'startSector':80*1024**3//sector,'endSector':160*1024**3//sector-1}
        intent=gpt.compact_plan(snapshot,extent)
        expected=json.loads((legacy.ROOT/'test/fixtures/free_space_intent_v1.json').read_text())
        self.assertEqual(intent,expected)
        for bad in ({'startSector':extent['startSector']+1,'endSector':extent['endSector']}, {'startSector':True,'endSector':1}, {'startSector':0,'endSector':100}):
            with self.assertRaises(ValueError):gpt.compact_plan(snapshot,bad)
    def test_both_header_crcs_and_array_crcs_are_required(self):
        image=Image()
        for offset in list(image.blocks)[1:]:
            broken=Image();raw=bytearray(broken.blocks[offset]);raw[16 if len(raw)==512 else 56]^=1;broken.blocks[offset]=bytes(raw)
            with self.assertRaises(ValueError):broken.snapshot()
    def test_hybrid_mbr_and_incorrect_protective_capacity_rejected(self):
        for mode in ('hybrid','capacity','signature','type'):
            image=Image();raw=bytearray(image.blocks[0])
            if mode=='hybrid':raw[466]=7
            if mode=='capacity':struct.pack_into('<I',raw,458,1)
            if mode=='signature':raw[510]=0
            if mode=='type':raw[450]=7
            image.blocks[0]=bytes(raw)
            with self.assertRaises(ValueError):image.snapshot()
    def test_header_geometry_revision_capacity_and_copy_disagreement_rejected(self):
        for index,value in [(1,0x20000),(2,513),(4,1),(5,2),(6,1),(7,1),(10,2048),(11,4097),(12,129)]:
            image=Image();image.header_change(index,value)
            with self.assertRaises(ValueError):image.snapshot()
        image=Image();image.header_change(9,uuid.UUID('55555555-5555-5555-5555-555555555555').bytes_le,backup=True)
        with self.assertRaises(ValueError):image.snapshot()
    def test_short_reads_and_normalized_invalid_types_rejected(self):
        image=Image()
        with self.assertRaises(ValueError):gpt.verified_snapshot(lambda o,n:image.read(o,n)[:-1],image.data['device'],512)
        snapshot=image.snapshot()
        for change in ({'entryCount':True},{'entryBytes':129},{'primaryEntriesLba':snapshot['firstUsableSector']},{'logicalSectorBytes':1024},{'schemaVersion':1.0},{'path':'secret'}):
            with self.assertRaises(ValueError):gpt.normalize_snapshot({**snapshot,**change})
    def test_crc_valid_overlap_duplicates_and_out_of_bounds_rejected(self):
        for kind in ('overlap','duplicate-number-guid','outside','zero-guid'):
            data=copy.deepcopy(Image().data)
            if kind=='overlap':data['partitions'][1]['startSector']=data['partitions'][0]['endSector']
            if kind=='duplicate-number-guid':data['partitions'][1]['partitionGuid']=data['partitions'][0]['partitionGuid']
            if kind=='outside':data['partitions'][2]['endSector']=data['device']['size']//512
            if kind=='zero-guid':data['partitions'][1]['partitionGuid']='00000000-0000-0000-0000-000000000000'
            with self.assertRaises(ValueError):Image(data=data).snapshot()
    def test_private_labels_and_reserved_metadata_change_fingerprint_without_leaking_text(self):
        first=Image(name='FIRST_SECRET').snapshot();second=Image(name='SECOND_SECRET').snapshot()
        self.assertNotEqual(first['tableFingerprint'],second['tableFingerprint'])
        self.assertEqual(first['partitions'],second['partitions'])
        self.assertNotIn('SECRET',json.dumps(second))
    def test_changed_valid_table_between_reads_rejects(self):
        first,second=Image(name='ONE'),Image(name='TWO');passes=0
        def read(off,n):
            nonlocal passes
            if off==0:passes+=1
            return (first if passes==1 else second).read(off,n)
        with self.assertRaises(ValueError):gpt.verified_snapshot(read,first.data['device'],512)
    def test_output_cap_never_silently_truncates_occupied_inventory(self):
        data=copy.deepcopy(Image().data);data['partitions']=[]
        for n in range(1,34):
            data['partitions'].append({'number':n,'startSector':2048*n,'endSector':2048*n+1023,
                'typeGuid':'0fc63daf-8483-4772-8e79-3d69d8477de4','partitionGuid':str(uuid.UUID(int=n+100)), 'attributesHex':'0000000000000000'})
        with self.assertRaises(ValueError):Image(data=data).snapshot()


class WorkerTests(unittest.TestCase):
    def test_kernel_inventory_uses_512_byte_units_even_on_4kn(self):
        for sector in (512,4096):
            snapshot=Image(sector).snapshot();root='/sys/devices/mock/block/vda';files={root+'/dev':'252:0'};children=[]
            for p in snapshot['partitions']:
                name='vda'+str(p['number']);children.append(name);base=root+'/'+name
                files[base+'/partition']=str(p['number']);files[base+'/start']=str(p['startSector']*sector//512)
                files[base+'/size']=str((p['endSector']-p['startSector']+1)*sector//512)
            children.append('queue')
            with mock.patch.object(gpt,'Path',side_effect=lambda *args:SysPath(root,files,children)):
                gpt.verify_kernel_layout(snapshot)
                files[root+'/vda1/start']=str(int(files[root+'/vda1/start'])+1)
                with self.assertRaises(ValueError):gpt.verify_kernel_layout(snapshot)
                files[root+'/vda1/partition']=PermissionError('read denied')
                with self.assertRaises(PermissionError):gpt.verify_kernel_layout(snapshot)
    def test_sector_change_after_reads_rejects_and_releases_the_block_fd(self):
        proxy=OsProxy();proxy.open=mock.Mock(return_value=17);proxy.close=mock.Mock();image=Image()
        with mock.patch.object(gpt,'os',proxy),mock.patch.object(gpt,'fd_geometry',side_effect=[512,4096]),mock.patch.object(gpt,'verified_snapshot',return_value=image.snapshot()),mock.patch.object(gpt,'verify_kernel_layout'):
            with self.assertRaises(ValueError):gpt.probe_device('/dev/vda',image.data['device'])
        proxy.close.assert_called_once_with(17)
    def test_open_is_readonly_bound_to_expected_fd_and_always_closed(self):
        image=Image();proxy=OsProxy();proxy.open=mock.Mock(return_value=17);proxy.close=mock.Mock()
        proxy.pread=mock.Mock(side_effect=lambda fd,n,off:image.read(off,n))
        with mock.patch.object(gpt,'os',proxy),mock.patch.object(gpt,'fd_geometry',side_effect=[512,512]) as geom, mock.patch.object(gpt,'verify_kernel_layout'):
            value=gpt.probe_device('/dev/vda',image.data['device'])
        flags=proxy.open.call_args.args[1]
        self.assertEqual(flags&os.O_ACCMODE,os.O_RDONLY)
        for bit in (os.O_NOFOLLOW,os.O_CLOEXEC,os.O_NONBLOCK,os.O_EXCL):self.assertTrue(flags&bit)
        self.assertFalse(flags&(os.O_CREAT|os.O_TRUNC));proxy.close.assert_called_once_with(17);self.assertEqual(geom.call_count,2)
        self.assertEqual(value['device'],image.data['device'])
    def test_fd_mismatch_regular_file_and_sequence_drift_reject(self):
        image=Image();proxy=OsProxy();proxy.fstat=mock.Mock(return_value=SimpleNamespace(st_mode=stat.S_IFREG|0o600,st_rdev=0))
        with mock.patch.object(gpt,'os',proxy),mock.patch.object(gpt,'fcntl',SimpleNamespace(ioctl=mock.Mock())) as fc:
            with self.assertRaises(ValueError):gpt.fd_geometry(17,image.data['device'])
            fc.ioctl.assert_not_called()
        proxy.fstat.return_value=SimpleNamespace(st_mode=stat.S_IFBLK|0o600,st_rdev=os.makedev(252,0))
        for sequence in (11,12):
            def ioctl(fd,op,arg):return struct.pack('=I',512) if op==0x1268 else struct.pack('=Q',image.data['device']['size'] if op==0x80081272 else sequence)
            with mock.patch.object(gpt,'os',proxy),mock.patch.object(gpt,'fcntl',SimpleNamespace(ioctl=ioctl)):
                if sequence==11:self.assertEqual(gpt.fd_geometry(17,image.data['device']),512)
                else:
                    with self.assertRaises(ValueError):gpt.fd_geometry(17,image.data['device'])
    def test_kernel_mismatch_failure_closes_fd_and_main_has_no_raw_diagnostics(self):
        proxy=OsProxy();proxy.open=mock.Mock(return_value=17);proxy.close=mock.Mock();proxy.geteuid=lambda:0
        image=Image()
        with mock.patch.object(gpt,'os',proxy),mock.patch.object(gpt,'fd_geometry',return_value=512),mock.patch.object(gpt,'verified_snapshot',return_value=image.snapshot()),mock.patch.object(gpt,'verify_kernel_layout',side_effect=ValueError('SECRET')):
            with self.assertRaises(ValueError):gpt.probe_device('/dev/vda',image.data['device'])
        proxy.close.assert_called_once_with(17)
        output=io.StringIO();errors=io.StringIO()
        with mock.patch.object(gpt,'os',proxy),mock.patch.object(sys,'argv',['worker','--probe','/dev/vda',json.dumps(image.data['device'])]),mock.patch.object(gpt,'probe_device',side_effect=ValueError('SECRET')),redirect_stdout(output),redirect_stderr(errors):
            self.assertEqual(gpt.main(),2)
        self.assertEqual(output.getvalue()+errors.getvalue(),'')
    def test_worker_source_has_no_disk_write_or_subprocess_api(self):
        tree=ast.parse((legacy.ROOT/'linux/ro_installer_gpt.py').read_text())
        for node in ast.walk(tree):
            if isinstance(node,(ast.Import,ast.ImportFrom)):
                self.assertNotIn(getattr(node,'module',None),('subprocess','shutil'))
                for name in node.names:self.assertNotIn(name.name,('subprocess','shutil'))
            if isinstance(node,ast.Call) and isinstance(node.func,ast.Attribute) and isinstance(node.func.value,ast.Name) and node.func.value.id=='os':
                self.assertNotIn(node.func.attr,('write','pwrite','truncate','ftruncate','system','execv','execve','unlink','remove'))


class FakeGptSystem(legacy.FakeSystem):
    def __init__(self):
        super().__init__();self.snapshot=Image().snapshot();size=self.snapshot['device']['size']
        self.data['blockdevices'][0]['size']=size;self.infos['252:0']['size']=size;self.calls=0
    def gpt_snapshot(self,device):self.calls+=1;return copy.deepcopy(self.snapshot)


class HelperAdmissionTests(legacy.ErrorAssertions,unittest.TestCase):
    def error(self,code,action,*args,**kwargs):
        with self.assertRaises(helper.HelperError) as raised:action(*args,**kwargs)
        self.assertEqual(raised.exception.code,code)
    def parse(self,op='probe-free-space',**extra):return helper.parse_request(json.dumps({'protocolVersion':2,'operation':op,'disk':'/dev/vda',**extra}).encode(),2)
    def test_new_operations_are_v2_only_and_reject_unknown_fields(self):
        system=FakeGptSystem();intent=gpt.compact_plan(system.snapshot,{'startSector':80*1024**3//512,'endSector':160*1024**3//512-1})
        for op,extra in [('probe-free-space',{}),('validate-free-space-plan',{'expectedDevice':{k:v for k,v in system.snapshot['device'].items() if k!='path'},'tableFingerprint':intent['tableFingerprint'],'selectedExtent':intent['selectedExtent']})]:
            value={'protocolVersion':2,'operation':op,'disk':'/dev/vda',**extra}
            helper.parse_request(json.dumps(value).encode(),2)
            self.error('INVALID_REQUEST',helper.parse_request,json.dumps({**value,'protocolVersion':1}).encode(),version=1)
            for field in ('command','argv','path','confirmedPlan','confirmDestructive'):
                self.error('INVALID_REQUEST',helper.parse_request,json.dumps({**value,field:True}).encode(),version=2)
    def test_probe_and_fresh_validation_use_lock_and_never_start_backend(self):
        system=FakeGptSystem();request=self.parse()
        with mock.patch.object(helper.os,'geteuid',return_value=0),mock.patch.object(helper,'InstallerLock') as lock,mock.patch.object(helper,'run_backend') as backend:
            lock.return_value.__enter__.return_value.fd=123
            result=helper.handle(request,system);self.assertEqual(result['snapshot'],system.snapshot)
            extent={'startSector':80*1024**3//512,'endSector':160*1024**3//512-1}
            req=self.parse('validate-free-space-plan',expectedDevice={k:v for k,v in system.snapshot['device'].items() if k!='path'},tableFingerprint=system.snapshot['tableFingerprint'],selectedExtent=extent)
            self.assertEqual(helper.handle(req,system),{'plan':gpt.compact_plan(system.snapshot,extent)})
            self.assertEqual(lock.call_count,2);backend.assert_not_called();self.assertFalse(hasattr(system,'lease_fd'))
    def test_stale_device_table_or_occupied_range_reject(self):
        system=FakeGptSystem();expected={k:v for k,v in system.snapshot['device'].items() if k!='path'}
        base={'expectedDevice':expected,'tableFingerprint':system.snapshot['tableFingerprint'],'selectedExtent':{'startSector':80*1024**3//512,'endSector':160*1024**3//512-1}}
        with mock.patch.object(helper.os,'geteuid',return_value=0),mock.patch.object(helper,'InstallerLock'):
            self.error('DEVICE_CHANGED',helper.handle,self.parse('validate-free-space-plan',**{**base,'tableFingerprint':'b'*64}),system)
            self.error('DEVICE_CHANGED',helper.handle,self.parse('validate-free-space-plan',**{**base,'expectedDevice':{**expected,'diskSequence':12}}),system)
            self.error('INVALID_REQUEST',helper.handle,self.parse('validate-free-space-plan',**{**base,'selectedExtent':{'startSector':2048,'endSector':999999}}),system)
            real=helper.validate_device;calls=0
            def changed(sys,path):
                nonlocal calls
                calls+=1;value=real(sys,path)
                return value if calls==1 else helper.Device(value.path,value.major_minor,value.size,99,value.sysfs_path)
            with mock.patch.object(helper,'validate_device',side_effect=changed):
                self.error('DEVICE_CHANGED',helper.handle,self.parse(),system)
    def test_root_platform_busy_and_active_disk_guards_precede_gpt_reads(self):
        system=FakeGptSystem()
        with mock.patch.object(helper.os,'geteuid',return_value=1000):self.error('ROOT_REQUIRED',helper.handle,self.parse(),system)
        with mock.patch.object(helper.os,'geteuid',return_value=0):
            system.supported=False;self.error('UNSUPPORTED_PLATFORM',helper.handle,self.parse(),system);system.supported=True
            with mock.patch.object(helper,'InstallerLock',side_effect=helper.HelperError('BUSY','busy')):
                self.error('BUSY',helper.handle,self.parse(),system)
            with mock.patch.object(helper,'InstallerLock'):
                request=helper.parse_request(json.dumps({'protocolVersion':2,'operation':'probe-free-space','disk':'/dev/sda'}).encode(),2)
                self.error('UNSAFE_DEVICE',helper.handle,request,system)
        self.assertEqual(system.calls,0)
    def test_worker_child_output_deadline_and_inherited_lease(self):
        image=Image();device=helper.Device('/dev/vda','252:0',image.data['device']['size'],11,'/sys/devices/mock/vda')
        snapshot=image.snapshot()
        with tempfile.TemporaryDirectory() as td:
            stub=Path(td)/'worker.py';lease=os.open(Path(td)/'lease',os.O_CREAT|os.O_RDWR,0o600)
            try:
                system=helper.System();system.lease_fd=lease
                stub.write_text(f'import os,json\nos.fstat({lease})\nprint('+repr(json.dumps(snapshot))+')\n')
                with mock.patch.object(helper,'GPT_ARGV',(sys.executable,'-I',str(stub))):
                    self.assertEqual(system.gpt_snapshot(device),snapshot)
                    stub.write_text("print('x'*9000)\n");self.error('AMBIGUOUS_TOPOLOGY',system.gpt_snapshot,device)
                    stub.write_text('import time\ntime.sleep(60)\n');start=time.monotonic()
                    with mock.patch.object(helper,'GPT_TIMEOUT',0.1):self.error('SYSTEM_ERROR',system.gpt_snapshot,device)
                    self.assertLess(time.monotonic()-start,3)
                    stub.write_text('import os,time\nos.close(1)\nos.close(2)\ntime.sleep(60)\n')
                    with mock.patch.object(helper,'GPT_TIMEOUT',0.1):self.error('SYSTEM_ERROR',system.gpt_snapshot,device)
            finally:os.close(lease)


if __name__=='__main__':unittest.main(verbosity=2)
