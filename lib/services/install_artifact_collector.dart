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
    await _runDiagCmd(
      'cat /mnt/etc/crypttab',
      t('artifact_title_crypttab', 'CRYPTTAB YAPILANDIRMASI'),
      onLog,
      isMock: isMock,
      localizer: localizer,
    );
    await _runDiagCmdArgs(
      'grep',
      [
        '-R',
        '-n',
        '-E',
        'root=UUID|rootflags|resume=UUID|nomodeset|nouveau|i915|xe|blacklist|ro\\.live',
        '/mnt/etc/kernel/cmdline',
        '/mnt/boot/loader/entries',
      ],
      t('artifact_title_boot_args', 'BOOT ARGÜMAN ÖZETİ'),
      onLog,
      isMock: isMock,
      localizer: localizer,
    );
    await _runDiagCmdArgs(
      'find',
      ['/mnt/boot', '-maxdepth', '1', '-type', 'f', '-name', 'config-*', '-print'],
      t('artifact_title_kernel_configs', 'KERNEL CONFIG DOSYALARI'),
      onLog,
      isMock: isMock,
      localizer: localizer,
    );
    await _runDiagCmd(
      'ls -la /mnt/lib/modules',
      t('artifact_title_kernel_modules', 'KERNEL MODÜL DİZİNLERİ'),
      onLog,
      isMock: isMock,
      localizer: localizer,
    );
    await _runDiagCmdArgs(
      'chroot',
      ['/mnt', 'sh', '-c', 'modinfo -p nouveau 2>/dev/null || true'],
      t('artifact_title_nouveau_params', 'NOUVEAU MODÜL PARAMETRELERİ'),
      onLog,
      isMock: isMock,
      localizer: localizer,
    );
    await _runDiagCmdArgs(
      'chroot',
      [
        '/mnt',
        'sh',
        '-c',
        r'''
for img in /boot/initramfs-*.img; do
  [ -e "$img" ] || continue
  echo "== $img =="
  lsinitrd "$img" 2>/dev/null | grep -E "nouveau|nvidia|firmware|gsp" || true
done
''',
      ],
      t('artifact_title_initramfs_gpu', 'INITRAMFS GPU/FIRMWARE İPUÇLARI'),
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
    final parts = cmdLine.split(' ');
    final cmd = parts.first;
    final args = parts.length > 1 ? parts.sublist(1) : <String>[];
    await _runDiagCmdArgs(
      cmd,
      args,
      title,
      onLog,
      displayLine: cmdLine,
      isMock: isMock,
      localizer: localizer,
    );
  }

  Future<void> _runDiagCmdArgs(
    String cmd,
    List<String> args,
    String title,
    void Function(String) onLog, {
    String? displayLine,
    bool isMock = false,
    InstallLocalizer localizer = const InstallLocalizer(),
  }) async {
    onLog('\n--- $title ---');
    onLog('\$ ${displayLine ?? [cmd, ...args].join(' ')}');

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
      onLog(SecretRedactor.redactText(result.stdout.trim()));
    }

    if (result.stderr.isNotEmpty) {
      onLog('[STDERR] ${SecretRedactor.redactText(result.stderr.trim())}');
    }

    if (result.stdout.isEmpty && result.stderr.isEmpty) {
      onLog(localizer.t('artifact_empty_output', '(Çıktı boş)'));
    }
  }
}
