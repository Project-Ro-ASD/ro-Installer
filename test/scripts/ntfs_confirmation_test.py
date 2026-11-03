"""Minimal public confirmation parity; pure objects, no storage access."""
import copy,json,unittest
import installer_helper_test as legacy
from ntfs_approval_test import mutate

gpt=legacy.load_module('ntfs_confirmation_contract',legacy.ROOT/'linux/ro_installer_gpt.py')
CASES=json.loads((legacy.ROOT/'test/fixtures/ntfs_confirmations_v1.json').read_text())
PREPARED=json.loads((legacy.ROOT/'test/fixtures/ntfs_preparations_v1.json').read_text())['bases']

class ConfirmationTests(unittest.TestCase):
    def normalize(self,value,base=0,proposal=None,inspection=None):
        return gpt.normalize_ntfs_confirmation(value,PREPARED[base]['proposal'] if proposal is None else proposal,
            PREPARED[base]['response']['inspection']['inspectionFingerprint'] if inspection is None else inspection)

    def test_shared_confirmation_binds_both_sector_sizes_without_mutation(self):
        for index,row in enumerate(CASES['valid']):
            raw=copy.deepcopy(row['confirmation']);before=copy.deepcopy(raw)
            observed=self.normalize(raw,index)
            self.assertEqual(observed,before);self.assertEqual(raw,before)
            raw['intent']['source']['newEndSector']=0
            raw['selection']['rootBytes']=1
            self.assertEqual(observed,before)
            observed['intent']['subvolumes']['home']='/other'
            self.assertEqual(self.normalize(before,index),before)
            self.assertEqual(set(before),{'selection','intent','inspectionFingerprint','preparationFingerprint'})

    def test_shared_invalid_public_confirmation_vectors(self):
        for row in CASES['invalid']:
            with self.subTest(name=row['name']),self.assertRaises((ValueError,TypeError,KeyError)):
                self.normalize(mutate(CASES['valid'][0]['confirmation'],row))
        for raw in (None,[],True,'confirmation',1):
            with self.assertRaises(ValueError):self.normalize(raw)

    def test_fresh_inspection_minimum_identity_and_geometry_override_old_confirmation(self):
        raw=CASES['valid'][0]['confirmation']
        for path,value in [(['minimumFilesystemBytes'],PREPARED[0]['proposal']['minimumFilesystemBytes']+512),
                           (['rootBytes'],PREPARED[0]['proposal']['rootBytes']+1048576),
                           (['snapshot','device','diskSequence'],999),
                           (['snapshot','tableFingerprint'],'f'*64)]:
            proposal=mutate(PREPARED[0]['proposal'],{'op':'set','path':path,'value':value})
            with self.subTest(path=path),self.assertRaises(ValueError):self.normalize(raw,proposal=proposal)
        for fingerprint in ('f'*64,'A'*64,'a'*63,None,True):
            with self.subTest(fingerprint=fingerprint),self.assertRaises(ValueError):
                gpt.normalize_ntfs_confirmation(raw,PREPARED[0]['proposal'],fingerprint)

    def test_preparation_fingerprint_is_a_claim_for_the_guarded_worker_to_reproduce(self):
        raw=copy.deepcopy(CASES['valid'][0]['confirmation'])
        raw['preparationFingerprint']='f'*64
        self.assertEqual(self.normalize(raw),raw)
        # A shape-valid fingerprint does not prove fresh toolchain/metadata or
        # authorize mutation. Public admission must still gate the private worker.

if __name__=='__main__':unittest.main()
