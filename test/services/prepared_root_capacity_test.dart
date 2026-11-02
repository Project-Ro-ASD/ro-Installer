import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:ro_installer/models/prepared_root_capacity.dart';
import 'package:ro_installer/models/approved_manual_plan.dart';
import 'package:ro_installer/services/fake_command_runner.dart';
import 'package:ro_installer/services/command_runner.dart';
import 'package:ro_installer/services/install_preflight.dart';
import 'package:ro_installer/services/install_stages/file_copy_stage.dart';
import 'package:ro_installer/services/install_stages/stage_context.dart';
import 'package:ro_installer/services/mount_session.dart';
import '../support/prepared_source.dart';
import 'free_space_installation_test.dart' as free;
import 'install_preflight_test.dart' as checks;
import 'install_service_finalization_test.dart' as pipeline;

class InventoryRunner extends FakeCommandRunner {
  void Function()? afterInventory;
  Duration? inventoryTimeout;
  @override
  Future<CommandResult> run(
    String command,
    List<String> args, {
    bool isMock = false,
    CommandLogCallback? onLog,
    Duration? timeout,
    String? stdinText,
  }) async {
    final result = await super.run(
      command,
      args,
      isMock: isMock,
      onLog: onLog,
      timeout: timeout,
      stdinText: stdinText,
    );
    if (command == 'rsync' && args.contains('--dry-run')) {
      inventoryTimeout = timeout;
      afterInventory?.call();
    }
    return result;
  }
}

const gib = 1024 * 1024 * 1024;
String stats(int bytes, int count) =>
    'Number of files: $count (reg: ${count - 1}, dir: 1)\nTotal file size: $bytes bytes\nTotal transferred file size: 0 bytes\n';
StageContext context(
  FakeCommandRunner runner, {
  String mode = 'full',
  bool manual = false,
}) {
  final fixture = manual
      ? (jsonDecode(
                      File(
                        'test/fixtures/manual_ownership_v1.json',
                      ).readAsStringSync(),
                    )
                    as List)
                .first
            as Map<String, dynamic>
      : null;
  final approval = fixture == null
      ? null
      : ApprovedManualPlan.fromJson({
          'snapshot': fixture['snapshot'],
          'approval': fixture['approval'],
        });
  return StageContext(
    state: mode == 'full'
        ? {
            'selectedDisk': '/dev/vda',
            'partitionMethod': 'full',
            'fileSystem': 'btrfs',
          }
        : manual
        ? {
            'selectedDisk': '/dev/vda',
            'partitionMethod': 'manual',
            'fileSystem': 'btrfs',
            '_approvedManualPlan': approval!.json,
          }
        : free.state(),
    commandRunner: runner,
    mountSession: SimulatedMountSession(runner),
    log: (_) {},
    onProgress: (_, _) {},
    approvedFreeSpacePlan: mode == 'free_space' ? free.approved() : null,
    approvedManualPlan: approval,
    runCmd:
        (
          cmd,
          args,
          log, {
          bool isMock = false,
          List<int> allowedExitCodes = const [0],
        }) async => throw StateError('No mutation during preflight'),
  );
}

void main() {
  test(
    'budget includes logical bytes, entry reserve and growth without lowering the floor',
    () {
      expect(
        PreparedRootCapacity.fromRsyncStats(
          stats(2 * gib, 30000),
        ).requiredRootBytes,
        40 * gib,
      );
      expect(
        PreparedRootCapacity.fromRsyncStats(
          stats(50 * gib, 65536),
        ).requiredRootBytes,
        63 * gib,
      );
      expect(
        PreparedRootCapacity.fromRsyncStats(
          stats(50 * gib + 1, 65536),
        ).requiredRootBytes,
        63 * gib + 1048576,
      );
    },
  );
  test(
    'missing duplicate malformed oversized and inconsistent stats fail closed',
    () {
      for (final raw in [
        '',
        stats(0, 1),
        stats(1, 0),
        stats(1, 2000001),
        stats(8 * 1024 * gib + 1, 1),
        '${stats(1, 1)}Total file size: 1 bytes\n',
        '${stats(1, 1)}Number of files: 1 (dir: 1)\n',
        stats(1, 1).replaceFirst('reg: 0, dir: 1', 'dir: 1, dir: 0'),
        stats(1, 2).replaceFirst('reg: 1, dir: 1', 'reg: 2, dir: 1'),
        stats(1, 1).replaceFirst('1 bytes', '1,000 bytes'),
        '${stats(1, 1)}\u0000',
        'x' * 16385,
      ]) {
        expect(
          () => PreparedRootCapacity.fromRsyncStats(raw),
          throwsFormatException,
        );
      }
    },
  );
  test(
    'full-disk budget uses root capacity and includes boundary equality',
    () async {
      for (final delta in [0, -1]) {
        final runner = FakeCommandRunner();
        configurePreparedSource(
          runner,
          disk: '/dev/vda',
          diskBytes: 63 * gib + 512 * 1048576 + 2 * 1048576 + delta,
          budgetStats: stats(50 * gib, 65536),
        );
        expect(
          await const InstallPreflight().check(context(runner)),
          delta == 0,
        );
        checks.noMutations(runner);
      }
    },
  );
  test(
    'free-space and manual use the selected root rather than the whole disk',
    () async {
      for (final mode in ['free_space', 'manual']) {
        for (final fits in [true, false]) {
          final runner = FakeCommandRunner();
          configurePreparedSource(
            runner,
            disk: '/dev/vda',
            diskBytes: 256 * gib,
            budgetStats: stats((fits ? 2 : 100) * gib, 65536),
          );
          expect(
            await const InstallPreflight().check(
              context(runner, mode: mode, manual: mode == 'manual'),
            ),
            fits,
          );
          expect(runner.wasCommandCalled('rsync'), true);
          checks.noMutations(runner);
        }
      }
    },
  );
  test(
    'inventory deadline is explicit and changed selection cannot reuse the budget',
    () async {
      for (final change in [false, true]) {
        final runner = InventoryRunner();
        configurePreparedSource(runner, disk: '/dev/vda');
        final ctx = context(runner);
        if (change) {
          runner.afterInventory = () => ctx.state['selectedDisk'] = '/dev/vdb';
        }
        expect(await const InstallPreflight().check(ctx), !change);
        expect(runner.inventoryTimeout, const Duration(seconds: 60));
        checks.noMutations(runner);
      }
    },
  );
  test(
    'an oversized prepared root fails before stage one and the mutation gate',
    () async {
      final graph = pipeline.PipelineGraph();
      graph.reset();
      configurePreparedSource(
        graph,
        disk: '/dev/vda',
        budgetStats: stats(100 * gib, 65536),
      );
      graph.addResponse('uname', ['-m'], stdout: 'x86_64');
      final stages = <int>[];
      final engine = pipeline.engine(graph);
      expect(
        await engine.runInstall(
          pipeline.state(),
          (_, _) {},
          (_) {},
          onStage: stages.add,
        ),
        false,
      );
      expect(stages, isEmpty);
      expect(engine.lastOutcome!.primaryFailure, 'PREFLIGHT_FAILED');
      checks.noMutations(graph);
      expect(
        graph.commandLog.where(
          (v) => v.command == 'rsync' && !v.args.contains('--dry-run'),
        ),
        isEmpty,
      );
    },
  );
  test('inventory failure or malformed output prevents mutations', () async {
    for (final mode in ['missing', 'failed', 'malformed']) {
      final runner = FakeCommandRunner();
      configurePreparedSource(
        runner,
        disk: '/dev/vda',
        budgetStats: mode == 'malformed' ? 'SECRET' : stats(2 * gib, 30000),
        budgetStarted: mode != 'missing',
        budgetExitCode: mode == 'failed' ? 1 : 0,
      );
      expect(await const InstallPreflight().check(context(runner)), false);
      checks.noMutations(runner);
    }
  });
  test(
    'copy and inventory share exact filters while copy retains its prior flags',
    () {
      final copy = FileCopyStage.mainCopyArguments(['--exclude=/foreign/*']);
      final scan = FileCopyStage.mainCopyArguments([
        '--exclude=/foreign/*',
      ], dryRun: true);
      expect(
        copy,
        jsonDecode(
          File('test/fixtures/rsync_main_args_v1.json').readAsStringSync(),
        ),
      );
      expect(copy.take(4), [
        '-aAX',
        '--numeric-ids',
        '--info=progress2,stats2',
        '--no-human-readable',
      ]);
      expect(
        copy.where((v) => v.startsWith('--exclude=')),
        scan.where((v) => v.startsWith('--exclude=')),
      );
      expect(copy.skip(copy.length - 2), ['/', '/mnt/']);
      expect(scan.contains('--dry-run'), true);
      expect(copy.contains('--dry-run'), false);
    },
  );
  test(
    'real rsync inventory counts sparse/hardlink names, excludes data and never changes destination',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'ro-budget fixture ',
      );
      try {
        final source = Directory('${directory.path}/source')..createSync();
        final target = Directory('${directory.path}/target')..createSync();
        Directory('${source.path}/usr/bin').createSync(recursive: true);
        Directory('${target.path}/usr/bin').createSync(recursive: true);
        final app = File('${source.path}/usr/bin/app');
        final handle = app.openSync(mode: FileMode.write);
        handle.truncateSync(30 * gib);
        handle.closeSync();
        expect(
          (await Process.run('ln', [
            app.path,
            '${source.path}/usr/bin/hardlink',
          ])).exitCode,
          0,
        );
        Link('${source.path}/usr/bin/link').createSync('/outside');
        Directory('${source.path}/home/liveuser').createSync(recursive: true);
        final excluded = File(
          '${source.path}/home/liveuser/excluded',
        ).openSync(mode: FileMode.write);
        excluded.truncateSync(100 * gib);
        excluded.closeSync();
        File('${target.path}/keep').writeAsStringSync('unchanged');
        final args = FileCopyStage.mainCopyArguments([
          '--exclude=/boot/efi/*',
          '--exclude=/boot/efi',
        ], dryRun: true);
        args[args.length - 2] = '${source.path}/';
        args[args.length - 1] = '${target.path}/';
        final result = await Process.run(
          'rsync',
          args,
          environment: {'LC_ALL': 'C'},
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
        final budget = PreparedRootCapacity.fromRsyncStats(
          result.stdout as String,
        );
        expect(budget.sourceBytes, 60 * gib + 8);
        expect(budget.entryCount, 7);
        expect(
          target
              .listSync(recursive: true)
              .map((v) => v.path.substring(target.path.length))
              .toList()
            ..sort(),
          ['/keep', '/usr', '/usr/bin'],
        );
        expect(File('${target.path}/keep').readAsStringSync(), 'unchanged');
        expect(app.lengthSync(), 30 * gib);
      } finally {
        directory.deleteSync(recursive: true);
      }
    },
  );
}
