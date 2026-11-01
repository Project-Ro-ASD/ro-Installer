import '../services/helper_protocol.dart';
import 'approved_full_disk_plan.dart';

const maximumSnapshotBytes = 9007199254740991;

int snapshotInteger(Object? value, int minimum, int maximum) {
  if (value is! int || value < minimum || value > maximum) {
    throw const FormatException('Invalid GPT integer');
  }
  return value;
}

String snapshotGuid(Object? value) {
  if (value is! String ||
      !RegExp(
        r'^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$',
      ).hasMatch(value) ||
      value.replaceAll(RegExp(r'[-0]'), '').isEmpty) {
    throw const FormatException('Invalid GPT GUID');
  }
  return value.toLowerCase();
}

final class GptPartitionSnapshot {
  const GptPartitionSnapshot._(
    this.number,
    this.startSector,
    this.endSector,
    this.typeGuid,
    this.partitionGuid,
    this.attributesHex,
  );
  final int number, startSector, endSector;
  final String typeGuid, partitionGuid, attributesHex;
  factory GptPartitionSnapshot.fromJson(
    Object? input, {
    required int entryCount,
    required int firstUsable,
    required int lastUsable,
  }) {
    if (input is! Map<String, dynamic> ||
        !exactFields(input, {
          'number',
          'startSector',
          'endSector',
          'typeGuid',
          'partitionGuid',
          'attributesHex',
        })) {
      throw const FormatException('Invalid GPT partition');
    }
    final start = snapshotInteger(
      input['startSector'],
      firstUsable,
      lastUsable,
    );
    final end = snapshotInteger(input['endSector'], start, lastUsable);
    final attrs = input['attributesHex'];
    if (attrs is! String || !RegExp(r'^[0-9a-f]{16}$').hasMatch(attrs)) {
      throw const FormatException('Invalid GPT attributes');
    }
    return GptPartitionSnapshot._(
      snapshotInteger(input['number'], 1, entryCount),
      start,
      end,
      snapshotGuid(input['typeGuid']),
      snapshotGuid(input['partitionGuid']),
      attrs,
    );
  }
  Map<String, dynamic> get json => {
    'number': number,
    'startSector': startSector,
    'endSector': endSector,
    'typeGuid': typeGuid,
    'partitionGuid': partitionGuid,
    'attributesHex': attributesHex,
  };
}

final class FreeSectorExtent {
  const FreeSectorExtent(this.startSector, this.endSector);
  final int startSector, endSector;
  Map<String, dynamic> get json => {
    'startSector': startSector,
    'endSector': endSector,
  };
}

/// Normalized planning input, not an authorization or an authoritative probe.
/// The future privileged probe must validate both GPT copies/CRCs, kernel
/// topology and device identity, and fingerprint all table metadata.
final class GptDiskSnapshot {
  GptDiskSnapshot._(
    this.device,
    this.logicalSectorBytes,
    this.firstUsableSector,
    this.lastUsableSector,
    this.entryCount,
    this.entryBytes,
    this.primaryEntriesLba,
    this.backupEntriesLba,
    this.diskGuid,
    this.tableFingerprint,
    List<GptPartitionSnapshot> partitions,
  ) : partitions = List.unmodifiable(partitions);
  final DeviceIdentity device;
  final int logicalSectorBytes,
      firstUsableSector,
      lastUsableSector,
      entryCount,
      entryBytes;
  final int primaryEntriesLba, backupEntriesLba;
  final String diskGuid, tableFingerprint;
  final List<GptPartitionSnapshot> partitions;
  factory GptDiskSnapshot.fromJson(Object? input) {
    if (input is! Map<String, dynamic> ||
        !exactFields(input, {
          'schemaVersion',
          'device',
          'logicalSectorBytes',
          'firstUsableSector',
          'lastUsableSector',
          'entryCount',
          'entryBytes',
          'primaryEntriesLba',
          'backupEntriesLba',
          'diskGuid',
          'tableFingerprint',
          'partitions',
        }) ||
        input['schemaVersion'] is! int ||
        input['schemaVersion'] != 1 ||
        input['device'] is! Map<String, dynamic>) {
      throw const FormatException('Invalid GPT snapshot');
    }
    final device = DeviceIdentity.fromJson(input['device']);
    snapshotInteger(device.size, 1, maximumSnapshotBytes);
    final sector = snapshotInteger(input['logicalSectorBytes'], 512, 4096);
    if (!const [512, 4096].contains(sector) || device.size % sector != 0) {
      throw const FormatException('Unsupported sector geometry');
    }
    final count = snapshotInteger(input['entryCount'], 1, 4096);
    final entryBytes = snapshotInteger(input['entryBytes'], 128, 1024);
    if (!const [128, 256, 512, 1024].contains(entryBytes)) {
      throw const FormatException('Unsupported GPT entry size');
    }
    final arrayBytes = count * entryBytes;
    final reserved =
        ((arrayBytes < 16384 ? 16384 : arrayBytes) + sector - 1) ~/ sector;
    final total = device.size ~/ sector;
    final first = snapshotInteger(
      input['firstUsableSector'],
      2 + reserved,
      total - reserved - 2,
    );
    final last = snapshotInteger(
      input['lastUsableSector'],
      first,
      total - reserved - 2,
    );
    final primary = snapshotInteger(input['primaryEntriesLba'], 2, first);
    final backup = snapshotInteger(
      input['backupEntriesLba'],
      last + 1,
      total - 2,
    );
    if (primary + reserved > first || backup + reserved > total - 1) {
      throw const FormatException(
        'GPT metadata overlaps usable space or headers',
      );
    }
    final guid = snapshotGuid(input['diskGuid']);
    final fingerprint = input['tableFingerprint'];
    if (fingerprint is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint)) {
      throw const FormatException('Invalid table fingerprint');
    }
    final rows = input['partitions'];
    if (rows is! List || rows.length > count) {
      throw const FormatException('Invalid GPT inventory');
    }
    final parts = rows
        .map(
          (row) => GptPartitionSnapshot.fromJson(
            row,
            entryCount: count,
            firstUsable: first,
            lastUsable: last,
          ),
        )
        .toList();
    final numbers = <int>{};
    final guids = {guid};
    for (final part in parts) {
      if (!numbers.add(part.number) || !guids.add(part.partitionGuid)) {
        throw const FormatException('Duplicate GPT identity');
      }
    }
    parts.sort((a, b) => a.startSector.compareTo(b.startSector));
    for (var i = 1; i < parts.length; i++) {
      if (parts[i].startSector <= parts[i - 1].endSector) {
        throw const FormatException('Overlapping GPT partitions');
      }
    }
    return GptDiskSnapshot._(
      device,
      sector,
      first,
      last,
      count,
      entryBytes,
      primary,
      backup,
      guid,
      fingerprint,
      parts,
    );
  }
  List<FreeSectorExtent> get freeExtents {
    final result = <FreeSectorExtent>[];
    var cursor = firstUsableSector;
    for (final part in partitions) {
      if (cursor < part.startSector) {
        result.add(FreeSectorExtent(cursor, part.startSector - 1));
      }
      cursor = part.endSector + 1;
    }
    if (cursor <= lastUsableSector) {
      result.add(FreeSectorExtent(cursor, lastUsableSector));
    }
    return List.unmodifiable(result);
  }

  Map<String, dynamic> get json => {
    'schemaVersion': 1,
    'device': device.json,
    'logicalSectorBytes': logicalSectorBytes,
    'firstUsableSector': firstUsableSector,
    'lastUsableSector': lastUsableSector,
    'entryCount': entryCount,
    'entryBytes': entryBytes,
    'primaryEntriesLba': primaryEntriesLba,
    'backupEntriesLba': backupEntriesLba,
    'diskGuid': diskGuid,
    'tableFingerprint': tableFingerprint,
    'partitions': partitions.map((p) => p.json).toList(),
  };
  bool sameAs(GptDiskSnapshot other) => samePlanValue(json, other.json);
}
