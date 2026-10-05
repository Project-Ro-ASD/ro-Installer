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
    'info', 'warn', 'fail', 'validate_guest_command_path', 'run_host', 'cleanup', 'preflight_display',
    'configure_display', 'wait_for_spice_socket', 'launch_spice_viewer',
    'wait_for_qmp_socket', 'launch_auto_vm', 'monitor_auto_test',
    'wait_for_qga_ready', 'run_guest_install', 'verify_guest_artifacts',
    'reboot_guest', 'orchestrate_guest_install',
])


GUEST_PATH_SETTING = re.search(r'^GUEST_COMMAND_PATH=.*$', SOURCE, re.MULTILINE).group()
CANONICAL_GUEST_PATH = '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'


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
QGA_SOCKET="$RUN_DIR/qga.sock"
QGA_LOG="$RUN_DIR/qga.log"
QGA_READY_TIMEOUT_SECONDS=1
SERIAL_LOG="$RUN_DIR/serial.log"
PROJECT_DIR="$RUN_DIR"
HOST_VM_LOG_DIR="$RUN_DIR/guest-logs"
DISK_IMAGE="$RUN_DIR/disk.qcow2"
OVMF_CODE=code.fd OVMF_VARS_COPY=vars.fd ISO_FILE=live.iso
MEMORY_MB=4096 CPU_COUNT=4 AUTO_TEST_TIMEOUT_SECONDS=2
HOST_MOUNT_IN_GUEST=/run/ro-host
GENERATED_PROFILE_RELATIVE_PATH=outputs/vm/fixture/auto_profile.json
mkdir -p "$HOST_VM_LOG_DIR"
require_host_cmd() {
  echo "$1" >> "$RUN_DIR/required"
  command -v "$1" >/dev/null || fail "missing $1 (virt-viewer)"
}
'''
        return subprocess.run(['bash', '-c', setup + '\n' + GUEST_PATH_SETTING + '\n' + FUNCTIONS +
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
        self.assertEqual(args.count('virtio-serial-pci,id=virtio_serial0'), 1)
        self.assertIn('spicevmc,id=vdagent,name=vdagent', args)
        self.assertIn('virtserialport,bus=virtio_serial0.0,nr=2,chardev=vdagent,name=com.redhat.spice.0', args)
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

    def qga_trace_helper(self):
        (self.run_dir / 'linux').mkdir(exist_ok=True)
        (self.run_dir / 'linux/qga_client.py').write_text(r"""
import json, os, sys
from pathlib import Path
root = Path(os.environ['RUN_DIR'])
with (root / 'qga-trace').open('a') as trace:
    trace.write(json.dumps(sys.argv[1:]) + '\n')
args = sys.argv[1:]
if 'ready' in args:
    sys.exit(int(os.environ.get('READY_STATUS', '0')))
if 'exec' in args:
    status = int(os.environ.get('RUNNER_STATUS', '0'))
    if status: sys.exit(status)
    logs = root / 'guest-logs'
    (logs / 'runner-install-exited-0').touch()
    if os.environ.get('NO_LOGS') != '1':
        (logs / 'runner-logs-copied-0').touch()
        (logs / 'install-test.summary.json').write_text(json.dumps({'success': True}))
        (logs / 'install-test.log').touch()
        (logs / 'install-test.manifest.json').touch()
""")
        # QMP must never be used by guest installation orchestration.
        (self.run_dir / 'linux/qmp_send_keys.py').write_text('raise RuntimeError("unexpected keyboard injection")')

    def test_qga_topology_all_display_modes(self):
        for mode in ['headless', 'gui', 'spice']:
            result = self.shell('configure_display; printf "%s\\n" "${DISPLAY_ARGS[@]}"', mode)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.count('virtio-serial-pci'), 1)
            self.assertIn('socket,id=qga,path=', result.stdout)
            self.assertIn('qga.sock,server=on,wait=off', result.stdout)
            self.assertIn('bus=virtio_serial0.0,nr=1,chardev=qga,name=org.qemu.guest_agent.0', result.stdout)
            self.assertEqual('name=com.redhat.spice.0' in result.stdout, mode == 'spice')
            self.assertNotIn('tcp', result.stdout)
            self.assertNotIn('port=', result.stdout)
        self.assertIn('chmod 700 "$RUN_DIR"', SOURCE)

    def test_qga_success_orders_runner_artifacts_and_reboot(self):
        self.qga_trace_helper()
        result = self.shell('orchestrate_guest_install')
        self.assertEqual(result.returncode, 0, result.stderr + (self.run_dir / 'qga.log').read_text())
        events = [json.loads(line) for line in (self.run_dir / 'qga-trace').read_text().splitlines()]
        self.assertEqual([event[4] for event in events], ['ready', 'exec', 'submit'])
        command = events[1][-1]
        self.assertIn('mkdir -p /run/ro-host && mount -t 9p', command)
        self.assertIn('hostshare /run/ro-host && GUEST_COMMAND_PATH=', command)
        self.assertIn(f'PATH={CANONICAL_GUEST_PATH}; export PATH; ', command)
        self.assertIn(f'PATH={CANONICAL_GUEST_PATH}; export PATH; ', events[2][-1])
        self.assertIn('RO_INSTALLER_AUTO_REBOOT=0 RO_INSTALLER_VM_USE_LIVE_DISPLAY=1 sh /run/ro-host/test_qemu_guest_runner.sh', command)
        self.assertIn('/bin/sh', events[1])
        self.assertNotIn('sudo', command)
        self.assertIn('systemctl reboot', events[2][-1])

    def test_guest_preparation_chain_stops_on_failure(self):
        self.qga_trace_helper()
        result = self.shell('run_guest_install', GUEST_COMMAND_PATH=f'{self.tools}:{CANONICAL_GUEST_PATH}')
        self.assertEqual(result.returncode, 0, result.stderr)
        command = json.loads((self.run_dir / 'qga-trace').read_text().splitlines()[0])[-1]
        for name, variable in [('mkdir', 'MKDIR_STATUS'), ('mount', 'MOUNT_STATUS')]:
            self.tool(name, f'#!/bin/sh\necho {name} >> "$RUN_DIR/prep-trace"\nexit "${variable}"\n')
        self.tool('sh', '#!/bin/bash\necho runner >> "$RUN_DIR/prep-trace"\nexit 0\n')
        for mkdir, mount, expected in [('1', '0', ['mkdir']),
                                       ('0', '1', ['mkdir', 'mount']),
                                       ('0', '0', ['mkdir', 'mount', 'runner'])]:
            trace = self.run_dir / 'prep-trace'
            trace.unlink(missing_ok=True)
            result = subprocess.run(['/bin/sh', '-c', command], capture_output=True,
                                    env=dict(os.environ, RUN_DIR=str(self.run_dir),
                                             PATH='',
                                             MKDIR_STATUS=mkdir, MOUNT_STATUS=mount))
            self.assertEqual(result.returncode == 0, mkdir == mount == '0')
            self.assertEqual(trace.read_text().splitlines(), expected)

    def test_guest_runner_copies_before_exit_and_copy_failure_fails(self):
        host = self.run_dir / 'share'
        host.mkdir()
        profile = host / 'profile.json'
        profile.write_text('{}')
        binary = host / 'installer'
        binary.write_text("""#!/bin/sh
[ "$RO_INSTALLER_AUTO_REBOOT" = 0 ] || exit 99
[ "$WAYLAND_DISPLAY" = wayland-0 ] || exit 98
[ "$GDK_BACKEND" = wayland ] || exit 97
[ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ] || exit 96
printf '{"success":true}' > "$RO_INSTALLER_LOG_DIR/install-test.summary.json"
echo log > "$RO_INSTALLER_LOG_DIR/install-test.log"
echo manifest > "$RO_INSTALLER_LOG_DIR/install-test.manifest.json"
exit "${INSTALL_STATUS:-0}"
""")
        binary.chmod(0o755)
        # Exercise the root execution path without privileged host operations.
        self.tool('id', '#!/bin/sh\necho 0\n')
        self.tool('sudo', '#!/bin/sh\nexit 99\n')
        self.tool('cp', '#!/bin/sh\n[ "${FAIL_COPY:-0}" = 0 ] || exit 1\nexec /bin/cp "$@"\n')
        runtime = self.run_dir / 'runtime' / '1000'
        runtime.mkdir(parents=True)
        import socket
        display = socket.socket(socket.AF_UNIX)
        display.bind(str(runtime / 'wayland-0'))
        self.addCleanup(display.close)
        for status, copy_failure in [('0', '0'), ('7', '0'), ('0', '1')]:
            logs = self.run_dir / f'logs-{status}-{copy_failure}'
            local = self.run_dir / f'local-{status}-{copy_failure}'
            result = subprocess.run(['/bin/sh', str(ROOT / 'test_qemu_guest_runner.sh'), str(profile)],
                capture_output=True, env=dict(os.environ,
                    PATH='/no-qga-commands', GUEST_COMMAND_PATH=f'{self.tools}:{CANONICAL_GUEST_PATH}', HOST_MOUNT=str(host),
                    RO_INSTALLER_VM_BINARY=str(binary), RO_INSTALLER_VM_LOG_DIR=str(logs),
                    RO_INSTALLER_LOCAL_LOG_DIR=str(local), RO_INSTALLER_AUTO_REBOOT='0',
                    INSTALL_STATUS=status, FAIL_COPY=copy_failure,
                    RO_INSTALLER_VM_USE_LIVE_DISPLAY='1',
                    RO_INSTALLER_VM_RUNTIME_ROOT=str(runtime.parent)))
            self.assertEqual(result.returncode, int(status) if status != '0' else int(copy_failure))
            self.assertTrue((logs / f'runner-install-exited-{status}').exists())
            self.assertEqual((logs / f'runner-logs-copied-{status}').exists(), copy_failure == '0')
            if copy_failure == '0':
                self.assertTrue((logs / 'install-test.summary.json').exists())
                self.assertIn(f'state=logs-copied-{status}', (logs / 'runner-state.txt').read_text())

    def test_qga_guest_runner_display_timeout_fails_closed(self):
        host = self.run_dir / 'share'
        host.mkdir()
        profile = host / 'profile.json'
        profile.write_text('{}')
        binary = host / 'installer'
        binary.write_text('#!/bin/sh\nexit 99\n')
        binary.chmod(0o755)
        logs = self.run_dir / 'guest-logs'
        result = subprocess.run(['/bin/sh', str(ROOT / 'test_qemu_guest_runner.sh'), str(profile)],
            capture_output=True, text=True, env=dict(os.environ,
                HOST_MOUNT=str(host), RO_INSTALLER_VM_BINARY=str(binary),
                RO_INSTALLER_VM_LOG_DIR=str(logs), RO_INSTALLER_LOCAL_LOG_DIR=str(host / 'logs'),
                RO_INSTALLER_VM_USE_LIVE_DISPLAY='1', RO_INSTALLER_VM_DISPLAY_TIMEOUT_SECONDS='0',
                RO_INSTALLER_VM_RUNTIME_ROOT=str(host / 'no-session')))
        self.assertEqual(result.returncode, 1)
        self.assertIn('Live Wayland display not ready', result.stderr)
        self.assertTrue((logs / 'runner-display-not-ready').exists())
        self.assertFalse((logs / 'runner-install-started').exists())

    def test_generated_install_resolves_system_commands_with_empty_or_bad_path(self):
        self.qga_trace_helper()
        result = self.shell('run_guest_install')
        self.assertEqual(result.returncode, 0, result.stderr)
        command = json.loads((self.run_dir / 'qga-trace').read_text().splitlines()[0])[-1]
        # Stop before mounting anything. Intercept the actual generated chain
        # and check command discovery under the exported guest PATH.
        probe = r"""
mkdir() {
  [ "$PATH" = "$EXPECTED_PATH" ] || exit 91
  for tool in mkdir mount sh env cp systemctl; do
    # A new shell avoids the test functions shadowing command discovery.
    resolved=$(/bin/sh -c 'command -v "$1"' sh "$tool") || exit 92
    case "$resolved" in /*) ;; *) exit 93 ;; esac
  done
  /usr/bin/env | /usr/bin/grep -Fx "PATH=$EXPECTED_PATH" || exit 94
}
mount() { return 73; }
"""
        for inherited in ['', '/no-qga-commands']:
            result = subprocess.run(['/bin/sh', '-c', probe + command],
                capture_output=True, text=True,
                env=dict(os.environ, PATH=inherited, EXPECTED_PATH=CANONICAL_GUEST_PATH))
            self.assertEqual(result.returncode, 73, result.stderr)
            self.assertNotIn('command not found', result.stderr)

    def test_runner_default_path_precedes_external_commands(self):
        runner = (ROOT / 'test_qemu_guest_runner.sh').read_text()
        self.assertLess(runner.index('export PATH'), runner.index('$(dirname'))
        for inherited in ['', '/no-qga-commands']:
            logs = self.run_dir / ('runner-empty' if not inherited else 'runner-restricted')
            env = dict(os.environ, PATH=inherited, HOST_MOUNT=str(self.run_dir),
                       RO_INSTALLER_VM_LOG_DIR=str(logs), RO_INSTALLER_LOCAL_LOG_DIR=str(logs / 'local'))
            env.pop('GUEST_COMMAND_PATH', None)
            result = subprocess.run(['/bin/sh', str(ROOT / 'test_qemu_guest_runner.sh'),
                                     str(self.run_dir / 'missing-profile.json')],
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertTrue((logs / 'runner-profile-missing').exists())
            self.assertNotIn('not found', result.stderr)
        setup = runner[:runner.index('HOST_MOUNT=')]
        result = subprocess.run(['/bin/sh', '-c', setup + '\nprintf "%s" "$PATH"'],
                                env={'PATH': '/no-qga-commands'}, capture_output=True, text=True)
        self.assertEqual(result.stdout, CANONICAL_GUEST_PATH)

    def test_reboot_command_uses_explicit_path_with_restricted_environment(self):
        self.qga_trace_helper()
        self.tool('sleep', '#!/bin/sh\necho sleep:$1 >> "$RUN_DIR/reboot-trace"\n')
        self.tool('systemctl', '#!/bin/sh\necho systemctl:$1 >> "$RUN_DIR/reboot-trace"\n')
        result = self.shell('reboot_guest', GUEST_COMMAND_PATH=f'{self.tools}:{CANONICAL_GUEST_PATH}')
        self.assertEqual(result.returncode, 0, result.stderr)
        command = json.loads((self.run_dir / 'qga-trace').read_text().splitlines()[0])[-1]
        for inherited in ['', '/no-qga-commands']:
            trace = self.run_dir / 'reboot-trace'
            trace.unlink(missing_ok=True)
            result = subprocess.run(['/bin/sh', '-c', command], capture_output=True,
                                    env=dict(os.environ, PATH=inherited, RUN_DIR=str(self.run_dir)))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(trace.read_text().splitlines(), ['sleep:2', 'systemctl:reboot'])

    def test_guest_path_override_rejects_empty_or_relative_entries(self):
        self.qga_trace_helper()
        for path in ['', 'bin', '/usr/bin:', ':/usr/bin', '/usr/bin::/bin', '/bin:relative']:
            for operation in ['run_guest_install', 'reboot_guest']:
                result = self.shell(operation, GUEST_COMMAND_PATH=path)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('nonempty absolute directories', result.stderr)
            result = subprocess.run(['/bin/sh', str(ROOT / 'test_qemu_guest_runner.sh')],
                                    capture_output=True, text=True,
                                    env=dict(os.environ, GUEST_COMMAND_PATH=path))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('nonempty absolute directories', result.stderr)
        self.assertFalse((self.run_dir / 'qga-trace').exists())

    def test_guest_path_and_custom_guest_paths_are_shell_quoted(self):
        self.qga_trace_helper()
        result = self.shell('HOST_MOUNT_IN_GUEST="/run/host share\'s"; '
                            'GENERATED_PROFILE_RELATIVE_PATH="profiles/a b\'s.json"; run_guest_install',
                            GUEST_COMMAND_PATH="/guest bin's:/usr/bin")
        self.assertEqual(result.returncode, 0, result.stderr)
        command = json.loads((self.run_dir / 'qga-trace').read_text().splitlines()[0])[-1]
        probe = r"""
mkdir() { [ "$1" = -p ] && [ "$2" = "/run/host share's" ]; }
mount() { [ "$6" = "/run/host share's" ]; }
sh() {
  [ "$PATH" = "/guest bin's:/usr/bin" ] &&
  [ "$GUEST_COMMAND_PATH" = "$PATH" ] &&
  [ "$1" = "/run/host share's/test_qemu_guest_runner.sh" ] &&
  [ "$2" = "/run/host share's/profiles/a b's.json" ]
}
"""
        result = subprocess.run(['/bin/sh', '-c', probe + command], capture_output=True,
                                env=dict(os.environ, PATH=''))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_qga_failures_never_reboot_or_use_keyboard(self):
        self.qga_trace_helper()
        for settings, expected in [({'READY_STATUS': '1'}, ['ready']),
                                    ({'RUNNER_STATUS': '4'}, ['ready', 'exec']),
                                    ({'NO_LOGS': '1'}, ['ready', 'exec'])]:
            with self.subTest(settings=settings):
                (self.run_dir / 'qga-trace').unlink(missing_ok=True)
                for item in (self.run_dir / 'guest-logs').glob('*'):
                    item.unlink()
                result = self.shell('orchestrate_guest_install', **settings)
                self.assertNotEqual(result.returncode, 0)
                events = [json.loads(line)[4] for line in (self.run_dir / 'qga-trace').read_text().splitlines()]
                self.assertEqual(events, expected)
                if 'READY_STATUS' in settings:
                    self.assertIn('did not become ready within 1 seconds', result.stderr)
                    self.assertIn('qga.log', result.stderr)

    def test_artifact_summary_and_manifest_fail_closed(self):
        logs = self.run_dir / 'guest-logs'
        logs.mkdir()
        for name in ['runner-install-exited-0', 'runner-logs-copied-0', 'install-test.log']:
            (logs / name).touch()
        summary = logs / 'install-test.summary.json'
        for content in ['garbage', '{"success": false}', '{"success": true}']:
            summary.write_text(content)
            result = self.shell('verify_guest_artifacts')
            self.assertNotEqual(result.returncode, 0)
        (logs / 'install-test.manifest.json').touch()
        self.assertEqual(self.shell('verify_guest_artifacts').returncode, 0)

    def test_qmp_machine_control_and_serial_contract(self):
        self.assertIn('--combo home', function('select_live_boot_entry'))
        self.assertIn('--combo ret', function('select_live_boot_entry'))
        self.assertNotIn('--text', SOURCE)
        self.assertNotIn('GUEST_TERMINAL_OPEN_WAIT_SECONDS', SOURCE)
        self.assertNotIn('ctrl-alt-t', SOURCE)
        self.assertIn("grep -q 'RO_INSTALLER_VM_BOOT_OK'", function('monitor_auto_test'))
        self.assertNotIn('VIEWER_PID', function('monitor_auto_test'))
        self.assertLess(SOURCE.index('\npreflight_display\n'), SOURCE.index('\nbuild_installer\n'))


if __name__ == '__main__':
    unittest.main(verbosity=2)
