import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/installer_state.dart';

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  final Map<String, String> _languages = const {
    'tr': 'Türkçe',
    'en': 'English',
    'es': 'Español',
  };

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<InstallerState>(context);
    final theme = Theme.of(context);

    return Column(
      children: [
        // Hoş Geldiniz Metinleri
        Expanded(
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.handshake_rounded,
                  size: 64,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 20),
                Text(
                  state.t('welcome_title'),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.displaySmall?.copyWith(
                    fontWeight: FontWeight.w900,
                    color: theme.textTheme.bodyLarge?.color,
                  ),
                ),
                const SizedBox(height: 15),
                Text(
                  state.t('welcome_desc'),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.textTheme.bodyLarge?.color?.withOpacity(0.7),
                  ),
                ),
                const SizedBox(height: 40),

                // Dil Seçici Kutusu
                Container(
                  width: 300,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    color: theme.cardColor.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey.withOpacity(0.2)),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: state.selectedLanguage,
                      icon: const Icon(Icons.language),
                      items: _languages.entries.map((e) {
                        return DropdownMenuItem(value: e.key, child: Text(e.value));
                      }).toList(),
                      onChanged: (val) {
                        if (val != null) {
                          state.updateLanguage(val);
                        }
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        // Alt Butonlar (Back / Next)
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
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
      ],
    );
  }
}
