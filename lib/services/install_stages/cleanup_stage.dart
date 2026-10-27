import 'stage_context.dart';
import 'stage_result.dart';

/// AŞAMA 9: Temizlik (Cleanup)
///
/// Kurulum sonrası tüm bağlama noktalarını kaldırır
/// ve sistemi yeniden başlatmaya hazır hale getirir.
class CleanupStage {
  const CleanupStage();

  Future<StageResult> execute(StageContext ctx) async {
    ctx.log('════════════════════════════════════════════');
    ctx.log('[AŞAMA 9] Temizlik Başlatılıyor');
    ctx.log('════════════════════════════════════════════');

    ctx.progress(
      0.98,
      'stage_progress_cleanup_unmount',
      'Sistem dosyaları korunuyor ve unmount işlemi başlatılıyor...',
    );

    final report = await ctx.mountSession?.cleanup();
    if (report == null || !report.success) {
      return StageResult.fail(
        'Kurulum oturumu bağlantıları güvenli biçimde kapatılamadı.',
      );
    }

    ctx.log('[AŞAMA 9] Temizlik tamamlandı. Sistem yeniden başlatmaya hazır.');
    return StageResult.ok(
      ctx.t('stage_result_cleanup_done', 'Temizlik tamamlandı.'),
    );
  }
}
