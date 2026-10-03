import 'package:test/test.dart';
import 'package:ro_installer/services/fake_command_runner.dart';
import 'package:ro_installer/services/install_service.dart';

void main() {
  for (final mode in ['alongside', 'free_space', 'manual', 'unknown']) {
    test('$mode is rejected before any disk preparation command', () async {
      final runner = FakeCommandRunner(defaultSuccess: false);
      final state = <String, dynamic>{
        'selectedDisk': '/dev/sda',
        'partitionMethod': mode,
      };
      final logs = <String>[];
      final success = await InstallService(commandRunner: runner)
          .runInstall(state, (_, _) {}, logs.add);
      expect(success, isFalse);
      expect(runner.commandLog, isEmpty);
      expect(state['partitionMethod'], mode);
      expect(logs.join('\n'), contains('full-disk erase'));
    });
  }

  test('non-x86_64 or non-UEFI hosts fail before disk preparation', () async {
    for (final arch in ['aarch64', 'x86_64']) {
      final runner = FakeCommandRunner();
      runner.addResponse('uname', ['-m'], stdout: arch);
      runner.addResponse('test', ['-d', '/sys/firmware/efi'], exitCode: arch == 'aarch64' ? 0 : 1);
      final success = await InstallService(commandRunner: runner).runInstall(
        {'selectedDisk': '/dev/sda', 'partitionMethod': 'full'},
        (_, _) {},
        (_) {},
      );
      expect(success, isFalse);
      expect(runner.commandNames, ['uname', 'test']);
    }
  });
}
