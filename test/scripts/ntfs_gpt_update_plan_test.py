#!/usr/bin/env python3
"""Pure GPT patches plus independent parsing of new sparse normal files."""
import copy
import json
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
from gpt_probe_test import Image, gpt
from ntfs_gpt_preservation_test import proposal, proof, ROOT_GUID, arrays


def fixture(sector=512, count=128, entry=128):
    p=proposal(sector);p['snapshot']['entryCount']=count;p['snapshot']['entryBytes']=entry
    image=Image(sector,data=p['snapshot'])
    # Give both reservations different nonzero padding, plus protected names
    # and residue in an unused entry. These bytes must survive exactly.
    if count*entry < 16384:
        for number,key in enumerate(('primaryEntriesLba','backupEntriesLba'),1):
            offset=image.data[key]*sector;raw=bytearray(image.blocks[offset]);raw[-1]=number
            image.blocks[offset]=bytes(raw)
    arrays(image,4,56,b'UNOWNED-UNUSED-RESIDUE')
    arrays(image,3,56,b'OWNED-UNUSED-RESIDUE')
    arrays(image,3,entry-1,b'\xaa')
    mbr=bytearray(image.blocks[0]);mbr[0]=123;image.blocks[0]=bytes(mbr)
    initial=proof(image);p['snapshot']=initial['snapshot']
    return p,image,initial


def apply(image, groups):
    result=copy.deepcopy(image)
    for group in groups:
        for offset,original,replacement in group:
            if result.blocks[offset] != original: raise AssertionError('unexpected old metadata')
            result.blocks[offset]=replacement
    return result


class UpdatePlanTests(unittest.TestCase):
    def plan(self, p, image, initial, guid=ROOT_GUID):
        return gpt.ntfs_gpt_update_plan(image.read,p,guid,initial['preservationFingerprint'])

    def test_exact_immutable_backup_first_plan_for_sector_entry_sizes_and_padding(self):
        for sector in (512,4096):
            for count,entry in ((64,128),(128,128),(64,256),(32,512),(32,1024)):
                with self.subTest(sector=sector,count=count,entry=entry):
                    p,image,initial=fixture(sector,count,entry);before=copy.deepcopy(image.blocks)
                    groups=self.plan(p,image,initial);self.assertIsInstance(groups,tuple)
                    self.assertEqual([len(group) for group in groups],[2,2])
                    self.assertEqual([[op[0] for op in group] for group in groups],
                        [[p['snapshot']['backupEntriesLba']*sector,p['snapshot']['device']['size']-sector],
                         [p['snapshot']['primaryEntriesLba']*sector,sector]])
                    self.assertEqual(image.blocks,before)
                    after=apply(image,groups);observed=proof(after)
                    gpt.verify_ntfs_created_layout(p,ROOT_GUID,initial['preservationFingerprint'],observed)
                    self.assertEqual(after.blocks[0],before[0])
                    self.assertEqual(observed['preservationFingerprint'],initial['preservationFingerprint'])
                    self.assertNotEqual(observed['snapshot']['tableFingerprint'],initial['snapshot']['tableFingerprint'])
                    slot=(gpt.ntfs_shrink_plan(p)['root']['number']-1)*entry
                    for group in groups:
                        self.assertEqual(group[0][2][slot+56:slot+entry],bytes(entry-56))
                    for group in groups:
                        self.assertIsInstance(group,tuple)
                        for offset,old,new in group:
                            self.assertIsInstance(old,bytes);self.assertIsInstance(new,bytes)
                            self.assertEqual(len(old),len(new));self.assertEqual(offset%sector,0)
                    self.assertEqual(groups,self.plan(p,image,initial))

    def test_changed_bytes_are_limited_to_source_end_root_slot_and_crc_fields(self):
        p,image,initial=fixture();groups=self.plan(p,image,initial)
        plan=gpt.ntfs_shrink_plan(p);entry=p['snapshot']['entryBytes']
        allowed_source=set(range((plan['source']['number']-1)*entry+40,(plan['source']['number']-1)*entry+48))
        allowed_root=set(range((plan['root']['number']-1)*entry,plan['root']['number']*entry))
        for group in groups:
            for index,(_,old,new) in enumerate(group):
                changed={n for n,(a,b) in enumerate(zip(old,new)) if a!=b}
                self.assertTrue(changed <= (allowed_source|allowed_root if index==0 else set(range(16,20))|set(range(88,92))))
                self.assertTrue(changed)

    def test_reused_guid_stale_proof_and_snapshot_are_rejected_without_mutating_reader(self):
        p,image,initial=fixture();before=copy.deepcopy(image.blocks)
        for guid in (p['snapshot']['diskGuid'],p['snapshot']['partitions'][0]['partitionGuid'],
                     '00000000-0000-0000-0000-000000000000','AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA',None):
            with self.assertRaises(ValueError):self.plan(p,image,initial,guid)
        for fingerprint in ('b'*64,None,'',True):
            with self.assertRaises(ValueError):self.plan(p,image,{'preservationFingerprint':fingerprint})
        changed=copy.deepcopy(p);changed['snapshot']['tableFingerprint']='b'*64
        with self.assertRaises(ValueError):self.plan(changed,image,initial)
        self.assertEqual(image.blocks,before)

    def test_short_invalid_and_drifting_reads_refuse_before_returning_patches(self):
        p,image,initial=fixture();calls=len(image.blocks)*2
        after=apply(image,self.plan(p,image,initial))
        for threshold in (1,calls+1):
            observed=0
            def drifting(offset,length):
                nonlocal observed
                observed+=1
                return (image if observed<=threshold else after).read(offset,length)
            with self.assertRaises(ValueError):
                gpt.ntfs_gpt_update_plan(drifting,p,ROOT_GUID,initial['preservationFingerprint'])
        for reader in (lambda offset,length:b'',lambda offset,length:bytearray(image.read(offset,length))):
            with self.assertRaises(ValueError):gpt.ntfs_gpt_update_plan(reader,p,ROOT_GUID,initial['preservationFingerprint'])

    def test_independent_sfdisk_validates_new_normal_file_gpt_without_changing_metadata(self):
        for sector in (512,4096):
            p,image,initial=fixture(sector);after=apply(image,self.plan(p,image,initial))
            with tempfile.TemporaryDirectory() as td:
                path=Path(td)/'new-sparse-gpt.img'
                with path.open('xb') as stream:
                    stream.truncate(p['snapshot']['device']['size'])
                    for offset,raw in after.blocks.items():stream.seek(offset);stream.write(raw)
                self.assertTrue(stat.S_ISREG(path.lstat().st_mode));self.assertFalse(path.is_symlink())
                result=subprocess.run(['/usr/sbin/sfdisk','--sector-size',str(sector),'--verify',str(path)],
                                      capture_output=True,text=True,timeout=10)
                self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                parsed=json.loads(subprocess.run(['/usr/sbin/sfdisk','--sector-size',str(sector),'--json',str(path)],
                                                 capture_output=True,text=True,check=True,timeout=10).stdout)['partitiontable']
                root=next(part for part in parsed['partitions'] if part['uuid'].lower()==ROOT_GUID)
                expected=gpt.ntfs_shrink_plan(p)['root']
                self.assertEqual(root['start'],expected['startSector'])
                self.assertEqual(root['size'],expected['endSector']-expected['startSector']+1)
                self.assertEqual(root['type'].lower(),expected['typeGuid'])
                intent=gpt.ntfs_shrink_plan(p)
                for original in p['snapshot']['partitions']:
                    observed=next(part for part in parsed['partitions'] if part['uuid'].lower()==original['partitionGuid'])
                    end=intent['source']['newEndSector'] if original['number']==p['sourceNumber'] else original['endSector']
                    self.assertEqual(observed['start'],original['startSector'])
                    self.assertEqual(observed['size'],end-original['startSector']+1)
                    self.assertEqual(observed['type'].lower(),original['typeGuid'])
                with path.open('rb') as stream:
                    for offset,raw in after.blocks.items():
                        stream.seek(offset);self.assertEqual(stream.read(len(raw)),raw)


if __name__=='__main__':unittest.main()
