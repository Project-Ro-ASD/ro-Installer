import 'dart:convert';

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
        final cmds = fake.commandNames
            .where(
              (cmd) =>
                  cmd != 'sh' &&
                  cmd != 'grep' &&
                  cmd != 'blockdev' &&
                  cmd != 'lsblk',
            )
            .toList();
        expect(cmds[0], 'wipefs');
        expect(cmds[1], 'sgdisk'); // -Z (sıfırlama)
        expect(cmds[2], 'sgdisk'); // EFI bölümü
        expect(cmds[3], 'sgdisk'); // SWAP bölümü
        expect(cmds[4], 'sgdisk'); // Root bölümü
        expect(cmds[5], 'partprobe');

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

        // SWAP bölümü: hibernate uyumlu, RAM'e göre dinamik
        expect(sgdiskCommands[2].args, contains('2:0:+8192M'));
        expect(sgdiskCommands[2].args, contains('2:8200'));

        // Root bölümü: kalan alan
        expect(sgdiskCommands[3].args, contains('3:0:0'));
        expect(sgdiskCommands[3].args, contains('3:8300'));

        final storagePlan =
            jsonDecode(state['_storagePlan'] as String) as Map<String, dynamic>;
        final destructiveTypes =
            (storagePlan['destructiveOperations'] as List<dynamic>)
                .map((entry) => (entry as Map<String, dynamic>)['type'])
                .toList();
        expect(destructiveTypes, [
          'wipe_disk',
          'create_efi',
          'create_swap',
          'create_btrfs_root',
          'format_efi',
          'format_swap',
          'format_btrfs_root',
        ]);
      },
    );

    test('unsupported storage topology disk yazmadan reddedilir', () async {
      final fake = FakeCommandRunner();
      fake.addResponse(
        'lsblk',
        ['-J', '-o', 'NAME,TYPE,FSTYPE', '/dev/sda'],
        stdout: '''
{
  "blockdevices": [
    {
      "name": "sda",
      "type": "disk",
      "fstype": null,
      "children": [
        {
          "name": "sda2",
          "type": "part",
          "fstype": "LVM2_member",
          "children": [
            {"name": "fedora-root", "type": "lvm", "fstype": "btrfs"}
          ]
        }
      ]
    }
  ]
}''',
      );
      final state = {'selectedDisk': '/dev/sda', 'partitionMethod': 'full'};
      final ctx = makeContext(state, fake);

      final result = await const PartitioningStage().execute(ctx);

      expect(result.success, false);
      expect(result.message, contains('LVM'));
      expect(fake.wasCommandCalled('wipefs'), false);
      expect(fake.wasCalledWith('sgdisk', ['-Z', '/dev/sda']), false);
    });

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

    test('partprobe başarısız olursa stage tamamlandı sayılmaz', () async {
      final fake = FakeCommandRunner();
      fake.addResponse(
        'partprobe',
        ['/dev/sda'],
        exitCode: 1,
        stderr: 'kernel busy',
      );

      final state = {'selectedDisk': '/dev/sda', 'partitionMethod': 'full'};
      final ctx = makeContext(state, fake);

      final result = await const PartitioningStage().execute(ctx);

      expect(result.success, false);
      expect(result.message, contains('yeniden okunamadi'));
      expect(fake.wasCalledWith('sgdisk', ['-Z', '/dev/sda']), true);
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
          'diskBootMode': 'uefi',
          'diskPartitionTable': 'gpt',
          'hasExistingEfi': true,
          'existingEfiPartition': '/dev/sda1',
          'linuxDiskSizeGB': 48.0,
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
            '0:180000768:196777983',
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
            '0:196777984:280664063',
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
        'diskBootMode': 'uefi',
        'diskPartitionTable': 'gpt',
        'hasExistingEfi': true,
        'existingEfiPartition': '/dev/sda1',
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
          '0:132227072:151101439',
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
          '0:151101440:299999231',
          '-t',
          '0:8300',
          '-c',
          '0:RoASD_Root',
          '/dev/sda',
        ]),
        true,
      );
    });

    test(
      'preflight kesin NTFS blocker varsa disk tablosuna dokunmadan durur',
      () async {
        final fake = FakeCommandRunner();
        final state = {
          'selectedDisk': '/dev/sda',
          'partitionMethod': 'alongside',
          'alongsideBlockers': ['ntfs_hibernated_or_fast_startup'],
        };
        final ctx = makeContext(state, fake);

        final stage = const PartitioningStage();
        final result = await stage.execute(ctx);

        expect(result.success, false);
        expect(result.message, contains('Windows'));
        expect(fake.wasCommandCalled('sgdisk'), false);
        expect(fake.wasCommandCalled('parted'), false);
      },
    );

    test('NTFS info hibernation bildirirse resize baslamadan durur', () async {
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
      fake.addResponse(
        'ntfsresize',
        ['--info', '--force', '/dev/sda2'],
        exitCode: 1,
        stderr:
            'The NTFS partition is hibernated. Resume and shutdown Windows fully.',
      );

      final state = {
        'selectedDisk': '/dev/sda',
        'partitionMethod': 'alongside',
        'diskBootMode': 'uefi',
        'diskPartitionTable': 'gpt',
        'hasExistingEfi': true,
        'existingEfiPartition': '/dev/sda1',
        'linuxDiskSizeGB': 80.0,
        'shrinkCandidatePartition': '/dev/sda2',
        'shrinkCandidateFs': 'ntfs',
      };
      final ctx = makeContext(state, fake);

      final stage = const PartitioningStage();
      final result = await stage.execute(ctx);

      expect(result.success, false);
      expect(result.message, contains('Windows'));
      expect(
        fake.wasCalledWith('ntfsresize', [
          '--force',
          '--size',
          '67095232512',
          '/dev/sda2',
        ]),
        false,
      );
      expect(fake.wasCommandCalled('parted'), false);
    });

    test(
      'NTFS dirty ise ntfsfix sonrasi tekrar kontrol edip resize eder',
      () async {
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
        fake.addResponse(
          'ntfsresize',
          ['--info', '--force', '/dev/sda2'],
          exitCode: 1,
          stderr: 'Volume is dirty. Run chkdsk.',
        );
        fake.addResponse('ntfsfix', ['-d', '/dev/sda2']);
        fake.addResponse('ntfsresize', [
          '--info',
          '--force',
          '/dev/sda2',
        ], stdout: 'You might resize at 67000000000 bytes');

        final state = {
          'selectedDisk': '/dev/sda',
          'partitionMethod': 'alongside',
          'diskBootMode': 'uefi',
          'diskPartitionTable': 'gpt',
          'hasExistingEfi': true,
          'existingEfiPartition': '/dev/sda1',
          'linuxDiskSizeGB': 80.0,
          'shrinkCandidatePartition': '/dev/sda2',
          'shrinkCandidateFs': 'ntfs',
          'alongsideBlockers': ['ntfs_dirty'],
        };
        final ctx = makeContext(state, fake);

        final stage = const PartitioningStage();
        final result = await stage.execute(ctx);

        expect(result.success, true);
        expect(fake.wasCalledWith('ntfsfix', ['-d', '/dev/sda2']), true);
        expect(
          fake.wasCalledWith('ntfsresize', [
            '--force',
            '--size',
            '67095232512',
            '/dev/sda2',
          ]),
          true,
        );
      },
    );

    test('NTFS dirty ama ntfsfix yoksa resize baslamadan durur', () async {
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
      fake.addResponse(
        'ntfsresize',
        ['--info', '--force', '/dev/sda2'],
        exitCode: 1,
        stderr: 'Volume is dirty. Run chkdsk.',
      );
      fake.addResponse('sh', [
        '-c',
        'command -v ntfsfix >/dev/null 2>&1',
      ], exitCode: 1);

      final state = {
        'selectedDisk': '/dev/sda',
        'partitionMethod': 'alongside',
        'diskBootMode': 'uefi',
        'diskPartitionTable': 'gpt',
        'hasExistingEfi': true,
        'existingEfiPartition': '/dev/sda1',
        'linuxDiskSizeGB': 80.0,
        'shrinkCandidatePartition': '/dev/sda2',
        'shrinkCandidateFs': 'ntfs',
        'alongsideBlockers': ['ntfs_dirty'],
      };
      final ctx = makeContext(state, fake);

      final stage = const PartitioningStage();
      final result = await stage.execute(ctx);

      expect(result.success, false);
      expect(result.message, contains('ntfsfix'));
      expect(
        fake.wasCalledWith('ntfsresize', [
          '--force',
          '--size',
          '67095232512',
          '/dev/sda2',
        ]),
        false,
      );
    });

    test('NTFS resize basarisiz olursa GPT yedegini geri yukler', () async {
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
      fake.addResponse('ntfsresize', ['--info', '--force', '/dev/sda2']);
      fake.addResponse(
        'ntfsresize',
        ['--force', '--size', '67095232512', '/dev/sda2'],
        exitCode: 1,
        stderr: 'resize failed',
      );

      final state = {
        'selectedDisk': '/dev/sda',
        'partitionMethod': 'alongside',
        'diskBootMode': 'uefi',
        'diskPartitionTable': 'gpt',
        'hasExistingEfi': true,
        'existingEfiPartition': '/dev/sda1',
        'linuxDiskSizeGB': 80.0,
        'shrinkCandidatePartition': '/dev/sda2',
        'shrinkCandidateFs': 'ntfs',
      };
      final ctx = makeContext(state, fake);

      final stage = const PartitioningStage();
      final result = await stage.execute(ctx);

      expect(result.success, false);
      expect(
        fake.commandLog.any(
          (cmd) =>
              cmd.command == 'sgdisk' &&
              cmd.args.length == 2 &&
              cmd.args[0].startsWith(
                '--load-backup=/tmp/ro-installer-gpt-alongside-_dev_sda-',
              ) &&
              cmd.args[1] == '/dev/sda',
        ),
        true,
      );
      expect(fake.wasCommandCalled('parted'), false);
    });

    test('BTRFS kaynak bolumu guvenli sekilde kucultur', () async {
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
          "fstype": "btrfs"
        }
      ]
    }
  ]
}''',
      );
      fake.addResponse('sgdisk', ['-F', '/dev/sda'], stdout: '252708864');
      fake.addResponse('sgdisk', ['-E', '/dev/sda'], stdout: '299999966');
      fake.addResponse(
        'btrfs',
        [
          'filesystem',
          'show',
          '--raw',
          '/tmp/ro-installer-btrfs-shrink-_dev_sda2',
        ],
        stdout: '''
Label: none  uuid: 11111111-2222-3333-4444-555555555555
        Total devices 1 FS bytes used 40000000000
        devid    1 size 128849018880 used 50000000000 path /dev/sda2
''',
      );
      fake.addResponse('btrfs', [
        'inspect-internal',
        'min-dev-size',
        '/tmp/ro-installer-btrfs-shrink-_dev_sda2',
      ], stdout: '50000000000 bytes');

      final state = {
        'selectedDisk': '/dev/sda',
        'partitionMethod': 'alongside',
        'diskBootMode': 'uefi',
        'diskPartitionTable': 'gpt',
        'hasExistingEfi': true,
        'existingEfiPartition': '/dev/sda1',
        'linuxDiskSizeGB': 80.0,
        'shrinkCandidatePartition': '/dev/sda2',
        'shrinkCandidateFs': 'btrfs',
      };
      final ctx = makeContext(state, fake);

      final stage = const PartitioningStage();
      final result = await stage.execute(ctx);

      expect(result.success, true);
      expect(
        fake.wasCalledWith('mount', [
          '-o',
          'subvolid=5',
          '/dev/sda2',
          '/tmp/ro-installer-btrfs-shrink-_dev_sda2',
        ]),
        true,
      );
      expect(
        fake.wasCalledWith('btrfs', [
          'filesystem',
          'resize',
          '67095232512',
          '/tmp/ro-installer-btrfs-shrink-_dev_sda2',
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
    });
  });

  group('PartitioningStage — free space', () {
    test('secilen ayrilmis alanda SWAP ve Root olusturur', () async {
      final fake = FakeCommandRunner();
      fake.addResponse('grep', [
        'MemTotal',
        '/proc/meminfo',
      ], stdout: 'MemTotal:        4096000 kB');

      final state = {
        'selectedDisk': '/dev/sda',
        'partitionMethod': 'free_space',
        'hasExistingEfi': true,
        'existingEfiPartition': '/dev/sda1',
        'diskPartitionTable': 'gpt',
        'selectedFreeSpace': {
          'name': 'Free Space',
          'type': 'unallocated',
          'isFreeSpace': true,
          'sizeBytes': 64 * 1024 * 1024 * 1024,
          'startSector': 2048,
          'endSector': 134219775,
          'sectorSize': 512,
        },
      };
      final ctx = makeContext(state, fake);

      final stage = const PartitioningStage();
      final result = await stage.execute(ctx);

      expect(result.success, true);
      expect(fake.wasCommandCalled('ntfsresize'), false);
      expect(fake.wasCommandCalled('parted'), false);
      expect(
        fake.wasCalledWith('sgdisk', [
          '-n',
          '0:2048:16779263',
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
          '0:16779264:134219775',
          '-t',
          '0:8300',
          '-c',
          '0:RoASD_Root',
          '/dev/sda',
        ]),
        true,
      );
      expect(state['_resolvedSwapStartSector'], 2048);
      expect(state['_resolvedRootStartSector'], 16779264);
    });

    test('mevcut EFI yoksa baslamadan durur', () async {
      final fake = FakeCommandRunner();
      final state = {
        'selectedDisk': '/dev/sda',
        'partitionMethod': 'free_space',
        'hasExistingEfi': false,
        'existingEfiPartition': '',
        'selectedFreeSpace': {'startSector': 2048, 'endSector': 134219775},
      };
      final ctx = makeContext(state, fake);

      final stage = const PartitioningStage();
      final result = await stage.execute(ctx);

      expect(result.success, false);
      expect(
        fake.commandLog.any(
          (cmd) =>
              cmd.command == 'sgdisk' &&
              cmd.args.any((arg) => arg.startsWith('--backup=')),
        ),
        false,
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
          'type': 'btrfs',
          'mount': '/',
          'isFreeSpace': false,
          'isPlanned': true,
          'sizeBytes': 50000000000,
        },
        {
          'name': 'Free Space',
          'type': 'unallocated',
          'mount': 'unmounted',
          'isFreeSpace': true,
          'isPlanned': true,
          'sizeBytes': 85899345920,
          'deletedPartitionNames': ['/dev/sda2'],
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

    test(
      'plandan eksilen mevcut bolum acik delete marker yoksa silinmez',
      () async {
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

        final state = {
          'selectedDisk': '/dev/sda',
          'partitionMethod': 'manual',
          'manualPartitions': [
            {
              'name': '/dev/sda1',
              'type': 'fat32',
              'mount': '/boot/efi',
              'isFreeSpace': false,
              'isPlanned': false,
              'sizeBytes': 500000000,
            },
          ],
        };
        final ctx = makeContext(state, fake, isMock: true);

        final result = await const PartitioningStage().execute(ctx);

        expect(result.success, false);
        expect(result.message, contains('açık silme planı olmadan'));
        expect(fake.wasCalledWith('sgdisk', ['-d', '2', '/dev/sda']), false);
      },
    );

    test('resize planli mevcut BTRFS bolumu gercekten kucultur', () async {
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
      "size": 128849018880,
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
          "fstype": "btrfs"
        }
      ]
    }
  ]
}''',
      );

      final resizedBytes = 60 * 1024 * 1024 * 1024;
      final manualParts = [
        {
          'name': '/dev/sda1',
          'type': 'fat32',
          'mount': '/boot/efi',
          'isFreeSpace': false,
          'isPlanned': false,
          'sizeBytes': 536870912,
        },
        {
          'name': '/dev/sda2',
          'type': 'btrfs',
          'mount': 'unmounted',
          'isFreeSpace': false,
          'isPlanned': true,
          'isResized': true,
          'formatOnInstall': false,
          'sizeBytes': resizedBytes,
          'endSector': 126879743,
        },
      ];
      final state = {
        'selectedDisk': '/dev/sda',
        'partitionMethod': 'manual',
        'manualPartitions': manualParts,
      };
      fake.addResponse(
        'btrfs',
        [
          'filesystem',
          'show',
          '--raw',
          '/tmp/ro-installer-btrfs-shrink-_dev_sda2',
        ],
        stdout: '''
Label: none  uuid: 11111111-2222-3333-4444-555555555555
        Total devices 1 FS bytes used 40000000000
        devid    1 size 85899345920 used 50000000000 path /dev/sda2
''',
      );
      fake.addResponse('btrfs', [
        'inspect-internal',
        'min-dev-size',
        '/tmp/ro-installer-btrfs-shrink-_dev_sda2',
      ], stdout: '50000000000 bytes');
      final ctx = makeContext(state, fake);

      final stage = const PartitioningStage();
      final result = await stage.execute(ctx);

      expect(result.success, true);
      expect(
        fake.wasCalledWith('mount', [
          '-o',
          'subvolid=5',
          '/dev/sda2',
          '/tmp/ro-installer-btrfs-shrink-_dev_sda2',
        ]),
        true,
      );
      expect(
        fake.wasCalledWith('btrfs', [
          'filesystem',
          'resize',
          '64357400576',
          '/tmp/ro-installer-btrfs-shrink-_dev_sda2',
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
          '126879743s',
        ]),
        true,
      );
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
