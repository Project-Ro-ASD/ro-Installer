import 'dart:convert';
import 'package:test/test.dart';
import 'package:ro_installer/models/gpt_disk_snapshot.dart';
import 'package:ro_installer/models/ntfs_shrink_installation_plan.dart';
import 'package:ro_installer/services/install_service.dart';
import 'package:ro_installer/services/fake_command_runner.dart';

const gib = 1024 * 1024 * 1024;
Map<String, dynamic> snapshotJson([int sector = 512]) {
  final total = 256 * gib ~/ sector, reserved = 16384 ~/ sector;
  Map<String, dynamic> part(
    int n,
    int start,
    int end,
    String type,
    String digit,
  ) => {
    'number': n,
    'startSector': start ~/ sector,
    'endSector': end ~/ sector - 1,
    'typeGuid': type,
    'partitionGuid':
        '$digit$digit$digit$digit$digit$digit$digit$digit-$digit$digit$digit$digit-$digit$digit$digit$digit-$digit$digit$digit$digit-$digit$digit$digit$digit$digit$digit$digit$digit$digit$digit$digit$digit',
    'attributesHex': '0000000000000000',
  };
  return {
    'schemaVersion': 1,
    'device': {
      'path': '/dev/nvme0n1',
      'majorMinor': '259:0',
      'size': 256 * gib,
      'diskSequence': 11,
    },
    'logicalSectorBytes': sector,
    'firstUsableSector': 1048576 ~/ sector,
    'lastUsableSector': total - reserved - 2,
    'entryCount': 128,
    'entryBytes': 128,
    'primaryEntriesLba': 2,
    'backupEntriesLba': total - reserved - 1,
    'diskGuid': '11111111-1111-1111-1111-111111111111',
    'tableFingerprint': 'a' * 64,
    'partitions': [
      part(
        1,
        1048576,
        513 * 1048576,
        'c12a7328-f81f-11d2-ba4b-00a0c93ec93b',
        '2',
      ),
      part(
        2,
        gib,
        160 * gib,
        NtfsShrinkInstallationPlan.basicDataTypeGuid,
        '3',
      ),
      part(
        7,
        200 * gib,
        210 * gib,
        'de94bba4-06d1-4d40-a16a-bfd50179d6ac',
        '4',
      ),
    ],
  };
}

NtfsShrinkInstallationPlan plan({
  Map<String, dynamic>? snapshot,
  int rootBytes = 64 * gib,
  int minimum = 50 * gib,
  int source = 2,
  int esp = 1,
}) => NtfsShrinkInstallationPlan.build(
  snapshot: GptDiskSnapshot.fromJson(snapshot ?? snapshotJson()),
  sourceNumber: source,
  espNumber: esp,
  rootBytes: rootBytes,
  minimumFilesystemBytes: minimum,
);
void main() {
  for (final sector in [512, 4096]) {
    test(
      '$sector-byte sectors shrink only the selected tail and preserve recovery',
      () {
        final p = plan(snapshot: snapshotJson(sector));
        expect(p.rootNumber, 3);
        expect(p.rootStart * sector, 136 * gib);
        expect((p.rootEnd + 1) * sector, 200 * gib);
        expect((p.sourceEnd + 1) * sector, 136 * gib);
        expect(p.retainedSourceBytes, 135 * gib);
        expect(p.shrinkBytes, 24 * gib);
        expect(p.rootEnd, p.snapshot.partitions.last.startSector - 1);
        expect(p.intentJson['esp']['formatOnInstall'], false);
        expect(p.intentJson['diskSwap'], false);
        expect(p.snapshot.partitions[1].endSector, 160 * gib ~/ sector - 1);
        expect(p.snapshot.tableFingerprint, 'a' * 64);
        expect(
          NtfsShrinkInstallationPlan.fromJson(p.json).intentJson,
          p.intentJson,
        );
      },
    );
  }
  test(
    'sufficient contiguous free space never authorizes an unnecessary shrink',
    () {
      expect(() => plan(rootBytes: 40 * gib), throwsFormatException);
      expect(() => plan(rootBytes: 41 * gib), returnsNormally);
    },
  );
  test('no following gap confines new root to the selected source', () {
    final s = snapshotJson();
    s['partitions'][2]['startSector'] = 160 * gib ~/ 512;
    final p = plan(snapshot: s);
    expect((p.rootEnd + 1) * 512, 160 * gib);
    expect(p.shrinkBytes, 64 * gib);
  });
  test('retained source floor and measured-minimum headroom are mandatory', () {
    for (final minimum in [0, -1, 159 * gib + 1, 135 * gib, 134 * gib + 1]) {
      expect(() => plan(minimum: minimum), throwsFormatException);
    }
    expect(() => plan(minimum: 134 * gib), returnsNormally);
    expect(() => plan(rootBytes: 160 * gib, minimum: 1), throwsFormatException);
    expect(() => plan(rootBytes: 200 * gib, minimum: 1), throwsFormatException);
  });
  test('root capacity and integer MiB geometry are bounded', () {
    for (final size in [-1, 0, 39 * gib, 64 * gib + 1, maximumSnapshotBytes]) {
      expect(() => plan(rootBytes: size), throwsFormatException);
    }
  });
  test(
    'only eligible distinct source and reusable ESP choices are admitted',
    () {
      for (final args in [(1, 1), (7, 1), (2, 2), (2, 7), (4, 1)]) {
        expect(
          () => plan(source: args.$1, esp: args.$2),
          throwsFormatException,
        );
      }
      for (final mutate in <void Function(Map<String, dynamic>)>[
        (s) => s['partitions'][1]['typeGuid'] =
            '0fc63daf-8483-4772-8e79-3d69d8477de4',
        (s) => s['partitions'][1]['attributesHex'] = '0000000000000001',
        (s) => s['partitions'][0]['attributesHex'] = '8000000000000000',
        (s) => s['partitions'][0]['endSector'] = 512 * 1048576 ~/ 512 - 1,
        (s) => s['partitions'][1]['startSector'] += 1,
      ]) {
        final s = snapshotJson();
        mutate(s);
        expect(() => plan(snapshot: s), throwsFormatException);
      }
    },
  );
  test('full GPT slots or probe inventories fail closed', () {
    final s = snapshotJson();
    s['entryCount'] = 3;
    s['partitions'][2]['number'] = 3;
    expect(() => plan(snapshot: s), throwsFormatException);
    final many = snapshotJson();
    for (var n = 8; n < 37; n++) {
      final p = Map<String, dynamic>.from(many['partitions'][2]);
      p['number'] = n;
      p['startSector'] = (211 + n - 8) * gib ~/ 512;
      p['endSector'] = p['startSector'] + gib ~/ 512 - 1;
      p['partitionGuid'] =
          '55555555-5555-5555-5555-${n.toString().padLeft(12, '0')}';
      many['partitions'].add(p);
    }
    expect(() => plan(snapshot: many), throwsFormatException);
  });
  test('exported maps cannot mutate captured GPT, geometry or policy', () {
    final input = snapshotJson();
    final p = plan(snapshot: input);
    final original = jsonEncode(p.intentJson);
    final export = p.json;
    export['snapshot']['partitions'][1]['endSector'] = 42;
    final intent = p.intentJson;
    intent['esp']['formatOnInstall'] = true;
    input['partitions'][1]['endSector'] = 42;
    expect(jsonEncode(p.intentJson), original);
    expect(p.matchesSnapshot(GptDiskSnapshot.fromJson(snapshotJson())), true);
    final changed = snapshotJson()..['tableFingerprint'] = 'b' * 64;
    expect(p.matchesSnapshot(GptDiskSnapshot.fromJson(changed)), false);
  });
  test(
    'strict input schema rejects bool integers and caller authority fields',
    () {
      for (final change in [
        {'schemaVersion': true},
        {'rootBytes': true},
        {'minimumFilesystemBytes': true},
        {'sourceNumber': true},
        {'espNumber': true},
        {'sourceEnd': 42},
        {'confirmedPlan': {}},
        {'commands': []},
        {'safeForWrite': true},
        {'formatEsp': true},
      ]) {
        expect(
          () =>
              NtfsShrinkInstallationPlan.fromJson({...plan().json, ...change}),
          throwsFormatException,
        );
      }
    },
  );
  test(
    'a pure shrink proposal cannot enable the dormant alongside executor',
    () async {
      final runner = FakeCommandRunner(defaultSuccess: false);
      final guarded = InstallService(commandRunner: runner);
      expect(
        await guarded.runInstall(
          {
            'selectedDisk': '/dev/nvme0n1',
            'fileSystem': 'btrfs',
            'partitionMethod': 'alongside',
            '_ntfsShrinkPlan': plan().json,
          },
          (_, _) {},
          (_) {},
        ),
        false,
      );
      expect(guarded.lastOutcome!.primaryFailure, 'UNSUPPORTED_MODE');
      expect(runner.commandLog, isEmpty);
    },
  );
}
