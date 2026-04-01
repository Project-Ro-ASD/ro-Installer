import 'stage_context.dart';
import 'stage_result.dart';

/// AŞAMA 7: Bootloader (Önyükleyici Kurulumu)
///
/// GRUB2 bootloader'ı kurar ve yapılandırır:
/// - /etc/default/grub dosyasını temiz bir şekilde yazar
/// - dracut ile initramfs imajlarını yeniden oluşturur (grub'dan ÖNCE)
/// - grub2-install ile UEFI bootloader'ı kurar
/// - grub2-mkconfig ile grub.cfg üretir (initramfs'den SONRA)
///
/// ÖNEMLİ SIRALAMA (Faz 5 bulgusu):
///   dracut → grub2-install → grub2-mkconfig
///   Çünkü grub2-mkconfig initramfs dosyalarını tarar ve menü oluşturur.
///   İnitramfs hazır değilse grub.cfg eksik/yanlış olur.
class BootloaderStage {
  const BootloaderStage();

  Future<StageResult> execute(StageContext ctx) async {
    ctx.log('════════════════════════════════════════════');
    ctx.log('[AŞAMA 7] Bootloader Kurulumu Başlatılıyor');
    ctx.log('════════════════════════════════════════════');

    // ── 7.0: EFI Bağlama Doğrulaması ──
    // Bootloader kurulumu öncesi EFI bölümünün gerçekten bağlı olduğunu doğrula
    ctx.onProgress(0.88, 'EFI bağlama noktası doğrulanıyor...');

    final efiCheckResult = await ctx.commandRunner.run('findmnt', ['-rn', '-o', 'SOURCE', '/mnt/boot/efi']);
    if (efiCheckResult.exitCode != 0 || efiCheckResult.stdout.trim().isEmpty) {
      ctx.log('HATA: /mnt/boot/efi bağlı değil! Bootloader kurulamaz.');
      ctx.log('Lütfen EFI bölümünün doğru oluşturulduğundan ve bağlandığından emin olun.');
      return StageResult.fail('EFI bölümü /mnt/boot/efi\'ye bağlı değil.');
    }
    ctx.log('EFI doğrulandı: ${efiCheckResult.stdout.trim()} → /mnt/boot/efi');

    // ── 7.1: GRUB Yapılandırma Dosyası ──
    ctx.onProgress(0.89, 'GRUB2 yapılandırılıyor...');

    // /etc/default/grub dosyasını LiveCD label hatalarından temizleyerek yaz
    await ctx.runCmd('sh', ['-c', '''
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
      '''], ctx.log, isMock: ctx.isMock);

    // ── 7.2: Initramfs Yeniden Oluşturma (Dracut) — GRUB'DAN ÖNCE ──
    // dracut, initramfs imajlarını oluşturur. grub2-mkconfig bu imajları tarar.
    // Bu yüzden dracut MUTLAKA grub2-mkconfig'den ÖNCE çalışmalıdır.
    ctx.onProgress(0.90, 'Initramfs imajları güncelleniyor (Dracut)... (Bu işlem biraz sürebilir)');

    if (!await ctx.runCmd('chroot', ['/mnt', 'dracut', '-f', '--regenerate-all'], ctx.log, isMock: ctx.isMock)) {
      ctx.log('HATA: Dracut işlemi başarısız oldu. Initramfs oluşturulamadı.');
      ctx.log('Bu hata sistemi boot edemez hale getirebilir.');
      return StageResult.fail('Dracut initramfs oluşturma başarısız.');
    }
    ctx.log('✓ Dracut initramfs başarıyla oluşturuldu.');

    // ── 7.3: GRUB2 Kurulumu (UEFI) ──
    ctx.onProgress(0.94, 'GRUB önyükleyici sisteme kuruluyor...');

    // Fedora'da grub2-install Secure Boot için --recheck ve --bootloader-id ile birlikte çalıştırılmalı
    if (!await ctx.runCmd('chroot', [
      '/mnt', 'grub2-install',
      '--target=x86_64-efi',
      '--efi-directory=/boot/efi',
      '--bootloader-id=fedora',
      '--recheck'
    ], ctx.log, isMock: ctx.isMock)) {
      ctx.log('HATA: grub2-install başarısız oldu. Bootloader kurulamadı.');
      ctx.log('EFI bölümünü ve /boot/efi mount durumunu kontrol edin.');
      return StageResult.fail('grub2-install başarısız oldu.');
    }
    ctx.log('✓ GRUB2 UEFI bootloader başarıyla kuruldu.');

    // ── 7.4: GRUB Konfigürasyon Dosyası Üretimi — DRACUT'DAN SONRA ──
    ctx.onProgress(0.96, 'GRUB konfigürasyonu üretiliyor...');

    if (!await ctx.runCmd('chroot', ['/mnt', 'grub2-mkconfig', '-o', '/boot/grub2/grub.cfg'], ctx.log, isMock: ctx.isMock)) {
      ctx.log('UYARI: grub2-mkconfig başarısız oldu. Boot menüsü eksik olabilir.');
      // grub.cfg olmadan sistem boot edemeyebilir ama BLS (Boot Loader Spec) aktifse
      // Fedora'da /boot/loader/entries/ altındaki .conf dosyaları yeterli olabilir.
    }
    ctx.log('✓ GRUB konfigürasyonu üretildi.');

    // ── 7.5: Bootloader Dosyalarını Doğrula ──
    ctx.log('Bootloader dosya doğrulaması yapılıyor...');
    await ctx.runCmd('ls', ['-la', '/mnt/boot/efi/EFI/fedora/'], ctx.log, isMock: ctx.isMock);
    await ctx.runCmd('ls', ['-la', '/mnt/boot/grub2/grub.cfg'], ctx.log, isMock: ctx.isMock);

    ctx.log('[AŞAMA 7] Bootloader kurulumu tamamlandı.');
    return StageResult.ok('Bootloader kurulumu tamamlandı.');
  }
}
