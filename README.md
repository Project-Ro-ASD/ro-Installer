<div align="center">
  <img src="assets/branding/roasd-logo.png" width="88" alt="Ro-ASD Logo">
  <h1>Ro-Installer</h1>
  <p><b>Official graphical installer for Ro-ASD</b></p>

  [![Flutter](https://img.shields.io/badge/Flutter-02569B?style=flat-square&logo=flutter&logoColor=white)](https://flutter.dev)
  [![Platform](https://img.shields.io/badge/Platform-Linux-yellow?style=flat-square&logo=linux)](#)
  [![License](https://img.shields.io/badge/License-MIT-blue.svg?style=flat-square)](LICENSE)
</div>

Release line: `v3.0.0`

For Turkish notes, see the section below.

## Overview

Ro-Installer is the official Linux desktop installer for the Ro-ASD operating system.
It provides a Flutter-based interface on top of the Fedora installation toolchain and
focuses on a clean guided flow, direct hardware configuration, and clear runtime feedback.

Core capabilities:

- guided and advanced installation flows
- automatic and manual partitioning
- BTRFS-focused layout with `ext4`, `xfs`, `fat32`, and swap support
- locale, timezone, keyboard, and post-install system configuration
- multilingual installer UI with RTL support
- live installation progress, diagnostics, and validation

## Architecture

The project is split into two main layers:

1. The Flutter UI layer for screens, flow control, translations, and state.
2. The Linux execution layer for disk, network, filesystem, chroot, and bootloader operations.

The installer talks directly to native tools such as:

- `lsblk`
- `sgdisk`
- `mkfs.*`
- `nmcli`
- `mount`
- `rsync`
- `chroot`
- `grub2`

## Build

Requirements:

- Flutter SDK for Linux
- a Linux environment with desktop Flutter support enabled

Development build:

```bash
git clone https://github.com/Project-Ro-ASD/ro-Installer.git
cd ro-Installer
flutter pub get
flutter run -d linux
```

Release build:

```bash
flutter build linux --release
```

## Runtime Notes

Ro-Installer performs privileged installation operations. In production it should
be started with root privileges or through the provided Polkit flow.

Important runtime areas:

- target disk detection and validation
- network and Wi-Fi scanning
- partitioning and formatting
- target system locale, keyboard, and timezone configuration
- post-install validation and diagnostic export

## Repository Layout

- `lib/`: Flutter application source
- `assets/`: images, branding, and translation catalogs
- `linux/`: Linux desktop runner, launcher, and policy files
- `test/`: automated tests
- `tool/`: translation and maintenance utilities
- `.copr/` and `ro-installer.spec`: Fedora COPR packaging files

## Turkish Summary

Ro-Installer, Ro-ASD için geliştirilen resmi grafiksel kurulum uygulamasıdır.
Flutter tabanlı arayüz ile Fedora kurulum araç zincirini birleştirir. Disk
bölümleme, dil, klavye, saat dilimi, kullanıcı hesabı, bootloader ve kurulum
sonrası doğrulama akışlarını tek bir masaüstü deneyiminde toplar.
