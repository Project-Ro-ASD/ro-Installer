import 'stage_context.dart';
import 'stage_result.dart';

/// AŞAMA 1: Disk Hazırlığı
///
/// Kurulum öncesi diski hazırlar:
/// - Tüm mevcut bağlantıları (mount) kaldırır
/// - Swap alanlarını kapatır
///
/// Bu aşama, disk üzerinde güvenli bir şekilde çalışılabilmesi
/// için ön koşulları sağlar.
class DiskPreparationStage {
  const DiskPreparationStage();

  Future<StageResult> execute(StageContext ctx) async {
    final selectedDisk = ctx.state['selectedDisk'] as String;

    ctx.log('════════════════════════════════════════════');
    ctx.log('[AŞAMA 1] Disk Hazırlığı Başlatılıyor: $selectedDisk');
    ctx.log('════════════════════════════════════════════');

    ctx.onProgress(0.02, 'Disk bağlantıları kontrol ediliyor...');

    // 1. Diskteki tüm bölümleri ayır (umount)
    ctx.log('Diskteki mevcut bağlantılar kaldırılıyor...');
    await ctx.runCmd(
      'sh', ['-c', 'umount -f $selectedDisk* 2>/dev/null || true'],
      ctx.log, isMock: ctx.isMock,
    );

    // 2. Takas alanlarını kapat
    ctx.log('Takas (swap) alanları kapatılıyor...');
    await ctx.runCmd('swapoff', ['-a'], ctx.log, isMock: ctx.isMock);

    ctx.log('[AŞAMA 1] Disk hazırlığı tamamlandı.');
    return StageResult.ok('Disk hazırlığı tamamlandı: $selectedDisk');
  }
}
