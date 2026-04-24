import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/installer_state.dart';
import '../theme/app_theme.dart';
import '../widgets/nebula_ui.dart';

class KernelScreen extends StatelessWidget {
  const KernelScreen({super.key});

  String _buttonLabel(
    InstallerState state,
    bool experimental,
    bool online,
    bool selected,
  ) {
    if (selected) {
      return state.t('kernel_button_selected');
    }

    if (experimental && !online) {
      return state.t('kernel_button_network_required');
    }

    if (experimental) {
      return state.t('kernel_button_experimental');
    }

    return state.t('kernel_button_stable');
  }

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<InstallerState>(context);
    final theme = Theme.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 1040;
        final dense = constraints.maxHeight < 900;
        final online = state.networkStatus == 'connected';

        final stableCard = _KernelCard(
          title: state.t('kernel_stable_title'),
          description: state.t('kernel_stable_desc'),
          accent: theme.colorScheme.primary,
          icon: Icons.verified_rounded,
          selected: state.kernelType == 'stable',
          channelLabel: state.t('kernel_channel_stable'),
          featureA: state.t('kernel_s_feat1'),
          featureB: state.t('kernel_s_feat2'),
          buttonLabel: _buttonLabel(
            state,
            false,
            true,
            state.kernelType == 'stable',
          ),
          statusLabel: state.kernelType == 'stable'
              ? state.t('kernel_status_active')
              : state.t('kernel_status_available'),
          onSelect: () => state.updateKernel('stable'),
          dense: dense,
        );

        final experimentalCard = _KernelCard(
          title: state.t('kernel_exp_title'),
          description: state.t('kernel_exp_desc'),
          accent: const Color(0xFFFF906A),
          icon: Icons.science_rounded,
          selected: state.kernelType == 'experimental' && online,
          channelLabel: state.t('kernel_channel_experimental'),
          featureA: state.t('kernel_e_feat1'),
          featureB: state.t('kernel_e_feat2'),
          buttonLabel: _buttonLabel(
            state,
            true,
            online,
            state.kernelType == 'experimental' && online,
          ),
          statusLabel: !online
              ? state.t('kernel_status_offline_gated')
              : state.kernelType == 'experimental'
              ? state.t('kernel_status_active')
              : state.t('kernel_status_available'),
          disabled: !online,
          disabledMessage: state.t('kernel_network_required_message'),
          onSelect: () {
            if (online) {
              state.updateKernel('experimental');
            }
          },
          dense: dense,
        );

        return Column(
          children: [
            const SizedBox(height: 10),
            NebulaScreenIntro(
              badge: state.t('kernel_badge'),
              title: state.t('kernel_title'),
              description: state.t('kernel_desc'),
            ),
            const SizedBox(height: 28),
            NebulaPanel(
              padding: EdgeInsets.all(dense ? 22 : 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  NebulaSectionLabel(state.t('kernel_summary')),
                  SizedBox(height: dense ? 12 : 16),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      NebulaStatusChip(
                        label: online
                            ? state.t('net_ready')
                            : state.t('offline_status'),
                        color: online
                            ? theme.colorScheme.tertiary
                            : theme.colorScheme.outline,
                        icon: online
                            ? Icons.cloud_done_rounded
                            : Icons.cloud_off_rounded,
                      ),
                      NebulaStatusChip(
                        label: state.installType == 'advanced'
                            ? state.t('kernel_path_advanced')
                            : state.t('kernel_path_standard'),
                        color: theme.colorScheme.primary,
                        icon: Icons.tune_rounded,
                      ),
                      NebulaStatusChip(
                        label: state.t('install_est'),
                        color: theme.colorScheme.secondary,
                        icon: Icons.schedule_rounded,
                      ),
                    ],
                  ),
                  SizedBox(height: dense ? 12 : 16),
                  Text(
                    state.t('kernel_summary_note'),
                    style:
                        (dense
                                ? theme.textTheme.bodySmall
                                : theme.textTheme.bodyMedium)
                            ?.copyWith(
                              color: context.installerVisuals.mutedForeground,
                            ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Expanded(
              child: compact
                  ? SingleChildScrollView(
                      child: Column(
                        children: [
                          stableCard,
                          const SizedBox(height: 18),
                          experimentalCard,
                        ],
                      ),
                    )
                  : Row(
                      children: [
                        Expanded(child: stableCard),
                        const SizedBox(width: 22),
                        Expanded(child: experimentalCard),
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
                      state.t('install_est'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: context.installerVisuals.mutedForeground,
                      ),
                    ),
                  ),
                NebulaPrimaryButton(
                  label: state.t('install_init'),
                  icon: Icons.rocket_launch_rounded,
                  onPressed: state.nextStep,
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _KernelCard extends StatelessWidget {
  const _KernelCard({
    required this.title,
    required this.description,
    required this.accent,
    required this.icon,
    required this.selected,
    required this.channelLabel,
    required this.featureA,
    required this.featureB,
    required this.buttonLabel,
    required this.statusLabel,
    required this.onSelect,
    required this.dense,
    this.disabled = false,
    this.disabledMessage,
  });

  final String title;
  final String description;
  final Color accent;
  final IconData icon;
  final bool selected;
  final String channelLabel;
  final String featureA;
  final String featureB;
  final String buttonLabel;
  final String statusLabel;
  final VoidCallback onSelect;
  final bool dense;
  final bool disabled;
  final String? disabledMessage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final panelPadding = dense ? 16.0 : 22.0;
    final headerSize = dense ? 38.0 : 50.0;

    return AnimatedContainer(
      duration: context.installerMotion.medium,
      curve: context.installerMotion.enterCurve,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(32),
        border: Border.all(
          color: disabled
              ? theme.colorScheme.outlineVariant.withValues(alpha: 0.24)
              : selected
              ? accent.withValues(alpha: 0.82)
              : theme.colorScheme.outlineVariant.withValues(alpha: 0.34),
        ),
        boxShadow: selected && !disabled
            ? [
                BoxShadow(
                  color: accent.withValues(alpha: 0.18),
                  blurRadius: 28,
                  spreadRadius: -12,
                ),
              ]
            : const [],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(32),
          onTap: disabled ? null : onSelect,
          child: NebulaPanel(
            padding: EdgeInsets.all(panelPadding),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final boundedHeight = constraints.maxHeight.isFinite;

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: headerSize,
                          height: headerSize,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: accent.withValues(
                              alpha: disabled ? 0.08 : 0.16,
                            ),
                          ),
                          child: Icon(
                            icon,
                            color: disabled
                                ? theme.colorScheme.outline
                                : accent,
                            size: dense ? 22 : 28,
                          ),
                        ),
                        const Spacer(),
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
                              : theme.colorScheme.outline.withValues(
                                  alpha: 0.7,
                                ),
                        ),
                      ],
                    ),
                    SizedBox(height: dense ? 16 : 22),
                    Text(
                      title,
                      style:
                          (dense
                                  ? theme.textTheme.titleMedium
                                  : theme.textTheme.headlineSmall)
                              ?.copyWith(
                                color: disabled
                                    ? theme.colorScheme.outline
                                    : theme.colorScheme.onSurface,
                              ),
                    ),
                    SizedBox(height: dense ? 6 : 10),
                    Text(
                      description,
                      style:
                          (dense
                                  ? theme.textTheme.bodySmall
                                  : theme.textTheme.bodyMedium)
                              ?.copyWith(
                                color: disabled
                                    ? theme.colorScheme.outline.withValues(
                                        alpha: 0.82,
                                      )
                                    : context.installerVisuals.mutedForeground,
                                height: 1.35,
                              ),
                    ),
                    SizedBox(height: dense ? 12 : 18),
                    _KernelFeature(
                      text: featureA,
                      color: accent,
                      disabled: disabled,
                    ),
                    SizedBox(height: dense ? 6 : 8),
                    _KernelFeature(
                      text: featureB,
                      color: accent,
                      disabled: disabled,
                    ),
                    SizedBox(height: dense ? 12 : 18),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _KernelMetaChip(
                          label: channelLabel,
                          color: accent,
                          icon: Icons.bolt_rounded,
                        ),
                        _KernelMetaChip(
                          label: statusLabel,
                          color: disabled
                              ? theme.colorScheme.outline
                              : selected
                              ? const Color(0xFF6BE7B1)
                              : theme.colorScheme.secondary,
                          icon: disabled
                              ? Icons.cloud_off_rounded
                              : selected
                              ? Icons.check_rounded
                              : Icons.play_arrow_rounded,
                        ),
                      ],
                    ),
                    if (disabled && disabledMessage != null) ...[
                      SizedBox(height: dense ? 12 : 16),
                      Container(
                        width: double.infinity,
                        padding: EdgeInsets.all(dense ? 12 : 14),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          color: Colors.redAccent.withValues(alpha: 0.08),
                          border: Border.all(
                            color: Colors.redAccent.withValues(alpha: 0.18),
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(
                              Icons.warning_amber_rounded,
                              color: Colors.redAccent,
                              size: 18,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                disabledMessage!,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: Colors.redAccent,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (boundedHeight && !dense) const Spacer(),
                    SizedBox(height: dense ? 12 : 22),
                    SizedBox(
                      width: double.infinity,
                      child: selected && !disabled
                          ? NebulaPrimaryButton(
                              label: buttonLabel,
                              icon: Icons.check_rounded,
                              onPressed: onSelect,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 10,
                              ),
                            )
                          : NebulaSecondaryButton(
                              label: buttonLabel,
                              icon: disabled
                                  ? Icons.cloud_off_rounded
                                  : Icons.arrow_forward_rounded,
                              onPressed: disabled ? null : onSelect,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 10,
                              ),
                            ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _KernelFeature extends StatelessWidget {
  const _KernelFeature({
    required this.text,
    required this.color,
    required this.disabled,
  });

  final String text;
  final Color color;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.check_circle_rounded,
          size: 16,
          color: disabled ? theme.colorScheme.outline : color,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: disabled
                  ? theme.colorScheme.outline.withValues(alpha: 0.82)
                  : context.installerVisuals.mutedForeground,
              height: 1.3,
            ),
          ),
        ),
      ],
    );
  }
}

class _KernelMetaChip extends StatelessWidget {
  const _KernelMetaChip({
    required this.label,
    required this.color,
    required this.icon,
  });

  final String label;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: color,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }
}
