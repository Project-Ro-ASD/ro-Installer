import 'dart:convert';
import 'package:test/test.dart';
import 'package:ro_installer/services/privileged_backend.dart';
import 'package:ro_installer/services/helper_protocol.dart';
import 'package:ro_installer/services/fake_command_runner.dart';
import 'package:ro_installer/services/install_service.dart';
import 'package:ro_installer/services/install_localizer.dart';

final identity = DeviceIdentity(
  path: '/dev/vda',
  majorMinor: '252:0',
  size: 68719476736,
  diskSequence: 11,
);
Map<String, dynamic> get request => {
  'protocolVersion': 1,
  'operation': 'install-full-disk',
  'disk': identity.path,
  'expectedDevice': identity.expected,
};
Map<String, dynamic> get gate => {
  'protocolVersion': 1,
  'type': 'continue',
  'device': identity.json,
};
Stream<List<int>> input(List<Map<String, dynamic>> data) =>
    Stream.value(utf8.encode('${data.map(jsonEncode).join('\n')}\n'));

class BridgeEngine extends InstallService {
  BridgeEngine({this.success = true, this.useGate = true});
  final bool success;
  final bool useGate;
  Map<String, dynamic>? state;
  @override
  Future<bool> runInstall(
    Map<String, dynamic> state,
    void Function(double, String) onProgress,
    void Function(String) onTechnicalLog, {
    bool isMock = false,
    InstallTranslator? translate,
    Future<void> Function()? beforeFirstMutation,
    void Function(int)? onStage,
  }) async {
    this.state = Map.of(state);
    if (useGate) await beforeFirstMutation!();
    onStage?.call(5);
    onProgress(0.6, 'arbitrary secret must never cross protocol');
    onTechnicalLog('password secret');
    return success;
  }
}

void main() {
  test(
    'fixed normalized full/Btrfs state reuses engine and explicit result',
    () async {
      final events = <Map<String, dynamic>>[];
      final engine = BridgeEngine();
      expect(
        await runPrivilegedBackend(
          input([request, gate]),
          events.add,
          service: engine,
          rootCheck: () async => true,
        ),
        0,
      );
      expect(engine.state, {
        'selectedDisk': '/dev/vda',
        'partitionMethod': 'full',
        'fileSystem': 'btrfs',
        'selectedLanguage': 'en',
      });
      expect(events.last, {
        'protocolVersion': 1,
        'type': 'result',
        'ok': true,
        'code': 'OK',
      });
      expect(jsonEncode(events), isNot(contains('secret')));
      expect(events.where((e) => e['type'] == 'ready').length, 1);
    },
  );
  test('stage failure or success without gate is failure', () async {
    for (final engine in [
      BridgeEngine(success: false),
      BridgeEngine(useGate: false),
    ]) {
      final events = <Map<String, dynamic>>[];
      expect(
        await runPrivilegedBackend(
          input([request, gate]),
          events.add,
          service: engine,
          rootCheck: () async => true,
        ),
        8,
      );
      expect(events.last['ok'], false);
    }
  });
  test('root required and identity gate cannot switch targets', () async {
    for (final root in [false, true]) {
      final events = <Map<String, dynamic>>[];
      final wrong = {
        'protocolVersion': 1,
        'type': 'continue',
        'device': {...identity.json, 'path': '/dev/sda'},
      };
      expect(
        await runPrivilegedBackend(
          input([request, wrong]),
          events.add,
          service: BridgeEngine(),
          rootCheck: () async => root,
        ),
        9,
      );
      expect(events.last['code'], 'BACKEND_ERROR');
    }
  });
  test(
    'unknown backend fields, versions, paths and operations rejected before engine',
    () async {
      for (final invalid in [
        {...request, 'command': 'sh'},
        {...request, 'protocolVersion': 2},
        {...request, 'protocolVersion': 1.0},
        {...request, 'operation': 'exec'},
        {...request, 'disk': '/dev/vda;id'},
        {
          ...request,
          'expectedDevice': {...identity.expected, 'path': '/dev/sda'},
        },
      ]) {
        final engine = BridgeEngine();
        final events = <Map<String, dynamic>>[];
        expect(
          await runPrivilegedBackend(
            input([invalid, gate]),
            events.add,
            service: engine,
            rootCheck: () async => true,
          ),
          9,
        );
        expect(engine.state, isNull);
      }
    },
  );
  test(
    'extra backend messages are rejected before mutation permission',
    () async {
      final events = <Map<String, dynamic>>[];
      expect(
        await runPrivilegedBackend(
          input([
            request,
            gate,
            {'type': 'exec'},
          ]),
          events.add,
          service: BridgeEngine(),
          rootCheck: () async => true,
        ),
        9,
      );
      expect(events.last['code'], 'BACKEND_ERROR');
    },
  );
  test(
    'real nine-stage engine executes under fake runner with one pre-wipe gate',
    () async {
      final runner = FakeCommandRunner();
      final stages = <int>[];
      var gates = 0;
      final ok = await InstallService(commandRunner: runner).runInstall(
        {
          'selectedDisk': '/dev/vda',
          'partitionMethod': 'full',
          'fileSystem': 'btrfs',
          'selectedLanguage': 'en',
        },
        (_, _) {},
        (_) {},
        isMock: true,
        onStage: stages.add,
        beforeFirstMutation: () async {
          gates++;
          expect(runner.wasCommandCalled('wipefs'), false);
        },
      );
      expect(ok, true);
      expect(stages, List.generate(9, (i) => i + 1));
      expect(gates, 1);
      expect(runner.wasCalledWith('wipefs', ['-a', '/dev/vda']), true);
      expect(runner.wasCalledWith('swapoff', ['-a']), false);
      expect(
        runner.commandLog
            .where((c) => c.command.startsWith('mkfs.'))
            .every((c) => c.args.last.startsWith('/dev/vda')),
        true,
      );
    },
  );
  test('failed pre-wipe authorization prevents all disk writes', () async {
    final runner = FakeCommandRunner();
    expect(
      await InstallService(commandRunner: runner).runInstall(
        {
          'selectedDisk': '/dev/vda',
          'partitionMethod': 'full',
          'fileSystem': 'btrfs',
        },
        (_, _) {},
        (_) {},
        isMock: true,
        beforeFirstMutation: () async => throw const FormatException('Denied'),
      ),
      false,
    );
    expect(runner.wasCommandCalled('wipefs'), false);
    expect(runner.wasCommandCalled('sgdisk'), false);
    expect(runner.commandLog.any((c) => c.command.startsWith('mkfs.')), false);
  });
}
