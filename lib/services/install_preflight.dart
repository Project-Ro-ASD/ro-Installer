import 'dart:convert';
import '../models/standard_storage_layout.dart';
import 'install_stages/file_copy_stage.dart';
import 'install_stages/prepared_kernel_artifacts.dart';
import 'install_stages/stage_context.dart';

/// Read-only, before stage 1 and before the final device-identity handshake.
/// Uses existing Ro-ASD release metadata, not a new Compose marker.
class InstallPreflight {
  const InstallPreflight();
  static const tools = [
    'rsync',
    'findmnt',
    'mount',
    'umount',
    'lsblk',
    'blockdev',
    'wipefs',
    'partprobe',
    'udevadm',
    'mkfs.fat',
    'mkfs.btrfs',
    'btrfs',
    'chroot',
    'blkid',
    'sh',
    'bash',
    'test',
    'mkdir',
    'rm',
    'cp',
    'cat',
    'sed',
    'awk',
    'grep',
    'find',
    'sort',
    'tee',
    'chmod',
    'readlink',
    'dirname',
    'basename',
    'sync',
    'systemd-machine-id-setup',
    'dracut',
    'kernel-install',
    'depmod',
    'modprobe',
    'grub2-mkconfig',
    'efibootmgr',
  ];
  Future<bool> check(StageContext ctx) async {
    if (ctx.isMock) {
      return true; // Explicit simulation, never selected by GUI input.
    }
    try {
      await ctx.mountSession!.assertEmpty();
      for (final tool in tools) {
        final result = await ctx.commandRunner.run('sh', [
          '-c',
          'command -v $tool >/dev/null 2>&1',
        ]);
        if (!result.started || result.exitCode != 0) return false;
      }
      final gpt = await ctx.commandRunner.run('sh', [
        '-c',
        'command -v sgdisk >/dev/null 2>&1',
      ]);
      if (!gpt.started || gpt.exitCode != 0) {
        final fallback = await ctx.commandRunner.run('sh', [
          '-c',
          'command -v parted >/dev/null 2>&1',
        ]);
        if (!fallback.started || fallback.exitCode != 0) return false;
      }
      if (await const FileCopyStage().inspectSource(ctx) == null) return false;
      for (final path in FileCopyStage.requiredFiles) {
        for (final flag in ['-f', '-s', '-r']) {
          final result = await ctx.commandRunner.run('test', [flag, path]);
          if (!result.started || result.exitCode != 0) return false;
        }
      }
      final release = await ctx.commandRunner.run('cat', [
        '/usr/lib/ro-asd/release.json',
      ]);
      if (!release.started || release.exitCode != 0) return false;
      final data = jsonDecode(release.stdout);
      if (data is! Map ||
          data['schema_version'] != 'ro-asd-release-metadata-v1' ||
          data['product'] is! Map ||
          data['product']['name'] != 'Ro-ASD' ||
          data['product']['release'] != 44 ||
          data['base'] is! Map ||
          data['base']['distribution'] != 'Fedora Linux' ||
          data['base']['release'] != 44 ||
          data['primary_architecture'] != 'x86_64') {
        return false;
      }
      final capacity = await ctx.commandRunner.run('blockdev', [
        '--getsize64',
        ctx.state['selectedDisk'] as String,
      ]);
      if (!capacity.started ||
          capacity.exitCode != 0 ||
          (int.tryParse(capacity.stdout.trim()) ?? 0) <
              StandardStorageLayout.minimumDiskBytes) {
        return false;
      }
      final btrfs = await ctx.commandRunner.run('sh', [
        '-c',
        'grep -qw btrfs /proc/filesystems || modprobe -n -q btrfs',
      ]);
      if (!btrfs.started || btrfs.exitCode != 0) return false;
      final kernels = await ctx.commandRunner.run('sh', [
        '-c',
        '$preparedKernelDiscoveryScript\ndiscover_prepared_kernels',
      ]);
      if (!kernels.started ||
          kernels.exitCode != 0 ||
          kernels.stdout.trim().isEmpty) {
        return false;
      }
      return true;
    } catch (_) {
      return false; // No raw source metadata, command stderr or exception in UI errors.
    }
  }
}
