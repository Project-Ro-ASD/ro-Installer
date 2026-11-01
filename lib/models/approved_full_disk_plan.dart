import 'dart:convert';
import '../services/helper_protocol.dart';
import 'standard_storage_layout.dart';
import 'storage_plan.dart';

/// A snapshot of the supported full-disk intent, never a command/argv API.
final class ApprovedFullDiskPlan {
  ApprovedFullDiskPlan(DeviceIdentity identity)
    : device = DeviceIdentity.fromJson(identity.json);
  final DeviceIdentity device;
  Map<String, dynamic> get state => {
    'selectedDisk': device.path,
    'partitionMethod': 'full',
    'fileSystem': 'btrfs',
  };
  Map<String, dynamic> get json => {
    'schemaVersion': 1,
    'layoutVersion': 1,
    'device': device.json,
    'partitionTable': 'gpt',
    'espBytes': StandardStorageLayout.espBytes,
    'espFileSystem': 'fat32',
    'diskSwap': false,
    'subvolumes': Map<String, String>.of(StandardStorageLayout.subvolumes),
    'storagePlan': StoragePlanBuilder.fromState(state).toJson(),
  };
  factory ApprovedFullDiskPlan.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['device'] is! Map<String, dynamic>) {
      throw const FormatException('Invalid approved plan');
    }
    final plan = ApprovedFullDiskPlan(DeviceIdentity.fromJson(value['device']));
    if (!samePlanValue(value, plan.json)) {
      throw const FormatException('Unsupported approved plan');
    }
    return plan;
  }
  bool matchesState(Map<String, dynamic> current) {
    try {
      return current['selectedDisk'] == device.path &&
          current['partitionMethod'] == 'full' &&
          current['fileSystem'] == 'btrfs' &&
          samePlanValue(
            StoragePlanBuilder.fromState(current).toJson(),
            json['storagePlan'],
          );
    } catch (_) {
      return false;
    }
  }
}

/// Key order is irrelevant; field presence, list order and JSON types are not.
bool samePlanValue(Object? a, Object? b) {
  Object? canonical(Object? value) {
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: canonical(value[key])};
    }
    if (value is List) return value.map(canonical).toList();
    return value;
  }

  try {
    return jsonEncode(canonical(a)) == jsonEncode(canonical(b));
  } catch (_) {
    return false;
  }
}

bool matchesApprovedPlan(
  Map<String, dynamic> state, {
  ApprovedFullDiskPlan? expected,
}) {
  if (expected != null &&
      (!samePlanValue(state['_approvedFullDiskPlan'], expected.json) ||
          !expected.matchesState(state))) {
    return false;
  }
  if (!state.containsKey('_approvedFullDiskPlan')) {
    return true; // Legacy fixed-mode path.
  }
  try {
    return ApprovedFullDiskPlan.fromJson(
      state['_approvedFullDiskPlan'],
    ).matchesState(state);
  } catch (_) {
    return false;
  }
}
