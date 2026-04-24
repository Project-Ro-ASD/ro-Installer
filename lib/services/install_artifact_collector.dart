import 'command_runner.dart';
import 'install_localizer.dart';

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
    InstallLocalizer localizer = const InstallLocalizer(),
  }) async {
    String t(String key, String fallback) => localizer.t(key, fallback);

    onLog('');
    onLog('╔═══════════════════════════════════════════════════════════╗');
    onLog(
      t(
        'artifact_header_title',
        '║ 🚨 KURULUM HATASI TEŞHİS RAPORU (ARTIFACT COLLECTION)    ║',
      ),
    );
    onLog('╚═══════════════════════════════════════════════════════════╝');

    await _runDiagCmd(
      'lsblk -f',
      t('artifact_title_disk_layout', 'DİSK VE BÖLÜM YAPISI'),
      onLog,
      isMock: isMock,
      localizer: localizer,
    );
    await _runDiagCmd(
      'blkid',
      t('artifact_title_partition_uuid', 'BÖLÜM UUID BİLGİLERİ'),
      onLog,
      isMock: isMock,
      localizer: localizer,
    );
    await _runDiagCmd(
      'findmnt',
      t('artifact_title_active_mounts', 'AKTİF MOUNT NOKTALARI'),
      onLog,
      isMock: isMock,
      localizer: localizer,
    );
    await _runDiagCmd(
      'cat /mnt/etc/fstab',
      t('artifact_title_fstab', 'FSTAB YAPILANDIRMASI'),
      onLog,
      isMock: isMock,
      localizer: localizer,
    );
    await _runDiagCmd(
      'ls -la /mnt/boot/efi/EFI/fedora/',
      t('artifact_title_efi_files', 'EFI DOSYALARI'),
      onLog,
      isMock: isMock,
      localizer: localizer,
    );
    await _runDiagCmd(
      'cat /mnt/boot/efi/EFI/fedora/grub.cfg',
      t('artifact_title_efi_grub_stub', 'EFI GRUB STUB'),
      onLog,
      isMock: isMock,
      localizer: localizer,
    );
    await _runDiagCmd(
      'ls -la /mnt/boot/loader/entries/',
      t('artifact_title_bls_entries', 'BLS GİRİŞLERİ'),
      onLog,
      isMock: isMock,
      localizer: localizer,
    );
    await _runDiagCmd(
      'cat /mnt/etc/kernel/cmdline',
      t('artifact_title_kernel_cmdline', 'KERNEL CMDLINE'),
      onLog,
      isMock: isMock,
      localizer: localizer,
    );

    onLog('═════════════════════════════════════════════════════════════');
    onLog(
      t(
        'artifact_footer',
        'TEŞHİS RAPORU TAMAMLANDI. Lütfen yukarıdaki çıktıları inceleyin.',
      ),
    );
    onLog('═════════════════════════════════════════════════════════════');
  }

  Future<void> _runDiagCmd(
    String cmdLine,
    String title,
    void Function(String) onLog, {
    bool isMock = false,
    InstallLocalizer localizer = const InstallLocalizer(),
  }) async {
    onLog('\n--- $title ---');
    onLog('\$ $cmdLine');

    final parts = cmdLine.split(' ');
    final cmd = parts.first;
    final args = parts.length > 1 ? parts.sublist(1) : <String>[];

    final result = await _commandRunner.run(cmd, args, isMock: isMock);

    if (!result.started) {
      onLog(
        localizer.t(
          'artifact_command_not_started',
          '[HATA] Komut çalıştırılamadı!',
        ),
      );
      return;
    }

    if (result.stdout.isNotEmpty) {
      onLog(result.stdout.trim());
    }

    if (result.stderr.isNotEmpty) {
      onLog('[STDERR] ${result.stderr.trim()}');
    }

    if (result.stdout.isEmpty && result.stderr.isEmpty) {
      onLog(localizer.t('artifact_empty_output', '(Çıktı boş)'));
    }
  }
}
