"""Real native Dart -> root-internal IPC; mount/disk commands remain synthetic."""
import importlib.machinery
import importlib.util
import json
import ctypes
import signal
import time
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT=Path(__file__).resolve().parents[2]
def load(name,path):
    loader=importlib.machinery.SourceFileLoader(name,str(path));spec=importlib.util.spec_from_loader(name,loader)
    m=importlib.util.module_from_spec(spec);sys.modules[name]=m;loader.exec_module(m);return m
session=load('observed_session',ROOT/'linux/ro-installer-session')
gate=load('observed_helper',ROOT/'linux/ro-installer-helper')
records=load('observed_records',ROOT/'linux/ro_installer_records.py')

class NativeObservationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory(prefix='p0-04-native-')
        cls.binary=str(Path(cls.temp.name)/'engine')
        result=subprocess.run(['dart','compile','exe',str(ROOT/'test/fixtures/observability_transport.dart'),'-o',cls.binary],capture_output=True,text=True)
        if result.returncode:raise AssertionError(result.stdout+result.stderr)
    @classmethod
    def tearDownClass(cls):cls.temp.cleanup()
    def run_engine(self,fault,write_failure=False):
        with tempfile.TemporaryDirectory(prefix='p0-04-transport-') as td:
            recorder=records.Recorder(directory=td+'/records',owner_uid=os.geteuid())
            if write_failure:recorder.write=mock.Mock(side_effect=OSError('SECRET_SENTINEL'))
            try:
                with gate.InstallerLock(td+'/lease',os.geteuid()) as lease:
                    supervisor=session.Supervisor(gate,lease.fd,'synthetic-parent','synthetic-namespace',td,recorder=recorder)
                    env={**session.ROOT_ENV,'FIXTURE_SOCKET':supervisor.path,'FIXTURE_RESULT':td+'/result.json','FIXTURE_FAULT':fault}
                    with mock.patch.object(session,'verify_private'):
                        status=supervisor.run((self.binary,),env)
                    self.assertLessEqual(len(supervisor.threads),32)
                summary=recorder.finish(status,remaining=0)
                self.assertTrue(records.valid_report(summary),summary)
                result=json.loads(Path(td+'/result.json').read_text())
                self.assertEqual(result['success'],fault=='success')
                self.assertEqual(summary['terminalStatus'],'success' if result['success'] else 'failed')
                self.assertNotIn('SECRET_SENTINEL',json.dumps(summary))
                if fault=='success':
                    self.assertEqual([s['status'] for s in summary['stages']],['success']*9)
                if fault=='main':
                    self.assertEqual(summary['primaryError'],'STAGE_5_FAILED')
                    self.assertEqual(summary['cleanupStatus'],'success')
                    self.assertTrue(all(s['status']=='notStarted' for s in summary['stages'][5:]))
                if fault=='cleanup':self.assertEqual(summary['cleanupStatus'],'failed')
                if write_failure:self.assertEqual(summary['logStatus'],'failed')
                return summary
            finally:recorder.close()
    def test_supervisor_sigkill_keeps_incomplete_checkpoint_and_reaps_test_children(self):
        libc=ctypes.CDLL(None,use_errno=True)
        previous=ctypes.c_int()
        self.assertEqual(libc.prctl(37,ctypes.byref(previous),0,0,0),0)
        self.assertEqual(libc.prctl(36,1,0,0,0),0)
        engine_pid=None
        with tempfile.TemporaryDirectory(prefix='p0-04-supervisor-crash-') as td:
            code=r"""
import importlib.machinery,importlib.util,sys,os,json
from pathlib import Path
from unittest import mock
root=Path(sys.argv[1]);directory=sys.argv[2]
def load(name,path):
 loader=importlib.machinery.SourceFileLoader(name,str(path));spec=importlib.util.spec_from_loader(name,loader)
 m=importlib.util.module_from_spec(spec);sys.modules[name]=m;loader.exec_module(m);return m
s=load('worker_session',root/'linux/ro-installer-session');g=load('worker_helper',root/'linux/ro-installer-helper')
r=s.records_module().Recorder(directory=directory+'/records',owner_uid=os.geteuid())
Path(directory+'/sid').write_text(r.sid)
with g.InstallerLock(directory+'/lease',os.geteuid()) as lease:
 x=s.Supervisor(g,lease.fd,'synthetic-parent','synthetic-ns',directory,recorder=r)
 env={**s.ROOT_ENV,'FIXTURE_FAULT':'stay','FIXTURE_SOCKET':x.path,'FIXTURE_RESULT':directory+'/ready'}
 with mock.patch.object(s,'verify_private'):x.run((sys.argv[3],),env)
"""
            process=subprocess.Popen([sys.executable,'-c',code,str(ROOT),td,self.binary],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,start_new_session=True)
            try:
                deadline=time.monotonic()+10
                while not Path(td+'/ready').exists() and time.monotonic()<deadline:time.sleep(.02)
                self.assertTrue(Path(td+'/ready').exists())
                engine_pid=json.loads(Path(td+'/ready').read_text())['pid']
                os.kill(process.pid,signal.SIGKILL);process.wait(timeout=5)
                sid=Path(td+'/sid').read_text()
                summary=json.loads(Path(td+'/records/'+sid+'/summary.json').read_text())
                self.assertEqual(summary['terminalStatus'],'running')
                self.assertNotEqual(summary['logStatus'],'complete')
                events=(Path(td)/'records'/sid/'events.jsonl').read_text()
                self.assertIn('stage.start',events);self.assertNotIn('session.end',events)
            finally:
                try:os.killpg(process.pid,signal.SIGKILL)
                except ProcessLookupError:pass
                process.wait(timeout=5);process.stderr.close()
                if engine_pid is not None:
                    try:os.waitpid(engine_pid,0)
                    except ChildProcessError:pass
                libc.prctl(36,previous.value,0,0,0)

    def test_success_native_engine_all_stage_and_copy_timings(self):
        summary=self.run_engine('success')
        self.assertTrue(all(s['durationMs'] is not None for s in summary['stages']))
        for op in ['preflight','copy.main','copy.efi','cleanup','engine']:
            self.assertEqual(next(s['status'] for s in summary['spans'] if s['operationId']==op),'success')
    def test_native_copy_failure_records_primary_and_cleanup(self):self.run_engine('main')
    def test_native_cleanup_failure_is_not_success(self):self.run_engine('cleanup')
    def test_real_native_engine_survives_writer_exception(self):self.run_engine('success',True)
    def test_original_copy_failure_survives_writer_exception(self):self.run_engine('main',True)

if __name__=='__main__':unittest.main(verbosity=2)
