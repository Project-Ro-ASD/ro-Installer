import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:ro_installer/models/approved_manual_plan.dart';
import 'package:ro_installer/models/gpt_disk_snapshot.dart';
import 'package:ro_installer/services/fake_command_runner.dart';
import 'package:ro_installer/services/install_service.dart';

List<Map<String, dynamic>> fixtures() =>
    (jsonDecode(
              File('test/fixtures/manual_ownership_v1.json').readAsStringSync(),
            )
            as List)
        .cast<Map<String, dynamic>>();
ApprovedManualPlan approved(Map<String, dynamic> v) =>
    ApprovedManualPlan.fromJson({
      'snapshot': v['snapshot'],
      'approval': v['approval'],
    });

void main() {
  for (var i = 0; i < 4; i++) {
    test('ownership case $i resolves only exact old and new targets', () {
      final v = fixtures()[i], plan = approved(fixtures()[i]);
      final layout = plan.verifyCreated(
        GptDiskSnapshot.fromJson(v['created']['snapshot']),
        v['created']['preservationFingerprint'],
      );
      expect(layout.rootPath, plan.plan.root.target);
      expect(layout.espPath, plan.plan.esp.target);
      expect(layout.reusesEsp, !plan.plan.esp.formatOnInstall);
      expect(
        plan.allocationGuids.keys.toSet(),
        plan.plan.operations
            .where((o) => o.kind.name == 'createPartition')
            .map((o) => o.partition.role.name)
            .toSet(),
      );
      expect(
        plan.newSlots.toSet(),
        plan.plan.operations
            .where((o) => o.kind.name == 'createPartition')
            .map((o) => o.partition.number)
            .toSet(),
      );
      expect(
        plan.newSlots.length,
        i == 0
            ? 0
            : i == 3
            ? 2
            : 1,
      );
      expect(approved(plan.json).approval, plan.approval);
    });
  }
  test(
    'ownership parser rejects altered geometry, stale types and GUID injection',
    () {
      for (final mutate in <void Function(Map<String, dynamic>)>[
        (v) => v['approval']['intent']['root']['formatOnInstall'] = false,
        (v) => v['approval']['intent']['esp']['number'] = 7,
        (v) => v['approval']['intent']['root']['startSector'] =
            v['approval']['intent']['esp']['startSector'],
        (v) => v['approval']['intent']['root']['fileSystem'] = 'ext4',
        (v) => v['approval']['intent']['device']['diskSequence'] = 12,
        (v) => v['approval']['intent']['tableFingerprint'] = 'b' * 64,
        (v) => v['approval']['allocationGuids']['esp'] =
            v['snapshot']['partitions'][0]['partitionGuid'],
        (v) => v['approval']['allocationGuids']['root'] =
            v['approval']['allocationGuids']['esp'],
        (v) => v['approval']['allocationGuids']['extra'] =
            '77777777-7777-7777-7777-777777777777',
        (v) => v['approval']['allocationGuids'].remove('root'),
        (v) => v['approval']['preservationFingerprint'] = 'secret',
        (v) => v['approval']['intent']['command'] = 'mkfs.btrfs',
        (v) => v['approval']['intent']['esp'] = null,
      ]) {
        final v = fixtures()[3];
        mutate(v);
        expect(() => approved(v), throwsFormatException);
      }
      final noNew = fixtures()[0];
      noNew['approval']['allocationGuids']['root'] =
          '77777777-7777-7777-7777-777777777777';
      expect(() => approved(noNew), throwsFormatException);
    },
  );
  test(
    'a different valid extent cannot replace an already captured approval',
    () {
      final original = approved(fixtures()[3]);
      final other = fixtures()[3];
      other['approval']['intent']['root']['startSector'] += 2048;
      final changed = approved(other);
      expect(
        original.matchesState({
          'selectedDisk': '/dev/vda',
          'partitionMethod': 'manual',
          'fileSystem': 'btrfs',
          '_approvedManualPlan': changed.json,
        }),
        false,
      );
      expect(
        () => changed.verifyCreated(
          GptDiskSnapshot.fromJson(other['created']['snapshot']),
          other['created']['preservationFingerprint'],
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'every existing GPT entry is preserved, even root selected for formatting',
    () {
      for (final index in [0, 1, 2, 3]) {
        for (final field in ['startSector', 'partitionGuid', 'attributesHex']) {
          final v = fixtures()[index], plan = approved(fixtures()[index]);
          final old = v['created']['snapshot']['partitions'].firstWhere(
            (p) => p['number'] == 2,
          );
          if (field == 'startSector') old[field] += 2048;
          if (field == 'partitionGuid') {
            old[field] = '77777777-7777-7777-7777-777777777777';
          }
          if (field == 'attributesHex') old[field] = '0000000000000001';
          expect(
            () => plan.verifyCreated(
              GptDiskSnapshot.fromJson(v['created']['snapshot']),
              v['created']['preservationFingerprint'],
            ),
            throwsFormatException,
          );
        }
      }
    },
  );
  test(
    'new slots require allocated GUID, range, type, attributes and exact inventory',
    () {
      for (final mutate in <void Function(Map<String, dynamic>)>[
        (p) => p['partitionGuid'] = '77777777-7777-7777-7777-777777777777',
        (p) => p['startSector'] += 2048,
        (p) => p['typeGuid'] = 'ebd0a0a2-b9e5-4433-87c0-68b6b72699c7',
        (p) => p['attributesHex'] = '0000000000000001',
      ]) {
        final v = fixtures()[3], plan = approved(fixtures()[3]);
        mutate(
          v['created']['snapshot']['partitions'].firstWhere(
            (p) => p['number'] == 3,
          ),
        );
        expect(
          () => plan.verifyCreated(
            GptDiskSnapshot.fromJson(v['created']['snapshot']),
            v['created']['preservationFingerprint'],
          ),
          throwsFormatException,
        );
      }
      final v = fixtures()[3], plan = approved(fixtures()[3]);
      v['created']['snapshot']['partitions'].removeWhere(
        (p) => p['number'] == 4,
      );
      expect(
        () => plan.verifyCreated(
          GptDiskSnapshot.fromJson(v['created']['snapshot']),
          v['created']['preservationFingerprint'],
        ),
        throwsFormatException,
      );
      expect(
        () => plan.verifyCreated(
          GptDiskSnapshot.fromJson(fixtures()[3]['created']['snapshot']),
          'b' * 64,
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'private facts and resolved layout remain immutable after exported-map mutation',
    () {
      final v = fixtures()[3], plan = approved(fixtures()[3]);
      final expected = plan.approval;
      v['snapshot']['partitions'].clear();
      plan.json['snapshot']['partitions'].clear();
      plan.approval['allocationGuids'].clear();
      plan.approval['intent']['root']['number'] = 7;
      expect(() => plan.newSlots.clear(), throwsUnsupportedError);
      expect(() => plan.allocationGuids.clear(), throwsUnsupportedError);
      expect(plan.approval, expected);
    },
  );
  test(
    'state copy deletion or mode downgrade invalidates the captured private plan',
    () {
      final plan = approved(fixtures()[0]);
      Map<String, dynamic> state() => {
        'selectedDisk': '/dev/vda',
        'partitionMethod': 'manual',
        'fileSystem': 'btrfs',
        '_approvedManualPlan': plan.json,
      };
      expect(plan.matchesState(state()), true);
      for (final mutate in <void Function(Map<String, dynamic>)>[
        (v) => v.remove('_approvedManualPlan'),
        (v) => v['partitionMethod'] = 'full',
        (v) => v['partitionMethod'] = 'free_space',
        (v) => v['selectedDisk'] = '/dev/vdb',
        (v) => v['fileSystem'] = 'ext4',
        (v) =>
            v['_approvedManualPlan']['approval']['intent']['esp']['formatOnInstall'] =
                true,
      ]) {
        final data = state();
        mutate(data);
        expect(plan.matchesState(data), false);
      }
    },
  );
  test('private manual facts do not bypass platform admission', () async {
    final plan = approved(fixtures()[0]);
    final runner = FakeCommandRunner(defaultSuccess: false)
      ..addResponse('uname', ['-m'], stdout: 'aarch64')
      ..addResponse('test', ['-d', '/sys/firmware/efi']);
    final service = InstallService(commandRunner: runner);
    expect(
      await service.runInstall(
        {
          'selectedDisk': '/dev/vda',
          'partitionMethod': 'manual',
          'fileSystem': 'btrfs',
          '_approvedManualPlan': plan.json,
        },
        (_, _) {},
        (_) {},
      ),
      false,
    );
    expect(service.lastOutcome!.primaryFailure, 'UNSUPPORTED_PLATFORM');
    expect(
      runner.commandLog.where(
        (c) =>
            c.command.startsWith('mkfs.') ||
            const ['sfdisk', 'sgdisk', 'wipefs', 'mount'].contains(c.command),
      ),
      isEmpty,
    );
  });
}
