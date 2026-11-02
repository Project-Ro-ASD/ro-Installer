import '../services/helper_protocol.dart';
import 'gpt_disk_snapshot.dart';
import 'manual_installation_plan.dart';
import 'standard_storage_layout.dart';

/// Pure geometry proposal, never filesystem evidence or mutation authority.
/// A privileged assessment must independently establish NTFS safety/minimums.
final class NtfsShrinkInstallationPlan {
  NtfsShrinkInstallationPlan._(
    this.snapshot,
    this.source,
    this.esp,
    this.rootBytes,
    this.minimumFilesystemBytes,
    this.sourceEnd,
    this.rootNumber,
    this.rootStart,
    this.rootEnd,
  );
  static const basicDataTypeGuid = 'ebd0a0a2-b9e5-4433-87c0-68b6b72699c7';
  static const sourceSafetyMarginBytes = 1024 * 1024 * 1024;
  // Conservative proposal floor; not an operating-system support minimum.
  static const minimumRetainedSourceBytes = 40 * 1024 * 1024 * 1024;
  final GptDiskSnapshot snapshot;
  final GptPartitionSnapshot source, esp;
  final int rootBytes,
      minimumFilesystemBytes,
      sourceEnd,
      rootNumber,
      rootStart,
      rootEnd;
  int get retainedSourceBytes =>
      (sourceEnd - source.startSector + 1) * snapshot.logicalSectorBytes;
  int get shrinkBytes =>
      (source.endSector - sourceEnd) * snapshot.logicalSectorBytes;

  factory NtfsShrinkInstallationPlan.build({
    required GptDiskSnapshot snapshot,
    required int sourceNumber,
    required int espNumber,
    required int rootBytes,
    required int minimumFilesystemBytes,
  }) {
    GptPartitionSnapshot partition(int number) {
      final rows = snapshot.partitions.where((p) => p.number == number);
      if (rows.length != 1) {
        throw const FormatException('Select an observed partition');
      }
      return rows.single;
    }

    final source = partition(sourceNumber), esp = partition(espNumber);
    final sector = snapshot.logicalSectorBytes,
        align = 1048576 ~/ snapshot.logicalSectorBytes;
    final originalBytes = (source.endSector - source.startSector + 1) * sector;
    if (sourceNumber == espNumber ||
        source.typeGuid != basicDataTypeGuid ||
        esp.typeGuid != ManualInstallationPlan.espTypeGuid ||
        source.attributesHex != '0000000000000000' ||
        esp.attributesHex != '0000000000000000' ||
        source.startSector % align != 0 ||
        (esp.endSector - esp.startSector + 1) * sector <
            StandardStorageLayout.espBytes) {
      throw const FormatException(
        'Unsupported source or reusable ESP geometry',
      );
    }
    snapshotInteger(
      rootBytes,
      StandardStorageLayout.temporaryMinimumRootBytes,
      maximumSnapshotBytes,
    );
    snapshotInteger(minimumFilesystemBytes, 1, originalBytes);
    if (rootBytes % 1048576 != 0 || snapshot.partitions.length >= 32) {
      throw const FormatException(
        'Root must be MiB aligned with room for one new GPT entry',
      );
    }
    final occupied = snapshot.partitions.map((p) => p.number).toSet();
    var slot = 1;
    while (occupied.contains(slot)) {
      slot++;
    }
    if (slot > snapshot.entryCount) {
      throw const FormatException('No free GPT slot');
    }
    // Extend only into the gap immediately following the selected source.
    // Recovery/data partitions beyond that gap are never moved or consumed.
    var exclusiveEnd = source.endSector + 1;
    for (final gap in snapshot.freeExtents) {
      if (gap.startSector == exclusiveEnd) {
        exclusiveEnd = gap.endSector + 1;
        break;
      }
    }
    exclusiveEnd = exclusiveEnd ~/ align * align;
    final rootStart = exclusiveEnd - rootBytes ~/ sector;
    if (rootStart > source.endSector) {
      throw const FormatException(
        'Shrink unnecessary; use create-only free space',
      );
    }
    final sourceEnd = rootStart - 1;
    final retained = (sourceEnd - source.startSector + 1) * sector;
    if (rootStart <= source.startSector ||
        retained < minimumRetainedSourceBytes ||
        retained < minimumFilesystemBytes + sourceSafetyMarginBytes) {
      throw const FormatException('Insufficient retained source capacity');
    }
    return NtfsShrinkInstallationPlan._(
      snapshot,
      source,
      esp,
      rootBytes,
      minimumFilesystemBytes,
      sourceEnd,
      slot,
      rootStart,
      exclusiveEnd - 1,
    );
  }

  factory NtfsShrinkInstallationPlan.fromJson(Object? input) {
    if (input is! Map<String, dynamic> ||
        !exactFields(input, {
          'schemaVersion',
          'snapshot',
          'sourceNumber',
          'espNumber',
          'rootBytes',
          'minimumFilesystemBytes',
        }) ||
        input['schemaVersion'] is! int ||
        input['schemaVersion'] != 1) {
      throw const FormatException('Invalid NTFS shrink proposal');
    }
    return NtfsShrinkInstallationPlan.build(
      snapshot: GptDiskSnapshot.fromJson(input['snapshot']),
      sourceNumber: snapshotInteger(input['sourceNumber'], 1, 4096),
      espNumber: snapshotInteger(input['espNumber'], 1, 4096),
      rootBytes: snapshotInteger(input['rootBytes'], 1, maximumSnapshotBytes),
      minimumFilesystemBytes: snapshotInteger(
        input['minimumFilesystemBytes'],
        1,
        maximumSnapshotBytes,
      ),
    );
  }
  bool matchesSnapshot(GptDiskSnapshot current) => snapshot.sameAs(current);
  Map<String, dynamic> get json => {
    'schemaVersion': 1,
    'snapshot': snapshot.json,
    'sourceNumber': source.number,
    'espNumber': esp.number,
    'rootBytes': rootBytes,
    'minimumFilesystemBytes': minimumFilesystemBytes,
  };
  Map<String, dynamic> get intentJson => {
    'schemaVersion': 1,
    'layoutVersion': 1,
    'mode': 'alongside_ntfs_shrink',
    'device': snapshot.device.json,
    'tableFingerprint': snapshot.tableFingerprint,
    'fileSystem': 'btrfs',
    'diskSwap': false,
    'subvolumes': Map<String, String>.of(StandardStorageLayout.subvolumes),
    'source': {
      ...source.json,
      'newEndSector': sourceEnd,
      'minimumFilesystemBytes': minimumFilesystemBytes,
      'retainedBytes': retainedSourceBytes,
    },
    'esp': {...esp.json, 'formatOnInstall': false},
    'root': {
      'number': rootNumber,
      'startSector': rootStart,
      'endSector': rootEnd,
      'typeGuid': ManualInstallationPlan.rootTypeGuid,
      'formatOnInstall': true,
    },
  };
}
