"""Read-only proof transport on new ordinary files; no block devices."""
import io,json,os,subprocess,time
from pathlib import Path
import sys,tempfile,unittest
from unittest import mock
sys.path.insert(0,'test/scripts')
import installer_helper_test as legacy
from ntfs_gpt_update_plan_test import fixture,apply
from ntfs_gpt_preservation_test import ROOT_GUID
from ntfs_native_runner_test import proxy

gpt=legacy.load_module('ntfs_readonly_gpt_probe',legacy.ROOT/'linux/ro_installer_gpt.py')
LAYOUT={'sourceNumber':2,'rootNumber':3}

class ProbeTests(unittest.TestCase):
    def test_readonly_bound_probe_before_and_after_metadata_commit_preserves_projection(self):
        for sector in (512,4096):
            p,image,before=fixture(sector)
            after=apply(image,gpt.ntfs_gpt_update_plan(image.read,p,ROOT_GUID,before['preservationFingerprint']))
            for current in (image,after):
                with tempfile.TemporaryDirectory() as td:
                    path=Path(td)/'new-normal-gpt'
                    with path.open('xb') as stream:
                        stream.truncate(p['snapshot']['device']['size'])
                        for offset,data in current.blocks.items():stream.seek(offset);stream.write(data)
                    opened=[]
                    def open_source(node,flags):
                        self.assertEqual(node,p['snapshot']['device']['path'])
                        self.assertEqual(flags,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW|os.O_NONBLOCK|os.O_EXCL)
                        fd=os.open(path,flags);opened.append(fd);return fd
                    with mock.patch.object(gpt,'os',proxy(os,open=open_source)), \
                         mock.patch.object(gpt,'fd_geometry',return_value=sector) as geometry, \
                         mock.patch.object(gpt,'verify_kernel_layout') as kernel:
                        observed=gpt.probe_device(p['snapshot']['device']['path'],p['snapshot']['device'],ntfs_layout=LAYOUT)
                    self.assertEqual(observed['preservationFingerprint'],before['preservationFingerprint'])
                    self.assertEqual(geometry.call_count,2);kernel.assert_called_once_with(observed['snapshot'])
                    with self.assertRaises(OSError):os.fstat(opened[0])
                    with path.open('rb') as stream:
                        for offset,data in current.blocks.items():stream.seek(offset);self.assertEqual(stream.read(len(data)),data)

    def test_invalid_or_conflicting_slots_refuse_before_open(self):
        p,_,_=fixture()
        for bad in (None,[],{}, {'sourceNumber':2,'rootNumber':2},{'sourceNumber':True,'rootNumber':3},
                    {'sourceNumber':2,'rootNumber':0},{'sourceNumber':2,'rootNumber':4097},
                    {'sourceNumber':2,'rootNumber':3,'extra':1}):
            with mock.patch.object(gpt.os,'open') as opened:
                if bad is None:
                    with self.assertRaises(ValueError):gpt.probe_device(p['snapshot']['device']['path'],p['snapshot']['device'],[3,4],ntfs_layout=LAYOUT)
                else:
                    with self.assertRaises(ValueError):gpt.probe_device(p['snapshot']['device']['path'],p['snapshot']['device'],ntfs_layout=bad)
                opened.assert_not_called()

    def test_cli_has_only_fixed_readonly_probe_and_strict_layout_binding(self):
        p,_,initial=fixture();output=io.StringIO()
        args=['worker','--probe',p['snapshot']['device']['path'],json.dumps(p['snapshot']['device']),'--ntfs-layout',json.dumps(LAYOUT)]
        with mock.patch.object(gpt,'os',proxy(os,geteuid=lambda:0)),mock.patch.object(gpt,'sys',proxy(sys,argv=args,stdout=output)), \
             mock.patch.object(gpt,'probe_device',return_value=initial) as probe:
            self.assertEqual(gpt.main(),0);self.assertEqual(json.loads(output.getvalue()),initial)
            probe.assert_called_once_with(args[2],p['snapshot']['device'],ntfs_layout=LAYOUT)
        for bad in ('[]','{"sourceNumber":2,"sourceNumber":2,"rootNumber":3}','{"sourceNumber":true,"rootNumber":3}','{"sourceNumber":2,"rootNumber":2}'):
            with mock.patch.object(gpt,'os',proxy(os,geteuid=lambda:0)),mock.patch.object(gpt,'sys',proxy(sys,argv=[*args[:-1],bad],stdout=io.StringIO())), \
                 mock.patch.object(gpt,'probe_device') as probe:
                self.assertEqual(gpt.main(),2);probe.assert_not_called()

class ProbeFailureTests(unittest.TestCase):
    def test_cli_root_shape_and_output_budget_fail_without_diagnostics(self):
        p,_,initial=fixture()
        args=['worker','--probe',p['snapshot']['device']['path'],json.dumps(p['snapshot']['device']),'--ntfs-layout',json.dumps(LAYOUT)]
        for uid,argv,result in ((1000,args,initial),(0,[*args,'extra'],initial),(0,args,{'oversized':'x'*8192})):
            stdout,stderr=io.StringIO(),io.StringIO()
            with mock.patch.object(gpt,'os',proxy(os,geteuid=lambda:uid)), \
                 mock.patch.object(gpt,'sys',proxy(sys,argv=argv,stdout=stdout,stderr=stderr)), \
                 mock.patch.object(gpt,'probe_device',return_value=result) as probe:
                self.assertEqual(gpt.main(),2)
                self.assertEqual(stdout.getvalue(),'');self.assertEqual(stderr.getvalue(),'')
                if uid!=0 or len(argv)!=6:probe.assert_not_called()

    def test_read_or_kernel_or_geometry_failure_always_closes_source(self):
        p,image,_=fixture()
        for failure in ('read','kernel','geometry'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as td:
                path=Path(td)/'new-normal-file'
                with path.open('xb') as stream:
                    stream.truncate(p['snapshot']['device']['size'])
                    for offset,data in image.blocks.items():stream.seek(offset);stream.write(data)
                fd=os.open(path,os.O_RDONLY)
                with mock.patch.object(gpt,'os',proxy(os,open=lambda *_:fd,
                        pread=(lambda *_:b'') if failure=='read' else os.pread)), \
                     mock.patch.object(gpt,'fd_geometry',side_effect=[512,4096] if failure=='geometry' else None,return_value=512), \
                     mock.patch.object(gpt,'verify_kernel_layout',side_effect=ValueError('kernel drift') if failure=='kernel' else None):
                    with self.assertRaises(ValueError):gpt.probe_device(p['snapshot']['device']['path'],p['snapshot']['device'],ntfs_layout=LAYOUT)
                with self.assertRaises(OSError):os.fstat(fd)


class HelperTransportTests(unittest.TestCase):
    def setUp(self):
        self.helper=legacy.helper
        self.p,_,self.proof=fixture()
        d=self.p['snapshot']['device']
        self.device=self.helper.Device(d['path'],d['majorMinor'],d['size'],d['diskSequence'],'/sys/devices/mock/vda')

    def error(self,code,system,**kwargs):
        with self.assertRaises(self.helper.HelperError) as raised:
            system.gpt_snapshot(self.device,**kwargs)
        self.assertEqual(raised.exception.code,code)
        self.assertNotIn('SECRET',str(raised.exception))

    def test_fixed_readonly_argv_and_inherited_lease_return_normalized_proof(self):
        with tempfile.TemporaryDirectory() as td:
            stub=Path(td)/'worker.py'
            lease=os.open(Path(td)/'new-lease',os.O_CREAT|os.O_EXCL|os.O_RDWR,0o600)
            try:
                system=self.helper.System();system.lease_fd=lease
                stub.write_text('import json,os,sys\n'
                    +f'os.fstat({lease})\n'
                    +f'assert sys.argv[1:]=={[self.device.path,json.dumps(self.device.public(),separators=(",",":")),"--ntfs-layout",json.dumps(LAYOUT,separators=(",",":"))]!r}\n'
                    +f'print({json.dumps(self.proof)!r})\n')
                with mock.patch.object(self.helper,'GPT_ARGV',(sys.executable,'-I',str(stub))):
                    self.assertEqual(system.gpt_snapshot(self.device,ntfs_layout=LAYOUT),self.proof)
                os.fstat(lease)  # The parent retains its own lease.
            finally:os.close(lease)

    def test_conflicting_or_invalid_modes_reject_without_spawning(self):
        for values in ({'ntfs_layout':{}},{'ntfs_layout':{'sourceNumber':2,'rootNumber':True}},
                       {'ntfs_layout':LAYOUT,'preserve_slots':[3,4]},
                       {'ntfs_layout':LAYOUT,'manual_roles':{}},
                       {'ntfs_layout':LAYOUT,'layout_slots':[3,4]},
                       {'ntfs_layout':LAYOUT,'admit_manual':True}):
            with self.subTest(values=values),mock.patch.object(self.helper.subprocess,'Popen') as spawn:
                self.error('INVALID_REQUEST',self.helper.System(),**values)
                spawn.assert_not_called()

    def test_bad_response_or_process_exit_cannot_become_valid_proof(self):
        invalid=[{},self.proof['snapshot'],{**self.proof,'extra':1},
                 {**self.proof,'preservationFingerprint':'A'*64},
                 {**self.proof,'snapshot':{**self.proof['snapshot'],'device':{**self.device.public(),'diskSequence':999}}}]
        bodies=[f'print({json.dumps(value)!r})' for value in invalid]
        bodies += ["print('SECRET'*2000)",f'print({json.dumps(self.proof)!r});raise SystemExit(2)',
                   f'print({json.dumps(self.proof)[:-1]+',"preservationFingerprint":"'+ 'b'*64+'"}'!r})']
        with tempfile.TemporaryDirectory() as td:
            stub=Path(td)/'worker.py'
            for body in bodies:
                with self.subTest(body=body[:50]):
                    stub.write_text(body+'\n')
                    with mock.patch.object(self.helper,'GPT_ARGV',(sys.executable,'-I',str(stub))):
                        self.error('INVALID_REQUEST' if body==bodies[-1] else 'AMBIGUOUS_TOPOLOGY',self.helper.System(),ntfs_layout=LAYOUT)

    def test_timeout_reaps_readonly_child_and_closes_streams(self):
        with tempfile.TemporaryDirectory() as td:
            stub=Path(td)/'worker.py';stub.write_text('import time\ntime.sleep(60)\n')
            children=[];real_spawn=subprocess.Popen
            def spawn(*args,**kwargs):
                child=real_spawn(*args,**kwargs);children.append(child);return child
            started=time.monotonic()
            with mock.patch.object(self.helper,'GPT_ARGV',(sys.executable,'-I',str(stub))), \
                 mock.patch.object(self.helper,'GPT_TIMEOUT',0.15), \
                 mock.patch.object(self.helper,'subprocess',proxy(subprocess,Popen=spawn)):
                self.error('SYSTEM_ERROR',self.helper.System(),ntfs_layout=LAYOUT)
            self.assertLess(time.monotonic()-started,3)
            self.assertEqual(len(children),1)
            child=children[0];self.assertIsNotNone(child.poll())
            self.assertTrue(child.stdout.closed);self.assertTrue(child.stderr.closed)


if __name__=='__main__':unittest.main()

