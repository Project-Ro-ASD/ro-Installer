#!/usr/bin/env python3
"""Pure NTFS geometry parity; no device or filesystem access."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('ntfs_plan_gpt', ROOT / 'linux/ro_installer_gpt.py')
gpt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gpt)
CASES = json.loads((ROOT / 'test/fixtures/ntfs_shrink_plans_v1.json').read_text())


class NtfsShrinkPlanTests(unittest.TestCase):
    pass


def case_test(row):
    def check(self):
        proposal = copy.deepcopy(row['input'])
        before = copy.deepcopy(proposal)
        if row['intent'] is None:
            with self.assertRaises(ValueError):
                gpt.ntfs_shrink_plan(proposal)
        else:
            intent = gpt.ntfs_shrink_plan(proposal)
            self.assertEqual(intent, row['intent'])
            # Returned maps cannot mutate the observed snapshot or next result.
            intent['source']['endSector'] = 0
            intent['device']['diskSequence'] = 0
            self.assertEqual(gpt.ntfs_shrink_plan(proposal), row['intent'])
        self.assertEqual(proposal, before)
    return check


for index, row in enumerate(CASES):
    setattr(NtfsShrinkPlanTests, f'test_{index:02d}_{row["name"]}', case_test(row))


if __name__ == '__main__':
    unittest.main()
