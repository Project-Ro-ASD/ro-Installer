import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:ro_installer/models/gpt_disk_snapshot.dart';
import 'package:ro_installer/models/manual_installation_plan.dart';
import 'package:ro_installer/models/standard_storage_layout.dart';
import 'package:ro_installer/services/fake_command_runner.dart';
import 'package:ro_installer/services/install_service.dart';

const gib = 1024 * 1024 * 1024;
Map<String, dynamic> fixture({int sector = 512}) {
  final v =
      jsonDecode(
            File(
              'test/fixtures/manual_installation_plan_v1.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  if (sector != 512) {
    final s = v['snapshot'];
    for (final part in s['partitions']) {
      part['startSector'] = part['startSector'] * 512 ~/ sector;
      part['endSector'] = (part['endSector'] + 1) * 512 ~/ sector - 1;
    }
    final total = s['device']['size'] ~/ sector;
    final reserved =
        ((s['entryCount'] * s['entryBytes']).clamp(16384, 4194304) +
            sector -
            1) ~/
        sector;
    s['logicalSectorBytes'] = sector;
    s['firstUsableSector'] = 1024 * 1024 ~/ sector;
    s['lastUsableSector'] = total - reserved - 2;
    s['backupEntriesLba'] = total - reserved - 1;
  }
  return v;
}

Map<String, dynamic> create(int startBytes, int endBytes, int sector) => {
  'source': 'create',
  'startSector': startBytes ~/ sector,
  'endSector': endBytes ~/ sector - 1,
};

void main() {
  for (final sector in [512, 4096]) {
    for (final newEsp in [false, true]) {
      for (final newRoot in [false, true]) {
        test(
          '$sector-byte sector: new ESP=$newEsp, new root=$newRoot preserve exact inventory',
          () {
            final v = fixture(sector: sector);
            if (newEsp) v['esp'] = create(80 * gib, 81 * gib, sector);
            if (newRoot) v['root'] = create(100 * gib, 150 * gib, sector);
            final plan = ManualInstallationPlan.fromJson(v);
            expect(plan.snapshot.json, v['snapshot']);
            expect(plan.esp.number, newEsp ? 3 : 1);
            expect(plan.root.number, newRoot ? (newEsp ? 4 : 3) : 2);
            expect(plan.esp.formatOnInstall, newEsp);
            expect(plan.root.formatOnInstall, true);
            expect(
              plan.operations.where(
                (o) => o.kind == ManualOperationKind.createPartition,
              ),
              hasLength((newEsp ? 1 : 0) + (newRoot ? 1 : 0)),
            );
            expect(
              plan.operations
                  .where((o) => o.kind == ManualOperationKind.formatPartition)
                  .map((o) => o.partition.target),
              [
                if (newEsp) '/dev/vda3',
                '/dev/vda${newRoot ? (newEsp ? 4 : 3) : 2}',
              ],
            );
            expect(plan.untouchedPartitions.map((p) => p.number), [
              if (newEsp) 1,
              if (newRoot) 2,
              7,
            ]);
            expect(
              plan.intentJson['subvolumes'],
              StandardStorageLayout.subvolumes,
            );
            expect(plan.intentJson['diskSwap'], false);
            expect(plan.intentJson['root']['fileSystem'], 'btrfs');
            expect(plan.intentJson['esp']['fileSystem'], 'fat32');
            expect(
              ManualInstallationPlan.fromJson(plan.json).intentJson,
              plan.intentJson,
            );
          },
        );
      }
    }
  }
  test('existing ESP reuse is distinct from formatting and untouched data', () {
    final plan = ManualInstallationPlan.fromJson(fixture());
    final reuse = plan.operations.singleWhere(
      (o) => o.kind == ManualOperationKind.reuseEsp,
    );
    expect(reuse.partition.target, '/dev/vda1');
    expect(reuse.destructive, false);
    expect(plan.untouchedPartitions.map((p) => p.number), [7]);
    expect(
      plan.operations.any((o) => o.partition.target == '/dev/vda7'),
      false,
    );
    expect(
      plan.esp.json['partitionGuid'],
      plan.snapshot.partitions.first.partitionGuid,
    );
    final formatted = fixture();
    formatted['esp']['formatOnInstall'] = true;
    final other = ManualInstallationPlan.fromJson(formatted);
    expect(other.operations.map((o) => o.kind), [
      ManualOperationKind.formatPartition,
      ManualOperationKind.formatPartition,
    ]);
    expect(other.operations.every((o) => o.destructive), true);
    expect(other.intentJson, isNot(equals(plan.intentJson)));
  });
  test(
    'normalized source, choices and all exported containers are defensive',
    () {
      final input = fixture();
      final plan = ManualInstallationPlan.fromJson(input);
      final expected = jsonEncode(plan.intentJson);
      input['root']['number'] = 7;
      input['snapshot']['partitions'].clear();
      plan.json['snapshot']['partitions'].clear();
      plan.json['esp']['formatOnInstall'] = true;
      plan.intentJson['subvolumes'].clear();
      plan.intentJson['root']['number'] = 7;
      plan.operations.first.json['partition']['number'] = 7;
      expect(() => plan.operations.clear(), throwsUnsupportedError);
      expect(() => plan.untouchedPartitions.clear(), throwsUnsupportedError);
      expect(() => plan.snapshot.partitions.clear(), throwsUnsupportedError);
      expect(jsonEncode(plan.intentJson), expected);
    },
  );
  test(
    'snapshot matching covers unselected partitions as well as selected roles',
    () {
      final plan = ManualInstallationPlan.fromJson(fixture());
      expect(
        plan.matchesSnapshot(GptDiskSnapshot.fromJson(fixture()['snapshot'])),
        true,
      );
      for (final mutate in <void Function(Map<String, dynamic>)>[
        (v) => v['tableFingerprint'] = 'b' * 64,
        (v) => v['device']['diskSequence'] = 12,
        (v) => v['device']['path'] = '/dev/vdb',
        (v) => v['device']['majorMinor'] = '252:16',
        (v) => v['partitions'][2]['partitionGuid'] =
            '55555555-5555-5555-5555-555555555555',
        (v) => v['partitions'][2]['startSector'] += 2048,
        (v) => v['partitions'][2]['attributesHex'] = '0000000000000001',
        (v) => v['partitions'][0]['number'] = 8,
      ]) {
        final current = fixture()['snapshot'] as Map<String, dynamic>;
        mutate(current);
        expect(plan.matchesSnapshot(GptDiskSnapshot.fromJson(current)), false);
      }
    },
  );
  test(
    'strict schema rejects legacy maps, overrides, ambiguous types and unsupported roles',
    () {
      for (final mutate in <void Function(Map<String, dynamic>)>[
        (v) => v['schemaVersion'] = true,
        (v) => v['schemaVersion'] = 1.0,
        (v) => v['mode'] = 'full',
        (v) => v.remove('root'),
        (v) => v['diskSwap'] = true,
        (v) => v['operations'] = [],
        (v) => v['manualPartitions'] = [],
        (v) => v['home'] = {'number': 7},
        (v) => v['deletedPartitionNames'] = ['/dev/vda7'],
        (v) => v['root']['formatOnInstall'] = false,
        (v) => v['root']['formatOnInstall'] = 1,
        (v) => v['root'].remove('formatOnInstall'),
        (v) => v['root']['number'] = true,
        (v) => v['root']['number'] = 2.0,
        (v) => v['root']['number'] = 0,
        (v) => v['root']['number'] = 3,
        (v) => v['root']['number'] = 7,
        (v) => v['root']['source'] = 'resize',
        (v) => v['root']['path'] = '/dev/vdb2',
        (v) => v['root']['mountPoint'] = '/home',
        (v) => v['root']['fileSystem'] = 'ext4',
        (v) =>
            v['root']['partitionGuid'] = '55555555-5555-5555-5555-555555555555',
        (v) => v['esp']['number'] = 2,
        (v) => v['esp'] = {
          'source': 'create',
          'startSector': true,
          'endSector': 999999999,
        },
        (v) => v['esp'] = {
          ...create(80 * gib, 81 * gib, 512),
          'formatOnInstall': false,
        },
        (v) => v['snapshot']['partitions'][0]['attributesHex'] =
            '8000000000000000',
        (v) => v['snapshot']['partitions'][1]['attributesHex'] =
            '1000000000000000',
        (v) => v['snapshot']['partitions'][0]['endSector'] -= 1,
        (v) => v['snapshot']['partitions'][1]['endSector'] = 10000000,
      ]) {
        final v = fixture();
        mutate(v);
        expect(
          () => ManualInstallationPlan.fromJson(v),
          throwsFormatException,
          reason: jsonEncode(v),
        );
      }
    },
  );
  for (final sector in [512, 4096]) {
    test(
      '$sector-byte sector: rejects overlap, metadata, alignment, gaps and undersized root',
      () {
        for (final mutate in <void Function(Map<String, dynamic>)>[
          (v) => v['root'] = create(79 * gib, 130 * gib, sector),
          (v) => v['root'] = create(150 * gib, 200 * gib, sector),
          (v) => v['root'] = create(80 * gib, 119 * gib, sector),
          (v) => v['root'] = {
            'source': 'create',
            'startSector': 80 * gib ~/ sector + 1,
            'endSector': 150 * gib ~/ sector - 1,
          },
          (v) => v['root'] = {
            'source': 'create',
            'startSector': 80 * gib ~/ sector,
            'endSector': 150 * gib ~/ sector - 2,
          },
          (v) => v['root'] = {
            'source': 'create',
            'startSector': -1,
            'endSector': 0,
          },
          (v) => v['root'] = {
            'source': 'create',
            'startSector': 0,
            'endSector': 100 * gib ~/ sector,
          },
          (v) => v['root'] = {
            'source': 'create',
            'startSector': 80 * gib ~/ sector,
            'endSector': maximumSnapshotBytes + 1,
          },
          (v) => v['root'] = {
            'source': 'create',
            'startSector': 80 * gib ~/ sector,
            'endSector': 79 * gib ~/ sector,
          },
          (v) =>
              v['esp'] = create(80 * gib, 80 * gib + 256 * 1024 * 1024, sector),
          (v) {
            v['esp'] = create(90 * gib, 91 * gib, sector);
            v['root'] = create(80 * gib, 150 * gib, sector);
          },
        ]) {
          final v = fixture(sector: sector);
          mutate(v);
          expect(
            () => ManualInstallationPlan.fromJson(v),
            throwsFormatException,
          );
        }
      },
    );
    test(
      '$sector-byte sector: accepts adjacent exact-size partitions in empty GPT',
      () {
        final v = fixture(sector: sector);
        v['snapshot']['partitions'] = <dynamic>[];
        v['esp'] = create(1024 * 1024, 513 * 1024 * 1024, sector);
        v['root'] = create(
          513 * 1024 * 1024,
          513 * 1024 * 1024 + 40 * gib,
          sector,
        );
        final plan = ManualInstallationPlan.fromJson(v);
        expect(plan.esp.number, 1);
        expect(plan.root.number, 2);
        expect(plan.esp.endSector + 1, plan.root.startSector);
        expect(plan.untouchedPartitions, isEmpty);
      },
    );
  }
  test(
    'new partitions may occupy separate gaps, never merge across existing data',
    () {
      final v = fixture();
      v['esp'] = create(180 * gib, 181 * gib, 512);
      v['root'] = create(100 * gib, 150 * gib, 512);
      final plan = ManualInstallationPlan.fromJson(v);
      expect(plan.esp.number, 3);
      expect(plan.root.number, 4);
      expect(plan.esp.startSector, greaterThan(plan.root.endSector));
      expect(plan.untouchedPartitions, hasLength(3));
    },
  );
  test('GPT slot exhaustion rejects before creating a partial plan', () {
    final v = fixture();
    v['snapshot']['entryCount'] = 3;
    v['snapshot']['partitions'][2]['number'] = 3;
    v['root'] = create(100 * gib, 150 * gib, 512);
    expect(() => ManualInstallationPlan.fromJson(v), throwsFormatException);
  });
  test('probe inventory limit covers the post-create inventory', () {
    final v = fixture();
    final parts = v['snapshot']['partitions'] as List;
    for (var n = 8; n <= 36; n++) {
      final start = (180 + n - 8) * gib ~/ 512;
      parts.add({
        'number': n,
        'startSector': start,
        'endSector': start + 2047,
        'typeGuid': ManualInstallationPlan.rootTypeGuid,
        'partitionGuid':
            '55555555-5555-5555-5555-${n.toRadixString(16).padLeft(12, '0')}',
        'attributesHex': '0000000000000000',
      });
    }
    expect(parts, hasLength(32));
    expect(
      ManualInstallationPlan.fromJson(v).untouchedPartitions,
      hasLength(30),
    );
    v['root'] = create(100 * gib, 150 * gib, 512);
    expect(() => ManualInstallationPlan.fromJson(v), throwsFormatException);
    parts.removeLast();
    expect(ManualInstallationPlan.fromJson(v).root.number, 3);
    v['esp'] = create(80 * gib, 81 * gib, 512);
    expect(() => ManualInstallationPlan.fromJson(v), throwsFormatException);
  });
  test('targets derive only from canonical parent paths', () {
    for (final disk in ['/dev/vda', '/dev/nvme0n1', '/dev/mmcblk0']) {
      final v = fixture();
      v['snapshot']['device']['path'] = disk;
      final plan = ManualInstallationPlan.fromJson(v);
      expect(plan.root.target, '$disk${disk == '/dev/vda' ? '' : 'p'}2');
    }
  });
  test(
    'a valid planner cannot authorize the production manual engine',
    () async {
      final plan = ManualInstallationPlan.fromJson(fixture());
      final runner = FakeCommandRunner(defaultSuccess: false);
      final data = <String, dynamic>{
        'selectedDisk': '/dev/vda',
        'partitionMethod': 'manual',
        'fileSystem': 'btrfs',
        '_manualInstallationPlan': plan.json,
      };
      final engine = InstallService(commandRunner: runner);
      expect(await engine.runInstall(data, (_, _) {}, (_) {}), false);
      expect(engine.lastOutcome!.primaryFailure, 'UNSUPPORTED_MODE');
      expect(runner.commandLog, isEmpty);
    },
  );
}
