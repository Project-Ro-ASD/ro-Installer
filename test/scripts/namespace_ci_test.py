"""Required namespace CI verdicts; fake Python only, never creates a namespace."""
import json,os,re,shlex,shutil,subprocess,tempfile,unittest
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]

class NamespaceCiTests(unittest.TestCase):
    def test_ci_preserves_probe_failures_and_json_including_unavailable(self):
        for code,status in ((0,'PASS'),(1,'FAIL'),(77,'UNAVAILABLE')):
            with self.subTest(code=code),tempfile.TemporaryDirectory() as td:
                root=Path(td);(root/'scripts').mkdir();(root/'bin').mkdir()
                script=root/'scripts/check-namespace-ci.sh'
                shutil.copyfile(ROOT/'scripts/check-namespace-ci.sh',script)
                stub=root/'bin/python3'
                stub.write_text('#!/bin/sh\n[ "$#" -eq 2 ] && [ "$1" = -B ] && [ "$2" = test/scripts/namespace_acceptance.py ] || exit 99\n'
                    + 'printf \'%s\\n\' '+shlex.quote(json.dumps({'status':status}))+'\nexit '+str(code)+'\n')
                stub.chmod(0o700)
                result=subprocess.run(['bash',str(script)],capture_output=True,text=True,timeout=5,
                    env={**os.environ,'PATH':str(root/'bin')+os.pathsep+os.environ['PATH']})
                self.assertEqual(result.returncode,code,result.stderr)
                expected={'status':status}
                self.assertEqual(json.loads(result.stdout),expected)
                self.assertEqual(json.loads((root/'outputs/namespace-acceptance/result.json').read_text()),expected)

    def test_mount_capability_is_confined_to_required_disposable_job(self):
        source=(ROOT/'.github/workflows/rpm-fedora44.yml').read_text()
        jobs={name:body for name,body in re.findall(r'(?ms)^  ([a-z][a-z0-9-]*):\n(.*?)(?=^  [a-z][a-z0-9-]*:|\Z)',source)}
        fixture=jobs['real-namespace'];build=jobs['build-rpm']
        options=re.search(r'(?m)^      options: (.+)$',fixture).group(1)
        self.assertEqual(shlex.split(options),['--cap-add','SYS_ADMIN','--security-opt','apparmor=unconfined'])
        self.assertNotRegex(build,r'(?m)^      options:')
        self.assertRegex(build,r'(?m)^    needs: real-namespace$')
        self.assertRegex(build,r'(?m)^    if: \$\{\{ always\(\) \}\}$')
        prerequisite=build.split('name: Require real namespace prerequisite',1)[1].split('- name:',1)[0]
        self.assertIn("if: needs.real-namespace.result != 'success'",prerequisite)
        self.assertRegex(prerequisite,r'(?m)^          exit 1$')
        self.assertLess(build.index('name: Require real namespace prerequisite'),build.index('name: Install Fedora 44 build dependencies'))
        self.assertIn('run: bash scripts/check-namespace-ci.sh',fixture)
        self.assertNotIn('continue-on-error:',fixture)
        self.assertIn('if: always()',fixture)
        self.assertIn('name: ro-installer-namespace-fedora44',fixture)
        self.assertIn("fields['Seccomp'].strip() == '2'",fixture)

if __name__=='__main__':unittest.main()
