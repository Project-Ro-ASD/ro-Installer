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
      expect(plan.operations.last.target, '/dev/sda2');
      expect(plan.operations.any((op) => op.type.contains('swap')), isFalse);
      expect(plan.operations.map((op) => op.type), contains('wipe_disk'));
      expect(plan.destructiveOperations.map((op) => op.type), [
        'wipe_disk',
        'create_efi',
        'create_btrfs_root',
        'format_efi',
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

    for (final patch in [
      {
        'deletedPartitionNames': ['/dev/sda2'],
        'isFreeSpace': true,
      },
      {
        'name': '/dev/sda2',
        'isResized': true,
        'sizeBytes': 64 * 1024 * 1024 * 1024,
      },
    ]) {
      test(
        'legacy manual maps cannot produce destructive operations: $patch',
        () {
          expect(
            () => StoragePlanBuilder.fromState({
              'selectedDisk': '/dev/sda',
              'partitionMethod': 'manual',
              'fileSystem': 'btrfs',
              'manualPartitions': [patch],
            }),
            throwsA(isA<StoragePlanException>()),
          );
        },
      );
    }
  });
}
