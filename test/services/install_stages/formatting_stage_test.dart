import 'package:test/test.dart';
import 'package:ro_installer/services/fake_command_runner.dart';
import 'package:ro_installer/services/command_runner.dart';
import 'package:ro_installer/services/install_stages/formatting_stage.dart';
import 'package:ro_installer/services/install_stages/stage_context.dart';
import 'package:ro_installer/services/install_stages/stage_result.dart';

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
    runCmd: (cmd, args, onLog, {bool isMock = false, List<int> allowedExitCodes = const [0]}) async {
      final result = await runner.run(cmd, args);
      return allowedExitCodes.contains(result.exitCode);
    },
    isMock: isMock,
  );
}

void main() {
  group('FormattingStage — full disk', () {
    test('EFI → FAT32, Root → BTRFS biçimlendirilir', () async {
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
      // mkfs.btrfs -f /dev/sda2
      expect(fake.wasCalledWith('mkfs.btrfs', ['-f', '/dev/sda2']), true);
    });

    test('EXT4 dosya sistemi doğru formatlanır', () async {
      final fake = FakeCommandRunner();
      final state = {
        'selectedDisk': '/dev/sda',
        'partitionMethod': 'full',
        'fileSystem': 'ext4',
      };
      final ctx = makeContext(state, fake);

      final stage = const FormattingStage();
      final result = await stage.execute(ctx);

      expect(result.success, true);
      expect(fake.wasCalledWith('mkfs.ext4', ['-F', '/dev/sda2']), true);
    });

    test('XFS dosya sistemi doğru formatlanır', () async {
      final fake = FakeCommandRunner();
      final state = {
        'selectedDisk': '/dev/sda',
        'partitionMethod': 'full',
        'fileSystem': 'xfs',
      };
      final ctx = makeContext(state, fake);

      final stage = const FormattingStage();
      final result = await stage.execute(ctx);

      expect(result.success, true);
      expect(fake.wasCalledWith('mkfs.xfs', ['-f', '/dev/sda2']), true);
    });

    test('NVMe disk için p1/p2 bölüm adları kullanılır', () async {
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
      // NVMe: /dev/nvme0n1p1 ve /dev/nvme0n1p2
      expect(fake.wasCalledWith('mkfs.fat', ['-F32', '/dev/nvme0n1p1']), true);
      expect(fake.wasCalledWith('mkfs.btrfs', ['-f', '/dev/nvme0n1p2']), true);
    });

    test('mkfs.fat başarısız olursa stage durur', () async {
      final fake = FakeCommandRunner();
      fake.addResponse('mkfs.fat', ['-F32', '/dev/sda1'],
          exitCode: 1, stderr: 'Permission denied');

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

  group('FormattingStage — manual', () {
    test('planlanan bölümler sırayla biçimlendirilir', () async {
      final fake = FakeCommandRunner();
      final state = {
        'selectedDisk': '/dev/sda',
        'partitionMethod': 'manual',
        'fileSystem': 'btrfs',
        'manualPartitions': [
          {'name': '/dev/sda1', 'type': 'fat32', 'mount': '/boot/efi', 'isPlanned': true, 'isFreeSpace': false},
          {'name': '/dev/sda2', 'type': 'ext4', 'mount': '/', 'isPlanned': true, 'isFreeSpace': false},
          {'name': '/dev/sda3', 'type': 'linux-swap', 'mount': '[SWAP]', 'isPlanned': true, 'isFreeSpace': false},
        ],
      };
      final ctx = makeContext(state, fake);

      final stage = const FormattingStage();
      final result = await stage.execute(ctx);

      expect(result.success, true);
      expect(fake.wasCalledWith('mkfs.fat', ['-F32', '/dev/sda1']), true);
      expect(fake.wasCalledWith('mkfs.ext4', ['-F', '/dev/sda2']), true);
      expect(fake.wasCalledWith('mkswap', ['/dev/sda3']), true);
    });

    test('isPlanned=false olan bölümler atlanır', () async {
      final fake = FakeCommandRunner();
      final state = {
        'selectedDisk': '/dev/sda',
        'partitionMethod': 'manual',
        'fileSystem': 'btrfs',
        'manualPartitions': [
          {'name': '/dev/sda1', 'type': 'ntfs', 'mount': 'unmounted', 'isPlanned': false, 'isFreeSpace': false},
          {'name': '/dev/sda2', 'type': 'ext4', 'mount': '/', 'isPlanned': true, 'isFreeSpace': false},
        ],
      };
      final ctx = makeContext(state, fake);

      final stage = const FormattingStage();
      final result = await stage.execute(ctx);

      expect(result.success, true);
      // sda1 formatlanmamalı (isPlanned=false)
      expect(fake.wasCommandCalled('mkfs.ntfs'), false);
      // sda2 formatlanmalı
      expect(fake.wasCalledWith('mkfs.ext4', ['-F', '/dev/sda2']), true);
    });
  });
}
