import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/installer_state.dart';

class LocationScreen extends StatelessWidget {
  const LocationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<InstallerState>(context);
    final theme = Theme.of(context);
    final isDark = state.themeMode == 'dark';

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 20, bottom: 40),
          child: Column(
            children: [
              Text(
                state.t('location_title'),
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                state.t('location_desc'),
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: (isDark ? Colors.white : Colors.black87).withOpacity(0.6),
                ),
              ),
            ],
          ),
        ),

        Expanded(
          child: Center(
            child: Container(
              width: 500,
              padding: const EdgeInsets.all(30),
              decoration: BoxDecoration(
                color: theme.cardColor.withOpacity(isDark ? 0.3 : 0.6),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withOpacity(0.1)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildDropdownRow(
                    context,
                    icon: Icons.public,
                    label: state.t('region'),
                    value: state.selectedRegion,
                    items: ['United States', 'Türkiye', 'Germany', 'United Kingdom', 'España'],
                    onChanged: (val) {
                      if (val != null) {
                        state.selectedRegion = val;
                        state.notifyListeners();
                      }
                    },
                  ),
                  const SizedBox(height: 20),
                  _buildDropdownRow(
                    context,
                    icon: Icons.access_time,
                    label: state.t('timezone'),
                    value: state.selectedTimezone,
                    items: ['UTC', 'Europe/Istanbul', 'Europe/Berlin', 'America/New_York', 'Europe/Madrid'],
                    onChanged: (val) {
                      if (val != null) {
                        state.selectedTimezone = val;
                        state.notifyListeners();
                      }
                    },
                  ),
                  const SizedBox(height: 20),
                  _buildDropdownRow(
                    context,
                    icon: Icons.keyboard,
                    label: state.t('kbd'),
                    value: state.selectedKeyboard,
                    items: ['us', 'trq', 'trf', 'de', 'uk', 'es'],
                    onChanged: (val) {
                      if (val != null) {
                        state.selectedKeyboard = val;
                        state.notifyListeners();
                      }
                    },
                  ),
                ],
              ),
            ),
          ),
        ),

        // Alt Butonlar
        Padding(
          padding: const EdgeInsets.only(top: 20),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              TextButton.icon(
                onPressed: () => state.previousStep(),
                icon: const Icon(Icons.arrow_back),
                label: Text(state.t('prev')),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  foregroundColor: (isDark ? Colors.white : Colors.black87).withOpacity(0.7),
                ),
              ),
              ElevatedButton.icon(
                onPressed: () => state.nextStep(),
                icon: const Icon(Icons.arrow_forward),
                label: Text(state.t('next')),
                style: theme.elevatedButtonTheme.style?.copyWith(
                  padding: const WidgetStatePropertyAll(
                    EdgeInsets.symmetric(horizontal: 32, vertical: 20),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDropdownRow(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
    required List<String> items,
    required ValueChanged<String?> onChanged,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Row(
      children: [
        Icon(icon, color: theme.colorScheme.primary, size: 28),
        const SizedBox(width: 20),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: (isDark ? Colors.white : Colors.black87).withOpacity(0.6),
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF151520) : Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey.withOpacity(0.3)),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    value: value,
                    dropdownColor: isDark ? const Color(0xFF1E1E2E) : Colors.white,
                    items: items.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                    onChanged: onChanged,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
