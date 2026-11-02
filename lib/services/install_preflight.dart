import '../models/prepared_root_capacity.dart';
import 'dart:convert';
import 'command_runner.dart';
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
  // Names are fixed argv entries; the shell only checks them, never executes them.
  static const toolCheckScript =
      r'for tool in "$@"; do command -v "$tool" >/dev/null 2>&1 || exit 1; done';
  static List<String> get toolCheckArguments => [
    '-c',
    toolCheckScript,
    'ro-installer-preflight',
    ...tools,
  ];
  Future<bool> check(StageContext ctx) async {
    if (ctx.isMock) {
      return true; // Explicit simulation, never selected by GUI input.
    }
    try {
      await ctx.mountSession!.assertEmpty();
      final disk = ctx.state['selectedDisk'] as String;
      final method = ctx.state['partitionMethod'];
      final available = await _read(
        ctx,
        'preflight.tools',
        'sh',
        toolCheckArguments,
      );
      if (!available.started || available.exitCode != 0) return false;
      final gpt = await _read(ctx, 'preflight.gpt.sgdisk', 'sh', [
        '-c',
        'command -v sgdisk >/dev/null 2>&1',
      ]);
      if (!gpt.started || gpt.exitCode != 0) {
        final fallback = await _read(ctx, 'preflight.gpt.parted', 'sh', [
          '-c',
          'command -v parted >/dev/null 2>&1',
        ]);
        if (!fallback.started || fallback.exitCode != 0) return false;
      }
      final sourceExcludes =
          await (ctx.observation?.span(
                'preflight.source',
                () => const FileCopyStage().inspectSource(ctx),
                success: (value) => value != null,
              ) ??
              const FileCopyStage().inspectSource(ctx));
      if (sourceExcludes == null) return false;
      for (final path in FileCopyStage.requiredFiles) {
        for (final flag in ['-f', '-s', '-r']) {
          final index = FileCopyStage.requiredFiles.indexOf(path);
          final operation = const [
            'preflight.file.os-release',
            'preflight.file.systemd',
            'preflight.file.shim',
            'preflight.file.grub',
          ][index];
          final result = await _read(ctx, operation, 'test', [flag, path]);
          if (!result.started || result.exitCode != 0) return false;
        }
      }
      final release = await _read(ctx, 'preflight.metadata', 'cat', [
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
      final capacity = await _read(ctx, 'preflight.capacity', 'blockdev', [
        '--getsize64',
        disk,
      ]);
      final diskBytes = int.tryParse(capacity.stdout.trim());
      if (!capacity.started ||
          capacity.exitCode != 0 ||
          diskBytes == null ||
          diskBytes < StandardStorageLayout.minimumDiskBytes) {
        return false;
      }
      final rootBytes = _rootCapacity(ctx, diskBytes);
      if (rootBytes == null) return false;
      final btrfs = await _read(ctx, 'preflight.btrfs', 'sh', [
        '-c',
        'grep -qw btrfs /proc/filesystems || modprobe -n -q btrfs',
      ]);
      if (!btrfs.started || btrfs.exitCode != 0) return false;
      final kernels = await _read(ctx, 'preflight.kernels', 'sh', [
        '-c',
        '$preparedKernelDiscoveryScript\ndiscover_prepared_kernels',
      ]);
      if (!kernels.started ||
          kernels.exitCode != 0 ||
          kernels.stdout.trim().isEmpty) {
        return false;
      }
      final inventory = await _read(
        ctx,
        'preflight.source-size',
        'rsync',
        FileCopyStage.mainCopyArguments(sourceExcludes, dryRun: true),
        timeout: const Duration(seconds: 60),
      );
      if (!inventory.started || inventory.exitCode != 0) return false;
      final budget = PreparedRootCapacity.fromRsyncStats(inventory.stdout);
      if (budget.requiredRootBytes > rootBytes ||
          ctx.state['selectedDisk'] != disk ||
          ctx.state['partitionMethod'] != method ||
          _rootCapacity(ctx, diskBytes) != rootBytes) {
        return false;
      }
      return true;
    } catch (_) {
      return false; // No raw source metadata, command stderr or exception in UI errors.
    }
  }

  int? _rootCapacity(StageContext ctx, int diskBytes) {
    if (!ctx.approvedStateMatches ||
        (ctx.state['fileSystem'] ?? 'btrfs') != 'btrfs') {
      return null;
    }
    switch (ctx.state['partitionMethod']) {
      case 'full':
        return diskBytes - StandardStorageLayout.espBytes - 2 * 1048576;
      case 'free_space':
        final plan = ctx.approvedFreeSpacePlan?.plan;
        if (plan == null) return null;
        final bytes =
            (plan.rootEnd - plan.rootStart + 1) *
            plan.snapshot.logicalSectorBytes;
        return bytes <= diskBytes ? bytes : null;
      case 'manual':
        final plan = ctx.approvedManualPlan?.plan;
        if (plan == null) return null;
        final bytes =
            (plan.root.endSector - plan.root.startSector + 1) *
            plan.snapshot.logicalSectorBytes;
        return bytes <= diskBytes ? bytes : null;
      default:
        return null;
    }
  }

  Future<CommandResult> _read(
    StageContext ctx,
    String operation,
    String command,
    List<String> args, {
    Duration? timeout,
  }) {
    Future<CommandResult> action() =>
        ctx.commandRunner.run(command, args, timeout: timeout);
    return ctx.observation?.span(
          operation,
          action,
          success: (r) => r.started && r.exitCode == 0,
        ) ??
        action();
  }
}
