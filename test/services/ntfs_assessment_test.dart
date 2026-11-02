import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:ro_installer/models/gpt_disk_snapshot.dart';
import 'package:ro_installer/models/ntfs_shrink_assessment.dart';
import 'package:ro_installer/services/helper_client.dart';
import 'helper_client_test.dart' as f;

List<Map<String, dynamic>> fixtures() =>
    (jsonDecode(
              File(
                'test/fixtures/ntfs_shrink_plans_v1.json',
              ).readAsStringSync(),
            )
            as List)
        .cast<Map<String, dynamic>>()
        .where((v) => v['intent'] != null)
        .toList();
Map<String, dynamic> response(Map<String, dynamic> row) {
  final s = row['input']['snapshot'];
  final source = row['intent']['source'];
  final size =
      (source['endSector'] - source['startSector'] + 1) *
      s['logicalSectorBytes'];
  return {
    'protocolVersion': 2,
    'type': 'result',
    'operation': 'assess-ntfs-shrink',
    'ok': true,
    'plan': row['intent'],
    'inspection': {
      'schemaVersion': 1,
      'deviceBytes': size,
      'volumeBytes': size - 4096 + s['logicalSectorBytes'],
      'clusterBytes': 4096,
      'minimumBytes': row['input']['minimumFilesystemBytes'],
      'inspectionFingerprint': 'c' * 64,
    },
  };
}

Future<NtfsShrinkAssessment> assess(
  HelperClient client,
  Map<String, dynamic> row,
) => client.assessNtfsShrink(
  snapshot: GptDiskSnapshot.fromJson(row['input']['snapshot']),
  sourceNumber: 2,
  espNumber: 1,
  rootBytes: row['input']['rootBytes'],
);
NtfsShrinkAssessment decode(
  Map<String, dynamic> value,
  Map<String, dynamic> row,
) => NtfsShrinkAssessment.fromJson(
  {'plan': value['plan'], 'inspection': value['inspection']},
  snapshot: GptDiskSnapshot.fromJson(row['input']['snapshot']),
  sourceNumber: 2,
  espNumber: 1,
  rootBytes: row['input']['rootBytes'],
);
void main() {
  for (final row in fixtures()) {
    test(
      'read-only assessment reconstructs shared intent: ${row['name']}',
      () async {
        final value = response(row);
        final process = f.FakeHelperProcess(f.messages([value]));
        final result = await assess(
          HelperClient(protocolVersion: 2, start: (_, _) async => process),
          row,
        );
        expect(result.plan.intentJson, row['intent']);
        expect(result.minimumBytes, row['input']['minimumFilesystemBytes']);
        expect(jsonDecode(process.sent), {
          'protocolVersion': 2,
          'operation': 'assess-ntfs-shrink',
          'disk': row['input']['snapshot']['device']['path'],
          'expectedDevice': GptDiskSnapshot.fromJson(
            row['input']['snapshot'],
          ).device.expected,
          'tableFingerprint': row['input']['snapshot']['tableFingerprint'],
          'sourceNumber': 2,
          'espNumber': 1,
          'rootBytes': row['input']['rootBytes'],
        });
        final before = jsonEncode(result.json);
        result.json['inspection']['minimumBytes'] = 1;
        result.json['plan']['esp']['formatOnInstall'] = true;
        expect(jsonEncode(result.json), before);
      },
    );
  }
  test('invalid geometry or v1 is rejected before helper starts', () async {
    for (final version in [1, 2]) {
      var starts = 0;
      final row = fixtures().first;
      if (version == 2) row['input']['rootBytes'] = 41 * 1024 * 1024 * 1024;
      await expectLater(
        assess(
          HelperClient(
            protocolVersion: version,
            start: (_, _) async {
              starts++;
              throw StateError('must not start');
            },
          ),
          row,
        ),
        throwsA(f.helperError('INVALID_REQUEST')),
      );
      expect(starts, 0);
    }
  });
  final invalidInspection = <Map<String, dynamic>>[
    {'schemaVersion': true},
    {'deviceBytes': true},
    {'deviceBytes': 1},
    {'volumeBytes': 1},
    {'clusterBytes': true},
    {'clusterBytes': 513},
    {'clusterBytes': 131072},
    {'minimumBytes': true},
    {'minimumBytes': 0},
    {'minimumBytes': 50 * 1024 * 1024 * 1024 + 1},
    {'inspectionFingerprint': 'A' * 64},
    {'safeForWrite': true},
    {'stdout': 'SECRET'},
  ];
  for (var i = 0; i < invalidInspection.length; i++) {
    test('invalid inspection geometry/schema $i fails closed', () {
      final row = fixtures().first;
      final value = response(row);
      value['inspection'] = {...value['inspection'], ...invalidInspection[i]};
      expect(() => decode(value, row), throwsFormatException);
    });
  }
  test(
    'helper plan and observed minimum must agree with selected snapshot',
    () async {
      for (final mutate in <void Function(Map<String, dynamic>)>[
        (v) => v['plan']['source']['newEndSector'] += 1,
        (v) => v['plan']['root']['endSector'] += 1,
        (v) => v['plan']['device']['diskSequence'] += 1,
        (v) => v['plan']['esp']['formatOnInstall'] = true,
        (v) => v['plan']['tableFingerprint'] = 'b' * 64,
        (v) => v['inspection']['minimumBytes'] = 134 * 1024 * 1024 * 1024,
        (v) => v['inspection']['deviceBytes'] = 1,
        (v) => v['sourceSnapshot'] = {},
        (v) => v.remove('inspection'),
      ]) {
        final row = fixtures().first;
        final value = response(row);
        mutate(value);
        final process = f.FakeHelperProcess(f.messages([value]));
        await expectLater(
          assess(
            HelperClient(protocolVersion: 2, start: (_, _) async => process),
            row,
          ),
          throwsA(f.helperError('PROTOCOL_ERROR')),
        );
      }
    },
  );
  test('assessment preserves authoritative helper failures', () async {
    final process = f.FakeHelperProcess(
      f.messages([
        {
          'protocolVersion': 2,
          'type': 'result',
          'operation': 'assess-ntfs-shrink',
          'ok': false,
          'error': {'code': 'DEVICE_CHANGED', 'message': 'Changed'},
        },
      ]),
      status: 4,
    );
    await expectLater(
      assess(
        HelperClient(protocolVersion: 2, start: (_, _) async => process),
        fixtures().first,
      ),
      throwsA(f.helperError('DEVICE_CHANGED')),
    );
  });
}
