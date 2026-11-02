import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:flutter_test/flutter_test.dart' show testWidgets;
import 'package:ro_installer/models/approved_full_disk_plan.dart';
import 'package:ro_installer/models/gpt_disk_snapshot.dart';
import 'package:ro_installer/services/fake_command_runner.dart';
import 'package:ro_installer/services/mount_session.dart';
import 'package:ro_installer/services/helper_protocol.dart';
import 'package:ro_installer/services/install_stages/stage_context.dart';
import 'package:ro_installer/services/install_stages/full_disk_readiness.dart';
import 'package:ro_installer/services/install_stages/partitioning_stage.dart';

Map<String, dynamic> snapshot([int index = 0]) =>
    (jsonDecode(
          File('test/fixtures/full_disk_ready_v1.json').readAsStringSync(),
        )
        as List)[index];
ApprovedFullDiskPlan approval([int index = 0]) =>
    ApprovedFullDiskPlan(DeviceIdentity.fromJson(snapshot(index)['device']));

class IdentitySession extends SimulatedMountSession {
  IdentitySession(super.runner);
  int calls = 0;
  int? failAt;
  void Function(int)? onValidate;
  @override
  Future<void> validateTarget(String disk, {bool commit = false}) async {
    expect(disk, '/dev/vda');
    expect(commit, true);
    calls++;
    onValidate?.call(calls);
    if (calls == failAt) throw StateError('Device changed');
  }
}

StageContext context(
  FakeCommandRunner runner,
  IdentitySession session, {
  Map<String, dynamic>? state,
}) {
  final plan = approval();
  return StageContext(
    state: state ?? {...plan.state, '_approvedFullDiskPlan': plan.json},
    log: (_) {},
    onProgress: (_, _) {},
    commandRunner: runner,
    mountSession: session,
    approvedPlan: plan,
    runCmd:
        (
          cmd,
          args,
          onLog, {
          bool isMock = false,
          List<int> allowedExitCodes = const [0],
        }) async {
          final result = await runner.run(cmd, args);
          return result.started && allowedExitCodes.contains(result.exitCode);
        },
  );
}

void response(
  FakeCommandRunner runner, {
  Map<String, dynamic>? value,
  String? raw,
  int code = 0,
  bool started = true,
}) => runner.addResponseForCommand(
  '/usr/bin/python3',
  stdout: raw ?? jsonEncode(value ?? snapshot()),
  exitCode: code,
  started: started,
);
void main() {
  for (var index = 0; index < 2; index++) {
    test(
      'accepts canonical ${index == 0 ? 512 : 4096}-byte sector full layout',
      () {
        expect(
          matchesFullDiskLayout(
            approval(index),
            GptDiskSnapshot.fromJson(snapshot(index)),
          ),
          true,
        );
      },
    );
  }
  testWidgets('ready immediately does not introduce an unconditional sleep', (
    tester,
  ) async {
    final runner = FakeCommandRunner(defaultSuccess: false);
    response(runner);
    final session = IdentitySession(runner);
    bool? ready;
    waitForFullDiskLayout(
      context(runner, session),
    ).then((value) => ready = value);
    // Flush only microtasks; no time elapses for a retry/sleep timer.
    await tester.pump();
    expect(ready, true);
    expect(session.calls, 2);
    expect(runner.commandLog.single.args.take(4), [
      '-I',
      '/usr/libexec/ro_installer_gpt.py',
      '--probe',
      '/dev/vda',
    ]);
  });
  test(
    'a transient kernel/GPT probe failure is retried before formatting',
    () async {
      final runner = FakeCommandRunner(defaultSuccess: false);
      response(runner, code: 2, raw: '');
      response(runner);
      final session = IdentitySession(runner);
      expect(await waitForFullDiskLayout(context(runner, session)), true);
      expect(runner.commandLog, hasLength(2));
      expect(session.calls, 3);
    },
  );
  for (final failAt in [1, 2]) {
    test('device change at identity check $failAt refuses readiness', () async {
      final runner = FakeCommandRunner(defaultSuccess: false);
      response(runner);
      final session = IdentitySession(runner)..failAt = failAt;
      expect(await waitForFullDiskLayout(context(runner, session)), false);
      expect(session.calls, failAt);
    });
  }
  test(
    'a readable wrong layout is rejected without retry or formatting',
    () async {
      for (final mutate in <void Function(Map<String, dynamic>)>[
        (s) => s['device']['diskSequence'] = 12,
        (s) => s['device']['majorMinor'] = '252:16',
        (s) => s['device']['size'] += 1048576,
        (s) => s['partitions'][0]['number'] = 3,
        (s) => s['partitions'][0]['startSector'] += 2048,
        (s) => s['partitions'][0]['endSector'] -= 2048,
        (s) => s['partitions'][1]['startSector'] += 2048,
        (s) => s['partitions'][1]['endSector'] -= 2048,
        (s) => s['partitions'][1]['typeGuid'] =
            'ebd0a0a2-b9e5-4433-87c0-68b6b72699c7',
        (s) => s['partitions'][0]['attributesHex'] = '8000000000000000',
        (s) => s['partitions'].removeLast(),
      ]) {
        final s = snapshot();
        mutate(s);
        final runner = FakeCommandRunner(defaultSuccess: false);
        response(runner, value: s);
        expect(
          await waitForFullDiskLayout(context(runner, IdentitySession(runner))),
          false,
        );
        expect(runner.commandLog, hasLength(1));
      }
    },
  );
  test('missing worker, malformed and oversized output fail closed', () async {
    for (final raw in ['', '{', '{}', 'x' * 4097]) {
      final runner = FakeCommandRunner(defaultSuccess: false);
      response(runner, raw: raw);
      expect(
        await waitForFullDiskLayout(context(runner, IdentitySession(runner))),
        false,
      );
      expect(runner.commandLog, hasLength(1));
    }
    final runner = FakeCommandRunner(defaultSuccess: false);
    response(runner, started: false);
    expect(
      await waitForFullDiskLayout(context(runner, IdentitySession(runner))),
      false,
    );
    expect(runner.commandLog, hasLength(1));
  });
  test('unready metadata exhausts only bounded retries', () async {
    final runner = FakeCommandRunner(defaultSuccess: false);
    for (var n = 0; n < 20; n++) {
      response(runner, code: 2, raw: '');
    }
    expect(
      await waitForFullDiskLayout(context(runner, IdentitySession(runner))),
      false,
    );
    expect(runner.commandLog, hasLength(20));
  });
  test('deleted approval is never reinterpreted as legacy readiness', () async {
    final runner = FakeCommandRunner(defaultSuccess: false),
        state = {...approval().state};
    expect(
      await waitForFullDiskLayout(
        context(runner, IdentitySession(runner), state: state),
      ),
      false,
    );
    expect(runner.commandLog, isEmpty);
  });
  test(
    'full partition stage cannot succeed after a valid but wrong layout',
    () async {
      final runner = FakeCommandRunner();
      runner.addResponse('blockdev', [
        '--getsize64',
        '/dev/vda',
      ], stdout: '${80 * 1024 * 1024 * 1024}');
      final s = snapshot();
      s['partitions'][0]['number'] = 3;
      response(runner, value: s);
      final session = IdentitySession(runner);
      final ctx = context(runner, session);
      final result = await const PartitioningStage().execute(ctx);
      expect(result.success, false);
      expect(runner.wasCommandCalled('partprobe'), true);
      expect(runner.wasCommandCalled('udevadm'), true);
      expect(
        runner.commandLog.where((c) => c.command.startsWith('mkfs.')),
        isEmpty,
      );
    },
  );
  test(
    'real parted fallback on a sparse regular file matches readiness geometry',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'ro-full-readiness-',
      );
      try {
        final file = File('${directory.path}/disk.img');
        final handle = file.openSync(mode: FileMode.write);
        handle.truncateSync(80 * 1024 * 1024 * 1024);
        handle.closeSync();
        expect(file.statSync().type, FileSystemEntityType.file);
        for (final args in [
          ['-s', file.path, 'mklabel', 'gpt'],
          ['-s', file.path, 'mkpart', 'ESP', 'fat32', '1MiB', '513MiB'],
          ['-s', file.path, 'set', '1', 'esp', 'on'],
          ['-s', file.path, 'mkpart', 'ROOT', '513MiB', '100%'],
        ]) {
          final process = await Process.run('parted', args);
          expect(process.exitCode, 0, reason: '${process.stderr}');
        }
        const readRegularFile = r"""
import importlib.util,json,os,sys
spec=importlib.util.spec_from_file_location('gpt_fixture',sys.argv[1])
gpt=importlib.util.module_from_spec(spec);spec.loader.exec_module(gpt)
with open(sys.argv[2],'rb') as image:
    print(json.dumps(gpt.verified_snapshot(lambda offset,length:os.pread(image.fileno(),length,offset),json.loads(sys.argv[3]),512)))
""";
        final probe = await Process.run('python3', [
          '-I',
          '-c',
          readRegularFile,
          File('linux/ro_installer_gpt.py').absolute.path,
          file.path,
          jsonEncode(approval().device.json),
        ]);
        expect(probe.exitCode, 0, reason: '${probe.stderr}');
        final value = GptDiskSnapshot.fromJson(
          jsonDecode(probe.stdout as String),
        );
        expect(
          matchesFullDiskLayout(
            approval(),
            value,
            writer: FullDiskPartitionWriter.parted,
          ),
          true,
          reason: jsonEncode(value.json),
        );
        final runner = FakeCommandRunner(defaultSuccess: false);
        response(runner, value: value.json);
        expect(
          await waitForFullDiskLayout(
            context(runner, IdentitySession(runner)),
            writer: FullDiskPartitionWriter.parted,
          ),
          true,
        );
      } finally {
        directory.deleteSync(recursive: true);
      }
    },
  );
  test(
    'writer-specific end alignment is exact and cannot hide extra unused space',
    () {
      final s = snapshot(), sector = s['logicalSectorBytes'] as int;
      final align = 1048576 ~/ sector;
      s['partitions'][1]['endSector'] =
          (s['lastUsableSector'] + 1) ~/ align * align - 1;
      final value = GptDiskSnapshot.fromJson(s);
      expect(matchesFullDiskLayout(approval(), value), false);
      expect(
        matchesFullDiskLayout(
          approval(),
          value,
          writer: FullDiskPartitionWriter.parted,
        ),
        true,
      );
      s['partitions'][1]['endSector'] -= align;
      expect(
        matchesFullDiskLayout(
          approval(),
          GptDiskSnapshot.fromJson(s),
          writer: FullDiskPartitionWriter.parted,
        ),
        false,
      );
    },
  );
  test(
    'late identity success or an approval change cannot grant readiness',
    () async {
      for (final late in [true, false]) {
        final runner = FakeCommandRunner(defaultSuccess: false);
        response(runner);
        final session = IdentitySession(runner),
            ctx = context(runner, IdentitySession(runner));
        var elapsed = Duration.zero;
        session.onValidate = (call) {
          if (call == 2) {
            if (late) {
              elapsed = const Duration(seconds: 5);
            } else {
              ctx.state.remove('_approvedFullDiskPlan');
            }
          }
        };
        final actual = StageContext(
          state: ctx.state,
          log: ctx.log,
          onProgress: ctx.onProgress,
          commandRunner: runner,
          runCmd: ctx.runCmd,
          mountSession: session,
          approvedPlan: ctx.approvedPlan,
        );
        expect(
          await waitForFullDiskLayout(actual, monotonicElapsed: () => elapsed),
          false,
        );
        expect(session.calls, 2);
      }
    },
  );
  test(
    'a mode downgrade during rescan cannot use the legacy success path',
    () async {
      final runner = FakeCommandRunner();
      runner.addResponse('blockdev', [
        '--getsize64',
        '/dev/vda',
      ], stdout: '${80 * 1024 * 1024 * 1024}');
      final session = IdentitySession(runner),
          base = context(runner, IdentitySession(runner));
      final ctx = StageContext(
        state: base.state,
        log: base.log,
        onProgress: base.onProgress,
        commandRunner: runner,
        mountSession: session,
        approvedPlan: base.approvedPlan,
        runCmd:
            (
              cmd,
              args,
              onLog, {
              bool isMock = false,
              List<int> allowedExitCodes = const [0],
            }) async {
              final ok = await base.runCmd(
                cmd,
                args,
                onLog,
                isMock: isMock,
                allowedExitCodes: allowedExitCodes,
              );
              if (cmd == 'partprobe') {
                base.state['partitionMethod'] = 'free_space';
              }
              return ok;
            },
      );
      expect((await const PartitioningStage().execute(ctx)).success, false);
      expect(session.calls, 0);
      expect(
        runner.commandLog.where((c) => c.command == '/usr/bin/python3'),
        isEmpty,
      );
    },
  );
}
