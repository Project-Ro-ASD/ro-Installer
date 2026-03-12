import 'dart:convert';
import 'package:flutter/material.dart';
import '../widgets/glass_container.dart';

class SummaryScreen extends StatelessWidget {
  final VoidCallback onToggleTheme;
  final VoidCallback onBack;
  final VoidCallback onInstall;
  final String langConfig;
  final String diskConfig;
  final String userConfig;

  const SummaryScreen({
    super.key,
    required this.onToggleTheme,
    required this.onBack,
    required this.onInstall,
    required this.langConfig,
    required this.diskConfig,
    required this.userConfig,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // JSON Verilerini Parse Edelim
    final langData = jsonDecode(langConfig);
    final diskData = jsonDecode(diskConfig);
    final userData = jsonDecode(userConfig);

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: isDark
                ? [const Color(0xFF1E1E2F), const Color(0xFF121212)]
                : [const Color(0xFFE8E8FA), const Color(0xFFFFFFFF)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Stack(
          children: [
            Positioned(
              top: -100,
              left: -100,
              child: Container(
                width: 400,
                height: 400,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: theme.colorScheme.primary.withOpacity(0.3),
                ),
              ),
            ),
            Positioned(
              bottom: -150,
              right: -50,
              child: Container(
                width: 500,
                height: 500,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: theme.colorScheme.tertiary.withOpacity(0.2), // Turuncu tonlu arka plan
                ),
              ),
            ),

            Center(
              child: GlassContainer(
                width: 800,
                height: 600,
                padding: const EdgeInsets.all(40),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          "Kurulum Özeti",
                          style: theme.textTheme.headlineLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                        IconButton(
                          icon: Icon(isDark ? Icons.light_mode : Icons.dark_mode),
                          onPressed: onToggleTheme,
                          tooltip: "Temayı Değiştir",
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      "Lütfen kuruluma başlamadan önce bilgilerinizi kontrol edin.",
                      style: theme.textTheme.bodyLarge?.copyWith(color: Colors.grey),
                    ),
                    const SizedBox(height: 30),

                    Expanded(
                      child: SingleChildScrollView(
                        child: Column(
                          children: [
                            _buildSummaryItem(
                              context,
                              icon: Icons.language,
                              title: "Dil ve Bölge",
                              values: [
                                "Dil: ${langData['lang']}",
                                "Bölge: ${langData['region']}",
                                "Klavye: ${langData['kbd']}",
                              ],
                            ),
                            const SizedBox(height: 15),
                            _buildSummaryItem(
                              context,
                              icon: Icons.save_alt,
                              title: "Hedef Disk",
                              values: [
                                "Seçili Disk: ${diskData['disk']}",
                                "Uyarı: Bu diskteki tüm veriler SİLİNECEK!",
                              ],
                              isWarning: true,
                            ),
                            const SizedBox(height: 15),
                            _buildSummaryItem(
                              context,
                              icon: Icons.person,
                              title: "Kullanıcı Hesabı",
                              values: [
                                "Ad Soyad: ${userData['fullname']}",
                                "Kullanıcı Adı: ${userData['username']}",
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 20),

                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        TextButton.icon(
                          onPressed: onBack,
                          icon: const Icon(Icons.arrow_back),
                          label: const Text("Geri Dön"),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                          ),
                        ),
                        ElevatedButton.icon(
                          onPressed: onInstall,
                          icon: const Icon(Icons.warning_amber_rounded),
                          label: const Text("Yüklemeyi Başlat"),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: theme.colorScheme.tertiary, // Turuncu/Kırmızı tonlu uyarı butonu
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8.0),
                            ),
                          ),
                        ),
                      ],
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

  Widget _buildSummaryItem(BuildContext context, {required IconData icon, required String title, required List<String> values, bool isWarning = false}) {
    final theme = Theme.of(context);
    
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isWarning ? theme.colorScheme.tertiary.withOpacity(0.1) : theme.cardColor.withOpacity(0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isWarning ? theme.colorScheme.tertiary : Colors.grey.withOpacity(0.2),
          width: 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 32, color: isWarning ? theme.colorScheme.tertiary : theme.colorScheme.primary),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                ),
                const SizedBox(height: 8),
                ...values.map((v) => Text(
                  v,
                  style: TextStyle(color: isWarning && v.contains("SİLİNECEK") ? Colors.redAccent : Colors.grey[400]),
                )),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
