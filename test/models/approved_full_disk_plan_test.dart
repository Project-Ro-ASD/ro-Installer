import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:ro_installer/models/approved_full_disk_plan.dart';
import 'package:ro_installer/services/helper_protocol.dart';
import 'package:ro_installer/services/install_stages/stage_context.dart';
import 'package:ro_installer/services/install_stages/partitioning_stage.dart';
import 'package:ro_installer/services/install_stages/formatting_stage.dart';
import 'package:ro_installer/services/install_service.dart';
import 'package:ro_installer/services/fake_command_runner.dart';
import '../services/install_service_finalization_test.dart' as pipeline;

Map<String, dynamic> fixture() =>
    jsonDecode(
          File(
            'test/fixtures/approved_full_disk_plan_v1.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;
ApprovedFullDiskPlan plan() => ApprovedFullDiskPlan.fromJson(fixture());
Map<String, dynamic> state() => {
  ...plan().state,
  '_approvedFullDiskPlan': plan().json,
};
StageContext context(
  Map<String, dynamic> data,
  FakeCommandRunner runner, {
  Future<void> Function()? gate,
}) => StageContext(
  state: data,
  approvedPlan: plan(),
  log: (_) {},
  onProgress: (_, _) {},
  commandRunner: runner,
  runCmd: InstallService(commandRunner: runner).runCmd,
  isMock: true,
  beforeFirstMutation: gate,
);

void main() {
  test(
    'cross-language fixture fixes exact destructive operations and standard layout',
    () {
      final value = plan();
      expect(value.json, fixture());
      expect(value.json['espBytes'], 512 * 1024 * 1024);
      expect(value.json['diskSwap'], false);
      expect((value.json['storagePlan'] as Map)['operations'], hasLength(5));
      final reordered = Map<String, dynamic>.fromEntries(
        fixture().entries.toList().reversed,
      );
      expect(ApprovedFullDiskPlan.fromJson(reordered).json, fixture());
      final nvme = ApprovedFullDiskPlan(
        DeviceIdentity(
          path: '/dev/nvme0n1',
          majorMinor: '259:0',
          size: 68719476736,
          diskSequence: 12,
        ),
      );
      expect(
        (nvme.json['storagePlan'] as Map)['operations'][3]['target'],
        '/dev/nvme0n1p1',
      );
    },
  );
  test('JSON getters are defensive and never mutate the approved snapshot', () {
    final value = plan();
    final exported = value.json;
    exported['device']['size'] = 1;
    exported['subvolumes']['root'] = '/other';
    exported['storagePlan']['operations'].clear();
    expect(value.json, fixture());
    expect(value.matchesState(value.state), true);
  });
  test(
    'missing, extra, type-changed, reordered and altered plan values reject',
    () {
      final mutations = <void Function(Map<String, dynamic>)>[
        (v) => v.remove('schemaVersion'),
        (v) => v['schemaVersion'] = 1.0,
        (v) => v['layoutVersion'] = 2,
        (v) => v['diskSwap'] = 0,
        (v) => v['diskSwap'] = true,
        (v) => v['espBytes'] = 1,
        (v) => v['espFileSystem'] = 'ext4',
        (v) => v['partitionTable'] = 'msdos',
        (v) => v['command'] = 'sh',
        (v) => v['subvolumes']['root'] = '/other',
        (v) => v['storagePlan']['mode'] = 'manual',
        (v) => v['storagePlan']['operations'].removeLast(),
        (v) => v['storagePlan']['operations'][0]['destructive'] = false,
        (v) => v['storagePlan']['operations'] = v['storagePlan']['operations']
            .reversed
            .toList(),
        (v) => v['storagePlan']['operations'][3]['target'] = '/dev/vdb1',
      ];
      for (final mutate in mutations) {
        final v = fixture();
        mutate(v);
        expect(() => ApprovedFullDiskPlan.fromJson(v), throwsFormatException);
      }
    },
  );
  test(
    'stale state and removed approved plan reject before partition or formatting commands',
    () async {
      for (final change in <void Function(Map<String, dynamic>)>[
        (v) => v['selectedDisk'] = '/dev/vdb',
        (v) => v['partitionMethod'] = 'manual',
        (v) => v['fileSystem'] = 'ext4',
        (v) => v.remove('_approvedFullDiskPlan'),
        (v) => v['_approvedFullDiskPlan']['device']['diskSequence'] = 99,
      ]) {
        for (final format in [false, true]) {
          final runner = FakeCommandRunner();
          final data = state();
          change(data);
          final ctx = context(data, runner);
          expect(
            (format
                    ? await const FormattingStage().execute(ctx)
                    : await const PartitioningStage().execute(ctx))
                .success,
            false,
          );
          expect(runner.commandLog, isEmpty);
        }
      }
    },
  );
  test(
    'plan alteration during first-mutation authorization prevents wipefs',
    () async {
      for (final remove in [false, true]) {
        final data = state();
        final runner = FakeCommandRunner();
        final result = await const PartitioningStage().execute(
          context(
            data,
            runner,
            gate: () async {
              if (remove) {
                data.remove('_approvedFullDiskPlan');
              } else {
                data['selectedDisk'] = '/dev/vdb';
              }
            },
          ),
        );
        expect(result.success, false);
        expect(runner.wasCommandCalled('wipefs'), false);
        expect(
          runner.commandLog.where(
            (c) => ['sgdisk', 'parted'].contains(c.command),
          ),
          isEmpty,
        );
      }
    },
  );
  test(
    'real pipeline captures initial plan and rejects later deletion before wipe or format',
    () async {
      for (final stage in [2, 3]) {
        final graph = pipeline.PipelineGraph();
        final data = state();
        final engine = pipeline.engine(graph);
        var reached = false;
        expect(
          await engine.runInstall(
            data,
            (_, _) {},
            (_) {},
            isMock: true,
            onStage: (value) {
              if (value == stage) {
                reached = true;
                data.remove('_approvedFullDiskPlan');
              }
            },
          ),
          false,
        );
        expect(reached, true);
        if (stage == 2) pipeline.noMutation(graph);
        expect(
          graph.commandLog.where((c) => c.command.startsWith('mkfs.')),
          isEmpty,
        );
        pipeline.empty(graph);
      }
    },
  );
  test(
    'matching approved plan completes the existing nine-stage engine',
    () async {
      final graph = pipeline.PipelineGraph();
      final engine = pipeline.engine(graph);
      expect(
        await engine.runInstall(state(), (_, _) {}, (_) {}, isMock: true),
        true,
      );
      expect(graph.wasCalledWith('wipefs', ['-a', '/dev/vda']), true);
      expect(graph.wasCalledWith('mkfs.fat', ['-F32', '/dev/vda1']), true);
      expect(
        graph.commandLog.any(
          (c) => c.command == 'mkfs.btrfs' && c.args.last == '/dev/vda2',
        ),
        true,
      );
      pipeline.empty(graph);
    },
  );
  test(
    'invalid initial approval rejects before even read-only platform commands',
    () async {
      for (final invalid in [
        null,
        {},
        {...plan().json, 'espBytes': 1},
      ]) {
        final graph = pipeline.PipelineGraph();
        final engine = pipeline.engine(graph);
        expect(
          await engine.runInstall(
            {...plan().state, '_approvedFullDiskPlan': invalid},
            (_, _) {},
            (_) {},
          ),
          false,
        );
        expect(graph.commandLog, isEmpty);
        expect(engine.lastOutcome!.primaryFailure, 'PREFLIGHT_FAILED');
      }
    },
  );
}
