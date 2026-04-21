import 'stage_context.dart';
import 'stage_result.dart';

/// AŞAMA 8: Kurulum Sonrası Doğrulama
///
/// Kurulumun "tamamlandı" sayılabilmesi için hedef sistemde
/// boot için kritik dosya ve girdileri doğrular:
/// - /etc/fstab mevcut mu
/// - /etc/kernel/cmdline mevcut mu
/// - BLS girdileri mevcut mu
/// - fstab sözdizimi doğrulanıyor mu
/// - Live ISO parametreleri hedef sisteme sızmış mı
/// - BTRFS tam kurulumlarında rootflags=subvol=@ mevcut mu
class PostInstallValidationStage {
  const PostInstallValidationStage();

  Future<StageResult> execute(StageContext ctx) async {
    ctx.log('════════════════════════════════════════════');
    ctx.log('[AŞAMA 8] Kurulum Sonrası Doğrulama Başlatılıyor');
    ctx.log('════════════════════════════════════════════');

    ctx.onProgress(0.97, 'Kurulu sistemin boot doğrulaması yapılıyor...');

    StageResult? failure = await _requireCommand(ctx, 'test', [
      '-f',
      '/mnt/etc/fstab',
    ], '/mnt/etc/fstab bulunamadı.');
    if (failure != null) return failure;

    failure = await _requireCommand(ctx, 'test', [
      '-f',
      '/mnt/etc/kernel/cmdline',
    ], '/mnt/etc/kernel/cmdline bulunamadı.');
    if (failure != null) return failure;

    failure = await _requireCommand(ctx, 'sh', [
      '-c',
      'ls /mnt/boot/loader/entries/*.conf >/dev/null 2>&1',
    ], 'BLS giriş dosyaları bulunamadı.');
    if (failure != null) return failure;

    failure = await _requireCommand(ctx, 'chroot', [
      '/mnt',
      'rpm',
      '-q',
      'kernel-core',
      'dracut',
      'grub2-efi-x64',
      'shim-x64',
    ], 'Boot için gerekli paketler hedef sistemde doğrulanamadı.');
    if (failure != null) return failure;

    failure = await _requireCommand(ctx, 'sh', [
      '-c',
      'ls /mnt/boot/vmlinuz-* >/dev/null 2>&1',
    ], 'Kernel dosyası /mnt/boot altında bulunamadı.');
    if (failure != null) return failure;

    failure = await _requireCommand(ctx, 'sh', [
      '-c',
      'ls /mnt/boot/initramfs-*.img >/dev/null 2>&1',
    ], 'Initramfs dosyası /mnt/boot altında bulunamadı.');
    if (failure != null) return failure;

    failure = await _requireCommand(
      ctx,
      'test',
      ['-f', '/mnt/boot/efi/EFI/fedora/shimx64.efi'],
      'EFI shim dosyası /mnt/boot/efi/EFI/fedora/shimx64.efi bulunamadı.',
    );
    if (failure != null) return failure;

    failure = await _requireCommand(
      ctx,
      'test',
      ['-f', '/mnt/boot/efi/EFI/fedora/grubx64.efi'],
      'EFI GRUB binary dosyası /mnt/boot/efi/EFI/fedora/grubx64.efi bulunamadı.',
    );
    if (failure != null) return failure;

    failure = await _requireCommand(
      ctx,
      'test',
      ['-f', '/mnt/boot/efi/EFI/fedora/grub.cfg'],
      'EFI GRUB stub dosyası /mnt/boot/efi/EFI/fedora/grub.cfg bulunamadı.',
    );
    if (failure != null) return failure;

    failure = await _requireCommand(
      ctx,
      'sh',
      [
        '-c',
        r'grep -q "configfile \$prefix/grub.cfg" /mnt/boot/efi/EFI/fedora/grub.cfg',
      ],
      'EFI GRUB stub dosyası /boot/grub2/grub.cfg yönlendirmesini içermiyor.',
    );
    if (failure != null) return failure;

    failure = await _requireCommand(ctx, 'sh', [
      '-c',
      'ls /mnt/boot/efi/EFI/fedora/* >/dev/null 2>&1',
    ], 'EFI boot dosyaları /mnt/boot/efi/EFI/fedora altında bulunamadı.');
    if (failure != null) return failure;

    failure = await _requireCommand(ctx, 'findmnt', [
      '--verify',
      '--tab-file',
      '/mnt/etc/fstab',
    ], '/etc/fstab doğrulaması başarısız.');
    if (failure != null) return failure;

    if (!await ctx.runCmd(
      'sh',
      [
        '-c',
        'if grep -R -E "rd.live.image|inst.stage2|CDLABEL|root=live:" /mnt/etc/kernel/cmdline /mnt/boot/loader/entries >/dev/null 2>&1; then exit 1; else exit 0; fi',
      ],
      ctx.log,
      isMock: ctx.isMock,
    )) {
      return StageResult.fail(
        'Live ISO boot parametreleri hedef sisteme sızmış görünüyor.',
      );
    }

    final rootFs = (ctx.state['fileSystem'] ?? 'btrfs').toString();
    final partitionMethod = (ctx.state['partitionMethod'] ?? 'full').toString();
    if (rootFs == 'btrfs' && partitionMethod != 'manual') {
      failure = await _requireCommand(ctx, 'sh', [
        '-c',
        'grep -q "rootflags=subvol=@" /mnt/etc/kernel/cmdline',
      ], 'BTRFS kurulumunda rootflags=subvol=@ eksik.');
      if (failure != null) return failure;
    }

    ctx.log('[AŞAMA 8] Kurulum sonrası doğrulama başarıyla tamamlandı.');
    return StageResult.ok('Kurulum sonrası doğrulama tamamlandı.');
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
}
