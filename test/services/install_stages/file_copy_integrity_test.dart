import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ro_installer/services/command_runner.dart';
import 'package:ro_installer/services/fake_command_runner.dart';
import 'package:ro_installer/services/install_service.dart';
import 'package:ro_installer/services/install_stages/file_copy_stage.dart';
import 'package:ro_installer/services/install_stages/stage_context.dart';

// No mounts, block-device IO, or actual /mnt access. Only topology is synthetic;
// production rsync arguments run against disposable source/destination trees.
class CopyFixture extends CommandRunner {
  final root = Directory.systemTemp.createTempSync('p0-02-rsync-');
  final delegate = RealCommandRunner();
  final calls = <RecordedCommand>[];
  final copyExits = <int>[];
  bool denyRead = false;
  bool removeEfi = false;
  bool removeRequired = false;
  String get source => '${root.path}/source';
  String get target => '${root.path}/target';
  String get script =>
      File('test/fixtures/rsync_integrity_fixture.py').absolute.path;

  Future<Map<String, dynamic>> python(String operation) async {
    final result = await Process.run('python3', [script, operation, root.path]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    return jsonDecode(result.stdout as String) as Map<String, dynamic>;
  }

  String mapped(String path) {
    expect(path.startsWith('/'), isTrue);
    expect(path.split('/'), isNot(contains('..')));
    return path == '/mnt' || path.startsWith('/mnt/')
        ? '$target${path.substring(4)}'
        : '$source$path';
  }

  @override
  Future<CommandResult> run(
    String command,
    List<String> args, {
    bool isMock = false,
    CommandLogCallback? onLog,
    Duration? timeout,
    String? stdinText,
  }) async {
    calls.add(RecordedCommand(command: command, args: args));
    expect(isMock, isFalse);
    if (command == 'findmnt') {
      expect(args, ['--json', '--list', '--output', 'TARGET,FSTYPE']);
      return CommandResult(
        command: command,
        args: args,
        exitCode: 0,
        started: true,
        stderr: '',
        stdout: jsonEncode({
          'filesystems': [
            {'target': '/', 'fstype': 'overlay'},
            {'target': '/run', 'fstype': 'tmpfs'},
            {'target': '/mnt', 'fstype': 'btrfs'},
            {'target': '/mnt/boot/efi', 'fstype': 'vfat'},
            for (final point in [
              'srv/foreign-ext',
              'data/foreign-fat',
              'data/foreign-ntfs',
              'backup [a]*? space',
            ])
              {
                'target': '/$point',
                'fstype': point.contains('ext') ? 'ext4' : 'vfat',
              },
          ],
        }),
      );
    }
    List<String> redirected;
    if (command == 'test') {
      expect(args, hasLength(2));
      expect(args.first, anyOf('-f', '-s'));
      redirected = [args.first, mapped(args.last)];
    } else if (command == 'mkdir') {
      expect(args, ['-p', '/mnt/boot/efi']);
      redirected = ['-p', mapped(args.last)];
    } else if (command == 'rsync') {
      final main = args[args.length - 2] == '/';
      expect(
        args.sublist(args.length - 2),
        main ? ['/', '/mnt/'] : ['/boot/efi/', '/mnt/boot/efi/'],
      );
      // Options cannot introduce another source, destination, shell or file list.
      for (final flag in args.take(args.length - 2)) {
        expect(
          flag.startsWith('--exclude=') ||
              const {
                '-aAX',
                '-aA',
                '--numeric-ids',
                '--info=progress2,stats2',
                '--human-readable',
                '--no-xattrs',
              }.contains(flag),
          isTrue,
          reason: flag,
        );
      }
      redirected = [
        ...args.take(args.length - 2),
        mapped(args[args.length - 2]),
        mapped(args.last),
      ];
      if (main && removeRequired) {
        File('$source/usr/lib/systemd/systemd').deleteSync();
      }
      if (!main && removeEfi) {
        Directory('$source/boot/efi').deleteSync(recursive: true);
      }
      if (main && denyRead) {
        final result = await delegate.run('python3', [
          script,
          'deny-read',
          root.path,
          jsonEncode(redirected),
        ]);
        copyExits.add(result.exitCode);
        return result;
      }
    } else {
      throw StateError('fixture refuses command: $command');
    }
    final result = await delegate.run(
      command,
      redirected,
      onLog: onLog,
      timeout: timeout,
    );
    if (command == 'rsync') copyExits.add(result.exitCode);
    return result;
  }

  Future<bool> copy() async => (await const FileCopyStage().execute(
    StageContext(
      state: {},
      commandRunner: this,
      log: (_) {},
      onProgress: (_, _) {},
      runCmd: InstallService(commandRunner: this).runCmd,
    ),
  )).success;
}

void main() {
  late CopyFixture fixture;
  setUp(() async {
    fixture = CopyFixture();
    addTearDown(() => fixture.root.deleteSync(recursive: true));
    await fixture.python(
      'prepare',
    ); // Missing tools/ACL/xattr support are FAIL, not SKIP.
  });
  test(
    'real rsync preserves file integrity and excludes foreign/Live trees',
    () async {
      expect(await fixture.copy(), isTrue);
      expect(fixture.copyExits, [0, 0]);
      final matrix = await fixture.python('verify');
      expect(matrix['hardlinks_preserved'], isFalse);
      stdout.writeln('P0-02 real integrity matrix: ${jsonEncode(matrix)}');
    },
  );
  for (final directory in [false, true]) {
    test(
      'required EFI source cannot be empty or a directory: directory=$directory',
      () async {
        final path = '${fixture.source}/boot/efi/EFI/fedora/shimx64.efi';
        File(path).deleteSync();
        if (directory) {
          Directory(path).createSync();
        } else {
          File(path).writeAsStringSync('');
        }
        expect(await fixture.copy(), isFalse);
        expect(fixture.copyExits, isEmpty);
      },
    );
  }
  test('real permission-denied rsync exit 23 fails the stage', () async {
    fixture.denyRead = true;
    expect(await fixture.copy(), isFalse);
    expect(fixture.copyExits, [23]);
    expect(fixture.calls.where((c) => c.command == 'mkdir'), isEmpty);
  });
  test(
    'real missing EFI source after preflight returns 23 and fails',
    () async {
      fixture.removeEfi = true;
      expect(await fixture.copy(), isFalse);
      expect(fixture.copyExits, [0, 23]);
    },
  );
  test(
    'mandatory root file lost before transfer fails even when rsync returns 0',
    () async {
      fixture.removeRequired = true;
      expect(await fixture.copy(), isFalse);
      expect(fixture.copyExits, [0]);
      expect(fixture.calls.where((c) => c.command == 'mkdir'), isEmpty);
    },
  );
}
