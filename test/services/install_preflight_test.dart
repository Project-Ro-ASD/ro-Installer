import 'dart:convert';
import 'dart:io';
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
  test(
    'one batch checks the complete fixed tool list without executing tools',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'ro-preflight-tools-',
      );
      try {
        for (final tool in InstallPreflight.tools) {
          final file = File('${directory.path}/$tool');
          file.writeAsStringSync(
            '#!/bin/sh\nprintf executed > "\$RO_TOOL_MARKER"\nexit 91\n',
          );
          final chmod = await Process.run('/usr/bin/chmod', ['755', file.path]);
          expect(chmod.exitCode, 0);
        }
        Future<ProcessResult> check() => Process.run(
          '/usr/bin/sh',
          InstallPreflight.toolCheckArguments,
          environment: {
            'PATH': directory.path,
            'RO_TOOL_MARKER': '${directory.path}/executed',
          },
          includeParentEnvironment: false,
        );
        expect((await check()).exitCode, 0);
        // `test` is a shell builtin, exactly as in the previous command-v check.
        for (final tool in InstallPreflight.tools.where(
          (name) => name != 'test',
        )) {
          final original = File('${directory.path}/$tool');
          final omitted = original.renameSync('${directory.path}/omitted');
          final result = await check();
          expect(result.exitCode, 1, reason: 'Missing $tool must fail closed');
          expect(result.stdout, isEmpty);
          expect(result.stderr, isEmpty);
          omitted.renameSync(original.path);
        }
        expect(File('${directory.path}/executed').existsSync(), false);
      } finally {
        directory.deleteSync(recursive: true);
      }
    },
  );
  test(
    'failed or missing batch refuses preflight before source checks or mutations',
    () async {
      for (final started in [true, false]) {
        final f = healthy()
          ..addResponse(
            'sh',
            InstallPreflight.toolCheckArguments,
            exitCode: 1,
            started: started,
          );
        expect(await const InstallPreflight().check(ctx(f)), false);
        noMutations(f);
        expect(f.wasCommandCalled('blockdev'), false);
      }
    },
  );
  test('healthy preflight launches one tool discovery shell', () async {
    final f = healthy();
    expect(await const InstallPreflight().check(ctx(f)), true);
    final batches = f.commandLog.where(
      (v) =>
          v.command == 'sh' &&
          v.args.length > 2 &&
          v.args[2] == 'ro-installer-preflight',
    );
    expect(batches, hasLength(1));
    expect(batches.single.args.skip(3), InstallPreflight.tools);
    for (final tool in InstallPreflight.tools) {
      expect(
        f.wasCalledWith('sh', ['-c', 'command -v $tool >/dev/null 2>&1']),
        false,
      );
    }
    noMutations(f);
  });
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
