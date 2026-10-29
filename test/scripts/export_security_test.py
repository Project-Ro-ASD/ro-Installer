"""Disposable, unprivileged export attacks and write-fault assertions."""
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT=Path(__file__).resolve().parents[2]
SCRIPT=ROOT/'linux/ro-installer-export'
loader=importlib.machinery.SourceFileLoader('user_export',str(SCRIPT));spec=importlib.util.spec_from_loader(loader.name,loader)
module=importlib.util.module_from_spec(spec);loader.exec_module(module)
CHILD=r'''
import importlib.machinery,importlib.util,json,os,sys
from pathlib import Path
loader=importlib.machinery.SourceFileLoader('fixture_export',sys.argv[1]);spec=importlib.util.spec_from_loader(loader.name,loader)
m=importlib.util.module_from_spec(spec);loader.exec_module(m)
request=json.loads(sys.stdin.read());mode=request.pop('fixtureMode')
target=Path(request['target']);target.mkdir(mode=0o700)
identity='a'*32
if mode in ('symlink','hardlink','directory','file','pending'):
 victim=target/'victim';victim.write_text('unaltered')
 final=target/('install-'+identity)
 if mode=='symlink':final.symlink_to(victim)
 if mode=='hardlink':os.link(victim,final)
 if mode=='directory':final.mkdir()
 if mode=='file':final.write_text('unaltered')
 if mode=='pending':(target/('.install-'+identity)).mkdir()
if mode=='unsafe':target.chmod(0o777)
if mode=='target-symlink':
 target.rename(str(target)+'-victim');target.symlink_to(str(target)+'-victim')
kw={'token':lambda _:identity}
if mode=='enospc':
 def write(*_):raise OSError(28,'SECRET_SENTINEL')
 kw['write']=write
if mode=='partial':
 kw['write']=lambda fd,data:os.write(fd,data[:3])
if mode=='zero':kw['write']=lambda *_:0
if mode=='sync':
 def sync(*_):raise OSError(5,'SECRET_SENTINEL')
 kw['sync']=sync
result=m.export_package(request,**kw)
result['victimUnchanged']=not (target/'victim').exists() or (target/'victim').read_text()=='unaltered'
result['members']=sorted(p.name for p in target.iterdir())
print(json.dumps(result))
'''
class ExportTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='p0-04-export-')
        if os.geteuid()==0:os.chmod(self.temp.name,0o1777)
    def tearDown(self):self.temp.cleanup()
    def run_export(self,mode):
        request={'fixtureMode':mode,'target':self.temp.name+'/bundle','files':{'install.log':'safe text','summary.json':'{}'}}
        def drop():
            os.setgroups([]);os.setgid(65534);os.setuid(65534)
        p=subprocess.run([sys.executable,'-I','-c',CHILD,str(SCRIPT)],input=json.dumps(request),capture_output=True,text=True,preexec_fn=drop if os.geteuid()==0 else None,timeout=10)
        self.assertEqual(p.returncode,0,p.stderr);self.assertNotIn('SECRET_SENTINEL',p.stdout)
        return json.loads(p.stdout)
    def test_success_modes_and_manifest_hashes(self):
        result=self.run_export('success');self.assertTrue(result['success'])
        folder=Path(result['manifestPath']).parent
        self.assertEqual(stat.S_IMODE(folder.stat().st_mode),0o700)
        for path in folder.iterdir():self.assertEqual(stat.S_IMODE(path.stat().st_mode),0o600)
        manifest=json.loads(Path(result['manifestPath']).read_text());self.assertTrue(manifest['complete'])
        import hashlib
        for name,entry in manifest['files'].items():self.assertEqual(hashlib.sha256((folder/name).read_bytes()).hexdigest(),entry['sha256'])
    def test_symlink_never_followed(self):self.assert_refused('symlink')
    def test_writable_target_refused(self):self.assert_refused('unsafe')
    def test_target_directory_symlink_refused(self):self.assert_refused('target-symlink')
    def test_hardlink_never_modified(self):self.assert_refused('hardlink')
    def test_existing_file_never_overwritten(self):self.assert_refused('file')
    def test_existing_directory_never_overwritten(self):self.assert_refused('directory')
    def test_preexisting_pending_directory_is_not_removed(self):
        result=self.run_export('pending');self.assertFalse(result['success']);self.assertIn('.install-'+'a'*32,result['members'])
    def assert_refused(self,mode):
        result=self.run_export(mode);self.assertFalse(result['success']);self.assertTrue(result['victimUnchanged'])
        self.assertFalse(any(s.startswith('.install-') for s in result['members']))
    def test_partial_writes_are_completed(self):self.assertTrue(self.run_export('partial')['success'])
    def test_enospc_removes_only_own_unpublished_bundle(self):
        result=self.run_export('enospc');self.assertFalse(result['success']);self.assertEqual(result['members'],[])
    def test_zero_write_removes_only_own_unpublished_bundle(self):
        result=self.run_export('zero');self.assertFalse(result['success']);self.assertEqual(result['members'],[])
    def test_sync_error_does_not_publish_partial_package(self):
        result=self.run_export('sync');self.assertFalse(result['success']);self.assertEqual(result['members'],[])
    def test_root_refused_before_input_target_access(self):
        with mock.patch.object(module.os,'geteuid',return_value=0):
            self.assertEqual(module.export_package({'target':'/root/arbitrary'}),{'success':False,'error':'EXPORT_ROOT_DENIED'})
    def test_unknown_input_fields_not_accepted(self):
        with mock.patch.object(module.os,'geteuid',return_value=1000):
            result=module.export_package({'target':'/tmp','files':{},'command':'arbitrary'})
            self.assertEqual(result['error'],'EXPORT_INPUT_INVALID')

if __name__=='__main__':unittest.main(verbosity=2)
