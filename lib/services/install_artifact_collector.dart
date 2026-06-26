import 'command_runner.dart';
import 'install_localizer.dart';

/// Kurulum hata verdiğinde, hatanın nedenini teşhis edebilmek için
/// sistem durumunun (disk, mount, boot dosyaları vb.) kaydını tutan servis.
class InstallArtifactCollector {
  static const String diagnosticContractVersion = '2026-06-26.1';
  static const List<String> diagnosticSectionIds = [
    'disk-layout',
    'partition-uuid',
    'active-mounts',
    'target-fstab',
    'efi-files',
    'efi-grub-stub',
    'bls-entries',
    'kernel-cmdline',
    'crypttab',
    'boot-args',
    'release-policy',
    'dnf-policy',
    'repo-files',
    'kernel-configs',
    'kernel-modules',
    'nouveau-params',
    'initramfs-gpu',
    'live-cmdline',
    'live-journal-warnings',
    'live-dmesg-warnings',
  ];

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
    onLog('[ARTIFACT_CONTRACT] version=$diagnosticContractVersion');

    await _runDiagCmd(
      'lsblk -f',
      t('artifact_title_disk_layout', 'DİSK VE BÖLÜM YAPISI'),
      onLog,
      sectionId: 'disk-layout',
      isMock: isMock,
      localizer: localizer,
    );
    await _runDiagCmd(
      'blkid',
      t('artifact_title_partition_uuid', 'BÖLÜM UUID BİLGİLERİ'),
      onLog,
      sectionId: 'partition-uuid',
      isMock: isMock,
      localizer: localizer,
    );
    await _runDiagCmd(
      'findmnt',
      t('artifact_title_active_mounts', 'AKTİF MOUNT NOKTALARI'),
      onLog,
      sectionId: 'active-mounts',
      isMock: isMock,
      localizer: localizer,
    );
    await _runDiagCmd(
      'cat /mnt/etc/fstab',
      t('artifact_title_fstab', 'FSTAB YAPILANDIRMASI'),
      onLog,
      sectionId: 'target-fstab',
      isMock: isMock,
      localizer: localizer,
    );
    await _runDiagCmd(
      'ls -la /mnt/boot/efi/EFI/fedora/',
      t('artifact_title_efi_files', 'EFI DOSYALARI'),
      onLog,
      sectionId: 'efi-files',
      isMock: isMock,
      localizer: localizer,
    );
    await _runDiagCmd(
      'cat /mnt/boot/efi/EFI/fedora/grub.cfg',
      t('artifact_title_efi_grub_stub', 'EFI GRUB STUB'),
      onLog,
      sectionId: 'efi-grub-stub',
      isMock: isMock,
      localizer: localizer,
    );
    await _runDiagCmd(
      'ls -la /mnt/boot/loader/entries/',
      t('artifact_title_bls_entries', 'BLS GİRİŞLERİ'),
      onLog,
      sectionId: 'bls-entries',
      isMock: isMock,
      localizer: localizer,
    );
    await _runDiagCmd(
      'cat /mnt/etc/kernel/cmdline',
      t('artifact_title_kernel_cmdline', 'KERNEL CMDLINE'),
      onLog,
      sectionId: 'kernel-cmdline',
      isMock: isMock,
      localizer: localizer,
    );
    await _runDiagCmd(
      'cat /mnt/etc/crypttab',
      t('artifact_title_crypttab', 'CRYPTTAB YAPILANDIRMASI'),
      onLog,
      sectionId: 'crypttab',
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
      sectionId: 'boot-args',
      isMock: isMock,
      localizer: localizer,
    );
    await _runDiagCmd(
      'cat /mnt/etc/ro-asd/release-policy.conf',
      t('artifact_title_release_policy', 'RO RELEASE POLICY'),
      onLog,
      sectionId: 'release-policy',
      isMock: isMock,
      localizer: localizer,
    );
    await _runDiagCmdArgs(
      'sh',
      [
        '-c',
        r'''
for file in /mnt/etc/dnf/dnf.conf /mnt/etc/dnf/protected.d/ro-kernel.conf; do
  [ -e "$file" ] || continue
  echo "== $file =="
  grep -E "^(excludepkgs|protect_packages|installonlypkgs)=" "$file" || true
done
''',
      ],
      t('artifact_title_dnf_policy', 'DNF KERNEL KORUMA POLİTİKASI'),
      onLog,
      sectionId: 'dnf-policy',
      displayLine:
          'sh -c "show dnf kernel protection policy from target system"',
      isMock: isMock,
      localizer: localizer,
    );
    await _runDiagCmdArgs(
      'sh',
      [
        '-c',
        r'''
for file in /mnt/etc/yum.repos.d/ro-*.repo /mnt/etc/yum.repos.d/_copr:copr.fedorainfracloud.org:*.repo; do
  [ -e "$file" ] || continue
  echo "== $file =="
  grep -E "^\[|^name=|^baseurl=|^enabled=|^gpgcheck=|^repo_gpgcheck=|^gpgkey=|^metadata_expire=|^skip_if_unavailable=" "$file" || true
done
''',
      ],
      t('artifact_title_repo_files', 'HEDEF REPO DOSYALARI'),
      onLog,
      sectionId: 'repo-files',
      displayLine: 'sh -c "show target repo trust settings"',
      isMock: isMock,
      localizer: localizer,
    );
    await _runDiagCmdArgs(
      'find',
      [
        '/mnt/boot',
        '-maxdepth',
        '1',
        '-type',
        'f',
        '-name',
        'config-*',
        '-print',
      ],
      t('artifact_title_kernel_configs', 'KERNEL CONFIG DOSYALARI'),
      onLog,
      sectionId: 'kernel-configs',
      isMock: isMock,
      localizer: localizer,
    );
    await _runDiagCmd(
      'ls -la /mnt/lib/modules',
      t('artifact_title_kernel_modules', 'KERNEL MODÜL DİZİNLERİ'),
      onLog,
      sectionId: 'kernel-modules',
      isMock: isMock,
      localizer: localizer,
    );
    await _runDiagCmdArgs(
      'chroot',
      ['/mnt', 'sh', '-c', 'modinfo -p nouveau 2>/dev/null || true'],
      t('artifact_title_nouveau_params', 'NOUVEAU MODÜL PARAMETRELERİ'),
      onLog,
      sectionId: 'nouveau-params',
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
      sectionId: 'initramfs-gpu',
      isMock: isMock,
      localizer: localizer,
    );
    await _runDiagCmd(
      'cat /proc/cmdline',
      t('artifact_title_live_cmdline', 'LIVE KERNEL CMDLINE'),
      onLog,
      sectionId: 'live-cmdline',
      isMock: isMock,
      localizer: localizer,
    );
    await _runDiagCmdArgs(
      'journalctl',
      ['-b', '-p', 'warning', '--no-pager', '-n', '160'],
      t('artifact_title_live_journal', 'LIVE JOURNAL UYARI/HATA ÖZETİ'),
      onLog,
      sectionId: 'live-journal-warnings',
      isMock: isMock,
      localizer: localizer,
    );
    await _runDiagCmdArgs(
      'dmesg',
      ['--level=err,warn', '--ctime'],
      t('artifact_title_live_dmesg', 'LIVE DMESG UYARI/HATA ÖZETİ'),
      onLog,
      sectionId: 'live-dmesg-warnings',
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
    required String sectionId,
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
      sectionId: sectionId,
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
    required String sectionId,
    String? displayLine,
    bool isMock = false,
    InstallLocalizer localizer = const InstallLocalizer(),
  }) async {
    final safeDisplay = displayLine == null
        ? SecretRedactor.redactCommandLine(cmd, args)
        : SecretRedactor.redactText(displayLine);
    onLog('\n--- [$sectionId] $title ---');
    onLog('[ARTIFACT_SECTION] id=$sectionId');
    onLog('\$ $safeDisplay');

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

    if (result.exitCode != 0) {
      onLog('[EXIT] ${result.exitCode}');
    }
  }
}
