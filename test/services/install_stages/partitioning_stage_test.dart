import 'package:test/test.dart';
import 'package:ro_installer/services/fake_command_runner.dart';
import 'package:ro_installer/services/install_stages/partitioning_stage.dart';
import 'package:ro_installer/services/install_stages/stage_context.dart';

/// Test için StageContext oluşturur.
StageContext makeContext(
  Map<String, dynamic> state,
  FakeCommandRunner runner, {
  bool isMock = false,
}) {
  return StageContext(
    state: state,
    log: (msg) {}, // Sessiz log
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
  group('PartitioningStage — full disk', () {
    test('doğru komut sırasını izler: wipefs → sgdisk -Z → sgdisk EFI → sgdisk Root → partprobe', () async {
      final fake = FakeCommandRunner();
      final state = {
        'selectedDisk': '/dev/sda',
        'partitionMethod': 'full',
      };
      final ctx = makeContext(state, fake);

      final stage = const PartitioningStage();
      final result = await stage.execute(ctx);

      expect(result.success, true);

      // Komut sırası doğrulaması
      final cmds = fake.commandNames;
      expect(cmds[0], 'wipefs');
      expect(cmds[1], 'sgdisk'); // -Z (sıfırlama)
      expect(cmds[2], 'sgdisk'); // EFI bölümü
      expect(cmds[3], 'sgdisk'); // Root bölümü
      expect(cmds[4], 'partprobe');

      // wipefs argüman kontrolü
      expect(fake.commandLog[0].args, ['-a', '/dev/sda']);

      // sgdisk -Z argüman kontrolü
      expect(fake.commandLog[1].args, ['-Z', '/dev/sda']);

      // EFI bölümü: 512MB, tip ef00
      expect(fake.commandLog[2].args, contains('-n'));
      expect(fake.commandLog[2].args, contains('1:0:+512M'));
      expect(fake.commandLog[2].args, contains('1:ef00'));

      // Root bölümü: kalan alan
      expect(fake.commandLog[3].args, contains('2:0:0'));
    });

    test('sgdisk sıfırlama başarısız olursa stage durur', () async {
      final fake = FakeCommandRunner();
      // sgdisk -Z başarısız olsun
      fake.addResponse('sgdisk', ['-Z', '/dev/sda'], exitCode: 4, stderr: 'GPT sıfırlanamadı');

      final state = {
        'selectedDisk': '/dev/sda',
        'partitionMethod': 'full',
      };
      final ctx = makeContext(state, fake);

      final stage = const PartitioningStage();
      final result = await stage.execute(ctx);

      expect(result.success, false);
      expect(result.message, contains('sıfırlanamadı'));
    });

    test('NVMe disk için bölüm adları doğru oluşturulur (p1, p2)', () async {
      final fake = FakeCommandRunner();
      final state = {
        'selectedDisk': '/dev/nvme0n1',
        'partitionMethod': 'full',
      };
      final ctx = makeContext(state, fake);

      final stage = const PartitioningStage();
      final result = await stage.execute(ctx);

      expect(result.success, true);

      // partprobe NVMe disk adıyla çağrılmalı
      expect(fake.wasCalledWith('partprobe', ['/dev/nvme0n1']), true);
    });
  });

  group('PartitioningStage — alongside', () {
    test('SWAP ve Root bölümleri oluşturulur', () async {
      final fake = FakeCommandRunner();
      // RAM bilgisi için fixture
      fake.addResponse('grep', ['MemTotal', '/proc/meminfo'],
          stdout: 'MemTotal:        8192000 kB');

      final state = {
        'selectedDisk': '/dev/sda',
        'partitionMethod': 'alongside',
        'linuxDiskSizeGB': 80.0,
      };
      final ctx = makeContext(state, fake);

      final stage = const PartitioningStage();
      final result = await stage.execute(ctx);

      expect(result.success, true);

      // sgdisk backup + SWAP + Root + partprobe çağrılmış olmalı
      expect(fake.wasCommandCalled('sgdisk'), true);
      expect(fake.wasCommandCalled('partprobe'), true);
    });
  });

  group('PartitioningStage — manual', () {
    test('boş plan verilirse hata döner', () async {
      final fake = FakeCommandRunner();
      final state = {
        'selectedDisk': '/dev/sda',
        'partitionMethod': 'manual',
        'manualPartitions': <Map<String, dynamic>>[],
      };
      final ctx = makeContext(state, fake);

      final stage = const PartitioningStage();
      final result = await stage.execute(ctx);

      expect(result.success, false);
      expect(result.message, contains('boş'));
    });

    test('plan varsa fiziksel uygulama akışı başlar', () async {
      final fake = FakeCommandRunner();
      fake.addResponse('lsblk', ['-rn', '-o', 'NAME,TYPE', '/dev/sda'], stdout: '''
sda disk
sda1 part
sda2 part
''');
      fake.addResponse('lsblk', ['-rn', '-o', 'NAME,TYPE', '/dev/sda'], stdout: '''
sda disk
sda1 part
sda3 part
''');

      final manualParts = [
        {
          'name': '/dev/sda1',
          'type': 'fat32',
          'mount': '/boot/efi',
          'isFreeSpace': false,
          'isPlanned': false,
          'sizeBytes': 500000000,
        },
        {
          'name': 'New Partition',
          'type': 'ext4',
          'mount': '/',
          'isFreeSpace': false,
          'isPlanned': true,
          'sizeBytes': 50000000000,
        },
      ];
      final state = {
        'selectedDisk': '/dev/sda',
        'partitionMethod': 'manual',
        'manualPartitions': manualParts,
      };
      final ctx = makeContext(state, fake, isMock: true);

      final stage = const PartitioningStage();
      final result = await stage.execute(ctx);

      expect(result.success, true);
      expect(fake.wasCalledWith('sgdisk', ['-d', '2', '/dev/sda']), true);
      expect(fake.wasCommandCalled('partprobe'), true);
    });
  });

  group('PartitioningStage — bilinmeyen yöntem', () {
    test('bilinmeyen yöntemde hata döner', () async {
      final fake = FakeCommandRunner();
      final state = {
        'selectedDisk': '/dev/sda',
        'partitionMethod': 'unknown_method',
      };
      final ctx = makeContext(state, fake);

      final stage = const PartitioningStage();
      final result = await stage.execute(ctx);

      expect(result.success, false);
      expect(result.message, contains('Bilinmeyen'));
    });
  });
}
