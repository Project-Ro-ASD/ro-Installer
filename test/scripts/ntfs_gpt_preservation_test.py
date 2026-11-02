#!/usr/bin/env python3
"""Synthetic GPT bytes only: narrow NTFS masks plus exact final layout checks."""
import copy
import json
import struct
import unittest
import uuid
import zlib
import installer_helper_test as legacy
from gpt_probe_test import Image, gpt

ROOT_GUID = '55555555-5555-5555-5555-555555555555'


def proposal(sector=512):
    rows=json.loads((legacy.ROOT/'test/fixtures/ntfs_shrink_plans_v1.json').read_text())
    return next(row['input'] for row in rows if row['name']==f'{sector}: following gap')


def proof(image, source=2, root=3):
    return gpt.verified_ntfs_snapshot(image.read,image.data['device'],image.sector,source,root)


def arrays(image, slot, offset, raw):
    for key in ('primaryEntriesLba','backupEntriesLba'):
        position=image.data[key]*image.sector;array=bytearray(image.blocks[position])
        start=(slot-1)*image.data['entryBytes']+offset;array[start:start+len(raw)]=raw
        image.blocks[position]=bytes(array)
    crc=zlib.crc32(array[:image.data['entryCount']*image.data['entryBytes']])
    image.header_change(13,crc);image.header_change(13,crc,backup=True)


def created(sector=512):
    p=proposal(sector);before=Image(sector,data=p['snapshot']);plan=gpt.ntfs_shrink_plan(p)
    current=copy.deepcopy(p['snapshot']);current['partitions'][1]['endSector']=plan['source']['newEndSector']
    current['partitions'].append({k:v for k,v in plan['root'].items() if k!='formatOnInstall'})
    current['partitions'][-1].update(partitionGuid=ROOT_GUID,attributesHex='0000000000000000')
    return p,before,Image(sector,data=current)


class PreservationTests(unittest.TestCase):
    def test_only_source_end_and_one_new_slot_can_change_for_both_sector_sizes(self):
        for sector in (512,4096):
            p,before,after=created(sector);first=proof(before);last=proof(after)
            self.assertEqual(first['preservationFingerprint'],last['preservationFingerprint'])
            self.assertNotEqual(first['snapshot']['tableFingerprint'],last['snapshot']['tableFingerprint'])
            self.assertEqual(gpt.verify_ntfs_created_layout(p,ROOT_GUID,first['preservationFingerprint'],last),last['snapshot'])
    def test_raw_source_identity_start_name_and_unowned_unused_bytes_are_protected(self):
        for sector in (512,4096):
            for slot,offset,raw in [(2,16,uuid.UUID('88888888-8888-8888-8888-888888888888').bytes_le),(2,32,struct.pack('<Q',2*1024**3//sector)),
                                  (2,56,'CHANGED'.encode('utf-16-le')),(7,56,'CHANGED'.encode('utf-16-le')),
                                  (4,56,b'residual-unused-name')]:
                _,before,after=created(sector);initial=proof(before)['preservationFingerprint']
                arrays(after,slot,offset,raw)
                self.assertNotEqual(initial,proof(after)['preservationFingerprint'])
    def test_protective_mbr_and_reserved_array_padding_are_protected(self):
        p,before,after=created();initial=proof(before)['preservationFingerprint']
        mbr=bytearray(after.blocks[0]);mbr[0]=1;after.blocks[0]=bytes(mbr)
        self.assertNotEqual(initial,proof(after)['preservationFingerprint'])
        # Use fewer entries so the mandatory 16 KiB reservation has padding.
        p['snapshot']['entryCount']=64
        before=Image(data=p['snapshot']);initial=proof(before)['preservationFingerprint']
        for key in ('primaryEntriesLba','backupEntriesLba'):
            position=before.data[key]*512;raw=bytearray(before.blocks[position]);raw[-1]=1;before.blocks[position]=bytes(raw)
        self.assertNotEqual(initial,proof(before)['preservationFingerprint'])
    def test_source_protection_bits_and_wrong_slot_roles_fail_closed(self):
        for layout in [{'sourceNumber':True,'rootNumber':3},{'sourceNumber':2,'rootNumber':True},
                       {'sourceNumber':2,'rootNumber':2},{'sourceNumber':4,'rootNumber':3},
                       {'sourceNumber':1,'rootNumber':3},{'sourceNumber':2,'rootNumber':7},
                       {'sourceNumber':2,'rootNumber':129},{'sourceNumber':2,'rootNumber':3,'commands':[]}]:
            image=Image(data=proposal()['snapshot'])
            with self.assertRaises(ValueError):gpt.read_snapshot(image.read,image.data['device'],512,ntfs_layout=layout)
        image=Image(data=proposal()['snapshot'])
        self.assertNotEqual(proof(image,root=3)['preservationFingerprint'],proof(image,root=4)['preservationFingerprint'])
        arrays(image,2,48,struct.pack('<Q',1))
        with self.assertRaises(ValueError):proof(image)
    def test_exact_geometry_and_guid_checks_complement_the_root_slot_mask(self):
        for mutate in [lambda s:s['partitions'][-1].update(partitionGuid='66666666-6666-6666-6666-666666666666'),
                       lambda s:s['partitions'][-1].update(startSector=s['partitions'][-1]['startSector']+2048),
                       lambda s:s['partitions'][1].update(endSector=s['partitions'][1]['endSector']-2048)]:
            p,before,after=created();first=proof(before);changed=copy.deepcopy(after.data);mutate(changed)
            observed=proof(Image(data=changed))
            # Raw proof allows owned fields; the exact plan must still reject.
            self.assertEqual(first['preservationFingerprint'],observed['preservationFingerprint'])
            with self.assertRaises(ValueError):gpt.verify_ntfs_created_layout(p,ROOT_GUID,first['preservationFingerprint'],observed)
    def test_missing_root_wrong_proof_reused_guid_and_device_drift_are_rejected(self):
        p,before,after=created();first=proof(before);last=proof(after)
        for observed in [first,{**last,'preservationFingerprint':'b'*64},{**last,'commands':[]}]:
            with self.assertRaises(ValueError):gpt.verify_ntfs_created_layout(p,ROOT_GUID,first['preservationFingerprint'],observed)
        with self.assertRaises(ValueError):gpt.verify_ntfs_created_layout(p,p['snapshot']['diskGuid'],first['preservationFingerprint'],last)
        changed=copy.deepcopy(last);changed['snapshot']['device']['diskSequence']+=1
        with self.assertRaises(ValueError):gpt.verify_ntfs_created_layout(p,ROOT_GUID,first['preservationFingerprint'],changed)
    def test_drift_between_complete_reads_and_conflicting_masks_are_rejected(self):
        _,before,after=created();calls=0;first_read_count=len(before.blocks)*1
        def read(offset,length):
            nonlocal calls
            calls+=1
            return (before if calls<=first_read_count else after).read(offset,length)
        with self.assertRaises(ValueError):gpt.verified_ntfs_snapshot(read,before.data['device'],512,2,3)
        with self.assertRaises(ValueError):gpt.read_snapshot(before.read,before.data['device'],512,[3],ntfs_layout={'sourceNumber':2,'rootNumber':3})


if __name__ == '__main__':
    unittest.main()
