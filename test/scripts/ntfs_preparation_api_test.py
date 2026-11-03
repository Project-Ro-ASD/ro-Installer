#!/usr/bin/env python3
"""Read-only target preparation: shared DTOs, helper guards and fixed child IO."""
import copy
import fcntl
import io
import json
import os
from pathlib import Path
import stat
import signal
import subprocess
import struct
import sys
import tempfile
import time
import unittest
from types import SimpleNamespace
from unittest import mock
import installer_helper_test as legacy
from ntfs_approval_test import mutate
from ntfs_assessment_test import System as AssessmentSystem, proposal, inspection, request as assess_request
from ntfs_native_runner_test import proxy

helper=legacy.helper
worker=legacy.load_module('ntfs_preparation_cli',legacy.ROOT/'linux/ro_installer_ntfs.py')
CASES=json.loads((legacy.ROOT/'test/fixtures/ntfs_preparations_v1.json').read_text())
TOOLS={'version':'2026.9.28','epoch':2,'release':'1.fc44','arch':'x86_64'}


def evidence(target,fingerprint):
    return {'inspection':inspection(),'preparation':{'schemaVersion':1,'deviceBytes':inspection()['deviceBytes'],
        'targetBytes':target,'inspectionFingerprint':fingerprint,'toolchain':dict(TOOLS),'preparationFingerprint':'d'*64}}


def request():return {**assess_request(),'operation':'prepare-ntfs-shrink','inspectionFingerprint':inspection()['inspectionFingerprint']}


class System(AssessmentSystem):
    def __init__(self):super().__init__();self.preparations=0;self.refuse=False;self.bad=False
    def prepare_ntfs(self,snapshot,source,target,fingerprint):
        self.preparations+=1
        assert self.lease_fd==123 and source['number']==2
        if self.refuse:helper.fail('NTFS_TOOLS_UNSUPPORTED','fixed refusal')
        result=evidence(target,fingerprint)
        if self.bad:result['preparation']['targetBytes']+=1048576
        if self.drift:self.snapshot['tableFingerprint']='f'*64
        return result


class PreparationApiTests(unittest.TestCase):
    def error(self,code,action,*args):
        with self.assertRaises(helper.HelperError) as failure:action(*args)
        self.assertEqual(failure.exception.code,code)
    def parse(self,value=None,version=2):return helper.parse_request(json.dumps(request() if value is None else value).encode(),version)
    def run_helper(self,system,value=None):
        with mock.patch.object(helper,'os',proxy(os,geteuid=lambda:0)),mock.patch.object(helper,'InstallerLock') as lock, \
             mock.patch.object(helper,'run_backend') as backend:
            lock.return_value.__enter__.return_value.fd=123
            result=helper.handle(self.parse(value),system)
            backend.assert_not_called();return result

    def test_strict_v2_request_has_no_caller_minimum_paths_or_authority(self):
        self.assertEqual(self.parse().inspection_fingerprint,inspection()['inspectionFingerprint'])
        for field,value in [('minimumBytes',1),('targetBytes',64*1024**3),('commands',[]),('fd',3),
                            ('sourceSnapshot',proposal()['snapshot']),('confirmedPlan',{}),('confirmDestructive',True),
                            ('inspectionFingerprint',True),('inspectionFingerprint','A'*64),('sourceNumber',True)]:
            self.error('INVALID_REQUEST',self.parse,{**request(),field:value})
        self.error('INVALID_REQUEST',self.parse,{**request(),'protocolVersion':1},1)

    def test_helper_recomputes_plan_from_prepared_minimum_without_extra_inspection(self):
        system=System();result=self.run_helper(system)
        self.assertEqual(system.preparations,1);self.assertEqual(system.inspections,0)
        self.assertEqual(result['inspection'],inspection())
        self.assertEqual(result['plan']['source']['minimumFilesystemBytes'],inspection()['minimumBytes'])
        self.assertEqual(result['plan']['source']['retainedBytes'],result['preparation']['targetBytes'])

    def test_stale_gpt_tools_and_malformed_evidence_refuse(self):
        system=System();self.error('DEVICE_CHANGED',self.run_helper,system,{**request(),'tableFingerprint':'f'*64})
        self.assertEqual(system.preparations,0)
        for field,code in [('refuse','NTFS_TOOLS_UNSUPPORTED'),('bad','AMBIGUOUS_TOPOLOGY'),('drift','DEVICE_CHANGED')]:
            system=System();setattr(system,field,True);self.error(code,self.run_helper,system)

    def test_root_platform_busy_guards_precede_preparation(self):
        system=System()
        with mock.patch.object(helper,'os',proxy(os,geteuid=lambda:1000)):
            self.error('ROOT_REQUIRED',helper.handle,self.parse(),system)
        system.supported=False;self.error('UNSUPPORTED_PLATFORM',self.run_helper,system)
        self.assertEqual(system.preparations,0)
        system.supported=True
        with mock.patch.object(helper,'os',proxy(os,geteuid=lambda:0)), \
             mock.patch.object(helper,'InstallerLock',side_effect=helper.HelperError('BUSY','busy')):
            self.error('BUSY',helper.handle,self.parse(),system)
        self.assertEqual(system.preparations,0)

    def test_cli_is_fixed_readonly_block_mode_with_bounded_resources_and_data(self):
        with tempfile.TemporaryDirectory() as td:
            path=Path(td)/'new';path.write_bytes(b'normal');fd=os.open(path,os.O_RDONLY)
            try:
                def fstat(number):return SimpleNamespace(st_mode=stat.S_IFBLK) if number==fd else os.fstat(number)
                args=['worker','--prepare-fd',str(fd),str(128*1024**3),'512',str(64*1024**3),'a'*64]
                output=io.StringIO()
                prepared={'inspection':inspection(),'preparation':{'test':'evidence'}}
                with mock.patch.object(worker,'os',proxy(os,geteuid=lambda:0,fstat=fstat)), \
                     mock.patch.object(worker,'sys',proxy(sys,argv=args,stdout=output)), \
                     mock.patch.object(worker,'restrict_limit') as limits,mock.patch.object(worker,'signal',proxy(worker.signal,alarm=mock.Mock())) as signals, \
                     mock.patch.object(worker,'prepare_resize_evidence',return_value=prepared) as prepare:
                    self.assertEqual(worker.main(),0);self.assertEqual(json.loads(output.getvalue()),prepared)
                    self.assertEqual(prepare.call_args.args,(fd,128*1024**3,512,64*1024**3,'a'*64))
                    self.assertEqual(signals.alarm.call_args_list,[mock.call(360),mock.call(0)])
                    self.assertEqual(limits.call_args_list[-1].args[1],360)
                for bad in ('--resize-fd','--execute','--check-resized-fd'):
                    with mock.patch.object(worker,'os',proxy(os,geteuid=lambda:0)), \
                         mock.patch.object(worker,'sys',proxy(sys,argv=['worker',bad],stdout=io.StringIO())), \
                         mock.patch.object(worker,'run_native_resize') as writer:
                        self.assertEqual(worker.main(),2);writer.assert_not_called()
            finally:os.close(fd)

    def test_cli_tool_refusal_is_fixed_and_readwrite_source_never_queries_tools(self):
        with tempfile.TemporaryFile() as stream:
            fd=stream.fileno();args=['worker','--prepare-fd',str(fd),str(128*1024**3),'512',str(64*1024**3),'a'*64]
            output=io.StringIO()
            with mock.patch.object(worker,'os',proxy(os,geteuid=lambda:0,fstat=lambda _:SimpleNamespace(st_mode=stat.S_IFBLK))), \
                 mock.patch.object(worker,'sys',proxy(sys,argv=args,stdout=output)), \
                 mock.patch.object(worker,'restrict_limit'),mock.patch.object(worker,'signal',proxy(worker.signal,alarm=mock.Mock())), \
                 mock.patch.object(worker,'run_tool') as tools:
                self.assertEqual(worker.main(),2);tools.assert_not_called()
            self.assertEqual(output.getvalue(),'')
        output=io.StringIO()
        with mock.patch.object(worker,'os',proxy(os,geteuid=lambda:0,fstat=lambda _:SimpleNamespace(st_mode=stat.S_IFBLK))), \
             mock.patch.object(worker,'sys',proxy(sys,argv=args,stdout=output)),mock.patch.object(worker,'restrict_limit'), \
             mock.patch.object(worker,'signal',proxy(worker.signal,alarm=mock.Mock())), \
             mock.patch.object(worker,'prepare_resize_evidence',side_effect=worker.ResizeToolchainError('PRIVATE')):
            self.assertEqual(worker.main(),2)
        self.assertEqual(json.loads(output.getvalue()),{'error':'NTFS_TOOLS_UNSUPPORTED'})

    def test_bound_source_opens_readonly_exclusive_and_rechecks_after_preparation(self):
        p=proposal();source=p['snapshot']['partitions'][1];target=helper.gpt_module().ntfs_shrink_plan(p)['source']['retainedBytes']
        with tempfile.TemporaryDirectory() as td:
            path=Path(td)/'new-source';path.write_bytes(b'unchanged');opened=[]
            def descriptor(snapshot,binding,fd=None):
                if fd is not None:opened.append(fd);self.assertEqual(fcntl.fcntl(fd,fcntl.F_GETFL)&os.O_ACCMODE,os.O_RDONLY)
                return str(path),'252:2'
            def open_source(node,flags):
                self.assertEqual(flags,os.O_RDONLY|os.O_EXCL|os.O_NOFOLLOW|os.O_CLOEXEC|os.O_NONBLOCK)
                return os.open(node,flags)
            for sectors in ([512,512],[512,4096]):
                system=helper.System()
                with mock.patch.object(helper,'os',proxy(os,open=open_source)), \
                     mock.patch.object(helper,'manual_module',return_value=SimpleNamespace(partition_descriptor=descriptor)), \
                     mock.patch.object(helper,'fcntl',proxy(fcntl,ioctl=mock.Mock(side_effect=[struct.pack('=I',v) for v in sectors]))), \
                     mock.patch.object(system,'ntfs_worker',return_value=evidence(target,inspection()['inspectionFingerprint'])) as child:
                    if sectors[-1]==512:
                        self.assertEqual(system.prepare_ntfs(p['snapshot'],source,target,inspection()['inspectionFingerprint']),evidence(target,inspection()['inspectionFingerprint']))
                        self.assertEqual(child.call_args.kwargs,{'target_bytes':target,'inspection_fingerprint':inspection()['inspectionFingerprint']})
                    else:self.error('AMBIGUOUS_TOPOLOGY',system.prepare_ntfs,p['snapshot'],source,target,inspection()['inspectionFingerprint'])
            for fd in opened:
                with self.assertRaises(OSError):os.fstat(fd)
            self.assertEqual(path.read_bytes(),b'unchanged')


class PreparationChildTests(unittest.TestCase):
    def error(self,code,action,*args):
        with self.assertRaises(helper.HelperError) as failure:action(*args)
        self.assertEqual(failure.exception.code,code)

    def child(self,body,*,timeout=2,interrupt=False):
        with tempfile.TemporaryDirectory() as td:
            directory=Path(td);path=directory/'new-source';path.write_bytes(b'unchanged')
            script=directory/'readonly-worker.py'
            script.write_text("import os,sys,json,time,fcntl\n"
                "assert sys.argv[1]=='--prepare-fd'\n"
                "fd=int(sys.argv[2]);lease=int(os.environ['RO_INSTALLER_LEASE_FD'])\n"
                "assert sys.argv[5]=='68719476736' and sys.argv[6]=='"+'a'*64+"'\n"
                "assert fcntl.fcntl(fd,fcntl.F_GETFL)&os.O_ACCMODE==os.O_RDONLY\n"
                "try:os.pwrite(fd,b'x',0)\nexcept OSError:pass\nelse:raise AssertionError('writable source')\n"+body)
            fd=os.open(path,os.O_RDONLY);lease=os.open(directory/'lease',os.O_RDWR|os.O_CREAT|os.O_EXCL,0o600)
            fcntl.flock(lease,fcntl.LOCK_EX|fcntl.LOCK_NB)
            system=helper.System();system.lease_fd=lease
            process=None
            def spawn(*args,**kwargs):
                nonlocal process
                process=__import__('subprocess').Popen(*args,**kwargs);return process
            try:
                with mock.patch.object(helper,'NTFS_PREPARE_ARGV',(sys.executable,'-I',str(script),'--prepare-fd')), \
                     mock.patch.object(helper,'NTFS_PREPARE_TIMEOUT',timeout), \
                     mock.patch.object(helper,'subprocess',proxy(helper.subprocess,Popen=spawn)):
                    if interrupt:
                        with mock.patch.object(helper,'time',proxy(time,monotonic=mock.Mock(side_effect=KeyboardInterrupt))):
                            system.ntfs_worker(fd,128*1024**3,512,target_bytes=64*1024**3,inspection_fingerprint='a'*64)
                    else:return system.ntfs_worker(fd,128*1024**3,512,target_bytes=64*1024**3,inspection_fingerprint='a'*64)
            finally:
                if process is not None:
                    self.assertIsNotNone(process.returncode)
                    self.assertTrue(process.stdout.closed);self.assertTrue(process.stderr.closed)
                os.close(fd);os.close(lease)
                self.assertEqual(path.read_bytes(),b'unchanged')
                with (directory/'lease').open('r+b') as check:fcntl.flock(check.fileno(),fcntl.LOCK_EX|fcntl.LOCK_NB)

    def test_fixed_prepare_child_arguments_readonly_fd_and_inherited_lease(self):
        expected={'inspection':{},'preparation':{}}
        self.assertEqual(self.child('print('+repr(json.dumps(expected))+')\n'),expected)

    def test_only_preparation_mode_reports_fixed_toolchain_refusal(self):
        self.error('NTFS_TOOLS_UNSUPPORTED',self.child,"print('{\"error\":\"NTFS_TOOLS_UNSUPPORTED\"}');sys.exit(2)\n")
        self.error('AMBIGUOUS_TOPOLOGY',self.child,"print('{\"error\":\"PRIVATE_DETAIL\"}');sys.exit(2)\n")

    def test_deadline_and_interrupt_reap_group_before_releasing_lease(self):
        with self.assertRaises(helper.HelperError) as failure:self.child('time.sleep(5)\n',timeout=.1)
        self.assertEqual(failure.exception.code,'SYSTEM_ERROR')
        with self.assertRaises(KeyboardInterrupt):self.child('time.sleep(5)\n',interrupt=True)

class ReadonlySignalTests(unittest.TestCase):
    def test_prepare_helper_sigterm_unwinds_child_and_releases_lease(self):
        with tempfile.TemporaryDirectory() as td:
            directory=Path(td);source=directory/'new-source';source.write_bytes(b'unchanged')
            pidfile=directory/'worker.pid';worker_script=directory/'worker.py'
            worker_script.write_text("import os,time\nfrom pathlib import Path\nPath("+repr(str(pidfile))+").write_text(str(os.getpid()))\ntime.sleep(8)\n")
            fixture=directory/'helper.py'
            fixture.write_text("import os,sys\nfrom pathlib import Path\nsys.path.insert(0,"+repr(str(legacy.ROOT/'test/scripts'))+")\n"
                "from ntfs_assessment_test import System as Fake\nimport installer_helper_test as legacy\nfrom ntfs_native_runner_test import proxy\n"
                "helper=legacy.load_module('signal_prepare_helper',legacy.ROOT/'linux/ro-installer-helper')\n"
                "original_system=helper.System;original_lock=helper.InstallerLock;uid=os.geteuid()\n"
                "class System(Fake):\n def prepare_ntfs(self,snapshot,source,target,fingerprint):\n"
                "  fd=os.open("+repr(str(source))+",os.O_RDONLY)\n  try:return original_system.ntfs_worker(self,fd,"+str(inspection()['deviceBytes'])+",512,target_bytes=target,inspection_fingerprint=fingerprint)\n"
                "  finally:os.close(fd)\n"
                "helper.System=System\nhelper.InstallerLock=lambda:original_lock("+repr(str(directory/'runtime'))+",uid)\n"
                "helper.os=proxy(os,geteuid=lambda:0)\nhelper.NTFS_PREPARE_ARGV=(sys.executable,'-I',"+repr(str(worker_script)) +",'--prepare-fd')\n"
                "sys.argv=['helper','--protocol=2']\nsys.exit(helper.main())\n")
            process=subprocess.Popen([sys.executable,'-I',str(fixture)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            try:
                process.stdin.write(json.dumps(request()).encode()+b'\n');process.stdin.close()
                deadline=time.monotonic()+5
                while not pidfile.exists() and time.monotonic()<deadline and process.poll() is None:time.sleep(.01)
                self.assertTrue(pidfile.exists())
                with (directory/'runtime/install.lock').open('r+b') as other:
                    with self.assertRaises(BlockingIOError):fcntl.flock(other.fileno(),fcntl.LOCK_EX|fcntl.LOCK_NB)
                process.send_signal(signal.SIGTERM);process.wait(timeout=5)
                result=json.loads(process.stdout.read());self.assertEqual(result['error']['code'],'SYSTEM_ERROR')
                self.assertNotEqual(process.returncode,0);self.assertEqual(process.stderr.read(),b'')
                with (directory/'runtime/install.lock').open('r+b') as other:fcntl.flock(other.fileno(),fcntl.LOCK_EX|fcntl.LOCK_NB)
                self.assertEqual(source.read_bytes(),b'unchanged')
            finally:
                if process.poll() is None:process.kill();process.wait(timeout=5)
                process.stdout.close();process.stderr.close()



def shared_valid(row):
    def check(self):
        p={k:v for k,v in row['proposal'].items() if k!='minimumFilesystemBytes'}
        value=copy.deepcopy(row['response']);before=copy.deepcopy(value)
        normalized=helper.normalize_ntfs_prepared_plan(value,p,value['inspection']['inspectionFingerprint'])
        self.assertEqual(normalized,value)
        normalized['preparation']['toolchain']['epoch']=99
        self.assertEqual(value,before)
    return check


def shared_invalid(row):
    def check(self):
        base=CASES['bases'][0];p={k:v for k,v in base['proposal'].items() if k!='minimumFilesystemBytes'}
        value=mutate(base['response'],row)
        with self.assertRaises((ValueError,TypeError,KeyError)):
            helper.normalize_ntfs_prepared_plan(value,p,base['response']['inspection']['inspectionFingerprint'])
    return check


for row in CASES['bases']:setattr(PreparationApiTests,'test_shared_valid_'+row['name'],shared_valid(row))
for i,row in enumerate(CASES['invalid']):setattr(PreparationApiTests,f'test_shared_invalid_{i:02d}_{row["name"]}',shared_invalid(row))
if __name__=='__main__':unittest.main()
