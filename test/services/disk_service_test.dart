import 'dart:io';
import 'package:test/test.dart';
import 'package:ro_installer/services/disk_service.dart';
import 'package:ro_installer/services/fake_command_runner.dart';

/// Fixture dosyasını okur
String fixture(String name) {
  return File('test/fixtures/$name').readAsStringSync();
}

void main() {
  group('DiskService.getDisks()', () {
    test('tek diskli sistem doğru parse edilir', () async {
      final fake = FakeCommandRunner();
      fake.addResponse('lsblk', [
        '-J',
        '-b',
        '-o',
        'NAME,MODEL,SIZE,TYPE,RM,MOUNTPOINTS',
      ], stdout: fixture('lsblk_single_disk.json'));

      final service = DiskService(commandRunner: fake);
      final disks = await service.getDisks();

      expect(disks.length, 1);
      expect(disks[0]['name'], '/dev/sda');
      expect(disks[0]['model'], 'VBOX HARDDISK');
      expect(disks[0]['size'], 107374182400);
      expect(disks[0]['isLive'], false);
      expect(disks[0]['isHostOS'], false);
    });

    test('çok diskli sistemde live USB doğru tespit edilir', () async {
      final fake = FakeCommandRunner();
      fake.addResponse('lsblk', [
        '-J',
        '-b',
        '-o',
        'NAME,MODEL,SIZE,TYPE,RM,MOUNTPOINTS',
      ], stdout: fixture('lsblk_multi_disk.json'));

      final service = DiskService(commandRunner: fake);
      final disks = await service.getDisks();

      expect(disks.length, 3);

      // sda — host OS (/ mount edilmiş)
      final sda = disks.firstWhere((d) => d['name'] == '/dev/sda');
      expect(sda['isHostOS'], true);
      expect(sda['isLive'], false);

      // sdc — live USB (removable + /run/initramfs/live)
      final sdc = disks.firstWhere((d) => d['name'] == '/dev/sdc');
      expect(sdc['isLive'], true);

      // sdb — veri diski
      final sdb = disks.firstWhere((d) => d['name'] == '/dev/sdb');
      expect(sdb['isLive'], false);
      expect(sdb['isHostOS'], false);
    });

    test('NVMe disk doğru parse edilir', () async {
      final fake = FakeCommandRunner();
      fake.addResponse('lsblk', [
        '-J',
        '-b',
        '-o',
        'NAME,MODEL,SIZE,TYPE,RM,MOUNTPOINTS',
      ], stdout: fixture('lsblk_nvme.json'));

      final service = DiskService(commandRunner: fake);
      final disks = await service.getDisks();

      expect(disks.length, 1);
      expect(disks[0]['name'], '/dev/nvme0n1');
      expect(disks[0]['model'], 'Samsung 980 PRO 1TB');
    });

    test('lsblk başarısız olursa boş liste döner', () async {
      final fake = FakeCommandRunner();
      fake.addResponse(
        'lsblk',
        ['-J', '-b', '-o', 'NAME,MODEL,SIZE,TYPE,RM,MOUNTPOINTS'],
        exitCode: 1,
        stderr: 'lsblk: command not found',
      );

      final service = DiskService(commandRunner: fake);
      final disks = await service.getDisks();

      expect(disks, isEmpty);
    });

    test('loop ve zram diskler filtrelenir', () async {
      final fake = FakeCommandRunner();
      fake.addResponse(
        'lsblk',
        ['-J', '-b', '-o', 'NAME,MODEL,SIZE,TYPE,RM,MOUNTPOINTS'],
        stdout: '''
{
  "blockdevices": [
    {"name": "loop0", "model": null, "size": 1073741824, "type": "disk", "rm": false, "mountpoints": [null]},
    {"name": "zram0", "model": null, "size": 1073741824, "type": "disk", "rm": false, "mountpoints": [null]},
    {"name": "sr0", "model": "DVD", "size": 1073741824, "type": "disk", "rm": true, "mountpoints": [null]},
    {"name": "sda", "model": "Disk", "size": 107374182400, "type": "disk", "rm": false, "mountpoints": [null]}
  ]
}''',
      );

      final service = DiskService(commandRunner: fake);
      final disks = await service.getDisks();

      expect(disks.length, 1);
      expect(disks[0]['name'], '/dev/sda');
    });
  });

  group('DiskService.detectDiskDetails()', () {
    test('Windows kurulu disk doğru algılanır', () async {
      final fake = FakeCommandRunner();
      fake.addResponse('lsblk', [
        '-J',
        '-b',
        '-o',
        'NAME,FSTYPE,SIZE,START,PARTTYPE,PTTYPE,MOUNTPOINTS',
        '/dev/sda',
      ], stdout: fixture('lsblk_disk_with_windows.json'));
      // sgdisk print yanıtı da ekle
      fake.addResponseForCommand('sgdisk', stdout: '', exitCode: 0);

      final service = DiskService(commandRunner: fake);
      final details = await service.detectDiskDetails('/dev/sda');

      expect(details['hasExistingOS'], true);
      expect(details['detectedOS'], 'Windows');
      expect(details['hasEfiPartition'], true);
      expect(details['efiPartitionName'], '/dev/sda1');
      expect(details['bootMode'], 'uefi');
      expect(details['partitionTable'], 'gpt');
      expect(details['shrinkCandidatePartition'], '/dev/sda2');
      expect(details['shrinkCandidateFs'], 'ntfs');
      expect(details['alongsideMaxLinuxSizeBytes'], 42949672960);
      expect((details['alongsideBlockers'] as List<dynamic>), isEmpty);
    });

    test('boş disk algılandığında OS yok döner', () async {
      final fake = FakeCommandRunner();
      fake.addResponse(
        'lsblk',
        [
          '-J',
          '-b',
          '-o',
          'NAME,FSTYPE,SIZE,START,PARTTYPE,PTTYPE,MOUNTPOINTS',
          '/dev/sda',
        ],
        stdout: '''
{
  "blockdevices": [
    {"name": "sda", "size": 107374182400, "pttype": "gpt", "children": []}
  ]
}''',
      );
      fake.addResponseForCommand('sgdisk', stdout: '', exitCode: 0);

      final service = DiskService(commandRunner: fake);
      final details = await service.detectDiskDetails('/dev/sda');

      expect(details['hasExistingOS'], false);
      expect(details['detectedOS'], '');
      expect(details['hasEfiPartition'], false);
      expect(
        (details['alongsideBlockers'] as List<dynamic>).map(
          (entry) => entry.toString(),
        ),
        containsAll(['no_existing_os', 'missing_efi']),
      );
    });

    test(
      'BitLocker algılanırsa alongside güvenlik nedeniyle kilitlenir',
      () async {
        final fake = FakeCommandRunner();
        fake.addResponse(
          'lsblk',
          [
            '-J',
            '-b',
            '-o',
            'NAME,FSTYPE,SIZE,START,PARTTYPE,PTTYPE,MOUNTPOINTS',
            '/dev/nvme0n1',
          ],
          stdout: '''
{
  "blockdevices": [
    {
      "name": "nvme0n1",
      "size": 512110190592,
      "pttype": "gpt",
      "children": [
        {
          "name": "nvme0n1p1",
          "fstype": "vfat",
          "size": 536870912,
          "start": 0,
          "parttype": "c12a7328-f81f-11d2-ba4b-00a0c93ec93b",
          "mountpoints": [null]
        },
        {
          "name": "nvme0n1p3",
          "fstype": "",
          "size": 400000000000,
          "start": 1048576,
          "parttype": "ebd0a0a2-b9e5-4433-87c0-68b6b72699c7",
          "mountpoints": [null]
        }
      ]
    }
  ]
}''',
        );
        fake.addResponse('blkid', [
          '-s',
          'TYPE',
          '-o',
          'value',
          '/dev/nvme0n1p1',
        ], stdout: 'vfat');
        fake.addResponse('blkid', [
          '-s',
          'TYPE',
          '-o',
          'value',
          '/dev/nvme0n1p3',
        ], stdout: 'BitLocker');
        fake.addResponseForCommand('sgdisk', stdout: '', exitCode: 0);

        final service = DiskService(commandRunner: fake);
        final details = await service.detectDiskDetails('/dev/nvme0n1');

        expect(details['hasExistingOS'], false);
        expect(details['shrinkCandidatePartition'], '');
        expect(
          (details['alongsideBlockers'] as List<dynamic>).map(
            (entry) => entry.toString(),
          ),
          containsAll(['bitlocker_enabled', 'no_existing_os']),
        );
      },
    );
  });
}
