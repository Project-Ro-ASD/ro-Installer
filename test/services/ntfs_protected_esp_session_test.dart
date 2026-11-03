import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:ro_installer/models/approved_ntfs_shrink_plan.dart';
import 'package:ro_installer/models/approved_free_space_plan.dart';
import 'package:ro_installer/models/gpt_disk_snapshot.dart';
import 'package:ro_installer/services/command_runner.dart';
import 'package:ro_installer/services/fake_command_runner.dart';
import 'package:ro_installer/services/mount_session.dart';
import 'protected_esp_session_test.dart' as manual;

Map<String, dynamic> sample(int index, String disk) {
  final row =
      (jsonDecode(
                File('test/fixtures/ntfs_approvals_v1.json').readAsStringSync(),
              )
              as Map)['bases'][index]
          as Map<String, dynamic>;
  row['input']['proposal']['snapshot']['device']['path'] = disk;
  row['input']['approval']['intent']['device']['path'] = disk;
  row['created']['device']['path'] = disk;
  return row;
}

ApprovedNtfsShrinkPlan approval(Map<String, dynamic> row) =>
    ApprovedNtfsShrinkPlan.fromJson(row['input']);
CreatedNtfsLayout layout(Map<String, dynamic> row) =>
    approval(row).verifyCreated(
      GptDiskSnapshot.fromJson(row['created']),
      row['proof'] as String,
    );

CreatedFreeSpaceLayout freeLayout() {
  final f = jsonDecode(
    File('test/fixtures/free_space_execution_v1.json').readAsStringSync(),
  );
  return ApprovedFreeSpacePlan.fromJson({
    'snapshot': f['snapshot'],
    'approval': f['approval'],
  }).verifyCreated(
    GptDiskSnapshot.fromJson(f['created']['snapshot']),
    f['created']['preservationFingerprint'],
  );
}

/// Distinct source2/root3 identities; all operations stay in a synthetic graph.
class NtfsGraph extends manual.EspGraph {
  NtfsGraph(this.disk);
  final String disk;
  String part(int number) =>
      '$disk${RegExp(r'[0-9]$').hasMatch(disk) ? 'p' : ''}$number';
  @override
  void fat(String target, String root, Iterable<String> options) {
    add(target, device: '259:1', root: root, type: 'vfat', source: part(1));
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
    if (command == 'lsblk' && args.first == '-dnro') {
      commandLog.add(RecordedCommand(command: command, args: args));
      final number = [1, 2, 3].where((n) => args.last == part(n));
      return CommandResult(
        command: command,
        args: args,
        started: true,
        exitCode: number.length == 1 ? 0 : 1,
        stdout: number.length == 1 ? '259:${number.single}' : '',
        stderr: '',
      );
    }
    final result = await super.run(
      command,
      args,
      isMock: isMock,
      onLog: onLog,
      timeout: timeout,
      stdinText: stdinText,
    );
    if (command == 'mount' &&
        args.first == '-o' &&
        (args[2] == part(2) || args[2] == part(3))) {
      final index = rows.indexWhere((m) => m.target == args.last);
      if (index >= 0) {
        final m = rows[index];
        rows[index] = MountRecord(
          m.id,
          m.parent,
          args[2] == part(3) ? '259:3' : '259:2',
          m.root,
          m.target,
          m.type,
          m.source,
          m.options,
        );
      }
    }
    return result;
  }
}

Future<VerifiedMountSession> ready(NtfsGraph g) async {
  final s = g.session();
  await s.initialize();
  await s.validateTarget(g.disk);
  return s;
}

Future<VerifiedMountSession> rooted(
  NtfsGraph g,
  Map<String, dynamic> row,
) async {
  final s = await ready(g);
  expect(await s.inspectNtfsEspReuse(approval(row)), true);
  expect(g.rows.where((m) => m.target.startsWith('/mnt')), isEmpty);
  s.bindCreatedNtfsLayout(layout(row));
  expect(
    await s.mount(['-o', 'compress=zstd:1,subvol=root', g.part(3), '/mnt']),
    true,
  );
  expect(g.rows.singleWhere((m) => m.target == '/mnt').device, '259:3');
  return s;
}

void main() {
  for (final sector in [0, 1]) {
    for (final disk in ['/dev/vda', '/dev/nvme0n1']) {
      test(
        'NTFS protected EFI keeps source/root separate $sector $disk',
        () async {
          final g = NtfsGraph(disk), row = sample(sector, disk);
          final s = await rooted(g, row);
          expect(await s.mountProtectedEsp(), true);
          expect(await s.verifyProtectedEsp(), true);
          final base = g.rows.singleWhere((m) => m.target == manual.base);
          expect(base.source, g.part(1));
          expect(base.options, contains('ro'));
          final child = g.rows.singleWhere((m) => m.target == manual.owned);
          expect(child.options, contains('rw'));
          expect(child.root.toLowerCase(), '/efi/fedora');
          expect(
            g.rows.any(
              (m) => m.target == manual.stage || m.target == manual.probe,
            ),
            false,
          );
          expect(
            g.commandLog.where(
              (c) => c.command == 'mount' && c.args.contains(g.part(2)),
            ),
            isEmpty,
          );
          await manual.cleaned(g, s);
        },
      );
    }
  }
  test(
    'pending NTFS inspection never opens full root2 or legacy mode fallbacks',
    () async {
      final g = NtfsGraph('/dev/vda'), row = sample(0, '/dev/vda');
      final s = await ready(g);
      expect(() => s.bindCreatedNtfsLayout(layout(row)), throwsStateError);
      expect(await s.inspectNtfsEspReuse(approval(row)), true);
      final count = g.commandLog.length;
      for (final args in [
        ['-o', 'compress=zstd:1,subvol=root', g.part(2), '/mnt'],
        ['-o', 'compress=zstd:1,subvol=root', g.part(3), '/mnt'],
        [g.part(1), manual.base],
        ['-t', 'tmpfs', 'tmpfs', '/mnt/tmp'],
      ]) {
        expect(await s.mount(args), false);
      }
      expect(await s.mountProtectedEsp(), false);
      expect(await s.mountReadOnlyEspProbe(manual.approval()), false);
      expect(
        () => s.bindCreatedManualLayout(manual.layout()),
        throwsStateError,
      );
      expect(g.commandLog.length, count);
      await expectLater(s.validateTarget('/dev/sdz'), throwsStateError);
      await s.validateTarget(g.disk, commit: true);
      s.bindCreatedNtfsLayout(layout(row));
      expect(() => s.bindCreatedNtfsLayout(layout(row)), throwsStateError);
      expect(
        () => s.bindCreatedManualLayout(manual.layout()),
        throwsStateError,
      );
      final after = g.commandLog.length;
      expect(
        await s.mount(['-o', 'compress=zstd:1,subvol=root', g.part(2), '/mnt']),
        false,
      );
      expect(g.commandLog.length, after);
      await manual.cleaned(g, s);
    },
  );
  test(
    'inspection ownership includes preparation fingerprint, not just geometry',
    () async {
      final g = NtfsGraph('/dev/vda'), row = sample(0, '/dev/vda');
      final s = await ready(g);
      expect(await s.inspectNtfsEspReuse(approval(row)), true);
      final changed = sample(0, '/dev/vda');
      changed['input']['approval']['preparationFingerprint'] = 'f' * 64;
      expect(() => s.bindCreatedNtfsLayout(layout(changed)), throwsStateError);
      s.bindCreatedNtfsLayout(layout(row));
      await manual.cleaned(g, s);
    },
  );
  for (final fault in [
    'collision',
    'space',
    'protocol',
    'busy',
    'probe-mount',
  ]) {
    test(
      'NTFS preflight $fault cannot publish ownership or reopen fallback',
      () async {
        final g = NtfsGraph('/dev/vda')
          ..collision = fault == 'collision'
          ..insufficient = fault == 'space'
          ..malformedBudget = fault == 'protocol';
        if (fault == 'busy') g.busy.add(manual.probe);
        if (fault == 'probe-mount') g.failedMountTargets.add(manual.probe);
        final s = await ready(g), row = sample(0, '/dev/vda');
        expect(await s.inspectNtfsEspReuse(approval(row)), false);
        expect(() => s.bindCreatedNtfsLayout(layout(row)), throwsStateError);
        expect(await s.inspectNtfsEspReuse(approval(row)), false);
        final count = g.commandLog.length;
        expect(await s.mount(['-o', 'subvolid=5', g.part(2), '/mnt']), false);
        expect(await s.mount([g.part(1), manual.base]), false);
        expect(await s.mountReadOnlyEspProbe(manual.approval()), false);
        expect(
          () => s.bindCreatedManualLayout(manual.layout()),
          throwsStateError,
        );
        expect(g.commandLog.length, count);
        final report = await s.cleanup();
        expect(report.success, fault != 'busy');
        expect(g.namespaceCreated, false);
      },
    );
  }
  test(
    'manual ownership cannot be replaced by an NTFS inspection attempt',
    () async {
      final g = NtfsGraph('/dev/vda'), s = await ready(g);
      expect(await s.inspectEspReuse(manual.approval()), true);
      expect(await s.inspectNtfsEspReuse(approval(sample(0, g.disk))), false);
      s.bindCreatedManualLayout(manual.layout());
      // The synthetic manual graph uses root2; switching attempts cannot poison it.
      expect(
        await s.mount(['-o', 'compress=zstd:1,subvol=root', g.part(2), '/mnt']),
        true,
      );
      await manual.cleaned(g, s);
    },
  );
  for (final drift in ['namespace', 'foreign']) {
    test('NTFS $drift drift rejects mount before commands', () async {
      final g = NtfsGraph('/dev/vda'),
          s = await ready(g),
          row = sample(0, '/dev/vda');
      expect(await s.inspectNtfsEspReuse(approval(row)), true);
      if (drift == 'namespace') {
        g.ns = 'mnt:[changed]';
      } else {
        g.add('/mnt/foreign');
      }
      s.bindCreatedNtfsLayout(layout(row));
      final count = g.commandLog.length;
      expect(await s.mount(['-o', 'subvolid=5', g.part(3), '/mnt']), false);
      expect(g.commandLog.length, count);
      expect((await s.cleanup()).success, false);
    });
  }
  for (final fault in ['remount', 'noexec', 'root', 'partial-stage']) {
    test('NTFS protected EFI $fault failure retains owned cleanup', () async {
      final g = NtfsGraph('/dev/vda'),
          s = await rooted(g, sample(0, '/dev/vda'));
      g.failRemount = fault == 'remount';
      g.omitNoexec = fault == 'noexec';
      g.wrongRoot = fault == 'root';
      if (fault == 'partial-stage') g.partial = manual.stage;
      expect(await s.mountProtectedEsp(), false);
      expect(await s.verifyProtectedEsp(), false);
      if (fault == 'root') {
        final count = g.commandLog.where((c) => c.command == 'umount').length;
        final report = await s.cleanup();
        expect(report.success, false);
        expect(report.remaining, contains(manual.owned));
        expect(
          report.remaining.toSet(),
          g.rows
              .where((m) => m.target.startsWith('/mnt'))
              .map((m) => m.target)
              .toSet(),
        );
        expect(g.commandLog.where((c) => c.command == 'umount').length, count);
      } else {
        await manual.cleaned(g, s);
      }
    });
  }
  test(
    'NTFS writable staging rechecks EFI capacity before namespace creation',
    () async {
      final g = NtfsGraph('/dev/vda'),
          s = await rooted(g, sample(0, '/dev/vda'));
      g.insufficient = true;
      expect(await s.mountProtectedEsp(), false);
      expect(g.namespaceCreated, false);
      await manual.cleaned(g, s);
    },
  );
  test('free-space binding cannot be replaced by NTFS ownership', () async {
    final g = NtfsGraph('/dev/vda'),
        s = await ready(g),
        row = sample(0, '/dev/vda');
    s.bindCreatedFreeSpaceLayout(freeLayout());
    final count = g.commandLog.length;
    expect(await s.inspectNtfsEspReuse(approval(row)), false);
    expect(() => s.bindCreatedNtfsLayout(layout(row)), throwsStateError);
    expect(g.commandLog.length, count);
    await manual.cleaned(g, s);
  });
  test(
    'NTFS approval for another selected disk never starts a probe',
    () async {
      final g = NtfsGraph('/dev/vda'),
          s = await ready(g),
          row = sample(0, '/dev/nvme0n1');
      final count = g.commandLog.length;
      expect(await s.inspectNtfsEspReuse(approval(row)), false);
      expect(() => s.bindCreatedNtfsLayout(layout(row)), throwsStateError);
      expect(g.commandLog.length, count);
      await manual.cleaned(g, s);
    },
  );
  test('simulated session never grants NTFS inspection or targets', () async {
    final g = NtfsGraph('/dev/vda'),
        s = SimulatedMountSession(g),
        row = sample(0, '/dev/vda');
    expect(await s.inspectNtfsEspReuse(approval(row)), false);
    expect(() => s.bindCreatedNtfsLayout(layout(row)), throwsStateError);
    expect(g.commandLog, isEmpty);
  });
}
