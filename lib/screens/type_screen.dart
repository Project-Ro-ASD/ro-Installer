import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/installer_state.dart';

class TypeScreen extends StatelessWidget {
  const TypeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<InstallerState>(context);
    final theme = Theme.of(context);
    final isDark = state.themeMode == 'dark';
    final textColor = isDark ? Colors.white : Colors.black87;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 20, bottom: 40),
          child: Column(
            children: [
              Text(
                state.t('type_title'),
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: textColor,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                state.t('type_desc'),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: textColor.withOpacity(0.6),
                ),
              ),
            ],
          ),
        ),

        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Standard Installation Card
              _buildTypeCard(
                context,
                title: state.t('type_std_title'),
                description: state.t('type_std_desc'),
                icon: Icons.verified_user,
                iconColor: theme.colorScheme.primary,
                type: 'standard',
                isActive: state.installType == 'standard',
                onSelect: () => state.updateInstallType('standard'),
                buttonLabel: state.t('type_std_btn'),
              ),
              const SizedBox(width: 40),
              // Advanced Installation Card
              _buildTypeCard(
                context,
                title: state.t('type_adv_title'),
                description: state.t('type_adv_desc'),
                icon: Icons.memory,
                iconColor: const Color(0xFFFF5252), // Kırmızı/Turuncu Vurgu
                type: 'advanced',
                isActive: state.installType == 'advanced',
                onSelect: () => state.updateInstallType('advanced'),
                buttonLabel: state.t('type_adv_btn'),
              ),
            ],
          ),
        ),

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
                  foregroundColor: textColor.withOpacity(0.7),
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

  Widget _buildTypeCard(
    BuildContext context, {
    required String title,
    required String description,
    required IconData icon,
    required Color iconColor,
    required String type,
    required bool isActive,
    required VoidCallback onSelect,
    required String buttonLabel,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      width: 380,
      padding: const EdgeInsets.all(2), // İç gölge hissiyatı için küçük dış sınır
      decoration: BoxDecoration(
        color: isActive ? theme.colorScheme.primary.withOpacity(0.5) : Colors.transparent,
        borderRadius: BorderRadius.circular(18),
        boxShadow: isActive 
            ? [BoxShadow(color: theme.colorScheme.primary.withOpacity(0.2), blurRadius: 30, spreadRadius: 5)] 
            : [],
      ),
      child: Container(
        decoration: BoxDecoration(
          color: theme.cardColor.withOpacity(isDark ? 0.4 : 0.8),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: isActive ? theme.colorScheme.primary : Colors.white.withOpacity(0.1)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Resim veya İkon Alanı
            Expanded(
              child: ClipRRect(
                borderRadius: const BorderRadius.only(topLeft: Radius.circular(16), topRight: Radius.circular(16)),
                child: Container(
                  color: isDark ? const Color(0xFF101018) : const Color(0xFFF3F3F3),
                  child: Stack(
                    children: [
                      // Arka Planda Devasa İkon (Stitch'teki görselin yerine)
                      Positioned(
                        right: -40,
                        bottom: -40,
                        child: Icon(icon, size: 200, color: iconColor.withOpacity(0.1)),
                      ),
                      Center(
                        child: Icon(icon, size: 80, color: iconColor),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            
            // Metin ve Buton (Alt Kısım)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(icon, color: iconColor, size: 20),
                      const SizedBox(width: 10),
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    description,
                    style: TextStyle(
                      fontSize: 14,
                      color: isDark ? Colors.white70 : Colors.black54,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 30),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: onSelect,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: isActive 
                            ? theme.colorScheme.primary 
                            : (isDark ? const Color(0xFF2A2A35) : Colors.grey.withOpacity(0.2)),
                        foregroundColor: isActive ? Colors.white : (isDark ? Colors.white70 : Colors.black87),
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        elevation: 0,
                      ),
                      child: Text(buttonLabel, style: const TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
