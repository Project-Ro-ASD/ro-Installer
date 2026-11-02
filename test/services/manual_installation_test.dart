import 'dart:convert';
import 'package:test/test.dart';
import 'package:ro_installer/models/approved_manual_plan.dart';
import 'package:ro_installer/models/installer_handoff.dart';
import 'package:ro_installer/services/command_runner.dart';
import 'package:ro_installer/services/fake_command_runner.dart';
import 'package:ro_installer/services/helper_client.dart';
import 'package:ro_installer/services/install_service.dart';
import 'package:ro_installer/services/privileged_backend.dart';
import '../support/prepared_source.dart';
import 'protected_esp_session_test.dart' as e;
import 'privileged_backend_test.dart' as b;
import 'helper_client_test.dart' as h;

class ManualGraph extends e.EspGraph {
  ManualGraph(this.index, {this.formatExistingEsp = false}) {
    configurePreparedSource(this, disk: '/dev/vda');
    addResponse('uname', ['-m'], stdout: 'x86_64');
    created = approved.newSlots.isEmpty;
  }
  final int index;
  final bool formatExistingEsp;
  bool created = false;
  String? fault;
  final writes = <String, String>{};
  String? appendInput;
  ApprovedManualPlan get approved {
    final value = e.fixture(index);
    if (formatExistingEsp) {
      value['approval']['intent']['esp']['formatOnInstall'] = true;
    }
    return ApprovedManualPlan.fromJson({
      'snapshot': value['snapshot'],
      'approval': value['approval'],
    });
  }

  @override
  Future<CommandResult> run(
    String command,
    List<String> args, {
    bool isMock = false,
    CommandLogCallback? onLog,
    Duration? timeout,
    String? stdinText,
  }) async {
    CommandResult result(String data, [int code = 0]) => CommandResult(
      command: command,
      args: args,
      started: true,
      exitCode: code,
      stdout: data,
      stderr: '',
    );
    if (stdinText != null && args.isNotEmpty) writes[args.last] = stdinText;
    if (command == 'lsblk' && args.first == '-dnro') {
      commandLog.add(RecordedCommand(command: command, args: args));
      return result(args.last == approved.plan.esp.target ? '8:1' : '8:2');
    }
    if (command == '/usr/bin/python3' && args.contains('--new-efi-budget')) {
      commandLog.add(RecordedCommand(command: command, args: args));
      return result(
        jsonEncode({
          'requiredBytes': 32 * 1048576,
          'availableBytes': int.parse(args.last),
          'sourceBytes': 1000000,
          'fileCount': 2,
          'clusterBytes': 1048576,
          'sufficient': !insufficient,
        }),
      );
    }
    if (command == '/usr/bin/python3' && args.contains('--layout')) {
      commandLog.add(RecordedCommand(command: command, args: args));
      final f = e.fixture(index);
      final value = created
          ? f['created']
          : {
              'snapshot': f['snapshot'],
              'preservationFingerprint':
                  f['approval']['preservationFingerprint'],
            };
      if (fault == 'proof' && created) {
        value['preservationFingerprint'] = 'b' * 64;
      }
      return result(jsonEncode(value));
    }
    if (command == 'sfdisk') {
      appendInput = stdinText;
      created = true;
      if (fault == 'append') addResponse(command, args, exitCode: 1);
    }
    if (command == 'rsync' &&
        (fault == 'copy-main' && args.contains('/') ||
            fault == 'copy-efi' && !args.contains('/'))) {
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

Map<String, dynamic> state(int index) => {
  'selectedDisk': '/dev/vda',
  'partitionMethod': 'manual',
  'fileSystem': 'btrfs',
  '_approvedManualPlan': e.approval(index).json,
};
InstallService service(ManualGraph graph) => InstallService(
  commandRunner: graph,
  sessionFactory: (_) async => graph.session(),
);
void empty(ManualGraph graph) => expect(
  graph.rows.where((m) => m.target == '/mnt' || m.target.startsWith('/mnt/')),
  isEmpty,
);

void main() {
  for (var index = 0; index < 4; index++) {
    test(
      'manual case $index completes all nine stages with only approved targets',
      () async {
        final g = ManualGraph(index);
        final stages = <int>[], logs = <String>[];
        final runner = service(g);
        expect(
          await runner.runInstall(
            state(index),
            (_, _) {},
            logs.add,
            isMock: true,
            onStage: stages.add,
          ),
          true,
          reason: logs.join('\n'),
        );
        expect(stages, List.generate(9, (i) => i + 1));
        expect(g.wasCommandCalled('sfdisk'), g.approved.newSlots.isNotEmpty);
        expect(g.wasCommandCalled('wipefs'), false);
        expect(g.wasCommandCalled('sgdisk'), false);
        expect(
          g.wasCalledWith('mkfs.btrfs', ['-f', g.approved.plan.root.target]),
          true,
        );
        expect(
          g.wasCommandCalled('mkfs.fat'),
          g.approved.plan.esp.formatOnInstall,
        );
        if (g.appendInput != null) {
          expect(
            g.appendInput!.split('\n'),
            hasLength(g.approved.newSlots.length + 1),
          );
        }
        expect(
          g.commandLog.where(
            (c) => const [
              'mkswap',
              'swapon',
              'swapoff',
              'ntfsresize',
            ].contains(c.command),
          ),
          isEmpty,
        );
        final metadata = jsonDecode(g.writes['/mnt$installMetadataPath']!);
        expect(metadata['install_mode'], 'manual');
        expect(
          isValidInstallerHandoff(
            jsonDecode(g.writes['/mnt$installerSeedPath']!),
            metadata,
            expectedMode: 'manual',
          ),
          true,
        );
        expect(
          g.writes['/mnt/etc/fstab'],
          contains(
            'MOCK-${g.approved.plan.root.target.split('/').last.toUpperCase()}',
          ),
        );
        expect(
          g.commandLog.any(
            (c) =>
                c.command == 'efibootmgr' &&
                c.args.contains('${g.approved.plan.esp.number}'),
          ),
          true,
        );
        expect(
          g.commandLog.any(
            (c) => c.args.any(
              (v) => v.contains('kernel-install --boot-path=/boot add'),
            ),
          ),
          true,
        );
        if (!g.approved.plan.esp.formatOnInstall) {
          expect(
            g.commandLog.any(
              (c) => c.command == 'rsync' && c.args.contains('/boot/efi/'),
            ),
            false,
          );
          expect(
            g.commandLog.any(
              (c) =>
                  c.command == 'rsync' &&
                  c.args.contains('/boot/efi/EFI/fedora/'),
            ),
            true,
          );
        }
        empty(g);
        expect(runner.lastOutcome!.success, true);
      },
    );
  }
  test(
    'explicit existing ESP formatting is allowed only by the captured plan',
    () async {
      final g = ManualGraph(0, formatExistingEsp: true);
      final data = state(0)..['_approvedManualPlan'] = g.approved.json;
      expect(
        await service(g).runInstall(data, (_, _) {}, (_) {}, isMock: true),
        true,
      );
      expect(g.wasCalledWith('mkfs.fat', ['-F32', '/dev/vda1']), true);
      expect(g.wasCommandCalled('sfdisk'), false);
      empty(g);
    },
  );
  test(
    'formatted ESP source capacity is checked before any mutation',
    () async {
      final g = ManualGraph(3)..insufficient = true;
      expect(
        await service(g).runInstall(state(3), (_, _) {}, (_) {}, isMock: true),
        false,
      );
      expect(
        g.commandLog.where(
          (c) => c.command.startsWith('mkfs.') || c.command == 'sfdisk',
        ),
        isEmpty,
      );
      empty(g);
    },
  );
  for (final fault in ['append', 'proof', 'copy-main', 'copy-efi']) {
    test(
      '$fault cannot become successful and cleans verified mounts',
      () async {
        final g = ManualGraph(fault.startsWith('copy') ? 0 : 3)..fault = fault;
        expect(
          await service(
            g,
          ).runInstall(state(g.index), (_, _) {}, (_) {}, isMock: true),
          false,
        );
        if (!fault.startsWith('copy')) {
          expect(g.wasCommandCalled('mkfs.btrfs'), false);
        }
        empty(g);
      },
    );
  }
  test('kernel failure on a reused ESP cannot report success', () async {
    final g = ManualGraph(0);
    g.addResponseForCommand('chroot', exitCode: 1);
    final runner = service(g);
    expect(
      await runner.runInstall(state(0), (_, _) {}, (_) {}, isMock: true),
      false,
    );
    expect(runner.lastOutcome!.success, false);
    expect(g.wasCommandCalled('mkfs.fat'), false);
    empty(g);
  });
  test('changed ESP write protection blocks boot work', () async {
    final g = ManualGraph(0);
    final runner = service(g);
    expect(
      await runner.runInstall(
        state(0),
        (_, _) {},
        (_) {},
        isMock: true,
        onStage: (stage) {
          if (stage == 7) g.flags(e.base, {'rw', 'nosuid', 'nodev', 'noexec'});
        },
      ),
      false,
    );
    expect(
      g.commandLog.where(
        (c) => c.args.any(
          (a) => a.contains('kernel-install --boot-path=/boot add'),
        ),
      ),
      isEmpty,
    );
    expect(runner.lastOutcome!.success, false);
    expect(runner.lastOutcome!.cleanup.success, false);
    expect(
      runner.lastOutcome!.cleanup.reason,
      contains('Unverified mount ownership'),
    );
    expect(
      runner.lastOutcome!.cleanup.remaining,
      containsAll(['/mnt', e.base, e.owned]),
    );
    expect(g.rows.where((m) => m.target == e.base), hasLength(1));
  });
  test('collision or insufficient space prevents any disk mutation', () async {
    for (final fault in ['collision', 'space']) {
      final g = ManualGraph(0)
        ..collision = fault == 'collision'
        ..insufficient = fault == 'space';
      expect(
        await service(g).runInstall(state(0), (_, _) {}, (_) {}, isMock: true),
        false,
      );
      expect(
        g.commandLog.where(
          (c) => c.command.startsWith('mkfs.') || c.command == 'sfdisk',
        ),
        isEmpty,
      );
      empty(g);
    }
  });
  test(
    'captured manual approval cannot downgrade to full or lose its state copy',
    () async {
      for (final targetStage in [2, 3, 4]) {
        for (final remove in [false, true]) {
          final g = ManualGraph(3), data = state(3);
          expect(
            await service(g).runInstall(
              data,
              (_, _) {},
              (_) {},
              isMock: true,
              onStage: (stage) {
                if (stage == targetStage) {
                  if (remove) {
                    data.remove('_approvedManualPlan');
                  } else {
                    data['partitionMethod'] = 'full';
                  }
                }
              },
            ),
            false,
          );
          expect(g.wasCommandCalled('wipefs'), false);
          expect(g.wasCommandCalled('sgdisk'), false);
          expect(
            g.commandLog.where(
              (c) =>
                  c.command.startsWith('mkfs.') && c.args.contains('/dev/vda1'),
            ),
            isEmpty,
          );
          empty(g);
        }
      }
    },
  );
  test(
    'legacy manual maps are rejected and cannot supply implicit deletion',
    () async {
      final g = ManualGraph(0);
      expect(
        await service(g).runInstall(
          {
            'selectedDisk': '/dev/vda',
            'partitionMethod': 'manual',
            'fileSystem': 'btrfs',
            'manualPartitions': [
              {'name': '/dev/vda7', 'delete': true},
            ],
          },
          (_, _) {},
          (_) {},
          isMock: true,
        ),
        false,
      );
      expect(g.commandLog, isEmpty);
      final data = state(0)
        ..['manualPartitions'] = [
          {
            'deletedPartitionNames': ['/dev/vda7'],
            'type': 'ext4',
            'mount': '/',
          },
        ];
      expect(
        await service(g).runInstall(data, (_, _) {}, (_) {}, isMock: true),
        true,
      );
      expect(g.wasCommandCalled('sgdisk'), false);
      empty(g);
    },
  );
  test('backend binds manual private ownership to ready/continue', () async {
    final plan = e.approval(3), events = <Map<String, dynamic>>[];
    final request = {
      'protocolVersion': 1,
      'operation': 'install-manual',
      'disk': '/dev/vda',
      'expectedDevice': plan.plan.snapshot.device.expected,
      'sourceSnapshot': plan.plan.snapshot.json,
      'confirmedPlan': plan.approval,
    };
    final gate = {
      'protocolVersion': 1,
      'type': 'continue',
      'device': plan.plan.snapshot.device.json,
      'confirmedPlan': plan.approval,
    };
    final engine = b.BridgeEngine();
    expect(
      await runPrivilegedBackend(
        b.input([request, gate]),
        events.add,
        service: engine,
        rootCheck: () async => true,
      ),
      0,
    );
    expect(engine.state!['partitionMethod'], 'manual');
    expect(
      events.singleWhere((e) => e['type'] == 'ready')['confirmedPlan'],
      plan.approval,
    );
    expect(
      await runPrivilegedBackend(
        b.input([
          request,
          {...gate, 'confirmedPlan': plan.plan.intentJson},
        ]),
        (_) {},
        service: b.BridgeEngine(),
        rootCheck: () async => true,
      ),
      9,
    );
  });
  test(
    'v2 client sends only compact intent and terminal installed success is required',
    () async {
      final plan = e.approval(0).plan;
      final process = h.FakeHelperProcess(
        h.messages([
          {
            ...h.result('install-manual', {'installed': true}),
            'protocolVersion': 2,
          },
        ]),
      );
      await HelperClient(
        protocolVersion: 2,
        start: (_, _) async => process,
      ).installManualPlan(plan, (_, _) {});
      final value = jsonDecode(process.sent);
      expect(value['confirmedPlan'], plan.intentJson);
      expect(value.containsKey('sourceSnapshot'), false);
      await expectLater(
        HelperClient(
          start: (_, _) async => throw StateError('must not start'),
        ).installManualPlan(plan, (_, _) {}),
        throwsA(h.helperError('INVALID_REQUEST')),
      );
    },
  );
}
