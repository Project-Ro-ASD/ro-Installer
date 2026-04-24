import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/installer_state.dart';
import '../theme/app_theme.dart';
import '../widgets/nebula_ui.dart';

class TypeScreen extends StatelessWidget {
  const TypeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<InstallerState>(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 980;
        final dense = constraints.maxHeight < 840;

        return Column(
          children: [
            const SizedBox(height: 10),
            NebulaScreenIntro(
              badge: state.t('type_badge'),
              title: state.t('type_title'),
              description: state.t('type_desc'),
            ),
            const SizedBox(height: 28),
            Expanded(
              child: compact
                  ? SingleChildScrollView(
                      child: Column(
                        children: [
                          _TypeCard(
                            title: state.t('type_std_title'),
                            description: state.t('type_std_desc'),
                            accent: Theme.of(context).colorScheme.primary,
                            active: state.installType == 'standard',
                            icon: Icons.verified_user_rounded,
                            featureA: state.t('type_std_feature_a'),
                            featureB: state.t('type_std_feature_b'),
                            buttonLabel: state.t('type_std_btn'),
                            onSelect: () => state.updateInstallType('standard'),
                            dense: dense,
                          ),
                          const SizedBox(height: 18),
                          _TypeCard(
                            title: state.t('type_adv_title'),
                            description: state.t('type_adv_desc'),
                            accent: const Color(0xFFFF866E),
                            active: state.installType == 'advanced',
                            icon: Icons.memory_rounded,
                            featureA: state.t('type_adv_feature_a'),
                            featureB: state.t('type_adv_feature_b'),
                            buttonLabel: state.t('type_adv_btn'),
                            onSelect: () => state.updateInstallType('advanced'),
                            dense: dense,
                          ),
                        ],
                      ),
                    )
                  : Row(
                      children: [
                        Expanded(
                          child: _TypeCard(
                            title: state.t('type_std_title'),
                            description: state.t('type_std_desc'),
                            accent: Theme.of(context).colorScheme.primary,
                            active: state.installType == 'standard',
                            icon: Icons.verified_user_rounded,
                            featureA: state.t('type_std_feature_a'),
                            featureB: state.t('type_std_feature_b'),
                            buttonLabel: state.t('type_std_btn'),
                            onSelect: () => state.updateInstallType('standard'),
                            dense: dense,
                          ),
                        ),
                        const SizedBox(width: 22),
                        Expanded(
                          child: _TypeCard(
                            title: state.t('type_adv_title'),
                            description: state.t('type_adv_desc'),
                            accent: const Color(0xFFFF866E),
                            active: state.installType == 'advanced',
                            icon: Icons.memory_rounded,
                            featureA: state.t('type_adv_feature_a'),
                            featureB: state.t('type_adv_feature_b'),
                            buttonLabel: state.t('type_adv_btn'),
                            onSelect: () => state.updateInstallType('advanced'),
                            dense: dense,
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
                NebulaPrimaryButton(
                  label: state.t('next'),
                  icon: Icons.arrow_forward_rounded,
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

class _TypeCard extends StatelessWidget {
  const _TypeCard({
    required this.title,
    required this.description,
    required this.accent,
    required this.active,
    required this.icon,
    required this.featureA,
    required this.featureB,
    required this.buttonLabel,
    required this.onSelect,
    required this.dense,
  });

  final String title;
  final String description;
  final Color accent;
  final bool active;
  final IconData icon;
  final String featureA;
  final String featureB;
  final String buttonLabel;
  final VoidCallback onSelect;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final heroHeight = dense ? 132.0 : 220.0;
    final panelPadding = dense ? 18.0 : 24.0;
    final titleGap = dense ? 14.0 : 24.0;
    final descGap = dense ? 8.0 : 14.0;
    final featureGap = dense ? 12.0 : 20.0;

    return AnimatedContainer(
      duration: context.installerMotion.medium,
      curve: context.installerMotion.enterCurve,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(32),
        border: Border.all(
          color: active
              ? accent.withValues(alpha: 0.85)
              : theme.colorScheme.outlineVariant.withValues(alpha: 0.32),
        ),
        boxShadow: active
            ? [
                BoxShadow(
                  color: accent.withValues(alpha: 0.22),
                  blurRadius: 34,
                  spreadRadius: -10,
                ),
              ]
            : const [],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(32),
          onTap: onSelect,
          child: NebulaPanel(
            padding: EdgeInsets.all(panelPadding),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final shouldCompress = dense || constraints.maxHeight < 540;
                final boundedHeight = constraints.maxHeight.isFinite;

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      height: shouldCompress ? heroHeight : heroHeight,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(24),
                        color: theme.colorScheme.surface.withValues(
                          alpha: theme.brightness == Brightness.dark
                              ? 0.24
                              : 0.58,
                        ),
                      ),
                      child: Stack(
                        children: [
                          Positioned(
                            right: -16,
                            bottom: -18,
                            child: Icon(
                              icon,
                              size: shouldCompress ? 92 : 150,
                              color: accent.withValues(alpha: 0.12),
                            ),
                          ),
                          Positioned(
                            left: 18,
                            top: 18,
                            child: Container(
                              width: shouldCompress ? 42 : 48,
                              height: shouldCompress ? 42 : 48,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: accent.withValues(alpha: 0.18),
                              ),
                              child: Icon(
                                icon,
                                color: accent,
                                size: shouldCompress ? 20 : 24,
                              ),
                            ),
                          ),
                          Positioned(
                            right: 18,
                            top: 18,
                            child: Container(
                              width: 18,
                              height: 18,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: accent.withValues(alpha: 0.55),
                                ),
                                color: active
                                    ? accent.withValues(alpha: 0.18)
                                    : Colors.transparent,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: titleGap),
                    Text(
                      title,
                      style: shouldCompress
                          ? theme.textTheme.titleLarge
                          : theme.textTheme.headlineSmall,
                    ),
                    SizedBox(height: descGap),
                    Text(
                      description,
                      style:
                          (shouldCompress
                                  ? theme.textTheme.bodySmall
                                  : theme.textTheme.bodyMedium)
                              ?.copyWith(
                                color: context.installerVisuals.mutedForeground,
                              ),
                    ),
                    SizedBox(height: featureGap),
                    _FeatureLine(text: featureA, color: accent),
                    const SizedBox(height: 8),
                    _FeatureLine(text: featureB, color: accent),
                    if (boundedHeight) const Spacer(),
                    SizedBox(height: boundedHeight ? 18 : featureGap),
                    SizedBox(
                      width: double.infinity,
                      child: active
                          ? NebulaPrimaryButton(
                              label: buttonLabel,
                              icon: Icons.check_rounded,
                              onPressed: onSelect,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 18,
                                vertical: 12,
                              ),
                            )
                          : NebulaSecondaryButton(
                              label: buttonLabel,
                              icon: Icons.arrow_forward_rounded,
                              onPressed: onSelect,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 18,
                                vertical: 12,
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

class _FeatureLine extends StatelessWidget {
  const _FeatureLine({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(Icons.check_rounded, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: context.installerVisuals.mutedForeground,
            ),
          ),
        ),
      ],
    );
  }
}
