import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ro_installer/services/command_runner.dart';
import 'package:ro_installer/services/fake_command_runner.dart';
import 'package:ro_installer/services/install_service.dart';
import 'package:ro_installer/services/install_stages/file_copy_stage.dart';
import 'package:ro_installer/services/install_stages/stage_context.dart';

const scanArgs = ['--json', '--list', '--output', 'TARGET,FSTYPE'];
const requiredFiles = [
  '/usr/lib/os-release',
  '/usr/lib/systemd/systemd',
  '/boot/efi/EFI/fedora/shimx64.efi',
  '/boot/efi/EFI/fedora/grubx64.efi',
];

String mounts(List<List<String>> rows) => jsonEncode({
  'filesystems': [
    for (final row in rows) {'target': row[0], 'fstype': row[1]},
  ],
});

FakeCommandRunner healthyRunner({List<List<String>> extra = const []}) {
  final fake = FakeCommandRunner();
  fake.addResponse(
    'findmnt',
    scanArgs,
    stdout: mounts([
      ['/', 'overlay'],
      ['/run', 'tmpfs'],
      ...extra,
    ]),
  );
  return fake;
}

StageContext context(CommandRunner runner, {List<String>? logs}) =>
    StageContext(
      state: {},
      log: (message) => logs?.add(message),
      onProgress: (_, _) {},
      commandRunner: runner,
      runCmd: InstallService(commandRunner: runner).runCmd,
    );

class ThrowingRunner extends FakeCommandRunner {
  ThrowingRunner(this.commandToThrow, {this.secondaryOnly = false});
  final String commandToThrow;
  final bool secondaryOnly;
  @override
  Future<CommandResult> run(
    String command,
    List<String> args, {
    bool isMock = false,
    CommandLogCallback? onLog,
    Duration? timeout,
    String? stdinText,
  }) {
    if (command == commandToThrow &&
        (!secondaryOnly || args.contains('/boot/efi/'))) {
      throw const FileSystemException('fixture-secret-do-not-export');
    }
    if (command == 'findmnt') {
      addResponse(
        'findmnt',
        scanArgs,
        stdout: mounts([
          ['/', 'overlay'],
        ]),
      );
    }
    return super.run(
      command,
      args,
      isMock: isMock,
      onLog: onLog,
      timeout: timeout,
      stdinText: stdinText,
    );
  }
}

void main() {
  const stage = FileCopyStage();
  test(
    'exit 0 preserves existing main flags, exclusions and EFI copy',
    () async {
      final fake = healthyRunner();
      final result = await stage.execute(context(fake));
      expect(result.success, isTrue);
      final copies = fake.commandLog
          .where((c) => c.command == 'rsync')
          .toList();
      expect(copies, hasLength(2));
      final args = copies.first.args;
      for (final flag in [
        '-aAX',
        '--numeric-ids',
        '--info=progress2,stats2',
        '--human-readable',
        '--exclude=/etc/kernel/cmdline',
        '--exclude=/etc/machine-id',
        '--exclude=/var/lib/dbus/machine-id',
        '--exclude=/etc/hostname',
        '--exclude=/var/cache/dnf/*',
        '--exclude=/var/tmp/*',
        '--exclude=/home/*/.cache/*',
        '--exclude=/home/liveuser',
        '--exclude=/boot/loader/entries/*',
        '--exclude=/boot/grub2/grubenv',
        '--exclude=/boot/efi',
        '--exclude=/boot/efi/*',
        '--exclude=/mnt/*',
      ]) {
        expect(args, contains(flag));
      }
      expect(args, isNot(contains('--one-file-system')));
      expect(copies.last.args, [
        '-aA',
        '--numeric-ids',
        '--no-xattrs',
        '/boot/efi/',
        '/mnt/boot/efi/',
      ]);
    },
  );

  for (final code in [23, 1, 11, 12, 24, 30]) {
    test('main rsync exit $code fails before secondary writes', () async {
      final fake = healthyRunner()
        ..addResponseForCommand(
          'rsync',
          exitCode: code,
          stderr: 'fixture-secret-do-not-export',
        );
      final logs = <String>[];
      final result = await stage.execute(context(fake, logs: logs));
      expect(result.success, isFalse);
      expect(fake.commandLog.where((c) => c.command == 'rsync'), hasLength(1));
      expect(fake.wasCommandCalled('mkdir'), isFalse);
      expect(
        '${result.message}\n${logs.join('\n')}',
        isNot(contains('fixture-secret')),
      );
    });
  }
  test(
    'main rsync not started is failure even with synthetic exit 0',
    () async {
      final fake = healthyRunner()
        ..addResponseForCommand('rsync', started: false);
      expect((await stage.execute(context(fake))).success, isFalse);
    },
  );
  for (final error in [
    'Permission denied',
    'failed to set permissions',
    'ACL not supported',
    'setxattr failed',
    'No space left on device',
  ]) {
    test('main rsync rejects partial metadata/data transfer: $error', () async {
      final fake = healthyRunner()
        ..addResponseForCommand('rsync', exitCode: 23, stderr: error);
      expect((await stage.execute(context(fake))).success, isFalse);
      expect(fake.wasCommandCalled('mkdir'), isFalse);
    });
  }
  for (final command in ['findmnt', 'rsync', 'mkdir']) {
    test('$command launch exception is a safe stage failure', () async {
      final logs = <String>[];
      final result = await stage.execute(
        context(ThrowingRunner(command), logs: logs),
      );
      expect(result.success, isFalse);
      expect(
        '${result.message}\n${logs.join('\n')}',
        isNot(contains('fixture-secret')),
      );
    });
  }
  test(
    'EFI rsync launch exception identifies only fixed EFI operation',
    () async {
      final result = await stage.execute(
        context(ThrowingRunner('rsync', secondaryOnly: true)),
      );
      expect(result.success, isFalse);
      expect(result.message, contains('EFI dosya aktarımı'));
      expect(result.message, isNot(contains('fixture-secret')));
    },
  );
  for (final started in [true, false]) {
    test('EFI mkdir failure started=$started stops before EFI rsync', () async {
      final fake = healthyRunner()
        ..addResponse(
          'mkdir',
          ['-p', '/mnt/boot/efi'],
          exitCode: 1,
          started: started,
        );
      final result = await stage.execute(context(fake));
      expect(result.success, isFalse);
      expect(result.message, contains('EFI hedef dizini'));
      expect(fake.commandLog.where((c) => c.command == 'rsync'), hasLength(1));
    });
  }
  for (final failure in [(23, true), (11, true), (0, false)]) {
    test(
      'EFI rsync rejects exit/started $failure including full target',
      () async {
        final fake = healthyRunner()
          ..addResponseForCommand('rsync')
          ..addResponseForCommand(
            'rsync',
            exitCode: failure.$1,
            started: failure.$2,
          );
        final result = await stage.execute(context(fake));
        expect(result.success, isFalse);
        expect(result.message, contains('EFI dosya aktarımı'));
      },
    );
  }
  for (final path in requiredFiles) {
    test('missing required source $path fails before main copy', () async {
      final fake = healthyRunner()
        ..addResponse('test', ['-s', path], exitCode: 1);
      final result = await stage.execute(context(fake));
      expect(result.success, isFalse);
      expect(result.message, contains(path));
      expect(fake.wasCommandCalled('rsync'), isFalse);
    });
    test('missing required destination $path cannot report success', () async {
      final fake = healthyRunner()
        ..addResponse('test', ['-s', '/mnt$path'], exitCode: 1);
      final result = await stage.execute(context(fake));
      expect(result.success, isFalse);
      expect(result.message, contains(path));
    });
  }
  for (final failure in [(1, true), (0, false)]) {
    test('findmnt failure $failure stops before any write', () async {
      final fake = FakeCommandRunner()
        ..addResponse(
          'findmnt',
          scanArgs,
          exitCode: failure.$1,
          started: failure.$2,
        );
      expect((await stage.execute(context(fake))).success, isFalse);
      expect(fake.commandNames, ['findmnt']);
    });
  }
  for (final invalid in [
    '',
    'garbage fixture-secret',
    '{}',
    '{"filesystems":[]}',
    '{"filesystems":{}}',
    mounts([
      ['/run', 'tmpfs'],
    ]),
    mounts([
      ['/', 'mystery'],
    ]),
    mounts([
      ['/', 'overlay'],
      ['/', 'overlay'],
    ]),
    mounts([
      ['/', 'overlay'],
      ['/data/../usr', 'ext4'],
    ]),
    mounts([
      ['/', 'overlay'],
      ['/data//other', 'ext4'],
    ]),
    mounts([
      ['/', 'overlay'],
      ['/data\nsecret', 'ext4'],
    ]),
    '{"filesystems":[{"target":"/","fstype":"overlay","children":[]}]}',
  ]) {
    test(
      'invalid/ambiguous mount report fails closed ${invalid.hashCode}',
      () async {
        final fake = FakeCommandRunner()
          ..addResponse('findmnt', scanArgs, stdout: invalid);
        final result = await stage.execute(context(fake));
        expect(result.success, isFalse);
        expect(fake.commandNames, ['findmnt']);
        expect(result.message, isNot(contains('fixture-secret')));
      },
    );
  }
  for (final point in [
    '/boot',
    '/boot/efi',
    '/usr',
    '/etc',
    '/var/lib/prepared',
    '/home',
    '/opt',
  ]) {
    test(
      'unproven system mount $point is not copied or silently omitted',
      () async {
        final fake = healthyRunner(
          extra: [
            [point, 'ext4'],
          ],
        );
        expect((await stage.execute(context(fake))).success, isFalse);
        expect(fake.wasCommandCalled('rsync'), isFalse);
      },
    );
  }
  test(
    'foreign FAT NTFS ext4 and virtual mounts are exclusions, never extra sources',
    () async {
      final fake = healthyRunner(
        extra: [
          ['/data/fat', 'vfat'],
          ['/data/windows', 'ntfs3'],
          ['/srv/foreign', 'ext4'],
          ['/virtual', 'rpc_pipefs'],
          ['/mnt', 'btrfs'],
          ['/mnt/boot/efi', 'vfat'],
          ['/mnt-extra', 'ext4'],
          ['/backup [a]*? space', 'exfat'],
        ],
      );
      expect((await stage.execute(context(fake))).success, isTrue);
      final copies = fake.commandLog
          .where((c) => c.command == 'rsync')
          .toList();
      expect(copies, hasLength(2));
      for (final path in [
        '/data/fat',
        '/data/windows',
        '/srv/foreign',
        '/virtual',
        '/mnt-extra',
      ]) {
        expect(copies.first.args, contains('--exclude=$path'));
      }
      expect(copies.first.args, contains(r'--exclude=/backup \[a\]\*\? space'));
    },
  );
  test(
    'recorded Fedora KIWI overlay/erofs topology remains supported',
    () async {
      final fixture =
          jsonDecode(
                File(
                  'test/fixtures/helper_fedora44_kiwi_live.json',
                ).readAsStringSync(),
              )
              as Map;
      final rows = [
        for (final line in fixture['mountinfo'] as List)
          (line as String).split(' '),
      ];
      final fake = FakeCommandRunner()
        ..addResponse(
          'findmnt',
          scanArgs,
          stdout: mounts([
            for (final row in rows) [row[4], row[row.indexOf('-') + 1]],
            ['/mnt', 'btrfs'],
            ['/mnt/home', 'btrfs'],
            ['/mnt/boot/efi', 'vfat'],
          ]),
        );
      expect((await stage.execute(context(fake))).success, isTrue);
      expect(
        fake.commandLog.firstWhere((c) => c.command == 'rsync').args,
        contains('--exclude=/run/rootfsbase'),
      );
    },
  );
  for (final phase in ['main', 'mkdir', 'efi']) {
    test(
      'orchestrator never enters stages 6-9 after $phase copy failure',
      () async {
        // Every command, including earlier disk stages, is fake. No host disk IO.
        final fake = FakeCommandRunner();
        if (phase == 'main') fake.addResponseForCommand('rsync', exitCode: 23);
        if (phase == 'mkdir') {
          // MountingStage creates the same EFI directory once before copying.
          fake.addResponse('mkdir', ['-p', '/mnt/boot/efi']);
          fake.addResponse('mkdir', ['-p', '/mnt/boot/efi'], exitCode: 1);
        }
        if (phase == 'efi') {
          fake.addResponseForCommand('rsync');
          fake.addResponseForCommand('rsync', exitCode: 23);
        }
        final stages = <int>[];
        final result = await InstallService(commandRunner: fake).runInstall(
          {
            'selectedDisk': '/dev/fixture-only',
            'partitionMethod': 'full',
            'fileSystem': 'btrfs',
          },
          (_, _) {},
          (_) {},
          isMock: true,
          onStage: stages.add,
        );
        expect(
          result,
          isFalse,
          reason: 'stages=$stages calls=${fake.commandLog}',
        );
        expect(stages, [1, 2, 3, 4, 5]);
        // Read-only diagnostics may still use chroot; stage callbacks prove
        // finalization/bootloader/validation/cleanup were never entered.
      },
    );
  }
}
