import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/command_runner.dart';
import '../services/install_log_export_service.dart';
import '../services/install_service.dart';
import '../state/installer_state.dart';
import '../theme/app_theme.dart';
import '../widgets/nebula_ui.dart';

class InstallingScreen extends StatefulWidget {
  const InstallingScreen({super.key});

  @override
  State<InstallingScreen> createState() => _InstallingScreenState();
}

class _InstallingScreenState extends State<InstallingScreen>
    with SingleTickerProviderStateMixin {
  double _progress = 0.0;
  String _statusText = '';
  bool _isFinished = false;
  bool _isRebooting = false;

  final List<String> _statusHistory = [];
  final List<String> _technicalLogs = [];
  final ScrollController _scrollController = ScrollController();

  bool _startExpansion = false;
  int _currentSlide = 0;
  Timer? _slideTimer;

  final List<String> _slideImages = [
    'assets/images/slide1.png',
    'assets/images/slide2.png',
    'assets/images/slide3.png',
  ];

  final List<String> _slideKeys = ['slide_1', 'slide_2', 'slide_3'];

  @override
  void initState() {
    super.initState();

    Future.delayed(const Duration(seconds: 1), () {
      if (mounted) {
        setState(() => _startExpansion = true);
      }
    });

    _slideTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (mounted && !_isFinished) {
        setState(() {
          _currentSlide = (_currentSlide + 1) % _slideImages.length;
        });
      }
    });

    _startRealInstallation();
  }

  @override
  void dispose() {
    _slideTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _pushLog(String logMsg) {
    if (!mounted) {
      return;
    }

    setState(() {
      _technicalLogs.add(logMsg);
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _pushStatus(String status) {
    if (!mounted) {
      return;
    }

    setState(() {
      _statusHistory.add(status);
    });
  }

  void _showLogsDialog() {
    final state = Provider.of<InstallerState>(context, listen: false);

    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 24,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920, maxHeight: 640),
            child: NebulaPanel(
              padding: const EdgeInsets.all(22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          state.t('install_logs_title'),
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                      ),
                      NebulaSecondaryButton(
                        label: state.t('close'),
                        icon: Icons.close_rounded,
                        onPressed: () => Navigator.pop(dialogContext),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Expanded(
                    child: _technicalLogs.isEmpty
                        ? Center(
                            child: Text(
                              state.t('install_logs_empty'),
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    color: context
                                        .installerVisuals
                                        .mutedForeground,
                                  ),
                            ),
                          )
                        : _TerminalPanel(
                            logs: _technicalLogs,
                            controller: _scrollController,
                          ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _rebootSystem() async {
    if (_isRebooting) {
      return;
    }

    final state = Provider.of<InstallerState>(context, listen: false);
    setState(() {
      _isRebooting = true;
      _statusText = state.t('install_rebooting_status');
    });
    _pushStatus(_statusText);
    _pushLog('[REBOOT] systemctl reboot çağrılıyor...');

    final result = await CommandRunner.instance.run('systemctl', ['reboot']);
    if (!mounted) {
      return;
    }

    if (!result.started) {
      _pushLog('[REBOOT] systemctl reboot başlatılamadı: ${result.stderr}');
      setState(() {
        _isRebooting = false;
        _statusText = state.t('install_reboot_start_failed');
      });
      _pushStatus(_statusText);
      return;
    }

    if (result.exitCode != 0) {
      final detail = result.stderr.isNotEmpty ? result.stderr : result.stdout;
      _pushLog('[REBOOT] systemctl reboot başarısız: $detail');
      setState(() {
        _isRebooting = false;
        _statusText = state.t('install_reboot_failed');
      });
      _pushStatus(_statusText);
      return;
    }

    _pushLog('[REBOOT] Yeniden başlatma komutu başarıyla gönderildi.');
  }

  Future<void> _startRealInstallation() async {
    final state = Provider.of<InstallerState>(context, listen: false);
    final startedAt = DateTime.now();

    if (_statusText.isEmpty) {
      setState(() {
        _statusText = state.t('install_progress_initial');
      });
    }

    await Future.delayed(const Duration(seconds: 1));

    final stateMap = <String, dynamic>{
      'selectedDisk': state.selectedDisk,
      'partitionMethod': state.partitionMethod,
      'fileSystem': state.fileSystem,
      'manualPartitions': state.manualPartitions,
      'username': state.username,
      'password': state.password,
      'selectedRegion': state.selectedRegion,
      'selectedTimezone': state.selectedTimezone,
      'selectedKeyboard': state.selectedKeyboard,
      'selectedLanguage': state.selectedLanguage,
      'selectedLocale': state.selectedLocale.locale,
      'isAdministrator': state.isAdministrator,
      'linuxDiskSizeGB': state.linuxDiskSizeGB,
      'hasExistingEfi': state.hasExistingEfi,
      'existingEfiPartition': state.existingEfiPartition,
      'shrinkCandidatePartition': state.shrinkCandidatePartition,
      'shrinkCandidateFs': state.shrinkCandidateFs,
      'shrinkCandidateSizeBytes': state.shrinkCandidateSizeBytes,
      'largestFreeContiguousBytes': state.largestFreeContiguousBytes,
    };

    _pushStatus(_statusText);

    final success = await InstallService.instance.runInstall(
      stateMap,
      (progress, status) {
        if (!mounted) {
          return;
        }
        final normalizedProgress = progress < 0
            ? _progress
            : progress.clamp(0.0, 1.0);
        setState(() {
          _progress = normalizedProgress;
          _statusText = status;
        });
        _pushStatus(status);
      },
      (message) {
        _pushLog(message);
      },
      isMock: state.isMockEnabled,
      translate: state.t,
    );

    final finishedAt = DateTime.now();
    final exportResult = await InstallLogExportService.instance.exportSession(
      startedAt: startedAt,
      finishedAt: finishedAt,
      success: success,
      finalStatus: _statusText,
      statusHistory: _statusHistory,
      technicalLogs: _technicalLogs,
      installContext: {
        'selectedDisk': state.selectedDisk,
        'partitionMethod': state.partitionMethod,
        'fileSystem': state.fileSystem,
        'selectedRegion': state.selectedRegion,
        'selectedTimezone': state.selectedTimezone,
        'selectedKeyboard': state.selectedKeyboard,
        'selectedLanguage': state.selectedLanguage,
        'selectedLocale': state.selectedLocale.locale,
        'isAdministrator': state.isAdministrator,
        'linuxDiskSizeGB': state.linuxDiskSizeGB,
        'hasExistingEfi': state.hasExistingEfi,
        'shrinkCandidatePartition': state.shrinkCandidatePartition,
        'shrinkCandidateFs': state.shrinkCandidateFs,
      },
    );

    if (exportResult.success) {
      _pushLog('[LOG] Oturum kaydı yazıldı: ${exportResult.logPath}');
      _pushLog('[LOG] Oturum özeti yazıldı: ${exportResult.summaryPath}');
    } else {
      _pushLog('[LOG] Oturum dışa aktarımı başarısız: ${exportResult.error}');
    }

    if (!mounted) {
      return;
    }

    if (success) {
      setState(() {
        _progress = 1.0;
        _isFinished = true;
        _statusText = state.t('install_ready_reboot_status');
        _slideTimer?.cancel();
      });
    } else {
      setState(() {
        _statusText = state.t('install_failed_log_hint');
        _isFinished = true;
        _slideTimer?.cancel();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = Provider.of<InstallerState>(context);
    final visibleStatusText = _statusText.isEmpty
        ? state.t('install_progress_initial')
        : _statusText;
    final success = _isFinished && _progress >= 1.0;
    final failed = _isFinished && !success;
    final statusColor = failed
        ? Colors.redAccent
        : success
        ? const Color(0xFF6BE7B1)
        : theme.colorScheme.primary;
    final title = success
        ? state.t('install_done')
        : failed
        ? state.t('install_failure_title')
        : state.t('installing');
    final badge = success
        ? state.t('install_badge_success')
        : failed
        ? state.t('install_badge_failure')
        : state.t('install_badge_active');

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 1180;

        final progressPanel = _ProgressOverviewPanel(
          progress: _progress,
          statusText: visibleStatusText,
          statusColor: statusColor,
          technicalLogs: _technicalLogs,
          isFinished: _isFinished,
          success: success,
          onShowLogs: _showLogsDialog,
        );

        final visualPanel = _VisualStatePanel(
          compact: compact,
          startExpansion: _startExpansion,
          isFinished: _isFinished,
          success: success,
          isRebooting: _isRebooting,
          rebootLabel: state.t('restart'),
          onReboot: _isFinished ? _rebootSystem : null,
          onInspectLogs: _showLogsDialog,
          slideImage: _slideImages[_currentSlide],
          slideCaption: state.t(_slideKeys[_currentSlide]),
        );

        return AnimatedOpacity(
          duration: context.installerMotion.slow,
          opacity: _startExpansion ? 1.0 : 0.0,
          child: Column(
            children: [
              const SizedBox(height: 10),
              NebulaScreenIntro(
                badge: badge,
                title: title,
                description: visibleStatusText,
              ),
              const SizedBox(height: 18),
              Expanded(child: visualPanel),
              const SizedBox(height: 18),
              progressPanel,
            ],
          ),
        );
      },
    );
  }
}

class _ProgressOverviewPanel extends StatelessWidget {
  const _ProgressOverviewPanel({
    required this.progress,
    required this.statusText,
    required this.statusColor,
    required this.technicalLogs,
    required this.isFinished,
    required this.success,
    required this.onShowLogs,
  });

  final double progress;
  final String statusText;
  final Color statusColor;
  final List<String> technicalLogs;
  final bool isFinished;
  final bool success;
  final VoidCallback onShowLogs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = Provider.of<InstallerState>(context, listen: false);
    final progressPercent = (progress.clamp(0.0, 1.0) * 100).round();
    final engineStateLabel = isFinished
        ? success
              ? state.t('install_engine_ready')
              : state.t('install_engine_halted')
        : technicalLogs.isEmpty
        ? state.t('install_engine_waiting')
        : state.t('install_engine_running');

    return NebulaPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: NebulaSectionLabel(state.t('install_status_panel')),
              ),
              Text(
                '$progressPercent%',
                style: theme.textTheme.headlineMedium?.copyWith(
                  color: statusColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            statusText,
            style: theme.textTheme.titleMedium?.copyWith(color: statusColor),
          ),
          const SizedBox(height: 10),
          _LiquidProgressBar(
            progress: progress.clamp(0.0, 1.0),
            color: statusColor,
          ),
          const SizedBox(height: 12),
          Text(
            engineStateLabel,
            style: theme.textTheme.bodySmall?.copyWith(
              color: context.installerVisuals.mutedForeground,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              NebulaSecondaryButton(
                label: state.t('install_inspect_logs'),
                icon: Icons.terminal_rounded,
                onPressed: onShowLogs,
              ),
              const Spacer(),
              Text(
                state.t('install_log_lines', {
                  'count': technicalLogs.length.toString(),
                }),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: context.installerVisuals.mutedForeground,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TerminalPanel extends StatelessWidget {
  const _TerminalPanel({required this.logs, required this.controller});

  final List<String> logs;
  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = Provider.of<InstallerState>(context, listen: false);

    return NebulaPanel(
      padding: const EdgeInsets.all(0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 22, 24, 14),
            child: Row(
              children: [
                NebulaSectionLabel(state.t('install_terminal_title')),
                const Spacer(),
                Text(
                  state.t('install_terminal_lines', {
                    'count': logs.length.toString(),
                  }),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: context.installerVisuals.mutedForeground,
                  ),
                ),
              ],
            ),
          ),
          Divider(
            height: 1,
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.35),
          ),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.36),
                borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(28),
                ),
              ),
              child: logs.isEmpty
                  ? Center(
                      child: Text(
                        state.t('install_terminal_empty'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.white.withValues(alpha: 0.55),
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: controller,
                      itemCount: logs.length,
                      itemBuilder: (context, index) {
                        final line = logs[index];
                        final isLatest = index == logs.length - 1;
                        return TweenAnimationBuilder<double>(
                          duration: const Duration(milliseconds: 360),
                          tween: Tween<double>(
                            begin: isLatest ? 0.86 : 1.0,
                            end: 1.0,
                          ),
                          curve: context.installerMotion.enterCurve,
                          builder: (context, value, child) {
                            return Opacity(
                              opacity: value,
                              child: Transform.translate(
                                offset: Offset(
                                  isLatest ? (1 - value) * 18 : 0,
                                  isLatest ? (1 - value) * 8 : 0,
                                ),
                                child: Container(
                                  margin: const EdgeInsets.only(bottom: 6),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(12),
                                    color: isLatest
                                        ? _logColor(line).withValues(alpha: 0.1)
                                        : Colors.transparent,
                                    border: Border.all(
                                      color: isLatest
                                          ? _logColor(
                                              line,
                                            ).withValues(alpha: 0.16)
                                          : Colors.transparent,
                                    ),
                                  ),
                                  child: child,
                                ),
                              ),
                            );
                          },
                          child: Text(
                            line,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontFamily: 'monospace',
                              color: _logColor(line),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LiquidProgressBar extends StatefulWidget {
  const _LiquidProgressBar({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  State<_LiquidProgressBar> createState() => _LiquidProgressBarState();
}

class _LiquidProgressBarState extends State<_LiquidProgressBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final fillWidth = width * widget.progress;

        return Container(
          height: 18,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            color: theme.colorScheme.surface.withValues(
              alpha: theme.brightness == Brightness.dark ? 0.28 : 0.62,
            ),
            border: Border.all(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.35),
            ),
          ),
          child: Stack(
            children: [
              AnimatedContainer(
                duration: context.installerMotion.medium,
                curve: context.installerMotion.enterCurve,
                width: fillWidth,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  gradient: LinearGradient(
                    colors: [
                      widget.color.withValues(alpha: 0.9),
                      theme.colorScheme.primary,
                      theme.colorScheme.tertiary,
                    ],
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: widget.color.withValues(alpha: 0.32),
                      blurRadius: 24,
                      spreadRadius: -10,
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: AnimatedBuilder(
                    animation: _controller,
                    builder: (context, child) {
                      return Stack(
                        children: [
                          Positioned.fill(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    Colors.white.withValues(alpha: 0.22),
                                    Colors.transparent,
                                  ],
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                ),
                              ),
                            ),
                          ),
                          FractionalTranslation(
                            translation: Offset(
                              -1.0 + (_controller.value * 2.2),
                              0,
                            ),
                            child: Container(
                              width: 90,
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    Colors.transparent,
                                    Colors.white.withValues(alpha: 0.34),
                                    Colors.transparent,
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _VisualStatePanel extends StatelessWidget {
  const _VisualStatePanel({
    required this.compact,
    required this.startExpansion,
    required this.isFinished,
    required this.success,
    required this.isRebooting,
    required this.rebootLabel,
    required this.onReboot,
    required this.onInspectLogs,
    required this.slideImage,
    required this.slideCaption,
  });

  final bool compact;
  final bool startExpansion;
  final bool isFinished;
  final bool success;
  final bool isRebooting;
  final String rebootLabel;
  final VoidCallback? onReboot;
  final VoidCallback onInspectLogs;
  final String slideImage;
  final String slideCaption;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = Provider.of<InstallerState>(context, listen: false);
    final feedDeck = compact
        ? Column(
            children: [
              _BrandFocusCard(
                title: state.t('install_brand_title'),
                body: state.t('install_brand_body'),
                websitePrompt: state.t('install_website_prompt'),
              ),
              const SizedBox(height: 14),
              _SlideshowCard(
                compact: compact,
                slideImage: slideImage,
                slideCaption: slideCaption,
              ),
            ],
          )
        : Row(
            children: [
              Expanded(
                child: _BrandFocusCard(
                  title: state.t('install_brand_title'),
                  body: state.t('install_brand_body'),
                  websitePrompt: state.t('install_website_prompt'),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: _SlideshowCard(
                  compact: compact,
                  slideImage: slideImage,
                  slideCaption: slideCaption,
                ),
              ),
            ],
          );

    return NebulaPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          NebulaSectionLabel(state.t('install_visual_feed')),
          const SizedBox(height: 18),
          AnimatedSwitcher(
            duration: context.installerMotion.slow,
            child: isFinished
                ? _FinishedStateCard(
                    success: success,
                    isRebooting: isRebooting,
                    rebootLabel: rebootLabel,
                    onReboot: onReboot,
                    onInspectLogs: onInspectLogs,
                  )
                : Column(
                    key: const ValueKey('slideshow'),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      feedDeck,
                      const SizedBox(height: 18),
                      Text(
                        startExpansion
                            ? state.t('install_runtime_note')
                            : state.t('install_preparing_note'),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: context.installerVisuals.mutedForeground,
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _FinishedStateCard extends StatelessWidget {
  const _FinishedStateCard({
    required this.success,
    required this.isRebooting,
    required this.rebootLabel,
    required this.onReboot,
    required this.onInspectLogs,
  });

  final bool success;
  final bool isRebooting;
  final String rebootLabel;
  final VoidCallback? onReboot;
  final VoidCallback onInspectLogs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = Provider.of<InstallerState>(context, listen: false);
    final accent = success ? const Color(0xFF6BE7B1) : Colors.redAccent;
    final motion = context.installerMotion;

    return TweenAnimationBuilder<double>(
      key: const ValueKey('finished'),
      tween: Tween(begin: 0, end: 1),
      duration: motion.cinematic,
      curve: motion.enterCurve,
      builder: (context, crystal, child) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final horizontal = constraints.maxWidth >= 720;

            return Stack(
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(28),
                    gradient: LinearGradient(
                      colors: success
                          ? [
                              accent.withValues(alpha: 0.12),
                              theme.colorScheme.tertiary.withValues(
                                alpha: 0.08,
                              ),
                              Colors.white.withValues(alpha: 0.03),
                            ]
                          : [
                              const Color(0x66A11224),
                              const Color(0x33240B10),
                              Colors.black.withValues(alpha: 0.18),
                            ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    border: Border.all(color: accent.withValues(alpha: 0.24)),
                    boxShadow: [
                      BoxShadow(
                        color: accent.withValues(alpha: success ? 0.2 : 0.16),
                        blurRadius: 36,
                        spreadRadius: -18,
                      ),
                    ],
                  ),
                  child: horizontal
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Transform.scale(
                              scale: 0.92 + (crystal * 0.08),
                              alignment: Alignment.centerLeft,
                              child: Icon(
                                success
                                    ? Icons.task_alt_rounded
                                    : Icons.error_outline_rounded,
                                size: 72,
                                color: accent,
                              ),
                            ),
                            const SizedBox(width: 20),
                            Expanded(
                              child: _FinishedCardContent(
                                success: success,
                                accent: accent,
                                title: success
                                    ? state.t('install_finished_success_title')
                                    : state.t('install_finished_failure_title'),
                                body: success
                                    ? state.t('install_finished_success_body')
                                    : state.t('install_finished_failure_body'),
                                button: success
                                    ? NebulaPrimaryButton(
                                        label: isRebooting
                                            ? state.t('install_rebooting')
                                            : state.t(
                                                'install_ready_reboot_button',
                                              ),
                                        icon: Icons.restart_alt_rounded,
                                        onPressed: isRebooting
                                            ? null
                                            : onReboot,
                                      )
                                    : NebulaSecondaryButton(
                                        label: state.t('install_inspect_logs'),
                                        icon: Icons.terminal_rounded,
                                        onPressed: onInspectLogs,
                                      ),
                              ),
                            ),
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Transform.scale(
                              scale: 0.92 + (crystal * 0.08),
                              alignment: Alignment.centerLeft,
                              child: Icon(
                                success
                                    ? Icons.task_alt_rounded
                                    : Icons.error_outline_rounded,
                                size: 64,
                                color: accent,
                              ),
                            ),
                            const SizedBox(height: 14),
                            _FinishedCardContent(
                              success: success,
                              accent: accent,
                              title: success
                                  ? state.t('install_finished_success_title')
                                  : state.t('install_finished_failure_title'),
                              body: success
                                  ? state.t('install_finished_success_body')
                                  : state.t('install_finished_failure_body'),
                              button: success
                                  ? NebulaPrimaryButton(
                                      label: isRebooting
                                          ? state.t('install_rebooting')
                                          : state.t(
                                              'install_ready_reboot_button',
                                            ),
                                      icon: Icons.restart_alt_rounded,
                                      onPressed: isRebooting ? null : onReboot,
                                    )
                                  : NebulaSecondaryButton(
                                      label: state.t('install_inspect_logs'),
                                      icon: Icons.terminal_rounded,
                                      onPressed: onInspectLogs,
                                    ),
                            ),
                          ],
                        ),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _CrystalOutcomePainter(
                        progress: crystal,
                        success: success,
                        accent: accent,
                        spread: motion.crystalSpread,
                        secondary: success
                            ? theme.colorScheme.tertiary
                            : const Color(0xFF4F0E18),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _FinishedCardContent extends StatelessWidget {
  const _FinishedCardContent({
    required this.success,
    required this.accent,
    required this.title,
    required this.body,
    required this.button,
  });

  final bool success;
  final Color accent;
  final String title;
  final String body;
  final Widget button;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.headlineSmall?.copyWith(color: accent),
        ),
        const SizedBox(height: 10),
        Text(
          body,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.86),
            height: 1.45,
          ),
        ),
        const SizedBox(height: 18),
        button,
      ],
    );
  }
}

class _CrystalOutcomePainter extends CustomPainter {
  const _CrystalOutcomePainter({
    required this.progress,
    required this.success,
    required this.accent,
    required this.spread,
    required this.secondary,
  });

  final double progress;
  final bool success;
  final Color accent;
  final double spread;
  final Color secondary;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) {
      return;
    }

    final rect = Offset.zero & size;
    final glow = Paint()
      ..shader = RadialGradient(
        center: const Alignment(-0.2, -0.45),
        radius: 1.1,
        colors: [
          accent.withValues(alpha: success ? 0.1 * progress : 0.08 * progress),
          Colors.transparent,
        ],
      ).createShader(rect);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(28)),
      glow,
    );

    if (success) {
      _paintCrystalBloom(canvas, size);
    } else {
      _paintCracks(canvas, size);
    }
  }

  void _paintCrystalBloom(Canvas canvas, Size size) {
    final center = Offset(size.width * 0.26, size.height * 0.36);

    for (var index = 0; index < 10; index++) {
      final angle = (-0.9 + (index * 0.22)) * math.pi;
      final length = (size.shortestSide * 0.12) + (index * (spread * 0.32));
      final start = Offset(
        center.dx + (math.cos(angle) * length * 0.2),
        center.dy + (math.sin(angle) * length * 0.2),
      );
      final end = Offset(
        center.dx + (math.cos(angle) * length * progress),
        center.dy + (math.sin(angle) * length * progress),
      );
      final line = Paint()
        ..color = Color.lerp(
          accent,
          secondary,
          index / 10,
        )!.withValues(alpha: 0.12 + (0.26 * progress))
        ..strokeWidth = 1.2 + ((index % 3) * 0.5)
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
      canvas.drawLine(start, end, line);
    }

    final shardPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.15
      ..color = Colors.white.withValues(alpha: 0.16 + (0.18 * progress))
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);

    for (var index = 0; index < 4; index++) {
      final left = size.width * (0.48 + (index * 0.09));
      final top = size.height * (0.16 + ((index % 2) * 0.16));
      final shard = Path()
        ..moveTo(left, top)
        ..lineTo(
          left + ((spread * 0.78) * progress),
          top + ((spread * 0.64) * progress),
        )
        ..lineTo(
          left + ((spread * 0.42) * progress),
          top + ((spread * 1.92) * progress),
        )
        ..lineTo(left - ((spread * 0.58) * progress), top + (spread * progress))
        ..close();
      canvas.drawPath(shard, shardPaint);
    }
  }

  void _paintCracks(Canvas canvas, Size size) {
    final frost = Paint()
      ..shader = LinearGradient(
        colors: [
          const Color(0x66FFFFFF).withValues(alpha: 0.08 * progress),
          Colors.transparent,
          secondary.withValues(alpha: 0.12 * progress),
        ],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ).createShader(Offset.zero & size);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(28)),
      frost,
    );

    final crackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.25
      ..strokeCap = StrokeCap.round
      ..color = accent.withValues(alpha: 0.26 + (0.18 * progress))
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);

    for (var index = 0; index < 5; index++) {
      final path = Path()..moveTo(size.width * (0.06 + (index * 0.14)), 0);
      for (var segment = 0; segment < 5; segment++) {
        final x =
            size.width *
            (0.08 + (index * 0.14) + (math.sin(segment + index * 0.7) * 0.03));
        final y = size.height * (0.14 + (segment * 0.16) * progress);
        path.lineTo(x, y);
      }
      canvas.drawPath(path, crackPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _CrystalOutcomePainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.success != success ||
        oldDelegate.accent != accent ||
        oldDelegate.spread != spread ||
        oldDelegate.secondary != secondary;
  }
}

class _BrandFocusCard extends StatelessWidget {
  const _BrandFocusCard({
    required this.title,
    required this.body,
    required this.websitePrompt,
  });

  final String title;
  final String body;
  final String websitePrompt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      height: 280,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(
          colors: [
            theme.colorScheme.primary.withValues(alpha: 0.24),
            theme.colorScheme.tertiary.withValues(alpha: 0.12),
            Colors.black.withValues(alpha: 0.12),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.28),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 112,
                  height: 112,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(28),
                    color: Colors.white.withValues(alpha: 0.08),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.1),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Image.asset(
                      'assets/branding/roasd-logo.png',
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        websitePrompt,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: Colors.white,
                          height: 1.3,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          color: Colors.white.withValues(alpha: 0.08),
                          border: Border.all(
                            color: theme.colorScheme.primary.withValues(
                              alpha: 0.22,
                            ),
                          ),
                        ),
                        child: Text(
                          'www.project.ro-asd.org',
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: theme.colorScheme.primaryContainer,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const Spacer(),
            Text(
              title,
              style: theme.textTheme.headlineSmall?.copyWith(
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              body,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: Colors.white.withValues(alpha: 0.82),
                height: 1.45,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SlideshowCard extends StatelessWidget {
  const _SlideshowCard({
    required this.compact,
    required this.slideImage,
    required this.slideCaption,
  });

  final bool compact;
  final String slideImage;
  final String slideCaption;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AnimatedContainer(
      duration: context.installerMotion.medium,
      curve: context.installerMotion.enterCurve,
      height: compact ? 260 : 280,
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.36),
        ),
        image: DecorationImage(
          image: AssetImage(slideImage),
          fit: BoxFit.cover,
          colorFilter: ColorFilter.mode(
            Colors.black.withValues(alpha: 0.32),
            BlendMode.darken,
          ),
        ),
      ),
      child: Align(
        alignment: Alignment.bottomLeft,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            slideCaption,
            style: theme.textTheme.headlineSmall?.copyWith(color: Colors.white),
          ),
        ),
      ),
    );
  }
}

Color _logColor(String line) {
  if (line.startsWith('[STDERR]') || line.contains('[HATA]')) {
    return Colors.redAccent;
  }
  if (line.startsWith('[LOG]')) {
    return const Color(0xFF7AD7FF);
  }
  if (line.startsWith('[REBOOT]')) {
    return const Color(0xFFFFC76E);
  }
  return const Color(0xFF6BE7B1);
}
