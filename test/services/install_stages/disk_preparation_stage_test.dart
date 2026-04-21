import 'package:test/test.dart';
import 'package:ro_installer/services/fake_command_runner.dart';
import 'package:ro_installer/services/command_runner.dart';
import 'package:ro_installer/services/install_stages/disk_preparation_stage.dart';
import 'package:ro_installer/services/install_stages/stage_context.dart';
import 'package:ro_installer/services/install_stages/stage_result.dart';

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
    runCmd: (cmd, args, onLog, {bool isMock = false, List<int> allowedExitCodes = const [0]}) async {
      final result = await runner.run(cmd, args);
      return allowedExitCodes.contains(result.exitCode);
    },
    isMock: isMock,
  );
}

void main() {
  group('DiskPreparationStage', () {
    test('umount ve swapoff komutlarını sırasıyla çalıştırır', () async {
      final fake = FakeCommandRunner();
      final ctx = makeContext({'selectedDisk': '/dev/sda'}, fake);

      final stage = const DiskPreparationStage();
      final result = await stage.execute(ctx);

      expect(result.success, true);
      expect(result.message, contains('sda'));

      // Komut sırası doğrulaması
      expect(fake.commandLog.length, 2);
      expect(fake.commandLog[0].command, 'sh'); // umount
      expect(fake.commandLog[0].args, contains('-c'));
      expect(fake.commandLog[1].command, 'swapoff');
      expect(fake.commandLog[1].args, ['-a']);
    });

    test('NVMe disk adıyla da çalışır', () async {
      final fake = FakeCommandRunner();
      final ctx = makeContext({'selectedDisk': '/dev/nvme0n1'}, fake);

      final stage = const DiskPreparationStage();
      final result = await stage.execute(ctx);

      expect(result.success, true);
      expect(result.message, contains('nvme0n1'));
    });
  });
}
