import 'package:test/test.dart';
import 'package:ro_installer/services/fake_command_runner.dart';
import 'package:ro_installer/services/install_stages/disk_preparation_stage.dart';
import 'package:ro_installer/services/install_stages/stage_context.dart';

/// Test için StageContext oluşturur.
StageContext makeContext(
  Map<String, dynamic> state,
  FakeCommandRunner runner, {
  bool isMock = false,
}) {
  return StageContext(
    state: state,
    log: (msg) {}, // Sessiz log
    onProgress: (p, s) {},
    commandRunner: runner,
    runCmd:
        (
          cmd,
          args,
          onLog, {
          bool isMock = false,
          List<int> allowedExitCodes = const [0],
        }) async {
          final result = await runner.run(cmd, args);
          return allowedExitCodes.contains(result.exitCode);
        },
    isMock: isMock,
  );
}

void main() {
  group('DiskPreparationStage', () {
    test(
      'mounted targets are refused without unmounting or global swapoff',
      () async {
        final fake = FakeCommandRunner(defaultSuccess: false);
        fake.addResponse(
          'lsblk',
          ['-J', '-o', 'NAME,TYPE,MOUNTPOINTS', '/dev/sda'],
          stdout: '''
{
  "blockdevices": [
    {
      "name": "sda",
      "type": "disk",
      "mountpoints": [null],
      "children": [
        {"name": "sda1", "type": "part", "mountpoints": ["/mnt/boot/efi"]},
        {"name": "sda2", "type": "part", "mountpoints": [null]},
        {"name": "sda3", "type": "part", "mountpoints": ["/mnt"]}
      ]
    }
  ]
}
''',
        );
        final result = await const DiskPreparationStage().execute(
          makeContext({'selectedDisk': '/dev/sda'}, fake),
        );
        expect(result.success, isFalse);
        expect(fake.commandNames, ['lsblk']);
      },
    );

    test('inactive target never disables system swap/ZRAM', () async {
      final fake = FakeCommandRunner(defaultSuccess: false);
      fake.addResponse(
        'lsblk',
        ['-J', '-o', 'NAME,TYPE,MOUNTPOINTS', '/dev/sda'],
        stdout: '''
{
  "blockdevices": [
    {
      "name": "sda",
      "type": "disk",
      "mountpoints": [null],
      "children": [
        {"name": "sda1", "type": "part", "mountpoints": [null]}
      ]
    }
  ]
}
''',
      );
      fake.addResponse('swapoff', ['-a']);

      final ctx = makeContext({'selectedDisk': '/dev/sda'}, fake);
      final result = await const DiskPreparationStage().execute(ctx);

      expect(result.success, true);
      expect(fake.commandNames, ['lsblk']);
    });

    test('NVMe disk adıyla da çalışır', () async {
      final fake = FakeCommandRunner(defaultSuccess: false);
      fake.addResponse(
        'lsblk',
        ['-J', '-o', 'NAME,TYPE,MOUNTPOINTS', '/dev/nvme0n1'],
        stdout: '''
{
  "blockdevices": [
    {
      "name": "nvme0n1",
      "type": "disk",
      "mountpoints": [null],
      "children": [
        {"name": "nvme0n1p1", "type": "part", "mountpoints": ["/mnt/boot/efi"]}
      ]
    }
  ]
}
''',
      );
      fake.addResponse('umount', ['-f', '/dev/nvme0n1p1']);
      fake.addResponse('swapoff', ['-a']);
      final ctx = makeContext({'selectedDisk': '/dev/nvme0n1'}, fake);

      final stage = const DiskPreparationStage();
      final result = await stage.execute(ctx);

      expect(result.success, isFalse);
      expect(fake.commandNames, ['lsblk']);
    });
  });
}
