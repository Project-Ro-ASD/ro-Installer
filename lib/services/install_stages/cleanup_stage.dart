import 'stage_context.dart';
import 'stage_result.dart';

/// AŞAMA 8: Temizlik (Cleanup)
///
/// Kurulum sonrası tüm bağlama noktalarını kaldırır
/// ve sistemi yeniden başlatmaya hazır hale getirir.
class CleanupStage {
  const CleanupStage();

  Future<StageResult> execute(StageContext ctx) async {
    ctx.log('════════════════════════════════════════════');
    ctx.log('[AŞAMA 8] Temizlik Başlatılıyor');
    ctx.log('════════════════════════════════════════════');

    ctx.onProgress(0.98, 'Sistem dosyaları korunuyor ve unmount işlemi başlatılıyor...');

    // Tüm bağlama noktalarını kaldır
    await ctx.runCmd('sh', ['-c', 'umount -R /mnt 2>/dev/null || true'], ctx.log, isMock: ctx.isMock);

    ctx.log('[AŞAMA 8] Temizlik tamamlandı. Sistem yeniden başlatmaya hazır.');
    return StageResult.ok('Temizlik tamamlandı.');
  }
}
