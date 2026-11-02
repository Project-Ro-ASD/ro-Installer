#!/usr/bin/env python3
"""Read-only NTFS admission and real child transport; never opens block devices."""
import copy
import fcntl
import json
import os
from pathlib import Path
import signal
import struct
import subprocess
import sys
import tempfile
import time
import unittest
from types import SimpleNamespace
from unittest import mock
import installer_helper_test as legacy
from gpt_probe_test import FakeGptSystem

helper = legacy.helper


def proposal():
    p = json.loads((legacy.ROOT/'test/fixtures/ntfs_shrink_plans_v1.json').read_text())[0]['input']
    p['snapshot']['device'].update(path='/dev/vda', majorMinor='252:0')
    return p


def inspection():
    p = proposal(); sector = p['snapshot']['logicalSectorBytes']; source = p['snapshot']['partitions'][1]
    size = (source['endSector'] - source['startSector'] + 1) * sector
    return dict(schemaVersion=1, deviceBytes=size, volumeBytes=size-4096+sector,
                clusterBytes=4096, minimumBytes=50*1024**3, inspectionFingerprint='c'*64)


def request():
    p = proposal(); s = p['snapshot']
    return dict(protocolVersion=2, operation='assess-ntfs-shrink', disk=s['device']['path'],
                expectedDevice={k:v for k,v in s['device'].items() if k!='path'},
                tableFingerprint=s['tableFingerprint'], sourceNumber=2, espNumber=1, rootBytes=p['rootBytes'])


class System(FakeGptSystem):
    def __init__(self):
        super().__init__(); self.snapshot = proposal()['snapshot']; self.inspections = 0; self.drift = False
    def inspect_ntfs(self, snapshot, source):
        assert hasattr(self, 'lease_fd') and source['number'] == 2
        self.inspections += 1
        if self.drift: self.snapshot['tableFingerprint'] = 'b'*64
        return inspection()


class AssessmentTests(unittest.TestCase):
    def error(self, code, action, *args, **kwargs):
        with self.assertRaises(helper.HelperError) as raised: action(*args, **kwargs)
        self.assertEqual(raised.exception.code, code)
        self.assertNotIn('SECRET', str(raised.exception))
    def parse(self, value=None, version=2):
        return helper.parse_request(json.dumps(request() if value is None else value).encode(), version)
    def run_assessment(self, system, value=None):
        with mock.patch.object(helper.os, 'geteuid', return_value=0), mock.patch.object(helper, 'InstallerLock') as lock, \
             mock.patch.object(helper, 'run_backend') as backend:
            lock.return_value.__enter__.return_value.fd = 123
            result = helper.handle(self.parse(value), system)
            backend.assert_not_called()
            return result
    def test_strict_readonly_v2_request_has_no_caller_minimum_or_private_authority(self):
        self.assertEqual(self.parse().ntfs_choices, {'sourceNumber':2,'espNumber':1,'rootBytes':64*1024**3})
        for patch in [{'minimumFilesystemBytes':1}, {'minimumBytes':1}, {'sourceSnapshot':proposal()['snapshot']},
                      {'inspectionFingerprint':'a'*64}, {'fd':3}, {'commands':[]}, {'confirmedPlan':{}},
                      {'confirmDestructive':True}, {'sourceNumber':True}, {'espNumber':True}, {'rootBytes':True},
                      {'sourceNumber':0}, {'rootBytes':64.0*1024**3}, {'tableFingerprint':'A'*64}]:
            self.error('INVALID_REQUEST', self.parse, {**request(), **patch})
        self.error('INVALID_REQUEST', self.parse, {**request(),'protocolVersion':1}, 1)
        self.error('INVALID_REQUEST', self.parse, {**request(),'operation':'install-ntfs-shrink'})
    def test_assessment_uses_observed_minimum_and_returns_no_snapshot_or_write_authority(self):
        system = System(); result = self.run_assessment(system)
        self.assertEqual(result, {'plan':helper.gpt_module().ntfs_shrink_plan(proposal()), 'inspection':inspection()})
        self.assertEqual(system.inspections, 1); self.assertEqual(system.calls, 2)
        self.assertFalse(hasattr(system, 'lease_fd'))
        self.assertLess(len(json.dumps(result).encode()), helper.MAX_MESSAGE_BYTES-256)
    def test_stale_identity_table_and_postinspection_drift_fail_closed(self):
        self.error('DEVICE_CHANGED', self.run_assessment, System(), {**request(),'tableFingerprint':'b'*64})
        self.error('DEVICE_CHANGED', self.run_assessment, System(), {**request(),'expectedDevice':{**request()['expectedDevice'],'diskSequence':12}})
        system=System();system.drift=True
        self.error('DEVICE_CHANGED', self.run_assessment, system)
        self.assertFalse(hasattr(system,'lease_fd'))
    def test_impossible_or_unnecessary_geometry_rejects_before_inspection(self):
        for patch in [{'rootBytes':40*1024**3}, {'rootBytes':41*1024**3}, {'sourceNumber':7}, {'espNumber':2}, {'rootBytes':64*1024**3+1}]:
            system=System(); self.error('INVALID_REQUEST', self.run_assessment, system, {**request(),**patch})
            self.assertEqual(system.inspections,0);self.assertFalse(hasattr(system,'lease_fd'))
    def test_inspection_schema_capacity_and_hash_are_validated_independently(self):
        p=proposal();s=p['snapshot'];source=s['partitions'][1]
        for patch in [{'schemaVersion':True}, {'deviceBytes':True}, {'deviceBytes':1}, {'volumeBytes':1},
                      {'clusterBytes':True}, {'clusterBytes':513}, {'clusterBytes':131072}, {'minimumBytes':True},
                      {'minimumBytes':0}, {'minimumBytes':50*1024**3+1}, {'inspectionFingerprint':'A'*64},
                      {'safeForWrite':True}, {'stdout':'SECRET'}]:
            with self.assertRaises(ValueError):helper.normalize_ntfs_inspection({**inspection(),**patch},s,source)
        with mock.patch.object(System,'inspect_ntfs',return_value={**inspection(),'minimumBytes':135*1024**3}):
            self.error('AMBIGUOUS_TOPOLOGY',self.run_assessment,System())
    def test_root_platform_and_busy_guards_precede_filesystem_inspection(self):
        system=System()
        with mock.patch.object(helper.os,'geteuid',return_value=1000):
            self.error('ROOT_REQUIRED',helper.handle,self.parse(),system)
        with mock.patch.object(helper.os,'geteuid',return_value=0):
            system.supported=False
            self.error('UNSUPPORTED_PLATFORM',helper.handle,self.parse(),system)
            system.supported=True
            with mock.patch.object(helper,'InstallerLock',side_effect=helper.HelperError('BUSY','busy')):
                self.error('BUSY',helper.handle,self.parse(),system)
        self.assertEqual(system.inspections,0)

    def test_source_fd_is_readonly_exclusive_and_closed_after_identity_or_sector_failure(self):
        s=proposal()['snapshot'];source=s['partitions'][1];system=helper.System()
        with tempfile.TemporaryDirectory() as td:
            path=Path(td)/'source.img';path.write_bytes(b'fixture');opened=[]
            def descriptor(snapshot,binding,fd=None):
                if fd is not None:
                    opened.append(fd)
                    flags=fcntl.fcntl(fd,fcntl.F_GETFL)
                    self.assertEqual(flags & os.O_ACCMODE,os.O_RDONLY)
                    self.assertTrue(flags & os.O_NOFOLLOW)
                return str(path),'252:2'
            proxy=SimpleNamespace(**{name:getattr(os,name) for name in dir(os)})
            def open_source(node,flags):
                self.assertEqual(node,str(path))
                self.assertEqual(flags,os.O_RDONLY|os.O_EXCL|os.O_NOFOLLOW|os.O_CLOEXEC|os.O_NONBLOCK)
                return os.open(node,flags)
            proxy.open=open_source
            for sectors in [(512,512),(4096,), (512,4096)]:
                opened.clear()
                with mock.patch.object(helper,'os',proxy), \
                     mock.patch.object(helper,'manual_module',return_value=SimpleNamespace(partition_descriptor=descriptor)), \
                     mock.patch.object(helper,'fcntl',SimpleNamespace(ioctl=mock.Mock(side_effect=[struct.pack('=I',v) for v in sectors]))), \
                     mock.patch.object(system,'ntfs_worker',return_value=inspection()) as reader:
                    if len(sectors)==2 and sectors[-1]==512:self.assertEqual(system.inspect_ntfs(s,source),inspection())
                    else:self.error('AMBIGUOUS_TOPOLOGY',system.inspect_ntfs,s,source)
                    if sectors[0]!=512:reader.assert_not_called()
                for fd in opened:
                    with self.assertRaises(OSError):os.fstat(fd)
            with mock.patch.object(helper,'manual_module',return_value=SimpleNamespace(partition_descriptor=mock.Mock(side_effect=ValueError('SECRET')))):
                self.error('AMBIGUOUS_TOPOLOGY',system.inspect_ntfs,s,source)


class ChildTests(unittest.TestCase):
    error = AssessmentTests.error

    def run_child(self, body, timeout=2, after=None):
        with tempfile.TemporaryDirectory() as td:
            path=Path(td);(path/'source').write_bytes(b'fixture')
            script=path/'worker.py'
            script.write_text("import os,sys,json,fcntl,subprocess,time\n"
                "fd=int(sys.argv[2]);lease=int(os.environ['RO_INSTALLER_LEASE_FD'])\n"
                "assert os.getpid()==os.getpgrp() and fcntl.fcntl(fd,fcntl.F_GETFL)&os.O_ACCMODE==os.O_RDONLY\n"
                "assert set(os.environ)-{'LC_CTYPE'}=={'PATH','LC_ALL','HOME','RO_INSTALLER_LEASE_FD'}\n" + body)
            fd=os.open(path/'source',os.O_RDONLY);lease=os.open(path/'lease',os.O_CREAT|os.O_RDWR,0o600)
            fcntl.flock(lease,fcntl.LOCK_EX|fcntl.LOCK_NB)
            system=helper.System();system.lease_fd=lease
            try:
                with mock.patch.object(helper,'NTFS_ARGV',(sys.executable,'-I',str(script),'--check-fd')), \
                     mock.patch.object(helper,'NTFS_TIMEOUT',timeout):
                    result=system.ntfs_worker(fd,inspection()['deviceBytes'],512)
                if after:after(path)
                return result
            finally:
                os.close(fd);os.close(lease)
                # Children cannot retain the lease after normal/error cleanup.
                check=os.open(path/'lease',os.O_RDWR)
                try:
                    deadline=time.monotonic()+2
                    while True:
                        try:
                            fcntl.flock(check,fcntl.LOCK_EX|fcntl.LOCK_NB)
                            break
                        except BlockingIOError:
                            if time.monotonic()>=deadline:raise
                            time.sleep(0.01)
                finally:os.close(check)

    def test_real_pipes_fixed_environment_inherited_readonly_fd_and_lease(self):
        body='print('+repr(json.dumps(inspection()))+',flush=True)\n'
        self.assertEqual(self.run_child(body),inspection())

    def test_transport_refuses_nonzero_malformed_duplicate_overflow_and_timeout(self):
        for code,body in [('AMBIGUOUS_TOPOLOGY',"print('SECRET',file=sys.stderr);sys.exit(2)\n"),
                          ('AMBIGUOUS_TOPOLOGY',"print('SECRET')\n"),
                          ('AMBIGUOUS_TOPOLOGY',"print('{\"x\":1,\"x\":2}')\n"),
                          ('AMBIGUOUS_TOPOLOGY',"print('x'*4096)\n"),
                          ('SYSTEM_ERROR',"time.sleep(5)\n"),
                          ('SYSTEM_ERROR',"sys.stdout.close();sys.stderr.close();os.close(1);os.close(2);time.sleep(5)\n")]:
            self.error(code,self.run_child,body,0.1 if code=='SYSTEM_ERROR' else 2)

    def test_exited_leader_is_not_reaped_before_group_and_inherited_lease_cleanup(self):
        body = ("child=subprocess.Popen([sys.executable,'-I','-c','import time;time.sleep(20)'],"
                "stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,pass_fds=(lease,))\n"
                "print("+repr(json.dumps(inspection()))+",flush=True)\n")
        events=[];real_killpg=os.killpg
        def killpg(pid,sig):
            events.append('group');return real_killpg(pid,sig)
        def spawn(*args,**kwargs):
            process=subprocess.Popen(*args,**kwargs)
            real_wait=process.wait
            def wait(*a,**kw):
                events.append('reap');return real_wait(*a,**kw)
            process.wait=wait
            return process
        proxy=SimpleNamespace(**{name:getattr(os,name) for name in dir(os)})
        proxy.killpg=killpg
        subprocess_proxy=SimpleNamespace(**{name:getattr(subprocess,name) for name in dir(subprocess)})
        subprocess_proxy.Popen=spawn
        with mock.patch.object(helper,'os',proxy),mock.patch.object(helper,'subprocess',subprocess_proxy):
            self.assertEqual(self.run_child(body),inspection())
        self.assertIn('group',events);self.assertIn('reap',events)
        self.assertLess(events.index('group'),events.index('reap'))

    def test_invalid_lease_is_refused_without_spawning(self):
        system=helper.System()
        with mock.patch.object(helper.subprocess,'Popen') as spawn:
            self.error('UNSAFE_LOCK',system.ntfs_worker,3,4096,512)
            spawn.assert_not_called()


if __name__ == '__main__':
    unittest.main()

