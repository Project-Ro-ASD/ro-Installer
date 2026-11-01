import '../services/helper_protocol.dart';
import 'approved_full_disk_plan.dart';
import 'gpt_disk_snapshot.dart';
import 'standard_storage_layout.dart';

enum ManualPartitionSource { existing, create }

/// A selection, not a device path, filesystem claim or executable operation.
final class ManualPartitionChoice {
  const ManualPartitionChoice.existing({
    required int number,
    required bool formatOnInstall,
  }) : this._(
         ManualPartitionSource.existing,
         number,
         null,
         null,
         formatOnInstall,
       );

  const ManualPartitionChoice.create({
    required int startSector,
    required int endSector,
  }) : this._(ManualPartitionSource.create, null, startSector, endSector, true);

  const ManualPartitionChoice._(
    this.source,
    this.number,
    this.startSector,
    this.endSector,
    this.formatOnInstall,
  );

  final ManualPartitionSource source;
  final int? number, startSector, endSector;
  final bool formatOnInstall;

  factory ManualPartitionChoice.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Invalid manual selection');
    }
    if (value['source'] == 'existing' &&
        exactFields(value, {'source', 'number', 'formatOnInstall'}) &&
        value['formatOnInstall'] is bool) {
      return ManualPartitionChoice.existing(
        number: snapshotInteger(value['number'], 1, 4096),
        formatOnInstall: value['formatOnInstall'] as bool,
      );
    }
    if (value['source'] == 'create' &&
        exactFields(value, {'source', 'startSector', 'endSector'})) {
      final start = snapshotInteger(
        value['startSector'],
        0,
        maximumSnapshotBytes,
      );
      return ManualPartitionChoice.create(
        startSector: start,
        endSector: snapshotInteger(
          value['endSector'],
          start,
          maximumSnapshotBytes,
        ),
      );
    }
    throw const FormatException('Unsupported manual selection');
  }

  Map<String, dynamic> get json => source == ManualPartitionSource.existing
      ? {
          'source': 'existing',
          'number': number,
          'formatOnInstall': formatOnInstall,
        }
      : {
          'source': 'create',
          'startSector': startSector,
          'endSector': endSector,
        };
}

enum ManualPartitionRole { esp, root }

/// Resolved from the snapshot; callers cannot supply paths, GUIDs or flags.
final class ManualPartitionBinding {
  const ManualPartitionBinding._(
    this.role,
    this.choice,
    this.number,
    this.startSector,
    this.endSector,
    this.existingPartition,
    this.disk,
  );
  final ManualPartitionRole role;
  final ManualPartitionChoice choice;
  final int number, startSector, endSector;
  final GptPartitionSnapshot? existingPartition;
  final String disk;
  bool get isNew => choice.source == ManualPartitionSource.create;
  bool get formatOnInstall => choice.formatOnInstall;
  String get fileSystem => role == ManualPartitionRole.esp ? 'fat32' : 'btrfs';
  String get mountPoint => role == ManualPartitionRole.esp ? '/boot/efi' : '/';
  String get typeGuid => role == ManualPartitionRole.esp
      ? ManualInstallationPlan.espTypeGuid
      : ManualInstallationPlan.rootTypeGuid;
  String get target =>
      '$disk${RegExp(r'[0-9]$').hasMatch(disk) ? 'p' : ''}$number';
  Map<String, dynamic> get json => {
    'source': isNew ? 'create' : 'existing',
    'number': number,
    'startSector': startSector,
    'endSector': endSector,
    'typeGuid': typeGuid,
    if (existingPartition != null)
      'partitionGuid': existingPartition!.partitionGuid,
    if (existingPartition != null)
      'attributesHex': existingPartition!.attributesHex,
    'fileSystem': fileSystem,
    'mountPoint': mountPoint,
    'formatOnInstall': formatOnInstall,
  };
}

enum ManualOperationKind { createPartition, formatPartition, reuseEsp }

final class ManualPlanOperation {
  const ManualPlanOperation._(this.kind, this.partition);
  final ManualOperationKind kind;
  final ManualPartitionBinding partition;
  // Reuse preserves the filesystem, but later boot-file writes still need
  // authoritative admission. It does not mean this partition is untouched.
  bool get destructive => kind != ManualOperationKind.reuseEsp;
  Map<String, dynamic> get json => {
    'type': switch (kind) {
      ManualOperationKind.createPartition => 'create_partition',
      ManualOperationKind.formatPartition => 'format_partition',
      ManualOperationKind.reuseEsp => 'reuse_esp',
    },
    'target': partition.target,
    'destructive': destructive,
    'partition': partition.json,
  };
}

/// Pure planning input. No helper admission, disk access or legacy-state adapter.
/// Filesystem type, ESP capacity and safe reuse require fresh privileged probes.
final class ManualInstallationPlan {
  ManualInstallationPlan._(this.snapshot, this.esp, this.root);
  static const espTypeGuid = 'c12a7328-f81f-11d2-ba4b-00a0c93ec93b';
  static const rootTypeGuid = '0fc63daf-8483-4772-8e79-3d69d8477de4';
  static const maximumOccupiedPartitions = 32;
  final GptDiskSnapshot snapshot;
  final ManualPartitionBinding esp, root;

  factory ManualInstallationPlan.build({
    required GptDiskSnapshot snapshot,
    required ManualPartitionChoice esp,
    required ManualPartitionChoice root,
  }) {
    if (!root.formatOnInstall) {
      throw const FormatException('Manual root requires explicit formatting');
    }
    final additions = [
      esp,
      root,
    ].where((c) => c.source == ManualPartitionSource.create).length;
    if (snapshot.partitions.length + additions > maximumOccupiedPartitions) {
      throw const FormatException('Manual plan exceeds probe inventory limit');
    }
    final used = snapshot.partitions.map((p) => p.number).toSet();
    ManualPartitionBinding resolve(
      ManualPartitionRole role,
      ManualPartitionChoice choice,
    ) {
      late final int number, start, end;
      GptPartitionSnapshot? existing;
      if (choice.source == ManualPartitionSource.existing) {
        final selected = snapshot.partitions.where(
          (p) => p.number == choice.number,
        );
        if (selected.length != 1) {
          throw const FormatException(
            'Selected partition is not in this snapshot',
          );
        }
        existing = selected.single;
        final expectedType = role == ManualPartitionRole.esp
            ? espTypeGuid
            : rootTypeGuid;
        if (existing.typeGuid != expectedType ||
            existing.attributesHex != '0000000000000000') {
          throw const FormatException(
            'Unsupported writable partition type or attributes',
          );
        }
        number = existing.number;
        start = existing.startSector;
        end = existing.endSector;
      } else {
        start = snapshotInteger(
          choice.startSector,
          snapshot.firstUsableSector,
          snapshot.lastUsableSector,
        );
        end = snapshotInteger(
          choice.endSector,
          start,
          snapshot.lastUsableSector,
        );
        final alignment = 1024 * 1024 ~/ snapshot.logicalSectorBytes;
        if (start % alignment != 0 ||
            (end + 1) % alignment != 0 ||
            !snapshot.freeExtents.any(
              (gap) => start >= gap.startSector && end <= gap.endSector,
            )) {
          throw const FormatException(
            'New partition must be aligned inside a current free extent',
          );
        }
        var slot = 1;
        while (used.contains(slot)) {
          slot++;
        }
        if (slot > snapshot.entryCount) {
          throw const FormatException('No unused GPT slot');
        }
        number = slot;
        used.add(slot);
      }
      final minimum = role == ManualPartitionRole.esp
          ? StandardStorageLayout.espBytes
          : StandardStorageLayout.temporaryMinimumRootBytes;
      if ((end - start + 1) * snapshot.logicalSectorBytes < minimum) {
        throw const FormatException(
          'Selected partition is below the safety floor',
        );
      }
      return ManualPartitionBinding._(
        role,
        choice,
        number,
        start,
        end,
        existing,
        snapshot.device.path,
      );
    }

    // Slot allocation is stable regardless of JSON map order or physical order.
    final resolvedEsp = resolve(ManualPartitionRole.esp, esp);
    final resolvedRoot = resolve(ManualPartitionRole.root, root);
    if (resolvedEsp.number == resolvedRoot.number ||
        (resolvedEsp.startSector <= resolvedRoot.endSector &&
            resolvedRoot.startSector <= resolvedEsp.endSector)) {
      throw const FormatException('Manual roles overlap');
    }
    return ManualInstallationPlan._(snapshot, resolvedEsp, resolvedRoot);
  }

  factory ManualInstallationPlan.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        !exactFields(value, {
          'schemaVersion',
          'mode',
          'snapshot',
          'esp',
          'root',
        }) ||
        value['schemaVersion'] is! int ||
        value['schemaVersion'] != 1 ||
        value['mode'] != 'manual') {
      throw const FormatException('Invalid manual plan');
    }
    return ManualInstallationPlan.build(
      snapshot: GptDiskSnapshot.fromJson(value['snapshot']),
      esp: ManualPartitionChoice.fromJson(value['esp']),
      root: ManualPartitionChoice.fromJson(value['root']),
    );
  }

  /// Only unselected partitions are untouched, including their filesystems.
  List<GptPartitionSnapshot> get untouchedPartitions => List.unmodifiable(
    snapshot.partitions.where(
      (p) =>
          p.number != esp.existingPartition?.number &&
          p.number != root.existingPartition?.number,
    ),
  );
  List<ManualPlanOperation> get operations => List.unmodifiable([
    for (final part in [esp, root])
      if (part.isNew)
        ManualPlanOperation._(ManualOperationKind.createPartition, part),
    for (final part in [esp, root])
      ManualPlanOperation._(
        part.formatOnInstall
            ? ManualOperationKind.formatPartition
            : ManualOperationKind.reuseEsp,
        part,
      ),
  ]);
  Map<String, dynamic> get intentJson => {
    'schemaVersion': 1,
    'layoutVersion': 1,
    'mode': 'manual',
    'device': snapshot.device.json,
    'tableFingerprint': snapshot.tableFingerprint,
    'fileSystem': 'btrfs',
    'diskSwap': false,
    'subvolumes': Map<String, String>.of(StandardStorageLayout.subvolumes),
    'esp': esp.json,
    'root': root.json,
  };
  Map<String, dynamic> get json => {
    'schemaVersion': 1,
    'mode': 'manual',
    'snapshot': snapshot.json,
    'esp': esp.choice.json,
    'root': root.choice.json,
  };
  bool matchesSnapshot(GptDiskSnapshot current) =>
      samePlanValue(snapshot.json, current.json);
}
