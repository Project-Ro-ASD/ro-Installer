import 'package:test/test.dart';
import 'package:ro_installer/services/mount_session.dart';
import 'package:ro_installer/services/fake_command_runner.dart';
import 'package:ro_installer/services/install_stages/mounting_stage.dart';
import 'package:ro_installer/services/install_stages/stage_context.dart';

StageContext makeContext(
  Map<String, dynamic> state,
  FakeCommandRunner runner, {
  bool isMock = false,
}) {
  return StageContext(
    mountSession: SimulatedMountSession(runner),
    state: state,
    log: (msg) {},
    onProgress: (p, s) {},
    commandRunner: runner,
    runCmd:
        (
          cmd,
          args,
          onLog, {
          bool isMock = false,
          List<int> allowedExitCodes = const [0],
        }) async {
          final result = await runner.run(cmd, args);
          return allowedExitCodes.contains(result.exitCode);
        },
    isMock: isMock,
  );
}

void main() {
  group('MountingStage - standard full disk', () {
    for (final disk in ['/dev/sda', '/dev/nvme0n1']) {
      test(
        '$disk creates flat rollback-aware subvolumes without swap',
        () async {
          final fake = FakeCommandRunner();
          final root = disk.contains('nvme') ? '${disk}p2' : '${disk}2';
          final efi = disk.contains('nvme') ? '${disk}p1' : '${disk}1';
          final result = await const MountingStage().execute(
            makeContext({
              'selectedDisk': disk,
              'partitionMethod': 'full',
              'fileSystem': 'btrfs',
            }, fake),
          );
          expect(result.success, isTrue);
          expect(
            fake.wasCalledWith('mount', ['-o', 'subvolid=5', root, '/mnt']),
            isTrue,
          );
          const layout = {
            'root': '/',
            'home': '/home',
            'var_log': '/var/log',
            'var_cache': '/var/cache',
            'var_tmp': '/var/tmp',
          };
          final creates = fake.commandLog
              .where((cmd) => cmd.command == 'btrfs')
              .map((cmd) => cmd.args.last)
              .toList();
          expect(creates, layout.keys.map((name) => '/mnt/$name').toList());
          for (final entry in layout.entries) {
            final target = entry.value == '/' ? '/mnt' : '/mnt${entry.value}';
            expect(
              fake.wasCalledWith('mount', [
                '-o',
                'compress=zstd:1,subvol=${entry.key}',
                root,
                target,
              ]),
              isTrue,
            );
          }
          expect(fake.wasCalledWith('mount', [efi, '/mnt/boot/efi']), isTrue);
          expect(fake.wasCommandCalled('swapon'), isFalse);
          expect(
            fake.commandLog.any(
              (cmd) => cmd.command == 'mount' && cmd.args.last == '/mnt/boot',
            ),
            isFalse,
          );
        },
      );
    }
    test('top-level unmount failure stops root remount', () async {
      final fake = FakeCommandRunner();
      fake.addResponse('umount', ['/mnt'], exitCode: 1);
      final result = await const MountingStage().execute(
        makeContext({
          'selectedDisk': '/dev/sda',
          'partitionMethod': 'full',
          'fileSystem': 'btrfs',
        }, fake),
      );
      expect(result.success, isFalse);
      expect(
        fake.wasCalledWith('mount', [
          '-o',
          'compress=zstd:1,subvol=root',
          '/dev/sda2',
          '/mnt',
        ]),
        isFalse,
      );
    });
  });

  group('MountingStage - unapproved manual maps', () {
    for (final mount in ['/', '/boot/efi', '/boot', '/home', '[SWAP]']) {
      test('legacy mount selection cannot bind a filesystem: $mount', () async {
        final runner = FakeCommandRunner();
        final ctx = makeContext(
          {
            'selectedDisk': '/dev/sda',
            'partitionMethod': 'manual',
            'fileSystem': 'btrfs',
            'manualPartitions': [
              {
                'name': '/dev/sda2',
                'type': 'btrfs',
                'mount': mount,
                'isPlanned': true,
              },
            ],
          },
          runner,
          isMock: true,
        );
        expect((await const MountingStage().execute(ctx)).success, false);
        expect(runner.commandLog, isEmpty);
      });
    }
  });
}
