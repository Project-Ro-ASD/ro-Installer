import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:ro_installer/models/manual_installation_plan.dart';
import 'package:ro_installer/services/helper_client.dart';
import '../models/manual_installation_plan_test.dart' as m;
import 'helper_client_test.dart' as f;

ManualInstallationPlan proposal() =>
    ManualInstallationPlan.fromJson(m.fixture());
Map<String, dynamic> response(Object? plan) => {
  ...f.result('validate-manual-plan', {'plan': plan}),
  'protocolVersion': 2,
};

void main() {
  test(
    'Python and Dart agree on role combinations, sector geometry and invalid choices',
    () async {
      final cases = <Map<String, dynamic>>[];
      for (final sector in [512, 4096]) {
        for (final esp in [false, true]) {
          for (final root in [false, true]) {
            final value = m.fixture(sector: sector);
            if (esp) value['esp'] = m.create(80 * m.gib, 81 * m.gib, sector);
            if (root) {
              value['root'] = m.create(100 * m.gib, 150 * m.gib, sector);
            }
            cases.add(value);
          }
        }
        for (final mutation in <void Function(Map<String, dynamic>)>[
          (v) => v['root']['formatOnInstall'] = false,
          (v) => v['root']['formatOnInstall'] = 1,
          (v) => v['root']['number'] = true,
          (v) => v['esp']['number'] = 2,
          (v) => v['root']['number'] = 7,
          (v) => v['root']['path'] = '/dev/vdb2',
          (v) => v['snapshot']['partitions'][0]['attributesHex'] =
              '1000000000000000',
          (v) => v['root'] = m.create(79 * m.gib, 130 * m.gib, sector),
          (v) => v['root'] = m.create(80 * m.gib, 119 * m.gib, sector),
          (v) {
            v['esp'] = m.create(90 * m.gib, 91 * m.gib, sector);
            v['root'] = m.create(80 * m.gib, 150 * m.gib, sector);
          },
          (v) => v['root'] = {
            'source': 'create',
            'startSector': 80 * m.gib ~/ sector + 1,
            'endSector': 150 * m.gib ~/ sector - 1,
          },
        ]) {
          final value = m.fixture(sector: sector);
          mutation(value);
          cases.add(value);
        }
      }
      final expected = cases.map((v) {
        try {
          return {
            'ok': true,
            'plan': ManualInstallationPlan.fromJson(v).intentJson,
          };
        } on FormatException {
          return {'ok': false};
        }
      }).toList();
      final result = await Process.run('python3', [
        '-I',
        '-B',
        'test/scripts/manual_plan_parity.py',
        jsonEncode(cases),
      ]);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      expect(jsonDecode(result.stdout as String), expected);
    },
  );
  test(
    'v2 sends choices only and requires the exact independently computed intent',
    () async {
      final plan = proposal();
      final process = f.FakeHelperProcess(
        f.messages([response(plan.intentJson)]),
      );
      final client = HelperClient(
        protocolVersion: 2,
        start: (_, args) async {
          expect(args.last, '--protocol=2');
          return process;
        },
      );
      expect(await client.validateManualPlan(plan), same(plan));
      expect(jsonDecode(process.sent), {
        'protocolVersion': 2,
        'operation': 'validate-manual-plan',
        'disk': '/dev/vda',
        'expectedDevice': plan.snapshot.device.expected,
        'tableFingerprint': plan.snapshot.tableFingerprint,
        'esp': plan.esp.choice.json,
        'root': plan.root.choice.json,
      });
    },
  );
  test('v1 manual validation is rejected before launching pkexec', () async {
    var starts = 0;
    final client = HelperClient(
      start: (_, _) async {
        starts++;
        throw StateError('unexpected');
      },
    );
    await expectLater(
      client.validateManualPlan(proposal()),
      throwsA(f.helperError('INVALID_REQUEST')),
    );
    expect(starts, 0);
  });
  test(
    'changed format decisions, source identity, unexpected fields or success exit mismatch fail',
    () async {
      for (final mutation in <void Function(Map<String, dynamic>)>[
        (v) => v['esp']['formatOnInstall'] = true,
        (v) =>
            v['root']['partitionGuid'] = '55555555-5555-5555-5555-555555555555',
        (v) => v['device']['diskSequence'] = 12,
        (v) => v['tableFingerprint'] = 'b' * 64,
        (v) => v['root']['number'] = 7,
        (v) => v['diskSwap'] = true,
        (v) => v['extra'] = true,
      ]) {
        final value = proposal().intentJson;
        mutation(value);
        final process = f.FakeHelperProcess(f.messages([response(value)]));
        await expectLater(
          HelperClient(
            protocolVersion: 2,
            start: (_, _) async => process,
          ).validateManualPlan(proposal()),
          throwsA(f.helperError('PROTOCOL_ERROR')),
        );
      }
      final process = f.FakeHelperProcess(
        f.messages([response(proposal().intentJson)]),
        status: 1,
      );
      await expectLater(
        HelperClient(
          protocolVersion: 2,
          start: (_, _) async => process,
        ).validateManualPlan(proposal()),
        throwsA(isA<HelperException>()),
      );
    },
  );
}
