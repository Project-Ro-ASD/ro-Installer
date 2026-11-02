import '../services/helper_protocol.dart';
import 'approved_full_disk_plan.dart';
import 'gpt_disk_snapshot.dart';
import 'ntfs_shrink_installation_plan.dart';

/// Read-only assessment bound to the observed snapshot, never write approval.
final class NtfsShrinkAssessment {
  const NtfsShrinkAssessment._(
    this.plan,
    this.volumeBytes,
    this.clusterBytes,
    this.inspectionFingerprint,
  );
  final NtfsShrinkInstallationPlan plan;
  final int volumeBytes, clusterBytes;
  final String inspectionFingerprint;
  int get deviceBytes =>
      (plan.source.endSector - plan.source.startSector + 1) *
      plan.snapshot.logicalSectorBytes;
  int get minimumBytes => plan.minimumFilesystemBytes;

  factory NtfsShrinkAssessment.fromJson(
    Object? input, {
    required GptDiskSnapshot snapshot,
    required int sourceNumber,
    required int espNumber,
    required int rootBytes,
  }) {
    if (input is! Map<String, dynamic> ||
        !exactFields(input, {'plan', 'inspection'})) {
      throw const FormatException('Invalid NTFS assessment');
    }
    final inspection = input['inspection'];
    if (inspection is! Map<String, dynamic> ||
        !exactFields(inspection, {
          'schemaVersion',
          'deviceBytes',
          'volumeBytes',
          'clusterBytes',
          'minimumBytes',
          'inspectionFingerprint',
        }) ||
        inspection['schemaVersion'] is! int ||
        inspection['schemaVersion'] != 1) {
      throw const FormatException('Invalid NTFS inspection');
    }
    final rows = snapshot.partitions.where((p) => p.number == sourceNumber);
    if (rows.length != 1) {
      throw const FormatException('Missing NTFS source');
    }
    final source = rows.single;
    final sector = snapshot.logicalSectorBytes;
    final bytes = (source.endSector - source.startSector + 1) * sector;
    final observedBytes = snapshotInteger(
      inspection['deviceBytes'],
      1,
      8 * 1024 * 1024 * 1024 * 1024,
    );
    final cluster = snapshotInteger(inspection['clusterBytes'], sector, 65536);
    final volume = snapshotInteger(inspection['volumeBytes'], sector, bytes);
    final minimum = snapshotInteger(inspection['minimumBytes'], 1, volume);
    final fingerprint = inspection['inspectionFingerprint'];
    if (observedBytes != bytes ||
        (cluster & (cluster - 1)) != 0 ||
        bytes - volume >= cluster ||
        (volume - sector) % cluster != 0 ||
        minimum % sector != 0 ||
        fingerprint is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint)) {
      throw const FormatException('NTFS inspection geometry mismatch');
    }
    final plan = NtfsShrinkInstallationPlan.build(
      snapshot: snapshot,
      sourceNumber: sourceNumber,
      espNumber: espNumber,
      rootBytes: rootBytes,
      minimumFilesystemBytes: minimum,
    );
    if (!samePlanValue(plan.intentJson, input['plan'])) {
      throw const FormatException('NTFS intent does not match inspection');
    }
    return NtfsShrinkAssessment._(plan, volume, cluster, fingerprint);
  }

  Map<String, dynamic> get json => {
    'plan': plan.intentJson,
    'inspection': {
      'schemaVersion': 1,
      'deviceBytes': deviceBytes,
      'volumeBytes': volumeBytes,
      'clusterBytes': clusterBytes,
      'minimumBytes': minimumBytes,
      'inspectionFingerprint': inspectionFingerprint,
    },
  };
}
