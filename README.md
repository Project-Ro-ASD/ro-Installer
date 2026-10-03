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
and no dedicated disk swap partition. The planned rollback-aware Btrfs layout is:

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

The architecture and storage contracts above define the direction of the
project; they are not a claim that the runtime migration is complete. The
current code still includes legacy install flows, target configuration,
repository/kernel policy, and ISO remix/audit tooling. Those responsibilities
will be realigned in later focused changes. This documentation and stable-gate
realignment does not change installer UI, stages, storage, or bootloader behavior.

Destructive disk operations remain guarded by storage planning and validation.
The current stable path rejects LUKS, LVM, RAID, multipath, and nested storage
topologies before destructive disk writes.

## Technology and Repository Layout

- Flutter and Dart for the Linux desktop application.
- `lib/`: Flutter UI, installer state, services, storage planning, and stages.
- `assets/`: product images, branding, and localization data.
- `linux/`: Linux desktop integration, launcher, policy, and helper scripts.
- `scripts/`: RPM packaging, stable-gate automation, QEMU helpers, and retained
  legacy ISO tooling.
- `test/`: unit, service, stage, profile, storage, log, and script contract tests.
- `tool/`: development checks, including the i18n audit.
- `ro-installer.spec`: RPM packaging.
- `.github/workflows/`: CI automation. The existing Fedora 43 RPM workflow is
  retained; that exact Fedora release is not an architectural requirement.

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
kernel policy, or a custom-kernel-only release policy. Legacy scripts remain
syntax-checked while present; passing this gate does not prove that the runtime
has completed the architecture migration.

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
