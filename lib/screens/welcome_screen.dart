import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/installer_state.dart';
import '../theme/app_theme.dart';
import '../widgets/nebula_ui.dart';

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<InstallerState>(context);
    final theme = Theme.of(context);
    final visuals = context.installerVisuals;

    return LayoutBuilder(
      builder: (context, constraints) {
        final compactWarning = constraints.maxWidth < 560;
        final warningWidth = compactWarning ? double.infinity : 292.0;

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  state.t('welcome_title'),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.displaySmall?.copyWith(
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 14),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Text(
                    state.t('welcome_desc'),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: visuals.mutedForeground,
                    ),
                  ),
                ),
                const SizedBox(height: 40),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      NebulaPanel(
                        width: double.infinity,
                        padding: const EdgeInsets.all(26),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            NebulaSectionLabel(
                              state.t('welcome_language_section'),
                            ),
                            const SizedBox(height: 18),
                            NebulaDropdown<String>(
                              value: state.selectedLanguage,
                              leadingIcon: Icons.language_rounded,
                              items: state.availableLocales
                                  .map(
                                    (locale) => NebulaDropdownItem<String>(
                                      value: locale.code,
                                      label: locale.nativeName,
                                      icon: Icons.language_rounded,
                                    ),
                                  )
                                  .toList(),
                              onChanged: state.updateLanguage,
                            ),
                            const SizedBox(height: 22),
                            Align(
                              alignment: Alignment.centerRight,
                              child: SizedBox(
                                width: compactWarning
                                    ? double.infinity
                                    : warningWidth,
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    NebulaPrimaryButton(
                                      label: state.t('welcome_start'),
                                      icon: Icons.arrow_forward_rounded,
                                      onPressed: state.nextStep,
                                    ),
                                    const SizedBox(height: 10),
                                    SizedBox(
                                      width: double.infinity,
                                      child: _WelcomeWarningCard(
                                        title: state.t('welcome_warning_title'),
                                        body: state.t('welcome_warning_body'),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _WelcomeWarningCard extends StatelessWidget {
  const _WelcomeWarningCard({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visuals = context.installerVisuals;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: const Color(0xFFFFB347).withValues(alpha: 0.12),
        border: Border.all(
          color: const Color(0xFFFFB347).withValues(alpha: 0.26),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(
              Icons.warning_amber_rounded,
              color: Color(0xFFFFB347),
              size: 18,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: const Color(0xFFFFB347),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: visuals.mutedForeground,
                    height: 1.35,
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
