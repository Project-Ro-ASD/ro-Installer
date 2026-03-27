import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/installer_state.dart';
import '../services/disk_service.dart';

class DiskSelectionScreen extends StatefulWidget {
  const DiskSelectionScreen({super.key});

  @override
  State<DiskSelectionScreen> createState() => _DiskSelectionScreenState();
}

class _DiskSelectionScreenState extends State<DiskSelectionScreen> {
  List<dynamic> _disks = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadDisks();
  }

  Future<void> _loadDisks() async {
    setState(() => _isLoading = true);
    final diskList = await DiskService.instance.getDisks();
    if (mounted) {
      setState(() {
        _disks = diskList;
        final state = Provider.of<InstallerState>(context, listen: false);
        // Otomatik disk seçimi sadece canlı olmayanları seçecek
        if (_disks.isNotEmpty && state.selectedDisk.isEmpty) {
          final safeDisks = _disks.where((d) => d['isLive'] != true).toList();
          if (safeDisks.isNotEmpty) {
            state.selectDisk(safeDisks.first);
          }
        }
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<InstallerState>(context);
    final theme = Theme.of(context);
    final isDark = state.themeMode == 'dark';
    final textColor = isDark ? Colors.white : Colors.black87;
    final isAdvanced = state.installType == 'advanced';

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 20),
          child: Column(
            children: [
              Text(
                state.t('disk_title'),
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: textColor,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                state.t('disk_desc'),
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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Sol Tarafta Disk Listesi
              Expanded(
                flex: 3,
                child: Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: theme.cardColor.withOpacity(isDark ? 0.3 : 0.6),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white.withOpacity(0.1)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text("AVAILABLE DISKS", style: _headerStyle(textColor)),
                          IconButton(
                            icon: const Icon(Icons.refresh, size: 20),
                            onPressed: _isLoading ? null : _loadDisks,
                            color: theme.colorScheme.primary,
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Expanded(
                        child: _isLoading
                            ? const Center(child: CircularProgressIndicator())
                            : ListView.builder(
                                itemCount: _disks.length,
                                itemBuilder: (context, index) {
                                  final disk = _disks[index] as Map<String, dynamic>;
                                  final isSelected = state.selectedDisk == disk['name'];
                                  final isLive = disk['isLive'] == true;
                                  final isSafe = disk['isSafe'] == true;

                                  IconData diskIcon = Icons.save_alt;
                                  Color iconColor = isSelected ? theme.colorScheme.primary : Colors.grey;

                                  if (isSafe) {
                                    diskIcon = Icons.science;
                                    iconColor = isSelected ? Colors.greenAccent : Colors.green.shade300;
                                  } else if (isLive) {
                                    diskIcon = Icons.usb;
                                    iconColor = Colors.redAccent.withOpacity(0.5);
                                  }

                                  final double sizeGB = disk['size'] is int ? (disk['size'] as int) / (1024*1024*1024) : 0;
                                  String subtitle = "${disk['type']} • ${sizeGB.toStringAsFixed(1)} GB";
                                  if (isLive) subtitle = "Cannot Format (Live OS USB)";
                                  if (isSafe) subtitle = "Safe Test Environment";

                                  return GestureDetector(
                                    onTap: () {
                                      state.selectDisk(disk);
                                    },
                                    child: AnimatedContainer(
                                      duration: const Duration(milliseconds: 200),
                                      margin: const EdgeInsets.only(bottom: 12),
                                      padding: const EdgeInsets.all(16),
                                      decoration: BoxDecoration(
                                        color: isSelected ? theme.colorScheme.primary.withOpacity(0.2) : Colors.transparent,
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(
                                          color: isSelected ? theme.colorScheme.primary : Colors.grey.withOpacity(0.2),
                                          width: isSelected ? 2 : 1,
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          Icon(diskIcon, color: iconColor),
                                          const SizedBox(width: 16),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(disk['name'], style: TextStyle(fontWeight: FontWeight.bold, color: isLive && !isSelected ? Colors.grey : textColor)),
                                                Text(subtitle, style: TextStyle(color: isLive ? Colors.redAccent.withOpacity(0.7) : Colors.grey, fontSize: 13, fontWeight: isLive ? FontWeight.bold : FontWeight.normal)),
                                              ],
                                            ),
                                          ),
                                          if (isSelected) Icon(Icons.check_circle, color: theme.colorScheme.primary),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 20),

              // Sağ Tarafta Ayarlar (File System & Partition Method)
              Expanded(
                flex: 2,
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                    // Dosya Sistemi Seçimi
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: theme.cardColor.withOpacity(isDark ? 0.3 : 0.6),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.white.withOpacity(0.1)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(state.t('disk_fs'), style: _headerStyle(textColor)),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              _fsButton(context, state, 'btrfs', 'BTRFS'),
                              const SizedBox(width: 10),
                              _fsButton(context, state, 'ext4', 'EXT4'),
                              const SizedBox(width: 10),
                              _fsButton(context, state, 'xfs', 'XFS'),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    
                    // Format metodu (Kural: Advanced ise Manual Option gelir)
                    Container(
                      padding: const EdgeInsets.all(20),
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: theme.cardColor.withOpacity(isDark ? 0.3 : 0.6),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.white.withOpacity(0.1)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(state.t('disk_method'), style: _headerStyle(textColor)),
                          const SizedBox(height: 16),
                          _methodButton(context, state, 'full', state.t('disk_full'), Icons.delete_sweep),
                          const SizedBox(height: 12),
                          _methodButton(context, state, 'alongside', state.t('disk_alongside'), Icons.call_split),
                          if (isAdvanced) ...[
                            const SizedBox(height: 12),
                            _methodButton(context, state, 'manual', state.t('disk_manual'), Icons.handyman),
                          ]
                        ],
                      ),
                    ),
                  ],
                ),
              ))
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
                onPressed: () {
                  if (state.selectedDisk.isEmpty || state.selectedDiskDetails == null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text("Lütfen kurulacak hedef diski seçiniz."), backgroundColor: Colors.orange)
                    );
                    return;
                  }

                  final isLive = state.selectedDiskDetails!['isLive'] == true;
                  final isSafe = state.selectedDiskDetails!['isSafe'] == true;

                  if (isLive) {
                    showDialog(
                      context: context, 
                      builder: (c) => AlertDialog(
                        title: const Text("Hatalı Hedef Sürücü", style: TextStyle(color: Colors.red)),
                        content: const Text("Seçtiğiniz bu sürücü şu an çalıştırmakta olduğunuz Live ISO USB belleğidir. Aktif işletim sistemi medyasını formatlayamazsınız!"),
                        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text("Tamam"))]
                      )
                    );
                    return;
                  }

                  // Test modunda veya gerçek disk modunda onay iste
                  showDialog(
                    context: context,
                    builder: (c) => AlertDialog(
                      title: Text(isSafe ? 'TEST FORMATI ONAYI' : '⚠️ FORMAT UYARISI', style: TextStyle(color: isSafe ? Colors.green : Colors.red)),
                      content: Text(
                        isSafe 
                         ? "${state.selectedDisk} sanal disk testidir. Fiziki disklerinize zarar vermez.\nDevam edilsin mi?"
                         : "${state.selectedDisk} üzerindeki BÜTÜN VERİLER KALICI OLARAK SİLİNECEK.\nİşlemi onaylıyor musunuz?"
                      ),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(c), child: const Text("İptal")),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(backgroundColor: isSafe ? Colors.green : Colors.redAccent),
                          onPressed: () {
                            Navigator.pop(c);
                            state.nextStep();
                          }, 
                          child: Text(isSafe ? "TESTE DEVAM ET" : "DİSKİ SİL VE KUR", style: const TextStyle(color: Colors.white))
                        )
                      ]
                    )
                  );
                },
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

  TextStyle _headerStyle(Color textColor) => TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.bold,
        letterSpacing: 1.5,
        color: textColor.withOpacity(0.5),
      );

  Widget _fsButton(BuildContext context, InstallerState state, String code, String label) {
    final theme = Theme.of(context);
    final isSelected = state.fileSystem == code;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          state.fileSystem = code;
          state.notifyListeners();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: isSelected ? theme.colorScheme.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: isSelected ? theme.colorScheme.primary : Colors.grey.withOpacity(0.3)),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: isSelected ? Colors.white : (state.themeMode == 'dark' ? Colors.white70 : Colors.black87),
            ),
          ),
        ),
      ),
    );
  }

  Widget _methodButton(BuildContext context, InstallerState state, String code, String label, IconData icon) {
    final theme = Theme.of(context);
    final isDark = state.themeMode == 'dark';
    final isSelected = state.partitionMethod == code;
    return GestureDetector(
      onTap: () {
        state.partitionMethod = code;
        state.notifyListeners();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isSelected ? theme.colorScheme.primary.withOpacity(0.2) : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: isSelected ? theme.colorScheme.primary : Colors.grey.withOpacity(0.3)),
        ),
        child: Column(
          children: [
            Row(
              children: [
                Icon(icon, color: isSelected ? theme.colorScheme.primary : Colors.grey),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: isSelected ? theme.colorScheme.primary : (isDark ? Colors.white : Colors.black87),
                    ),
                  ),
                ),
                if (isSelected) Icon(Icons.radio_button_checked, color: theme.colorScheme.primary)
                else const Icon(Icons.radio_button_unchecked, color: Colors.grey),
              ],
            ),
            
            // Yanına Kur Seçildiyse Slider Animasyonu ile Altta Gösterilir
            AnimatedCrossFade(
              duration: const Duration(milliseconds: 300),
              crossFadeState: (isSelected && code == 'alongside') ? CrossFadeState.showSecond : CrossFadeState.showFirst,
              firstChild: const SizedBox(width: double.infinity, height: 0),
              secondChild: Padding(
                padding: const EdgeInsets.only(top: 24, bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text("${state.linuxDiskSizeGB.toInt()} GB", style: TextStyle(fontWeight: FontWeight.bold, color: theme.colorScheme.primary)),
                        Text("${(state.totalDiskSizeGB - state.linuxDiskSizeGB).toInt()} GB", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 12,
                        activeTrackColor: theme.colorScheme.primary,
                        inactiveTrackColor: isDark ? const Color(0xFF2A2A35) : Colors.grey.shade300,
                        thumbColor: Colors.white,
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10, elevation: 5),
                        overlayShape: const RoundSliderOverlayShape(overlayRadius: 20),
                      ),
                      child: Slider(
                        value: state.linuxDiskSizeGB,
                        min: 40.0, // Minimum 40GB sınır
                        max: state.totalDiskSizeGB - 20, // Windows'a da bi 20gb falan kalsın
                        onChanged: (val) {
                          state.linuxDiskSizeGB = val;
                          state.notifyListeners();
                        },
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(state.t('linux_size'), style: TextStyle(fontSize: 10, color: theme.colorScheme.primary)),
                        Text(state.t('windows_size'), style: const TextStyle(fontSize: 10, color: Colors.grey)),
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
}
