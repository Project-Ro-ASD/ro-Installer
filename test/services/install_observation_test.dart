import 'dart:convert';
import 'package:test/test.dart';
import 'package:ro_installer/services/install_observation.dart';
import 'package:ro_installer/services/install_service.dart';
import 'package:ro_installer/services/session_report.dart';
import 'install_service_finalization_test.dart'
    show PipelineGraph, state, empty, noMutation;

void main() {
  for (final fault in [
    'success',
    'main',
    'efi',
    'bootloader',
    'exception',
    'cleanup',
    'preflight',
    'partition',
  ]) {
    test(
      'structured pipeline $fault preserves outcome and stage spans',
      () async {
        final graph = PipelineGraph()..fault = fault;
        if (fault == 'partition') {
          graph.addResponseForCommand('wipefs', exitCode: 1);
        }
        if (fault == 'bootloader') {
          graph.addResponseForCommand('chroot', exitCode: 1);
        }
        if (fault == 'cleanup') graph.busy.add('/mnt/boot/efi');
        if (fault == 'preflight') {
          graph.addResponse('sh', [
            '-c',
            'command -v rsync >/dev/null 2>&1',
          ], exitCode: 1);
        }
        final events = <Map<String, dynamic>>[];
        final service = InstallService(
          commandRunner: graph,
          sessionFactory: (_) async => graph.session(),
          observationFactory: () => InstallObservation(
            sink: (e) async {
              events.add(e);
            },
          ),
        );
        final result = await service.runInstall(
          state(),
          (_, _) {},
          (_) {},
          isMock: fault != 'preflight',
        );
        expect(result, fault == 'success');
        expect(events.where((e) => e['op'] == 'outcome'), hasLength(1));
        final outcome = events.last['outcome'] as Map<String, dynamic>;
        expect(outcome['terminalStatus'], result ? 'success' : 'failed');
        expect(outcome['primaryError'], service.lastOutcome!.primaryFailure);
        expect(
          outcome['cleanupStatus'],
          service.lastOutcome!.cleanup.success ? 'success' : 'failed',
        );
        final payloads = events
            .where((e) => e['op'] == 'observe')
            .map((e) => e['event'] as Map<String, dynamic>)
            .toList();
        expect(
          payloads.every((e) => validSchema(e, ['object', 'payload'])),
          isTrue,
        );
        final ended = payloads
            .where((e) => e['eventType'] == 'stage.end')
            .toList();
        if (fault == 'success') {
          expect(
            ended.map((e) => e['stageId']),
            List.generate(9, (i) => i + 1),
          );
        }
        if (fault == 'preflight') {
          expect(ended, isEmpty);
          noMutation(graph);
        }
        if (fault == 'partition') expect(outcome['failedStage'], 2);
        if (fault == 'exception') expect(outcome['failedStage'], 4);
        if (!const ['cleanup'].contains(fault)) empty(graph);
        expect(jsonEncode(events), isNot(contains('/dev/vda')));
        expect(
          payloads.every(
            (e) => !e.containsKey('stdout') && !e.containsKey('command'),
          ),
          isTrue,
        );
      },
    );
  }
  for (final failing in [false, true]) {
    test(
      'throwing telemetry sink never changes engine or cleanup fail=$failing',
      () async {
        final graph = PipelineGraph()..fault = failing ? 'main' : 'success';
        final service = InstallService(
          commandRunner: graph,
          sessionFactory: (_) async => graph.session(),
          observationFactory: () => InstallObservation(
            sink: (_) async => throw StateError('SECRET_SENTINEL'),
          ),
        );
        expect(
          await service.runInstall(state(), (_, _) {}, (_) {}, isMock: true),
          !failing,
        );
        empty(graph);
        expect(service.lastOutcome!.cleanup.success, isTrue);
      },
    );
  }
  test('throwing telemetry construction never changes engine result', () async {
    final graph = PipelineGraph();
    final service = InstallService(
      commandRunner: graph,
      sessionFactory: (_) async => graph.session(),
      observationFactory: () => throw StateError('SECRET_SENTINEL'),
    );
    expect(
      await service.runInstall(state(), (_, _) {}, (_) {}, isMock: true),
      isTrue,
    );
    empty(graph);
  });
  test(
    'telemetry clock exception cannot change successful installation',
    () async {
      final graph = PipelineGraph();
      var ticks = 0;
      final service = InstallService(
        commandRunner: graph,
        sessionFactory: (_) async => graph.session(),
        observationFactory: () => InstallObservation(
          microseconds: () {
            if (++ticks > 3) throw StateError('SECRET_SENTINEL');
            return ticks * 1000;
          },
        ),
      );
      expect(
        await service.runInstall(state(), (_, _) {}, (_) {}, isMock: true),
        isTrue,
      );
      empty(graph);
    },
  );
  test('monotonic partial stage uses injected elapsed clock', () async {
    var micros = 1000;
    final events = <Map<String, dynamic>>[];
    final observer = InstallObservation(
      microseconds: () => micros,
      sink: (e) async => events.add(e),
    );
    await observer.beginStage(5);
    micros += 1234000;
    await observer.endStage(5, false, error: 'STAGE_5_FAILED');
    await observer.finish(
      success: false,
      primary: 'STAGE_5_FAILED',
      cleanup: false,
      remaining: 2,
    );
    final ended = events.singleWhere(
      (e) => e['event']?['eventType'] == 'stage.end',
    )['event'];
    expect(ended['durationMs'], 1234);
    expect(ended['status'], 'failed');
    expect(events.last['outcome']['engineDurationMs'], 1234);
    expect(events.last['outcome']['failedStage'], 5);
    expect(events.last['outcome']['remainingResources'], 2);
  });
}
