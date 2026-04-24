import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/installer_state.dart';
import '../theme/app_theme.dart';
import '../widgets/nebula_ui.dart';

class NetworkScreen extends StatefulWidget {
  const NetworkScreen({super.key});

  @override
  State<NetworkScreen> createState() => _NetworkScreenState();
}

class _NetworkScreenState extends State<NetworkScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<InstallerState>(context, listen: false).scanWifiNetworks();
    });
  }

  String _signalText(InstallerState state, int signal) {
    if (signal > 80) {
      return state.t('net_signal_excellent');
    }
    if (signal > 50) {
      return state.t('net_signal_good');
    }
    if (signal > 20) {
      return state.t('net_signal_fair');
    }
    return state.t('net_signal_poor');
  }

  bool _isConnectionReady(InstallerState state) {
    final wifiConnected = state.wifiNetworks.any((net) => net['inUse'] == true);
    return state.isEthernetConnected ||
        wifiConnected ||
        state.networkStatus == 'connected';
  }

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<InstallerState>(context);
    final theme = Theme.of(context);
    final onlineReady = _isConnectionReady(state);

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 1080;

        final summaryPanel = NebulaPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              NebulaSectionLabel(state.t('net_status_panel')),
              const SizedBox(height: 20),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  NebulaStatusChip(
                    label: state.isEthernetConnected
                        ? state.t('net_connected')
                        : state.t('net_disconnected'),
                    color: state.isEthernetConnected
                        ? Colors.greenAccent.shade400
                        : theme.colorScheme.outline,
                    icon: state.isEthernetConnected
                        ? Icons.lan_rounded
                        : Icons.link_off_rounded,
                  ),
                  NebulaStatusChip(
                    label: onlineReady
                        ? state.t('net_ready')
                        : state.t('offline_status'),
                    color: onlineReady
                        ? theme.colorScheme.tertiary
                        : theme.colorScheme.secondary,
                    icon: onlineReady
                        ? Icons.cloud_done_rounded
                        : Icons.cloud_off_rounded,
                  ),
                ],
              ),
              const SizedBox(height: 24),
              _ConnectionTile(
                icon: state.isEthernetConnected
                    ? Icons.lan_rounded
                    : Icons.cable_rounded,
                title: state.t('net_ethernet'),
                subtitle: state.isEthernetConnected
                    ? state.t('net_connected')
                    : state.t('net_disconnected'),
                active: state.isEthernetConnected,
                chipColor: state.isEthernetConnected
                    ? Colors.greenAccent.shade400
                    : theme.colorScheme.outline,
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  color: theme.colorScheme.surface.withValues(
                    alpha: theme.brightness == Brightness.dark ? 0.2 : 0.52,
                  ),
                  border: Border.all(
                    color: theme.colorScheme.outlineVariant.withValues(
                      alpha: 0.35,
                    ),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      size: 18,
                      color: theme.colorScheme.secondary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        state.t('net_offline_hint'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: context.installerVisuals.mutedForeground,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );

        final wifiPanel = NebulaPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  NebulaSectionLabel(state.t('net_wireless_panel')),
                  const Spacer(),
                  NebulaSecondaryButton(
                    label: state.t('net_rescan'),
                    icon: state.isScanningWifi ? null : Icons.refresh_rounded,
                    onPressed: state.isScanningWifi
                        ? null
                        : state.scanWifiNetworks,
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Expanded(
                child: state.wifiNetworks.isEmpty
                    ? Center(
                        child: Text(
                          state.isScanningWifi
                              ? state.t('net_scanning')
                              : state.t('net_no_wifi'),
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: context.installerVisuals.mutedForeground,
                          ),
                        ),
                      )
                    : ListView.separated(
                        itemCount: state.wifiNetworks.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 12),
                        itemBuilder: (context, index) {
                          final net = state.wifiNetworks[index];
                          final signal = net['signal'] as int;
                          final inUse = net['inUse'] == true;
                          final isLocked =
                              net['security'].isNotEmpty &&
                              net['security'] != '--';

                          return _ConnectionTile(
                            icon: inUse
                                ? Icons.wifi_rounded
                                : signal > 50
                                ? Icons.wifi_rounded
                                : Icons.wifi_2_bar_rounded,
                            title: net['ssid'] as String,
                            subtitle: inUse
                                ? state.t('net_connected')
                                : _signalText(state, signal),
                            active: inUse,
                            locked: isLocked,
                            chipColor: inUse
                                ? Colors.greenAccent.shade400
                                : theme.colorScheme.tertiary,
                            trailingText: '$signal%',
                            onTap: inUse
                                ? null
                                : () => _showWifiPasswordDialog(
                                    context,
                                    state,
                                    net['ssid'] as String,
                                    net['security'] as String,
                                  ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );

        return Column(
          children: [
            const SizedBox(height: 10),
            NebulaScreenIntro(
              badge: state.t('net_badge'),
              title: state.t('net_title'),
              description: state.t('net_desc'),
            ),
            const SizedBox(height: 24),
            if (compact)
              Expanded(
                child: Column(
                  children: [
                    summaryPanel,
                    const SizedBox(height: 18),
                    Expanded(child: wifiPanel),
                  ],
                ),
              )
            else
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 3, child: summaryPanel),
                    const SizedBox(width: 22),
                    Expanded(flex: 5, child: wifiPanel),
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
                NebulaSecondaryButton(
                  label: state.t('offline'),
                  icon: Icons.wifi_off_rounded,
                  onPressed: () {
                    state.networkStatus = 'offline';
                    state.nextStep();
                  },
                ),
                const SizedBox(width: 12),
                NebulaPrimaryButton(
                  label: state.t('connect'),
                  icon: Icons.arrow_forward_rounded,
                  onPressed: onlineReady ? state.nextStep : null,
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  void _showWifiPasswordDialog(
    BuildContext context,
    InstallerState state,
    String ssid,
    String security,
  ) {
    if (security.isEmpty || security == '--' || security == 'NONE') {
      state.connectToWifi(ssid, '');
      return;
    }

    final theme = Theme.of(context);
    String password = '';
    bool isConnecting = false;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: theme.cardColor,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              title: Text(state.t('net_wifi_dialog_title', {'ssid': ssid})),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    obscureText: true,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: state.t('net_password_label'),
                    ),
                    onChanged: (value) => password = value,
                  ),
                  if (isConnecting)
                    const Padding(
                      padding: EdgeInsets.only(top: 16),
                      child: CircularProgressIndicator(),
                    ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: isConnecting
                      ? null
                      : () => Navigator.pop(dialogContext),
                  child: Text(state.t('cancel')),
                ),
                ElevatedButton(
                  onPressed: (isConnecting || password.isEmpty)
                      ? null
                      : () async {
                          setDialogState(() => isConnecting = true);
                          final success = await state.connectToWifi(
                            ssid,
                            password,
                          );

                          if (!context.mounted) {
                            return;
                          }

                          setDialogState(() => isConnecting = false);

                          if (success) {
                            Navigator.pop(dialogContext);
                          } else {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  state.t('net_connect_failed', {'ssid': ssid}),
                                ),
                                backgroundColor: Colors.redAccent,
                              ),
                            );
                          }
                        },
                  child: Text(state.t('net_connect_action')),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _ConnectionTile extends StatelessWidget {
  const _ConnectionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.active,
    required this.chipColor,
    this.locked = false,
    this.trailingText,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool active;
  final Color chipColor;
  final bool locked;
  final String? trailingText;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: active
                ? theme.colorScheme.primary.withValues(alpha: 0.14)
                : theme.colorScheme.surface.withValues(
                    alpha: theme.brightness == Brightness.dark ? 0.22 : 0.58,
                  ),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: active
                  ? theme.colorScheme.primary.withValues(alpha: 0.7)
                  : theme.colorScheme.outlineVariant.withValues(alpha: 0.42),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: chipColor.withValues(alpha: 0.14),
                ),
                child: Icon(icon, color: chipColor, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: context.installerVisuals.mutedForeground,
                      ),
                    ),
                  ],
                ),
              ),
              if (trailingText != null) ...[
                Text(
                  trailingText!,
                  style: theme.textTheme.labelLarge?.copyWith(color: chipColor),
                ),
                const SizedBox(width: 10),
              ],
              if (locked) ...[
                Icon(
                  Icons.lock_outline_rounded,
                  size: 18,
                  color: context.installerVisuals.mutedForeground,
                ),
                const SizedBox(width: 10),
              ],
              if (active)
                Icon(
                  Icons.check_circle_rounded,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
