import 'package:test/test.dart';
import 'package:ro_installer/services/fake_command_runner.dart';
import 'package:ro_installer/services/install_artifact_collector.dart';

void main() {
  group('InstallArtifactCollector', () {
    test('tüm teşhis komutları çalıştırılır ve loglanır', () async {
      final fake = FakeCommandRunner();
      final collector = InstallArtifactCollector(commandRunner: fake);

      final loggedMessages = <String>[];
      
      await collector.collectDiagnostics((msg) {
        loggedMessages.add(msg);
      }, isMock: true);

      // Çalıştırılan komutlar
      final cmds = fake.commandNames;
      final fullCmds = fake.commandLog.map((c) => '${c.command} ${c.args.join(' ')}').toList();

      expect(cmds.contains('lsblk'), true);
      expect(cmds.contains('blkid'), true);
      expect(cmds.contains('findmnt'), true);
      
      // cat komutları
      expect(fullCmds.any((c) => c.startsWith('cat /mnt/etc/fstab')), true);
      expect(fullCmds.any((c) => c.startsWith('cat /mnt/etc/kernel/cmdline')), true);
      
      // ls komutları
      expect(fullCmds.any((c) => c.startsWith('ls -la /mnt/boot/efi/EFI/fedora/')), true);
      expect(fullCmds.any((c) => c.startsWith('ls -la /mnt/boot/loader/entries/')), true);

      // Log kontrolü
      expect(loggedMessages.any((m) => m.contains('KURULUM HATASI TEŞHİS RAPORU')), true);
      expect(loggedMessages.any((m) => m.contains('lsblk -f')), true);
    });
  });
}
