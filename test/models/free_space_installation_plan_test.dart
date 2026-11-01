import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:ro_installer/models/gpt_disk_snapshot.dart';
import 'package:ro_installer/models/free_space_installation_plan.dart';
import 'package:ro_installer/models/standard_storage_layout.dart';
import 'package:ro_installer/services/fake_command_runner.dart';
import 'package:ro_installer/services/install_service.dart';

const gib = 1024 * 1024 * 1024, mib = 1024 * 1024;
Map<String, dynamic> fixture({int sector = 512}) {
  final v =
      jsonDecode(
            File('test/fixtures/gpt_disk_snapshot_v1.json').readAsStringSync(),
          )
          as Map<String, dynamic>;
  if (sector != 512) {
    for (final part in v['partitions']) {
      part['startSector'] = part['startSector'] * 512 ~/ sector;
      part['endSector'] = (part['endSector'] + 1) * 512 ~/ sector - 1;
    }
    final reserved = (v['entryCount'] * v['entryBytes'] + sector - 1) ~/ sector;
    final total = v['device']['size'] ~/ sector;
    v['logicalSectorBytes'] = sector;
    v['firstUsableSector'] = mib ~/ sector;
    v['lastUsableSector'] = total - reserved - 2;
    v['backupEntriesLba'] = total - reserved - 1;
  }
  return v;
}

GptDiskSnapshot snapshot({int sector = 512}) =>
    GptDiskSnapshot.fromJson(fixture(sector: sector));
FreeSectorExtent middle(GptDiskSnapshot s) => s.freeExtents.singleWhere(
  (e) => e.startSector == 80 * gib ~/ s.logicalSectorBytes,
);

void main() {
  test('empty GPT and fragmented GPT expose only maximal usable gaps', () {
    final empty = fixture();
    empty['partitions'] = <dynamic>[];
    final s = GptDiskSnapshot.fromJson(empty);
    expect(s.freeExtents.single.json, {
      'startSector': s.firstUsableSector,
      'endSector': s.lastUsableSector,
    });
    final p = FreeSpaceInstallationPlan.build(s, s.freeExtents.single);
    expect(p.espNumber, 1);
    expect(p.rootNumber, 2);
    final fragmented = fixture();
    fragmented['partitions'][1]['startSector'] += 1;
    final other = GptDiskSnapshot.fromJson(fragmented);
    final tiny = other.freeExtents.first;
    expect(tiny.startSector, tiny.endSector);
    expect(
      () => FreeSpaceInstallationPlan.build(other, tiny),
      throwsFormatException,
    );
  });
  for (final sector in [512, 4096]) {
    test(
      '$sector-byte sectors: deterministic private ESP/root, preserving every existing entry',
      () {
        final s = snapshot(sector: sector);
        final extent = middle(s);
        final plan = FreeSpaceInstallationPlan.build(s, extent);
        expect(plan.espNumber, 3);
        expect(plan.rootNumber, 4);
        expect(
          (plan.espEnd - plan.espStart + 1) * sector,
          StandardStorageLayout.espBytes,
        );
        expect(
          (plan.rootEnd - plan.rootStart + 1) * sector,
          greaterThanOrEqualTo(StandardStorageLayout.temporaryMinimumRootBytes),
        );
        expect(plan.espStart * sector % mib, 0);
        expect(plan.rootStart * sector % mib, 0);
        expect((plan.rootEnd + 1) * sector % mib, 0);
        expect(plan.espStart, greaterThanOrEqualTo(extent.startSector));
        expect(plan.rootEnd, lessThanOrEqualTo(extent.endSector));
        expect(plan.json['preservedPartitions'], s.json['partitions']);
        expect(plan.json['diskSwap'], false);
        final ops = plan.json['operations'] as List;
        expect(ops.map((o) => o['type']).toList(), [
          'create_efi',
          'create_btrfs_root',
          'format_efi',
          'format_btrfs_root',
        ]);
        expect(ops.map((o) => o['target']).toSet(), {'/dev/vda3', '/dev/vda4'});
        expect(s.partitions.first.attributesHex, '8000000000000000');
        for (final p in s.partitions) {
          expect(
            plan.espEnd < p.startSector || plan.espStart > p.endSector,
            true,
          );
          expect(
            plan.rootEnd < p.startSector || plan.rootStart > p.endSector,
            true,
          );
        }
      },
    );
  }
  test(
    'snapshot normalizes inventory order and GUID casing without hiding changes',
    () {
      final v = fixture();
      v['partitions'] = (v['partitions'] as List).reversed.toList();
      v['diskGuid'] = (v['diskGuid'] as String).toUpperCase();
      expect(GptDiskSnapshot.fromJson(v).sameAs(snapshot()), true);
      final nvme = fixture();
      nvme['device']['path'] = '/dev/nvme0n1';
      nvme['device']['majorMinor'] = '259:0';
      final s = GptDiskSnapshot.fromJson(nvme);
      final plan = FreeSpaceInstallationPlan.build(s, middle(s));
      expect(
        (plan.json['operations'] as List).first['target'],
        '/dev/nvme0n1p3',
      );
    },
  );
  test(
    'defensive copies and unmodifiable inventory keep accepted plans immutable',
    () {
      final input = fixture();
      final s = GptDiskSnapshot.fromJson(input);
      final plan = FreeSpaceInstallationPlan.build(s, middle(s));
      final original = jsonEncode(plan.json);
      input['device']['size'] = 1;
      input['partitions'].clear();
      final exported = plan.json;
      exported['snapshot']['device']['diskSequence'] = 1;
      exported['preservedPartitions'].clear();
      exported['operations'][0]['startSector'] = 1;
      expect(jsonEncode(plan.json), original);
      expect(() => s.partitions.clear(), throwsUnsupportedError);
      expect(() => s.freeExtents.clear(), throwsUnsupportedError);
    },
  );
  test(
    'unknown fields, booleans, floats, impossible numbers and metadata overlaps reject',
    () {
      for (final mutate in <void Function(Map<String, dynamic>)>[
        (v) => v['schemaVersion'] = true,
        (v) => v['schemaVersion'] = 1.0,
        (v) => v.remove('diskGuid'),
        (v) => v['path'] = '/tmp/raw',
        (v) => v['logicalSectorBytes'] = 1024,
        (v) => v['logicalSectorBytes'] = true,
        (v) => v['device']['size'] = v['device']['size'] + 1,
        (v) => v['device']['size'] = maximumSnapshotBytes + 1,
        (v) => v['entryCount'] = 4097,
        (v) => v['entryBytes'] = 129,
        (v) => v['firstUsableSector'] = 0,
        (v) => v['lastUsableSector'] = v['device']['size'] ~/ 512 - 1,
        (v) => v['primaryEntriesLba'] = v['firstUsableSector'],
        (v) => v['backupEntriesLba'] = v['lastUsableSector'],
        (v) => v['backupEntriesLba'] = v['device']['size'] ~/ 512 - 2,
        (v) => v['tableFingerprint'] = 'secret',
        (v) => v['diskGuid'] = '00000000-0000-0000-0000-000000000000',
        (v) => v['partitions'][0]['startSector'] = true,
        (v) => v['partitions'][0]['endSector'] = 0,
        (v) => v['partitions'][0]['number'] = 0,
        (v) => v['partitions'][0]['number'] = 129,
        (v) => v['partitions'][0]['partitionGuid'] = 'not-a-guid',
        (v) => v['partitions'][0]['attributesHex'] = 0,
        (v) => v['partitions'][0]['name'] = 'raw user data',
      ]) {
        final v = fixture();
        mutate(v);
        expect(() => GptDiskSnapshot.fromJson(v), throwsFormatException);
      }
    },
  );
  test(
    'overlapping, duplicated, out-of-range and over-capacity partitions reject',
    () {
      for (final mutate in <void Function(Map<String, dynamic>)>[
        (v) =>
            v['partitions'][1]['startSector'] = v['partitions'][0]['endSector'],
        (v) => v['partitions'][1]['number'] = v['partitions'][0]['number'],
        (v) => v['partitions'][1]['partitionGuid'] =
            v['partitions'][0]['partitionGuid'],
        (v) => v['partitions'][0]['partitionGuid'] = v['diskGuid'],
        (v) => v['partitions'][0]['startSector'] = v['firstUsableSector'] - 1,
        (v) => v['partitions'][2]['endSector'] = v['lastUsableSector'] + 1,
        (v) => v['partitions'] = List.filled(129, v['partitions'][0]),
      ]) {
        final v = fixture();
        mutate(v);
        expect(() => GptDiskSnapshot.fromJson(v), throwsFormatException);
      }
    },
  );
  test(
    'only a current maximal gap can be selected; no occupied or metadata ranges',
    () {
      final s = snapshot();
      final gap = middle(s);
      for (final extent in [
        FreeSectorExtent(-1, gap.endSector),
        FreeSectorExtent(gap.startSector + 1, gap.endSector),
        FreeSectorExtent(gap.startSector, gap.endSector - 1),
        FreeSectorExtent(0, s.lastUsableSector),
        FreeSectorExtent(s.partitions[1].startSector, gap.endSector),
      ]) {
        expect(
          () => FreeSpaceInstallationPlan.build(s, extent),
          throwsFormatException,
        );
      }
    },
  );
  test('alignment overhead is included in the root safety floor', () {
    final exact = fixture();
    exact['partitions'][2]['startSector'] = (120 * gib + 512 * mib) ~/ 512;
    final s = GptDiskSnapshot.fromJson(exact);
    final plan = FreeSpaceInstallationPlan.build(s, middle(s));
    expect(
      (plan.rootEnd - plan.rootStart + 1) * 512,
      StandardStorageLayout.temporaryMinimumRootBytes,
    );
    final misaligned = fixture();
    misaligned['partitions'][1]['endSector'] = 80 * gib ~/ 512;
    misaligned['partitions'][2]['startSector'] =
        (120 * gib + 512 * mib + mib) ~/ 512 - 1;
    final other = GptDiskSnapshot.fromJson(misaligned);
    final gap = other.freeExtents.first;
    expect(
      (gap.endSector - gap.startSector + 1) * 512,
      greaterThanOrEqualTo(
        StandardStorageLayout.espBytes +
            StandardStorageLayout.temporaryMinimumRootBytes,
      ),
    );
    expect(
      () => FreeSpaceInstallationPlan.build(other, gap),
      throwsFormatException,
    );
  });
  test(
    'entry capacity is explicit; slot shortage never reuses an existing partition',
    () {
      final v = fixture();
      v['entryCount'] = 3;
      v['partitions'].removeLast();
      final s = GptDiskSnapshot.fromJson(v);
      expect(
        () => FreeSpaceInstallationPlan.build(s, s.freeExtents.first),
        throwsFormatException,
      );
    },
  );
  test('minimum GPT array reservation remains 16KiB even with few entries', () {
    final v = fixture();
    v['entryCount'] = 3;
    v['partitions'].removeLast();
    v['firstUsableSector'] = 3;
    expect(() => GptDiskSnapshot.fromJson(v), throwsFormatException);
  });
  test(
    'device sequence, table fingerprint, GUID and geometry changes invalidate a plan',
    () {
      final s = snapshot();
      final plan = FreeSpaceInstallationPlan.build(s, middle(s));
      expect(plan.matchesSnapshot(GptDiskSnapshot.fromJson(fixture())), true);
      for (final mutate in <void Function(Map<String, dynamic>)>[
        (v) => v['device']['diskSequence'] = 12,
        (v) => v['tableFingerprint'] = 'b' * 64,
        (v) => v['partitions'][1]['partitionGuid'] =
            '55555555-5555-5555-5555-555555555555',
        (v) => v['partitions'][1]['startSector'] =
            v['partitions'][1]['startSector'] + 1,
        (v) => v['partitions'][0]['attributesHex'] = '0000000000000000',
      ]) {
        final v = fixture();
        mutate(v);
        expect(plan.matchesSnapshot(GptDiskSnapshot.fromJson(v)), false);
      }
    },
  );
  test(
    'a proposed plan does not authorize the existing full-only engine',
    () async {
      final s = snapshot();
      final plan = FreeSpaceInstallationPlan.build(s, middle(s));
      final runner = FakeCommandRunner();
      final engine = InstallService(commandRunner: runner);
      expect(
        await engine.runInstall(
          {
            'selectedDisk': s.device.path,
            'partitionMethod': 'free_space',
            'fileSystem': 'btrfs',
            'proposedPlan': plan.json,
          },
          (_, _) {},
          (_) {},
          isMock: true,
        ),
        false,
      );
      expect(runner.commandLog, isEmpty);
      expect(engine.lastOutcome!.primaryFailure, 'UNSUPPORTED_MODE');
    },
  );
}
