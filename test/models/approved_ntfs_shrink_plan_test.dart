import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ro_installer/models/gpt_disk_snapshot.dart';
import 'package:ro_installer/models/approved_ntfs_shrink_plan.dart';

Map<String, dynamic> clone(Object? value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
Map<String, dynamic> mutate(Object? input, Map<String, dynamic> row) {
  final value = clone(input);
  dynamic parent = value;
  final path = row['path'] as List;
  for (final key in path.take(path.length - 1)) {
    parent = parent[key];
  }
  if (row['op'] == 'remove') {
    parent.remove(path.last);
  } else {
    parent[path.last] = row['value'];
  }
  return value;
}

void main() {
  final cases =
      jsonDecode(
            File('test/fixtures/ntfs_approvals_v1.json').readAsStringSync(),
          )
          as Map<String, dynamic>;
  for (final base in cases['bases'] as List) {
    test('canonical private NTFS approval ${base['name']}', () {
      final input = clone(base['input']);
      final plan = ApprovedNtfsShrinkPlan.fromJson(input);
      expect(plan.json, input);
      plan.verifyCreated(
        GptDiskSnapshot.fromJson(base['created']),
        base['proof'] as String,
      );
      input['approval']['intent']['source']['newEndSector'] = 0;
      input['proposal']['snapshot']['device']['diskSequence'] = 999;
      expect(plan.json, base['input']);
      final output = plan.json;
      output['proposal']['snapshot']['partitions'].clear();
      output['approval']['intent']['root']['number'] = 4096;
      expect(plan.json, base['input']);
      expect(
        () => plan.plan.snapshot.partitions.clear(),
        throwsUnsupportedError,
      );
      final state = <String, dynamic>{
        'selectedDisk': plan.plan.snapshot.device.path,
        'partitionMethod': 'alongside_ntfs_shrink',
        'fileSystem': 'btrfs',
        '_approvedNtfsPlan': plan.json,
      };
      expect(plan.matchesState(state), isTrue);
      for (final entry in {
        'selectedDisk': '/dev/sdz',
        'partitionMethod': 'alongside',
        'fileSystem': 'ext4',
        '_approvedNtfsPlan': <String, dynamic>{},
      }.entries) {
        expect(plan.matchesState({...state, entry.key: entry.value}), isFalse);
      }
    });
  }
  for (final raw in cases['invalidApprovals'] as List) {
    final row = raw as Map<String, dynamic>;
    final base = cases['bases'][row['base']];
    test('reject NTFS approval ${row['name']}', () {
      expect(
        () => ApprovedNtfsShrinkPlan.fromJson(mutate(base['input'], row)),
        throwsFormatException,
      );
    });
  }
  for (final raw in cases['invalidCreated'] as List) {
    final row = raw as Map<String, dynamic>;
    final base = cases['bases'][row['base']];
    test('reject created NTFS metadata ${row['name']}', () {
      final plan = ApprovedNtfsShrinkPlan.fromJson(base['input']);
      final snapshot = row['op'] == 'proof'
          ? base['created']
          : mutate(base['created'], row);
      expect(
        () => plan.verifyCreated(
          GptDiskSnapshot.fromJson(snapshot),
          (row['op'] == 'proof' ? row['value'] : base['proof']) as String,
        ),
        throwsFormatException,
      );
    });
  }
}
