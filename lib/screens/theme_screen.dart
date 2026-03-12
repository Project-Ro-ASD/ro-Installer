import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/installer_state.dart';

class ThemeScreen extends StatelessWidget {
  const ThemeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<InstallerState>(context);
    final theme = Theme.of(context);

    return Column(
      children: [
        // Başlık
        Padding(
          padding: const EdgeInsets.only(top: 20, bottom: 40),
          child: Column(
            children: [
              Text(
                state.t('theme_title'),
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.textTheme.bodyLarge?.color,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                state.t('theme_desc'),
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.textTheme.bodyLarge?.color?.withOpacity(0.6),
                ),
              ),
            ],
          ),
        ),

        // Kartlar
        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildThemeCard(
                context,
                title: state.t('light_theme'),
                description: state.t('light_desc'),
                mode: 'light',
                isActive: state.themeMode == 'light',
                onTap: () => state.updateTheme('light'),
              ),
              const SizedBox(width: 40),
              _buildThemeCard(
                context,
                title: state.t('dark_theme'),
                description: state.t('dark_desc'),
                mode: 'dark',
                isActive: state.themeMode == 'dark',
                onTap: () => state.updateTheme('dark'),
              ),
            ],
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
                  foregroundColor: theme.textTheme.bodyLarge?.color?.withOpacity(0.7),
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

  Widget _buildThemeCard(
    BuildContext context, {
    required String title,
    required String description,
    required String mode,
    required bool isActive,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final isDarkCard = mode == 'dark';

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        width: 320,
        height: 380,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: isActive 
              ? (isDarkCard ? const Color(0xFF2B1A4A) : Colors.white)
              : (isDarkCard ? const Color(0xFF1E1E2E) : const Color(0xFFF5F5F5)),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isActive ? theme.colorScheme.primary : Colors.grey.withOpacity(0.2),
            width: isActive ? 2 : 1,
          ),
          boxShadow: [
            if (isActive)
              BoxShadow(
                color: theme.colorScheme.primary.withOpacity(0.3),
                blurRadius: 20,
                spreadRadius: 2,
              )
          ],
        ),
        child: Column(
          children: [
            // Dummy Mini Ekran Görselleştirme
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: isDarkCard ? const Color(0xFF151520) : const Color(0xFFF0F0F0),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Center(
                  child: Icon(
                    isDarkCard ? Icons.dark_mode_outlined : Icons.light_mode_outlined,
                    size: 64,
                    color: isDarkCard ? const Color(0xFFA575FF) : const Color(0xFFFFA726),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: isDarkCard ? Colors.white : Colors.black87,
                  ),
                ),
                Icon(
                  isActive ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                  color: isActive ? theme.colorScheme.primary : Colors.grey,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              description,
              style: TextStyle(
                fontSize: 14,
                color: isDarkCard ? Colors.white70 : Colors.black54,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
