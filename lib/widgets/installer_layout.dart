import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/installer_state.dart';
import 'glass_container.dart';

class InstallerLayout extends StatelessWidget {
  final Widget child;

  const InstallerLayout({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<InstallerState>(context);
    final theme = Theme.of(context);
    final isDark = state.themeMode == 'dark';

    // Tasarıma uygun degrade (gradient) arka plan (Aydınlık/Karanlık göre değişir)
    final bgColors = isDark
        ? [const Color(0xFF0F0F1A), const Color(0xFF1B0A2B)] // Çok Koyu Mor / Lacivert
        : [const Color(0xFFFFF3E0), const Color(0xFFF3E5F5), const Color(0xFFE8EAF6)]; // Krem, Açık Turuncu/Mor/Mavi (Renkli Aydınlık Tema)

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: bgColors,
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Stack(
          children: [
            // Canlı, bulanık dekoratif arka plan daireleri
            Positioned(
              top: -150,
              left: -100,
              child: Container(
                width: 500,
                height: 500,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: (isDark ? const Color(0xFF5A2A9B) : const Color(0xFFD6C8FF)).withOpacity(0.4),
                ),
              ),
            ),
            Positioned(
              bottom: -200,
              right: -100,
              child: Container(
                width: 600,
                height: 600,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: (isDark ? const Color(0xFF1E3A8A) : const Color(0xFFBBEBFF)).withOpacity(0.3),
                ),
              ),
            ),

            // Ana Glass Container (Tek seferlik çizilir)
            Center(
              child: GlassContainer(
                width: MediaQuery.of(context).size.width * 0.9,
                height: MediaQuery.of(context).size.height * 0.9,
                padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 30),
                child: Column(
                  children: [
                    // --- Header: Üst Bar --- (Sadece kurulum ekranında değilse göster)
                    if (state.currentStep < 8) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
                        decoration: BoxDecoration(
                          color: theme.cardColor.withOpacity(isDark ? 0.3 : 0.6),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.white.withOpacity(0.1)),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.primary,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: const Icon(Icons.download_rounded, color: Colors.white, size: 20),
                                ),
                                const SizedBox(width: 15),
                                Text(
                                  "Ro-Installer for Ro-ASD",
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color: isDark ? const Color(0xFFE6E6FA) : const Color(0xFF2B2B36),
                                  ),
                                ),
                              ],
                            ),
                            Text(
                              "v2.4.0 Build",
                              style: TextStyle(
                                color: (isDark ? Colors.white : Colors.black).withOpacity(0.5),
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 15),
                    ],

                    // --- Stepper Bar (Adımlar) ---
                    if (state.currentStep < 8) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                        decoration: BoxDecoration(
                          color: theme.cardColor.withOpacity(isDark ? 0.2 : 0.4),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: List.generate(state.steps.length, (index) {
                            final stepName = state.steps[index];
                            final isActive = state.currentStep == index;
                            final isPassed = index < state.currentStep;

                            return GestureDetector(
                              onTap: isPassed ? () => state.goToStep(index) : null,
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 300),
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                                decoration: BoxDecoration(
                                  color: isActive
                                      ? theme.colorScheme.primary
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Text(
                                  state.t('step_${stepName.toLowerCase()}'),
                                  style: TextStyle(
                                    color: isActive
                                        ? Colors.white
                                        : isPassed
                                            ? theme.colorScheme.primary.withOpacity(0.8)
                                            : (isDark ? Colors.white : Colors.black).withOpacity(0.3),
                                    fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            );
                          }),
                        ),
                      ),
                      const SizedBox(height: 30),
                    ],

                    // --- Dinamik İçerik (Her Adımın Kendi Ekranı) ---
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 400),
                        transitionBuilder: (child, animation) => FadeTransition(opacity: animation, child: child),
                        child: child,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
