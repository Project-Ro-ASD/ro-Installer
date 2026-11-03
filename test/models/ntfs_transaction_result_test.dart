import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ro_installer/models/approved_ntfs_shrink_plan.dart';
import 'package:ro_installer/models/ntfs_transaction_result.dart';
import 'approved_ntfs_shrink_plan_test.dart' show mutate, clone;

void main() {
  final bases =
      (jsonDecode(
                File('test/fixtures/ntfs_approvals_v1.json').readAsStringSync(),
              )
              as Map)['bases']
          as List;
  final cases =
      jsonDecode(File('test/fixtures/ntfs_outcomes_v1.json').readAsStringSync())
          as Map;
  Map<String, dynamic> success(dynamic base) => {
    'schemaVersion': 1,
    'status': 'success',
    'snapshot': base['created'],
    'preservationFingerprint': base['proof'],
  };
  Map<String, dynamic> failure() => {
    'schemaVersion': 1,
    'status': 'failed',
    'phase': 'gpt.verify',
    'progressKnown': true,
    'sourceMayHaveChanged': true,
    'gptWriteStarted': true,
    'verifiedGptCopies': 2,
    'cleanupFailed': false,
  };
  Map<String, dynamic> unknown() => {
    'schemaVersion': 1,
    'status': 'failed',
    'phase': 'unknown',
    'progressKnown': false,
    'sourceMayHaveChanged': true,
    'gptWriteStarted': true,
    'verifiedGptCopies': 0,
    'cleanupFailed': false,
  };
  for (final base in bases) {
    test('owned NTFS success ${base['name']}', () {
      final approved = ApprovedNtfsShrinkPlan.fromJson(base['input']);
      final result = NtfsTransactionResult.fromJson(
        success(base),
        approved: approved,
      );
      expect(result.succeeded, isTrue);
      expect(result.snapshot!.json, base['created']);
      expect(result.createdLayout!.snapshot, same(result.snapshot));
      expect(result.createdLayout!.approved.json, approved.json);
      expect(result.createdLayout!.reusesEsp, isTrue);
      expect(result.verifiedGptCopies, 2);
      expect(result.progressKnown, isTrue);
    });
  }
  for (final disk in ['/dev/sda', '/dev/vda', '/dev/nvme0n1', '/dev/mmcblk0']) {
    test('verified NTFS targets bind canonical disk $disk', () {
      final base = clone(bases.first);
      base['input']['proposal']['snapshot']['device']['path'] = disk;
      base['input']['approval']['intent']['device']['path'] = disk;
      base['created']['device']['path'] = disk;
      final expectedSnapshot = clone(base['created']);
      final approved = ApprovedNtfsShrinkPlan.fromJson(base['input']);
      final result = NtfsTransactionResult.fromJson(
        success(base),
        approved: approved,
      );
      final layout = result.createdLayout!;
      final prefix = '$disk${RegExp(r'[0-9]$').hasMatch(disk) ? 'p' : ''}';
      expect(layout.rootPath, '${prefix}3');
      expect(layout.espPath, '${prefix}1');
      expect(layout.sourcePath, '${prefix}2');
      expect(layout.rootPath, isNot(layout.sourcePath));
      expect(layout.rootPath, isNot(layout.espPath));
      base['created']['partitions'].clear();
      layout.approved.json['approval']['intent']['root']['number'] = 4096;
      layout.snapshot.json['device']['path'] = '/dev/sdz';
      expect(layout.rootPath, '${prefix}3');
      expect(layout.snapshot.json, expectedSnapshot);
      expect(layout.approved.plan.rootNumber, 3);
    });
  }
  test('not started never produces resolved targets', () {
    const result = NtfsTransactionResult.notStarted();
    expect(result.createdLayout, isNull);
    expect(result.snapshot, isNull);
    expect(result.succeeded, isFalse);
  });
  test('unknown transport never claims unchanged source', () {
    const result = NtfsTransactionResult.unknown();
    expect(result.succeeded, isFalse);
    expect(result.createdLayout, isNull);
    expect(result.snapshot, isNull);
    expect(result.progressKnown, isFalse);
    expect(result.sourceMayHaveChanged, isTrue);
    expect(result.gptWriteStarted, isTrue);
  });
  for (final row in cases['failures'] as List) {
    test('canonical NTFS failure ${row['phase']}', () {
      final approved = ApprovedNtfsShrinkPlan.fromJson(bases.first['input']);
      final result = NtfsTransactionResult.fromJson(row, approved: approved);
      expect(result.succeeded, isFalse);
      expect(result.createdLayout, isNull);
      expect(result.snapshot, isNull);
      expect(result.phase, row['phase']);
      expect(result.progressKnown, row['progressKnown']);
      expect(result.sourceMayHaveChanged, row['sourceMayHaveChanged']);
      expect(result.gptWriteStarted, row['gptWriteStarted']);
      expect(result.verifiedGptCopies, row['verifiedGptCopies']);
      expect(result.cleanupFailed, row['cleanupFailed']);
    });
  }
  for (final raw in cases['invalid'] as List) {
    final row = raw as Map<String, dynamic>;
    test('reject NTFS terminal ${row['name']}', () {
      final approved = ApprovedNtfsShrinkPlan.fromJson(bases.first['input']);
      final originals = {
        'success': success(bases.first),
        'failure': failure(),
        'unknown': unknown(),
      };
      expect(
        () => NtfsTransactionResult.fromJson(
          mutate(originals[row['base']], row),
          approved: approved,
        ),
        throwsFormatException,
      );
    });
  }
}
