import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ro_installer/main.dart';
import 'package:ro_installer/l10n/installer_translation_catalog.dart';
import 'package:ro_installer/services/fake_command_runner.dart';
import 'package:ro_installer/services/install_service.dart';
import 'package:ro_installer/services/install_localizer.dart';
import 'services/install_service_finalization_test.dart'
    show PipelineGraph, engine, noMutation;

class CapturingInstallService extends InstallService {
  CapturingInstallService(FakeCommandRunner runner)
    : super(commandRunner: runner);
  final states = <Map<String, dynamic>>[];
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
    states.add(Map.of(state));
    return false; // Stop before target operations; exercise the real auto entry point.
  }
}

class SuccessfulInstallService extends CapturingInstallService {
  SuccessfulInstallService(super.runner);
  @override
  Future<bool> runInstall(
    Map<String, dynamic> state,
    void Function(double, String) onProgress,
    void Function(String) onTechnicalLog, {
    bool isMock = false,
    InstallTranslator? translate,
    Future<void> Function()? beforeFirstMutation,
    void Function(int)? onStage,
  }) async => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late InstallerTranslationCatalog catalog;
  late FakeCommandRunner runner;
  late CapturingInstallService service;
  setUp(() async {
    temp = Directory.systemTemp.createTempSync('pr05-profile-');
    catalog = await InstallerTranslationCatalog.loadBundled();
    runner = FakeCommandRunner(defaultSuccess: false);
    service = CapturingInstallService(runner);
  });
  tearDown(() {
    temp.deleteSync(recursive: true);
  });
  Map<String, dynamic> valid() => {
    'selectedDisk': '/dev/vda',
    'partitionMethod': 'full',
    'fileSystem': 'btrfs',
    'selectedLanguage': 'tr',
    'confirmDestructive': true,
  };
  Future<int> run(Map<String, dynamic> input) async {
    final file = File('${temp.path}/profile.json')
      ..writeAsStringSync(jsonEncode(input));
    return runAutoInstall(file.path, runner, catalog, installService: service);
  }

  test(
    'root auto uses actual early shared gate and export cannot change failure',
    () async {
      final graph = PipelineGraph()
        ..addResponse('sh', [
          '-c',
          'command -v rsync >/dev/null 2>&1',
        ], exitCode: 1);
      final file = File('${temp.path}/shared.json')
        ..writeAsStringSync(jsonEncode(valid()));
      expect(
        await runAutoInstall(
          file.path,
          graph,
          catalog,
          installService: engine(graph),
          exportSession:
              ({
                required startedAt,
                required finishedAt,
                required success,
                required finalStatus,
                required statusHistory,
                required technicalLogs,
                required installContext,
              }) async {
                expect(success, isFalse);
                throw StateError('export failure');
              },
        ),
        1,
      );
      noMutation(graph);
    },
  );
  test('root auto verified result survives export exception', () async {
    final file = File('${temp.path}/export.json')
      ..writeAsStringSync(jsonEncode(valid()));
    final passing = SuccessfulInstallService(runner);
    expect(
      await runAutoInstall(
        file.path,
        runner,
        catalog,
        installService: passing,
        exportSession:
            ({
              required startedAt,
              required finishedAt,
              required success,
              required finalStatus,
              required statusHistory,
              required technicalLogs,
              required installContext,
            }) async {
              expect(success, isTrue);
              throw StateError('export failure');
            },
      ),
      0,
    );
  });
  test(
    'auto profile reaches engine without identity, secret or kernel policy',
    () async {
      expect(
        await run({
          ...valid(),
          'username': 'legacy-user',
          'password': 'legacy-secret',
          'timezone': 'Asia/Tokyo',
          'kernelChannels': ['experimental'],
        }),
        1,
      );
      expect(service.states, hasLength(1));
      final state = service.states.single;
      expect(state.keys.toSet(), {
        'schemaVersion',
        'selectedDisk',
        'partitionMethod',
        'fileSystem',
        'selectedLanguage',
        'confirmDestructive',
        'encryptionEnabled',
        'vmTestMode',
      });
      expect(state['selectedLanguage'], 'tr');
      expect(jsonEncode(state), isNot(contains('legacy-secret')));
      expect(jsonEncode(state), isNot(contains('legacy-user')));
      expect(runner.commandLog, isEmpty);
    },
  );
  for (final invalid in [
    {'confirmDestructive': false},
    {'partitionMethod': 'manual'},
    {'fileSystem': 'ext4'},
    {'encryptionEnabled': true},
    {
      'storage': {
        'encryption': {'enabled': true, 'passphrase': 'secret'},
      },
    },
  ]) {
    test(
      'invalid auto profile is rejected before engine or disk commands',
      () async {
        expect(await run({...valid(), ...invalid}), 2);
        expect(service.states, isEmpty);
        expect(runner.commandLog, isEmpty);
      },
    );
  }
  test('missing consent fails before engine', () async {
    final input = valid()..remove('confirmDestructive');
    expect(await run(input), 2);
    expect(service.states, isEmpty);
    expect(runner.commandLog, isEmpty);
  });
  test(
    'malformed legacy input fails without forwarding raw JSON errors',
    () async {
      final file = File('${temp.path}/bad.json')
        ..writeAsStringSync('{"password":"legacy-secret",');
      expect(
        await runAutoInstall(
          file.path,
          runner,
          catalog,
          installService: service,
        ),
        2,
      );
      expect(service.states, isEmpty);
      expect(runner.commandLog, isEmpty);
    },
  );
}
