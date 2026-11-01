"""Free-space admission/gate and regular-file create-only preservation tests."""
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
from gpt_probe_test import Image,FakeGptSystem,gpt

helper=legacy.helper
IDS={'esp':'55555555-5555-5555-5555-555555555555','root':'66666666-6666-6666-6666-666666666666'}
def fixture():return json.loads((legacy.ROOT/'test/fixtures/free_space_execution_v1.json').read_text())
def public_request():
    f=fixture();device=f['snapshot']['device']
    return {'protocolVersion':2,'operation':'install-free-space','disk':device['path'],
            'expectedDevice':{k:v for k,v in device.items() if k!='path'},'confirmDestructive':True,'confirmedPlan':f['approval']['intent']}


class System(FakeGptSystem):
    def __init__(self):super().__init__();self.probes=0;self.drift=False
    def gpt_snapshot(self,device,preserve_slots=None):
        self.probes+=1;f=fixture()
        if preserve_slots is None:return f['snapshot']
        value={'snapshot':f['snapshot'],'preservationFingerprint':f['approval']['preservationFingerprint']}
        if self.drift and self.probes>=3:value['snapshot']['tableFingerprint']='b'*64
        return value


class FreeSpaceTests(unittest.TestCase):
    def error(self,code,action,*args,**kwargs):
        with self.assertRaises(helper.HelperError) as caught:action(*args,**kwargs)
        self.assertEqual(caught.exception.code,code)
    def parse(self,data=None):return helper.parse_request(json.dumps(data or public_request()).encode(),2)
    def test_explicit_v2_confirmation_has_no_public_inventory_or_guid_override(self):
        self.assertEqual(self.parse().operation,'install-free-space')
        for change in [{'confirmDestructive':False},{'confirmDestructive':1},{'sourceSnapshot':fixture()['snapshot']},
                       {'allocationGuids':IDS},{'confirmedPlan':fixture()['approval']},{'partitionMethod':'free_space'},{'fileSystem':'btrfs'}]:
            self.error('INVALID_REQUEST',self.parse,{**public_request(),**change})
        self.error('INVALID_REQUEST',helper.parse_request,json.dumps({**public_request(),'protocolVersion':1}).encode(),version=1)
    def run_child(self,system=None,body=None):
        system=system or System()
        body=body or '''assert request['operation']=='install-free-space'
assert request['confirmedPlan']['allocationGuids']=={'esp':'55555555-5555-5555-5555-555555555555','root':'66666666-6666-6666-6666-666666666666'}
assert 'sourceSnapshot' in request
print(json.dumps({'protocolVersion':1,'type':'ready','confirmedPlan':request['confirmedPlan']}),flush=True)
gate=json.loads(sys.stdin.readline())
assert gate['confirmedPlan']==request['confirmedPlan']
print(json.dumps({'protocolVersion':1,'type':'result','ok':True,'code':'OK'}),flush=True)
'''
        with tempfile.TemporaryDirectory() as td:
            script=Path(td)/'backend.py';script.write_text(legacy.BackendBridgeTests.prefix+body)
            with mock.patch.object(helper.os,'geteuid',return_value=0),mock.patch.object(helper,'InstallerLock') as lock,\
                 mock.patch.object(helper,'BACKEND_ARGV',(sys.executable,'-I',str(script))),mock.patch.object(helper.uuid,'uuid4',side_effect=[uuid.UUID(IDS['esp']),uuid.UUID(IDS['root'])]):
                lock.return_value.__enter__.return_value.fd=None
                return helper.handle(self.parse(),system)
    def test_helper_assigns_ownership_and_revalidates_gpt_at_real_pipe_gate(self):
        system=System();self.assertEqual(self.run_child(system),{'installed':True});self.assertEqual(system.probes,3)
        self.assertFalse(hasattr(system,'lease_fd'))
    def test_table_drift_at_mutation_gate_never_sends_continue(self):
        system=System();system.drift=True
        self.error('DEVICE_CHANGED',self.run_child,system)
        self.assertFalse(hasattr(system,'lease_fd'))
    def test_changed_proposal_fails_before_backend_start(self):
        data=public_request();data['confirmedPlan']['tableFingerprint']='b'*64
        with mock.patch.object(helper.os,'geteuid',return_value=0),mock.patch.object(helper,'InstallerLock'),mock.patch.object(helper,'run_backend') as run:
            self.error('DEVICE_CHANGED',helper.handle,self.parse(data),System());run.assert_not_called()
    def test_private_backend_message_overflow_is_rejected_before_spawn(self):
        system=System();request=self.parse();device=helper.validate_device(system,'/dev/vda')
        request=helper.dataclasses.replace(request,source_snapshot={'padding':'x'*9000})
        with mock.patch.object(helper.subprocess,'Popen') as spawn:
            self.error('INVALID_REQUEST',helper.run_backend,request,device,system,lambda _:None)
            spawn.assert_not_called()
    def test_owned_slots_only_are_excluded_from_preservation_proof(self):
        f=fixture();image=Image();slots=[3,4]
        before=gpt.verified_snapshot(image.read,f['snapshot']['device'],512,slots)
        self.assertEqual(before['preservationFingerprint'],f['approval']['preservationFingerprint'])
        data=copy.deepcopy(f['created']['snapshot']);after=Image(data=data)
        verified=gpt.verified_snapshot(after.read,data['device'],512,slots)
        self.assertEqual(verified['preservationFingerprint'],before['preservationFingerprint'])
        renamed=Image(name='DIFFERENT_EXISTING_NAME',data=data)
        self.assertNotEqual(gpt.verified_snapshot(renamed.read,data['device'],512,slots)['preservationFingerprint'],before['preservationFingerprint'])
        for bad in ([3,3],[True,4],[0,4],[3,129],[[],4]):
            with self.assertRaises(ValueError):gpt.verified_snapshot(image.read,data['device'],512,bad)
    def test_independent_sfdisk_append_preserves_every_unowned_metadata_byte(self):
        size=64*1024**3
        with tempfile.TemporaryDirectory() as td:
            path=Path(td)/'regular-file.img'
            with path.open('wb') as stream:stream.truncate(size)
            subprocess.run(['sfdisk','--no-reread','--no-tell-kernel','--wipe','never',str(path)],
                input='label: gpt\nunit: sectors\n\nstart=2048,size=1048576,type=U,name="Old EFI"\nstart=1050624,size=16777216,type=L,name="Old root"\n7 : start=18874368,size=2097152,type=L,name="Old data"\n',text=True,capture_output=True,timeout=10,check=True)
            device={'path':'/dev/vda','majorMinor':'252:0','size':size,'diskSequence':11}
            def read(slots=None):
                fd=os.open(path,os.O_RDONLY)
                try:return gpt.verified_snapshot(lambda off,n:os.pread(fd,n,off),device,512,slots)
                finally:os.close(fd)
            source=read();intent=gpt.compact_plan(source,{'startSector':source['partitions'][-1]['endSector']+1,'endSector':source['lastUsableSector']});slots=[intent['esp']['number'],intent['root']['number']]
            sentinels={}
            with path.open('r+b') as stream:
                for part in source['partitions']:
                    for sector in (part['startSector'], (part['startSector']+part['endSector'])//2, part['endSector']):
                        payload=bytes([part['number']])*512
                        sentinels[sector*512]=payload
                        stream.seek(sector*512);stream.write(payload)
            before=read(slots);lines=[]
            for role,type_guid in [('esp','c12a7328-f81f-11d2-ba4b-00a0c93ec93b'),('root','0fc63daf-8483-4772-8e79-3d69d8477de4')]:
                part=intent[role];lines.append(f'{part["number"]} : start={part["startSector"]}, size={part["endSector"]-part["startSector"]+1}, type={type_guid}, uuid={IDS[role]}, name="RoASD_{role}"')
            subprocess.run(['sfdisk','--append','--no-reread','--no-tell-kernel','--wipe','never','--wipe-partitions','never',str(path)],input='\n'.join(lines)+'\n',text=True,capture_output=True,timeout=10,check=True)
            after=read(slots)
            with path.open('rb') as stream:
                for offset,payload in sentinels.items():
                    stream.seek(offset);self.assertEqual(stream.read(len(payload)),payload)
            self.assertEqual(before['preservationFingerprint'],after['preservationFingerprint'])
            self.assertEqual(after['snapshot']['partitions'][:3],source['partitions'])
            self.assertEqual(len(after['snapshot']['partitions']),5)
            for role in ('esp','root'):
                actual=next(p for p in after['snapshot']['partitions'] if p['number']==intent[role]['number'])
                self.assertEqual(actual['partitionGuid'],IDS[role]);self.assertEqual(actual['startSector'],intent[role]['startSector']);self.assertEqual(actual['endSector'],intent[role]['endSector'])


if __name__=='__main__':unittest.main(verbosity=2)
