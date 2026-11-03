import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:ro_installer/models/gpt_disk_snapshot.dart';
import 'package:ro_installer/models/ntfs_shrink_assessment.dart';
import 'package:ro_installer/models/prepared_ntfs_shrink.dart';
import 'package:ro_installer/services/helper_client.dart';
import '../models/approved_ntfs_shrink_plan_test.dart' show mutate, clone;
import 'helper_client_test.dart' as f;

void main() {
  final cases =
      jsonDecode(
            File('test/fixtures/ntfs_preparations_v1.json').readAsStringSync(),
          )
          as Map;
  NtfsShrinkAssessment assessment(dynamic base) {
    final p = base['proposal'];
    return NtfsShrinkAssessment.fromJson(
      {
        'plan': base['response']['plan'],
        'inspection': base['response']['inspection'],
      },
      snapshot: GptDiskSnapshot.fromJson(p['snapshot']),
      sourceNumber: p['sourceNumber'] as int,
      espNumber: p['espNumber'] as int,
      rootBytes: p['rootBytes'] as int,
    );
  }

  Map<String, dynamic> response(dynamic base) => {
    'protocolVersion': 2,
    'type': 'result',
    'operation': 'prepare-ntfs-shrink',
    'ok': true,
    ...(base['response'] as Map<String, dynamic>),
  };
  final first = cases['bases'][0];
  for (final base in cases['bases'] as List) {
    test('prepared evidence ${base['name']} is exact and immutable', () {
      final raw = clone(base['response']);
      final expected = assessment(base);
      final prepared = PreparedNtfsShrink.fromJson(raw, expected: expected);
      expect(prepared.json, base['response']);
      expect(prepared.targetBytes, expected.plan.retainedSourceBytes);
      raw['preparation']['toolchain']['epoch'] = 99;
      raw['inspection']['minimumBytes'] = 1;
      prepared.json['plan']['root']['startSector'] = 0;
      prepared.json['preparation']['toolchain']['release'] = 'changed';
      expect(prepared.json, base['response']);
    });
  }
  for (final raw in cases['invalid'] as List) {
    final row = raw as Map<String, dynamic>;
    test('prepared evidence rejects ${row['name']}', () {
      expect(
        () => PreparedNtfsShrink.fromJson(
          mutate(first['response'], row),
          expected: assessment(first),
        ),
        throwsFormatException,
      );
    });
  }
  test(
    'v2 helper sends minimal target intent without caller minimum or authority',
    () async {
      final process = f.FakeHelperProcess(f.messages([response(first)]));
      final client = HelperClient(
        protocolVersion: 2,
        start: (executable, args) async {
          expect(executable, '/usr/bin/pkexec');
          expect(args.last, '--protocol=2');
          return process;
        },
      );
      final expected = assessment(first);
      final result = await client.prepareNtfsShrink(expected);
      expect(result.json, first['response']);
      expect(jsonDecode(process.sent), {
        'protocolVersion': 2,
        'operation': 'prepare-ntfs-shrink',
        'disk': expected.plan.snapshot.device.path,
        'expectedDevice': expected.plan.snapshot.device.expected,
        'tableFingerprint': expected.plan.snapshot.tableFingerprint,
        'sourceNumber': expected.plan.source.number,
        'espNumber': expected.plan.esp.number,
        'rootBytes': expected.plan.rootBytes,
        'inspectionFingerprint': expected.inspectionFingerprint,
      });
      expect(process.closed, isTrue);
    },
  );
  test(
    'v1 refuses before launch and malformed evidence is protocol failure',
    () async {
      var starts = 0;
      await expectLater(
        HelperClient(
          protocolVersion: 1,
          start: (_, _) async {
            starts++;
            throw StateError('no start');
          },
        ).prepareNtfsShrink(assessment(first)),
        throwsA(f.helperError('INVALID_REQUEST')),
      );
      expect(starts, 0);
      final bad = clone(response(first));
      bad['preparation']['targetBytes']++;
      await expectLater(
        HelperClient(
          protocolVersion: 2,
          start: (_, _) async => f.FakeHelperProcess(f.messages([bad])),
        ).prepareNtfsShrink(assessment(first)),
        throwsA(f.helperError('PROTOCOL_ERROR')),
      );
    },
  );
  test(
    'qualified tool refusal stays actionable without raw diagnostics',
    () async {
      final process = f.FakeHelperProcess(
        f.messages([
          {
            'protocolVersion': 2,
            'type': 'result',
            'operation': 'prepare-ntfs-shrink',
            'ok': false,
            'error': {
              'code': 'NTFS_TOOLS_UNSUPPORTED',
              'message': 'Matching NTFS tools are required.',
            },
          },
        ]),
        status: 4,
      );
      await expectLater(
        HelperClient(
          protocolVersion: 2,
          start: (_, _) async => process,
        ).prepareNtfsShrink(assessment(first)),
        throwsA(f.helperError('NTFS_TOOLS_UNSUPPORTED')),
      );
    },
  );
  test('preparation uses its dedicated read-only deadline', () async {
    final process = f.FakeHelperProcess(
      Stream.fromFuture(
        Future.delayed(
          const Duration(milliseconds: 30),
          () => utf8.encode('${jsonEncode(response(first))}\n'),
        ),
      ),
    );
    final prepared = await HelperClient(
      protocolVersion: 2,
      start: (_, _) async => process,
      readTimeout: const Duration(milliseconds: 1),
      preparationTimeout: const Duration(seconds: 2),
    ).prepareNtfsShrink(assessment(first));
    expect(prepared.json, first['response']);
  });
  test('preparation deadline is total and stops a read-only helper', () async {
    final process = f.FakeHelperProcess(
      Stream.periodic(const Duration(milliseconds: 1), (_) => [32]),
    );
    await expectLater(
      HelperClient(
        protocolVersion: 2,
        start: (_, _) async => process,
        preparationTimeout: const Duration(milliseconds: 20),
      ).prepareNtfsShrink(assessment(first)),
      throwsA(f.helperError('TIMEOUT')),
    );
    expect(process.terminated, isTrue);
  });
}
