"""Strict real-kernel probe reports with fake child/kernel operations locally."""
import contextlib,importlib.util,io,json,subprocess,unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('namespace_acceptance',ROOT/'test/scripts/namespace_acceptance.py')
probe=importlib.util.module_from_spec(spec);spec.loader.exec_module(probe)
PARENT='mnt:[1000]'
MARKER='RO_NAMESPACE_WORKER_STARTED\n'
PASS={'status':'PASS','real_mounts':4,'namespace_before':'mnt:[1001]','namespace_after':'mnt:[1002]',
      'private_propagation':True,'rbind_nested':True,'individual_cleanup':True}

class AcceptanceStatusTests(unittest.TestCase):
    def run_result(self,completed=None,error=None,inventory=None,names=None,available=True):
        output=io.StringIO()
        namespace=mock.Mock(side_effect=names) if names else lambda _:PARENT
        with mock.patch.object(probe,'os',SimpleNamespace(readlink=namespace)), \
             mock.patch.object(probe,'rows',side_effect=inventory,return_value='unchanged'), \
             mock.patch.object(probe.shutil,'which',return_value='/usr/bin/unshare' if available else None), \
             mock.patch.object(probe.subprocess,'run',return_value=completed,side_effect=error) as run, \
             contextlib.redirect_stdout(output):
            status=probe.main()
            if not available:run.assert_not_called()
        return status,json.loads(output.getvalue())

    def completed(self,report=PASS,code=0,stderr=MARKER):
        return subprocess.CompletedProcess([],code,json.dumps(report),stderr)

    def test_kernel_bootstrap_denial_is_explicit_no_go(self):
        for code,stderr in ((1,'unshare: operation not permitted'),(77,'')):
            status,report=self.run_result(self.completed(None,code,stderr))
            self.assertEqual(status,77);self.assertEqual(report['status'],'UNAVAILABLE')
            self.assertEqual(report['security_acceptance'],'NO-GO')

    def test_failure_after_worker_started_is_never_capability_skip(self):
        for code in (1,77,-15):
            status,report=self.run_result(self.completed(None,code,MARKER+'unshare: PermissionError'))
            self.assertEqual(status,1);self.assertEqual(report['status'],'FAIL')
            self.assertEqual(report['security_acceptance'],'NO-GO')

    def test_only_complete_worker_success_is_accepted(self):
        status,report=self.run_result(self.completed())
        self.assertEqual(status,0);self.assertEqual(report,{**PASS,'parent_unchanged':True})

    def test_missing_tool_is_unavailable_without_spawning(self):
        status,report=self.run_result(available=False)
        self.assertEqual(status,77);self.assertEqual(report['status'],'UNAVAILABLE')

    def test_incomplete_forged_or_noncanonical_success_never_passes(self):
        invalid=[None,[],{'status':'PASS','real_mounts':4}]
        for key in PASS:
            row=dict(PASS);del row[key];invalid.append(row)
        for key,value in [('status','FAIL'),('real_mounts',4.0),('real_mounts',True),('real_mounts',3),
                          ('private_propagation',1),('rbind_nested',False),('individual_cleanup',False),
                          ('namespace_before',PARENT),('namespace_after',PARENT),
                          ('namespace_after',PASS['namespace_before']),('namespace_before',True),
                          ('namespace_after','not-a-namespace'),('extra',1),('parent_unchanged',True)]:
            invalid.append({**PASS,key:value})
        for row in invalid:
            with self.subTest(row=row):
                status,report=self.run_result(self.completed(row))
                self.assertEqual(status,1);self.assertEqual(report['status'],'FAIL')

    def test_missing_marker_duplicate_json_and_excess_output_never_pass(self):
        for result in (self.completed(stderr=''),self.completed(stderr=MARKER+'unexpected diagnostics'),
                       subprocess.CompletedProcess([],0,'not-json',MARKER),
                       subprocess.CompletedProcess([],0,'x'*4097,MARKER),
                       subprocess.CompletedProcess([],0,json.dumps(PASS)[:-1]+',"status":"PASS"}',MARKER)):
            with self.subTest(result=result):
                status,report=self.run_result(result)
                self.assertEqual(status,1);self.assertEqual(report['status'],'FAIL')

    def test_timeout_or_launch_error_produces_explicit_failure(self):
        for error in (subprocess.TimeoutExpired('unshare',40),OSError('could not start')):
            status,report=self.run_result(error=error)
            self.assertEqual(status,1);self.assertEqual(report['status'],'FAIL')
            self.assertEqual(report['security_acceptance'],'NO-GO')

    def test_parent_namespace_or_mount_changes_override_any_child_result(self):
        for child in (self.completed(),self.completed(None,1,'unshare: denied')):
            for args in ({'inventory':['original','changed']},{'names':[PARENT,'mnt:[9999]']}):
                status,report=self.run_result(child,**args)
                self.assertEqual(status,1);self.assertEqual(report['status'],'FAIL')
                self.assertIn('parent namespace',report['reason'])

if __name__=='__main__':unittest.main()
