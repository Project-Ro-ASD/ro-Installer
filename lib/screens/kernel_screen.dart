import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/installer_state.dart';

class KernelScreen extends StatelessWidget {
  const KernelScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<InstallerState>(context);
    final theme = Theme.of(context);
    final isDark = state.themeMode == 'dark';
    final textColor = isDark ? Colors.white : Colors.black87;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 30),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  state.t('kernel_badge'),
                  style: const TextStyle(color: Colors.orange, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.2),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                state.t('kernel_title'),
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: textColor,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                state.t('kernel_desc'),
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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Sol Taraftaki Bilgiler (Görselin sol alt köşesi)
              Expanded(
                flex: 2,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Sistem RAM Bilgisi İptal Edildi
                    _buildInfoChip(
                      context,
                      icon: Icons.cloud_download,
                      iconColor: state.networkStatus == 'connected' ? theme.colorScheme.primary : Colors.grey,
                      title: state.t('network'),
                      value: state.networkStatus == 'connected' ? state.t('net_ready') : state.t('offline_status'),
                    ),
                    const SizedBox(height: 40),
                  ],
                ),
              ),
              
              // Ortada Seçim Kartları
              Expanded(
                flex: 6,
                child: Row(
                  children: [
                    Expanded(
                      child: _buildKernelCard(
                        context,
                        title: state.t('kernel_stable_title'),
                        description: state.t('kernel_stable_desc'),
                        icon: Icons.verified,
                        color: Colors.blueAccent,
                        version: "v2.4.12-LTS",
                        features: [state.t('kernel_s_feat1'), state.t('kernel_s_feat2')],
                        isActive: state.kernelType == 'stable',
                        onSelect: () => state.updateKernel('stable'),
                      ),
                    ),
                    const SizedBox(width: 30),
                    Expanded(
                      child: _buildKernelCard(
                        context,
                        title: state.t('kernel_exp_title'),
                        description: state.t('kernel_exp_desc'),
                        icon: Icons.science,
                        color: Colors.deepOrangeAccent,
                        version: "v2.5.0-BETA.4",
                        features: [state.t('kernel_e_feat1'), state.t('kernel_e_feat2')],
                        isActive: state.kernelType == 'experimental' && state.networkStatus == 'connected',
                        onSelect: () {
                           if (state.networkStatus == 'connected') {
                              state.updateKernel('experimental');
                           }
                        },
                        isDisabled: state.networkStatus != 'connected',
                        disabledMessage: "İnternet Bağlantısı Gerekli\n(Sadece Çevrimiçi Kurulum)",
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(flex: 1), // Sağ boşluk
            ],
          ),
        ),

        Padding(
          padding: const EdgeInsets.only(top: 30),
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
              
              // İlerleme veya Yüklemeye Başlama Butonu
              Column(
                children: [
                  ElevatedButton(
                    onPressed: () => state.nextStep(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isDark ? Colors.white : const Color(0xFF101018),
                      foregroundColor: isDark ? Colors.black : Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 22),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(state.t('install_init'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                        const SizedBox(width: 12),
                        const Icon(Icons.arrow_forward),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    state.t('install_est'),
                    style: TextStyle(fontSize: 12, color: textColor.withOpacity(0.4)),
                  ),
                ],
              ),
              // Sağ boşluğu simetrik yapmak için:
              const SizedBox(width: 140),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildInfoChip(BuildContext context, {required IconData icon, required Color iconColor, required String title, required String value}) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: theme.cardColor.withOpacity(isDark ? 0.3 : 0.6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.1)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: iconColor.withOpacity(0.2), shape: BoxShape.circle),
            child: Icon(icon, color: iconColor, size: 20),
          ),
          const SizedBox(width: 16),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.grey, letterSpacing: 1.2)),
              const SizedBox(height: 4),
              Text(value, style: TextStyle(fontWeight: FontWeight.bold, color: isDark ? Colors.white : Colors.black87)),
            ],
          )
        ],
      ),
    );
  }

  Widget _buildKernelCard(
    BuildContext context, {
    required String title,
    required String description,
    required IconData icon,
    required Color color,
    required String version,
    required List<String> features,
    required bool isActive,
    required VoidCallback onSelect,
    bool isDisabled = false,
    String? disabledMessage,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    
    return GestureDetector(
      onTap: isDisabled ? null : onSelect,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(
          color: isDisabled 
              ? (isDark ? Colors.black26 : Colors.black12)
              : (isActive 
                  ? (isDark ? const Color(0xFF1E1E2E) : Colors.white)
                  : (isDark ? const Color(0xFF1A1A24) : Colors.grey.withOpacity(0.05))),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: isDisabled 
                ? Colors.transparent 
                : (isActive ? color : Colors.grey.withOpacity(0.2)),
            width: isActive ? 2 : 1,
          ),
          boxShadow: isActive
              ? [BoxShadow(color: color.withOpacity(0.15), blurRadius: 30, spreadRadius: 5)]
              : [],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: color.withOpacity(0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: color, size: 36),
            ),
            const SizedBox(height: 24),
            Text(
              title,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              description,
              style: TextStyle(
                fontSize: 14,
                color: isDark ? Colors.white70 : Colors.black54,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 24),
            ...features.map((f) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  Icon(Icons.check, size: 16, color: isDisabled ? Colors.grey : color),
                  const SizedBox(width: 8),
                  Expanded(child: Text(f, style: TextStyle(fontSize: 13, color: isDark ? Colors.white70 : Colors.black87))),
                ],
              ),
            )),
            const Spacer(),
            if (isDisabled && disabledMessage != null)
               Container(
                 width: double.infinity,
                 padding: const EdgeInsets.all(12),
                 margin: const EdgeInsets.only(bottom: 16),
                 decoration: BoxDecoration(
                   color: Colors.redAccent.withOpacity(0.1),
                   borderRadius: BorderRadius.circular(8),
                   border: Border.all(color: Colors.redAccent.withOpacity(0.3)),
                 ),
                 child: Row(
                   children: [
                     const Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 20),
                     const SizedBox(width: 8),
                     Expanded(child: Text(disabledMessage, style: const TextStyle(color: Colors.redAccent, fontSize: 12, fontWeight: FontWeight.bold))),
                   ],
                 ),
               ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text("VERSION", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey, letterSpacing: 1.2)),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(version, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: color)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
