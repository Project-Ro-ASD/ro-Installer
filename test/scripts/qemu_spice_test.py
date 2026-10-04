"""Exercise real harness functions with fake host commands, never boot a VM."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / 'test_qemu_vm.sh').read_text()


def function(name):
    return re.search(r'^' + name + r'\(\) \{\n.*?^\}', SOURCE,
                     re.MULTILINE | re.DOTALL).group()


FUNCTIONS = '\n'.join(function(name) for name in [
    'info', 'warn', 'fail', 'run_host', 'cleanup', 'preflight_display',
    'configure_display', 'wait_for_spice_socket', 'launch_spice_viewer',
    'wait_for_qmp_socket', 'launch_auto_vm', 'monitor_auto_test',
    'send_guest_command',
])
TERMINAL_WAIT_SETTING = re.search(
    r'^GUEST_TERMINAL_OPEN_WAIT_SECONDS=.*$', SOURCE, re.MULTILINE).group()
GUEST_COMMAND_SETTING = re.search(
    r'^RUN_DIALOG_COMMAND=.*$', SOURCE, re.MULTILINE).group()


class SpiceHarnessTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='ro-spice-')
        self.addCleanup(self.temp.cleanup)
        self.run_dir = Path(self.temp.name)
        self.tools = self.run_dir / 'tools'
        self.tools.mkdir()
        self.tool('qemu-system-x86_64', '''#!/usr/bin/python3
import json, os, signal, socket, sys, time
from pathlib import Path
args = sys.argv[1:]
root = Path(os.environ['RUN_DIR'])
if args == ['-spice', 'help']:
    print('  unix=<bool (on/off)>' if os.environ.get('SPICE_SUPPORTED', '1') == '1' else 'unsupported', file=sys.stderr)
    sys.exit(1)
(root / 'qemu-args.json').write_text(json.dumps(args))
if os.environ.get('QEMU_EXITS') == '1': sys.exit(1)
sockets = []
for option in ['-qmp', '-spice']:
    if option not in args: continue
    spec = args[args.index(option) + 1]
    if option == '-spice' and os.environ.get('NO_SPICE_SOCKET') == '1': continue
    path = spec.split(',')[0][5:] if option == '-qmp' else spec.split('addr=')[1].split(',')[0]
    sock = socket.socket(socket.AF_UNIX)
    sock.bind(path)
    sockets.append(sock)
(root / 'serial.log').write_text('RO_INSTALLER_VM_BOOT_OK\\n')
while True: time.sleep(1)
''')
        self.tool('remote-viewer', '''#!/bin/sh
printf '%s\\n' "$1" > "$RUN_DIR/viewer-arg"
echo viewer-exited
exit 19
''')

    def tool(self, name, contents):
        target = self.tools / name
        target.write_text(contents)
        target.chmod(0o755)

    def shell(self, commands, mode='spice', **extra):
        env = dict(os.environ, RUN_DIR=str(self.run_dir), QEMU_DISPLAY_MODE=mode,
                   PATH=f'{self.tools}:{os.environ["PATH"]}', **extra)
        setup = r'''
set -euo pipefail
HOST_PREFIX=()
SPICE_SOCKET="$RUN_DIR/spice.sock"
SPICE_VIEWER_FILE="$RUN_DIR/spice.vv"
VIEWER_LOG="$RUN_DIR/remote-viewer.log"
QMP_SOCKET="$RUN_DIR/qmp.sock"
SERIAL_LOG="$RUN_DIR/serial.log"
PROJECT_DIR="$RUN_DIR"
HOST_VM_LOG_DIR="$RUN_DIR/guest-logs"
DISK_IMAGE="$RUN_DIR/disk.qcow2"
OVMF_CODE=code.fd OVMF_VARS_COPY=vars.fd ISO_FILE=live.iso
MEMORY_MB=4096 CPU_COUNT=4 AUTO_TEST_TIMEOUT_SECONDS=2
GUEST_RUNNER_START_TIMEOUT_SECONDS=300
LIVE_BOOT_WAIT_SECONDS=0 QMP_KEY_DELAY_MS=90
HOST_MOUNT_IN_GUEST=/run/ro-host
GENERATED_PROFILE_RELATIVE_PATH=outputs/vm/fixture/auto_profile.json
mkdir -p "$HOST_VM_LOG_DIR"
require_host_cmd() {
  echo "$1" >> "$RUN_DIR/required"
  command -v "$1" >/dev/null || fail "missing $1 (virt-viewer)"
}
'''
        return subprocess.run(['bash', '-c', setup + TERMINAL_WAIT_SETTING + '\n' + FUNCTIONS +
                               '\ntrap cleanup EXIT\n' + commands],
                              env=env, capture_output=True, text=True, timeout=20)

    def test_modes_and_spice_only_dependency(self):
        for mode in ['headless', 'gui', 'spice']:
            with self.subTest(mode=mode):
                required = self.run_dir / 'required'
                required.unlink(missing_ok=True)
                result = self.shell('preflight_display; configure_display; '
                                    'printf "arg:%s\\n" "${DISPLAY_ARGS[@]}"', mode)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(required.exists(), mode == 'spice')
                if mode == 'headless':
                    self.assertIn('arg:-display\narg:none', result.stdout)
                if mode == 'gui':
                    self.assertNotIn('arg:-display', result.stdout)
                if mode == 'spice':
                    self.assertEqual(required.read_text(), 'remote-viewer\n')
                    self.assertEqual(self.run_dir.stat().st_mode & 0o777, 0o700)

    def test_invalid_mode_rejected(self):
        result = self.shell('preflight_display', 'invalid')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('headless|gui|spice', result.stderr)

    def test_missing_viewer_fails_only_spice(self):
        for mode in ['headless', 'gui', 'spice']:
            result = self.shell('require_host_cmd() { fail "missing $1 (virt-viewer)"; }; '
                                'preflight_display', mode)
            self.assertEqual(result.returncode == 0, mode != 'spice')
            if mode == 'spice': self.assertIn('virt-viewer', result.stderr)

    def test_capability_help_with_nonzero_exit_succeeds_preflight(self):
        help_result = subprocess.run(
            [str(self.tools / 'qemu-system-x86_64'), '-spice', 'help'],
            env=dict(os.environ, RUN_DIR=str(self.run_dir)),
            capture_output=True, text=True)
        self.assertEqual(help_result.returncode, 1)
        self.assertIn('  unix=<bool (on/off)>', help_result.stderr)
        result = self.shell('preflight_display')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.run_dir / 'qemu-args.json').exists())

    def test_non_capability_unix_text_fails_preflight(self):
        result = self.shell('run_host() { echo "error: unix= is unsupported" >&2; return 1; }; '
                            'preflight_display')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Details: error: unix= is unsupported', result.stderr)

    def test_unsupported_qemu_fails_preflight(self):
        result = self.shell('preflight_display', SPICE_SUPPORTED='0')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('QEMU lacks SPICE UNIX socket support', result.stderr)
        self.assertIn('Details: unsupported', result.stderr)
        self.assertFalse((self.run_dir / 'qemu-args.json').exists())

    def test_auto_configuration_and_viewer_exit_do_not_affect_smoke(self):
        result = self.shell('preflight_display; launch_auto_vm; '
                            'wait "$VIEWER_PID" || true; kill -0 "$QEMU_PID"; '
                            'monitor_auto_test; '
                            'echo "$QEMU_PID" > "$RUN_DIR/qemu-pid"')
        self.assertEqual(result.returncode, 0, result.stderr)
        args = json.loads((self.run_dir / 'qemu-args.json').read_text())
        def value(option): return args[args.index(option) + 1]
        self.assertEqual(value('-display'), 'none')
        self.assertEqual(value('-spice'),
                         f'unix=on,addr={self.run_dir}/spice.sock,disable-ticketing=on')
        self.assertNotIn('port=', value('-spice'))
        self.assertEqual(args.count('virtio-serial-pci'), 1)
        self.assertIn('spicevmc,id=vdagent,name=vdagent', args)
        self.assertIn('virtserialport,chardev=vdagent,name=com.redhat.spice.0', args)
        self.assertEqual(value('-qmp'), f'unix:{self.run_dir}/qmp.sock,server=on,wait=off')
        self.assertEqual(value('-serial'), f'file:{self.run_dir}/serial.log')
        self.assertIn('virtio-9p-pci,id=fs0,fsdev=fsdev0,mount_tag=hostshare', args)
        self.assertIn('if=pflash,format=raw,readonly=on,file=code.fd', args)
        self.assertEqual((self.run_dir / 'viewer-arg').read_text().strip(),
                         str(self.run_dir / 'spice.vv'))
        self.assertEqual((self.run_dir / 'spice.vv').read_text(),
                         f'[virt-viewer]\ntype=spice\nunix-path={self.run_dir}/spice.sock\n')
        self.assertIn('viewer-exited', (self.run_dir / 'remote-viewer.log').read_text())
        with self.assertRaises(ProcessLookupError):
            os.kill(int((self.run_dir / 'qemu-pid').read_text()), 0)
        self.assertTrue((self.run_dir / 'serial.log').exists())

    def test_viewer_success_without_smoke_marker_does_not_pass(self):
        self.tool('remote-viewer', '#!/bin/sh\nexit 0\n')
        result = self.shell('launch_auto_vm; wait "$VIEWER_PID"; '
                            'printf "runner started" > "$HOST_VM_LOG_DIR/runner-state.txt"; '
                            ': > "$SERIAL_LOG"; '
                            'sleep() { SECONDS=$((SECONDS + 10)); }; '
                            'if monitor_auto_test; then exit 42; fi')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('Smoke test marker bulundu.', result.stdout)

    def test_headless_and_gui_keep_qmp_without_spice_or_viewer(self):
        for mode in ['headless', 'gui']:
            with self.subTest(mode=mode):
                (self.run_dir / 'qmp.sock').unlink(missing_ok=True)
                result = self.shell('launch_auto_vm', mode)
                self.assertEqual(result.returncode, 0, result.stderr)
                args = json.loads((self.run_dir / 'qemu-args.json').read_text())
                self.assertIn('-qmp', args)
                self.assertNotIn('-spice', args)
                self.assertFalse((self.run_dir / 'viewer-arg').exists())
                self.assertEqual('-display' in args, mode == 'headless')

    def test_qemu_exit_before_spice_is_clear(self):
        result = self.shell('launch_auto_vm', QEMU_EXITS='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('QEMU exited before SPICE was ready', result.stderr)
        self.assertFalse((self.run_dir / 'viewer-arg').exists())

    def test_spice_timeout_independent_of_ready_qmp(self):
        # Advance Bash's SECONDS in a mocked sleep to avoid a ten-second test.
        result = self.shell('configure_display; '
                            'qemu-system-x86_64 "${DISPLAY_ARGS[@]}" '
                            '-qmp "unix:$QMP_SOCKET,server=on,wait=off" & '
                            'QEMU_PID=$!; wait_for_qmp_socket; '
                            'sleep() { SECONDS=$((SECONDS + 10)); }; '
                            'launch_spice_viewer', NO_SPICE_SOCKET='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('SPICE socket not ready after 10 seconds', result.stderr)
        self.assertTrue((self.run_dir / 'qmp.sock').exists())
        self.assertFalse((self.run_dir / 'viewer-arg').exists())

    def test_cleanup_terminates_running_viewer_and_qemu_retains_artifacts(self):
        self.tool('remote-viewer', '#!/bin/sh\necho ready > "$RUN_DIR/viewer-ready"\nexec sleep 30\n')
        result = self.shell('launch_auto_vm; '
                            'for _ in {1..100}; do '
                            '[ ! -f "$RUN_DIR/viewer-ready" ] || break; sleep 0.01; done; '
                            '[ -f "$RUN_DIR/viewer-ready" ]; '
                            'echo "$VIEWER_PID $QEMU_PID" > "$RUN_DIR/pids"')
        self.assertEqual(result.returncode, 0, result.stderr)
        for pid in (self.run_dir / 'pids').read_text().split():
            with self.assertRaises(ProcessLookupError): os.kill(int(pid), 0)
        self.assertTrue((self.run_dir / 'serial.log').exists())
        self.assertTrue((self.run_dir / 'remote-viewer.log').exists())

    def qmp_trace_helper(self):
        (self.run_dir / 'linux').mkdir()
        (self.run_dir / 'linux/qmp_send_keys.py').write_text('''
import json, os, sys
from pathlib import Path
with (Path(os.environ['RUN_DIR']) / 'input-trace').open('a') as trace:
    trace.write(json.dumps(['qmp'] + sys.argv[1:]) + '\\n')
''')

    def test_qmp_settles_and_synchronizes_before_command_text(self):
        self.qmp_trace_helper()
        for wait in ['6', '9']:
            with self.subTest(wait=wait):
                trace = self.run_dir / 'input-trace'
                trace.unlink(missing_ok=True)
                result = self.shell(
                    'sleep() { printf \'["sleep", "%s"]\\n\' "$1" >> "$RUN_DIR/input-trace"; }; '
                    + GUEST_COMMAND_SETTING + '\nsend_guest_command "$RUN_DIALOG_COMMAND"',
                    **({} if wait == '6' else {'GUEST_TERMINAL_OPEN_WAIT_SECONDS': wait}))
                self.assertEqual(result.returncode, 0, result.stderr)
                events = [json.loads(line) for line in trace.read_text().splitlines()]
                operations = [
                    ('sleep', event[1]) if event[0] == 'sleep' else
                    ('combo', event[event.index('--combo') + 1]) if '--combo' in event else
                    ('text', event[event.index('--text') + 1]) for event in events]
                self.assertEqual(operations[:8], [
                    ('sleep', '0'), ('combo', 'ctrl-alt-t'), ('sleep', wait),
                    ('combo', 'ret'), ('sleep', '1'), ('combo', 'ctrl-c'),
                    ('combo', 'ret'), ('sleep', '1')])
                self.assertEqual(len(operations), 9)
                self.assertEqual(operations[-1][0], 'text')
                self.assertEqual(operations[-1][1],
                                 'sudo mkdir -p /run/ro-host && '
                                 'sudo mount -t 9p -o trans=virtio hostshare /run/ro-host && '
                                 'sh /run/ro-host/test_qemu_guest_runner.sh '
                                 '/run/ro-host/outputs/vm/fixture/auto_profile.json')
                self.assertNotIn(';', operations[-1][1])
                for event in events:
                    if event[0] == 'qmp':
                        self.assertEqual(event[event.index('--socket') + 1],
                                         str(self.run_dir / 'qmp.sock'))
                self.assertIn('--enter', events[-1])

    def test_terminal_settle_delay_is_bounded(self):
        for value in ['-1', '61', 'infinity', '1.5']:
            result = self.shell('send_guest_command "must never be typed"',
                                GUEST_TERMINAL_OPEN_WAIT_SECONDS=value)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('integer from 0 to 60', result.stderr)

    def test_guest_command_stops_on_mkdir_or_mount_failure(self):
        self.tool('sudo', '''#!/bin/sh
echo "$1" >> "$RUN_DIR/command-trace"
case "$1" in
  mkdir) exit "$MKDIR_STATUS" ;;
  mount) exit "$MOUNT_STATUS" ;;
esac
exit 99
''')
        self.tool('sh', '#!/bin/bash\necho runner >> "$RUN_DIR/command-trace"\nexit 0\n')
        for mkdir, mount, expected in [('1', '0', ['mkdir']),
                                        ('0', '1', ['mkdir', 'mount']),
                                        ('0', '0', ['mkdir', 'mount', 'runner'])]:
            with self.subTest(mkdir=mkdir, mount=mount):
                trace = self.run_dir / 'command-trace'
                trace.unlink(missing_ok=True)
                result = self.shell(GUEST_COMMAND_SETTING + '\neval "$RUN_DIALOG_COMMAND"',
                                    MKDIR_STATUS=mkdir, MOUNT_STATUS=mount)
                self.assertEqual(result.returncode == 0, mkdir == mount == '0')
                self.assertEqual(trace.read_text().splitlines(), expected)

    def test_qmp_injection_and_smoke_contract(self):
        for name, expected in [
            ('select_live_boot_entry', ['qmp_send_keys.py', '--combo home', '--combo ret']),
            ('send_guest_command', ['qmp_send_keys.py', '--combo ctrl-alt-t', '--text "$command_text"']),
            ('monitor_auto_test', ["grep -q 'RO_INSTALLER_VM_BOOT_OK'", 'Installer failure summary']),
        ]:
            for token in expected: self.assertIn(token, function(name))
            self.assertNotIn('VIEWER_PID', function(name))
        self.assertIn('sudo mount -t 9p -o trans=virtio hostshare', SOURCE)
        self.assertIn('test_qemu_guest_runner.sh', SOURCE)
        self.assertIn('require_host_cmd qemu-system-x86_64', SOURCE)
        self.assertIn('require_host_cmd qemu-img', SOURCE)
        self.assertLess(SOURCE.index('\npreflight_display\n'), SOURCE.index('\nbuild_installer\n'))


if __name__ == '__main__':
    unittest.main(verbosity=2)
