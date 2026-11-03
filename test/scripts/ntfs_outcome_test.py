#!/usr/bin/env python3
"""Private terminal parity and conservative unknown state; no device access."""
import copy
import json
from pathlib import Path
import unittest
import installer_helper_test as legacy
from ntfs_approval_test import mutate

core=legacy.load_module('ntfs_outcome_core',legacy.ROOT/'linux/ro_installer_ntfs_commit.py')
BASES=json.loads((legacy.ROOT/'test/fixtures/ntfs_approvals_v1.json').read_text())['bases']
CASES=json.loads((legacy.ROOT/'test/fixtures/ntfs_outcomes_v1.json').read_text())


def success(base):
    return {'schemaVersion':1,'status':'success','snapshot':copy.deepcopy(base['created']),
            'preservationFingerprint':base['proof']}


def failure():
    return {'schemaVersion':1,'status':'failed','phase':'gpt.verify','progressKnown':True,
            'sourceMayHaveChanged':True,'gptWriteStarted':True,'verifiedGptCopies':2,'cleanupFailed':False}


class OutcomeTests(unittest.TestCase):
    def test_success_requires_exact_owned_snapshot_and_successful_exit(self):
        for base in BASES:
            raw=success(base);before=copy.deepcopy(raw)
            result=core.normalize_ntfs_outcome(raw,base['input'],0)
            self.assertEqual(result,raw)
            result['snapshot']['partitions'][0]['endSector']=0
            self.assertEqual(raw,before)
            for code in (2,-9,True,None):
                with self.assertRaises(ValueError):core.normalize_ntfs_outcome(raw,base['input'],code)

    def test_not_started_and_unknown_are_distinct_and_canonical(self):
        no_start=core.ntfs_unknown_outcome(started=False)
        unknown=core.ntfs_unknown_outcome()
        self.assertTrue(no_start['progressKnown']);self.assertFalse(no_start['sourceMayHaveChanged'])
        self.assertFalse(unknown['progressKnown']);self.assertTrue(unknown['sourceMayHaveChanged'])
        for raw in (no_start,unknown):self.assertEqual(core.normalize_ntfs_outcome(raw,BASES[0]['input'],2),raw)
        for kwargs in ({'started':1},{'cleanup_failed':'yes'}):
            with self.assertRaises(ValueError):core.ntfs_unknown_outcome(**kwargs)


def valid_failure(row):
    def check(self):
        self.assertEqual(core.normalize_ntfs_outcome(row,BASES[0]['input'],2),row)
        for code in (0,-9):
            with self.assertRaises(ValueError):core.normalize_ntfs_outcome(row,BASES[0]['input'],code)
    return check


def invalid(row):
    def check(self):
        originals={'success':success(BASES[0]),'failure':failure(),'unknown':core.ntfs_unknown_outcome()}
        raw=mutate(originals[row['base']],row)
        with self.assertRaises(ValueError):core.normalize_ntfs_outcome(raw,BASES[0]['input'],0 if row['base']=='success' else 2)
    return check


for i,row in enumerate(CASES['failures']):setattr(OutcomeTests,f'test_failure_{i:02d}_{row["phase"]}',valid_failure(row))
for i,row in enumerate(CASES['invalid']):setattr(OutcomeTests,f'test_invalid_{i:02d}_{row["name"]}',invalid(row))
if __name__=='__main__':unittest.main()
