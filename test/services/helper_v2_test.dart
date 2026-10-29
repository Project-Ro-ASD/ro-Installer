import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:ro_installer/services/helper_client.dart';
import 'package:ro_installer/services/session_report.dart';
import 'helper_client_test.dart' as f;

Map<String, dynamic> fixture() =>
    jsonDecode(File('test/fixtures/session_report.json').readAsStringSync())
        as Map<String, dynamic>;
Map<String, dynamic> terminal({bool ok = true}) => {
  'protocolVersion': 2,
  'type': 'result',
  'operation': 'install-full-disk',
  'ok': ok,
  if (ok)
    'installed': true
  else
    'error': {'code': 'INSTALL_FAILED', 'message': 'failure'},
};
Map<String, dynamic> report(dynamic value) => {
  'protocolVersion': 2,
  'type': 'session-report',
  'status': 'available',
  'report': value,
};
void main() {
  test(
    'central report schema rejects secrets wrong types impossible success and oversized values',
    () {
      final valid = fixture();
      expect(SessionReport.parse(valid), isNotNull);
      for (final invalid in [
        {...valid, 'stdout': 'SECRET_SENTINEL'},
        {...valid, 'remainingResources': true},
        {...valid, 'sessionId': 'SECRET_SENTINEL'},
        {...valid, 'cleanupStatus': 'failed'},
        {...valid, 'primaryError': 'SECRET_SENTINEL'},
      ]) {
        expect(SessionReport.parse(invalid), isNull);
      }
    },
  );
  for (final ok in [true, false]) {
    test('v2 safe report is delivered for terminal ok=$ok', () async {
      final process = f.FakeHelperProcess(
        f.messages([report(fixture()), terminal(ok: ok)]),
        status: ok ? 0 : 8,
      );
      final client = HelperClient(
        protocolVersion: 2,
        start: (exe, args) async {
          expect(args.last, '--protocol=2');
          return process;
        },
      );
      final statuses = <String>[];
      final future = client.installWithReport(
        f.identity,
        (_, _) {},
        onReport: (r, status) {
          statuses.add(status);
          expect(r, isNotNull);
        },
      );
      if (ok) {
        await future;
      } else {
        await expectLater(future, throwsA(f.helperError('INSTALL_FAILED')));
      }
      expect(statuses, ['available']);
      expect(jsonDecode(process.sent)['protocolVersion'], 2);
    });
  }
  for (final mode in [
    'missing',
    'invalid',
    'duplicate',
    'after-result',
    'progress-after-report',
    'partial',
    'oversized',
    'eof',
    'nonzero',
  ]) {
    test('v2 report/protocol distinction $mode', () async {
      final values = <Map<String, dynamic>>[
        if (mode != 'missing' && mode != 'eof')
          report(
            mode == 'invalid' ? {'password': 'SECRET_SENTINEL'} : fixture(),
          ),
        if (mode == 'duplicate') report(fixture()),
        if (mode == 'progress-after-report')
          {
            'protocolVersion': 2,
            'type': 'progress',
            'stage': 9,
            'progress': 1,
            'messageKey': 'install_stage_cleanup',
          },
        if (mode != 'eof') terminal(),
        if (mode == 'after-result') report(fixture()),
      ];
      Stream<List<int>> stream = f.messages(values);
      if (mode == 'partial') {
        stream = Stream.value(utf8.encode('{"protocolVersion":2'));
      }
      if (mode == 'oversized') stream = Stream.value(List.filled(9000, 120));
      final process = f.FakeHelperProcess(
        stream,
        status: mode == 'nonzero' ? 9 : 0,
      );
      final client = HelperClient(
        protocolVersion: 2,
        start: (_, _) async => process,
      );
      final statuses = <String>[];
      final future = client.installWithReport(
        f.identity,
        (_, _) {},
        onReport: (r, status) => statuses.add(status),
      );
      if (const ['missing', 'invalid'].contains(mode)) {
        await future;
        expect(statuses, [mode == 'missing' ? 'unavailable' : 'invalid']);
      } else {
        await expectLater(future, throwsA(isA<HelperException>()));
      }
    });
  }
  test('fragmented v2 JSON and progress validated without downgrade', () async {
    final text =
        '${[
          {
            'protocolVersion': 2,
            'type': 'progress',
            'stage': 5,
            'progress': 0.5,
            'messageKey': 'install_stage_file_copy',
          },
          report(fixture()),
          terminal(),
        ].map(jsonEncode).join('\n')}\n';
    final client = HelperClient(
      protocolVersion: 2,
      start: (_, _) async => f.FakeHelperProcess(
        Stream.fromIterable(utf8.encode(text).map((b) => [b])),
      ),
    );
    final progress = <double>[];
    await client.installWithReport(f.identity, (p, _) => progress.add(p));
    expect(progress, [0.5]);
  });
  test(
    'v1 still rejects session-report and unknown versions never start helper',
    () async {
      final client = HelperClient(
        start: (_, _) async =>
            f.FakeHelperProcess(f.messages([report(fixture()), terminal()])),
      );
      await expectLater(
        client.install(f.identity, (_, _) {}),
        throwsA(f.helperError('PROTOCOL_ERROR')),
      );
      final unknown = HelperClient(
        protocolVersion: 3,
        start: (_, _) async => throw StateError('must not start'),
      );
      await expectLater(
        unknown.install(f.identity, (_, _) {}),
        throwsA(f.helperError('INVALID_REQUEST')),
      );
    },
  );
}
