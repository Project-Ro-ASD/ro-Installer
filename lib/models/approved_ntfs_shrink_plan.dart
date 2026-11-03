import '../services/helper_protocol.dart';
import 'approved_full_disk_plan.dart';
import 'gpt_disk_snapshot.dart';
import 'ntfs_shrink_installation_plan.dart';

/// Private helper/backend ownership; source safety and kernel readiness are separate.
final class ApprovedNtfsShrinkPlan {
  const ApprovedNtfsShrinkPlan._(
    this.plan,
    this.rootGuid,
    this.preservationFingerprint,
    this.inspectionFingerprint,
    this.preparationFingerprint,
  );
  final NtfsShrinkInstallationPlan plan;
  final String rootGuid,
      preservationFingerprint,
      inspectionFingerprint,
      preparationFingerprint;

  factory ApprovedNtfsShrinkPlan.fromJson(Object? input) {
    if (input is! Map<String, dynamic> ||
        !exactFields(input, {'proposal', 'approval'}) ||
        input['approval'] is! Map<String, dynamic>) {
      throw const FormatException('Invalid private NTFS approval');
    }
    final plan = NtfsShrinkInstallationPlan.fromJson(input['proposal']);
    final approval = input['approval'] as Map<String, dynamic>;
    if (!exactFields(approval, {
          'intent',
          'rootGuid',
          'preservationFingerprint',
          'inspectionFingerprint',
          'preparationFingerprint',
        }) ||
        !samePlanValue(plan.intentJson, approval['intent'])) {
      throw const FormatException(
        'NTFS ownership differs from the bound proposal',
      );
    }
    final root = snapshotGuid(approval['rootGuid']);
    final used = {
      plan.snapshot.diskGuid,
      ...plan.snapshot.partitions.map((p) => p.partitionGuid),
    };
    if (used.contains(root)) {
      throw const FormatException('Reused NTFS allocation identity');
    }
    String fingerprint(String name) {
      final value = approval[name];
      if (value is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
        throw const FormatException('Invalid NTFS fingerprint');
      }
      return value;
    }

    final result = ApprovedNtfsShrinkPlan._(
      plan,
      root,
      fingerprint('preservationFingerprint'),
      fingerprint('inspectionFingerprint'),
      fingerprint('preparationFingerprint'),
    );
    if (!samePlanValue(result.approval, approval)) {
      throw const FormatException('Noncanonical NTFS ownership');
    }
    return result;
  }

  Map<String, dynamic> get approval => {
    'intent': plan.intentJson,
    'rootGuid': rootGuid,
    'preservationFingerprint': preservationFingerprint,
    'inspectionFingerprint': inspectionFingerprint,
    'preparationFingerprint': preparationFingerprint,
  };
  Map<String, dynamic> get json => {
    'proposal': plan.json,
    'approval': approval,
  };
  bool matchesState(Map<String, dynamic> state) =>
      state['selectedDisk'] == plan.snapshot.device.path &&
      state['partitionMethod'] == 'alongside_ntfs_shrink' &&
      state['fileSystem'] == 'btrfs' &&
      samePlanValue(state['_approvedNtfsPlan'], json);

  /// GPT ownership only: worker filesystem/kernel checks remain mandatory.
  CreatedNtfsLayout verifyCreated(GptDiskSnapshot current, String proof) {
    if (proof != preservationFingerprint) {
      throw const FormatException('Protected GPT metadata changed');
    }
    final before = plan.snapshot.json
      ..remove('partitions')
      ..remove('tableFingerprint');
    final after = current.json
      ..remove('partitions')
      ..remove('tableFingerprint');
    if (!samePlanValue(before, after) ||
        current.partitions.length != plan.snapshot.partitions.length + 1) {
      throw const FormatException('Unexpected GPT changes');
    }
    for (final old in plan.snapshot.partitions) {
      final rows = current.partitions.where((p) => p.number == old.number);
      final expected = old.json;
      if (old.number == plan.source.number) {
        expected['endSector'] = plan.sourceEnd;
      }
      if (rows.length != 1 || !samePlanValue(rows.single.json, expected)) {
        throw const FormatException('Existing GPT entry changed');
      }
    }
    final roots = current.partitions.where((p) => p.number == plan.rootNumber);
    if (roots.length != 1 ||
        !samePlanValue(roots.single.json, {
          'number': plan.rootNumber,
          'startSector': plan.rootStart,
          'endSector': plan.rootEnd,
          'typeGuid': plan.intentJson['root']['typeGuid'],
          'partitionGuid': rootGuid,
          'attributesHex': '0000000000000000',
        })) {
      throw const FormatException('NTFS root ownership mismatch');
    }
    return CreatedNtfsLayout._(this, current);
  }
}

/// Exact GPT ownership only; guarded worker filesystem/kernel checks are separate.
final class CreatedNtfsLayout {
  const CreatedNtfsLayout._(this.approved, this.snapshot);
  final ApprovedNtfsShrinkPlan approved;
  final GptDiskSnapshot snapshot;
  String _partition(int number) {
    final disk = approved.plan.snapshot.device.path;
    return '$disk${RegExp(r'[0-9]$').hasMatch(disk) ? 'p' : ''}$number';
  }

  String get rootPath => _partition(approved.plan.rootNumber);
  String get espPath => _partition(approved.plan.esp.number);
  String get sourcePath => _partition(approved.plan.source.number);
  bool get reusesEsp => true;
}
