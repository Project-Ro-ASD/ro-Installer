import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/installer_state.dart';
import '../theme/app_theme.dart';
import '../widgets/nebula_ui.dart';

class LocationScreen extends StatelessWidget {
  const LocationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<InstallerState>(context);
    final theme = Theme.of(context);
    final regionPreset = state.selectedRegionPreset;
    final recommendedLocale = regionPreset == null
        ? null
        : state.translations.localeFor(regionPreset.languageCode);
    final canApplyRecommendedLanguage =
        recommendedLocale != null &&
        recommendedLocale.enabled &&
        state.selectedLanguage != recommendedLocale.code;
    final isRecommendedLanguageActive =
        recommendedLocale != null &&
        state.selectedLanguage == recommendedLocale.code;

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 980;
        final dense = constraints.maxHeight < 780;

        final configurator = NebulaPanel(
          padding: EdgeInsets.all(dense ? 22 : 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              NebulaSectionLabel(state.t('location_matrix')),
              SizedBox(height: dense ? 16 : 22),
              _LocationSelector(
                icon: Icons.public_rounded,
                label: state.t('region'),
                value: state.selectedRegion,
                items: state.availableRegions
                    .map(
                      (value) =>
                          _LocationSelectorItem(value: value, label: value),
                    )
                    .toList(growable: false),
                dense: dense,
                onChanged: (value) {
                  if (value != null) {
                    state.applyLocationPreset(value);
                  }
                },
              ),
              SizedBox(height: dense ? 14 : 18),
              _LocationSelector(
                icon: Icons.schedule_rounded,
                label: state.t('timezone'),
                value: state.selectedTimezone,
                items: state.availableTimezones
                    .map(
                      (value) =>
                          _LocationSelectorItem(value: value, label: value),
                    )
                    .toList(growable: false),
                dense: dense,
                onChanged: (value) {
                  if (value != null) {
                    state.updateLocation(timezone: value);
                  }
                },
              ),
              SizedBox(height: dense ? 14 : 18),
              _LocationSelector(
                icon: Icons.keyboard_command_key_rounded,
                label: state.t('kbd'),
                value: state.selectedKeyboard,
                items: state.availableKeyboards
                    .map(
                      (value) => _LocationSelectorItem(
                        value: value,
                        label: state.keyboardLabelFor(value),
                      ),
                    )
                    .toList(growable: false),
                dense: dense,
                onChanged: (value) {
                  if (value != null) {
                    state.updateLocation(keyboard: value);
                  }
                },
              ),
            ],
          ),
        );

        final summary = NebulaPanel(
          padding: EdgeInsets.all(dense ? 22 : 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              NebulaSectionLabel(state.t('location_summary')),
              SizedBox(height: dense ? 14 : 18),
              _SummaryRow(
                icon: Icons.location_city_rounded,
                label: state.t('region'),
                value: state.selectedRegion,
                dense: dense,
              ),
              SizedBox(height: dense ? 10 : 14),
              _SummaryRow(
                icon: Icons.watch_later_outlined,
                label: state.t('timezone'),
                value: state.selectedTimezone,
                dense: dense,
              ),
              SizedBox(height: dense ? 10 : 14),
              _SummaryRow(
                icon: Icons.keyboard_rounded,
                label: state.t('kbd'),
                value: state.selectedKeyboardLabel,
                dense: dense,
              ),
              if (regionPreset != null) ...[
                SizedBox(height: dense ? 10 : 14),
                _SummaryRow(
                  icon: Icons.language_rounded,
                  label: state.t('location_recommended_language'),
                  value:
                      recommendedLocale?.nativeName ??
                      regionPreset.languageCode,
                  dense: dense,
                ),
                SizedBox(height: dense ? 8 : 12),
                if (canApplyRecommendedLanguage)
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        state.t('location_recommended_language_ready'),
                        style:
                            (dense
                                    ? theme.textTheme.bodySmall
                                    : theme.textTheme.bodyMedium)
                                ?.copyWith(
                                  color:
                                      context.installerVisuals.mutedForeground,
                                ),
                      ),
                      NebulaSecondaryButton(
                        label: state.t('location_apply_recommended_language'),
                        icon: Icons.language_rounded,
                        padding: EdgeInsets.symmetric(
                          horizontal: dense ? 16 : 18,
                          vertical: dense ? 10 : 12,
                        ),
                        onPressed: () {
                          state.updateLanguage(
                            recommendedLocale.code,
                            syncLocationPreset: false,
                          );
                        },
                      ),
                    ],
                  )
                else if (isRecommendedLanguageActive)
                  NebulaStatusChip(
                    label: state.t('location_recommended_language_applied'),
                    color: theme.colorScheme.primary,
                    icon: Icons.check_circle_outline_rounded,
                  )
                else
                  Text(
                    state.t('location_recommended_language_draft'),
                    style:
                        (dense
                                ? theme.textTheme.bodySmall
                                : theme.textTheme.bodyMedium)
                            ?.copyWith(
                              color: context.installerVisuals.mutedForeground,
                            ),
                  ),
              ],
              SizedBox(height: dense ? 14 : 20),
              Divider(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.45),
              ),
              SizedBox(height: dense ? 10 : 14),
              Text(
                state.t('location_summary_note'),
                style:
                    (dense
                            ? theme.textTheme.bodySmall
                            : theme.textTheme.bodyMedium)
                        ?.copyWith(
                          color: context.installerVisuals.mutedForeground,
                        ),
              ),
              SizedBox(height: dense ? 12 : 16),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  NebulaStatusChip(
                    label: state.selectedRegion,
                    color: theme.colorScheme.primary,
                    icon: Icons.near_me_rounded,
                  ),
                  NebulaStatusChip(
                    label: state.selectedKeyboardLabel,
                    color: theme.colorScheme.tertiary,
                    icon: Icons.keyboard_rounded,
                  ),
                  NebulaStatusChip(
                    label: state.selectedTimezone,
                    color: theme.colorScheme.secondary,
                    icon: Icons.schedule_rounded,
                  ),
                ],
              ),
            ],
          ),
        );

        return Column(
          children: [
            const SizedBox(height: 10),
            NebulaScreenIntro(
              badge: state.t('location_badge'),
              title: state.t('location_title'),
              description: state.t('location_desc'),
            ),
            const SizedBox(height: 28),
            if (compact)
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      configurator,
                      const SizedBox(height: 20),
                      summary,
                    ],
                  ),
                ),
              )
            else
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 5, child: configurator),
                    const SizedBox(width: 22),
                    Expanded(
                      flex: 4,
                      child: SingleChildScrollView(child: summary),
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

class _LocationSelector extends StatelessWidget {
  const _LocationSelector({
    required this.icon,
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
    this.dense = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final List<_LocationSelectorItem> items;
  final ValueChanged<String?> onChanged;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: dense ? 38 : 42,
              height: dense ? 38 : 42,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: theme.colorScheme.primary.withValues(alpha: 0.16),
              ),
              child: Icon(
                icon,
                color: theme.colorScheme.primary,
                size: dense ? 18 : 20,
              ),
            ),
            SizedBox(width: dense ? 12 : 14),
            Text(
              label,
              style: dense
                  ? theme.textTheme.titleSmall
                  : theme.textTheme.titleMedium,
            ),
          ],
        ),
        SizedBox(height: dense ? 8 : 12),
        NebulaDropdown<String>(
          value: value,
          dense: dense,
          leadingIcon: icon,
          items: items
              .map(
                (item) => NebulaDropdownItem<String>(
                  value: item.value,
                  label: item.label,
                  icon: icon,
                ),
              )
              .toList(),
          onChanged: (newValue) => onChanged(newValue),
        ),
      ],
    );
  }
}

class _LocationSelectorItem {
  const _LocationSelectorItem({required this.value, required this.label});

  final String value;
  final String label;
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.icon,
    required this.label,
    required this.value,
    this.dense = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: EdgeInsets.all(dense ? 12 : 16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(
          alpha: theme.brightness == Brightness.dark ? 0.22 : 0.55,
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.45),
        ),
      ),
      child: Row(
        children: [
          Icon(icon, color: theme.colorScheme.primary, size: dense ? 16 : 18),
          SizedBox(width: dense ? 10 : 12),
          Expanded(
            child: Text(
              label,
              style:
                  (dense
                          ? theme.textTheme.bodySmall
                          : theme.textTheme.bodyMedium)
                      ?.copyWith(
                        color: context.installerVisuals.mutedForeground,
                      ),
            ),
          ),
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
