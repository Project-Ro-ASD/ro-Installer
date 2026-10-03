import 'package:test/test.dart';
import 'package:ro_installer/services/fake_command_runner.dart';
import 'package:ro_installer/services/install_stages/mounting_stage.dart';
import 'package:ro_installer/services/install_stages/stage_context.dart';

StageContext makeContext(
  Map<String, dynamic> state,
  FakeCommandRunner runner, {
  bool isMock = false,
}) {
  return StageContext(
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

  group('MountingStage - Manual Mode', () {
    test('/boot, /boot/efi sirasiyla baglanir ve swap etkinlesir', () async {
      final fake = FakeCommandRunner();
      final state = {
        'selectedDisk': '/dev/sda',
        'partitionMethod': 'manual',
        'manualPartitions': [
          {
            'name': '/dev/sda2',
            'type': 'btrfs',
            'mount': '/',
            'isFreeSpace': false,
            'isPlanned': true,
            'formatOnInstall': true,
          },
          {
            'name': '/dev/sda1',
            'type': 'fat32',
            'mount': '/boot/efi',
            'isFreeSpace': false,
            'isPlanned': true,
            'formatOnInstall': false,
          },
          {
            'name': '/dev/sda3',
            'type': 'btrfs',
            'mount': '/boot',
            'isFreeSpace': false,
            'isPlanned': true,
            'formatOnInstall': true,
          },
          {
            'name': '/dev/sda4',
            'type': 'linux-swap',
            'mount': '[SWAP]',
            'isFreeSpace': false,
            'isPlanned': true,
            'formatOnInstall': false,
          },
        ],
      };

      final ctx = makeContext(state, fake, isMock: true);
      final stage = const MountingStage();
      final result = await stage.execute(ctx);

      expect(result.success, true);
      expect(
        fake.wasCalledWith('mount', [
          '-o',
          'subvol=@,compress=zstd:1',
          '/dev/sda2',
          '/mnt',
        ]),
        true,
      );
      expect(fake.wasCalledWith('mount', ['/dev/sda3', '/mnt/boot']), true);
      expect(fake.wasCalledWith('mount', ['/dev/sda1', '/mnt/boot/efi']), true);
      expect(fake.wasCalledWith('swapon', ['/dev/sda4']), true);

      final bootMountIndex = fake.commandLog.indexWhere(
        (cmd) =>
            cmd.command == 'mount' &&
            cmd.args.length == 2 &&
            cmd.args[0] == '/dev/sda3' &&
            cmd.args[1] == '/mnt/boot',
      );
      final efiMountIndex = fake.commandLog.indexWhere(
        (cmd) =>
            cmd.command == 'mount' &&
            cmd.args.length == 2 &&
            cmd.args[0] == '/dev/sda1' &&
            cmd.args[1] == '/mnt/boot/efi',
      );

      expect(bootMountIndex, greaterThanOrEqualTo(0));
      expect(efiMountIndex, greaterThanOrEqualTo(0));
      expect(bootMountIndex, lessThan(efiMountIndex));
    });

    test('ayri /home varsa root altinda @home olusturulmaz', () async {
      final fake = FakeCommandRunner();
      final state = {
        'selectedDisk': '/dev/sda',
        'partitionMethod': 'manual',
        'manualPartitions': [
          {
            'name': '/dev/sda2',
            'type': 'btrfs',
            'mount': '/',
            'isFreeSpace': false,
            'isPlanned': true,
            'formatOnInstall': true,
          },
          {
            'name': '/dev/sda5',
            'type': 'btrfs',
            'mount': '/home',
            'isFreeSpace': false,
            'isPlanned': true,
            'formatOnInstall': true,
          },
          {
            'name': '/dev/sda1',
            'type': 'fat32',
            'mount': '/boot/efi',
            'isFreeSpace': false,
            'isPlanned': true,
            'formatOnInstall': false,
          },
          {
            'name': '/dev/sda4',
            'type': 'linux-swap',
            'mount': '[SWAP]',
            'isFreeSpace': false,
            'isPlanned': true,
            'formatOnInstall': false,
          },
        ],
      };

      final ctx = makeContext(state, fake, isMock: true);
      final stage = const MountingStage();
      final result = await stage.execute(ctx);

      expect(result.success, true);
      expect(
        fake.wasCalledWith('btrfs', ['subvolume', 'create', '/mnt/@home']),
        false,
      );
      expect(
        fake.wasCalledWith('mount', [
          '-o',
          'subvol=@home,compress=zstd:1',
          '/dev/sda2',
          '/mnt/home',
        ]),
        false,
      );
      expect(fake.wasCalledWith('mount', ['/dev/sda5', '/mnt/home']), true);
    });
  });
}
