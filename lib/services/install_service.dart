import 'install_observation.dart';
import 'session_command_runner.dart';
import 'dart:async';
import 'mount_session.dart';
import 'install_preflight.dart';
import 'install_outcome.dart';
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
///   6. Hedef Sonlandırma   [TargetFinalizationStage]
///   7. Bootloader Kurulumu   [BootloaderStage]
///   8. Kurulum Sonrası Doğrulama [PostInstallValidationStage]
///   9. Temizlik              [CleanupStage]
class InstallService {
  final CommandRunner _commandRunner;
  final Future<MountSession> Function(CommandRunner)? _sessionFactory;
  InstallOutcome? lastOutcome;
  final InstallObservation Function()? _observationFactory;
  late final InstallArtifactCollector _artifactCollector;

  InstallService({
    CommandRunner? commandRunner,
    InstallObservation Function()? observationFactory,
    Future<MountSession> Function(CommandRunner)? sessionFactory,
  }) : _observationFactory = observationFactory,
       _sessionFactory = sessionFactory,
       _commandRunner = commandRunner ?? CommandRunner.instance {
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
  final _targetFinalization = const TargetFinalizationStage();
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
    final stopwatch = Stopwatch()..start();
    final result = await _commandRunner.run(
      cmd,
      args,
      isMock: isMock,
      onLog: (event) => onLog(event.displayMessage),
    );
    stopwatch.stop();
    onLog(
      '[SÜRE] ${result.displayCommandLine} -> exit=${result.exitCode} '
      'duration=${_formatDuration(stopwatch.elapsed)}',
    );

    if (!result.started) {
      onLog("═══════════════════════════════════════════");
      onLog("[İSTİSNA] Komut çalıştırılamadı: $cmd");
      onLog("[İSTİSNA] Sebep: ${SecretRedactor.redactText(result.stderr)}");
      onLog(
        "[İSTİSNA] Komut sisteminizde kurulu olmayabilir (PATH kontrol edin).",
      );
      onLog("═══════════════════════════════════════════");
      return false;
    }

    if (!allowedExitCodes.contains(result.exitCode)) {
      final rawErrorDetail = result.stderr.isNotEmpty
          ? result.stderr
          : (result.stdout.isNotEmpty ? result.stdout : 'Ek bilgi yok');
      final errorDetail = SecretRedactor.redactText(rawErrorDetail);
      onLog("═══════════════════════════════════════════");
      onLog("[HATA] Komut başarısız oldu!");
      onLog("[HATA] Komut: ${result.displayCommandLine}");
      onLog("[HATA] Çıkış Kodu: ${result.exitCode}");
      onLog("[HATA] Detay: $errorDetail");
      onLog("═══════════════════════════════════════════");
      return false;
    }

    return true;
  }

  String _formatDuration(Duration duration) {
    final totalSeconds = duration.inSeconds;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    final millis = duration.inMilliseconds % 1000;
    if (minutes > 0) {
      return '${minutes}m ${seconds.toString().padLeft(2, '0')}s';
    }
    if (seconds > 0) {
      return '$seconds.${millis ~/ 100}s';
    }
    return '${duration.inMilliseconds}ms';
  }

  Duration? _stageElapsed(Map<String, dynamic> state, int index) {
    final startedAt = state['_stage_${index}_startedAt'];
    if (startedAt is! Stopwatch) {
      return null;
    }
    startedAt.stop();
    return startedAt.elapsed;
  }

  // Ana kurulum motoru (Orkestratör)
  Future<bool> runInstall(
    Map<String, dynamic> state,
    void Function(double progress, String status) onProgress,
    void Function(String message) onTechnicalLog, {
    bool isMock = false,
    InstallTranslator? translate,
    Future<void> Function()? beforeFirstMutation,
    void Function(int stage)? onStage,
  }) async {
    lastOutcome = null;
    InstallObservation observation;
    try {
      observation =
          _observationFactory?.call() ??
          InstallObservation(
            sink: _commandRunner is SessionCommandRunner
                ? (request) async {
                    await _commandRunner.control(request);
                  }
                : null,
          );
    } catch (_) {
      observation = InstallObservation();
    }
    void log(String msg) {
      try {
        onTechnicalLog(msg);
      } catch (_) {
        /* diagnostics cannot bypass cleanup */
      }
    }

    // Discard obsolete identity/secret input before it can enter stage logs.
    for (final key in [
      'username',
      'fullName',
      'password',
      'passwordHash',
      'isAdministrator',
      'selectedRegion',
      'selectedTimezone',
      'selectedKeyboard',
      'selectedLocale',
    ]) {
      state.remove(key);
    }

    // Fail closed before disk preparation; never reinterpret another mode as full.
    if ((state['partitionMethod'] ?? 'full') != 'full') {
      log(
        'Storage MVP yalnızca full-disk erase destekler; disk işlemleri başlatılmadı.',
      );
      lastOutcome = InstallOutcome(
        primaryFailure: 'UNSUPPORTED_MODE',
        cleanup: const CleanupReport(true),
      );
      await observation.finish(
        success: false,
        primary: 'UNSUPPORTED_MODE',
        cleanup: true,
        remaining: 0,
      );
      return false;
    }
    try {
      if (!isMock) {
        final arch = await _commandRunner.run('uname', ['-m']);
        final uefi = await _commandRunner.run('test', [
          '-d',
          '/sys/firmware/efi',
        ]);
        if (!arch.started ||
            arch.exitCode != 0 ||
            arch.stdout.trim() != 'x86_64' ||
            !uefi.started ||
            uefi.exitCode != 0) {
          log(
            'Storage MVP x86_64 UEFI gerektirir; disk işlemleri başlatılmadı.',
          );
          lastOutcome = InstallOutcome(
            primaryFailure: 'UNSUPPORTED_PLATFORM',
            cleanup: const CleanupReport(true),
          );
          await observation.finish(
            success: false,
            primary: 'UNSUPPORTED_PLATFORM',
            cleanup: true,
            remaining: 0,
          );
          return false;
        }
      }
    } catch (_) {
      lastOutcome = InstallOutcome(
        primaryFailure: 'PLATFORM_CHECK_FAILED',
        cleanup: const CleanupReport(true),
      );
      log('Temel ortam kontrolleri tamamlanamadı; disk değiştirilmedi.');
      await observation.finish(
        success: false,
        primary: 'PLATFORM_CHECK_FAILED',
        cleanup: true,
        remaining: 0,
      );
      return false;
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
      onStage?.call(index);
      state['_stage_${index}_startedAt'] = Stopwatch()..start();
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
      final elapsed = _stageElapsed(state, index);
      log(
        t(
          'install_log_stage_failed',
          '[FATAL] Aşama {index} başarısız: {message}',
          {'index': index.toString(), 'message': result.message},
        ),
      );
      if (elapsed != null) {
        log('[SÜRE] AŞAMA $index başarısız oldu: ${_formatDuration(elapsed)}');
      }
    }

    void stageDone(int index, StageResult result) {
      final elapsed = _stageElapsed(state, index);
      log(
        t('install_log_stage_done', '✓ Aşama {index} tamamlandı: {message}', {
          'index': index.toString(),
          'message': result.message,
        }),
      );
      if (elapsed != null) {
        log('[SÜRE] AŞAMA $index tamamlandı: ${_formatDuration(elapsed)}');
      }
    }

    MountSession? mountSession;
    var stagesSucceeded = false;
    var cleanupStageEntered = false;
    String? primaryFailure;
    Future<void> diagnostics() async {
      try {
        await observation.span(
          'diagnostics',
          () => _artifactCollector.collectDiagnostics(
            log,
            isMock: isMock,
            localizer: localizer,
            safeOnly: !isMock,
          ),
        );
      } catch (_) {
        log('Tanılama tamamlanamadı; oturum temizliği yine uygulanacak.');
      }
    }

    try {
      mountSession = _sessionFactory != null
          ? await _sessionFactory(_commandRunner)
          : isMock
          ? SimulatedMountSession(_commandRunner)
          : await MountSession.open(_commandRunner);
      await mountSession.initialize();
      final disk = state['selectedDisk'] as String;
      await mountSession.validateTarget(disk);
      // ── Ortak bağlam (context) nesnesi oluştur ──
      final ctx = StageContext(
        state: state,
        log: log,
        onProgress: onProgress,
        commandRunner: _commandRunner,
        runCmd:
            (
              cmd,
              args,
              onLog, {
              bool isMock = false,
              List<int> allowedExitCodes = const [0],
            }) {
              final String? operation = args.contains(bootloaderDracutScript)
                  ? 'bootloader.dracut'
                  : args.contains(bootloaderKernelInstallScript)
                  ? 'bootloader.kernel-install'
                  : args.contains('grub2-mkconfig')
                  ? 'bootloader.grub-config'
                  : null;
              Future<bool> action() => runCmd(
                cmd,
                args,
                onLog,
                isMock: isMock,
                allowedExitCodes: allowedExitCodes,
              );
              return operation == null
                  ? action()
                  : observation.span(operation, action, success: (ok) => ok);
            },
        localizer: localizer,
        isMock: isMock,
        mountSession: mountSession,
        observation: observation,
        beforeFirstMutation: () async {
          await mountSession!.validateTarget(disk, commit: true);
          await beforeFirstMutation?.call();
        },
      );

      if (!await observation.span(
        'preflight',
        () => const InstallPreflight().check(ctx),
        success: (ok) => ok,
      )) {
        primaryFailure = 'PREFLIGHT_FAILED';
        log(
          'Kurulum öncesi güvenlik kontrolleri başarısız; disk değiştirilmedi.',
        );
        return false;
      }

      // The same nine stages and admission handshake, in the same order.
      Future<bool> executeStage(
        int index,
        String key,
        String fallback,
        Future<StageResult> Function() execute,
      ) async {
        stageBanner(index, key, fallback);
        await observation.beginStage(index);
        StageResult result;
        try {
          result = await execute();
        } catch (_) {
          primaryFailure = 'INSTALL_EXCEPTION';
          await observation.endStage(index, false, error: primaryFailure);
          rethrow;
        }
        await observation.endStage(
          index,
          result.success,
          error: result.success ? null : 'STAGE_${index}_FAILED',
        );
        if (!result.success) {
          primaryFailure = 'STAGE_${index}_FAILED';
          stageFailed(index, result);
          await diagnostics();
          return false;
        }
        stageDone(index, result);
        return true;
      }

      if (!await executeStage(
        1,
        'install_stage_disk_preparation',
        'Disk Hazırlığı',
        () => _diskPreparation.execute(ctx),
      )) {
        return false;
      }
      if (!await executeStage(
        2,
        'install_stage_partitioning',
        'Bölümleme',
        () => _partitioning.execute(ctx),
      )) {
        return false;
      }
      if (!await executeStage(
        3,
        'install_stage_formatting',
        'Biçimlendirme',
        () => _formatting.execute(ctx),
      )) {
        return false;
      }
      if (!await executeStage(
        4,
        'install_stage_mounting',
        'Bağlama',
        () => _mounting.execute(ctx),
      )) {
        return false;
      }
      if (!await executeStage(
        5,
        'install_stage_file_copy',
        'Dosya Kopyalama',
        () => _fileCopy.execute(ctx),
      )) {
        return false;
      }
      if (!await executeStage(
        6,
        'install_stage_target_finalization',
        'Hedef Sonlandırma',
        () => _targetFinalization.execute(ctx),
      )) {
        return false;
      }
      if (!await executeStage(
        7,
        'install_stage_bootloader',
        'Bootloader Kurulumu',
        () => _bootloader.execute(ctx),
      )) {
        return false;
      }
      if (!await executeStage(
        8,
        'install_stage_post_validation',
        'Kurulum Sonrası Doğrulama',
        () => _postInstallValidation.execute(ctx),
      )) {
        return false;
      }
      if (!await executeStage(9, 'install_stage_cleanup', 'Temizlik', () {
        cleanupStageEntered = true;
        return observation.span(
          'cleanup',
          () => _cleanup.execute(ctx),
          success: (result) => result.success,
        );
      })) {
        return false;
      }

      stagesSucceeded = true;
    } catch (_) {
      primaryFailure ??= 'INSTALL_EXCEPTION';
      log('Kurulum oturumunda beklenmeyen hata; güvenli temizlik denenecek.');
      await diagnostics();
    } finally {
      CleanupReport cleanup;
      try {
        cleanup = await observation.span(
          cleanupStageEntered ? 'cleanup.verify' : 'cleanup',
          () async =>
              await mountSession?.cleanup() ?? const CleanupReport(true),
          success: (report) => report.success,
        );
      } catch (_) {
        cleanup = const CleanupReport(false, reason: 'Cleanup exception');
      }
      lastOutcome = InstallOutcome(
        primaryFailure:
            primaryFailure ?? (stagesSucceeded ? null : 'SESSION_REJECTED'),
        cleanup: cleanup,
      );
      await observation.finish(
        success: stagesSucceeded && lastOutcome!.success,
        primary: lastOutcome!.primaryFailure,
        cleanup: cleanup.success,
        remaining: cleanup.success
            ? 0
            : cleanup.remaining.isEmpty
            ? null
            : cleanup.remaining.length,
      );
      if (!cleanup.success) {
        log('Kurulum oturumu temizliği doğrulanamadı; sonuç başarısız.');
      }
    }
    final ok = stagesSucceeded && lastOutcome!.success;
    if (ok) {
      onProgress(
        1.0,
        t(
          'install_progress_complete',
          'Kurulum doğrulanmış biçimde tamamlandı.',
        ),
      );
    }
    return ok;
  }
}
