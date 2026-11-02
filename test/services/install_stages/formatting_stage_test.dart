import 'dart:convert';

import 'package:test/test.dart';
import 'package:ro_installer/services/fake_command_runner.dart';
import 'package:ro_installer/services/install_stages/formatting_stage.dart';
import 'package:ro_installer/services/install_stages/stage_context.dart';

/// Test için StageContext oluşturur.
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
  group('FormattingStage — full disk', () {
    test('EFI ve Btrfs Root bölümleri biçimlendirilir', () async {
      final fake = FakeCommandRunner();
      final state = {
        'selectedDisk': '/dev/sda',
        'partitionMethod': 'full',
        'fileSystem': 'btrfs',
      };
      final ctx = makeContext(state, fake);

      final stage = const FormattingStage();
      final result = await stage.execute(ctx);

      expect(result.success, true);

      // mkfs.fat -F32 /dev/sda1
      expect(fake.wasCalledWith('mkfs.fat', ['-F32', '/dev/sda1']), true);
      expect(fake.wasCommandCalled('mkswap'), false);
      expect(state['_resolvedRootPart'], '/dev/sda2');
      expect(state.containsKey('_resolvedSwapPart'), isFalse);
      expect(fake.wasCalledWith('mkfs.btrfs', ['-f', '/dev/sda2']), true);
      final storagePlan =
          jsonDecode(state['_formatStoragePlan'] as String)
              as Map<String, dynamic>;
      final destructiveTypes =
          (storagePlan['destructiveOperations'] as List<dynamic>)
              .map((entry) => (entry as Map<String, dynamic>)['type'])
              .toList();
      expect(
        destructiveTypes,
        containsAll(['format_efi', 'format_btrfs_root']),
      );
    });

    test(
      'unsupported storage topology format komutu baslatmadan reddedilir',
      () async {
        final fake = FakeCommandRunner();
        final state = {
          'selectedDisk': '/dev/sda',
          'partitionMethod': 'full',
          'fileSystem': 'btrfs',
          'unsupportedStorageBlockers': ['unsupported_raid'],
          'unsupportedStorageDetails': [
            'unsupported_raid:/dev/sda2:type=part:fs=linux_raid_member',
          ],
        };
        final ctx = makeContext(state, fake);

        final result = await const FormattingStage().execute(ctx);

        expect(result.success, false);
        expect(result.message, contains('RAID'));
        expect(fake.wasCommandCalled('mkfs.fat'), false);
        expect(fake.wasCommandCalled('mkswap'), false);
        expect(fake.wasCommandCalled('mkfs.btrfs'), false);
      },
    );

    test('Btrfs dışı root dosya sistemi reddedilir', () async {
      final fake = FakeCommandRunner();
      final state = {
        'selectedDisk': '/dev/sda',
        'partitionMethod': 'full',
        'fileSystem': 'ext4',
      };
      final ctx = makeContext(state, fake);

      final stage = const FormattingStage();
      final result = await stage.execute(ctx);

      expect(result.success, false);
      expect(result.message, contains('yalnızca Btrfs'));
      expect(fake.wasCommandCalled('mkfs.fat'), false);
    });

    test('XFS root dosya sistemi reddedilir', () async {
      final fake = FakeCommandRunner();
      final state = {
        'selectedDisk': '/dev/sda',
        'partitionMethod': 'full',
        'fileSystem': 'xfs',
      };
      final ctx = makeContext(state, fake);

      final stage = const FormattingStage();
      final result = await stage.execute(ctx);

      expect(result.success, false);
      expect(result.message, contains('yalnızca Btrfs'));
      expect(fake.wasCommandCalled('mkfs.fat'), false);
    });

    test('NVMe disk için p1/p2/p3 bölüm adları kullanılır', () async {
      final fake = FakeCommandRunner();
      final state = {
        'selectedDisk': '/dev/nvme0n1',
        'partitionMethod': 'full',
        'fileSystem': 'btrfs',
      };
      final ctx = makeContext(state, fake);

      final stage = const FormattingStage();
      final result = await stage.execute(ctx);

      expect(result.success, true);
      expect(fake.wasCalledWith('mkfs.fat', ['-F32', '/dev/nvme0n1p1']), true);
      expect(fake.wasCommandCalled('mkswap'), false);
      expect(fake.wasCalledWith('mkfs.btrfs', ['-f', '/dev/nvme0n1p2']), true);
    });

    test('mkfs.fat başarısız olursa stage durur', () async {
      final fake = FakeCommandRunner();
      fake.addResponse(
        'mkfs.fat',
        ['-F32', '/dev/sda1'],
        exitCode: 1,
        stderr: 'Permission denied',
      );

      final state = {
        'selectedDisk': '/dev/sda',
        'partitionMethod': 'full',
        'fileSystem': 'btrfs',
      };
      final ctx = makeContext(state, fake);

      final stage = const FormattingStage();
      final result = await stage.execute(ctx);

      expect(result.success, false);
      expect(result.message, contains('EFI'));
    });
  });

  group('FormattingStage — unapproved manual input', () {
    for (final part in [
      {
        'name': '/dev/sda1',
        'type': 'fat32',
        'mount': '/boot/efi',
        'isPlanned': true,
        'formatOnInstall': true,
      },
      {
        'name': '/dev/sda2',
        'type': 'btrfs',
        'mount': '/',
        'isPlanned': true,
        'formatOnInstall': true,
      },
      {
        'name': '/dev/sda2',
        'type': 'ext4',
        'mount': '/',
        'isPlanned': true,
        'formatOnInstall': true,
      },
      {
        'name': '/dev/sda1',
        'type': 'fat32',
        'mount': '/boot/efi',
        'isPlanned': true,
        'formatOnInstall': false,
      },
    ]) {
      test('legacy flags cannot authorize formatting: $part', () async {
        final runner = FakeCommandRunner();
        final ctx = makeContext({
          'selectedDisk': '/dev/sda',
          'partitionMethod': 'manual',
          'fileSystem': 'btrfs',
          'manualPartitions': [part],
        }, runner);
        expect((await const FormattingStage().execute(ctx)).success, false);
        expect(runner.commandLog, isEmpty);
      });
    }
  });
}
