import 'dart:async';
import 'command_runner.dart';
import 'install_stages/install_stages.dart';
import 'install_artifact_collector.dart';
import 'install_localizer.dart';

/// Kurulum Orkestratörü (Install Service)
///
/// Bu sınıf artık doğrudan kurulum mantığı içermez.
/// Bunun yerine, kurulum akışını 9 bağımsız aşamaya (stage) böler
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
///   8. Kurulum Sonrası Doğrulama [PostInstallValidationStage]
///   9. Temizlik              [CleanupStage]
class InstallService {
  final CommandRunner _commandRunner;
  late final InstallArtifactCollector _artifactCollector;

  InstallService({CommandRunner? commandRunner})
    : _commandRunner = commandRunner ?? CommandRunner.instance {
    _artifactCollector = InstallArtifactCollector(
      commandRunner: _commandRunner,
    );
  }

  /// Varsayılan singleton erişimi (geriye uyumluluk için)
  static final InstallService instance = InstallService();

  // ── Aşama Nesneleri ──
  final _diskPreparation = const DiskPreparationStage();
  final _partitioning = const PartitioningStage();
  final _formatting = const FormattingStage();
  final _mounting = const MountingStage();
  final _fileCopy = const FileCopyStage();
  final _chrootConfig = const ChrootConfigStage();
  final _bootloader = const BootloaderStage();
  final _postInstallValidation = const PostInstallValidationStage();
  final _cleanup = const CleanupStage();

  /// Komut çalıştırma ve çıktıları canlı okuma.
  /// STDERR çıktısı biriktirilir ve hata durumunda tam olarak raporlanır.
  Future<bool> runCmd(
    String cmd,
    List<String> args,
    void Function(String) onLog, {
    bool isMock = false,
    List<int> allowedExitCodes = const [0],
  }) async {
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
      onLog(
        "[İSTİSNA] Komut sisteminizde kurulu olmayabilir (PATH kontrol edin).",
      );
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
    InstallTranslator? translate,
  }) async {
    void log(String msg) {
      onTechnicalLog(msg);
    }

    final localizer = InstallLocalizer(translate: translate);

    String t(
      String key,
      String fallback, [
      Map<String, String> placeholders = const {},
    ]) {
      return localizer.t(key, fallback, placeholders);
    }

    void stageBanner(int index, String key, String fallback) {
      final stageName = t(key, fallback);
      log('');
      log(
        t('install_log_stage_banner', '▶▶▶ AŞAMA {index}/9: {stage} ◀◀◀', {
          'index': index.toString(),
          'stage': stageName,
        }),
      );
    }

    void stageFailed(int index, StageResult result) {
      log(
        t(
          'install_log_stage_failed',
          '[FATAL] Aşama {index} başarısız: {message}',
          {'index': index.toString(), 'message': result.message},
        ),
      );
    }

    void stageDone(int index, StageResult result) {
      log(
        t('install_log_stage_done', '✓ Aşama {index} tamamlandı: {message}', {
          'index': index.toString(),
          'message': result.message,
        }),
      );
    }

    try {
      // ── Ortak bağlam (context) nesnesi oluştur ──
      final ctx = StageContext(
        state: state,
        log: log,
        onProgress: onProgress,
        commandRunner: _commandRunner,
        runCmd: runCmd,
        localizer: localizer,
        isMock: isMock,
      );

      // ══════════════════════════════════════════════
      //  AŞAMA 1: Disk Hazırlığı
      // ══════════════════════════════════════════════
      stageBanner(1, 'install_stage_disk_preparation', 'Disk Hazırlığı');
      final stage1 = await _diskPreparation.execute(ctx);
      if (!stage1.success) {
        stageFailed(1, stage1);
        await _artifactCollector.collectDiagnostics(
          log,
          isMock: isMock,
          localizer: localizer,
        );
        return false;
      }
      stageDone(1, stage1);

      // ══════════════════════════════════════════════
      //  AŞAMA 2: Bölümleme
      // ══════════════════════════════════════════════
      stageBanner(2, 'install_stage_partitioning', 'Bölümleme');
      final stage2 = await _partitioning.execute(ctx);
      if (!stage2.success) {
        stageFailed(2, stage2);
        await _artifactCollector.collectDiagnostics(
          log,
          isMock: isMock,
          localizer: localizer,
        );
        return false;
      }
      stageDone(2, stage2);

      // ══════════════════════════════════════════════
      //  AŞAMA 3: Biçimlendirme
      // ══════════════════════════════════════════════
      stageBanner(3, 'install_stage_formatting', 'Biçimlendirme');
      final stage3 = await _formatting.execute(ctx);
      if (!stage3.success) {
        stageFailed(3, stage3);
        await _artifactCollector.collectDiagnostics(
          log,
          isMock: isMock,
          localizer: localizer,
        );
        return false;
      }
      stageDone(3, stage3);

      // ══════════════════════════════════════════════
      //  AŞAMA 4: Bağlama
      // ══════════════════════════════════════════════
      stageBanner(4, 'install_stage_mounting', 'Bağlama');
      final stage4 = await _mounting.execute(ctx);
      if (!stage4.success) {
        stageFailed(4, stage4);
        await _artifactCollector.collectDiagnostics(
          log,
          isMock: isMock,
          localizer: localizer,
        );
        return false;
      }
      stageDone(4, stage4);

      // ══════════════════════════════════════════════
      //  AŞAMA 5: Dosya Kopyalama
      // ══════════════════════════════════════════════
      stageBanner(5, 'install_stage_file_copy', 'Dosya Kopyalama');
      final stage5 = await _fileCopy.execute(ctx);
      if (!stage5.success) {
        stageFailed(5, stage5);
        await _artifactCollector.collectDiagnostics(
          log,
          isMock: isMock,
          localizer: localizer,
        );
        return false;
      }
      stageDone(5, stage5);

      // ══════════════════════════════════════════════
      //  AŞAMA 6: Chroot Yapılandırma
      // ══════════════════════════════════════════════
      stageBanner(6, 'install_stage_chroot_config', 'Chroot Yapılandırma');
      final stage6 = await _chrootConfig.execute(ctx);
      if (!stage6.success) {
        stageFailed(6, stage6);
        await _artifactCollector.collectDiagnostics(
          log,
          isMock: isMock,
          localizer: localizer,
        );
        return false;
      }
      stageDone(6, stage6);

      // ══════════════════════════════════════════════
      //  AŞAMA 7: Bootloader Kurulumu
      // ══════════════════════════════════════════════
      stageBanner(7, 'install_stage_bootloader', 'Bootloader Kurulumu');
      final stage7 = await _bootloader.execute(ctx);
      if (!stage7.success) {
        stageFailed(7, stage7);
        await _artifactCollector.collectDiagnostics(
          log,
          isMock: isMock,
          localizer: localizer,
        );
        return false;
      }
      stageDone(7, stage7);

      // ══════════════════════════════════════════════
      //  AŞAMA 8: Kurulum Sonrası Doğrulama
      // ══════════════════════════════════════════════
      stageBanner(
        8,
        'install_stage_post_validation',
        'Kurulum Sonrası Doğrulama',
      );
      final stage8 = await _postInstallValidation.execute(ctx);
      if (!stage8.success) {
        stageFailed(8, stage8);
        await _artifactCollector.collectDiagnostics(
          log,
          isMock: isMock,
          localizer: localizer,
        );
        return false;
      }
      stageDone(8, stage8);

      // ══════════════════════════════════════════════
      //  AŞAMA 9: Temizlik
      // ══════════════════════════════════════════════
      stageBanner(9, 'install_stage_cleanup', 'Temizlik');
      final stage9 = await _cleanup.execute(ctx);
      if (!stage9.success) {
        stageFailed(9, stage9);
        await _artifactCollector.collectDiagnostics(
          log,
          isMock: isMock,
          localizer: localizer,
        );
        return false;
      }
      stageDone(9, stage9);

      // ══════════════════════════════════════════════
      //  KURULUM BAŞARIYLA TAMAMLANDI
      // ══════════════════════════════════════════════
      log('');
      log('══════════════════════════════════════════');
      log(
        t('install_log_all_stages_done', '✅ TÜM AŞAMALAR BAŞARIYLA TAMAMLANDI'),
      );
      log('══════════════════════════════════════════');

      onProgress(
        1.0,
        t(
          'install_progress_complete',
          'Kurulum Hatasız Tamamlandı! Sistemi Yeniden Başlatabilirsiniz.',
        ),
      );
      return true;
    } catch (e, stack) {
      log('FATAL CATCH: $e');
      log('STACKTRACE:\n$stack');
      await _artifactCollector.collectDiagnostics(
        log,
        isMock: isMock,
        localizer: localizer,
      );
      return false;
    }
  }
}
