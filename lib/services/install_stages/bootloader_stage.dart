import 'stage_context.dart';
import 'stage_result.dart';

const bootloaderKernelInstallScript = r'''
set -e
found=0
preferred_kver=""
preferred_image=""
stable_module_versions="$(rpm -ql ro-kernel-stable-core ro-kernel-stable-modules 2>/dev/null | awk -F/ '
  $2 == "lib" && $3 == "modules" && $4 != "" { print $4 }
  $2 == "usr" && $3 == "lib" && $4 == "modules" && $5 != "" { print $5 }
' | sort -u)"
experimental_module_versions="$(rpm -ql ro-kernel-experimental-core ro-kernel-experimental-modules 2>/dev/null | awk -F/ '
  $2 == "lib" && $3 == "modules" && $4 != "" { print $4 }
  $2 == "usr" && $3 == "lib" && $4 == "modules" && $5 != "" { print $5 }
' | sort -u)"
ro_module_versions="$(printf '%s\n%s\n' "$stable_module_versions" "$experimental_module_versions" | awk 'NF' | sort -u)"
is_ro_kernel() {
  case "$1" in
    *ro_stable*|*ro-stable*|*ro_experimental*|*ro-experimental*) return 0 ;;
  esac
  if [ -n "$ro_module_versions" ] && printf '%s\n' "$ro_module_versions" | grep -Fxq "$1"; then
    return 0
  fi
  return 1
}
is_stable_kernel() {
  case "$1" in
    *ro_stable*|*ro-stable*) return 0 ;;
  esac
  if [ -n "$stable_module_versions" ] && printf '%s\n' "$stable_module_versions" | grep -Fxq "$1"; then
    return 0
  fi
  return 1
}
for kver in $(find /lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -V); do
  kdir="/lib/modules/$kver"
  image="/boot/vmlinuz-$kver"
  if [ ! -f "$image" ]; then
    image="$kdir/vmlinuz"
  fi
  if ! is_ro_kernel "$kver"; then
    echo "Non-Ro kernel module directory found: $kver" >&2
    exit 1
  fi
  if [ ! -f "$image" ]; then
    echo "kernel image not found for $kver" >&2
    exit 1
  fi
  kernel-install add "$kver" "$image"
  if is_stable_kernel "$kver"; then
    preferred_kver="$kver"
    preferred_image="$image"
  elif [ -z "$preferred_image" ]; then
    preferred_kver="$kver"
    preferred_image="$image"
  fi
  found=1
done
[ "$found" -eq 1 ]
if [ -z "$preferred_image" ]; then
  echo "No Ro kernel found; refusing to generate a stock Fedora boot target" >&2
  exit 1
fi
if [ -n "$preferred_image" ] && command -v grubby >/dev/null 2>&1; then
  grubby --set-default "$preferred_image" || true
  echo "preferred default kernel: $preferred_kver"
fi
''';

const bootloaderDracutScript = r'''
set -e
found=0
stable_module_versions="$(rpm -ql ro-kernel-stable-core ro-kernel-stable-modules 2>/dev/null | awk -F/ '
  $2 == "lib" && $3 == "modules" && $4 != "" { print $4 }
  $2 == "usr" && $3 == "lib" && $4 == "modules" && $5 != "" { print $5 }
' | sort -u)"
experimental_module_versions="$(rpm -ql ro-kernel-experimental-core ro-kernel-experimental-modules 2>/dev/null | awk -F/ '
  $2 == "lib" && $3 == "modules" && $4 != "" { print $4 }
  $2 == "usr" && $3 == "lib" && $4 == "modules" && $5 != "" { print $5 }
' | sort -u)"
ro_module_versions="$(printf '%s\n%s\n' "$stable_module_versions" "$experimental_module_versions" | awk 'NF' | sort -u)"
is_ro_kernel() {
  case "$1" in
    *ro_stable*|*ro-stable*|*ro_experimental*|*ro-experimental*) return 0 ;;
  esac
  if [ -n "$ro_module_versions" ] && printf '%s\n' "$ro_module_versions" | grep -Fxq "$1"; then
    return 0
  fi
  return 1
}
for kver in $(find /lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -V); do
  if ! is_ro_kernel "$kver"; then
    echo "Skipping non-Ro kernel initramfs generation: $kver" >&2
    continue
  fi
  echo "Generating initramfs for Ro kernel: $kver"
  dracut -f "/boot/initramfs-$kver.img" "$kver"
  found=1
done
[ "$found" -eq 1 ]
''';

/// AŞAMA 7: Bootloader (Önyükleyici Kurulumu)
///
/// Fedora UEFI boot zincirini kurar ve yapılandırır:
/// - /etc/default/grub dosyasını temiz bir şekilde yazar
/// - dracut ile initramfs imajlarını yeniden oluşturur (grub'dan ÖNCE)
/// - kernel-install ile BLS girdilerini üretir
/// - ESP üzerindeki grub.cfg stub dosyasını /boot/grub2/grub.cfg'ye yönlendirir
/// - UEFI firmware kaydını shimx64.efi'ye yazar
/// - grub2-mkconfig ile grub.cfg üretir
///
/// Fedora'da UEFI/Secure Boot akışında grub2-install doğru araç değildir.
/// İmzalı shim + grub EFI binary'leri paketlerden gelir; installer yalnızca
/// doğru grub.cfg stub'unu ve firmware boot kaydını hazırlamalıdır.
class BootloaderStage {
  const BootloaderStage();

  Future<StageResult> execute(StageContext ctx) async {
    ctx.log('════════════════════════════════════════════');
    ctx.log('[AŞAMA 7] Bootloader Kurulumu Başlatılıyor');
    ctx.log('════════════════════════════════════════════');

    // ── 7.0: EFI Bağlama Doğrulaması ──
    ctx.progress(
      0.88,
      'stage_progress_boot_verify_efi',
      'EFI bağlama noktası doğrulanıyor...',
    );

    final efiCheckResult = await ctx.commandRunner.run('findmnt', [
      '-rn',
      '-o',
      'SOURCE',
      '/mnt/boot/efi',
    ]);
    if (efiCheckResult.exitCode != 0 || efiCheckResult.stdout.trim().isEmpty) {
      if (!ctx.isMock) {
        ctx.log('HATA: /mnt/boot/efi bağlı değil! Bootloader kurulamaz.');
        return StageResult.fail('EFI bölümü /mnt/boot/efi\'ye bağlı değil.');
      }
    }
    ctx.log('EFI doğrulandı: ${efiCheckResult.stdout.trim()} → /mnt/boot/efi');

    // ── 7.1: Root UUID Tespiti ve Kernel Cmdline ──
    ctx.progress(
      0.89,
      'stage_progress_boot_prepare_args',
      'Boot parametreleri hazırlanıyor...',
    );
    final uuidResult = await ctx.commandRunner.run('findmnt', [
      '-rn',
      '-o',
      'UUID',
      '/mnt',
    ]);
    final rootUuid = uuidResult.stdout.trim();
    if (rootUuid.isEmpty && !ctx.isMock) {
      return StageResult.fail('Root bölümü UUID tespiti başarısız.');
    }
    final cmdlineUuid = ctx.isMock ? '1234-abcd' : rootUuid;
    final rootFs = (ctx.state['fileSystem'] ?? 'btrfs').toString();
    final needsBtrfsRootflags = rootFs == 'btrfs';
    final rootFlags = needsBtrfsRootflags ? ' rootflags=subvol=@' : '';
    final swapDevice = _resolveSwapDevice(ctx.state);
    final resumeUuid = swapDevice == null
        ? null
        : await _lookupDeviceUuid(ctx, swapDevice);
    if (swapDevice != null && resumeUuid == null && !ctx.isMock) {
      return StageResult.fail(
        'Hibernate resume için SWAP UUID tespit edilemedi: $swapDevice',
      );
    }
    final resumeArg = resumeUuid == null ? '' : ' resume=UUID=$resumeUuid';
    final grubCmdline = resumeUuid == null
        ? 'rhgb quiet'
        : 'resume=UUID=$resumeUuid rhgb quiet';
    final cmdlineWrite = await _requireCommand(ctx, 'sh', [
      '-c',
      'echo "root=UUID=$cmdlineUuid ro$rootFlags$resumeArg rhgb quiet" > /mnt/etc/kernel/cmdline',
    ], '/etc/kernel/cmdline yazılamadı.');
    if (cmdlineWrite != null) return cmdlineWrite;

    // ── 7.2: GRUB Yapılandırma Dosyası ──
    ctx.progress(
      0.90,
      'stage_progress_boot_configure_grub',
      'GRUB2 yapılandırılıyor...',
    );

    // LiveCD label hatalarından temizleyerek yaz
    final grubDefaultsWrite = await _requireCommand(ctx, 'sh', [
      '-c',
      '''
cat > /mnt/etc/default/grub << 'EOF'
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="\$(sed 's, release .*\$,,g' /etc/system-release)"
GRUB_DEFAULT=saved
GRUB_DISABLE_SUBMENU=true
GRUB_TERMINAL_OUTPUT="console"
GRUB_CMDLINE_LINUX="$grubCmdline"
GRUB_DISABLE_RECOVERY="true"
GRUB_ENABLE_BLSCFG=true
GRUB_DISABLE_OS_PROBER=false
EOF
      ''',
    ], '/etc/default/grub yazılamadı.');
    if (grubDefaultsWrite != null) return grubDefaultsWrite;

    // ── 7.3: Initramfs Yeniden Oluşturma (Dracut) — GRUB'DAN ÖNCE ──
    ctx.progress(
      0.92,
      'stage_progress_boot_update_initramfs',
      'Initramfs imajları güncelleniyor (Dracut)...',
    );

    final dracutResult = await _requireCommand(ctx, 'chroot', [
      '/mnt',
      'sh',
      '-c',
      bootloaderDracutScript,
    ], 'Dracut initramfs oluşturma başarısız.');
    if (dracutResult != null) return dracutResult;
    ctx.log('✓ Dracut initramfs başarıyla oluşturuldu.');

    // ── 7.4: BLS (Boot Loader Spec) Girişleri (kernel-install) ──
    ctx.progress(
      0.93,
      'stage_progress_boot_create_bls',
      'Bootloader girişleri oluşturuluyor (BLS)...',
    );

    // Yüklü kernel sürümlerini bul ve her biri için BLS .conf dosyası oluştur.
    // Ro kernel paketleri /boot/vmlinuz-$kver üretir; bazı Fedora akışlarında
    // /lib/modules/$kver/vmlinuz da bulunabilir.
    final kernelInstallResult = await _requireCommand(ctx, 'chroot', [
      '/mnt',
      'sh',
      '-c',
      bootloaderKernelInstallScript,
    ], 'kernel-install başarısız oldu.');
    if (kernelInstallResult != null) return kernelInstallResult;

    // ── 7.5: ESP stub ve EFI binary doğrulaması ──
    ctx.progress(
      0.94,
      'stage_progress_boot_validate_chain',
      'EFI önyükleme zinciri doğrulanıyor...',
    );

    StageResult? failure = await _requireCommand(ctx, 'test', [
      '-f',
      '/mnt/boot/efi/EFI/fedora/shimx64.efi',
    ], 'shimx64.efi ESP üzerinde bulunamadı.');
    if (failure != null) return failure;

    failure = await _requireCommand(ctx, 'test', [
      '-f',
      '/mnt/boot/efi/EFI/fedora/grubx64.efi',
    ], 'grubx64.efi ESP üzerinde bulunamadı.');
    if (failure != null) return failure;

    final rootSourceResult = await ctx.commandRunner.run('findmnt', [
      '-rn',
      '-o',
      'SOURCE',
      '/mnt',
    ]);
    final bootSourceResult = await ctx.commandRunner.run('findmnt', [
      '-rn',
      '-o',
      'SOURCE',
      '/mnt/boot',
    ]);
    final bootUuidResult = await ctx.commandRunner.run('findmnt', [
      '-rn',
      '-o',
      'UUID',
      '/mnt/boot',
    ]);

    final rootSource = rootSourceResult.stdout.trim();
    final bootSource = bootSourceResult.stdout.trim();
    final bootUuid = bootUuidResult.stdout.trim();
    final hasSeparateBoot =
        bootSourceResult.exitCode == 0 &&
        bootSource.isNotEmpty &&
        bootSource != rootSource;

    if (hasSeparateBoot && bootUuid.isEmpty && !ctx.isMock) {
      return StageResult.fail('/boot için GRUB prefix UUID tespiti başarısız.');
    }

    final usesManagedBtrfsSubvolume = !hasSeparateBoot && rootFs == 'btrfs';
    final prefixPath = hasSeparateBoot
        ? '/grub2'
        : (usesManagedBtrfsSubvolume ? '/@/boot/grub2' : '/boot/grub2');
    final prefixUuid = ctx.isMock
        ? '5678-efgh'
        : (hasSeparateBoot ? bootUuid : rootUuid);

    failure = await _requireCommand(ctx, 'sh', [
      '-c',
      '''
cat > /mnt/boot/efi/EFI/fedora/grub.cfg << 'EOF'
search --no-floppy --fs-uuid --set=dev $prefixUuid
set prefix=(\$dev)$prefixPath

export prefix
configfile \$prefix/grub.cfg
EOF
      ''',
    ], 'ESP grub.cfg yönlendirme dosyası yazılamadı.');
    if (failure != null) return failure;
    ctx.log('✓ EFI grub.cfg yönlendirme stub dosyası yazıldı.');

    // ── 7.6: GRUB Konfigürasyon Dosyası Üretimi — DRACUT'DAN SONRA ──
    ctx.progress(
      0.96,
      'stage_progress_boot_generate_grub_config',
      'GRUB konfigürasyonu üretiliyor...',
    );

    final grubMkconfigResult = await _requireCommand(ctx, 'chroot', [
      '/mnt',
      'grub2-mkconfig',
      '-o',
      '/boot/grub2/grub.cfg',
    ], 'grub2-mkconfig başarısız oldu.');
    if (grubMkconfigResult != null) return grubMkconfigResult;
    ctx.log('✓ GRUB konfigürasyonu üretildi.');

    // ── 7.7: EFI firmware boot kaydı ──
    ctx.progress(
      0.97,
      'stage_progress_boot_write_firmware_entry',
      'UEFI firmware boot girdisi yazılıyor...',
    );
    final efiDevice = _parseEfiPartition(efiCheckResult.stdout.trim());
    if (efiDevice == null && !ctx.isMock) {
      return StageResult.fail(
        'EFI bölüm aygıtı ayrıştırılamadı: ${efiCheckResult.stdout.trim()}',
      );
    }

    final efiDisk = ctx.isMock ? '/dev/vda' : efiDevice!.disk;
    final efiPartNum = ctx.isMock ? '1' : efiDevice!.partition;
    failure = await _requireCommand(ctx, 'efibootmgr', [
      '-c',
      '-d',
      efiDisk,
      '-p',
      efiPartNum,
      '-L',
      'Ro-ASD',
      '-l',
      r'\EFI\fedora\shimx64.efi',
    ], 'EFI boot kaydı oluşturulamadı.');
    if (failure != null) return failure;
    ctx.log('✓ UEFI firmware kaydı shimx64.efi için oluşturuldu.');

    ctx.log('[AŞAMA 7] Bootloader kurulumu tamamlandı.');
    return StageResult.ok(
      ctx.t('stage_result_bootloader_done', 'Bootloader kurulumu tamamlandı.'),
    );
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

  _EfiPartition? _parseEfiPartition(String device) {
    if (!device.startsWith('/dev/')) return null;

    final nvmeOrMmc = RegExp(
      r'^(/dev/(?:nvme\d+n\d+|mmcblk\d+|loop\d+))p(\d+)$',
    );
    final classic = RegExp(r'^(/dev/[a-zA-Z]+)(\d+)$');

    final nvmeMatch = nvmeOrMmc.firstMatch(device);
    if (nvmeMatch != null) {
      return _EfiPartition(nvmeMatch.group(1)!, nvmeMatch.group(2)!);
    }

    final classicMatch = classic.firstMatch(device);
    if (classicMatch != null) {
      return _EfiPartition(classicMatch.group(1)!, classicMatch.group(2)!);
    }

    return null;
  }

  String? _resolveSwapDevice(Map<String, dynamic> state) {
    final resolved = (state['_resolvedSwapPart'] ?? '').toString();
    if (resolved.isNotEmpty) {
      return resolved;
    }

    final partitionMethod = (state['partitionMethod'] ?? 'full').toString();
    if (partitionMethod == 'full') {
      final selectedDisk = (state['selectedDisk'] ?? '').toString();
      if (selectedDisk.isNotEmpty) {
        return _partitionPath(selectedDisk, 2);
      }
    }

    if (partitionMethod == 'manual') {
      final manualPartitions =
          state['manualPartitions'] as List<dynamic>? ?? const [];
      for (final part in manualPartitions) {
        if (part is Map<String, dynamic> &&
            part['isFreeSpace'] != true &&
            part['mount'] == '[SWAP]') {
          final name = (part['name'] ?? '').toString();
          if (name.isNotEmpty) {
            return name;
          }
        }
      }
    }

    if (partitionMethod == 'free_space') {
      return null;
    }

    return null;
  }

  Future<String?> _lookupDeviceUuid(StageContext ctx, String device) async {
    if (ctx.isMock) {
      return 'mock-swap-uuid';
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
    return null;
  }

  String _partitionPath(String disk, int partitionNumber) {
    final needsP =
        disk.contains('nvme') ||
        disk.contains('loop') ||
        disk.contains('mmcblk');
    return needsP ? '${disk}p$partitionNumber' : '$disk$partitionNumber';
  }
}

class _EfiPartition {
  const _EfiPartition(this.disk, this.partition);

  final String disk;
  final String partition;
}
