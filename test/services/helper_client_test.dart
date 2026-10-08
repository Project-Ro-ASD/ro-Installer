import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:ro_installer/services/helper_client.dart';
import 'package:ro_installer/services/helper_protocol.dart';

class FakeHelperProcess implements HelperProcess {
  FakeHelperProcess(
    this.output, {
    this.status = 0,
    this.diagnostics = const Stream.empty(),
  });
  @override
  final Stream<List<int>> output;
  @override
  final Stream<List<int>> diagnostics;
  final int status;
  String sent = '';
  bool closed = false;
  bool terminated = false;
  @override
  Future<int> get exitCode async => status;
  @override
  void send(String text) {
    sent += text;
  }

  @override
  Future<void> closeInput() async {
    closed = true;
  }

  @override
  void terminate() {
    terminated = true;
  }
}

final identity = DeviceIdentity(
  path: '/dev/vda',
  majorMinor: '252:0',
  size: 68719476736,
  diskSequence: 11,
);
Map<String, dynamic> result(
  String operation, [
  Map<String, dynamic> payload = const {},
]) => {
  'protocolVersion': 1,
  'type': 'result',
  'operation': operation,
  'ok': true,
  ...payload,
};
Stream<List<int>> messages(List<Map<String, dynamic>> data) =>
    Stream.fromIterable(data.map((e) => utf8.encode('${jsonEncode(e)}\n')));
Matcher helperError(String code) =>
    isA<HelperException>().having((e) => e.code, 'code', code);

void main() {
  test('probe deadline is total even when output keeps arriving', () async {
    final process = FakeHelperProcess(
      Stream.periodic(const Duration(milliseconds: 1), (_) => [32]),
    );
    final client = HelperClient(
      start: (_, _) async => process,
      readTimeout: const Duration(milliseconds: 20),
    );
    await expectLater(
      client.probe('/dev/vda'),
      throwsA(helperError('TIMEOUT')),
    );
    expect(process.terminated, isTrue);
  });
  test('fixed pkexec argv, strict probe serialization and EOF', () async {
    final process = FakeHelperProcess(
      messages([
        result('probe-disk', {'device': identity.json}),
      ]),
    );
    final client = HelperClient(
      start: (executable, args) async {
        expect(executable, '/usr/bin/pkexec');
        expect(args, [
          '--disable-internal-agent',
          '/usr/libexec/ro-installer-helper',
          '--protocol=1',
        ]);
        return process;
      },
    );
    expect((await client.probe('/dev/vda')).json, identity.json);
    expect(jsonDecode(process.sent), {
      'protocolVersion': 1,
      'operation': 'probe-disk',
      'disk': '/dev/vda',
    });
    expect(process.closed, isTrue);
    expect(process.terminated, isFalse);
    await expectLater(
      client.probe('/dev/vda;id'),
      throwsA(helperError('INVALID_REQUEST')),
    );
  });
  for (final entry in {
    126: 'AUTH_CANCELLED',
    127: 'AUTH_DENIED',
    9: 'HELPER_FAILED',
  }.entries) {
    test('pkexec status ${entry.key} is distinct', () async {
      final client = HelperClient(
        start: (_, _) async =>
            FakeHelperProcess(const Stream.empty(), status: entry.key),
      );
      await expectLater(
        client.probe('/dev/vda'),
        throwsA(helperError(entry.value)),
      );
    });
  }
  test('missing pkexec never falls back', () async {
    var attempts = 0;
    final client = HelperClient(
      start: (_, _) async {
        attempts++;
        throw const ProcessException('pkexec', [], 'secret');
      },
    );
    await expectLater(
      client.probe('/dev/vda'),
      throwsA(helperError('PKEXEC_UNAVAILABLE')),
    );
    expect(attempts, 1);
  });
  test('structured helper error is sanitized and propagated', () async {
    final client = HelperClient(
      start: (_, _) async => FakeHelperProcess(
        messages([
          {
            'protocolVersion': 1,
            'type': 'result',
            'operation': 'probe-disk',
            'ok': false,
            'error': {
              'code': 'UNSAFE_DEVICE',
              'message': 'untrusted detail secret',
            },
          },
        ]),
        status: 4,
      ),
    );
    await expectLater(
      client.probe('/dev/vda'),
      throwsA(helperError('UNSAFE_DEVICE')),
    );
  });
  for (final raw in [
    'not-json\n',
    '{"protocolVersion":1,"type":"exec"}\n',
    '{"protocolVersion":1,"protocolVersion":1}\n',
    '${jsonEncode(result('probe-disk', {'device': identity.json}))}\ntrailing',
    '${jsonEncode(result('probe-disk', {'device': identity.json, 'command': 'sh'}))}\n',
  ]) {
    test(
      'malformed/incompatible response is rejected: ${raw.length}',
      () async {
        final client = HelperClient(
          start: (_, _) async =>
              FakeHelperProcess(Stream.value(utf8.encode(raw))),
        );
        await expectLater(
          client.probe('/dev/vda'),
          throwsA(helperError('PROTOCOL_ERROR')),
        );
      },
    );
  }
  test('unknown helper error codes fail closed', () async {
    final client = HelperClient(
      start: (_, _) async => FakeHelperProcess(
        messages([
          {
            'protocolVersion': 1,
            'type': 'result',
            'operation': 'probe-disk',
            'ok': false,
            'error': {'code': 'UNRECOGNIZED_CODE', 'message': 'uncontrolled'},
          },
        ]),
        status: 9,
      ),
    );
    await expectLater(
      client.probe('/dev/vda'),
      throwsA(helperError('PROTOCOL_ERROR')),
    );
  });
  test('bounded line and stderr output', () async {
    final client = HelperClient(
      start: (_, _) async => FakeHelperProcess(
        Stream.value(List.filled(helperLineLimit + 1, 120)),
      ),
    );
    await expectLater(
      client.probe('/dev/vda'),
      throwsA(helperError('OUTPUT_LIMIT')),
    );
    final noisy = HelperClient(
      start: (_, _) async => FakeHelperProcess(
        messages([
          result('probe-disk', {'device': identity.json}),
        ]),
        diagnostics: Stream.value(List.filled(65537, 120)),
      ),
    );
    await expectLater(
      noisy.probe('/dev/vda'),
      throwsA(helperError('OUTPUT_LIMIT')),
    );
  });
  test('read-only timeout terminates only read-only request', () async {
    final output = StreamController<List<int>>();
    final process = FakeHelperProcess(output.stream);
    final client = HelperClient(
      start: (_, _) async => process,
      readTimeout: const Duration(milliseconds: 10),
    );
    await expectLater(
      client.probe('/dev/vda'),
      throwsA(helperError('TIMEOUT')),
    );
    expect(process.terminated, isTrue);
    await output.close();
  });
  test(
    'install uses confirmed identity, bounded progress and explicit final success',
    () async {
      final process = FakeHelperProcess(
        messages([
          {
            'protocolVersion': 1,
            'type': 'progress',
            'stage': 2,
            'progress': 0.2,
            'messageKey': helperStageKeys[2],
          },
          result('install-full-disk', {'installed': true}),
        ]),
      );
      final client = HelperClient(start: (_, _) async => process);
      final events = <double>[];
      await client.install(identity, (p, key) {
        events.add(p);
        expect(key, helperStageKeys[2]);
      });
      expect(events, [0.2]);
      expect(jsonDecode(process.sent), identity.installRequest);
      expect(process.terminated, isFalse);
    },
  );
  test('EOF or nonzero exit cannot fake successful install', () async {
    for (final process in [
      FakeHelperProcess(const Stream.empty()),
      FakeHelperProcess(
        messages([
          result('install-full-disk', {'installed': true}),
        ]),
        status: 9,
      ),
    ]) {
      final client = HelperClient(start: (_, _) async => process);
      await expectLater(
        client.install(identity, (_, _) {}),
        throwsA(isA<HelperException>()),
      );
      expect(process.terminated, isFalse);
    }
  });
  test('unknown or injected progress text is never forwarded', () async {
    final client = HelperClient(
      start: (_, _) async => FakeHelperProcess(
        messages([
          {
            'protocolVersion': 1,
            'type': 'progress',
            'stage': 2,
            'progress': 0.2,
            'messageKey': 'secret command',
          },
          result('install-full-disk', {'installed': true}),
        ]),
      ),
    );
    await expectLater(
      client.install(identity, (_, _) => fail('Untrusted progress')),
      throwsA(helperError('PROTOCOL_ERROR')),
    );
  });
}
