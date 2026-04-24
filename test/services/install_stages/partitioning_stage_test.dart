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
  group('PartitioningStage — full disk', () {
    test(
      'doğru komut sırasını izler: wipefs → sgdisk -Z → sgdisk EFI → sgdisk Root → partprobe',
      () async {
        final fake = FakeCommandRunner();
        final state = {'selectedDisk': '/dev/sda', 'partitionMethod': 'full'};
        final ctx = makeContext(state, fake);

        final stage = const PartitioningStage();
        final result = await stage.execute(ctx);

        expect(result.success, true);

        // Komut sırası doğrulaması
        final cmds = fake.commandNames.where((cmd) => cmd != 'sh').toList();
        expect(cmds[0], 'wipefs');
        expect(cmds[1], 'sgdisk'); // -Z (sıfırlama)
        expect(cmds[2], 'sgdisk'); // EFI bölümü
        expect(cmds[3], 'sgdisk'); // Root bölümü
        expect(cmds[4], 'partprobe');

        // wipefs argüman kontrolü
        expect(
          fake.commandLog.firstWhere((entry) => entry.command == 'wipefs').args,
          ['-a', '/dev/sda'],
        );

        // sgdisk -Z argüman kontrolü
        final sgdiskCommands = fake.commandLog
            .where((entry) => entry.command == 'sgdisk')
            .toList();
        expect(sgdiskCommands.first.args, ['-Z', '/dev/sda']);

        // EFI bölümü: 512MB, tip ef00
        expect(sgdiskCommands[1].args, contains('-n'));
        expect(sgdiskCommands[1].args, contains('1:0:+512M'));
        expect(sgdiskCommands[1].args, contains('1:ef00'));

        // Root bölümü: kalan alan
        expect(sgdiskCommands[2].args, contains('2:0:0'));
      },
    );

    test('sgdisk sıfırlama başarısız olursa stage durur', () async {
      final fake = FakeCommandRunner();
      // sgdisk -Z başarısız olsun
      fake.addResponse(
        'sgdisk',
        ['-Z', '/dev/sda'],
        exitCode: 4,
        stderr: 'GPT sıfırlanamadı',
      );

      final state = {'selectedDisk': '/dev/sda', 'partitionMethod': 'full'};
      final ctx = makeContext(state, fake);

      final stage = const PartitioningStage();
      final result = await stage.execute(ctx);

      expect(result.success, false);
      expect(result.message, contains('sıfırlanamadı'));
    });

    test('NVMe disk için bölüm adları doğru oluşturulur (p1, p2)', () async {
      final fake = FakeCommandRunner();
      final state = {'selectedDisk': '/dev/nvme0n1', 'partitionMethod': 'full'};
      final ctx = makeContext(state, fake);

      final stage = const PartitioningStage();
      final result = await stage.execute(ctx);

      expect(result.success, true);

      // partprobe NVMe disk adıyla çağrılmalı
      expect(fake.wasCalledWith('partprobe', ['/dev/nvme0n1']), true);
    });
  });

  group('PartitioningStage — alongside', () {
    test(
      'yeterli bitisik bos alan varsa shrink yapmadan SWAP ve Root oluşturulur',
      () async {
        final fake = FakeCommandRunner();
        fake.addResponse('grep', [
          'MemTotal',
          '/proc/meminfo',
        ], stdout: 'MemTotal:        4096000 kB');
        fake.addResponse(
          'lsblk',
          ['-J', '-b', '-o', 'NAME,PATH,TYPE,SIZE,START,FSTYPE', '/dev/sda'],
          stdout: '''
{
  "blockdevices": [
    {
      "name": "sda",
      "path": "/dev/sda",
      "type": "disk",
      "size": 214748364800,
      "children": [
        {
          "name": "sda1",
          "path": "/dev/sda1",
          "type": "part",
          "size": 536870912,
          "start": 2048,
          "fstype": "vfat"
        },
        {
          "name": "sda2",
          "path": "/dev/sda2",
          "type": "part",
          "size": 85899345920,
          "start": 1050624,
          "fstype": "ntfs"
        }
      ]
    }
  ]
}''',
        );
        fake.addResponse('sgdisk', ['-F', '/dev/sda'], stdout: '180000768');
        fake.addResponse('sgdisk', ['-E', '/dev/sda'], stdout: '299999966');

        final state = {
          'selectedDisk': '/dev/sda',
          'partitionMethod': 'alongside',
          'linuxDiskSizeGB': 40.0,
        };
        final ctx = makeContext(state, fake);

        final stage = const PartitioningStage();
        final result = await stage.execute(ctx);

        expect(result.success, true);
        expect(fake.wasCommandCalled('parted'), false);
        expect(fake.wasCommandCalled('ntfsresize'), false);
        expect(
          fake.wasCalledWith('sgdisk', [
            '-n',
            '0:180000768:188192767',
            '-t',
            '0:8200',
            '-c',
            '0:RoASD_Swap',
            '/dev/sda',
          ]),
          true,
        );
        expect(
          fake.wasCalledWith('sgdisk', [
            '-n',
            '0:188192768:263886847',
            '-t',
            '0:8300',
            '-c',
            '0:RoASD_Root',
            '/dev/sda',
          ]),
          true,
        );
        expect(fake.wasCommandCalled('partprobe'), true);
      },
    );

    test('gerektiginde shrink yapip yeni yerlesimi olusturur', () async {
      final fake = FakeCommandRunner();
      fake.addResponse('grep', [
        'MemTotal',
        '/proc/meminfo',
      ], stdout: 'MemTotal:        8192000 kB');
      fake.addResponse(
        'lsblk',
        ['-J', '-b', '-o', 'NAME,PATH,TYPE,SIZE,START,FSTYPE', '/dev/sda'],
        stdout: '''
{
  "blockdevices": [
    {
      "name": "sda",
      "path": "/dev/sda",
      "type": "disk",
      "size": 153600000000,
      "children": [
        {
          "name": "sda1",
          "path": "/dev/sda1",
          "type": "part",
          "size": 536870912,
          "start": 2048,
          "fstype": "vfat"
        },
        {
          "name": "sda2",
          "path": "/dev/sda2",
          "type": "part",
          "size": 128849018880,
          "start": 1050624,
          "fstype": "ntfs"
        }
      ]
    }
  ]
}''',
      );
      fake.addResponse('sgdisk', ['-F', '/dev/sda'], stdout: '252708864');
      fake.addResponse('sgdisk', ['-E', '/dev/sda'], stdout: '299999966');

      final state = {
        'selectedDisk': '/dev/sda',
        'partitionMethod': 'alongside',
        'linuxDiskSizeGB': 80.0,
        'shrinkCandidatePartition': '/dev/sda2',
        'shrinkCandidateFs': 'ntfs',
      };
      final ctx = makeContext(state, fake);

      final stage = const PartitioningStage();
      final result = await stage.execute(ctx);

      expect(result.success, true);
      expect(
        fake.wasCalledWith('ntfsresize', [
          '--force',
          '--size',
          '67095232512',
          '/dev/sda2',
        ]),
        true,
      );
      expect(
        fake.wasCalledWith('parted', [
          '-s',
          '/dev/sda',
          'unit',
          's',
          'resizepart',
          '2',
          '132227071s',
        ]),
        true,
      );
      expect(
        fake.wasCalledWith('sgdisk', [
          '-n',
          '0:132227072:148611071',
          '-t',
          '0:8200',
          '-c',
          '0:RoASD_Swap',
          '/dev/sda',
        ]),
        true,
      );
      expect(
        fake.wasCalledWith('sgdisk', [
          '-n',
          '0:148611072:299999231',
          '-t',
          '0:8300',
          '-c',
          '0:RoASD_Root',
          '/dev/sda',
        ]),
        true,
      );
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
      fake.addResponse(
        'lsblk',
        ['-rn', '-o', 'NAME,TYPE', '/dev/sda'],
        stdout: '''
sda disk
sda1 part
sda2 part
''',
      );
      fake.addResponse(
        'lsblk',
        ['-rn', '-o', 'NAME,TYPE', '/dev/sda'],
        stdout: '''
sda disk
sda1 part
sda3 part
''',
      );
      fake.addResponse('blockdev', ['--getss', '/dev/sda'], stdout: '512');
      fake.addResponse(
        'lsblk',
        ['-J', '-b', '-o', 'NAME,PATH,TYPE,SIZE,START,FSTYPE', '/dev/sda'],
        stdout: '''
{
  "blockdevices": [
    {
      "name": "sda",
      "path": "/dev/sda",
      "type": "disk",
      "size": 68719476736,
      "children": [
        {
          "name": "sda1",
          "path": "/dev/sda1",
          "type": "part",
          "size": 536870912,
          "start": 2048,
          "fstype": "vfat"
        }
      ]
    }
  ]
}''',
      );

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
      expect(
        fake.wasCalledWith('sgdisk', [
          '-n',
          '0:1050624:98706873',
          '-t',
          '0:8300',
          '/dev/sda',
        ]),
        true,
      );
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
