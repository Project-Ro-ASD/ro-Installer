import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:ro_installer/models/approved_free_space_plan.dart';
import 'package:ro_installer/models/gpt_disk_snapshot.dart';
import 'package:ro_installer/models/installer_handoff.dart';
import 'package:ro_installer/services/command_runner.dart';
import 'package:ro_installer/services/fake_command_runner.dart';
import 'package:ro_installer/services/privileged_backend.dart';
import 'install_service_finalization_test.dart' as p;
import 'privileged_backend_test.dart' as b;

Map<String, dynamic> fixture() =>
    jsonDecode(
          File('test/fixtures/free_space_execution_v1.json').readAsStringSync(),
        )
        as Map<String, dynamic>;
ApprovedFreeSpacePlan approved() => ApprovedFreeSpacePlan.fromJson({
  'snapshot': fixture()['snapshot'],
  'approval': fixture()['approval'],
});
Map<String, dynamic> state() => {
  'selectedDisk': '/dev/vda',
  'partitionMethod': 'free_space',
  'fileSystem': 'btrfs',
  '_approvedFreeSpacePlan': approved().json,
};

class FreeGraph extends p.PipelineGraph {
  bool created = false;
  String? freeFault;
  int probes = 0;
  final writes = <String, String>{};
  String? partitionInput;
  @override
  Future<CommandResult> run(
    String command,
    List<String> args, {
    bool isMock = false,
    CommandLogCallback? onLog,
    Duration? timeout,
    String? stdinText,
  }) async {
    if (command == 'lsblk' &&
        args.first == '-dnro' &&
        args.last == '/dev/vda3') {
      commandLog.add(RecordedCommand(command: command, args: args));
      return CommandResult(
        command: command,
        args: args,
        exitCode: 0,
        stdout: '8:1',
        stderr: '',
        started: true,
      );
    }
    if (stdinText != null && args.isNotEmpty) writes[args.last] = stdinText;
    if (command == '/usr/bin/python3') {
      probes++;
      final f = fixture();
      Map<String, dynamic> value = created
          ? f['created']
          : {
              'snapshot': f['snapshot'],
              'preservationFingerprint':
                  f['approval']['preservationFingerprint'],
            };
      if (freeFault == 'preservation' && created) {
        value = {...value, 'preservationFingerprint': 'b' * 64};
      }
      if (freeFault == 'missing-root' && created) {
        (value['snapshot']['partitions'] as List).removeWhere(
          (row) => row['number'] == 4,
        );
      }
      if (freeFault == 'wrong-guid' && created) {
        (value['snapshot']['partitions'] as List).firstWhere(
          (row) => row['number'] == 4,
        )['partitionGuid'] = '77777777-7777-7777-7777-777777777777';
      }
      if (freeFault == 'late-drift' && probes >= 4) {
        value = {...value, 'preservationFingerprint': 'b' * 64};
      }
      addResponse(command, args, stdout: jsonEncode(value));
    }
    if (command == 'sfdisk') {
      created = true;
      partitionInput = stdinText;
      if (freeFault == 'create') addResponse(command, args, exitCode: 1);
    }
    if (command == 'mkfs.fat' && freeFault == 'format') {
      addResponse(command, args, exitCode: 1);
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

void main() {
  test('approved model validates ownership and exact created partitions', () {
    final a = approved();
    final f = fixture();
    final layout = a.verifyCreated(
      GptDiskSnapshot.fromJson(f['created']['snapshot']),
      f['created']['preservationFingerprint'],
    );
    expect(layout.espPath, '/dev/vda3');
    expect(layout.rootPath, '/dev/vda4');
    for (final mutation in <void Function(Map<String, dynamic>)>[
      (v) => v['approval']['allocationGuids']['root'] =
          v['approval']['allocationGuids']['esp'],
      (v) => v['approval']['allocationGuids']['esp'] =
          v['snapshot']['partitions'][0]['partitionGuid'],
      (v) => v['approval']['intent']['diskSwap'] = true,
      (v) => v['approval']['intent']['root']['number'] = 2,
    ]) {
      final v = fixture();
      mutation(v);
      expect(
        () => ApprovedFreeSpacePlan.fromJson({
          'snapshot': v['snapshot'],
          'approval': v['approval'],
        }),
        throwsFormatException,
      );
    }
    final copy = a.json;
    copy['snapshot']['partitions'].clear();
    expect(a.json['snapshot']['partitions'], hasLength(3));
  });
  test(
    'nine-stage free-space install uses only new EFI3/root4 and writes matching handoff',
    () async {
      final graph = FreeGraph();
      final engine = p.engine(graph);
      final stages = <int>[];
      final logs = <String>[];
      expect(
        await engine.runInstall(
          state(),
          (_, _) {},
          logs.add,
          isMock: true,
          onStage: stages.add,
        ),
        true,
        reason: logs.join('\n'),
      );
      expect(stages, List.generate(9, (i) => i + 1));
      expect(graph.wasCommandCalled('wipefs'), false);
      expect(graph.wasCommandCalled('sgdisk'), false);
      expect(graph.wasCalledWith('mkfs.fat', ['-F32', '/dev/vda3']), true);
      expect(graph.wasCalledWith('mkfs.btrfs', ['-f', '/dev/vda4']), true);
      expect(
        graph.commandLog.where(
          (c) =>
              ['mkswap', 'swapon', 'swapoff', 'ntfsresize'].contains(c.command),
        ),
        isEmpty,
      );
      expect(graph.partitionInput!.split('\n'), hasLength(3));
      expect(graph.partitionInput, contains('3 : start='));
      expect(graph.partitionInput, contains('4 : start='));
      expect(graph.partitionInput, contains(approved().espGuid));
      expect(
        graph.commandLog.where(
          (c) => c.command == 'mount' && c.args.contains('/dev/vda1'),
        ),
        isEmpty,
      );
      final fstab = graph.writes['/mnt/etc/fstab']!;
      expect(fstab, contains('MOCK-VDA4'));
      expect(fstab, contains('MOCK-VDA3'));
      expect(fstab, isNot(contains('swap')));
      final metadata = jsonDecode(graph.writes['/mnt$installMetadataPath']!);
      expect(metadata['install_mode'], 'free_space');
      expect(
        isValidInstallerHandoff(
          jsonDecode(graph.writes['/mnt$installerSeedPath']!),
          metadata,
          expectedMode: 'free_space',
        ),
        true,
      );
      expect(
        graph.commandLog.any(
          (c) => c.command == 'efibootmgr' && c.args.contains('3'),
        ),
        true,
      );
      expect(
        graph.commandLog.any(
          (c) => c.args.any((a) => a.contains('GRUB_DISABLE_OS_PROBER=true')),
        ),
        true,
      );
      p.empty(graph);
    },
  );
  for (final fault in [
    'create',
    'preservation',
    'missing-root',
    'wrong-guid',
  ]) {
    test('$fault stops before any filesystem format or mount', () async {
      final graph = FreeGraph()..freeFault = fault;
      final engine = p.engine(graph);
      expect(
        await engine.runInstall(state(), (_, _) {}, (_) {}, isMock: true),
        false,
      );
      expect(
        graph.commandLog.where(
          (c) => c.command.startsWith('mkfs.') || c.command == 'mount',
        ),
        isEmpty,
      );
      expect(graph.wasCommandCalled('wipefs'), false);
      p.empty(graph);
    });
  }
  test(
    'late table drift stops before root format after owned EFI format',
    () async {
      final graph = FreeGraph()..freeFault = 'late-drift';
      expect(
        await p
            .engine(graph)
            .runInstall(state(), (_, _) {}, (_) {}, isMock: true),
        false,
      );
      expect(graph.wasCalledWith('mkfs.fat', ['-F32', '/dev/vda3']), true);
      expect(graph.wasCommandCalled('mkfs.btrfs'), false);
      p.empty(graph);
    },
  );
  for (final fault in ['main-copy', 'efi-mount', 'efi-format']) {
    test(
      '$fault fails with owned mounts cleaned and old partitions untouched',
      () async {
        final graph = FreeGraph();
        if (fault == 'main-copy') graph.fault = 'main';
        if (fault == 'efi-mount') graph.failedMountTargets.add('/mnt/boot/efi');
        if (fault == 'efi-format') graph.freeFault = 'format';
        expect(
          await p
              .engine(graph)
              .runInstall(state(), (_, _) {}, (_) {}, isMock: true),
          false,
        );
        expect(
          graph.commandLog.where(
            (c) =>
                (c.command.startsWith('mkfs.') || c.command == 'mount') &&
                c.args.any(
                  (a) => ['/dev/vda1', '/dev/vda2', '/dev/vda7'].contains(a),
                ),
          ),
          isEmpty,
        );
        p.empty(graph);
      },
    );
  }
  test(
    'approved free-space cannot downgrade to full mode or lose its state copy',
    () async {
      for (final targetStage in [2, 3, 4]) {
        final graph = FreeGraph();
        final data = state();
        var reached = false;
        expect(
          await p
              .engine(graph)
              .runInstall(
                data,
                (_, _) {},
                (_) {},
                isMock: true,
                onStage: (stage) {
                  if (stage == targetStage) {
                    reached = true;
                    data['partitionMethod'] = 'full';
                  }
                },
              ),
          false,
        );
        expect(reached, true);
        expect(graph.wasCommandCalled('wipefs'), false);
        expect(
          graph.commandLog.where(
            (c) =>
                c.command.startsWith('mkfs.') &&
                c.args.any(
                  (a) => ['/dev/vda1', '/dev/vda2', '/dev/vda7'].contains(a),
                ),
          ),
          isEmpty,
        );
        p.empty(graph);
      }
    },
  );
  test(
    'backend requires trusted source, approval and matching handshake',
    () async {
      final a = approved();
      final device = a.plan.snapshot.device;
      final request = {
        'protocolVersion': 1,
        'operation': 'install-free-space',
        'disk': device.path,
        'expectedDevice': device.expected,
        'sourceSnapshot': a.plan.snapshot.json,
        'confirmedPlan': a.approval,
      };
      final gate = {
        'protocolVersion': 1,
        'type': 'continue',
        'device': device.json,
        'confirmedPlan': a.approval,
      };
      final engine = b.BridgeEngine();
      final events = <Map<String, dynamic>>[];
      expect(
        await runPrivilegedBackend(
          b.input([request, gate]),
          events.add,
          service: engine,
          rootCheck: () async => true,
        ),
        0,
      );
      expect(engine.state!['partitionMethod'], 'free_space');
      expect(
        events.singleWhere((e) => e['type'] == 'ready')['confirmedPlan'],
        a.approval,
      );
      for (final bad in [
        {...gate, 'confirmedPlan': a.plan.intentJson},
        {
          ...gate,
          'confirmedPlan': {...a.approval, 'preservationFingerprint': 'b' * 64},
        },
      ]) {
        expect(
          await runPrivilegedBackend(
            b.input([request, bad]),
            (_) {},
            service: b.BridgeEngine(),
            rootCheck: () async => true,
          ),
          9,
        );
      }
      final missing = Map<String, dynamic>.of(request)
        ..remove('sourceSnapshot');
      final badEngine = b.BridgeEngine();
      expect(
        await runPrivilegedBackend(
          b.input([missing, gate]),
          (_) {},
          service: badEngine,
          rootCheck: () async => true,
        ),
        9,
      );
      expect(badEngine.state, isNull);
    },
  );
}
