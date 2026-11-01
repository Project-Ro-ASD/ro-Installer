import '../services/helper_protocol.dart';
import 'approved_full_disk_plan.dart';
import 'gpt_disk_snapshot.dart';
import 'manual_installation_plan.dart';

/// Private helper-to-backend facts, not a public approval or command API.
final class ApprovedManualPlan {
  ApprovedManualPlan._(
    this.plan,
    Map<String, String> ids,
    this.preservationFingerprint,
  ) : allocationGuids = Map.unmodifiable(ids);
  final ManualInstallationPlan plan;
  final Map<String, String> allocationGuids;
  final String preservationFingerprint;

  factory ApprovedManualPlan.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        !exactFields(value, {'snapshot', 'approval'}) ||
        value['approval'] is! Map<String, dynamic>) {
      throw const FormatException('Invalid private manual approval');
    }
    final approval = value['approval'] as Map<String, dynamic>;
    if (!exactFields(approval, {
          'intent',
          'allocationGuids',
          'preservationFingerprint',
        }) ||
        approval['intent'] is! Map<String, dynamic> ||
        approval['allocationGuids'] is! Map<String, dynamic>) {
      throw const FormatException('Invalid manual ownership');
    }
    final intent = approval['intent'] as Map<String, dynamic>;
    ManualPartitionChoice choice(String role) {
      final binding = intent[role];
      if (binding is! Map<String, dynamic>) {
        throw const FormatException('Missing manual role');
      }
      return ManualPartitionChoice.fromJson(
        binding['source'] == 'existing'
            ? {
                'source': 'existing',
                'number': binding['number'],
                'formatOnInstall': binding['formatOnInstall'],
              }
            : {
                'source': binding['source'],
                'startSector': binding['startSector'],
                'endSector': binding['endSector'],
              },
      );
    }

    final plan = ManualInstallationPlan.build(
      snapshot: GptDiskSnapshot.fromJson(value['snapshot']),
      esp: choice('esp'),
      root: choice('root'),
    );
    if (!samePlanValue(plan.intentJson, intent)) {
      throw const FormatException('Manual intent mismatch');
    }
    final rawIds = approval['allocationGuids'] as Map<String, dynamic>;
    final newRoles = {
      for (final part in [plan.esp, plan.root])
        if (part.isNew) part.role.name,
    };
    if (!exactFields(rawIds, newRoles)) {
      throw const FormatException('Unexpected allocation identity');
    }
    final used = {
      plan.snapshot.diskGuid,
      ...plan.snapshot.partitions.map((p) => p.partitionGuid),
    };
    final ids = <String, String>{};
    for (final role in ['esp', 'root']) {
      if (newRoles.contains(role)) {
        final id = snapshotGuid(rawIds[role]);
        if (!used.add(id)) throw const FormatException('Reused partition GUID');
        ids[role] = id;
      }
    }
    final proof = approval['preservationFingerprint'];
    if (proof is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(proof)) {
      throw const FormatException('Invalid manual preservation proof');
    }
    final result = ApprovedManualPlan._(plan, ids, proof);
    if (!samePlanValue(result.approval, approval)) {
      throw const FormatException('Noncanonical manual ownership');
    }
    return result;
  }

  List<int> get newSlots => List.unmodifiable([
    for (final part in [plan.esp, plan.root])
      if (part.isNew) part.number,
  ]);
  Map<String, dynamic> get approval => {
    'intent': plan.intentJson,
    'allocationGuids': Map<String, String>.of(allocationGuids),
    'preservationFingerprint': preservationFingerprint,
  };
  Map<String, dynamic> get json => {
    'snapshot': plan.snapshot.json,
    'approval': approval,
  };
  bool matchesState(Map<String, dynamic> state) =>
      state['selectedDisk'] == plan.snapshot.device.path &&
      state['partitionMethod'] == 'manual' &&
      state['fileSystem'] == 'btrfs' &&
      samePlanValue(state['_approvedManualPlan'], json);

  CreatedManualLayout verifyCreated(GptDiskSnapshot current, String proof) {
    if (proof != preservationFingerprint) {
      throw const FormatException('Unowned GPT metadata changed');
    }
    final before = plan.snapshot.json
      ..remove('partitions')
      ..remove('tableFingerprint');
    final after = current.json
      ..remove('partitions')
      ..remove('tableFingerprint');
    if (!samePlanValue(before, after) ||
        current.partitions.length !=
            plan.snapshot.partitions.length + newSlots.length) {
      throw const FormatException('Unexpected manual GPT changes');
    }
    for (final old in plan.snapshot.partitions) {
      final rows = current.partitions.where((p) => p.number == old.number);
      if (rows.length != 1 || !samePlanValue(rows.single.json, old.json)) {
        throw const FormatException('Existing GPT entry changed');
      }
    }
    for (final binding in [plan.esp, plan.root].where((p) => p.isNew)) {
      final rows = current.partitions.where((p) => p.number == binding.number);
      if (rows.length != 1) {
        throw const FormatException('New manual partition missing');
      }
      final p = rows.single;
      if (p.partitionGuid != allocationGuids[binding.role.name] ||
          p.typeGuid != binding.typeGuid ||
          p.attributesHex != '0000000000000000' ||
          p.startSector != binding.startSector ||
          p.endSector != binding.endSector) {
        throw const FormatException('Manual partition ownership mismatch');
      }
    }
    return CreatedManualLayout._(this, current);
  }
}

/// Only exact post-create GPT identities can construct resolved manual targets.
final class CreatedManualLayout {
  const CreatedManualLayout._(this.approved, this.snapshot);
  final ApprovedManualPlan approved;
  final GptDiskSnapshot snapshot;
  String get rootPath => approved.plan.root.target;
  String get espPath => approved.plan.esp.target;
  bool get reusesEsp => !approved.plan.esp.formatOnInstall;
}
