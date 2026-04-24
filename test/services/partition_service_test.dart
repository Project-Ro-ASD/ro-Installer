import 'package:test/test.dart';
import 'package:ro_installer/services/partition_service.dart';
import 'package:ro_installer/services/fake_command_runner.dart';

void main() {
  group('PartitionService.getPartitions()', () {
    test('bölümlü disk doğru parse edilir', () async {
      final fake = FakeCommandRunner();
      fake.addResponse(
        'lsblk',
        ['-J', '-b', '-o', 'NAME,FSTYPE,SIZE,MOUNTPOINT,PARTFLAGS', '/dev/sda'],
        stdout: '''
{
  "blockdevices": [
    {
      "name": "sda",
      "size": 107374182400,
      "children": [
        {
          "name": "sda1",
          "fstype": "vfat",
          "size": 536870912,
          "mountpoints": [null],
          "partflags": ""
        },
        {
          "name": "sda2",
          "fstype": "btrfs",
          "size": 106837311488,
          "mountpoints": [null],
          "partflags": ""
        }
      ]
    }
  ]
}''',
      );

      final service = PartitionService(commandRunner: fake);
      final partitions = await service.getPartitions('/dev/sda');

      expect(partitions.length, 2);
      expect(partitions[0]['name'], '/dev/sda1');
      expect(partitions[0]['type'], 'fat32');
      expect(partitions[0]['mount'], 'unmounted');
      expect(partitions[0]['currentMount'], 'unmounted');
      expect(partitions[0]['formatOnInstall'], false);
      expect(partitions[1]['name'], '/dev/sda2');
      expect(partitions[1]['type'], 'btrfs');
    });

    test('boş alan varsa Free Space eklenir', () async {
      final fake = FakeCommandRunner();
      fake.addResponse(
        'lsblk',
        ['-J', '-b', '-o', 'NAME,FSTYPE,SIZE,MOUNTPOINT,PARTFLAGS', '/dev/sda'],
        stdout: '''
{
  "blockdevices": [
    {
      "name": "sda",
      "size": 107374182400,
      "children": [
        {
          "name": "sda1",
          "fstype": "vfat",
          "size": 536870912,
          "mountpoints": [null],
          "partflags": ""
        }
      ]
    }
  ]
}''',
      );

      final service = PartitionService(commandRunner: fake);
      final partitions = await service.getPartitions('/dev/sda');

      expect(partitions.length, 2);
      expect(partitions[1]['name'], 'Free Space');
      expect(partitions[1]['isFreeSpace'], true);
      expect(partitions[1]['currentMount'], 'unmounted');
      expect(partitions[1]['formatOnInstall'], false);
      // 107374182400 - 536870912 = 106837311488
      expect(partitions[1]['sizeBytes'], 106837311488);
    });

    test('ham disk (bölümsüz) tek Free Space döner', () async {
      final fake = FakeCommandRunner();
      fake.addResponse(
        'lsblk',
        ['-J', '-b', '-o', 'NAME,FSTYPE,SIZE,MOUNTPOINT,PARTFLAGS', '/dev/sda'],
        stdout: '''
{
  "blockdevices": [
    {
      "name": "sda",
      "size": 107374182400
    }
  ]
}''',
      );

      final service = PartitionService(commandRunner: fake);
      final partitions = await service.getPartitions('/dev/sda');

      expect(partitions.length, 1);
      expect(partitions[0]['name'], 'Free Space');
      expect(partitions[0]['isFreeSpace'], true);
      expect(partitions[0]['currentMount'], 'unmounted');
      expect(partitions[0]['sizeBytes'], 107374182400);
    });

    test('10 MB altındaki boş alan eklenmez', () async {
      final fake = FakeCommandRunner();
      fake.addResponse(
        'lsblk',
        ['-J', '-b', '-o', 'NAME,FSTYPE,SIZE,MOUNTPOINT,PARTFLAGS', '/dev/sda'],
        stdout: '''
{
  "blockdevices": [
    {
      "name": "sda",
      "size": 107374182400,
      "children": [
        {
          "name": "sda1",
          "fstype": "ext4",
          "size": 107373133824,
          "mountpoints": [null],
          "partflags": ""
        }
      ]
    }
  ]
}''',
      );

      final service = PartitionService(commandRunner: fake);
      final partitions = await service.getPartitions('/dev/sda');

      // Boş alan < 10 MB olduğu için Free Space eklenmemeli
      expect(partitions.length, 1);
      expect(partitions[0]['name'], '/dev/sda1');
    });

    test('lsblk başarısız olursa boş liste döner', () async {
      final fake = FakeCommandRunner();
      fake.addResponse(
        'lsblk',
        ['-J', '-b', '-o', 'NAME,FSTYPE,SIZE,MOUNTPOINT,PARTFLAGS', '/dev/sda'],
        exitCode: 1,
        stderr: 'error',
      );

      final service = PartitionService(commandRunner: fake);
      final partitions = await service.getPartitions('/dev/sda');

      expect(partitions, isEmpty);
    });
  });
}
