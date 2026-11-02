import 'package:test/test.dart';
import 'package:ro_installer/services/fake_command_runner.dart';
import 'package:ro_installer/services/install_stages/partitioning_stage.dart';
import 'partitioning_stage_test.dart' as f;

void main() {
  for (final legacy in [
    {
      'name': '/dev/sda2',
      'deletedPartitionNames': ['/dev/sda2'],
      'isFreeSpace': true,
    },
    {
      'name': '/dev/sda2',
      'isResized': true,
      'sizeBytes': 40 * 1024 * 1024 * 1024,
    },
    {
      'name': 'New Partition',
      'type': 'btrfs',
      'mount': '/',
      'startSector': 2048,
      'sizeBytes': 40 * 1024 * 1024 * 1024,
    },
    {
      'name': '/dev/sda2',
      'type': 'btrfs',
      'mount': '/',
      'formatOnInstall': true,
    },
    {
      'name': '/dev/sda1',
      'type': 'fat32',
      'mount': '/boot/efi',
      'formatOnInstall': false,
    },
    {
      'name': '/dev/sda3',
      'type': 'linux-swap',
      'mount': '[SWAP]',
      'formatOnInstall': true,
    },
  ]) {
    test(
      'unapproved legacy manual input cannot run storage commands: $legacy',
      () async {
        final runner = FakeCommandRunner();
        final ctx = f.makeContext({
          'selectedDisk': '/dev/sda',
          'partitionMethod': 'manual',
          'fileSystem': 'btrfs',
          'manualPartitions': [legacy],
        }, runner);
        expect((await const PartitioningStage().execute(ctx)).success, false);
        expect(runner.commandLog, isEmpty);
      },
    );
  }
}
