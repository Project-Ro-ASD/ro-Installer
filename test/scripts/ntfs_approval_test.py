#!/usr/bin/env python3
"""Shared private NTFS ownership and final-layout parity; no device access."""
import copy
import json
from pathlib import Path
import unittest
from ntfs_shrink_plan_test import gpt

CASES = json.loads((Path(__file__).resolve().parents[1]/'fixtures/ntfs_approvals_v1.json').read_text())


def mutate(value, row):
    result = copy.deepcopy(value)
    parent = result
    for key in row['path'][:-1]: parent = parent[key]
    if row['op'] == 'remove': del parent[row['path'][-1]]
    else: parent[row['path'][-1]] = row['value']
    return result


class ApprovalTests(unittest.TestCase):
    def test_valid_canonical_approval_and_exact_created_layout(self):
        for base in CASES['bases']:
            before = copy.deepcopy(base['input'])
            result = gpt.normalize_ntfs_approval(before)
            self.assertEqual(result, before)
            proposal, approval = result['proposal'], result['approval']
            self.assertEqual(gpt.verify_ntfs_created_layout(proposal, approval['rootGuid'],
                approval['preservationFingerprint'],
                {'snapshot': base['created'], 'preservationFingerprint': base['proof']}), base['created'])
            result['proposal']['snapshot']['device']['diskSequence'] = 999
            result['approval']['intent']['root']['number'] = 4096
            self.assertEqual(before, base['input'])
            self.assertEqual(gpt.normalize_ntfs_approval(before), before)


def bad_approval(row):
    def check(self):
        value = mutate(CASES['bases'][row['base']]['input'], row)
        with self.assertRaises((ValueError, TypeError)): gpt.normalize_ntfs_approval(value)
    return check


def bad_created(row):
    def check(self):
        base = CASES['bases'][row['base']]
        proposal, approval = base['input']['proposal'], base['input']['approval']
        snapshot = base['created'] if row['op'] == 'proof' else mutate(base['created'], row)
        proof = row['value'] if row['op'] == 'proof' else base['proof']
        with self.assertRaises(ValueError):
            gpt.verify_ntfs_created_layout(proposal, approval['rootGuid'], approval['preservationFingerprint'],
                {'snapshot': snapshot, 'preservationFingerprint': proof})
    return check


for i, row in enumerate(CASES['invalidApprovals']):
    setattr(ApprovalTests, f'test_approval_{i:02d}_{row["name"]}', bad_approval(row))
for i, row in enumerate(CASES['invalidCreated']):
    setattr(ApprovalTests, f'test_created_{i:02d}_{row["name"]}', bad_created(row))

if __name__ == '__main__': unittest.main()
