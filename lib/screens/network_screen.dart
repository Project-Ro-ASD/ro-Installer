import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/installer_state.dart';

class NetworkScreen extends StatelessWidget {
  const NetworkScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<InstallerState>(context);
    final theme = Theme.of(context);
    final isDark = state.themeMode == 'dark';
    final textColor = isDark ? Colors.white : Colors.black87;

    return Column(
      children: [
        // Başlık
        Padding(
          padding: const EdgeInsets.only(top: 20, bottom: 30),
          child: Column(
            children: [
              Text(
                state.t('net_title'),
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: textColor,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                state.t('net_desc'),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: textColor.withOpacity(0.6),
                ),
              ),
            ],
          ),
        ),

        // İçerik
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Wired Connection
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(state.t('wired'), style: _headerStyle(textColor)),
                    const SizedBox(height: 16),
                    _buildConnectionCard(
                      context,
                      icon: Icons.lan,
                      title: "Ethernet",
                      subtitle: "Connected",
                      subtitleColor: Colors.greenAccent,
                      isSelected: state.networkStatus == 'connected',
                      onTap: () {
                        state.networkStatus = 'connected';
                        state.notifyListeners();
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 40),
              
              // Wi-Fi Connections
              Expanded(
                flex: 2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(state.t('wifi'), style: _headerStyle(textColor)),
                        TextButton(
                          onPressed: () {},
                          child: Text("Rescan", style: TextStyle(color: theme.colorScheme.primary)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: ListView(
                        children: [
                          _buildConnectionCard(
                            context,
                            icon: Icons.wifi,
                            title: "Hyperion_5G_Main",
                            subtitle: "Excellent Signal",
                            isLocked: true,
                            isSelected: false,
                            onTap: () {},
                          ),
                          const SizedBox(height: 12),
                          _buildConnectionCard(
                            context,
                            icon: Icons.wifi,
                            title: "Guest_Network",
                            subtitle: "Fair Signal",
                            isLocked: true,
                            isSelected: false,
                            onTap: () {},
                          ),
                          const SizedBox(height: 12),
                          _buildConnectionCard(
                            context,
                            icon: Icons.wifi,
                            title: "Starlink_29381",
                            subtitle: "Good Signal",
                            isLocked: true,
                            isSelected: false,
                            onTap: () {},
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

        // Alt Butonlar
        Padding(
          padding: const EdgeInsets.only(top: 10),
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
              Row(
                children: [
                  TextButton.icon(
                    onPressed: () {
                      state.networkStatus = 'offline';
                      state.nextStep();
                    },
                    icon: const Icon(Icons.wifi_off),
                    label: Text(state.t('offline')),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                      foregroundColor: textColor.withOpacity(0.7),
                    ),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton(
                    onPressed: () => state.nextStep(),
                    style: theme.elevatedButtonTheme.style?.copyWith(
                      padding: const WidgetStatePropertyAll(
                        EdgeInsets.symmetric(horizontal: 32, vertical: 20),
                      ),
                    ),
                    child: Text(state.t('connect')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  TextStyle _headerStyle(Color textColor) => TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.bold,
        letterSpacing: 1.5,
        color: textColor.withOpacity(0.5),
      );

  Widget _buildConnectionCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    Color? subtitleColor,
    bool isLocked = false,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isSelected 
              ? theme.colorScheme.primary.withOpacity(0.2)
              : theme.cardColor.withOpacity(isDark ? 0.2 : 0.6),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? theme.colorScheme.primary : Colors.grey.withOpacity(0.2),
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1A1A24) : Colors.black.withOpacity(0.05),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: isSelected ? theme.colorScheme.primary : Colors.grey),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (subtitleColor != null) ...[
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(color: subtitleColor, shape: BoxShape.circle),
                        ),
                        const SizedBox(width: 6),
                      ],
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: subtitleColor ?? Colors.grey,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (isLocked)
              const Icon(Icons.lock, color: Colors.grey, size: 20),
            if (isSelected)
              Icon(Icons.check_circle, color: theme.colorScheme.primary),
          ],
        ),
      ),
    );
  }
}
