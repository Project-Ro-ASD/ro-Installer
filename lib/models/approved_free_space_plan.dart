import 'approved_full_disk_plan.dart';
import 'free_space_installation_plan.dart';
import 'gpt_disk_snapshot.dart';
import '../services/helper_protocol.dart';

final class ApprovedFreeSpacePlan {
  ApprovedFreeSpacePlan._(
    this.plan,
    this.espGuid,
    this.rootGuid,
    this.preservationFingerprint,
  );
  final FreeSpaceInstallationPlan plan;
  final String espGuid, rootGuid, preservationFingerprint;
  factory ApprovedFreeSpacePlan.fromJson(Object? input) {
    if (input is! Map<String, dynamic> ||
        !exactFields(input, {'snapshot', 'approval'}) ||
        input['approval'] is! Map<String, dynamic>) {
      throw const FormatException('Invalid free-space approval');
    }
    final approval = input['approval'] as Map<String, dynamic>;
    if (!exactFields(approval, {
          'intent',
          'allocationGuids',
          'preservationFingerprint',
        }) ||
        approval['intent'] is! Map<String, dynamic> ||
        approval['allocationGuids'] is! Map<String, dynamic>) {
      throw const FormatException('Invalid allocation ownership');
    }
    final snapshot = GptDiskSnapshot.fromJson(input['snapshot']);
    final extent = approval['intent']['selectedExtent'];
    if (extent is! Map<String, dynamic> ||
        !exactFields(extent, {'startSector', 'endSector'}) ||
        extent['startSector'] is! int ||
        extent['endSector'] is! int) {
      throw const FormatException('Invalid extent');
    }
    final plan = FreeSpaceInstallationPlan.build(
      snapshot,
      FreeSectorExtent(extent['startSector'], extent['endSector']),
    );
    if (!samePlanValue(plan.intentJson, approval['intent'])) {
      throw const FormatException('Plan mismatch');
    }
    final ids = approval['allocationGuids'] as Map<String, dynamic>;
    if (!exactFields(ids, {'esp', 'root'})) {
      throw const FormatException('Invalid allocation identities');
    }
    final esp = snapshotGuid(ids['esp']), root = snapshotGuid(ids['root']);
    final used = {
      snapshot.diskGuid,
      ...snapshot.partitions.map((p) => p.partitionGuid),
    };
    if (esp == root || used.contains(esp) || used.contains(root)) {
      throw const FormatException('Reused allocation identity');
    }
    final proof = approval['preservationFingerprint'];
    if (proof is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(proof)) {
      throw const FormatException('Invalid preservation fingerprint');
    }
    final result = ApprovedFreeSpacePlan._(plan, esp, root, proof);
    if (!samePlanValue(result.approval, approval)) {
      throw const FormatException('Noncanonical approval');
    }
    return result;
  }
  Map<String, dynamic> get approval => {
    'intent': plan.intentJson,
    'allocationGuids': {'esp': espGuid, 'root': rootGuid},
    'preservationFingerprint': preservationFingerprint,
  };
  Map<String, dynamic> get json => {
    'snapshot': plan.snapshot.json,
    'approval': approval,
  };
  bool matchesState(Map<String, dynamic> state) =>
      state['selectedDisk'] == plan.snapshot.device.path &&
      state['partitionMethod'] == 'free_space' &&
      state['fileSystem'] == 'btrfs' &&
      samePlanValue(state['_approvedFreeSpacePlan'], json);
  CreatedFreeSpaceLayout verifyCreated(GptDiskSnapshot current, String proof) {
    if (proof != preservationFingerprint) {
      throw const FormatException('Existing GPT metadata changed');
    }
    final before = plan.snapshot.json
      ..remove('partitions')
      ..remove('tableFingerprint');
    final after = current.json
      ..remove('partitions')
      ..remove('tableFingerprint');
    if (!samePlanValue(before, after) ||
        current.partitions.length != plan.snapshot.partitions.length + 2) {
      throw const FormatException('Unexpected GPT changes');
    }
    for (final old in plan.snapshot.partitions) {
      final rows = current.partitions.where((p) => p.number == old.number);
      if (rows.length != 1 || !samePlanValue(rows.single.json, old.json)) {
        throw const FormatException('Existing partition changed');
      }
    }
    for (final role in ['esp', 'root']) {
      final spec = plan.intentJson[role] as Map;
      final rows = current.partitions.where((p) => p.number == spec['number']);
      if (rows.length != 1) {
        throw const FormatException('Created partition missing');
      }
      final p = rows.single;
      if (p.startSector != spec['startSector'] ||
          p.endSector != spec['endSector'] ||
          p.partitionGuid != (role == 'esp' ? espGuid : rootGuid) ||
          p.typeGuid !=
              (role == 'esp'
                  ? FreeSpaceInstallationPlan.espTypeGuid
                  : FreeSpaceInstallationPlan.linuxTypeGuid) ||
          p.attributesHex != '0000000000000000') {
        throw const FormatException('Created partition identity mismatch');
      }
    }
    return CreatedFreeSpaceLayout._(this, current);
  }
}

final class CreatedFreeSpaceLayout {
  CreatedFreeSpaceLayout._(this.approved, this.snapshot);
  final ApprovedFreeSpacePlan approved;
  final GptDiskSnapshot snapshot;
  String path(int number) {
    final disk = snapshot.device.path;
    return '$disk${disk.contains('nvme') || disk.contains('mmcblk') || disk.contains('loop') ? 'p' : ''}$number';
  }

  String get rootPath => path(approved.plan.rootNumber);
  String get espPath => path(approved.plan.espNumber);
}
