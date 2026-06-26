import 'package:ro_installer/models/storage_plan.dart';
import 'package:test/test.dart';

void main() {
  group('StoragePlanBuilder', () {
    test('full disk Btrfs plan destructive wipe operasyonu uretir', () {
      final plan = StoragePlanBuilder.fromState({
        'selectedDisk': '/dev/sda',
        'partitionMethod': 'full',
        'fileSystem': 'btrfs',
      });

      expect(plan.mode, 'full');
      expect(plan.fileSystem, 'btrfs');
      expect(plan.operations.map((op) => op.type), contains('wipe_disk'));
      expect(plan.destructiveOperations.map((op) => op.type), [
        'wipe_disk',
        'create_efi',
        'create_swap',
        'create_btrfs_root',
        'format_efi',
        'format_swap',
        'format_btrfs_root',
      ]);
    });

    test('Btrfs disi root dosya sistemi reddedilir', () {
      expect(
        () => StoragePlanBuilder.fromState({
          'selectedDisk': '/dev/sda',
          'partitionMethod': 'full',
          'fileSystem': 'ext4',
        }),
        throwsA(isA<StoragePlanException>()),
      );
    });

    test(
      'manual plan acik delete operasyonu ve Btrfs mount sozlesmesi uretir',
      () {
        final plan = StoragePlanBuilder.fromState({
          'selectedDisk': '/dev/sda',
          'partitionMethod': 'manual',
          'fileSystem': 'btrfs',
          'manualPartitions': [
            {
              'name': 'Free Space',
              'type': 'unallocated',
              'mount': 'unmounted',
              'isFreeSpace': true,
              'deletedPartitionNames': ['/dev/sda2'],
            },
            {
              'name': '/dev/sda3',
              'type': 'btrfs',
              'mount': '/',
              'isPlanned': true,
              'formatOnInstall': true,
            },
          ],
        });

        expect(plan.operations.first.type, 'delete_partition');
        expect(plan.operations.first.target, '/dev/sda2');
        expect(plan.operations.first.destructive, true);
        expect(plan.operations.last.type, 'format_partition');
        expect(plan.operations.last.details['fsType'], 'btrfs');
        expect(
          plan.hasOperation(
            'format_partition',
            '/dev/sda3',
            destructiveOnly: true,
            details: {'fsType': 'btrfs', 'mount': '/'},
          ),
          true,
        );
      },
    );

    test('manual resize ayri destructive operasyon olarak isaretlenir', () {
      final plan = StoragePlanBuilder.fromState({
        'selectedDisk': '/dev/sda',
        'partitionMethod': 'manual',
        'fileSystem': 'btrfs',
        'manualPartitions': [
          {
            'name': '/dev/sda2',
            'type': 'btrfs',
            'mount': 'unmounted',
            'isResized': true,
            'sizeBytes': 64 * 1024 * 1024 * 1024,
          },
        ],
      });

      expect(plan.operations.single.type, 'resize_partition');
      expect(plan.operations.single.destructive, true);
      expect(
        plan.hasOperation(
          'resize_partition',
          '/dev/sda2',
          destructiveOnly: true,
        ),
        true,
      );
    });
  });
}
