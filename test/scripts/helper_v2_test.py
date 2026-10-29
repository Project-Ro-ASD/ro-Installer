"""V1 compatibility and V2 report-only response; real pipes, synthetic engine."""
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock
import installer_helper_test as legacy
import observability_test as observed

helper=legacy.helper
class V2Tests(legacy.ErrorAssertions,unittest.TestCase):
    def error(self,code,action,*args,**kwargs):
        with self.assertRaises(helper.HelperError) as raised:action(*args,**kwargs)
        self.assertEqual(raised.exception.code,code)

    def report(self):
        with tempfile.TemporaryDirectory(prefix='p0-04-report-') as td:
            rec=observed.r.Recorder(directory=td+'/records',owner_uid=os.geteuid())
            try:return rec.finish(8)
            finally:rec.close()
    def frame(self,report):return 'print('+repr(json.dumps({'protocolVersion':1,'type':'session-report','report':report}))+',flush=True)\n'
    def run_stub(self,body,version=2,events=None):
        data=legacy.install_request();data['protocolVersion']=version
        request=helper.parse_request(json.dumps(data).encode(),version=version)
        system=legacy.FakeSystem();confirmed=helper.validate_device(system,request.disk)
        with tempfile.TemporaryDirectory(prefix='p0-04-v2-') as td:
            path=Path(td)/'engine.py';path.write_text(legacy.BackendBridgeTests.prefix+body)
            with mock.patch.object(helper,'BACKEND_ARGV',(sys.executable,'-I',str(path))):
                return helper.run_backend(request,confirmed,system,emit=(events.append if events is not None else lambda _:None))
    def test_closed_gui_pipe_after_authorization_does_not_cancel_backend(self):
        read_fd,write_fd=os.pipe();os.close(read_fd)
        try:
            progress='print(json.dumps({"protocolVersion":1,"type":"progress","stage":5,"progress":0.5,"messageKey":"install_stage_file_copy"}),flush=True)\n'
            body=legacy.BackendBridgeTests.ready+progress+legacy.BackendBridgeTests.success+self.frame(self.report())
            # A closed GUI is represented by the actual EPIPE syscall, handled
            # by the same bounded public emitter used in helper.main.
            data=legacy.install_request();data['protocolVersion']=2
            request=helper.parse_request(json.dumps(data).encode(),version=2)
            system=legacy.FakeSystem();device=helper.validate_device(system,request.disk)
            with tempfile.TemporaryDirectory() as td:
                path=Path(td)/'engine.py';path.write_text(legacy.BackendBridgeTests.prefix+body)
                with mock.patch.object(helper,'BACKEND_ARGV',(sys.executable,'-I',str(path))):
                    result=helper.run_backend(request,device,system,emit=lambda message:helper.emit_message(message,2,write_fd))
                self.assertEqual(result,{'installed':True})
        finally:os.close(write_fd)
    def test_saturated_gui_pipe_is_bounded_without_polling(self):
        read_fd,write_fd=os.pipe();os.set_blocking(write_fd,False)
        try:
            try:
                while True:os.write(write_fd,b'x'*4096)
            except BlockingIOError:pass
            self.assertFalse(helper.emit_message({'type':'result'},2,write_fd))
        finally:os.close(read_fd);os.close(write_fd)

    def test_explicit_version_strictness_and_no_new_operations(self):
        data=legacy.install_request()
        for version in [1,2]:
            data['protocolVersion']=version
            self.assertEqual(helper.parse_request(json.dumps(data).encode(),version=version).protocol_version,version)
            self.error('INVALID_REQUEST',helper.parse_request,json.dumps(data).encode(),version=3-version)
        for mutation in [{'protocolVersion':True},{'operation':'report-get'},{'operation':'session-list'},{'path':'/root/secret'}]:
            self.error('INVALID_REQUEST',helper.parse_request,json.dumps({**data,**mutation}).encode(),version=2)
    def test_v2_report_delivered_after_real_child_exit(self):
        events=[];report=self.report()
        body=legacy.BackendBridgeTests.ready+legacy.BackendBridgeTests.success+self.frame(report)
        self.assertEqual(self.run_stub(body,events=events),{'installed':True})
        self.assertEqual(events[-1]['status'],'available');self.assertEqual(events[-1]['report'],report)
    def test_v1_stays_strict_and_no_report_response_when_absent(self):
        body=legacy.BackendBridgeTests.ready+legacy.BackendBridgeTests.success
        events=[];self.run_stub(body,version=1,events=events);self.assertEqual(events,[])
        self.error('BACKEND_ERROR',self.run_stub,body+self.frame(self.report()),version=1)
    def test_missing_and_bad_report_body_do_not_flip_success(self):
        base=legacy.BackendBridgeTests.ready+legacy.BackendBridgeTests.success
        for suffix,status in [('', 'unavailable'),(self.frame({'stdout':'SECRET_SENTINEL'}),'invalid')]:
            events=[];self.assertEqual(self.run_stub(base+suffix,events=events),{'installed':True})
            self.assertEqual(events[-1]['status'],status);self.assertIsNone(events[-1]['report'])
            self.assertNotIn('SECRET_SENTINEL',json.dumps(events))
    def test_install_failure_keeps_report_before_terminal_error(self):
        events=[];body=legacy.BackendBridgeTests.ready+'print(json.dumps({"protocolVersion":1,"type":"result","ok":False,"code":"INSTALL_FAILED"}),flush=True)\n'+self.frame(self.report())
        self.error('INSTALL_FAILED',self.run_stub,body,events=events)
        self.assertEqual(events[-1]['status'],'available')
    def test_crash_can_report_but_never_succeed_without_engine_result(self):
        events=[];self.error('BACKEND_ERROR',self.run_stub,self.frame(self.report())+'sys.exit(9)\n',events=events)
        self.assertEqual(events[-1]['status'],'available')
    def test_duplicate_out_of_order_extra_and_oversize_frames_rejected(self):
        ready=legacy.BackendBridgeTests.ready;success=legacy.BackendBridgeTests.success;report=self.frame(self.report())
        cases=[ready+success+report+report,ready+report+success,ready+success+report+success,
            ready+success+'print("x"*9000,flush=True)\n',ready+success+'print("{",end="",flush=True)\n',
            ready+success+'print(json.dumps({"protocolVersion":1,"type":"session-report","report":None,"extra":True}),flush=True)\n']
        for body in cases:
            with self.subTest(body=body[-120:]):self.error('BACKEND_ERROR',self.run_stub,body)
    def test_fragmented_json_frame_is_not_report_loss(self):
        frame=json.dumps({'protocolVersion':1,'type':'session-report','report':self.report()})+'\n'
        body=legacy.BackendBridgeTests.ready+legacy.BackendBridgeTests.success+f'raw={frame!r}\nfor part in raw:sys.stdout.write(part);sys.stdout.flush()\n'
        events=[];self.run_stub(body,events=events);self.assertEqual(events[-1]['status'],'available')

if __name__=='__main__':unittest.main(verbosity=2)
