import 'dart:convert';
import 'package:test/test.dart';
import 'package:ro_installer/services/fake_command_runner.dart';
import 'package:ro_installer/services/install_preflight.dart';
import 'package:ro_installer/services/install_stages/stage_context.dart';
import 'package:ro_installer/services/mount_session.dart';

import '../support/prepared_source.dart';

StageContext ctx(FakeCommandRunner f) => StageContext(
  state: {
    'selectedDisk': '/dev/fixture',
    'partitionMethod': 'full',
    'fileSystem': 'btrfs',
  },
  commandRunner: f,
  mountSession: SimulatedMountSession(f),
  log: (_) {},
  onProgress: (_, _) {},
  runCmd:
      (
        cmd,
        args,
        log, {
        bool isMock = false,
        List<int> allowedExitCodes = const [0],
      }) async => throw StateError('Preflight must never run mutations'),
);
void noMutations(FakeCommandRunner f) => expect(
  f.commandLog.where(
    (c) =>
        const [
          'wipefs',
          'mount',
          'umount',
          'sgdisk',
          'parted',
          'btrfs',
          'swapoff',
          'swapon',
        ].contains(c.command) ||
        c.command.startsWith('mkfs.'),
  ),
  isEmpty,
);
void main() {
  test(
    'existing Ro-ASD metadata and prepared payload pass read-only preflight',
    () async {
      final f = healthy();
      expect(await const InstallPreflight().check(ctx(f)), isTrue);
      noMutations(f);
    },
  );
  for (final tool in [
    'rsync',
    'findmnt',
    'mount',
    'umount',
    'mkfs.fat',
    'mkfs.btrfs',
    'dracut',
    'kernel-install',
    'depmod',
    'efibootmgr',
  ]) {
    test('missing real runtime $tool rejects without mutation', () async {
      final f = healthy()
        ..addResponse('sh', [
          '-c',
          'command -v $tool >/dev/null 2>&1',
        ], exitCode: 1);
      expect(await const InstallPreflight().check(ctx(f)), isFalse);
      noMutations(f);
    });
  }
  for (final path in [
    '/usr/lib/os-release',
    '/usr/lib/systemd/systemd',
    '/boot/efi/EFI/fedora/shimx64.efi',
    '/boot/efi/EFI/fedora/grubx64.efi',
  ]) {
    test('missing source $path rejects before write', () async {
      final f = healthy()..addResponse('test', ['-s', path], exitCode: 1);
      expect(await const InstallPreflight().check(ctx(f)), isFalse);
      noMutations(f);
    });
  }
  for (final error in [
    'malformed',
    'generic-fedora',
    'wrong-release',
    'wrong-architecture',
  ]) {
    test('source compatibility fails closed: $error', () async {
      final f =
          healthy(); // Replace queued response by a fresh runner for deterministic malformed metadata.
      final bad = error == 'malformed'
          ? 'invalid-secret'
          : jsonEncode({
              ...releaseMetadata,
              if (error == 'generic-fedora')
                'product': {'name': 'Fedora', 'release': 44},
              if (error == 'wrong-release')
                'base': {'distribution': 'Fedora Linux', 'release': 45},
              if (error == 'wrong-architecture')
                'primary_architecture': 'aarch64',
            });
      f.reset();
      f.addResponse('findmnt', [
        '--json',
        '--list',
        '--output',
        'TARGET,FSTYPE',
      ], stdout: '{"filesystems":[{"target":"/","fstype":"overlay"}]}');
      f.addResponse('cat', ['/usr/lib/ro-asd/release.json'], stdout: bad);
      expect(await const InstallPreflight().check(ctx(f)), isFalse);
      noMutations(f);
    });
  }
  test(
    'missing discovery payload fails without preparing kernels in Live',
    () async {
      final f = healthy();
      f.reset();
      f.addResponse('findmnt', [
        '--json',
        '--list',
        '--output',
        'TARGET,FSTYPE',
      ], stdout: '{"filesystems":[{"target":"/","fstype":"overlay"}]}');
      f.addResponse('cat', [
        '/usr/lib/ro-asd/release.json',
      ], stdout: jsonEncode(releaseMetadata));
      f.addResponse('blockdev', [
        '--getsize64',
        '/dev/fixture',
      ], stdout: '85899345920');
      f.addResponse('sh', kernelQuery, exitCode: 1);
      expect(await const InstallPreflight().check(ctx(f)), isFalse);
      noMutations(f);
    },
  );
  test('missing both GPT tools fails read-only', () async {
    final f = healthy()
      ..addResponse('sh', [
        '-c',
        'command -v sgdisk >/dev/null 2>&1',
      ], exitCode: 1)
      ..addResponse('sh', [
        '-c',
        'command -v parted >/dev/null 2>&1',
      ], exitCode: 1);
    expect(await const InstallPreflight().check(ctx(f)), isFalse);
    noMutations(f);
  });
  test('GPT fallback retains existing parted compatibility', () async {
    final f = healthy()
      ..addResponse('sh', [
        '-c',
        'command -v sgdisk >/dev/null 2>&1',
      ], exitCode: 1);
    expect(await const InstallPreflight().check(ctx(f)), isTrue);
    noMutations(f);
  });
}
