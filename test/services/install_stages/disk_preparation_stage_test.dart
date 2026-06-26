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
    test('mount edilmiş hedef partitionları tek tek ayırır', () async {
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
      fake.addResponse('umount', ['-f', '/dev/sda3']);
      fake.addResponse('umount', ['-f', '/dev/sda1']);
      fake.addResponse('swapoff', ['-a']);
      final ctx = makeContext({'selectedDisk': '/dev/sda'}, fake);

      final stage = const DiskPreparationStage();
      final result = await stage.execute(ctx);

      expect(result.success, true);
      expect(result.message, contains('sda'));

      expect(fake.commandNames, ['lsblk', 'umount', 'umount', 'swapoff']);
      expect(fake.wasCalledWith('umount', ['-f', '/dev/sda3']), true);
      expect(fake.wasCalledWith('umount', ['-f', '/dev/sda1']), true);
      expect(fake.commandLog.any((cmd) => cmd.command == 'sh'), false);
    });

    test('mount yoksa sadece lsblk ve swapoff çalışır', () async {
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
      expect(fake.commandNames, ['lsblk', 'swapoff']);
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

      expect(result.success, true);
      expect(result.message, contains('nvme0n1'));
      expect(fake.wasCalledWith('umount', ['-f', '/dev/nvme0n1p1']), true);
    });
  });
}
