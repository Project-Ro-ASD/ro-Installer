import 'stage_context.dart';
import 'stage_result.dart';

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
    ctx.onProgress(0.88, 'EFI bağlama noktası doğrulanıyor...');

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
    ctx.onProgress(0.89, 'Boot parametreleri hazırlanıyor...');
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
    final partitionMethod = (ctx.state['partitionMethod'] ?? 'full').toString();
    final needsBtrfsRootflags =
        rootFs == 'btrfs' && partitionMethod != 'manual';
    final rootFlags = needsBtrfsRootflags ? ' rootflags=subvol=@' : '';
    final cmdlineWrite = await _requireCommand(ctx, 'sh', [
      '-c',
      'echo "root=UUID=$cmdlineUuid ro$rootFlags rhgb quiet" > /mnt/etc/kernel/cmdline',
    ], '/etc/kernel/cmdline yazılamadı.');
    if (cmdlineWrite != null) return cmdlineWrite;

    // ── 7.2: GRUB Yapılandırma Dosyası ──
    ctx.onProgress(0.90, 'GRUB2 yapılandırılıyor...');

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
GRUB_CMDLINE_LINUX="rhgb quiet"
GRUB_DISABLE_RECOVERY="true"
GRUB_ENABLE_BLSCFG=true
GRUB_DISABLE_OS_PROBER=false
EOF
      ''',
    ], '/etc/default/grub yazılamadı.');
    if (grubDefaultsWrite != null) return grubDefaultsWrite;

    // ── 7.3: Initramfs Yeniden Oluşturma (Dracut) — GRUB'DAN ÖNCE ──
    ctx.onProgress(0.92, 'Initramfs imajları güncelleniyor (Dracut)...');

    final dracutResult = await _requireCommand(ctx, 'chroot', [
      '/mnt',
      'dracut',
      '-f',
      '--regenerate-all',
    ], 'Dracut initramfs oluşturma başarısız.');
    if (dracutResult != null) return dracutResult;
    ctx.log('✓ Dracut initramfs başarıyla oluşturuldu.');

    // ── 7.4: BLS (Boot Loader Spec) Girişleri (kernel-install) ──
    ctx.onProgress(0.93, 'Bootloader girişleri oluşturuluyor (BLS)...');

    // Yüklü kernel versiyonunu bul ve kernel-install ile BLS .conf dosyalarını oluştur
    final kernelInstallResult = await _requireCommand(ctx, 'chroot', [
      '/mnt',
      'sh',
      '-c',
      'kver=\$(ls /lib/modules | head -1) && kernel-install add \$kver /lib/modules/\$kver/vmlinuz',
    ], 'kernel-install başarısız oldu.');
    if (kernelInstallResult != null) return kernelInstallResult;

    // ── 7.5: ESP stub ve EFI binary doğrulaması ──
    ctx.onProgress(0.94, 'EFI önyükleme zinciri doğrulanıyor...');

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

    final usesManagedBtrfsSubvolume =
        !hasSeparateBoot && rootFs == 'btrfs' && partitionMethod != 'manual';
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

export \$prefix
configfile \$prefix/grub.cfg
EOF
      ''',
    ], 'ESP grub.cfg yönlendirme dosyası yazılamadı.');
    if (failure != null) return failure;
    ctx.log('✓ EFI grub.cfg yönlendirme stub dosyası yazıldı.');

    // ── 7.6: GRUB Konfigürasyon Dosyası Üretimi — DRACUT'DAN SONRA ──
    ctx.onProgress(0.96, 'GRUB konfigürasyonu üretiliyor...');

    final grubMkconfigResult = await _requireCommand(ctx, 'chroot', [
      '/mnt',
      'grub2-mkconfig',
      '-o',
      '/boot/grub2/grub.cfg',
    ], 'grub2-mkconfig başarısız oldu.');
    if (grubMkconfigResult != null) return grubMkconfigResult;
    ctx.log('✓ GRUB konfigürasyonu üretildi.');

    // ── 7.7: EFI firmware boot kaydı ──
    ctx.onProgress(0.97, 'UEFI firmware boot girdisi yazılıyor...');
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
      'Fedora',
      '-l',
      r'\EFI\fedora\shimx64.efi',
    ], 'EFI boot kaydı oluşturulamadı.');
    if (failure != null) return failure;
    ctx.log('✓ UEFI firmware kaydı shimx64.efi için oluşturuldu.');

    ctx.log('[AŞAMA 7] Bootloader kurulumu tamamlandı.');
    return StageResult.ok('Bootloader kurulumu tamamlandı.');
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
}

class _EfiPartition {
  const _EfiPartition(this.disk, this.partition);

  final String disk;
  final String partition;
}
