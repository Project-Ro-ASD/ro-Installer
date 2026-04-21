import 'package:test/test.dart';
import 'package:ro_installer/services/fake_command_runner.dart';
import 'package:ro_installer/services/install_stages/file_copy_stage.dart';
import 'package:ro_installer/services/install_stages/stage_context.dart';

StageContext makeContext(
  Map<String, dynamic> state,
  FakeCommandRunner runner, {
  bool isMock = false,
}) {
  return StageContext(
    state: state,
    log: (msg) {},
    onProgress: (p, s) {},
    commandRunner: runner,
    runCmd: (
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
  group('FileCopyStage', () {
    test('live boot kalintilarini rsync ile dislar', () async {
      final fake = FakeCommandRunner();
      fake.addResponse(
        'findmnt',
        ['-rn', '-o', 'TARGET,FSTYPE'],
        stdout: '''
/ ext4
/boot/efi vfat
/run tmpfs
''',
      );

      final ctx = makeContext({}, fake);
      final stage = const FileCopyStage();

      final result = await stage.execute(ctx);

      expect(result.success, true);

      final rsyncCall = fake.commandLog.firstWhere((c) => c.command == 'rsync');
      expect(rsyncCall.args, contains('--exclude=/etc/kernel/cmdline'));
      expect(rsyncCall.args, contains('--exclude=/boot/loader/entries/*'));
      expect(rsyncCall.args, contains('--exclude=/boot/grub2/grubenv'));
      expect(rsyncCall.args, contains('--exclude=/boot/efi'));
      expect(rsyncCall.args, contains('--exclude=/boot/efi/*'));
    });
  });
}
