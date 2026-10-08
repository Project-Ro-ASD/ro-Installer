import 'dart:convert';
import 'package:test/test.dart';
import 'package:ro_installer/services/disk_discovery.dart';
import 'package:ro_installer/services/fake_command_runner.dart';

Map<String, dynamic> disk({
  String name = 'vda',
  Object? model,
  Object? children,
  bool includeChildren = false,
}) => {
  'name': name,
  'type': 'disk',
  'size': 68719476736,
  'model': model,
  'rm': false,
  'mountpoints': [null],
  if (includeChildren) 'children': children,
};
void main() {
  for (final model in [null, '']) {
    for (final hasChildren in [false, true]) {
      test('blank virtio model=$model children-present=$hasChildren', () async {
        final runner = FakeCommandRunner();
        runner.addResponseForCommand(
          'lsblk',
          stdout: jsonEncode({
            'blockdevices': [
              disk(model: model, includeChildren: hasChildren, children: []),
            ],
          }),
        );
        final result = await discoverDisks(runner);
        expect(result.succeeded, true);
        expect(result.disks.single['name'], '/dev/vda');
        expect(result.disks.single['size'], 68719476736);
        expect(result.disks.single['model'], 'vda');
        expect(result.disks.single['isLive'], false);
        expect(runner.commandNames, ['lsblk']);
      });
    }
  }
  test('valid empty discovery has no error', () async {
    final runner = FakeCommandRunner();
    runner.addResponseForCommand('lsblk', stdout: '{"blockdevices":[]}');
    final result = await discoverDisks(runner);
    expect(result.error, isNull);
    expect(result.disks, isEmpty);
  });
  test(
    'null children and malformed entry preserve independent valid disk visibly',
    () async {
      final runner = FakeCommandRunner();
      runner.addResponseForCommand(
        'lsblk',
        stdout: jsonEncode({
          'blockdevices': [
            disk(),
            disk(name: 'sda', includeChildren: true, children: null),
            {'bad': 'entry'},
          ],
        }),
      );
      final result = await discoverDisks(runner);
      expect(result.disks.single['name'], '/dev/vda');
      expect(result.rejectedEntries, 2);
      expect(result.succeeded, true);
    },
  );
  test('only malformed topology is an error rather than no disk', () async {
    final runner = FakeCommandRunner();
    runner.addResponseForCommand(
      'lsblk',
      stdout: jsonEncode({
        'blockdevices': [disk(includeChildren: true, children: null)],
      }),
    );
    expect((await discoverDisks(runner)).error, DiskDiscoveryError.topology);
  });
  test('start, nonzero, timeout and incompatible JSON are distinct', () async {
    for (final error in [
      DiskDiscoveryError.startFailed,
      DiskDiscoveryError.commandFailed,
      DiskDiscoveryError.timeout,
      DiskDiscoveryError.incompatibleJson,
    ]) {
      final runner = FakeCommandRunner();
      runner.addResponseForCommand(
        'lsblk',
        started: error != DiskDiscoveryError.startFailed,
        exitCode: error == DiskDiscoveryError.timeout
            ? -124
            : error == DiskDiscoveryError.commandFailed
            ? 1
            : 0,
        stdout: 'not json',
        stderr: 'password secret',
      );
      final result = await discoverDisks(runner);
      expect(result.error, error);
      expect(result.toString(), isNot(contains('secret')));
    }
  });
  test(
    'all nested root/live mounts are marked and duplicates fail closed',
    () async {
      final runner = FakeCommandRunner();
      runner.addResponseForCommand(
        'lsblk',
        stdout: jsonEncode({
          'blockdevices': [
            {
              ...disk(),
              'mountpoints': ['/'],
            },
            disk(
              name: 'sdb',
              includeChildren: true,
              children: [
                {
                  'name': 'sdb1',
                  'type': 'part',
                  'mountpoints': ['/run/initramfs/live'],
                },
              ],
            ),
          ],
        }),
      );
      final result = await discoverDisks(runner);
      expect(result.disks.first['isHostOS'], true);
      expect(result.disks.last['isLive'], true);
      runner.addResponseForCommand(
        'lsblk',
        stdout: jsonEncode({
          'blockdevices': [disk(), disk()],
        }),
      );
      expect((await discoverDisks(runner)).error, DiskDiscoveryError.topology);
    },
  );
}
