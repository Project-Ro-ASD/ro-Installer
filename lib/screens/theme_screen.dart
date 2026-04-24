import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/installer_state.dart';
import '../theme/app_theme.dart';
import '../widgets/nebula_ui.dart';

class ThemeScreen extends StatelessWidget {
  const ThemeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<InstallerState>(context);
    final theme = Theme.of(context);
    final visuals = context.installerVisuals;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        children: [
          const SizedBox(height: 20),
          Text(
            state.t('theme_title'),
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineLarge,
          ),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Text(
              state.t('theme_desc'),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: visuals.mutedForeground,
              ),
            ),
          ),
          const SizedBox(height: 34),
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: _ThemeOptionCard(
                    title: state.t('theme_dark_title'),
                    description: state.t('theme_dark_desc'),
                    selected: state.themeMode == 'dark',
                    onTap: () => state.updateTheme('dark'),
                    preview: const _ThemePreview(isDark: true),
                  ),
                ),
                const SizedBox(width: 24),
                Expanded(
                  child: _ThemeOptionCard(
                    title: state.t('theme_light_title'),
                    description: state.t('theme_light_desc'),
                    selected: state.themeMode == 'light',
                    onTap: () => state.updateTheme('light'),
                    preview: const _ThemePreview(isDark: false),
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
      ),
    );
  }
}

class _ThemeOptionCard extends StatelessWidget {
  const _ThemeOptionCard({
    required this.title,
    required this.description,
    required this.selected,
    required this.onTap,
    required this.preview,
  });

  final String title;
  final String description;
  final bool selected;
  final VoidCallback onTap;
  final Widget preview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final motion = context.installerMotion;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: motion.medium,
          curve: motion.enterCurve,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(30),
            border: Border.all(
              color: selected
                  ? theme.colorScheme.primary.withValues(alpha: 0.78)
                  : theme.colorScheme.outlineVariant.withValues(alpha: 0.55),
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: theme.colorScheme.primary.withValues(alpha: 0.18),
                      blurRadius: 36,
                      spreadRadius: -8,
                    ),
                  ]
                : const [],
          ),
          child: NebulaPanel(
            padding: const EdgeInsets.all(22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Align(
                  alignment: Alignment.topRight,
                  child: AnimatedContainer(
                    duration: motion.fast,
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected
                            ? theme.colorScheme.primary
                            : theme.colorScheme.outlineVariant,
                      ),
                      color: selected
                          ? theme.colorScheme.primary.withValues(alpha: 0.16)
                          : Colors.transparent,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Expanded(child: preview),
                const SizedBox(height: 24),
                Text(title, style: theme.textTheme.headlineSmall),
                const SizedBox(height: 12),
                Text(
                  description,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: context.installerVisuals.mutedForeground,
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

class _ThemePreview extends StatelessWidget {
  const _ThemePreview({required this.isDark});

  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final border = isDark ? const Color(0xFF2F2A3F) : const Color(0xFFD9D7E8);
    final card = isDark ? const Color(0xFF17141F) : const Color(0xFFFAFAFD);
    final chrome = isDark ? const Color(0xFF252130) : const Color(0xFFEAE7F4);
    final line = isDark ? const Color(0xFF343041) : const Color(0xFFD6D2E3);
    final button = isDark
        ? const LinearGradient(colors: [Color(0xFFB77433), Color(0xFFE4A05D)])
        : const LinearGradient(colors: [Color(0xFF9A7FFF), Color(0xFF6C63F8)]);

    return Container(
      decoration: BoxDecoration(
        color: card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: border),
      ),
      child: Column(
        children: [
          Container(
            height: 34,
            decoration: BoxDecoration(
              color: chrome,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(20),
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                ...[
                  const Color(0xFFE8A2A2),
                  const Color(0xFFD8C18A),
                  const Color(0xFF8DA8FF),
                ].map(
                  (color) => Container(
                    width: 8,
                    height: 8,
                    margin: const EdgeInsets.only(right: 6),
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 110,
                    height: 12,
                    decoration: BoxDecoration(
                      color: line,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    height: 10,
                    decoration: BoxDecoration(
                      color: line.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    height: 10,
                    decoration: BoxDecoration(
                      color: line.withValues(alpha: 0.62),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  const Spacer(),
                  Container(
                    width: 88,
                    height: 32,
                    decoration: BoxDecoration(
                      gradient: button,
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
