import 'command_runner.dart';

/// Kurulum hata verdiğinde, hatanın nedenini teşhis edebilmek için
/// sistem durumunun (disk, mount, boot dosyaları vb.) kaydını tutan servis.
class InstallArtifactCollector {
  final CommandRunner _commandRunner;

  InstallArtifactCollector({CommandRunner? commandRunner})
    : _commandRunner = commandRunner ?? CommandRunner.instance;

  /// Hata anında tüm teşhis verilerini toplayıp log fonksiyonuna yollar.
  Future<void> collectDiagnostics(
    void Function(String) onLog, {
    bool isMock = false,
  }) async {
    onLog('');
    onLog('╔═══════════════════════════════════════════════════════════╗');
    onLog('║ 🚨 KURULUM HATASI TEŞHİS RAPORU (ARTIFACT COLLECTION)    ║');
    onLog('╚═══════════════════════════════════════════════════════════╝');

    await _runDiagCmd(
      'lsblk -f',
      'DİSK VE BÖLÜM YAPISI',
      onLog,
      isMock: isMock,
    );
    await _runDiagCmd('blkid', 'BÖLÜM UUID BİLGİLERİ', onLog, isMock: isMock);
    await _runDiagCmd(
      'findmnt',
      'AKTİF MOUNT NOKTALARI',
      onLog,
      isMock: isMock,
    );
    await _runDiagCmd(
      'cat /mnt/etc/fstab',
      'FSTAB YAPILANDIRMASI',
      onLog,
      isMock: isMock,
    );
    await _runDiagCmd(
      'ls -la /mnt/boot/efi/EFI/fedora/',
      'EFI DOSYALARI',
      onLog,
      isMock: isMock,
    );
    await _runDiagCmd(
      'cat /mnt/boot/efi/EFI/fedora/grub.cfg',
      'EFI GRUB STUB',
      onLog,
      isMock: isMock,
    );
    await _runDiagCmd(
      'ls -la /mnt/boot/loader/entries/',
      'BLS GİRİŞLERİ',
      onLog,
      isMock: isMock,
    );
    await _runDiagCmd(
      'cat /mnt/etc/kernel/cmdline',
      'KERNEL CMDLINE',
      onLog,
      isMock: isMock,
    );

    onLog('═════════════════════════════════════════════════════════════');
    onLog('TEŞHİS RAPORU TAMAMLANDI. Lütfen yukarıdaki çıktıları inceleyin.');
    onLog('═════════════════════════════════════════════════════════════');
  }

  Future<void> _runDiagCmd(
    String cmdLine,
    String title,
    void Function(String) onLog, {
    bool isMock = false,
  }) async {
    onLog('\n--- $title ---');
    onLog('\$ $cmdLine');

    final parts = cmdLine.split(' ');
    final cmd = parts.first;
    final args = parts.length > 1 ? parts.sublist(1) : <String>[];

    final result = await _commandRunner.run(cmd, args, isMock: isMock);

    if (!result.started) {
      onLog('[HATA] Komut çalıştırılamadı!');
      return;
    }

    if (result.stdout.isNotEmpty) {
      onLog(result.stdout.trim());
    }

    if (result.stderr.isNotEmpty) {
      onLog('[STDERR] ${result.stderr.trim()}');
    }

    if (result.stdout.isEmpty && result.stderr.isEmpty) {
      onLog('(Çıktı boş)');
    }
  }
}
