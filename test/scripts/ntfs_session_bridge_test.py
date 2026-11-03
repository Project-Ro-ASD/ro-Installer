#!/usr/bin/env python3
"""Storage drain over fake private workers, sockets and normal-file leases."""
import fcntl,json,os
from pathlib import Path
import subprocess,sys,tempfile,time,unittest
import threading
from unittest import mock
import installer_helper_test as legacy
from ntfs_native_runner_test import proxy

ROOT=Path(__file__).resolve().parents[2]
FIXTURE=ROOT/'test/fixtures/ntfs_session_bridge.py'

class TransportTests(unittest.TestCase):
    def run_case(self,mode):
        with tempfile.TemporaryDirectory() as td:
            directory=Path(td);lock=directory/'new-lease'
            lease=os.open(lock,os.O_RDWR|os.O_CREAT|os.O_EXCL|os.O_CLOEXEC,0o600)
            fcntl.flock(lease,fcntl.LOCK_EX|fcntl.LOCK_NB)
            try:
                process=subprocess.Popen([sys.executable,'-I',str(FIXTURE),str(ROOT),td,str(lease),mode],
                    pass_fds=(lease,),stdout=subprocess.PIPE,stderr=subprocess.PIPE)
                starts=mode not in ('thread-error','wrong-device','wrong-ownership')
                if starts:
                    deadline=time.monotonic()+5
                    while not (directory/'started').exists() and time.monotonic()<deadline and process.poll() is None:time.sleep(.01)
                    self.assertTrue((directory/'started').exists())
                    os.close(lease);lease=None
                    with lock.open('r+b') as other:
                        with self.assertRaises(BlockingIOError):fcntl.flock(other.fileno(),fcntl.LOCK_EX|fcntl.LOCK_NB)
                    (directory/'release').write_text('lease checked')
                else:
                    os.close(lease);lease=None
                output,error=process.communicate(timeout=15)
                self.assertEqual(process.returncode,0,error.decode())
                with lock.open('r+b') as other:fcntl.flock(other.fileno(),fcntl.LOCK_EX|fcntl.LOCK_NB)
                result=json.loads((directory/'session-result.json').read_text())
                self.assertEqual(result['spawns'],0 if mode in ('wrong-device','wrong-ownership') else 1)
                if starts and mode!='timeout':self.assertEqual((directory/'complete').read_text(),'quiescent')
                if mode=='normal':self.assertEqual(result['status'],0)
                else:self.assertNotEqual(result['status'],0)
                if (directory/'reply.json').exists():
                    raw=(directory/'reply.json').read_text();self.assertNotIn('PRIVATE_DEVICE_LABEL',raw)
                    reply=json.loads(raw)['result']
                    self.assertEqual(reply['status'],'success' if mode in ('normal','repeat') else 'failed')
                    if mode not in ('normal','repeat'):
                        if mode in ('wrong-device','wrong-ownership'):
                            self.assertTrue(reply['progressKnown']);self.assertFalse(reply['sourceMayHaveChanged'])
                        else:
                            self.assertFalse(reply['progressKnown']);self.assertTrue(reply['sourceMayHaveChanged'])
                if mode=='repeat':self.assertIn('SESSION_ERROR',(directory/'repeat.json').read_text())
            finally:
                if lease is not None:os.close(lease)
                if 'process' in locals() and process.poll() is None:process.kill();process.communicate(timeout=5)

class ClosingTests(unittest.TestCase):
    def test_stopping_session_refuses_storage_before_spawn(self):
        session=legacy.load_module('ntfs_closing_session',ROOT/'linux/ro-installer-session')
        supervisor=object.__new__(session.Supervisor)
        supervisor.storage_condition=threading.Condition();supervisor.stop=threading.Event();supervisor.stop.set()
        supervisor.storage_accepting=True;supervisor.ntfs_attempted=False;supervisor.storage_failed=False
        with mock.patch.object(session,'subprocess',proxy(session.subprocess,Popen=mock.Mock())):
            with self.assertRaises(RuntimeError):supervisor.ntfs_transaction({},lambda _:None)
            session.subprocess.Popen.assert_not_called()
        self.assertTrue(supervisor.storage_failed)


for mode in ('normal','crash','disconnect','stderr','overflow','bad-json','bad-exit','timeout','leak','repeat','wait-error','close-error','thread-error','wrong-device','wrong-ownership'):
    setattr(TransportTests,'test_'+mode,lambda self,mode=mode:self.run_case(mode))
if __name__=='__main__':unittest.main()
