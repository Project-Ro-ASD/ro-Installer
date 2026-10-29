import 'dart:convert';
import 'dart:io';
import 'package:ro_installer/services/install_service.dart';
import 'package:ro_installer/services/install_observation.dart';
import 'package:ro_installer/services/session_command_runner.dart';
import '../support/mount_graph.dart';
import '../support/prepared_source.dart';

Future<void> main() async {
  final graph = MountGraph();
  configurePreparedSource(graph, disk: '/dev/vda');
  final fault = Platform.environment['FIXTURE_FAULT'];
  if (fault == 'stay') {
    final transport = SessionCommandRunner(
      Platform.environment['FIXTURE_SOCKET']!,
    );
    await transport.control({
      'op': 'observe',
      'event': {
        'eventType': 'stage.start',
        'stageId': 5,
        'operationId': 'stage.command',
        'status': 'running',
        'durationMs': 0,
        'exitCode': null,
        'errorCode': null,
      },
    });
    File(
      Platform.environment['FIXTURE_RESULT']!,
    ).writeAsStringSync(jsonEncode({'ready': true, 'pid': pid}));
    await Future<void>.delayed(const Duration(seconds: 60));
    return;
  }

  if (fault == 'main') graph.addResponseForCommand('rsync', exitCode: 23);
  if (fault == 'cleanup') graph.busy.add('/mnt/boot/efi');
  final transport = SessionCommandRunner(
    Platform.environment['FIXTURE_SOCKET']!,
  );
  final service = InstallService(
    commandRunner: graph,
    sessionFactory: (_) async => graph.session(),
    observationFactory: () => InstallObservation(
      sink: (value) async {
        await transport.control(value);
      },
    ),
  );
  final success = await service.runInstall(
    {
      'selectedDisk': '/dev/vda',
      'partitionMethod': 'full',
      'fileSystem': 'btrfs',
    },
    (_, _) {},
    (_) {},
    isMock: true,
  );
  File(Platform.environment['FIXTURE_RESULT']!).writeAsStringSync(
    jsonEncode({
      'success': success,
      'remaining': graph.rows.where((m) => m.target.startsWith('/mnt')).length,
    }),
  );
  exitCode = success ? 0 : 8;
}
