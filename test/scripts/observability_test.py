"""Secure records on disposable directories; no real /run, /mnt or disks."""
import errno
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
spec=importlib.util.spec_from_file_location('records',ROOT/'linux/ro_installer_records.py')
r=importlib.util.module_from_spec(spec);spec.loader.exec_module(r)


def event(**fields):
    return dict(eventType='command.end',stageId=5,operationId='copy.main',status='failed',
                durationMs=12,exitCode=23,errorCode='COMMAND_FAILED',**fields)


class RecordTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='p0-04-records-')
        self.path=Path(self.temp.name)/'records'
        self.recorders=[]
    def tearDown(self):
        for item in self.recorders:item.close()
        self.temp.cleanup()
    def recorder(self,**kw):
        item=r.Recorder(directory=str(self.path),owner_uid=os.geteuid(),**kw)
        self.recorders.append(item);return item
    def test_real_permissions_types_id_and_jsonl(self):
        rec=self.recorder();self.assertEqual(rec.report['logStatus'],'recording')
        self.assertRegex(rec.sid,'^[a-f0-9]{32}$');self.assertTrue(rec.observe(event()))
        rec.finish(8)
        for p in (self.path,self.path/rec.sid):self.assertEqual(stat.S_IMODE(p.stat().st_mode),0o700)
        for name in ['events.jsonl','summary.json']:
            p=self.path/rec.sid/name
            self.assertEqual(stat.S_IMODE(p.stat().st_mode),0o600);self.assertEqual(p.stat().st_nlink,1)
        lines=(self.path/rec.sid/'events.jsonl').read_text().splitlines()
        self.assertTrue(all(r.validate(json.loads(v),['object','event']) for v in lines))
        self.assertTrue(r.valid_report(rec.report))
    def test_existing_unsafe_directory_refused_without_chmod(self):
        self.path.mkdir(mode=0o755)
        self.path.chmod(0o755)
        rec=self.recorder();self.assertEqual(rec.report['logStatus'],'unavailable')
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode),0o755)
        self.assertEqual(list(self.path.iterdir()),[])
    def test_symlink_store_refused_victim_unchanged(self):
        victim=Path(self.temp.name)/'victim';victim.mkdir(mode=0o700)
        (victim/'sentinel').write_text('unaltered');self.path.symlink_to(victim)
        rec=self.recorder();self.assertEqual(rec.report['logStatus'],'unavailable')
        self.assertEqual((victim/'sentinel').read_text(),'unaltered');self.assertEqual(len(list(victim.iterdir())),1)
    def test_symlink_or_hardlink_summary_is_never_overwritten(self):
        for hard in [False,True]:
            rec=self.recorder();summary=self.path/rec.sid/'summary.json';summary.unlink()
            victim=Path(self.temp.name)/('victim-'+str(hard));victim.write_text('unaltered');victim.chmod(0o600)
            if hard:os.link(victim,summary)
            else:summary.symlink_to(victim)
            self.assertFalse(rec.checkpoint());self.assertEqual(victim.read_text(),'unaltered')
            self.assertEqual(rec.report['logStatus'],'failed');rec.close()
            # Keep the poisoned store as evidence; next iteration uses a fresh one.
            self.path=Path(self.temp.name)/'records-next'
    def test_fifo_summary_refused_without_blocking(self):
        rec=self.recorder();summary=self.path/rec.sid/'summary.json';summary.unlink()
        os.mkfifo(summary,0o600)
        self.assertFalse(rec.checkpoint())
        self.assertEqual(rec.report['logStatus'],'failed')

    def test_enospc_and_short_write_are_separate_logging_errors(self):
        for error in [OSError(errno.ENOSPC,'secret sentinel'),PermissionError('secret sentinel'),RuntimeError('secret sentinel')]:
            rec=self.recorder()
            rec.write=mock.Mock(side_effect=error)
            self.assertFalse(rec.observe(event()))
            self.assertEqual(rec.report['logError'],'LOG_WRITE_FAILED')
            report=rec.finish(0);self.assertNotIn('secret sentinel',json.dumps(report))
            self.assertNotEqual(report['terminalStatus'],'success') # No engine outcome was supplied.
    def test_partial_write_retried_and_zero_write_reported(self):
        rec=self.recorder();real=os.write
        rec.write=lambda fd,data:real(fd,data[:7])
        self.assertTrue(rec.observe(event()))
        rec.write=lambda *_:0
        self.assertFalse(rec.observe(event()));self.assertEqual(rec.report['logStatus'],'failed')
    def test_event_count_and_byte_limits_do_not_change_outcome(self):
        for index,bounds in enumerate([{'events':1},{'sessionBytes':1},{'eventBytes':16}]):
            self.path=Path(self.temp.name)/('bounded-'+str(index))
            rec=self.recorder(limits={**r.LIMITS,**bounds})
            for _ in range(4):rec.observe(event())
            self.assertEqual(rec.report['logStatus'],'truncated')
            self.assertLessEqual(rec.bytes,rec.limits['sessionBytes'])
            self.assertLessEqual(rec.events,rec.limits['events'])
            rec.outcome(dict(terminalStatus='failed',failedStage=5,lastSuccessfulStage=4,
              primaryError='STAGE_5_FAILED',cleanupStatus='failed',remainingResources=2,engineDurationMs=99))
            report=rec.finish(8);self.assertEqual(report['primaryError'],'STAGE_5_FAILED')
            self.assertEqual(report['cleanupStatus'],'failed')
    def test_unknown_fields_secret_and_wrong_types_rejected(self):
        for value in [{**event(),'stdout':'SECRET_SENTINEL'}, {**event(),'operationId':'password SECRET_SENTINEL'},
                      {**event(),'exitCode':True}, {**event(),'durationMs':-1}]:
            rec=self.recorder();self.assertFalse(rec.observe(value))
            self.assertEqual(rec.report['logError'],'LOG_SCHEMA_INVALID')
            self.assertNotIn('SECRET_SENTINEL',(self.path/rec.sid/'events.jsonl').read_text())
    def test_store_count_full_retains_prior_records(self):
        rec=self.recorder(limits={**r.LIMITS,'sessions':1});rec.close()
        before=list(self.path.iterdir());other=self.recorder(limits={**r.LIMITS,'sessions':1})
        self.assertEqual(other.report['logError'],'LOG_STORE_FULL');self.assertEqual(list(self.path.iterdir()),before)
    def test_store_byte_reservation_and_lock(self):
        rec=self.recorder();other=self.recorder(limits={**r.LIMITS,'storeBytes':r.LIMITS['sessionBytes']+2*r.LIMITS['summaryBytes']})
        self.assertEqual(other.report['logError'],'LOG_STORE_FULL');rec.close()
    def test_32_small_finished_sessions_fit_and_33rd_refused(self):
        for _ in range(32):self.recorder().close()
        self.assertEqual(self.recorder().report['logError'],'LOG_STORE_FULL')
    def test_crash_prefix_survives_real_child_kill(self):
        code='''import sys,os,time,json
sys.path.insert(0,sys.argv[1]);import ro_installer_records as r
x=r.Recorder(directory=sys.argv[2],owner_uid=os.geteuid())
print(x.sid,flush=True);time.sleep(60)
'''
        process=subprocess.Popen([sys.executable,'-c',code,str(ROOT/'linux'),str(self.path)],stdout=subprocess.PIPE,text=True)
        try:
            sid=process.stdout.readline().strip();self.assertRegex(sid,'^[a-f0-9]{32}$')
            process.kill();process.wait()
            summary=json.loads((self.path/sid/'summary.json').read_text())
            self.assertEqual(summary['terminalStatus'],'running');self.assertNotEqual(summary['logStatus'],'complete')
        finally:
            if process.poll() is None:process.kill();process.wait()
            process.stdout.close()
    def test_atomic_summary_failure_keeps_last_checkpoint(self):
        rec=self.recorder();path=self.path/rec.sid/'summary.json';before=path.read_bytes()
        rec.write=mock.Mock(side_effect=OSError(errno.ENOSPC,'fixture'))
        self.assertFalse(rec.checkpoint());self.assertEqual(path.read_bytes(),before)
        self.assertEqual(len(list(path.parent.iterdir())),2)
    def test_crash_keeps_observed_last_success_and_interrupted_stage(self):
        rec=self.recorder()
        for stage,kind,status in [(1,'stage.start','running'),(1,'stage.end','success'),(2,'stage.start','running')]:
            rec.observe({'eventType':kind,'stageId':stage,'operationId':'stage.command',
                         'status':status,'durationMs':0,'exitCode':None,'errorCode':None})
        report=rec.finish(-9)
        self.assertEqual(report['lastSuccessfulStage'],1)
        self.assertEqual(report['failedStage'],2)
        self.assertEqual(report['stages'][0]['status'],'success')
        self.assertEqual(report['stages'][1]['status'],'interrupted')
        self.assertEqual(report['primaryError'],'ENGINE_CRASH')
        self.assertTrue(all(s['status']=='notStarted' for s in report['stages'][2:]))
        self.assertTrue(r.valid_report(report))

    def test_schema_generated_from_one_source(self):
        completed=subprocess.run([sys.executable,str(ROOT/'scripts/generate-observability-schema.py'),'--check'],capture_output=True,text=True)
        self.assertEqual(completed.returncode,0,completed.stderr)


if __name__=='__main__':unittest.main(verbosity=2)
