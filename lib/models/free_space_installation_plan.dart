import 'gpt_disk_snapshot.dart';
import 'standard_storage_layout.dart';

/// Create-only intent. No executor, shared ESP writes, swap or shrink fallback.
final class FreeSpaceInstallationPlan {
  FreeSpaceInstallationPlan._(
    this.snapshot,
    this.selectedExtent,
    this.espNumber,
    this.rootNumber,
    this.espStart,
    this.espEnd,
    this.rootStart,
    this.rootEnd,
  );
  final GptDiskSnapshot snapshot;
  final FreeSectorExtent selectedExtent;
  final int espNumber, rootNumber, espStart, espEnd, rootStart, rootEnd;
  static const espTypeGuid = 'c12a7328-f81f-11d2-ba4b-00a0c93ec93b';
  static const linuxTypeGuid = '0fc63daf-8483-4772-8e79-3d69d8477de4';
  factory FreeSpaceInstallationPlan.build(
    GptDiskSnapshot snapshot,
    FreeSectorExtent extent,
  ) {
    final current = snapshot.freeExtents.where(
      (e) =>
          e.startSector == extent.startSector &&
          e.endSector == extent.endSector,
    );
    if (current.length != 1) {
      throw const FormatException('Select a current complete free extent');
    }
    final used = snapshot.partitions.map((p) => p.number).toSet();
    final slots = <int>[];
    for (var n = 1; n <= snapshot.entryCount && slots.length < 2; n++) {
      if (!used.contains(n)) slots.add(n);
    }
    if (slots.length != 2) {
      throw const FormatException('Two GPT slots required');
    }
    final align = 1048576 ~/ snapshot.logicalSectorBytes;
    final start = ((extent.startSector + align - 1) ~/ align) * align;
    final espSectors =
        StandardStorageLayout.espBytes ~/ snapshot.logicalSectorBytes;
    final espEnd = start + espSectors - 1;
    final rootStart = espEnd + 1;
    final end = ((extent.endSector + 1) ~/ align) * align - 1;
    if (rootStart > end ||
        (end - rootStart + 1) * snapshot.logicalSectorBytes <
            StandardStorageLayout.temporaryMinimumRootBytes) {
      throw const FormatException(
        'Free extent is below the aligned safety floor',
      );
    }
    return FreeSpaceInstallationPlan._(
      snapshot,
      FreeSectorExtent(extent.startSector, extent.endSector),
      slots[0],
      slots[1],
      start,
      espEnd,
      rootStart,
      end,
    );
  }
  String _partitionPath(int number) {
    final disk = snapshot.device.path;
    final separator =
        disk.contains('nvme') ||
            disk.contains('mmcblk') ||
            disk.contains('loop')
        ? 'p'
        : '';
    return '$disk$separator$number';
  }

  bool matchesSnapshot(GptDiskSnapshot current) => snapshot.sameAs(current);

  /// Bounded intent for helper revalidation; never sends a full inventory as
  /// executable instructions. The helper independently rebuilds this layout.
  Map<String, dynamic> get intentJson => {
    'schemaVersion': 1,
    'mode': 'free_space',
    'device': snapshot.device.json,
    'tableFingerprint': snapshot.tableFingerprint,
    'selectedExtent': selectedExtent.json,
    'fileSystem': 'btrfs',
    'diskSwap': false,
    'esp': {'number': espNumber, 'startSector': espStart, 'endSector': espEnd},
    'root': {
      'number': rootNumber,
      'startSector': rootStart,
      'endSector': rootEnd,
    },
  };
  Map<String, dynamic> get json => {
    'schemaVersion': 1,
    'mode': 'free_space',
    'fileSystem': 'btrfs',
    'diskSwap': false,
    'snapshot': snapshot.json,
    'selectedExtent': selectedExtent.json,
    'subvolumes': Map<String, String>.of(StandardStorageLayout.subvolumes),
    'preservedPartitions': snapshot.partitions.map((p) => p.json).toList(),
    'operations': [
      {
        'type': 'create_efi',
        'number': espNumber,
        'target': _partitionPath(espNumber),
        'startSector': espStart,
        'endSector': espEnd,
        'typeGuid': espTypeGuid,
      },
      {
        'type': 'create_btrfs_root',
        'number': rootNumber,
        'target': _partitionPath(rootNumber),
        'startSector': rootStart,
        'endSector': rootEnd,
        'typeGuid': linuxTypeGuid,
      },
      {
        'type': 'format_efi',
        'target': _partitionPath(espNumber),
        'fileSystem': 'fat32',
      },
      {
        'type': 'format_btrfs_root',
        'target': _partitionPath(rootNumber),
        'fileSystem': 'btrfs',
      },
    ],
  };
}
