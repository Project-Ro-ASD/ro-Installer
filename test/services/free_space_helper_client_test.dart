import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:ro_installer/models/gpt_disk_snapshot.dart';
import 'package:ro_installer/models/free_space_installation_plan.dart';
import 'package:ro_installer/services/helper_client.dart';
import 'helper_client_test.dart' as f;

Map<String, dynamic> fixture(String name) =>
    jsonDecode(File('test/fixtures/$name.json').readAsStringSync())
        as Map<String, dynamic>;
Map<String, dynamic> response(String op, Map<String, dynamic> value) => {
  ...f.result(op, value),
  'protocolVersion': 2,
};
FreeSpaceInstallationPlan proposal() {
  final s = GptDiskSnapshot.fromJson(fixture('gpt_probe_snapshot_v1'));
  return FreeSpaceInstallationPlan.build(s, s.freeExtents.first);
}

void main() {
  test('Python GPT reader and Dart planner agree on compact intent', () {
    expect(proposal().intentJson, fixture('free_space_intent_v1'));
    final exported = proposal().intentJson;
    exported['esp']['startSector'] = 1;
    expect(proposal().intentJson, fixture('free_space_intent_v1'));
  });
  test(
    'v2 probe has fixed request and validates normalized snapshot identity',
    () async {
      final data = fixture('gpt_probe_snapshot_v1');
      final process = f.FakeHelperProcess(
        f.messages([
          response('probe-free-space', {'snapshot': data}),
        ]),
      );
      final client = HelperClient(
        protocolVersion: 2,
        start: (_, args) async {
          expect(args.last, '--protocol=2');
          return process;
        },
      );
      expect((await client.probeFreeSpace('/dev/vda')).json, data);
      expect(jsonDecode(process.sent), {
        'protocolVersion': 2,
        'operation': 'probe-free-space',
        'disk': '/dev/vda',
      });
    },
  );
  test(
    'v2 validates only compact selected intent and verifies helper recomputation',
    () async {
      final plan = proposal();
      final process = f.FakeHelperProcess(
        f.messages([
          response('validate-free-space-plan', {'plan': plan.intentJson}),
        ]),
      );
      expect(
        await HelperClient(
          protocolVersion: 2,
          start: (_, _) async => process,
        ).validateFreeSpacePlan(plan),
        same(plan),
      );
      expect(jsonDecode(process.sent), {
        'protocolVersion': 2,
        'operation': 'validate-free-space-plan',
        'disk': plan.snapshot.device.path,
        'expectedDevice': plan.snapshot.device.expected,
        'tableFingerprint': plan.snapshot.tableFingerprint,
        'selectedExtent': plan.selectedExtent.json,
      });
      expect(process.sent, isNot(contains('partitions')));
      expect(process.sent.length, lessThan(1024));
    },
  );
  test('v1 and malformed paths never launch privileged helper', () async {
    var starts = 0;
    Future<f.FakeHelperProcess> start(String exe, List<String> args) async {
      starts++;
      throw StateError('must not launch');
    }

    await expectLater(
      HelperClient(start: start).probeFreeSpace('/dev/vda'),
      throwsA(f.helperError('INVALID_REQUEST')),
    );
    await expectLater(
      HelperClient(start: start).validateFreeSpacePlan(proposal()),
      throwsA(f.helperError('INVALID_REQUEST')),
    );
    for (final path in ['/tmp/raw', '/dev/vda;id', '/dev/../vda']) {
      await expectLater(
        HelperClient(protocolVersion: 2, start: start).probeFreeSpace(path),
        throwsA(f.helperError('INVALID_REQUEST')),
      );
    }
    expect(starts, 0);
  });
  test(
    'unknown snapshot fields wrong path and unsafe geometry reject',
    () async {
      final data = fixture('gpt_probe_snapshot_v1');
      for (final changed in [
        {...data, 'command': 'sh'},
        {
          ...data,
          'device': {...data['device'], 'path': '/dev/vdb'},
        },
        {...data, 'entryCount': true},
        {...data, 'logicalSectorBytes': 1024},
      ]) {
        final process = f.FakeHelperProcess(
          f.messages([
            response('probe-free-space', {'snapshot': changed}),
          ]),
        );
        await expectLater(
          HelperClient(
            protocolVersion: 2,
            start: (_, _) async => process,
          ).probeFreeSpace('/dev/vda'),
          throwsA(f.helperError('PROTOCOL_ERROR')),
        );
      }
    },
  );
  test(
    'malformed helper plans never replace the proposed immutable plan',
    () async {
      final plan = proposal();
      for (final changed in [
        null,
        {},
        {...plan.intentJson, 'diskSwap': true},
        {
          ...plan.intentJson,
          'esp': {...plan.intentJson['esp'], 'number': 1},
        },
        {...plan.intentJson, 'tableFingerprint': 'b' * 64},
        {...plan.intentJson, 'schemaVersion': 1.0},
      ]) {
        final process = f.FakeHelperProcess(
          f.messages([
            response('validate-free-space-plan', {'plan': changed}),
          ]),
        );
        await expectLater(
          HelperClient(
            protocolVersion: 2,
            start: (_, _) async => process,
          ).validateFreeSpacePlan(plan),
          throwsA(f.helperError('PROTOCOL_ERROR')),
        );
      }
    },
  );
  test('stale table errors are preserved as helper errors', () async {
    final message = response('validate-free-space-plan', {
      'error': {
        'code': 'DEVICE_CHANGED',
        'message': 'Partition table changed.',
      },
    })..['ok'] = false;
    final process = f.FakeHelperProcess(f.messages([message]), status: 4);
    await expectLater(
      HelperClient(
        protocolVersion: 2,
        start: (_, _) async => process,
      ).validateFreeSpacePlan(proposal()),
      throwsA(f.helperError('DEVICE_CHANGED')),
    );
  });
}
