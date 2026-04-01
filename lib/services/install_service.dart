import 'dart:async';
import 'command_runner.dart';
import 'install_stages/install_stages.dart';

/// Kurulum Orkestratörü (Install Service)
///
/// Bu sınıf artık doğrudan kurulum mantığı içermez.
/// Bunun yerine, kurulum akışını 8 bağımsız aşamaya (stage) böler
/// ve her birini sırasıyla çalıştırır.
///
/// Aşamalar:
///   1. Disk Hazırlığı        [DiskPreparationStage]
///   2. Bölümleme             [PartitioningStage]
///   3. Biçimlendirme         [FormattingStage]
///   4. Bağlama               [MountingStage]
///   5. Dosya Kopyalama       [FileCopyStage]
///   6. Chroot Yapılandırma   [ChrootConfigStage]
///   7. Bootloader Kurulumu   [BootloaderStage]
///   8. Temizlik              [CleanupStage]
class InstallService {
  InstallService._();
  static final InstallService instance = InstallService._();
  final CommandRunner _commandRunner = CommandRunner.instance;

  // ── Aşama Nesneleri ──
  final _diskPreparation = const DiskPreparationStage();
  final _partitioning = const PartitioningStage();
  final _formatting = const FormattingStage();
  final _mounting = const MountingStage();
  final _fileCopy = const FileCopyStage();
  final _chrootConfig = const ChrootConfigStage();
  final _bootloader = const BootloaderStage();
  final _cleanup = const CleanupStage();

  /// Komut çalıştırma ve çıktıları canlı okuma.
  /// STDERR çıktısı biriktirilir ve hata durumunda tam olarak raporlanır.
  Future<bool> runCmd(String cmd, List<String> args, void Function(String) onLog, {bool isMock = false, List<int> allowedExitCodes = const [0]}) async {
    final result = await _commandRunner.run(
      cmd,
      args,
      isMock: isMock,
      onLog: (event) => onLog(event.displayMessage),
    );

    if (!result.started) {
      onLog("═══════════════════════════════════════════");
      onLog("[İSTİSNA] Komut çalıştırılamadı: $cmd");
      onLog("[İSTİSNA] Sebep: ${result.stderr}");
      onLog("[İSTİSNA] Komut sisteminizde kurulu olmayabilir (PATH kontrol edin).");
      onLog("═══════════════════════════════════════════");
      return false;
    }

    if (!allowedExitCodes.contains(result.exitCode)) {
      final errorDetail = result.stderr.isNotEmpty
          ? result.stderr
          : (result.stdout.isNotEmpty ? result.stdout : 'Ek bilgi yok');
      onLog("═══════════════════════════════════════════");
      onLog("[HATA] Komut başarısız oldu!");
      onLog("[HATA] Komut: ${result.commandLine}");
      onLog("[HATA] Çıkış Kodu: ${result.exitCode}");
      onLog("[HATA] Detay: $errorDetail");
      onLog("═══════════════════════════════════════════");
      return false;
    }

    return true;
  }

  // Ana kurulum motoru (Orkestratör)
  Future<bool> runInstall(
    Map<String, dynamic> state,
    void Function(double progress, String status) onProgress,
    void Function(String message) onTechnicalLog, {
    bool isMock = false,
  }) async {
    void log(String msg) {
       onTechnicalLog(msg);
    }

    try {
      // ── Ortak bağlam (context) nesnesi oluştur ──
      final ctx = StageContext(
        state: state,
        log: log,
        onProgress: onProgress,
        commandRunner: _commandRunner,
        runCmd: runCmd,
        isMock: isMock,
      );

      // ══════════════════════════════════════════════
      //  AŞAMA 1: Disk Hazırlığı
      // ══════════════════════════════════════════════
      log('');
      log('▶▶▶ AŞAMA 1/8: Disk Hazırlığı ◀◀◀');
      final stage1 = await _diskPreparation.execute(ctx);
      if (!stage1.success) {
        log('[FATAL] Aşama 1 başarısız: ${stage1.message}');
        return false;
      }
      log('✓ Aşama 1 tamamlandı: ${stage1.message}');

      // ══════════════════════════════════════════════
      //  AŞAMA 2: Bölümleme
      // ══════════════════════════════════════════════
      log('');
      log('▶▶▶ AŞAMA 2/8: Bölümleme ◀◀◀');
      final stage2 = await _partitioning.execute(ctx);
      if (!stage2.success) {
        log('[FATAL] Aşama 2 başarısız: ${stage2.message}');
        return false;
      }
      log('✓ Aşama 2 tamamlandı: ${stage2.message}');

      // ══════════════════════════════════════════════
      //  AŞAMA 3: Biçimlendirme
      // ══════════════════════════════════════════════
      log('');
      log('▶▶▶ AŞAMA 3/8: Biçimlendirme ◀◀◀');
      final stage3 = await _formatting.execute(ctx);
      if (!stage3.success) {
        log('[FATAL] Aşama 3 başarısız: ${stage3.message}');
        return false;
      }
      log('✓ Aşama 3 tamamlandı: ${stage3.message}');

      // ══════════════════════════════════════════════
      //  AŞAMA 4: Bağlama
      // ══════════════════════════════════════════════
      log('');
      log('▶▶▶ AŞAMA 4/8: Bağlama ◀◀◀');
      final stage4 = await _mounting.execute(ctx);
      if (!stage4.success) {
        log('[FATAL] Aşama 4 başarısız: ${stage4.message}');
        return false;
      }
      log('✓ Aşama 4 tamamlandı: ${stage4.message}');

      // ══════════════════════════════════════════════
      //  AŞAMA 5: Dosya Kopyalama
      // ══════════════════════════════════════════════
      log('');
      log('▶▶▶ AŞAMA 5/8: Dosya Kopyalama ◀◀◀');
      final stage5 = await _fileCopy.execute(ctx);
      if (!stage5.success) {
        log('[FATAL] Aşama 5 başarısız: ${stage5.message}');
        return false;
      }
      log('✓ Aşama 5 tamamlandı: ${stage5.message}');

      // ══════════════════════════════════════════════
      //  AŞAMA 6: Chroot Yapılandırma
      // ══════════════════════════════════════════════
      log('');
      log('▶▶▶ AŞAMA 6/8: Chroot Yapılandırma ◀◀◀');
      final stage6 = await _chrootConfig.execute(ctx);
      if (!stage6.success) {
        log('[FATAL] Aşama 6 başarısız: ${stage6.message}');
        return false;
      }
      log('✓ Aşama 6 tamamlandı: ${stage6.message}');

      // ══════════════════════════════════════════════
      //  AŞAMA 7: Bootloader Kurulumu
      // ══════════════════════════════════════════════
      log('');
      log('▶▶▶ AŞAMA 7/8: Bootloader Kurulumu ◀◀◀');
      final stage7 = await _bootloader.execute(ctx);
      if (!stage7.success) {
        log('[FATAL] Aşama 7 başarısız: ${stage7.message}');
        return false;
      }
      log('✓ Aşama 7 tamamlandı: ${stage7.message}');

      // ══════════════════════════════════════════════
      //  AŞAMA 8: Temizlik
      // ══════════════════════════════════════════════
      log('');
      log('▶▶▶ AŞAMA 8/8: Temizlik ◀◀◀');
      final stage8 = await _cleanup.execute(ctx);
      if (!stage8.success) {
        log('[FATAL] Aşama 8 başarısız: ${stage8.message}');
        return false;
      }
      log('✓ Aşama 8 tamamlandı: ${stage8.message}');

      // ══════════════════════════════════════════════
      //  KURULUM BAŞARIYLA TAMAMLANDI
      // ══════════════════════════════════════════════
      log('');
      log('══════════════════════════════════════════');
      log('✅ TÜM AŞAMALAR BAŞARIYLA TAMAMLANDI');
      log('══════════════════════════════════════════');

      onProgress(1.0, 'Kurulum Hatasız Tamamlandı! Sistemi Yeniden Başlatabilirsiniz.');
      return true;

    } catch (e) {
      log('FATAL CATCH: $e');
      return false;
    }
  }
}
