import 'stage_context.dart';
import 'stage_result.dart';
import '../../utils/account_validation.dart';
import '../target_system_settings.dart';

/// AŞAMA 6: Chroot Yapılandırma
///
/// Hedef sistemi chroot ortamında yapılandırır:
/// - Bind mount'ları oluşturur (/dev, /proc, /sys, /run, /tmp)
/// - Zaman dilimi ayarlar
/// - Machine ID oluşturur
/// - Hostname, Klavye, Locale ayarlar
/// - Kullanıcı hesabı ve şifre oluşturur
/// - SELinux context'leri düzeltir
/// - Eski installer kalıntılarını temizler
/// - FSTAB üretir
/// - .autorelabel oluşturur
class ChrootConfigStage {
  const ChrootConfigStage();

  Future<StageResult> execute(StageContext ctx) async {
    ctx.log('════════════════════════════════════════════');
    ctx.log('[AŞAMA 6] Chroot Yapılandırma Başlatılıyor');
    ctx.log('════════════════════════════════════════════');

    // ── 6.1: Bind Mount'ları Oluştur ──
    ctx.progress(
      0.7,
      'stage_progress_chroot_bind_mounts',
      'Kök sistem bağlamaları yapılıyor (Chroot hazırlığı)...',
    );

    // Rsync tarafından dışlanan dizinlerin bağlama noktalarını oluştur
    StageResult? failure = await _requireCommand(ctx, 'mkdir', [
      '-p',
      '/mnt/dev',
      '/mnt/proc',
      '/mnt/sys',
      '/mnt/run',
      '/mnt/tmp',
    ], 'Chroot bağlama dizinleri oluşturulamadı.');
    if (failure != null) return failure;

    // /tmp için tmpfs mount et (os-prober ve dracut için şart)
    failure = await _requireCommand(ctx, 'mount', [
      '-t',
      'tmpfs',
      'tmpfs',
      '/mnt/tmp',
    ], '/mnt/tmp için tmpfs bağlanamadı.');
    if (failure != null) return failure;

    // --rbind: /dev/pts, /dev/shm, /sys/firmware/efi/efivars gibi alt mount'ları da dahil eder
    // Bu dracut ve grub2-install için EFI ve cihaz erişiminde kritik önemdedir
    failure = await _requireCommand(ctx, 'mount', [
      '--rbind',
      '/dev',
      '/mnt/dev',
    ], '/dev bağı hedef sisteme aktarılamadı.');
    if (failure != null) return failure;
    failure = await _requireCommand(ctx, 'mount', [
      '--make-rslave',
      '/mnt/dev',
    ], '/mnt/dev için rslave ayarı uygulanamadı.');
    if (failure != null) return failure;
    failure = await _requireCommand(ctx, 'mount', [
      '--rbind',
      '/proc',
      '/mnt/proc',
    ], '/proc bağı hedef sisteme aktarılamadı.');
    if (failure != null) return failure;
    failure = await _requireCommand(ctx, 'mount', [
      '--make-rslave',
      '/mnt/proc',
    ], '/mnt/proc için rslave ayarı uygulanamadı.');
    if (failure != null) return failure;
    failure = await _requireCommand(ctx, 'mount', [
      '--rbind',
      '/sys',
      '/mnt/sys',
    ], '/sys bağı hedef sisteme aktarılamadı.');
    if (failure != null) return failure;
    failure = await _requireCommand(ctx, 'mount', [
      '--make-rslave',
      '/mnt/sys',
    ], '/mnt/sys için rslave ayarı uygulanamadı.');
    if (failure != null) return failure;
    failure = await _requireCommand(ctx, 'mount', [
      '--rbind',
      '/run',
      '/mnt/run',
    ], '/run bağı hedef sisteme aktarılamadı.');
    if (failure != null) return failure;
    failure = await _requireCommand(ctx, 'mount', [
      '--make-rslave',
      '/mnt/run',
    ], '/mnt/run için rslave ayarı uygulanamadı.');
    if (failure != null) return failure;

    // ── 6.2: Kullanıcı ve Sistem Ayarları ──
    ctx.progress(
      0.8,
      'stage_progress_chroot_user_timezone',
      'Zaman dilimi ve kullanıcı ayarları yapılandırılıyor...',
    );

    String user = ctx.state['username'] ?? 'user';
    String pass = ctx.state['password'] ?? 'user';
    String tz = ctx.state['selectedTimezone'] ?? 'Europe/Istanbul';
    String languageCode = ctx.state['selectedLanguage'] ?? 'en';
    String localeOverride = ctx.state['selectedLocale'] ?? '';
    String hostname = 'ro-asd';
    final isAdministrator = ctx.state['isAdministrator'] == true;
    final localeSettings = resolveTargetLocaleSettings(
      selectedLanguage: languageCode,
      selectedLocale: localeOverride,
    );
    final keyboardSettings = resolveTargetKeyboardSettings(
      (ctx.state['selectedKeyboard'] ?? 'trq').toString(),
    );

    user = normalizeLinuxUsername(user);
    if (!isValidLinuxUsername(user)) {
      return StageResult.fail(
        'Gecersiz kullanici adi: $user. Kullanici adi harf veya _ ile baslamali ve sadece kucuk harf, rakam, _ veya - icermelidir.',
      );
    }

    // Zaman dilimi
    failure = await _requireCommand(ctx, 'chroot', [
      '/mnt',
      'ln',
      '-sf',
      '/usr/share/zoneinfo/$tz',
      '/etc/localtime',
    ], 'Zaman dilimi ayarlanamadı.');
    if (failure != null) return failure;

    // Sistem kimliği (Machine ID) oluşturma
    failure = await _requireCommand(ctx, 'chroot', [
      '/mnt',
      'systemd-machine-id-setup',
    ], 'Machine ID oluşturulamadı.');
    if (failure != null) return failure;

    // Hostname (Makine Adı)
    failure = await _requireCommand(ctx, 'chroot', [
      '/mnt',
      'sh',
      '-c',
      'echo "$hostname" > /etc/hostname',
    ], 'Hostname yazılamadı.');
    if (failure != null) return failure;

    ctx.progress(
      0.81,
      'stage_progress_chroot_language_support',
      'Seçilen dil destek paketleri kuruluyor...',
    );

    failure = await _installLocalizationSupport(ctx, localeSettings);
    if (failure != null) return failure;

    // Vconsole (Klavye Düzeni)
    failure = await _requireCommand(ctx, 'chroot', [
      '/mnt',
      'sh',
      '-c',
      'echo "KEYMAP=${keyboardSettings.consoleKeymap}" > /etc/vconsole.conf',
    ], 'Klavye düzeni yapılandırılamadı.');
    if (failure != null) return failure;

    failure = await _requireCommand(ctx, 'chroot', [
      '/mnt',
      'sh',
      '-c',
      '''
mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/00-keyboard.conf << 'EOF'
${renderX11KeyboardConfig(keyboardSettings)}
EOF
      ''',
    ], 'Grafik oturum klavye düzeni yapılandırılamadı.');
    if (failure != null) return failure;

    // Locale (Dil)
    failure = await _requireCommand(ctx, 'chroot', [
      '/mnt',
      'sh',
      '-c',
      'echo "LANG=${localeSettings.locale}" > /etc/locale.conf',
    ], 'Locale yapılandırması yazılamadı.');
    if (failure != null) return failure;

    // ── 6.3: SELinux Context Düzeltmesi (chpasswd öncesi) ──
    failure = await _requireCommand(ctx, 'chroot', [
      '/mnt',
      'restorecon',
      '/etc/passwd',
      '/etc/shadow',
      '/etc/gshadow',
      '/etc/group',
    ], 'SELinux hesap dosyası context düzeltmesi başarısız oldu.');
    if (failure != null) return failure;

    // ── 6.4: Kullanıcı Hesabı ve Şifre ──
    // 1. Kullanıcıyı oluştur (home dizini, bash shell, yöneticiyse wheel grubu)
    final useraddArgs = <String>['/mnt', 'useradd', '-m', '-s', '/bin/bash'];
    if (isAdministrator) {
      useraddArgs.addAll(['-G', 'wheel']);
    }
    useraddArgs.add(user);
    failure = await _requireCommand(
      ctx,
      'chroot',
      useraddArgs,
      'Kullanıcı hesabı oluşturulamadı: $user',
    );
    if (failure != null) return failure;

    // 2. Parolasını belirle
    failure = await _requireCommand(ctx, 'chroot', [
      '/mnt',
      'sh',
      '-c',
      "printf '%s\\n' ${_shellQuote('$user:$pass')} | chpasswd",
    ], 'Kullanıcı parolası ayarlanamadı: $user');
    if (failure != null) return failure;

    // 3. Root hesabını kilitle (Güvenlik zafiyetini kapat)
    failure = await _requireCommand(ctx, 'chroot', [
      '/mnt',
      'passwd',
      '-l',
      'root',
    ], 'Root hesabı kilitlenemedi.');
    if (failure != null) return failure;

    if (isAdministrator) {
      failure = await _requireCommand(ctx, 'chroot', [
        '/mnt',
        'sh',
        '-c',
        "printf '%s\\n' ${_shellQuote('$user ALL=(ALL:ALL) ALL')} > /etc/sudoers.d/$user",
      ], 'Sudoers kuralı yazılamadı: $user');
      if (failure != null) return failure;
      failure = await _requireCommand(ctx, 'chroot', [
        '/mnt',
        'chmod',
        '0440',
        '/etc/sudoers.d/$user',
      ], 'Sudoers dosya izni ayarlanamadı: $user');
      if (failure != null) return failure;
    }

    // ── 6.5: Eski Installer ve Live CD Kalıntıları Temizliği ──
    ctx.progress(
      0.82,
      'stage_progress_chroot_cleanup_live',
      'Live CD ve eski installer kalıntıları temizleniyor...',
    );

    // Eski installer paketlerini kaldır
    await _runOptionalCommand(
      ctx,
      'chroot',
      ['/mnt', 'dnf', 'remove', '-y', 'calamares', 'anaconda*'],
      'Canlı ortam kurulum paketleri temizlenemedi; gereksiz paket kalıntıları kalabilir.',
      allowedExitCodes: const [0, 1],
    );

    // Live CD servis kalıntılarını devre dışı bırak ve kaldır
    // Bu servisler yalnızca Live ortamda gereklidir, kurulu sistemde çalışmamalıdır
    await _runOptionalCommand(
      ctx,
      'chroot',
      [
        '/mnt',
        'sh',
        '-c',
        '''
      systemctl disable livesys.service 2>/dev/null || true
      systemctl disable livesys-late.service 2>/dev/null || true
      rm -f /etc/systemd/system/livesys.service 2>/dev/null || true
      rm -f /etc/systemd/system/livesys-late.service 2>/dev/null || true
      rm -f /usr/lib/systemd/system/livesys.service 2>/dev/null || true
      rm -f /usr/lib/systemd/system/livesys-late.service 2>/dev/null || true
    ''',
      ],
      'Live servis kalıntıları tamamen temizlenemedi.',
      allowedExitCodes: const [0, 1],
    );

    // ro-Installer autostart dosyasını kurulu sistemden kaldır
    // (Kurulu sistemde artık yükleyiciye gerek yok)
    await _runOptionalCommand(
      ctx,
      'chroot',
      ['/mnt', 'rm', '-f', '/etc/xdg/autostart/ro-Installer.desktop'],
      'Kurulu sistemden eski autostart girdisi temizlenemedi.',
      allowedExitCodes: const [0, 1],
    );

    // liveuser kalıntılarını temizle (kurulu sistemde bulunmamalı)
    await _runOptionalCommand(
      ctx,
      'chroot',
      [
        '/mnt',
        'sh',
        '-c',
        '''
      userdel -r liveuser 2>/dev/null || true
      rm -f /etc/sudoers.d/ro-installer-live 2>/dev/null || true
    ''',
      ],
      'liveuser kalıntıları tamamen temizlenemedi.',
      allowedExitCodes: const [0, 1],
    );

    // /var/lib/dbus/machine-id senkronizasyonu
    await _runOptionalCommand(ctx, 'chroot', [
      '/mnt',
      'sh',
      '-c',
      'ln -sf /etc/machine-id /var/lib/dbus/machine-id 2>/dev/null || true',
    ], '/var/lib/dbus/machine-id senkronizasyonu doğrulanamadı.');

    // ── 6.6: FSTAB Üretimi ──
    // findmnt -R /mnt yaklaşımı /mnt/run altına bind edilen canlı ortam mountlarını
    // hedef sisteme sızdırdığı için girdileri kurulum planından deterministik üret.
    ctx.progress(
      0.85,
      'stage_progress_chroot_fstab_selinux',
      'Fstab ve SELinux yapılandırılıyor...',
    );

    final fstabEntries = await _buildFstabEntries(ctx);
    if (fstabEntries.isEmpty) {
      ctx.log('HATA: Kurulum planından fstab girdisi üretilemedi.');
      return StageResult.fail('/etc/fstab üretilemedi.');
    }

    final fstabContent = _renderFstab(fstabEntries);
    failure = await _requireCommand(ctx, 'sh', [
      '-c',
      "cat > /mnt/etc/fstab << 'EOF'\n$fstabContent\nEOF",
    ], '/etc/fstab üretilemedi.');
    if (failure != null) return failure;

    // Üretilen fstab'ı doğrulama için logla
    ctx.log('Üretilen /etc/fstab içeriği kontrol ediliyor...');
    failure = await _requireCommand(ctx, 'cat', [
      '/mnt/etc/fstab',
    ], 'Üretilen /etc/fstab okunamadı.');
    if (failure != null) return failure;
    failure = await _requireCommand(ctx, 'findmnt', [
      '--verify',
      '--tab-file',
      '/mnt/etc/fstab',
    ], 'Üretilen /etc/fstab doğrulanamadı.');
    if (failure != null) return failure;

    // ── 6.7: VM Smoke Test Servisi (Opsiyonel) ──
    if (ctx.state['vmTestMode'] == true) {
      ctx.progress(
        0.86,
        'stage_progress_chroot_vm_smoke',
        'VM test ilk acilis servisi hazirlaniyor...',
      );
      failure = await _requireCommand(ctx, 'sh', [
        '-c',
        '''
cat > /mnt/etc/systemd/system/ro-installer-vm-smoke.service << 'EOF'
[Unit]
Description=Ro-Installer VM Smoke Test Marker
After=local-fs.target systemd-user-sessions.service
ConditionPathExists=!/var/lib/ro-installer-vm-smoke.done

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo RO_INSTALLER_VM_BOOT_OK > /dev/ttyS0; touch /var/lib/ro-installer-vm-smoke.done; systemctl --no-block poweroff'
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF
        ''',
      ], 'VM smoke test servisi olusturulamadi.');
      if (failure != null) return failure;
      failure = await _requireCommand(ctx, 'chroot', [
        '/mnt',
        'systemctl',
        'enable',
        'ro-installer-vm-smoke.service',
      ], 'VM smoke test servisi etkinlestirilemedi.');
      if (failure != null) return failure;
    }

    // ── 6.8: SELinux Autorelabel ──
    // İlk açılışta dosyaların security context'lerinin düzeltilmesini sağlar
    failure = await _requireCommand(ctx, 'touch', [
      '/mnt/.autorelabel',
    ], 'SELinux autorelabel işaret dosyası oluşturulamadı.');
    if (failure != null) return failure;

    ctx.log('[AŞAMA 6] Chroot yapılandırma tamamlandı.');
    return StageResult.ok(
      ctx.t('stage_result_chroot_done', 'Chroot yapılandırma tamamlandı.'),
    );
  }

  Future<StageResult?> _installLocalizationSupport(
    StageContext ctx,
    TargetLocaleSettings localeSettings,
  ) async {
    final packages = localeSettings.requiredPackages;
    final ok = await ctx.runCmd(
      'chroot',
      ['/mnt', 'dnf', 'install', '-y', ...packages],
      ctx.log,
      isMock: ctx.isMock,
    );
    if (ok) {
      return null;
    }

    final message =
        'Secilen dil destek paketleri kurulamadı: ${packages.join(', ')}';
    ctx.log('HATA: $message');
    return StageResult.fail(message);
  }

  Future<StageResult?> _requireCommand(
    StageContext ctx,
    String cmd,
    List<String> args,
    String errorMessage, {
    List<int> allowedExitCodes = const [0],
  }) async {
    final ok = await ctx.runCmd(
      cmd,
      args,
      ctx.log,
      isMock: ctx.isMock,
      allowedExitCodes: allowedExitCodes,
    );
    if (ok) {
      return null;
    }

    ctx.log('HATA: $errorMessage');
    return StageResult.fail(errorMessage);
  }

  Future<void> _runOptionalCommand(
    StageContext ctx,
    String cmd,
    List<String> args,
    String warningMessage, {
    List<int> allowedExitCodes = const [0],
  }) async {
    final ok = await ctx.runCmd(
      cmd,
      args,
      ctx.log,
      isMock: ctx.isMock,
      allowedExitCodes: allowedExitCodes,
    );
    if (!ok) {
      ctx.log('UYARI: $warningMessage');
    }
  }

  String _shellQuote(String value) {
    return "'${value.replaceAll("'", "'\"'\"'")}'";
  }

  Future<List<_FstabEntry>> _buildFstabEntries(StageContext ctx) async {
    final partitionMethod = (ctx.state['partitionMethod'] ?? 'full').toString();
    final rootFs = (ctx.state['fileSystem'] ?? 'btrfs').toString();
    final entries = <_FstabEntry>[];

    switch (partitionMethod) {
      case 'full':
        final selectedDisk = (ctx.state['selectedDisk'] ?? '/dev/sda')
            .toString();
        final efiPart = _partitionPath(selectedDisk, 1);
        final rootPart = _partitionPath(selectedDisk, 2);

        final rootEntry = await _makeFsEntry(
          ctx,
          device: rootPart,
          mountPoint: '/',
          fsType: rootFs,
          options: _rootMountOptions(rootFs),
        );
        if (rootEntry == null) return const [];
        entries.add(rootEntry);

        if (rootFs == 'btrfs') {
          final homeEntry = await _makeFsEntry(
            ctx,
            device: rootPart,
            mountPoint: '/home',
            fsType: 'btrfs',
            options: 'defaults,compress=zstd:1,subvol=@home',
          );
          if (homeEntry == null) return const [];
          entries.add(homeEntry);
        }

        final efiEntry = await _makeFsEntry(
          ctx,
          device: efiPart,
          mountPoint: '/boot/efi',
          fsType: 'vfat',
          options: _defaultMountOptions('vfat'),
        );
        if (efiEntry == null) return const [];
        entries.add(efiEntry);
        return entries;

      case 'alongside':
        final rootPart = (ctx.state['_resolvedRootPart'] ?? '').toString();
        if (rootPart.isEmpty && !ctx.isMock) {
          ctx.log('HATA: Alongside kurulum için root bölümü çözümlenmemiş.');
          return const [];
        }

        final resolvedRootPart = rootPart.isEmpty ? '/dev/sda2' : rootPart;
        final rootEntry = await _makeFsEntry(
          ctx,
          device: resolvedRootPart,
          mountPoint: '/',
          fsType: rootFs,
          options: _rootMountOptions(rootFs),
        );
        if (rootEntry == null) return const [];
        entries.add(rootEntry);

        if (rootFs == 'btrfs') {
          final homeEntry = await _makeFsEntry(
            ctx,
            device: resolvedRootPart,
            mountPoint: '/home',
            fsType: 'btrfs',
            options: 'defaults,compress=zstd:1,subvol=@home',
          );
          if (homeEntry == null) return const [];
          entries.add(homeEntry);
        }

        final existingEfiPart = (ctx.state['existingEfiPartition'] ?? '')
            .toString();
        if (existingEfiPart.isNotEmpty) {
          final efiEntry = await _makeFsEntry(
            ctx,
            device: existingEfiPart,
            mountPoint: '/boot/efi',
            fsType: 'vfat',
            options: _defaultMountOptions('vfat'),
          );
          if (efiEntry == null) return const [];
          entries.add(efiEntry);
        }

        final swapPart = (ctx.state['_resolvedSwapPart'] ?? '').toString();
        if (swapPart.isNotEmpty) {
          final swapEntry = await _makeSwapEntry(ctx, swapPart);
          if (swapEntry == null) return const [];
          entries.add(swapEntry);
        }
        return entries;

      case 'manual':
        final manualPartitions =
            ctx.state['manualPartitions'] as List<dynamic>? ?? const [];
        final rootPart = manualPartitions
            .cast<Map<String, dynamic>?>()
            .firstWhere(
              (part) =>
                  part != null &&
                  part['isFreeSpace'] != true &&
                  part['mount'] == '/',
              orElse: () => null,
            );
        if (rootPart == null) {
          ctx.log('HATA: Manuel kurulum için root bölümü tanımlanmamış.');
          return const [];
        }

        final rootName = (rootPart['name'] ?? '').toString();
        final rootFs = _normalizeFsType((rootPart['type'] ?? '').toString());
        final rootEntry = await _makeFsEntry(
          ctx,
          device: rootName,
          mountPoint: '/',
          fsType: rootFs,
          options: _rootMountOptions(rootFs),
        );
        if (rootEntry == null) return const [];
        entries.add(rootEntry);

        final hasDedicatedHome = manualPartitions.any(
          (part) => part['isFreeSpace'] != true && part['mount'] == '/home',
        );
        if (rootFs == 'btrfs' && !hasDedicatedHome) {
          final homeEntry = await _makeFsEntry(
            ctx,
            device: rootName,
            mountPoint: '/home',
            fsType: 'btrfs',
            options: 'defaults,compress=zstd:1,subvol=@home',
          );
          if (homeEntry == null) return const [];
          entries.add(homeEntry);
        }

        final otherParts =
            manualPartitions
                .where(
                  (part) =>
                      part['isFreeSpace'] != true &&
                      part['mount'] != '/' &&
                      part['mount'] != 'unmounted' &&
                      (part['name'] ?? '').toString().isNotEmpty,
                )
                .cast<Map<String, dynamic>>()
                .toList()
              ..sort((a, b) {
                final mountA = (a['mount'] ?? '').toString();
                final mountB = (b['mount'] ?? '').toString();
                if (mountA == '[SWAP]') return 1;
                if (mountB == '[SWAP]') return -1;
                final depthCompare = _mountDepth(
                  mountA,
                ).compareTo(_mountDepth(mountB));
                if (depthCompare != 0) {
                  return depthCompare;
                }
                return mountA.compareTo(mountB);
              });

        for (final part in otherParts) {
          final mountPoint = (part['mount'] ?? 'unmounted').toString();
          final partName = (part['name'] ?? '').toString();
          if (mountPoint == '[SWAP]') {
            final swapEntry = await _makeSwapEntry(ctx, partName);
            if (swapEntry == null) return const [];
            entries.add(swapEntry);
            continue;
          }

          final fsType = _normalizeFsType((part['type'] ?? '').toString());
          final fsEntry = await _makeFsEntry(
            ctx,
            device: partName,
            mountPoint: mountPoint,
            fsType: fsType,
            options: _defaultMountOptions(fsType),
          );
          if (fsEntry == null) return const [];
          entries.add(fsEntry);
        }
        return entries;

      default:
        ctx.log('HATA: Bilinmeyen bölümleme yöntemi: $partitionMethod');
        return const [];
    }
  }

  Future<_FstabEntry?> _makeFsEntry(
    StageContext ctx, {
    required String device,
    required String mountPoint,
    required String fsType,
    required String options,
  }) async {
    final uuid = await _lookupUuid(ctx, device);
    if (uuid == null) return null;
    return _FstabEntry(
      uuid: uuid,
      mountPoint: mountPoint,
      fsType: fsType,
      options: options,
      dump: 0,
      pass: _fsckPass(fsType, mountPoint),
    );
  }

  Future<_FstabEntry?> _makeSwapEntry(StageContext ctx, String device) async {
    final uuid = await _lookupUuid(ctx, device);
    if (uuid == null) return null;
    return _FstabEntry(
      uuid: uuid,
      mountPoint: 'none',
      fsType: 'swap',
      options: 'defaults',
      dump: 0,
      pass: 0,
    );
  }

  Future<String?> _lookupUuid(StageContext ctx, String device) async {
    if (ctx.isMock) {
      final deviceId = device
          .split('/')
          .last
          .replaceAll(RegExp(r'[^A-Za-z0-9]'), '')
          .toUpperCase();
      return 'MOCK-$deviceId';
    }

    final result = await ctx.commandRunner.run('blkid', [
      '-s',
      'UUID',
      '-o',
      'value',
      device,
    ]);
    final uuid = result.stdout.trim();
    if (result.exitCode == 0 && uuid.isNotEmpty) {
      return uuid;
    }

    ctx.log('HATA: UUID okunamadı: $device');
    return null;
  }

  String _partitionPath(String disk, int partitionNumber) {
    final needsP =
        disk.contains('nvme') ||
        disk.contains('loop') ||
        disk.contains('mmcblk');
    return needsP ? '${disk}p$partitionNumber' : '$disk$partitionNumber';
  }

  String _normalizeFsType(String fsType) {
    switch (fsType) {
      case 'fat32':
      case 'vfat':
        return 'vfat';
      case 'linux-swap':
      case 'swap':
        return 'swap';
      default:
        return fsType;
    }
  }

  String _rootMountOptions(String fsType) {
    if (fsType == 'btrfs') {
      return 'defaults,compress=zstd:1,subvol=@';
    }
    return _defaultMountOptions(fsType);
  }

  String _defaultMountOptions(String fsType) {
    switch (fsType) {
      case 'btrfs':
        return 'defaults';
      case 'vfat':
        return 'umask=0077,shortname=winnt';
      case 'swap':
        return 'defaults';
      default:
        return 'defaults';
    }
  }

  int _fsckPass(String fsType, String mountPoint) {
    switch (fsType) {
      case 'ext4':
        return mountPoint == '/' ? 1 : 2;
      case 'vfat':
        return mountPoint == '/boot/efi' ? 2 : 0;
      default:
        return 0;
    }
  }

  int _mountDepth(String mountPoint) {
    return mountPoint.split('/').where((segment) => segment.isNotEmpty).length;
  }

  String _renderFstab(List<_FstabEntry> entries) {
    final buffer = StringBuffer()
      ..writeln('# /etc/fstab generated by ro-Installer')
      ..writeln('# <device>  <mount>  <type>  <options>  <dump>  <pass>');

    for (final entry in entries) {
      buffer.writeln(
        'UUID=${entry.uuid} ${entry.mountPoint} ${entry.fsType} ${entry.options} ${entry.dump} ${entry.pass}',
      );
    }

    return buffer.toString().trimRight();
  }
}

class _FstabEntry {
  const _FstabEntry({
    required this.uuid,
    required this.mountPoint,
    required this.fsType,
    required this.options,
    required this.dump,
    required this.pass,
  });

  final String uuid;
  final String mountPoint;
  final String fsType;
  final String options;
  final int dump;
  final int pass;
}
