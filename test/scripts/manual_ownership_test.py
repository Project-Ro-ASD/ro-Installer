"""Private layout proof regressions; fake device reads and regular files only."""
import copy
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest import mock
import installer_helper_test as legacy
from gpt_probe_test import Image, gpt
from manual_probe_test import worker, request

helper = legacy.helper


def fixtures():
    return json.loads((legacy.ROOT/'test/fixtures/manual_ownership_v1.json').read_text())


class OwnershipTests(unittest.TestCase):
    def test_shared_byte_images_produce_zero_one_and_two_slot_proofs(self):
        for value in fixtures():
            source = value['snapshot']; intent = value['approval']['intent']
            slots = [intent[role]['number'] for role in ('esp','root') if intent[role]['source']=='create']
            before = Image(data=source)
            after = Image(data=value['created']['snapshot'])
            source_result = gpt.verified_snapshot(before.read,source['device'],512,slots)
            created_result = gpt.verified_snapshot(after.read,source['device'],512,slots)
            self.assertEqual(source_result['snapshot'],source)
            self.assertEqual(source_result['preservationFingerprint'],value['approval']['preservationFingerprint'])
            self.assertEqual(created_result,value['created'])
            self.assertEqual(created_result['preservationFingerprint'],source_result['preservationFingerprint'])
            if slots:
                self.assertNotEqual(created_result['snapshot']['tableFingerprint'],source['tableFingerprint'])

    def test_old_names_and_unselected_entry_bytes_remain_inside_the_proof(self):
        for value in fixtures():
            source=value['snapshot']; intent=value['approval']['intent']
            slots=[intent[role]['number'] for role in ('esp','root') if intent[role]['source']=='create']
            changed=Image(name='DIFFERENT_PRIVATE_NAME',data=value['created']['snapshot'])
            proof=gpt.verified_snapshot(changed.read,source['device'],512,slots)['preservationFingerprint']
            self.assertNotEqual(proof,value['approval']['preservationFingerprint'])
            self.assertNotIn('PRIVATE_NAME',json.dumps(gpt.verified_snapshot(changed.read,source['device'],512,slots)))

    def test_internal_proof_bounds_and_legacy_public_worker_flag_are_distinct(self):
        image=Image(data=fixtures()[0]['snapshot'])
        for slots in ([],[3],[3,4]):
            self.assertIn('preservationFingerprint',gpt.verified_snapshot(image.read,image.data['device'],512,slots))
        for slots in (True,{},[True],[3,3],[1,2,3],[0],[129],[[]]):
            with self.assertRaises(ValueError):gpt.verified_snapshot(image.read,image.data['device'],512,slots)
        for slots in ([],[3]):
            with mock.patch.object(gpt.os,'geteuid',return_value=0),mock.patch.object(sys,'argv',
                ['worker','--probe','/dev/vda',json.dumps(image.data['device']),'--preserve-slots',json.dumps(slots)]),mock.patch.object(gpt,'probe_device') as probe:
                self.assertEqual(gpt.main(),2);probe.assert_not_called()

    def test_layout_worker_accepts_only_bounded_slots_and_emits_no_filesystem_metadata(self):
        value=fixtures()[1]; expected=value['created']
        for slots in ([],[3],[3,4]):
            with mock.patch.object(worker.gpt,'probe_device',return_value=expected) as probe:
                self.assertEqual(worker.probe_layout('/dev/vda',value['snapshot']['device'],slots),expected)
                probe.assert_called_once_with('/dev/vda',value['snapshot']['device'],preserve_slots=slots)
        for slots in (None,[True],[3,3],[1,2,3],[-1],[4097]):
            with mock.patch.object(worker.gpt,'probe_device') as probe:
                with self.assertRaises(ValueError):worker.probe_layout('/dev/vda',value['snapshot']['device'],slots)
                probe.assert_not_called()
        out=io.StringIO()
        with mock.patch.object(worker.os,'geteuid',return_value=0),mock.patch.object(worker,'probe_layout',return_value=expected), \
             mock.patch.object(sys,'argv',['worker','--layout','/dev/vda',json.dumps(value['snapshot']['device']),'[3]']),redirect_stdout(out):
            self.assertEqual(worker.main(),0)
        self.assertEqual(json.loads(out.getvalue()),expected)

    def test_helper_private_transport_preserves_empty_slot_list_and_exact_lease(self):
        value=fixtures()[0];device=helper.Device('/dev/vda','252:0',value['snapshot']['device']['size'],11,'/sys/mock/vda')
        with tempfile.TemporaryDirectory() as td:
            path=Path(td)/'worker.py';lease=os.open(Path(td)/'lease',os.O_CREAT|os.O_RDWR,0o600)
            try:
                system=helper.System();system.lease_fd=lease
                path.write_text(f"import sys,os\nos.fstat({lease})\nassert sys.argv[1]=='--layout' and sys.argv[-1]=='[]'\nprint({json.dumps(value['created'])!r})\n")
                with mock.patch.object(helper,'MANUAL_ARGV',(sys.executable,'-I',str(path))):
                    self.assertEqual(system.gpt_snapshot(device,layout_slots=[]),value['created'])
            finally:os.close(lease)

    def test_public_manual_requests_cannot_supply_private_ownership(self):
        for patch in ({'allocationGuids':{}},{'preservationFingerprint':'a'*64},
                      {'sourceSnapshot':fixtures()[0]['snapshot']},{'layoutSlots':[]}):
            with self.assertRaises(helper.HelperError) as caught:
                helper.parse_request(json.dumps({**request(),**patch}).encode(),2)
            self.assertEqual(caught.exception.code,'INVALID_REQUEST')

    def test_regular_file_one_append_preserves_all_other_metadata(self):
        with tempfile.TemporaryDirectory() as td:
            path=Path(td)/'disk.img';size=96*1024**3
            with path.open('wb') as stream:stream.truncate(size)
            subprocess.run(['sfdisk','--no-reread','--no-tell-kernel','--wipe','never',str(path)],
                input='label: gpt\nunit: sectors\n\nstart=2048,size=1048576,type=U\nstart=1050624,size=85983232,type=L\n',text=True,capture_output=True,check=True,timeout=10)
            device={'path':'/dev/vda','majorMinor':'252:0','size':size,'diskSequence':11}
            def read(slots):
                fd=os.open(path,os.O_RDONLY)
                try:return gpt.verified_snapshot(lambda off,n:os.pread(fd,n,off),device,512,slots)
                finally:os.close(fd)
            before=read([3]);unmasked=read([])
            subprocess.run(['sfdisk','--append','--no-reread','--no-tell-kernel','--wipe','never','--wipe-partitions','never',str(path)],
                input='3 : start=167772160,size=2097152,type=U,uuid=55555555-5555-5555-5555-555555555555\n',text=True,capture_output=True,check=True,timeout=10)
            after=read([3])
            self.assertEqual(before['preservationFingerprint'],after['preservationFingerprint'])
            self.assertEqual(before['snapshot']['partitions'],after['snapshot']['partitions'][:2])
            self.assertNotEqual(unmasked['preservationFingerprint'],read([])['preservationFingerprint'])


if __name__=='__main__':unittest.main(verbosity=2)
