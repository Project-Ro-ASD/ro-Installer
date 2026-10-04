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
extraction benchmarking have been removed. Dedicated Compose installer-test
profile integration and complete QEMU E2E acceptance remain future work.

Destructive disk operations remain guarded by storage planning and validation.
The current stable path rejects LUKS, LVM, RAID, multipath, and nested storage
topologies before destructive disk writes.

## Technology and Repository Layout

- Flutter and Dart for the Linux desktop application.
- `lib/`: Flutter UI, installer state, services, storage planning, and stages.
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

The install harness builds the current Flutter Linux release binary and exposes
the current bundle and sanitized profile through a 9p host share. The live guest
runs that Installer against a disposable VM disk, reboots, and the harness
observes the existing installed-target smoke marker. Serial logs, guest runner
state, Installer session/failure artifacts, and boot markers remain available.
This mechanism does not require the external ISO to contain the same Installer
build. A dedicated Compose installer-test profile and complete E2E acceptance
are not implemented by this change.

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
