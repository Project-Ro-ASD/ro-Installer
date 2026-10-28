import 'dart:convert';
import 'package:test/test.dart';
import 'package:ro_installer/services/command_runner.dart';
import 'package:ro_installer/services/install_service.dart';
import 'package:ro_installer/services/install_stages/bootloader_stage.dart';
import 'package:ro_installer/services/mount_session.dart';
import 'package:ro_installer/services/privileged_backend.dart';
import 'privileged_backend_test.dart' as bridge;
import '../support/mount_graph.dart';
import '../support/prepared_source.dart';

class PipelineGraph extends MountGraph {
  PipelineGraph() {
    configurePreparedSource(this, disk: '/dev/vda');
    addResponse('uname', ['-m'], stdout: 'x86_64');
  }
  String? fault;
  bool diagnosticsThrow = false;
  @override
  Future<CommandResult> run(
    String command,
    List<String> args, {
    bool isMock = false,
    CommandLogCallback? onLog,
    Duration? timeout,
    String? stdinText,
  }) async {
    if (fault == 'exception' && command == 'btrfs') {
      throw StateError('synthetic unexpected failure');
    }
    if (diagnosticsThrow && command == 'dmesg')
      throw StateError('diagnostic failure');
    if (command == 'rsync' &&
        ((fault == 'main' && args.contains('/')) ||
            (fault == 'efi' && args.contains('/boot/efi/')))) {
      addResponse(command, args, exitCode: 23);
    }
    return super.run(
      command,
      args,
      isMock: isMock,
      onLog: onLog,
      timeout: timeout,
      stdinText: stdinText,
    );
  }
}

class ThrowingCleanup extends VerifiedMountSession {
  ThrowingCleanup(MountGraph graph)
    : super(
        graph,
        inventory: graph.inventory,
        namespace: () async => graph.ns,
        control: graph.control,
      );
  @override
  Future<CleanupReport> cleanup() async => throw StateError('cleanup fixture');
}

Map<String, dynamic> state() => {
  'selectedDisk': '/dev/vda',
  'partitionMethod': 'full',
  'fileSystem': 'btrfs',
};
InstallService engine(PipelineGraph graph, {MountSession? session}) =>
    InstallService(
      commandRunner: graph,
      sessionFactory: (_) async => session ?? graph.session(),
    );
void empty(PipelineGraph graph) => expect(
  graph.rows.where((r) => r.target == '/mnt' || r.target.startsWith('/mnt/')),
  isEmpty,
);
void noMutation(PipelineGraph graph) => expect(
  graph.commandLog.where(
    (c) =>
        const [
          'wipefs',
          'sgdisk',
          'parted',
          'mount',
          'umount',
          'btrfs',
          'swapoff',
          'swapon',
        ].contains(c.command) ||
        c.command.startsWith('mkfs.'),
  ),
  isEmpty,
);
void main() {
  for (final fault in ['rsync', 'efi-file', 'source', 'foreign', 'namespace']) {
    test('real early gate $fault emits no stage or disk mutation', () async {
      final graph = PipelineGraph();
      if (fault == 'rsync')
        graph.addResponse('sh', [
          '-c',
          'command -v rsync >/dev/null 2>&1',
        ], exitCode: 1);
      if (fault == 'efi-file')
        graph.addResponse('test', [
          '-s',
          '/boot/efi/EFI/fedora/shimx64.efi',
        ], exitCode: 1);
      if (fault == 'source') {
        graph.reset();
        graph.addResponse('uname', ['-m'], stdout: 'x86_64');
        graph.addResponse('findmnt', [
          '--json',
          '--list',
          '--output',
          'TARGET,FSTYPE',
        ], stdout: '{}');
      }
      if (fault == 'foreign') graph.add('/mnt/foreign');
      if (fault == 'namespace') graph.ns = 'mnt:[1]';
      final stages = <int>[];
      final service = engine(graph);
      expect(
        await service.runInstall(
          state(),
          (_, _) {},
          (_) {},
          onStage: stages.add,
        ),
        isFalse,
      );
      expect(stages, isEmpty);
      noMutation(graph);
      expect(service.lastOutcome!.success, isFalse);
      if (fault == 'foreign')
        expect(graph.rows.any((r) => r.target == '/mnt/foreign'), isTrue);
    });
  }
  test(
    'all nine stages complete before progress 100 and empty inventory',
    () async {
      final graph = PipelineGraph();
      final service = engine(graph);
      final stages = <int>[];
      expect(
        await service.runInstall(
          state(),
          (p, _) {
            if (p == 1) empty(graph);
          },
          (_) {},
          isMock: true,
          onStage: stages.add,
        ),
        isTrue,
      );
      expect(stages, List.generate(9, (i) => i + 1));
      empty(graph);
      expect(service.lastOutcome!.success, isTrue);
      expect(graph.commandNames, isNot(contains('swapoff')));
    },
  );
  for (final fault in ['efi-mount', 'main', 'efi', 'bootloader', 'exception']) {
    test(
      '$fault failure preserves original error and cleans owned resources',
      () async {
        final graph = PipelineGraph()..fault = fault;
        if (fault == 'efi-mount') graph.failedMountTargets.add('/mnt/boot/efi');
        if (fault == 'bootloader')
          graph.addResponse('chroot', [
            '/mnt',
            'sh',
            '-c',
            bootloaderDracutScript,
          ], exitCode: 1);
        final service = engine(graph);
        final progress = <double>[];
        expect(
          await service.runInstall(
            state(),
            (p, _) => progress.add(p),
            (_) {},
            isMock: true,
          ),
          isFalse,
        );
        empty(graph);
        expect(graph.unmounts, greaterThan(0));
        expect(service.lastOutcome!.cleanup.success, isTrue);
        expect(
          service.lastOutcome!.primaryFailure,
          fault == 'exception'
              ? 'INSTALL_EXCEPTION'
              : 'STAGE_${fault == 'efi-mount'
                    ? 4
                    : fault == 'bootloader'
                    ? 7
                    : 5}_FAILED',
        );
        expect(progress, isNot(contains(1.0)));
      },
    );
  }
  test(
    'busy cleanup cannot produce success or be retried into success',
    () async {
      final graph = PipelineGraph()..busy.add('/mnt/boot/efi');
      final service = engine(graph);
      expect(
        await service.runInstall(state(), (_, _) {}, (_) {}, isMock: true),
        isFalse,
      );
      expect(service.lastOutcome!.primaryFailure, 'STAGE_9_FAILED');
      expect(service.lastOutcome!.cleanup.success, isFalse);
      expect(graph.rows.any((r) => r.target == '/mnt/boot/efi'), isTrue);
    },
  );
  test('cleanup exception never overwrites the original copy error', () async {
    final graph = PipelineGraph()..fault = 'main';
    final service = engine(graph, session: ThrowingCleanup(graph));
    expect(
      await service.runInstall(state(), (_, _) {}, (_) {}, isMock: true),
      isFalse,
    );
    expect(service.lastOutcome!.primaryFailure, 'STAGE_5_FAILED');
    expect(service.lastOutcome!.cleanup.success, isFalse);
  });
  test(
    'diagnostic/log callback exception cannot bypass finally cleanup',
    () async {
      final graph = PipelineGraph()
        ..fault = 'main'
        ..diagnosticsThrow = true;
      final service = engine(graph);
      expect(
        await service.runInstall(
          state(),
          (_, _) {},
          (_) => throw StateError('log sink'),
          isMock: true,
        ),
        isFalse,
      );
      empty(graph);
      expect(service.lastOutcome!.cleanup.success, isTrue);
    },
  );
  test(
    'GUI backend uses the actual shared preflight before ready/mutation',
    () async {
      final graph = PipelineGraph()
        ..addResponse('sh', [
          '-c',
          'command -v rsync >/dev/null 2>&1',
        ], exitCode: 1);
      final events = <Map<String, dynamic>>[];
      expect(
        await runPrivilegedBackend(
          bridge.input([bridge.request]),
          events.add,
          service: engine(graph),
          rootCheck: () async => true,
        ),
        8,
      );
      noMutation(graph);
      expect(events.where((e) => e['type'] == 'ready'), isEmpty);
      expect(events.last['ok'], isFalse);
    },
  );
  for (final busy in [false, true]) {
    test('backend terminal requires actual cleanup busy=$busy', () async {
      final graph = PipelineGraph();
      if (busy) graph.busy.add('/mnt/boot/efi');
      final events = <Map<String, dynamic>>[];
      expect(
        await runPrivilegedBackend(
          bridge.input([bridge.request, bridge.gate]),
          events.add,
          service: engine(graph),
          isMock: true,
          rootCheck: () async => true,
        ),
        busy ? 8 : 0,
      );
      expect(events.last['ok'], !busy);
      expect(jsonEncode(events), isNot(contains('synthetic')));
    });
  }
}
