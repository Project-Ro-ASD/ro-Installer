import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/disk_service.dart';
import '../state/installer_state.dart';
import '../theme/app_theme.dart';
import '../widgets/nebula_ui.dart';

class DiskSelectionScreen extends StatefulWidget {
  const DiskSelectionScreen({super.key});

  @override
  State<DiskSelectionScreen> createState() => _DiskSelectionScreenState();
}

class _DiskSelectionScreenState extends State<DiskSelectionScreen> {
  List<Map<String, dynamic>> _disks = <Map<String, dynamic>>[];
  bool _isLoading = true;

  Future<bool?> _showDecisionDialog({
    required Color accent,
    required IconData icon,
    required String title,
    required String message,
    required String confirmLabel,
    required String cancelLabel,
    bool showCancel = true,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 24,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: NebulaPanel(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 58,
                    height: 58,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: accent.withValues(alpha: 0.14),
                    ),
                    child: Icon(icon, color: accent, size: 28),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    title,
                    style: Theme.of(
                      context,
                    ).textTheme.headlineSmall?.copyWith(color: accent),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    message,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: context.installerVisuals.mutedForeground,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 22),
                  Row(
                    children: [
                      if (showCancel)
                        NebulaSecondaryButton(
                          label: cancelLabel,
                          icon: Icons.close_rounded,
                          onPressed: () => Navigator.pop(dialogContext, false),
                        ),
                      if (showCancel) const Spacer(),
                      NebulaPrimaryButton(
                        label: confirmLabel,
                        icon: Icons.arrow_forward_rounded,
                        onPressed: () => Navigator.pop(dialogContext, true),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  void initState() {
    super.initState();
    _loadDisks();
  }

  Future<void> _loadDisks() async {
    setState(() => _isLoading = true);
    final diskList = await DiskService.instance.getDisks();

    if (!mounted) {
      return;
    }

    final state = Provider.of<InstallerState>(context, listen: false);

    setState(() {
      _disks = diskList.map((disk) => Map<String, dynamic>.from(disk)).toList();

      if (_disks.isNotEmpty && state.selectedDisk.isEmpty) {
        final safeDisks = _disks
            .where((disk) => disk['isLive'] != true)
            .toList();
        if (safeDisks.isNotEmpty) {
          state.selectDisk(safeDisks.first);
        }
      }

      _isLoading = false;
    });
  }

  Future<void> _confirmAndContinue(InstallerState state) async {
    if (state.selectedDisk.isEmpty || state.selectedDiskDetails == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(state.t('disk_missing_target')),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final isLive = state.selectedDiskDetails!['isLive'] == true;
    final isSafe = state.selectedDiskDetails!['isSafe'] == true;
    final partitionMethod = state.partitionMethod;

    if (isLive) {
      await _showDecisionDialog(
        accent: Colors.redAccent,
        icon: Icons.warning_amber_rounded,
        title: state.t('disk_live_target_title'),
        message: state.t('disk_live_target_body'),
        confirmLabel: state.t('ok'),
        cancelLabel: state.t('cancel'),
        showCancel: false,
      );
      return;
    }

    if (partitionMethod == 'manual') {
      state.nextStep();
      return;
    }

    if (partitionMethod == 'alongside') {
      final confirmed = await _showDecisionDialog(
        accent: const Color(0xFF6BE7B1),
        icon: Icons.call_split_rounded,
        title: state.t('disk_alongside_confirm_title'),
        message: state.t('disk_alongside_confirm_body', {
          'disk': state.selectedDisk,
          'size': '${state.linuxDiskSizeGB.toStringAsFixed(1)} GB',
          'source': state.shrinkCandidatePartition.isNotEmpty
              ? state.shrinkCandidatePartition
              : state.selectedDisk,
        }),
        confirmLabel: state.t('disk_alongside_confirm_action'),
        cancelLabel: state.t('cancel'),
      );

      if (confirmed == true && mounted) {
        state.nextStep();
      }
      return;
    }

    final confirmed = await _showDecisionDialog(
      accent: isSafe ? const Color(0xFF6BE7B1) : Colors.redAccent,
      icon: isSafe ? Icons.science_rounded : Icons.delete_forever_rounded,
      title: isSafe
          ? state.t('disk_safe_confirm_title')
          : state.t('disk_danger_confirm_title'),
      message: isSafe
          ? state.t('disk_safe_confirm_body', {'disk': state.selectedDisk})
          : state.t('disk_danger_confirm_body', {'disk': state.selectedDisk}),
      confirmLabel: isSafe
          ? state.t('disk_safe_confirm_action')
          : state.t('disk_danger_confirm_action'),
      cancelLabel: state.t('cancel'),
    );

    if (confirmed == true && mounted) {
      state.nextStep();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<InstallerState>(context);
    final theme = Theme.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 1120;
        final denseDesktop = !compact && constraints.maxHeight < 840;

        final diskPanel = _DiskInventoryPanel(
          compact: compact,
          dense: denseDesktop,
          isLoading: _isLoading,
          disks: _disks,
          selectedDisk: state.selectedDisk,
          onRefresh: _isLoading ? null : _loadDisks,
          onSelect: state.selectDisk,
        );
        final strategyPanel = _InstallationPlanPanel(
          state: state,
          dense: denseDesktop || compact,
        );

        final compactControls = Column(
          children: [
            strategyPanel,
            const SizedBox(height: 18),
            _StorageSummaryPanel(state: state),
            const SizedBox(height: 18),
            _DeploymentPlanPanel(state: state, dense: true),
          ],
        );

        return Column(
          children: [
            const SizedBox(height: 10),
            NebulaScreenIntro(
              badge: state.t('disk_badge'),
              title: state.t('disk_title'),
              description: state.t('disk_desc'),
            ),
            const SizedBox(height: 28),
            if (compact)
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      diskPanel,
                      const SizedBox(height: 18),
                      compactControls,
                    ],
                  ),
                ),
              )
            else
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 5, child: diskPanel),
                    const SizedBox(width: 16),
                    Expanded(flex: 5, child: strategyPanel),
                    const SizedBox(width: 16),
                    Expanded(
                      flex: 6,
                      child: Column(
                        children: [
                          _StorageSummaryPanel(state: state, dense: true),
                          SizedBox(height: denseDesktop ? 12 : 18),
                          Expanded(
                            child: _DeploymentPlanPanel(
                              state: state,
                              dense: true,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 24),
            Row(
              children: [
                NebulaSecondaryButton(
                  label: state.t('prev'),
                  icon: Icons.arrow_back_rounded,
                  onPressed: state.previousStep,
                ),
                const Spacer(),
                if (!compact)
                  Padding(
                    padding: const EdgeInsets.only(right: 16),
                    child: Text(
                      state.t('disk_policy_note'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: context.installerVisuals.mutedForeground,
                      ),
                    ),
                  ),
                NebulaPrimaryButton(
                  label: state.t('next'),
                  icon: Icons.arrow_forward_rounded,
                  onPressed: () => _confirmAndContinue(state),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _InstallationPlanPanel extends StatelessWidget {
  const _InstallationPlanPanel({required this.state, this.dense = false});

  final InstallerState state;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final alongsideAvailability = _methodAvailability(state, 'alongside');
    final showManual = state.installType == 'advanced';

    return NebulaPanel(
      padding: EdgeInsets.all(dense ? 22 : 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          NebulaSectionLabel(state.t('disk_plan_label')),
          const SizedBox(height: 10),
          Text(
            state.t('disk_plan_hint'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: context.installerVisuals.mutedForeground,
              height: 1.45,
            ),
          ),
          SizedBox(height: dense ? 14 : 18),
          _CompactMethodGrid(
            state: state,
            alongsideAvailability: alongsideAvailability,
            showManual: showManual,
          ),
        ],
      ),
    );
  }
}

class _DiskInventoryPanel extends StatelessWidget {
  const _DiskInventoryPanel({
    required this.compact,
    required this.dense,
    required this.isLoading,
    required this.disks,
    required this.selectedDisk,
    required this.onRefresh,
    required this.onSelect,
  });

  final bool compact;
  final bool dense;
  final bool isLoading;
  final List<Map<String, dynamic>> disks;
  final String selectedDisk;
  final Future<void> Function()? onRefresh;
  final ValueChanged<Map<String, dynamic>> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = Provider.of<InstallerState>(context, listen: false);

    Widget body;
    if (isLoading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (disks.isEmpty) {
      body = _DiskEmptyState(onRefresh: onRefresh);
    } else {
      body = ListView.separated(
        itemCount: disks.length,
        itemBuilder: (context, index) {
          final disk = disks[index];
          return _DiskCard(
            disk: disk,
            dense: dense,
            selected: selectedDisk == disk['name'],
            onTap: () => onSelect(disk),
          );
        },
        separatorBuilder: (context, index) => const SizedBox(height: 14),
      );
    }

    final viewport = compact
        ? SizedBox(height: 390, child: body)
        : Expanded(child: body);

    return NebulaPanel(
      padding: EdgeInsets.all(dense ? 22 : 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    NebulaSectionLabel(state.t('disk_target_drives')),
                    SizedBox(height: dense ? 8 : 12),
                    Text(
                      state.t('disk_target_hint'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: context.installerVisuals.mutedForeground,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              IconButton(
                onPressed: onRefresh,
                tooltip: state.t('disk_target_refresh'),
                icon: Icon(
                  Icons.refresh_rounded,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
          SizedBox(height: dense ? 14 : 22),
          viewport,
        ],
      ),
    );
  }
}

class _DiskCard extends StatelessWidget {
  const _DiskCard({
    required this.disk,
    required this.dense,
    required this.selected,
    required this.onTap,
  });

  final Map<String, dynamic> disk;
  final bool dense;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = Provider.of<InstallerState>(context, listen: false);
    final tone = _diskTone(theme, state, disk);
    final model = (disk['model'] ?? state.t('disk_unknown_drive'))
        .toString()
        .trim();
    final size = _diskSizeLabel(disk['size']);

    return AnimatedContainer(
      duration: context.installerMotion.medium,
      curve: context.installerMotion.enterCurve,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: selected
              ? tone.color.withValues(alpha: 0.72)
              : theme.colorScheme.outlineVariant.withValues(alpha: 0.38),
          width: selected ? 1.8 : 1,
        ),
        boxShadow: selected
            ? [
                BoxShadow(
                  color: tone.color.withValues(alpha: 0.18),
                  blurRadius: 30,
                  spreadRadius: -10,
                ),
              ]
            : const [],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.all(dense ? 14 : 18),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: dense ? 40 : 48,
                  height: dense ? 40 : 48,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: tone.color.withValues(alpha: 0.14),
                  ),
                  child: Icon(
                    tone.icon,
                    color: tone.color,
                    size: dense ? 20 : 24,
                  ),
                ),
                SizedBox(width: dense ? 12 : 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              (disk['name'] ?? '/dev/unknown').toString(),
                              style: dense
                                  ? theme.textTheme.titleSmall
                                  : theme.textTheme.titleMedium,
                            ),
                          ),
                          if (selected)
                            Icon(
                              Icons.check_circle_rounded,
                              color: tone.color,
                              size: 20,
                            ),
                        ],
                      ),
                      SizedBox(height: dense ? 4 : 6),
                      Text(
                        model.isEmpty ? 'Unknown Drive' : model,
                        style:
                            (dense
                                    ? theme.textTheme.bodySmall
                                    : theme.textTheme.bodyMedium)
                                ?.copyWith(
                                  color:
                                      context.installerVisuals.mutedForeground,
                                ),
                      ),
                      SizedBox(height: dense ? 10 : 14),
                      Wrap(
                        spacing: dense ? 8 : 10,
                        runSpacing: dense ? 8 : 10,
                        children: [
                          _InfoBadge(
                            label: tone.label,
                            color: tone.color,
                            icon: tone.icon,
                            dense: dense,
                          ),
                          _InfoBadge(
                            label: size,
                            color: theme.colorScheme.primary,
                            icon: Icons.storage_rounded,
                            dense: dense,
                          ),
                          _InfoBadge(
                            label: (disk['type'] ?? 'disk')
                                .toString()
                                .toUpperCase(),
                            color: theme.colorScheme.tertiary,
                            icon: Icons.settings_input_component_rounded,
                            dense: dense,
                          ),
                        ],
                      ),
                      SizedBox(height: dense ? 8 : 12),
                      Text(
                        tone.subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: tone.color.withValues(alpha: 0.92),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StorageSummaryPanel extends StatelessWidget {
  const _StorageSummaryPanel({required this.state, this.dense = false});

  final InstallerState state;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = state.selectedDiskDetails;
    final selectedTone = _diskTone(theme, state, selected);
    final sectionGap = dense ? 14.0 : 18.0;
    final metricGap = dense ? 10.0 : 12.0;

    return NebulaPanel(
      padding: EdgeInsets.all(dense ? 22 : 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          NebulaSectionLabel(state.t('disk_target_section')),
          SizedBox(height: sectionGap),
          if (selected == null)
            Text(
              state.t('disk_target_empty'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: context.installerVisuals.mutedForeground,
              ),
            )
          else ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    state.selectedDisk,
                    style: dense
                        ? theme.textTheme.titleLarge
                        : theme.textTheme.headlineSmall,
                  ),
                ),
                NebulaStatusChip(
                  label: selectedTone.label,
                  color: selectedTone.color,
                  icon: selectedTone.icon,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              (selected['model'] ?? state.t('disk_unknown_drive')).toString(),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: context.installerVisuals.mutedForeground,
              ),
            ),
            SizedBox(height: dense ? 16 : 20),
            LayoutBuilder(
              builder: (context, constraints) {
                final singleColumn = constraints.maxWidth < 320;
                final metricWidth = singleColumn
                    ? constraints.maxWidth
                    : (constraints.maxWidth - metricGap) / 2;

                return Wrap(
                  spacing: metricGap,
                  runSpacing: metricGap,
                  children: [
                    SizedBox(
                      width: metricWidth,
                      child: _SummaryMetric(
                        label: state.t('disk_capacity'),
                        value: _diskSizeLabel(selected['size']),
                        icon: Icons.save_rounded,
                        dense: dense,
                      ),
                    ),
                    SizedBox(
                      width: metricWidth,
                      child: _SummaryMetric(
                        label: state.t('disk_filesystem'),
                        value: state.fileSystem.toUpperCase(),
                        icon: Icons.data_object_rounded,
                        dense: dense,
                      ),
                    ),
                    SizedBox(
                      width: metricWidth,
                      child: _SummaryMetric(
                        label: state.t('disk_install_type'),
                        value: state.installType == 'advanced'
                            ? state.t('install_type_advanced')
                            : state.t('install_type_standard'),
                        icon: Icons.tune_rounded,
                        dense: dense,
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}

class _DeploymentPlanPanel extends StatelessWidget {
  const _DeploymentPlanPanel({required this.state, this.dense = false});

  final InstallerState state;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final freeGb = state.diskFreeSpaceBytes / (1024 * 1024 * 1024);
    final freeRatio = state.totalDiskSizeGB <= 0
        ? 0.0
        : (freeGb / state.totalDiskSizeGB).clamp(0.0, 1.0);

    return NebulaPanel(
      padding: EdgeInsets.all(dense ? 22 : 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(state.t('disk_analysis'), style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          if (state.isDetectingOS)
            Text(
              state.t('disk_scanning'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: context.installerVisuals.mutedForeground,
              ),
            )
          else
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                NebulaStatusChip(
                  label: state.hasExistingOS
                      ? state
                            .t('disk_detected_os')
                            .replaceFirst('{os}', state.detectedOS)
                      : state.t('disk_no_secondary_os'),
                  color: state.hasExistingOS
                      ? const Color(0xFF6BE7B1)
                      : theme.colorScheme.outline,
                  icon: state.hasExistingOS
                      ? Icons.computer_rounded
                      : Icons.blur_on_rounded,
                ),
                NebulaStatusChip(
                  label: state.hasExistingEfi
                      ? state.t('disk_efi_ready')
                      : state.t('disk_efi_create'),
                  color: state.hasExistingEfi
                      ? theme.colorScheme.tertiary
                      : theme.colorScheme.secondary,
                  icon: state.hasExistingEfi
                      ? Icons.verified_rounded
                      : Icons.add_rounded,
                ),
                NebulaStatusChip(
                  label: state
                      .t('disk_free')
                      .replaceFirst(
                        '{size}',
                        '${freeGb.toStringAsFixed(1)} GB',
                      ),
                  color: theme.colorScheme.primary,
                  icon: Icons.space_dashboard_rounded,
                ),
                NebulaStatusChip(
                  label: _bootModeChipLabel(state),
                  color: state.diskBootMode == 'uefi'
                      ? theme.colorScheme.secondary
                      : Colors.orangeAccent,
                  icon: state.diskBootMode == 'uefi'
                      ? Icons.usb_rounded
                      : Icons.warning_amber_rounded,
                ),
                NebulaStatusChip(
                  label: _partitionTableChipLabel(state),
                  color: state.diskPartitionTable == 'gpt'
                      ? theme.colorScheme.secondary
                      : Colors.orangeAccent,
                  icon: state.diskPartitionTable == 'gpt'
                      ? Icons.table_chart_rounded
                      : Icons.report_problem_rounded,
                ),
                if (state.shrinkCandidatePartition.isNotEmpty)
                  NebulaStatusChip(
                    label: _shrinkCandidateChipLabel(state),
                    color: const Color(0xFF8CB6FF),
                    icon: Icons.compress_rounded,
                  ),
              ],
            ),
          const SizedBox(height: 18),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              minHeight: dense ? 10 : 12,
              value: freeRatio,
              backgroundColor: theme.colorScheme.surface.withValues(
                alpha: theme.brightness == Brightness.dark ? 0.35 : 0.65,
              ),
              valueColor: AlwaysStoppedAnimation<Color>(
                theme.colorScheme.primary,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            state.t('disk_capacity_note'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: context.installerVisuals.mutedForeground,
            ),
          ),
        ],
      ),
    );
  }
}

class _CompactMethodGrid extends StatelessWidget {
  const _CompactMethodGrid({
    required this.state,
    required this.alongsideAvailability,
    required this.showManual,
  });

  final InstallerState state;
  final _MethodAvailability alongsideAvailability;
  final bool showManual;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final options = <Widget>[
      _CompactMethodOption(
        label: state.t('disk_full'),
        caption: state.t('disk_full_caption'),
        icon: Icons.delete_sweep_rounded,
        accent: const Color(0xFFFF8C7A),
        selected: state.partitionMethod == 'full',
        disabled: false,
        onTap: () => state.updatePartitionMethod('full'),
      ),
      _CompactMethodOption(
        label: state.t('disk_alongside'),
        caption: _alongsideCaption(state),
        icon: Icons.call_split_rounded,
        accent: theme.colorScheme.tertiary,
        selected: state.partitionMethod == 'alongside',
        disabled: alongsideAvailability.disabled,
        onTap: () => state.updatePartitionMethod('alongside'),
      ),
      if (showManual)
        _CompactMethodOption(
          label: state.t('disk_manual'),
          caption: state.t('disk_manual_caption'),
          icon: Icons.handyman_rounded,
          accent: const Color(0xFF8CB6FF),
          selected: state.partitionMethod == 'manual',
          disabled: false,
          onTap: () => state.updatePartitionMethod('manual'),
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final width = showManual && constraints.maxWidth >= 520
                ? (constraints.maxWidth - 12) / 2
                : constraints.maxWidth;

            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: options
                  .map((option) => SizedBox(width: width, child: option))
                  .toList(),
            );
          },
        ),
        if (alongsideAvailability.disabled &&
            alongsideAvailability.reasons.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: Colors.redAccent.withValues(alpha: 0.08),
              border: Border.all(
                color: Colors.redAccent.withValues(alpha: 0.18),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  state.t('disk_alongside_locked_title'),
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: Colors.redAccent,
                  ),
                ),
                const SizedBox(height: 8),
                ...alongsideAvailability.reasons.map(
                  (reason) => Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      '• $reason',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.redAccent,
                        height: 1.35,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        if (!alongsideAvailability.disabled &&
            state.partitionMethod != 'alongside' &&
            state.shrinkCandidatePartition.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            _alongsideReadyHint(state),
            style: theme.textTheme.bodySmall?.copyWith(
              color: context.installerVisuals.mutedForeground,
              height: 1.35,
            ),
          ),
        ],
        if (state.partitionMethod == 'alongside' &&
            !alongsideAvailability.disabled) ...[
          const SizedBox(height: 12),
          _AlongsideSizeAllocator(visible: true, state: state, dense: true),
        ],
      ],
    );
  }
}

class _CompactMethodOption extends StatelessWidget {
  const _CompactMethodOption({
    required this.label,
    required this.caption,
    required this.icon,
    required this.accent,
    required this.selected,
    required this.disabled,
    required this.onTap,
  });

  final String label;
  final String caption;
  final IconData icon;
  final Color accent;
  final bool selected;
  final bool disabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: disabled ? null : onTap,
        child: AnimatedContainer(
          duration: context.installerMotion.medium,
          curve: context.installerMotion.enterCurve,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: disabled
                  ? theme.colorScheme.outlineVariant.withValues(alpha: 0.26)
                  : selected
                  ? accent.withValues(alpha: 0.82)
                  : theme.colorScheme.outlineVariant.withValues(alpha: 0.34),
            ),
            color: disabled
                ? theme.colorScheme.surface.withValues(alpha: 0.16)
                : theme.colorScheme.surface.withValues(alpha: 0.18),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accent.withValues(alpha: disabled ? 0.08 : 0.16),
                ),
                child: Icon(
                  icon,
                  size: 18,
                  color: disabled ? theme.colorScheme.outline : accent,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label.replaceAll('\n', ' '),
                      maxLines: 2,
                      overflow: TextOverflow.fade,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: disabled
                            ? theme.colorScheme.outline
                            : theme.colorScheme.onSurface,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      caption,
                      maxLines: 2,
                      overflow: TextOverflow.fade,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: disabled
                            ? theme.colorScheme.outline
                            : context.installerVisuals.mutedForeground,
                        height: 1.25,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Icon(
                disabled
                    ? Icons.lock_outline_rounded
                    : selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_off_rounded,
                color: disabled
                    ? theme.colorScheme.outline
                    : selected
                    ? accent
                    : theme.colorScheme.outline.withValues(alpha: 0.7),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AlongsideSizeAllocator extends StatelessWidget {
  const _AlongsideSizeAllocator({
    required this.visible,
    required this.state,
    this.dense = false,
  });

  final bool visible;
  final InstallerState state;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxSize = _alongsideSliderMax(state);
    final sliderValue = state.linuxDiskSizeGB.clamp(40.0, maxSize).toDouble();
    final maxFree = (state.alongsideMaxLinuxSizeBytes / (1024 * 1024 * 1024))
        .clamp(0.0, maxSize)
        .toDouble();

    return AnimatedCrossFade(
      duration: context.installerMotion.medium,
      crossFadeState: visible
          ? CrossFadeState.showSecond
          : CrossFadeState.showFirst,
      firstChild: const SizedBox(width: double.infinity, height: 0),
      secondChild: Container(
        width: double.infinity,
        padding: EdgeInsets.all(dense ? 12 : 16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: theme.colorScheme.surface.withValues(
            alpha: theme.brightness == Brightness.dark ? 0.22 : 0.6,
          ),
          border: Border.all(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.38),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              state.t('disk_alongside_size_title'),
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            Text(
              state.shrinkCandidatePartition.isNotEmpty
                  ? state.t('disk_alongside_size_shrink_desc')
                  : state.t('disk_alongside_size_free_desc'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: context.installerVisuals.mutedForeground,
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: _AllocationStat(
                    label: state.t('linux_size'),
                    value: '${sliderValue.toInt()} GB',
                    color: theme.colorScheme.primary,
                    dense: dense,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _AllocationStat(
                    label: state.t('disk_max_space'),
                    value: '${maxFree.toInt()} GB',
                    color: theme.colorScheme.outline,
                    dense: dense,
                  ),
                ),
              ],
            ),
            if (state.shrinkCandidatePartition.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                'Kaynak bolum: ${state.shrinkCandidatePartition} (${state.shrinkCandidateFs.toUpperCase()}). Bu bolumde en az 40 GB birakilacaktir.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: context.installerVisuals.mutedForeground,
                  height: 1.35,
                ),
              ),
            ],
            const SizedBox(height: 14),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 12,
                activeTrackColor: theme.colorScheme.primary,
                inactiveTrackColor: theme.colorScheme.outlineVariant.withValues(
                  alpha: 0.4,
                ),
                thumbColor: Colors.white,
                overlayColor: theme.colorScheme.primary.withValues(alpha: 0.12),
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10),
              ),
              child: Slider(
                value: sliderValue,
                min: 40.0,
                max: maxSize,
                onChanged: visible
                    ? (value) => state.updateLinuxDiskSize(value)
                    : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AllocationStat extends StatelessWidget {
  const _AllocationStat({
    required this.label,
    required this.value,
    required this.color,
    this.dense = false,
  });

  final String label;
  final String value;
  final Color color;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: EdgeInsets.all(dense ? 10 : 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(color: color),
          ),
          SizedBox(height: dense ? 4 : 6),
          Text(
            value,
            style: dense
                ? theme.textTheme.titleSmall
                : theme.textTheme.titleMedium,
          ),
        ],
      ),
    );
  }
}

class _SummaryMetric extends StatelessWidget {
  const _SummaryMetric({
    required this.label,
    required this.value,
    required this.icon,
    this.dense = false,
  });

  final String label;
  final String value;
  final IconData icon;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: EdgeInsets.all(dense ? 12 : 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: theme.colorScheme.surface.withValues(
          alpha: theme.brightness == Brightness.dark ? 0.22 : 0.56,
        ),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.42),
        ),
      ),
      child: Row(
        children: [
          Icon(icon, color: theme.colorScheme.primary, size: 18),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: context.installerVisuals.mutedForeground,
                  ),
                ),
                SizedBox(height: dense ? 2 : 4),
                Text(
                  value,
                  style: dense
                      ? theme.textTheme.titleSmall
                      : theme.textTheme.titleMedium,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoBadge extends StatelessWidget {
  const _InfoBadge({
    required this.label,
    required this.color,
    required this.icon,
    this.dense = false,
  });

  final String label;
  final Color color;
  final IconData icon;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 10 : 12,
        vertical: dense ? 6 : 8,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: dense ? 12 : 14),
          SizedBox(width: dense ? 6 : 8),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: color,
              fontSize: dense ? 10.5 : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _DiskEmptyState extends StatelessWidget {
  const _DiskEmptyState({required this.onRefresh});

  final Future<void> Function()? onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = Provider.of<InstallerState>(context, listen: false);

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.storage_outlined,
            size: 42,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(height: 14),
          Text(state.t('disk_empty_title'), style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            state.t('disk_empty_desc'),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: context.installerVisuals.mutedForeground,
            ),
          ),
          const SizedBox(height: 14),
          NebulaSecondaryButton(
            label: state.t('disk_empty_refresh'),
            icon: Icons.refresh_rounded,
            onPressed: onRefresh == null ? null : () => onRefresh!(),
          ),
        ],
      ),
    );
  }
}

class _MethodAvailability {
  const _MethodAvailability({required this.disabled, this.reasons = const []});

  final bool disabled;
  final List<String> reasons;
}

class _DiskTone {
  const _DiskTone({
    required this.icon,
    required this.color,
    required this.label,
    required this.subtitle,
  });

  final IconData icon;
  final Color color;
  final String label;
  final String subtitle;
}

_MethodAvailability _methodAvailability(InstallerState state, String code) {
  if (code != 'alongside') {
    return const _MethodAvailability(disabled: false);
  }

  if (state.isDetectingOS) {
    return _MethodAvailability(
      disabled: true,
      reasons: [state.t('disk_analysis_in_progress')],
    );
  }

  final reasons = _localizedAlongsideReasons(state);
  if (reasons.isNotEmpty) {
    return _MethodAvailability(disabled: true, reasons: reasons);
  }

  return const _MethodAvailability(disabled: false);
}

String _alongsideCaption(InstallerState state) {
  if (state.shrinkCandidatePartition.isNotEmpty &&
      state.shrinkCandidateFs.isNotEmpty) {
    return '${state.shrinkCandidateFs.toUpperCase()} • ${state.shrinkCandidatePartition}';
  }
  if (state.hasExistingOS) {
    return state.detectedOS;
  }
  return state.t('disk_dual_boot');
}

String _alongsideReadyHint(InstallerState state) {
  final maxSize = _alongsideSliderMax(state).toStringAsFixed(0);
  if (state.shrinkCandidatePartition.isNotEmpty) {
    return state.t('disk_alongside_ready_with_source', {
      'size': '$maxSize GB',
      'partition': state.shrinkCandidatePartition,
      'fs': state.shrinkCandidateFs.toUpperCase(),
    });
  }
  return state.t('disk_alongside_ready_free', {'size': '$maxSize GB'});
}

String _bootModeChipLabel(InstallerState state) {
  return state.diskBootMode == 'uefi'
      ? state.t('disk_boot_uefi')
      : state.t('disk_boot_legacy');
}

String _partitionTableChipLabel(InstallerState state) {
  final table = state.diskPartitionTable.toUpperCase();
  if (table == 'GPT') {
    return state.t('disk_partition_table_gpt');
  }
  return state.t('disk_partition_table_other', {
    'table': table.isEmpty ? state.t('unknown') : table,
  });
}

String _shrinkCandidateChipLabel(InstallerState state) {
  final sizeGb = state.shrinkCandidateSizeBytes / (1024 * 1024 * 1024);
  return state.t('disk_shrink_candidate', {
    'fs': state.shrinkCandidateFs.toUpperCase(),
    'size': '${sizeGb.toStringAsFixed(0)} GB',
  });
}

List<String> _localizedAlongsideReasons(InstallerState state) {
  final reasons = <String>[];
  for (final code in state.alongsideBlockers) {
    switch (code) {
      case 'boot_mode_not_uefi':
        reasons.add(state.t('disk_blocker_boot_mode_not_uefi'));
      case 'partition_table_not_gpt':
        reasons.add(state.t('disk_blocker_partition_table_not_gpt'));
      case 'missing_efi':
        reasons.add(state.t('disk_blocker_missing_efi'));
      case 'no_existing_os':
        reasons.add(state.t('disk_blocker_no_existing_os'));
      case 'no_shrink_candidate':
        reasons.add(state.t('disk_blocker_no_shrink_candidate'));
      case 'bitlocker_enabled':
        reasons.add(state.t('disk_blocker_bitlocker_enabled'));
      case 'ntfs_hibernated_or_fast_startup':
        reasons.add(state.t('disk_blocker_ntfs_hibernated_or_fast_startup'));
      case 'ntfs_dirty':
        reasons.add(state.t('disk_blocker_ntfs_dirty'));
      case 'ntfs_resize_tool_missing':
        reasons.add(state.t('disk_blocker_ntfs_resize_tool_missing'));
      case 'ext4_resize_tool_missing':
        reasons.add(state.t('disk_blocker_ext4_resize_tool_missing'));
      case 'ext4_check_tool_missing':
        reasons.add(state.t('disk_blocker_ext4_check_tool_missing'));
      case 'ntfs_check_failed':
        reasons.add(state.t('disk_blocker_ntfs_check_failed'));
      case 'alongside_minimum_not_met':
        reasons.add(state.t('disk_blocker_alongside_minimum_not_met'));
      case 'alongside_engine_pending':
        reasons.add(state.t('disk_blocker_alongside_engine_pending'));
      default:
        reasons.add(code);
    }
  }

  final unique = <String>{};
  return reasons.where(unique.add).toList(growable: false);
}

_DiskTone _diskTone(
  ThemeData theme,
  InstallerState state,
  Map<String, dynamic>? disk,
) {
  if (disk == null) {
    return _DiskTone(
      icon: Icons.blur_on_rounded,
      color: theme.colorScheme.outline,
      label: state.t('disk_tone_unassigned'),
      subtitle: state.t('disk_tone_unassigned_subtitle'),
    );
  }

  if (disk['isLive'] == true) {
    return _DiskTone(
      icon: Icons.usb_rounded,
      color: Colors.redAccent,
      label: state.t('disk_tone_live'),
      subtitle: state.t('disk_tone_live_subtitle'),
    );
  }

  if (disk['isHostOS'] == true) {
    return _DiskTone(
      icon: Icons.computer_rounded,
      color: Color(0xFFFFB347),
      label: state.t('disk_tone_host'),
      subtitle: state.t('disk_tone_host_subtitle'),
    );
  }

  if (disk['isSafe'] == true) {
    return _DiskTone(
      icon: Icons.science_rounded,
      color: Color(0xFF6BE7B1),
      label: state.t('disk_tone_safe'),
      subtitle: state.t('disk_tone_safe_subtitle'),
    );
  }

  return _DiskTone(
    icon: Icons.storage_rounded,
    color: theme.colorScheme.primary,
    label: state.t('disk_tone_available'),
    subtitle: state.t('disk_tone_available_subtitle'),
  );
}

String _diskSizeLabel(dynamic sizeBytes) {
  final size = sizeBytes is int ? sizeBytes.toDouble() : 0.0;
  final sizeGb = size / (1024 * 1024 * 1024);
  return '${sizeGb.toStringAsFixed(1)} GB';
}

double _alongsideSliderMax(InstallerState state) {
  final maxSize = state.alongsideMaxLinuxSizeBytes > 0
      ? state.alongsideMaxLinuxSizeBytes / (1024 * 1024 * 1024)
      : 40.0;
  return maxSize < 40 ? 40 : maxSize;
}
