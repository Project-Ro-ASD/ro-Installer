import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:ro_installer/models/approved_manual_plan.dart';
import 'package:ro_installer/models/approved_free_space_plan.dart';
import 'package:ro_installer/models/gpt_disk_snapshot.dart';
import 'package:ro_installer/services/command_runner.dart';
import 'package:ro_installer/services/fake_command_runner.dart';
import 'package:ro_installer/services/mount_session.dart';
import '../support/mount_graph.dart';

const probe = VerifiedMountSession.espProbeTarget;
const stage = VerifiedMountSession.espStageTarget;
const base = VerifiedMountSession.espTarget;
const owned = VerifiedMountSession.espOwnedTarget;
Map<String, dynamic> fixture([int index = 0]) =>
    (jsonDecode(
              File('test/fixtures/manual_ownership_v1.json').readAsStringSync(),
            )
            as List)[index]
        as Map<String, dynamic>;
ApprovedManualPlan approval([int index = 0]) {
  final v = fixture(index);
  return ApprovedManualPlan.fromJson({
    'snapshot': v['snapshot'],
    'approval': v['approval'],
  });
}

CreatedManualLayout layout([int index = 0]) {
  final v = fixture(index);
  return approval(index).verifyCreated(
    GptDiskSnapshot.fromJson(v['created']['snapshot']),
    v['created']['preservationFingerprint'],
  );
}

/// Models mount identities and per-mount flags; never performs a mount syscall.
class EspGraph extends MountGraph {
  bool collision = false,
      namespaceCreated = false,
      failRemount = false,
      omitNoexec = false,
      wrongRoot = false;
  String? partial;
  bool insufficient = false, malformedBudget = false;
  @override
  String text() => rows
      .map(
        (m) =>
            '${m.id} ${m.parent} ${m.device} ${m.root} ${m.target} ${m.options.join(',')} - ${m.type} ${m.source} rw',
      )
      .join('\n');
  void flags(String target, Iterable<String> options) {
    final n = rows.indexWhere((m) => m.target == target),
        m = rows.firstWhere((m) => m.target == target);
    rows[n] = MountRecord(
      m.id,
      m.parent,
      m.device,
      m.root,
      m.target,
      m.type,
      m.source,
      options,
    );
  }

  void fat(String target, String root, Iterable<String> options) {
    add(target, device: '8:1', root: root, type: 'vfat', source: '/dev/vda1');
    flags(target, options);
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
    CommandResult result([int code = 0]) => CommandResult(
      command: command,
      args: args,
      started: true,
      exitCode: code,
      stdout: '',
      stderr: '',
    );
    final customMount =
        command == 'mount' &&
        (const [probe, stage, base, owned].contains(args.last)) &&
        args.length > 2;
    if (command == '/usr/bin/python3') {
      commandLog.add(RecordedCommand(command: command, args: args));
      return CommandResult(
        command: command,
        args: args,
        started: true,
        exitCode: 0,
        stdout: jsonEncode({
          'requiredBytes': 20000000,
          'availableBytes': insufficient ? 1 : 100000000,
          'sourceBytes': 1000000,
          'fileCount': 2,
          'clusterBytes': 4096,
          'sufficient': !insufficient,
          if (malformedBudget) 'unexpected': true,
        }),
        stderr: '',
      );
    }
    if (command == 'test' &&
        (args.last.startsWith(stage) || args.last.startsWith(probe))) {
      commandLog.add(RecordedCommand(command: command, args: args));
      if (args.last.endsWith('/fedora')) {
        return result(
          (collision || namespaceCreated) && args.first == '-e' ? 0 : 1,
        );
      }
      return result(0);
    }
    if (command == 'mkdir' &&
        args.length == 1 &&
        args.single == '$stage/EFI/fedora') {
      commandLog.add(RecordedCommand(command: command, args: args));
      if (collision || namespaceCreated) return result(1);
      namespaceCreated = true;
      return result();
    }
    if (!customMount) {
      return super.run(
        command,
        args,
        isMock: isMock,
        onLog: onLog,
        timeout: timeout,
        stdinText: stdinText,
      );
    }
    commandLog.add(RecordedCommand(command: command, args: args));
    if (failedMountTargets.contains(args.last)) return result(1);
    if (args.contains('remount,bind,ro,nosuid,nodev,noexec')) {
      if (failRemount) return result(1);
      flags(base, {'ro', 'nosuid', 'nodev', if (!omitNoexec) 'noexec'});
    } else if (args.first == '--bind') {
      fat(
        args.last,
        args.last == owned
            ? (wrongRoot ? '/EFI/Microsoft' : '/EFI/fedora')
            : '/',
        {'rw', 'nosuid', 'nodev', 'noexec'},
      );
    } else {
      fat(args.last, '/', {
        args[3].startsWith('ro,') ? 'ro' : 'rw',
        'nosuid',
        'nodev',
        'noexec',
      });
    }
    return result(partial == args.last ? 23 : 0);
  }
}

Future<VerifiedMountSession> ready(EspGraph g) async {
  final s = g.session();
  await s.initialize();
  await s.validateTarget('/dev/vda');
  return s;
}

Future<VerifiedMountSession> rooted(EspGraph g) async {
  final s = await ready(g);
  expect(await s.inspectEspReuse(approval()), true);
  s.bindCreatedManualLayout(layout());
  expect(
    await s.mount(['-o', 'compress=zstd:1,subvol=root', '/dev/vda2', '/mnt']),
    true,
  );
  return s;
}

Future<void> cleaned(EspGraph g, VerifiedMountSession s) async {
  expect((await s.cleanup()).success, true);
  expect(
    g.rows.where((m) => m.target == '/mnt' || m.target.startsWith('/mnt/')),
    isEmpty,
  );
}

void main() {
  test(
    'read-only probe is bound to existing ESP and can finish before target commit',
    () async {
      final g = EspGraph();
      final session = await ready(g);
      expect(await session.mountReadOnlyEspProbe(approval()), true);
      final record = g.rows.singleWhere((m) => m.target == probe);
      expect(record.options, containsAll(['ro', 'nodev', 'nosuid', 'noexec']));
      expect(record.options, isNot(contains('rw')));
      await expectLater(
        session.validateTarget('/dev/vda', commit: true),
        throwsStateError,
      );
      expect(await session.finishEspProbe(), true);
      await session.validateTarget('/dev/vda', commit: true);
      expect(() => session.bindCreatedManualLayout(layout()), throwsStateError);
      expect(await session.inspectEspReuse(approval()), true);
      session.bindCreatedManualLayout(layout());
      expect(await session.finishEspProbe(), false);
      await cleaned(g, session);
    },
  );
  test(
    'normal EFI writes and arbitrary staging calls are unavailable for reuse',
    () async {
      final g = EspGraph();
      final s = await rooted(g);
      final count = g.commandLog.length;
      for (final args in [
        ['/dev/vda1', base],
        [
          '-t',
          'vfat',
          '-o',
          'rw,nosuid,nodev,noexec,umask=0077',
          '/dev/vda1',
          stage,
        ],
        ['--bind', stage, base],
        ['--bind', '$stage/EFI/Microsoft', owned],
      ]) {
        expect(await s.mount(args), false);
      }
      expect(g.commandLog.length, count);
      await cleaned(g, s);
    },
  );
  test(
    'only new fedora subtree remains writable and full staging disappears',
    () async {
      final g = EspGraph();
      final s = await rooted(g);
      expect(await s.mountProtectedEsp(), true);
      expect(await s.verifyProtectedEsp(), true);
      expect(g.rows.any((m) => m.target == stage), false);
      expect(
        g.rows.singleWhere((m) => m.target == base).options,
        contains('ro'),
      );
      expect(g.rows.singleWhere((m) => m.target == owned).root, '/EFI/fedora');
      expect(
        g.rows.singleWhere((m) => m.target == owned).options,
        contains('rw'),
      );
      final count = g.commandLog.length;
      expect(await s.mountProtectedEsp(), false);
      expect(g.commandLog.length, count);
      expect(
        g.commandLog.any(
          (c) =>
              c.command == 'mkdir' &&
              c.args.length == 1 &&
              c.args.single == '$stage/EFI/fedora',
        ),
        true,
      );
      expect(
        g.commandLog.any(
          (c) =>
              c.command == 'mount' &&
              c.args.contains('remount,bind,ro,nosuid,nodev,noexec'),
        ),
        true,
      );
      await cleaned(g, s);
      final unmounts = g.commandLog
          .where((c) => c.command == 'umount')
          .map((c) => c.args.single)
          .toList();
      expect(unmounts, [probe, stage, owned, base, '/mnt']);
    },
  );
  test(
    'existing namespace fails before creating or binding any boot directory',
    () async {
      final g = EspGraph();
      final s = await rooted(g);
      g.collision = true;
      expect(await s.mountProtectedEsp(), false);
      expect(g.namespaceCreated, false);
      expect(
        g.commandLog.any(
          (c) => c.command == 'mount' && c.args.first == '--bind',
        ),
        false,
      );
      await cleaned(g, s);
    },
  );
  for (final target in [stage, base, owned]) {
    test(
      'failed mount at $target leaves only verified resources to clean',
      () async {
        final g = EspGraph()..failedMountTargets.add(target);
        final s = await rooted(g);
        expect(await s.mountProtectedEsp(), false);
        expect(await s.verifyProtectedEsp(), false);
        await cleaned(g, s);
      },
    );
  }
  for (final target in [stage, base, owned]) {
    test(
      'partial mount at $target is tracked despite unsuccessful command exit',
      () async {
        final g = EspGraph()..partial = target;
        final s = await rooted(g);
        expect(await s.mountProtectedEsp(), false);
        await cleaned(g, s);
      },
    );
  }
  for (final wrong in ['remount-exit', 'missing-noexec']) {
    test(
      '$wrong prevents publishing protected state and retains cleanup ownership',
      () async {
        final g = EspGraph()
          ..failRemount = wrong == 'remount-exit'
          ..omitNoexec = wrong == 'missing-noexec';
        final s = await rooted(g);
        expect(await s.mountProtectedEsp(), false);
        expect(await s.verifyProtectedEsp(), false);
        expect(g.rows.any((m) => m.target == owned), false);
        await cleaned(g, s);
      },
    );
  }
  test(
    'wrong bind subtree cannot be claimed or treated as protected',
    () async {
      final g = EspGraph()..wrongRoot = true;
      final s = await rooted(g);
      expect(await s.mountProtectedEsp(), false);
      expect(await s.verifyProtectedEsp(), false);
      expect((await s.cleanup()).success, false);
      expect(g.rows.any((m) => m.target == owned), true);
    },
  );
  test(
    'live session children prevent publishing protection and report owned mounts',
    () async {
      final g = EspGraph();
      final s = await rooted(g);
      g.idle = false;
      expect(await s.mountProtectedEsp(), false);
      expect(await s.verifyProtectedEsp(), false);
      final report = await s.cleanup();
      expect(report.success, false);
      expect(report.remaining, contains(stage));
      expect(g.rows.any((m) => m.target == stage), true);
    },
  );
  test(
    'busy staging never allows protected-state success or hides remaining resources',
    () async {
      final g = EspGraph()..busy.add(stage);
      final s = await rooted(g);
      expect(await s.mountProtectedEsp(), false);
      expect(await s.verifyProtectedEsp(), false);
      final report = await s.cleanup();
      expect(report.success, false);
      expect(report.remaining, contains(stage));
    },
  );
  test(
    'unexpected flags or namespace change after preparation invalidates protection',
    () async {
      for (final change in ['rw', 'namespace', 'foreign']) {
        final g = EspGraph();
        final s = await rooted(g);
        expect(await s.mountProtectedEsp(), true);
        if (change == 'rw') g.flags(base, {'rw', 'nosuid', 'nodev', 'noexec'});
        if (change == 'namespace') g.ns = 'mnt:[other]';
        if (change == 'foreign') {
          g.add('$base/EFI/Microsoft', device: '8:99', root: '/', type: 'vfat');
        }
        expect(await s.verifyProtectedEsp(), false);
        final before = g.commandLog.where((c) => c.command == 'umount').length;
        final report = await s.cleanup();
        expect(report.success, false);
        expect(g.commandLog.where((c) => c.command == 'umount').length, before);
        if (change != 'namespace') {
          expect(report.remaining, containsAll(['/mnt', base, owned]));
          if (change == 'foreign') {
            expect(report.remaining, contains('$base/EFI/Microsoft'));
          }
          expect(identical(await s.cleanup(), report), true);
        } else {
          // An unreadable/unverified namespace cannot supply a trusted inventory.
          expect(report.reason, 'Session cleanup verification failed');
        }
      }
    },
  );
  test(
    'binding cannot mix full/free/manual targets or skip probe ownership cleanup',
    () async {
      final g = EspGraph();
      final s = await ready(g);
      expect(await s.mountReadOnlyEspProbe(approval(1)), false);
      expect(await s.mountReadOnlyEspProbe(approval()), true);
      expect(() => s.bindCreatedManualLayout(layout()), throwsStateError);
      expect(await s.finishEspProbe(), true);
      expect(await s.inspectEspReuse(approval()), true);
      s.bindCreatedManualLayout(layout());
      expect(() => s.bindCreatedManualLayout(layout()), throwsStateError);
      expect(await s.mountProtectedEsp(), false);
      await cleaned(g, s);
    },
  );
  test(
    'reuse inspection rejects collisions, insufficient space and malformed private results before root mount',
    () async {
      for (final fault in ['collision', 'space', 'protocol']) {
        final g = EspGraph()
          ..collision = fault == 'collision'
          ..insufficient = fault == 'space'
          ..malformedBudget = fault == 'protocol';
        final s = await ready(g);
        expect(await s.inspectEspReuse(approval()), false);
        expect(() => s.bindCreatedManualLayout(layout()), throwsStateError);
        expect(g.rows.any((m) => m.target == probe), false);
        expect(g.namespaceCreated, false);
        await cleaned(g, s);
      }
    },
  );
  test(
    'busy read-only probe cannot publish a successful reuse inspection',
    () async {
      final g = EspGraph()..busy.add(probe);
      final s = await ready(g);
      expect(await s.inspectEspReuse(approval()), false);
      expect(() => s.bindCreatedManualLayout(layout()), throwsStateError);
      final report = await s.cleanup();
      expect(report.success, false);
      expect(report.remaining, contains(probe));
    },
  );
  test(
    'space is rechecked in the writable staging mount before namespace creation',
    () async {
      final g = EspGraph();
      final s = await rooted(g);
      g.insufficient = true;
      expect(await s.mountProtectedEsp(), false);
      expect(g.namespaceCreated, false);
      await cleaned(g, s);
    },
  );
  test(
    'free and manual layouts cannot share a mount session binding',
    () async {
      final f = jsonDecode(
        File('test/fixtures/free_space_execution_v1.json').readAsStringSync(),
      );
      final free =
          ApprovedFreeSpacePlan.fromJson({
            'snapshot': f['snapshot'],
            'approval': f['approval'],
          }).verifyCreated(
            GptDiskSnapshot.fromJson(f['created']['snapshot']),
            f['created']['preservationFingerprint'],
          );
      final first = EspGraph();
      final a = await ready(first);
      a.bindCreatedFreeSpaceLayout(free);
      expect(() => a.bindCreatedManualLayout(layout()), throwsStateError);
      await cleaned(first, a);
      final second = EspGraph();
      final b = await ready(second);
      expect(await b.inspectEspReuse(approval()), true);
      b.bindCreatedManualLayout(layout());
      expect(() => b.bindCreatedFreeSpaceLayout(free), throwsStateError);
      await cleaned(second, b);
    },
  );
  test('mount option changes participate in identity tracking', () {
    final a = MountRecord(1, 0, '8:1', '/', '/mnt', 'vfat', '/dev/vda1', [
      'ro',
    ]);
    final b = MountRecord(1, 0, '8:1', '/', '/mnt', 'vfat', '/dev/vda1', [
      'rw',
    ]);
    expect(a.sameIdentity(b), true);
    expect(a.same(b), false);
    expect(() => a.options.add('rw'), throwsUnsupportedError);
    expect(
      () => MountRecord.parse('1 0 0:1 / / rw,ro - overlay root rw'),
      throwsFormatException,
    );
  });
}
