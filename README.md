<div align="center">
  <img src="https://upload.wikimedia.org/wikipedia/commons/thumb/1/17/Penguin_icon.svg/200px-Penguin_icon.svg.png" width="72" alt="Ro-Installer">
  <h1>Ro-Installer</h1>
  <p><b>Official graphical installer for Ro-ASD</b></p>
</div>

Ro-Installer is a Linux desktop installer written in Flutter and Dart for the Ro-ASD operating system. It provides a graphical workflow on top of native Linux tools such as `sgdisk`, `mkfs.*`, `rsync`, `chroot`, `dracut`, `kernel-install`, `efibootmgr`, and Fedora's UEFI boot chain.

This repository is the cleaned GitHub-ready project tree. Local experiment notes, ad-hoc markdown files, VM output logs, ISO images, and build artifacts are intentionally excluded.

For RPM/COPR packaging and webhook-based builds, see [COPR.md](COPR.md).

## Highlights

- Flutter-based Linux desktop UI
- Full disk, alongside, and manual partitioning flows
- `btrfs`, `ext4`, and `xfs` root filesystem support
- Fedora-compatible UEFI boot flow with `shimx64.efi`, GRUB, and `efibootmgr`
- Installation logging and post-install validation
- Unit tests for install stages and helper services
- QEMU test scripts for both manual and automated VM validation

## Repository Layout

```text
lib/                  Flutter UI and installer logic
lib/services/         System services and install orchestration
lib/services/install_stages/
                      Stage-based installation pipeline
linux/                Linux runner, policy files, packaging references, VM helpers
test/                 Unit tests and test fixtures
assets/               UI assets
ro-installer.spec     RPM spec used by COPR and local SRPM generation
.copr/Makefile        COPR make-srpm entrypoint
test_qemu_vm.sh       QEMU launcher for manual/auto VM tests
test_qemu_guest_runner.sh
                      Guest-side helper for auto VM runs
```

## Requirements

- Linux host
- Flutter SDK with Linux desktop support
- `clang`, `cmake`, `ninja`, `pkg-config`
- QEMU/KVM for VM-based testing
- OVMF / `edk2-ovmf` for UEFI tests

For real installation runs inside Fedora-based live environments, these tools are expected on the target side:

- `util-linux`
- `e2fsprogs`
- `btrfs-progs`
- `xfsprogs`
- `dosfstools`
- `gdisk`
- `parted`
- `rsync`
- `dracut`
- `efibootmgr`
- `grub2-common`
- `grub2-efi-x64`
- `shim-x64`

## Build

```bash
git clone https://github.com/Project-Ro-ASD/ro-Installer.git
cd ro-Installer

flutter pub get
flutter build linux --release
```

## Run

For desktop development:

```bash
flutter run -d linux
```

For the release bundle:

```bash
sudo -E build/linux/x64/release/bundle/ro_installer
```

Root privileges are required because the installer writes partition tables, formats filesystems, mounts target roots, enters `chroot`, and installs the boot chain.

## VM Testing

Manual QEMU session:

```bash
RO_INSTALLER_TEST_ISO=/path/to/Fedora-Live.iso ./test_qemu_vm.sh manual
```

Automated QEMU session:

```bash
RO_INSTALLER_TEST_ISO=/path/to/Fedora-Live.iso ./test_qemu_vm.sh auto
```

The automation path uses:

- `linux/qmp_send_keys.py`
- `test_qemu_vm.sh`
- `test_qemu_guest_runner.sh`

## Architecture Notes

The installer is organized as a stage pipeline:

1. Disk preparation
2. Partitioning
3. Formatting
4. Mounting
5. File copy
6. Chroot configuration
7. Bootloader setup
8. Post-install validation
9. Cleanup

The bootloader stage is Fedora UEFI oriented. On Secure Boot capable systems it uses the signed `shim` and GRUB binaries already present in the target system, writes the ESP-side GRUB stub, and creates the firmware entry with `efibootmgr`.

## Turkish Summary

Ro-Installer, Ro-ASD icin gelistirilmis Flutter tabanli resmi Linux kurulum aracidir. Bu depo GitHub icin temizlenmis surumdur; yerel notlar, gecici markdown dosyalari, ISO dosyalari, build ciktilari ve VM loglari burada tutulmaz.

Kisa baslangic:

```bash
flutter pub get
flutter build linux --release
sudo -E build/linux/x64/release/bundle/ro_installer
```

QEMU ile manuel test:

```bash
RO_INSTALLER_TEST_ISO=/path/to/Fedora-Live.iso ./test_qemu_vm.sh manual
```
