# Ro-Installer

Ro-Installer is the system installer for Ro-ASD, a Fedora KDE based Linux
distribution. The project focuses on turning a live Ro-ASD environment into a
bootable installed system with a clear graphical workflow, profile-driven
automation, and explicit validation around the risky parts of installation.

The installer is intentionally more than a UI shell around a few commands. It
contains the staged install engine, disk and storage validation, post-install
checks, RPM packaging, ISO remix tooling, QEMU helpers, and GitHub automation
used to produce Fedora 43 release RPMs.

## Goals

- Provide a Ro-ASD specific graphical installer with a predictable install
  contract.
- Keep destructive disk operations guarded by explicit storage plans and
  validation before writes happen.
- Support automated profile-based installs for VM and release testing.
- Produce release evidence through manifests, logs, ISO audits, and QEMU boot
  checks instead of relying on manual inspection.
- Keep the public repository focused on source code, packaging, CI, tests, and
  product assets.

## Current Scope

The stable target is UEFI/GPT with a Btrfs root filesystem. Full disk,
alongside, preallocated free-space, and manual partition flows are implemented
under the same Btrfs target contract.

The stable path rejects LUKS, LVM, RAID, multipath, and nested storage
topologies before destructive disk writes. LUKS root support is deliberately
held back until its own implementation and test matrix are ready.

## Technology

- Flutter and Dart for the Linux desktop application.
- Provider-based UI state and staged install orchestration.
- Native Linux tools such as `sgdisk`, `mkfs.btrfs`, `rsync`, `chroot`,
  `dracut`, `grub2`, `efibootmgr`, `nmcli`, and `journalctl`.
- RPM packaging through `ro-installer.spec`.
- Fedora 43 GitHub Actions builds for release RPM artifacts.
- ISO remix and audit scripts for Ro-ASD live images.
- QEMU/OVMF helpers for automated boot and install verification.

## Repository Layout

- `lib/`: Flutter UI, installer state, services, storage planning, and install
  stages.
- `assets/`: product images, branding, and localization data.
- `linux/`: Linux desktop integration, launcher, policy, and helper scripts.
- `scripts/`: RPM, ISO, audit, QEMU, and stable-gate automation.
- `test/`: unit, service, stage, profile, storage, log, and script contract
  tests.
- `.github/workflows/`: CI automation, including Fedora 43 RPM production.

## Testing

Before a pull request, run the code and contract checks that match the changed
area. For broad changes, use the full local gate:

```bash
flutter analyze
flutter test
dart run tool/i18n_audit.dart
bash scripts/check-stable.sh
```

Storage, bootloader, RPM, ISO, and QEMU changes should include the relevant
artifact or log evidence in the pull request. The Fedora 43 RPM workflow also
publishes RPM artifacts for review when it runs in GitHub Actions.

## Contributing

Pull requests should stay focused and describe the user-visible behavior,
storage or boot risk, and verification performed. Changes that affect disk
writes, boot configuration, package trust, release artifacts, or CI should
include tests or an explicit explanation of the remaining verification gap.

Do not commit local planning notes, historical reports, generated build output,
debug captures, VM disks, ISO files, RPM files, or workspace-specific editor
state. The repository should remain usable as a clean source tree for review,
CI, and release automation.
