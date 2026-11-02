import 'dart:convert';
import 'package:test/test.dart';
import 'package:flutter_test/flutter_test.dart' show testWidgets;
import 'package:ro_installer/services/command_runner.dart';
import 'package:ro_installer/services/fake_command_runner.dart';
import 'package:ro_installer/services/install_stages/stage_context.dart';
import 'package:ro_installer/services/install_stages/free_space_readiness.dart';
import 'package:ro_installer/services/install_stages/partitioning_stage.dart';
import '../free_space_installation_test.dart' as p;
import 'full_disk_readiness_test.dart' as f;

class ProbeRunner extends FakeCommandRunner {
  ProbeRunner({super.defaultSuccess = false});
  final timeouts = <Duration?>[];
  VoidCallback? afterProbe;
  @override
  Future<CommandResult> run(
    String command,
    List<String> args, {
    bool isMock = false,
    CommandLogCallback? onLog,
    Duration? timeout,
    String? stdinText,
  }) async {
    final value = await super.run(
      command,
      args,
      isMock: isMock,
      onLog: onLog,
      timeout: timeout,
      stdinText: stdinText,
    );
    if (command == '/usr/bin/python3') {
      timeouts.add(timeout);
      afterProbe?.call();
    }
    return value;
  }
}

typedef VoidCallback = void Function();
StageContext context(
  ProbeRunner runner,
  f.IdentitySession session, {
  Map<String, dynamic>? state,
}) => StageContext(
  state: state ?? p.state(),
  log: (_) {},
  onProgress: (_, _) {},
  commandRunner: runner,
  mountSession: session,
  approvedFreeSpacePlan: p.approved(),
  runCmd:
      (
        cmd,
        args,
        log, {
        bool isMock = false,
        List<int> allowedExitCodes = const [0],
      }) async {
        final result = await runner.run(cmd, args);
        return result.started && allowedExitCodes.contains(result.exitCode);
      },
);
void response(
  ProbeRunner runner, {
  Map<String, dynamic>? value,
  String? raw,
  int code = 0,
  bool started = true,
}) => runner.addResponseForCommand(
  '/usr/bin/python3',
  stdout: raw ?? jsonEncode(value ?? p.fixture()['created']),
  exitCode: code,
  started: started,
);
void main() {
  testWidgets('immediate readiness completes without advancing the clock', (
    tester,
  ) async {
    final runner = ProbeRunner();
    response(runner);
    final session = f.IdentitySession(runner);
    bool? ready;
    waitForFreeSpaceLayout(
      context(runner, session),
    ).then((v) => ready = v != null);
    await tester.pump();
    expect(ready, true);
    expect(session.calls, 2);
    expect(runner.timeouts, [const Duration(seconds: 1)]);
    final args = runner.commandLog.single.args;
    expect(args.take(4), [
      '-I',
      '/usr/libexec/ro_installer_gpt.py',
      '--probe',
      '/dev/vda',
    ]);
    expect(args[5], '--preserve-slots');
    expect(jsonDecode(args[6]), [3, 4]);
  });
  test(
    'transient worker failure retries but a readable wrong proof does not',
    () async {
      final runner = ProbeRunner();
      response(runner, code: 2, raw: '');
      response(runner);
      final session = f.IdentitySession(runner);
      expect(await waitForFreeSpaceLayout(context(runner, session)), isNotNull);
      expect(runner.commandLog, hasLength(2));
      expect(session.calls, 3);
    },
  );
  for (final failAt in [1, 2]) {
    test('device change at identity check $failAt rejects readiness', () async {
      final runner = ProbeRunner();
      response(runner);
      final session = f.IdentitySession(runner)..failAt = failAt;
      expect(await waitForFreeSpaceLayout(context(runner, session)), isNull);
      expect(session.calls, failAt);
    });
  }
  test(
    'changed preservation, identities and ranges fail without retry',
    () async {
      for (final mutate in <void Function(Map<String, dynamic>)>[
        (v) => v['preservationFingerprint'] = 'b' * 64,
        (v) => v['snapshot']['device']['diskSequence'] += 1,
        (v) => v['snapshot']['partitions'].removeLast(),
        (v) => v['snapshot']['partitions'].last['partitionGuid'] =
            '77777777-7777-7777-7777-777777777777',
        (v) => v['snapshot']['partitions'].last['endSector'] -= 2048,
        (v) => v['snapshot']['partitions'].first['attributesHex'] =
            '0000000000000001',
      ]) {
        final runner = ProbeRunner();
        final value = p.fixture()['created'] as Map<String, dynamic>;
        mutate(value);
        response(runner, value: value);
        expect(
          await waitForFreeSpaceLayout(
            context(runner, f.IdentitySession(runner)),
          ),
          isNull,
        );
        expect(runner.commandLog, hasLength(1));
      }
    },
  );
  test(
    'missing worker, malformed, duplicate and oversized frames fail closed',
    () async {
      for (final raw in [
        '',
        '{',
        '{}',
        '{"snapshot":{},"snapshot":{}}',
        'x' * 8193,
      ]) {
        final runner = ProbeRunner();
        response(runner, raw: raw);
        expect(
          await waitForFreeSpaceLayout(
            context(runner, f.IdentitySession(runner)),
          ),
          isNull,
        );
        expect(runner.commandLog, hasLength(1));
      }
      final runner = ProbeRunner();
      response(runner, started: false);
      expect(
        await waitForFreeSpaceLayout(
          context(runner, f.IdentitySession(runner)),
        ),
        isNull,
      );
      expect(runner.commandLog, hasLength(1));
    },
  );
  testWidgets('unready worker exhausts bounded retries without formatting', (
    tester,
  ) async {
    final runner = ProbeRunner();
    for (var n = 0; n < 20; n++) {
      response(runner, code: 2, raw: '');
    }
    bool? finished;
    waitForFreeSpaceLayout(
      context(runner, f.IdentitySession(runner)),
    ).then((v) => finished = v == null);
    await tester.pump();
    for (var n = 0; n < 20 && finished == null; n++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(finished, true);
    expect(runner.commandLog, hasLength(20));
    expect(
      runner.commandLog.where((v) => v.command.startsWith('mkfs.')),
      isEmpty,
    );
  });
  test(
    'elapsed deadline and revocation reject without legacy fallback',
    () async {
      final runner = ProbeRunner();
      response(runner);
      final state = p.state();
      state.remove('_approvedFreeSpacePlan');
      expect(
        await waitForFreeSpaceLayout(
          context(runner, f.IdentitySession(runner), state: state),
        ),
        isNull,
      );
      expect(runner.commandLog, isEmpty);
      expect(
        await waitForFreeSpaceLayout(
          context(runner, f.IdentitySession(runner)),
          monotonicElapsed: () => const Duration(seconds: 5),
        ),
        isNull,
      );
      expect(runner.commandLog, isEmpty);
    },
  );
  test('approval revoked during probe cannot bind a created layout', () async {
    final state = p.state();
    final runner = ProbeRunner()
      ..afterProbe = () => state.remove('_approvedFreeSpacePlan');
    response(runner);
    final ctx = context(runner, f.IdentitySession(runner), state: state);
    expect(await waitForFreeSpaceLayout(ctx), isNull);
    expect(ctx.createdFreeSpaceLayout, isNull);
  });
  testWidgets('free-space stage has no unconditional two-second delay', (
    tester,
  ) async {
    final runner = ProbeRunner(defaultSuccess: true);
    response(
      runner,
      value: {
        'snapshot': p.fixture()['snapshot'],
        'preservationFingerprint': p
            .fixture()['approval']['preservationFingerprint'],
      },
    );
    response(runner);
    bool? success;
    final ctx = context(runner, f.IdentitySession(runner));
    const PartitioningStage().execute(ctx).then((v) => success = v.success);
    await tester.pump();
    expect(success, true);
    expect(ctx.createdFreeSpaceLayout, isNotNull);
    expect(runner.wasCommandCalled('partprobe'), true);
    expect(runner.wasCommandCalled('udevadm'), true);
  });
}
