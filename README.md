# Ro-Installer

Ro-Installer is the system installer for Ro-ASD, a Fedora KDE based Linux
distribution. It installs the prepared Ro-Compose filesystem onto a target disk
and validates the resulting system. Ro-Installer is not a distro builder.

## Architecture and Ownership

Ro-Installer owns:

- Target disk discovery and safety, partitioning, formatting, and mounting.
- Deployment of the prepared Ro-Compose filesystem.
- Narrow target finalization, bootloader setup, and technical post-install
  validation.
- Cleanup and a minimal firstboot handoff.
- Automated profile-based installation and QEMU test support.

Ro-Compose owns image composition and supplies the supported baseline kernel.
Ro-ASD Initial Setup / Plasma Setup owns first-user configuration and first-boot
OOBE: final user accounts, passwords, hostname, locale, timezone, keyboard, and
theme configuration. Ro-Assist will own future kernel-management UX and Btrfs
recovery/snapshot management.

Ro-Installer does not own general ISO composition/remixing, runtime Internet
dependency, runtime DNF package installation as product policy, repository
creation/wiring, COPR configuration, distro identity rewriting, kernel
selection/channel policy, or replacing Fedora kernels with custom kernels.

## Standard Storage Contract

The standard automatic Ro-ASD profile is x86_64, UEFI, GPT, and Btrfs, with ZRAM
and no dedicated disk swap partition. The standard rollback-aware Btrfs layout is:

| Subvolume | Mount point |
| --- | --- |
| `root` | `/` |
| `home` | `/home` |
| `var_log` | `/var/log` |
| `var_cache` | `/var/cache` |
| `var_tmp` | `/var/tmp` |

`/boot` belongs inside the root Btrfs snapshot scope. The ESP remains FAT32 and
is mounted at `/boot/efi`.

The first implementation milestone is full-disk erase only. Manual partitioning,
alongside install, replace-existing-OS, reinstall-preserve-home, and LUKS are
future milestones. Manual installation may later support ext4/XFS; these
filesystems are valid for reliable normal Ro-ASD operation, but Ro-ASD must not
promise Btrfs snapshot/rollback/recovery features on them.

## Implementation Status

The current installation contract uses full-disk Btrfs deployment, narrow target
finalization, package-neutral prepared-kernel boot setup, technical validation,
and the v1 firstboot handoff. Repository, kernel composition, application, theme,
and distro branding policy belong to Ro-Compose.

Installer-owned ISO production, static ISO composition audit, and ISO payload
extraction benchmarking have been removed. Compose now provides the
`installer-test-iso` target and an external integration ISO for Installer E2E.
The canonical installed product profile is `desktop-standard`, with `live-iso`
and `installer-test-iso` as Compose targets. Full install/reboot E2E acceptance
remains in progress until a real run reaches `RO_INSTALLER_VM_BOOT_OK`.

Destructive disk operations remain guarded by storage planning and validation.
The current stable path rejects LUKS, LVM, RAID, multipath, and nested storage
topologies before destructive disk writes.

## User-session GUI and Privileged Installation (PR-A2)

The desktop launcher starts `/usr/bin/ro-installer` as the current graphical
user without changing UID, Wayland/X11, XDG_RUNTIME_DIR or theme environment.
Interactive main never reexecutes the GUI as root. `CommandRunner` executes
commands directly; `RO_INSTALLER_COMMAND_SUDO` has no effect. Normal `lsblk`,
`uname`, EFI checks and `nmcli` queries need no helper authorization. Explicit
root automatic-profile/QEMU execution remains separate and uses the existing
engine directly; its root check ignores UID environment variables.

The interactive privilege boundary is now:

```text
user GUI → /usr/bin/pkexec --disable-internal-agent
         /usr/libexec/ro-installer-helper --protocol=1
         → /usr/libexec/ro-installer-backend --privileged-backend-v1
         → existing Dart InstallService and its nine stages
```

The same RPM owns the isolated Python helper and the compiled, non-GUI Dart
backend, both root:root 0755. The backend is built with `dart compile exe`;
partitioning/install logic remains in the existing Dart stages. Only the
helper-specific `org.roasd.installer.helper` polkit action remains, bound to
exactly `/usr/libexec/ro-installer-helper`, with defaults no/no/auth_admin.
There is no retained authorization, root-GUI policy, sudoers or live-only allow
rule. A future active/local liveuser rule belongs to Ro-image-compose.

RPM stripping preserves only `/usr/libexec/ro-installer-backend`, because Dart
appends its AOT snapshot after the ELF image and strip would truncate it. Other
bundle ELF files retain normal Fedora processing. A real RPM fixture verifies
the snapshot bytes, and Fedora 44 CI executes the installed backend with an
invalid protocol request that exits before any disk operation.

### Disk discovery and confirmation

`DiskDiscoveryResult` distinguishes successful empty discovery, command start
failure, nonzero exit, timeout, incompatible JSON and topology/parsing failure.
Enumeration has a ten-second timeout. Blank virtio disks with null/empty MODEL,
boolean RM, `[null]` mountpoints, and absent/empty children are supported.
Malformed independent entries are excluded with a visible warning while valid
disks remain. Null children is not assumed to prove a blank disk. Ambiguous
identities fail the entire discovery. The UI never displays stderr or exception
text as a disk-discovery message and clears stale selection/confirmation on
refresh.

Only after selecting a disk does the GUI request an authorized `probe-disk`.
The destructive confirmation displays the authoritative path/size and retains
`{path,majorMinor,size,diskSequence}`. Installation sends that exact identity;
GUI metadata cannot override it. Authorization cancellation (126), denial (127),
missing pkexec, protocol failure and helper errors are distinct client errors.
There is no sudo or root-GUI fallback.

### Helper protocol v1

stdin is exactly one UTF-8 JSON object, at most 16 KiB, closed within five
seconds. Only no arguments or `--protocol=1` are supported. Every shown field is
required; additional/duplicate fields, unknown versions/operations, non-finite
numbers and malformed JSON are rejected. Each example is a separate invocation:

```json
{"protocolVersion":1,"operation":"audit-live"}
```

```json
{"protocolVersion":1,"operation":"probe-disk","disk":"/dev/vda"}
```

```json
{"protocolVersion":1,"operation":"install-full-disk","disk":"/dev/vda","partitionMethod":"full","fileSystem":"btrfs","confirmDestructive":true,"expectedDevice":{"majorMinor":"252:0","size":68719476736,"diskSequence":11}}
```

Replace the example identity with the actual probe. Size is bytes and diskSequence
is the kernel device generation. Only canonical /dev names are accepted. There
are no command/argv/environment/source/destination/chroot/profile/test-mode fields.
Root authority comes from effective UID, never environment variables.

Stdout is NDJSON. Audit/probe emit one `type:result` envelope with
`{protocolVersion, type, operation, ok}` plus respectively `audit` or `device`.
Audit reports runtime facts and `installationImplemented:true`; it does not
certify live-image provenance. Install emits bounded progress followed by exactly
one result. A successful final result requires explicit backend success and a
zero backend exit; EOF/crash/malformed output can never imply success:

```json
{"protocolVersion":1,"type":"progress","stage":2,"progress":0.2,"messageKey":"install_stage_partitioning"}
{"protocolVersion":1,"type":"result","operation":"install-full-disk","ok":true,"installed":true}
```

Errors have `ok:false,error:{code,message}` with constant messages. Stage is
0–9; messageKey must match the fixed stage-key table in `helper_protocol.dart`.
Progress is finite and within 0–1. Heartbeats repeat current progress every five
seconds during long commands; no raw command output is forwarded. Messages are
at most 8 KiB; each stream is limited to 4 MiB / 16,384 messages. Backend/authorization
stderr is discarded with a 64 KiB cap. Client probe requests have a two-minute
conversation timeout; disk enumeration's timeout is separate.

| Exit | Meaning / structured codes |
| --- | --- |
| 0 | Successful audit, probe or complete installation |
| 2 | INVALID_REQUEST, REQUEST_TOO_LARGE, REQUEST_TIMEOUT |
| 3 | ROOT_REQUIRED |
| 4 | DEVICE_NOT_FOUND, NOT_BLOCK_DEVICE, UNSAFE_DEVICE, AMBIGUOUS_TOPOLOGY, DEVICE_CHANGED, UNSUPPORTED_PLATFORM |
| 5 | BUSY, UNSAFE_LOCK |
| 7 | SYSTEM_ERROR |
| 8 | INSTALL_FAILED |
| 9 | BACKEND_ERROR |

### Backend handshake, scope and cancellation

The helper clears inherited environment, sets cwd `/` and umask 077, and chooses
all executable paths/argv. Its only child APIs are fixed read-only lsblk and
the fixed backend. The backend receives only
`{protocolVersion:1,operation:"install-full-disk",disk,expectedDevice}`. It
requires root and constructs a fixed full/Btrfs engine state, with no GUI
state/environment/profile overrides. Its initial request must arrive within
five seconds; total stdin is capped at 32 KiB.

The helper holds `/run/ro-installer/install.lock` for the complete backend
lifetime, in a root-owned 0700 directory with a root-owned 0600 persistent,
non-symlink inode. The backend inherits the locked descriptor so its kernel
lease remains held even if the helper is killed. It validates stat/sysfs/lsblk
identity and topology, compares
the confirmed major:minor/size/diskSequence and repeats validation before spawn.
After all partitioning read-only planning/tool checks, immediately before the
first wipefs, the existing Dart stage invokes its mutation callback. The backend
emits `{protocolVersion:1,type:"ready"}` and waits up to fifteen seconds. The
helper independently validates the device again and sends
`{protocolVersion:1,type:"continue",device:{path,majorMinor,size,diskSequence}}`.
The backend requires an exact matching identity before continuing. Its final
message is `{protocolVersion:1,type:"result",ok,code}` with OK, INSTALL_FAILED or
BACKEND_ERROR. The helper checks framing, schema, explicit success and process
exit before emitting the GUI's final result.

PR-A1 guards remain: partitions, aliases, removable/read-only disks, live/root
backing devices, mounted-device ancestors, active swap, nested target storage
and ambiguous topology are refused. Loop and overlay backing storage are traced.
Mounted Btrfs membership, unknown filesystems and stacked mounts still fail closed.
Only x86_64 UEFI, full erase, Btrfs, GPT, a 512 MiB ESP and the existing Btrfs
subvolume layout are authorized. No disk swap is created. Helper disk preparation
does not globally swapoff/unmount; ZRAM remains system policy. Alongside, manual,
ext4/XFS, LUKS/LVM/RAID/multipath and arbitrary swap are not authorized.

PR-A2 does not support cancellation after entering installation. Navigation and
target changes are disabled, and closing the GUI does not cancel the independent
backend session. The helper ignores terminal interruption and continues without
GUI output while retaining the lock. Protocol failure after authorization drains
the backend without forwarding data and returns failure after exit. A two-hour
helper watchdog kills a stalled backend process group and reports failure; this
is recovery from a stuck operation, not safe rollback. Any partial failure or
watchdog expiry requires inspecting target/mount state before retrying. There is
no automatic retry or promise of recovery from power loss/helper SIGKILL, even
though the backend retains the lock after helper death.

### Installed-target cleanup and validation

Target finalization strictly enumerates the RPM DB before removal and verifies
absence after removal; an unreadable RPM DB never means successful absence.
Narrow cleanup and post-install checks cover the installer RPM, both /usr/bin
symlinks, lib/lib64 bundle directories, desktop file, launcher, helper, backend,
old/new installer polkit policies, future 49-ro-installer-live.rules and legacy
ro-installer-live sudoers file. Both existing paths and dangling symlinks fail
validation. Unrelated system polkit files are preserved. The runtime /run lock
is excluded from the prepared-root copy.

The stable gate runs helper protocol/storage/locking/backend/launcher/RPM tests
and the full Flutter suite. Package CI additionally checks the compiled backend,
helper ownership/modes and exact helper policy in the actual Fedora 44 product
RPM, rejects old root-GUI policy/sudoers/allow rules, and verifies installability.
No release/version/tag changes are needed for this integration.

Before release, run a real Compose ISO with an active graphical polkit agent,
validate its live/root topology and authorization, then perform full install and
reboot to RO_INSTALLER_VM_BOOT_OK. This PR does not create an ISO or claim that
hardware/destructive E2E has passed. Further recovery/diagnostic hardening and any
fixes found during that run should precede the single future immutable release.

## Technology and Repository Layout

- Flutter and Dart for the Linux desktop application.
- `lib/`: Flutter UI, installer state, services, storage planning, and stages.
- `bin/`: fixed non-GUI privileged Dart backend entrypoint.
- `assets/`: product images, branding, and localization data.
- `linux/`: Linux desktop integration, launcher, policy, and helper scripts.
- `scripts/`: RPM packaging, stable-gate automation, and external-ISO QEMU test
  helpers.
- `test/`: unit, service, stage, profile, storage, log, and script contract tests.
- `tool/`: development checks, including the i18n audit.
- `ro-installer.spec`: RPM packaging.
- `.github/workflows/`: CI automation. Fedora 44 is the current supported RPM packaging/CI
  baseline; that exact Fedora release is not an architectural requirement.

## Testing

Before a pull request, run the code and contract checks that match the changed
area. The full local acceptance gate is:

```bash
flutter analyze
flutter test
dart run tool/i18n_audit.dart
bash scripts/check-stable.sh
```

The stable gate retains shell/Python syntax, Flutter analysis/tests, i18n,
destructive-disk safeguards, password/command redaction coverage, restricted
sudo policy, RPM source/build hygiene, and diagnostic/log artifact contracts.
It does not require Installer-owned ISO composition, repository wiring, COPR
kernel policy, or a custom-kernel-only release policy. Remaining shell scripts
are syntax-checked; the gate also guards the external-ISO testing boundary.

Ro-Installer does not build or remix test ISOs. QEMU integration requires a
known-good external Compose-produced live/test ISO, supplied explicitly:

```bash
scripts/test-qemu.sh --suite check --iso /path/to/compose-test.iso
RO_ASD_TEST_ISO=/path/to/compose-test.iso scripts/test-qemu.sh --suite smoke
scripts/test-qemu.sh --suite install --iso /path/to/compose-test.iso
RO_INSTALLER_TEST_ISO=/path/to/compose-test.iso ./test_qemu_vm.sh auto
```

The QEMU suites are `check`, `boot`, `smoke`, `install`, and `all`. The boot
helper and wrapper accept `--iso PATH` or `RO_ASD_TEST_ISO`; the full install
harness requires `RO_INSTALLER_TEST_ISO`. Missing or unreadable input stops
before building the Installer or launching QEMU. No repository-local ISO is
selected automatically.

The automated install harness accepts these `QEMU_DISPLAY_MODE` values:

| Mode | Use |
| --- | --- |
| `headless` (default) | CI / unattended, no display window |
| `gui` | Native QEMU display |
| `spice` | Recommended local interactive mode with clipboard |

```bash
RO_INSTALLER_TEST_ISO=/absolute/path/to/Ro-ASD-44-integration-0001-x86_64.iso \
QEMU_DISPLAY_MODE=spice \
./test_qemu_vm.sh auto
```

Host requirements are `qemu-system-x86_64`, `qemu-img`, and OVMF firmware
(Fedora packages: `qemu-system-x86`, `qemu-img`, `edk2-ovmf`). Only `spice`
requires a SPICE-enabled QEMU build and `remote-viewer` (`virt-viewer`, version
8.0 or newer for UNIX socket connection files). Preflight checks the viewer and
QEMU UNIX socket capability before building or starting the installation.

SPICE uses `$RUN_DIR/spice.sock` in a private per-run directory, with no TCP
listener, password, or credentials. QEMU runs with `-display none` and the
standard `com.redhat.spice.0` virtio-serial agent channel. The harness waits up
to 10 seconds for the socket, then launches `remote-viewer "$RUN_DIR/spice.vv"`.
Viewer output is retained in `$RUN_DIR/remote-viewer.log`. Closing the viewer
leaves QEMU and the automated test running; cleanup terminates both processes
best-effort and retains the run directory and logs after failures. Manual mode
also supports SPICE; its existing native-window behavior remains for other modes.

Guest clipboard requires `spice-vdagent` running in the Compose-produced live
image. It belongs to the live image environment, not Installer dependencies.
The clipboard path is host desktop → remote-viewer → SPICE → virtio-serial
vdagent channel → spice-vdagent in the live guest. QMP does not synchronize
clipboard content, and no custom clipboard scripts or SSH are used.

SPICE is for local human viewing and clipboard/input; QMP remains machine
control and short boot-menu key combinations. QGA executes guest commands,
9p transports files, and the serial `RO_INSTALLER_VM_BOOT_OK` marker is the final
boot authority, independent of QGA availability and viewer exit status.

Automation follows external Compose ISO → QEMU UEFI → QGA readiness → QGA
`guest-exec` → 9p mount → `test_qemu_guest_runner.sh` → Installer with
`RO_INSTALLER_AUTO_REBOOT=0` → logs copied to host → QGA reboot → installed
target → serial `RO_INSTALLER_VM_BOOT_OK` → smoke-service poweroff. The runner's
manual default for automatic reboot remains unchanged.

All display modes expose `$RUN_DIR/qga.sock`, a Unix-only socket under the
private (0700) run directory. One `virtio-serial-pci,id=virtio_serial0` controller
carries QGA on port 1 (`org.qemu.guest_agent.0`) and, in SPICE mode, vdagent on
port 2 (`com.redhat.spice.0`). The external live ISO must contain an enabled
`qemu-guest-agent.service`; the named device lets it start without terminal input.

The host retries socket connection, protocol synchronization and `guest-ping`
for `QGA_READY_TIMEOUT_SECONDS` (default 300). Each connection uses
[`guest-sync-delimited`](https://www.qemu.org/docs/master/interop/qemu-ga-ref.html#command-guest-sync-delimited)
with a fresh token and sentinel to discard stale stream data. Readiness timeout
fails closed and points to `qga.log`, `serial.log`, and the run directory.
There is no keyboard fallback. `/bin/sh -c` runs the quoted mkdir → mount →
runner chain with `&&`, without interactive sudo.
Install and reboot shells explicitly export `GUEST_COMMAND_PATH` (default
`/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`) before external
commands. The guest runner resets and exports PATH before its first external
command using the same default or explicit harness override, ignoring inherited
service/shell PATH. Empty overrides, empty entries, and relative directories
are rejected; custom mount/profile/PATH values are shell-quoted.

Because the Flutter Linux runner initializes GTK even in auto mode, the QGA harness waits up to 120 seconds for one existing live
Wayland socket under `/run/user` and passes its `XDG_RUNTIME_DIR`,
`WAYLAND_DISPLAY`, and `GDK_BACKEND=wayland`. Missing or ambiguous displays
fail closed; compositor permissions are unchanged. Execution/status polling is
bounded by `AUTO_TEST_TIMEOUT_SECONDS` (default 1800); unexpected agent loss
or a nonzero runner exit fails without reboot, retaining available diagnostics.

Before reboot the host requires `runner-install-exited-0`, `runner-logs-copied-0`,
a successful Installer summary and matching log/manifest. Copy failures fail the
E2E. QGA acknowledges the reboot shell's PID before the host returns to serial
monitoring; a short guest delay lets that acknowledgement arrive before
`systemctl reboot` disconnects the agent. Serial boot monitoring has its own
`AUTO_TEST_TIMEOUT_SECONDS` bound. Focused tests require no VM:
`python3 test/scripts/qemu_spice_test.py` and
`python3 test/scripts/qga_client_test.py` (also covered by the stable gate).

The install harness builds the current Flutter Linux release binary and exposes
the current bundle and sanitized profile through a 9p host share. The live guest
runs that Installer against a disposable VM disk, reboots, and the harness
observes the existing installed-target smoke marker. Serial logs, guest runner
state, Installer session/failure artifacts, and boot markers remain available.
This mechanism does not require the external ISO to contain the same Installer
build. The external Compose `installer-test-iso` integration image is available;
full installation, technical validation, reboot, and smoke-marker acceptance
are still in progress.

RPM packaging is independent: `scripts/01-build-rpm.sh` writes the source
tarball, RPM, checksum, manifest, and latest RPM pointers, then exits. It performs
no ISO action. `scripts/refresh-local-paths.sh` repairs local RPM pointers only.

Storage, bootloader, RPM, and QEMU changes should include the relevant artifact
or log evidence in the pull request. The existing RPM workflow publishes RPM
artifacts for review when it runs in GitHub Actions.

## Contributing

Pull requests should stay focused and describe the user-visible behavior,
storage or boot risk, and verification performed. Changes that affect disk
writes, boot configuration, package trust, release artifacts, or CI should
include tests or an explicit explanation of the remaining verification gap.

Do not commit local planning notes, historical reports, generated build output,
debug captures, VM disks, ISO files, RPM files, or workspace-specific editor
state. Keep active architecture documentation in this README. The repository
should remain usable as a clean source tree for review, CI, and release automation.
