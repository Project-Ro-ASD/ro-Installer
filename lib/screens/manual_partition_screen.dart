import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../state/installer_state.dart';
import '../services/partition_service.dart';

class ManualPartitionScreen extends StatefulWidget {
  const ManualPartitionScreen({super.key});

  @override
  State<ManualPartitionScreen> createState() => _ManualPartitionScreenState();
}

class _ManualPartitionScreenState extends State<ManualPartitionScreen> {
  int? _selectedIndex;
  bool _isLoading = true;
  String? _loadedDisk;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = Provider.of<InstallerState>(context);
    if (_loadedDisk != state.selectedDisk) {
       _loadedDisk = state.selectedDisk;
       _loadPartitions();
    }
  }

  void _loadPartitions() {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
       if (!mounted) return;
       final state = Provider.of<InstallerState>(context, listen: false);
       setState(() => _isLoading = true);
       
       if (state.manualPartitions.isEmpty && state.selectedDisk.isNotEmpty) {
          final realParts = await PartitionService.instance.getPartitions(state.selectedDisk);
          if (mounted) {
             state.manualPartitions = realParts;
          }
       }
       if (mounted) setState(() => _isLoading = false);
    });
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return "${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB";
    } else {
      return "${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB";
    }
  }

  void _openAddDialog(BuildContext context, InstallerState state) {
    if (_selectedIndex == null || _selectedIndex! >= state.manualPartitions.length) return;
    
    final part = state.manualPartitions[_selectedIndex!];
    if (part['isFreeSpace'] != true) return;

    final maxMb = (part['sizeBytes'] as int) ~/ (1024 * 1024);
    int inputMb = maxMb;
    
    String tempFormat = 'btrfs';
    String tempMount = '/';

    final textController = TextEditingController(text: inputMb.toString());

    showDialog(
       context: context,
       builder: (c) {
          return StatefulBuilder(builder: (c, setDialogState) {
             return AlertDialog(
                title: const Text("Yeni Bölüm Oluştur"),
                content: Column(
                   mainAxisSize: MainAxisSize.min,
                   children: [
                      const Text("DİKKAT: İşlem planlanacaktır, hemen uygulanmaz.", style: TextStyle(color: Colors.orange, fontSize: 12)),
                      const SizedBox(height: 16),
                      TextField(
                         controller: textController,
                         keyboardType: TextInputType.number,
                         inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                         decoration: InputDecoration(
                            labelText: 'Boyut (MB) [Maksimum: $maxMb MB]',
                         ),
                         onChanged: (v) {
                            int? parsed = int.tryParse(v);
                            if (parsed != null && parsed > maxMb) {
                               textController.text = maxMb.toString();
                            }
                         },
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                         value: tempFormat,
                         decoration: const InputDecoration(labelText: 'Dosya Sistemi (File System)'),
                         items: ['btrfs', 'ext4', 'xfs', 'fat32', 'linux-swap'].map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                         onChanged: (v) {
                             setDialogState(() {
                                 tempFormat = v!;
                                 if (tempFormat == 'fat32') tempMount = '/boot/efi';
                             });
                         },
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                         value: tempMount,
                         decoration: const InputDecoration(labelText: 'Bağlama Noktası (Mount Point)'),
                         items: ['/', '/home', '/boot', '/boot/efi', '[SWAP]', 'unmounted'].map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                         onChanged: (v) => setDialogState(() => tempMount = v!),
                      ),
                   ],
                ),
                actions: [
                   TextButton(onPressed: () => Navigator.pop(c), child: const Text("İptal")),
                   ElevatedButton(
                      onPressed: () {
                         int chosenMb = int.tryParse(textController.text) ?? maxMb;
                         if (chosenMb <= 0) return;
                         if (chosenMb > maxMb) chosenMb = maxMb;
                         
                         int newBytes = chosenMb * 1024 * 1024;
                         int remainingBytes = (part['sizeBytes'] as int) - newBytes;

                         setState(() {
                            state.manualPartitions.insert(_selectedIndex!, {
                               'name': 'New Partition',
                               'type': tempFormat,
                               'sizeBytes': newBytes,
                               'mount': tempMount,
                               'flags': (tempMount == '/boot/efi' || tempFormat == 'fat32') ? 'boot, esp' : '',
                               'isFreeSpace': false,
                               'isPlanned': true
                            });

                            if (remainingBytes > 10 * 1024 * 1024) {
                               state.manualPartitions[_selectedIndex! + 1]['sizeBytes'] = remainingBytes;
                            } else {
                               state.manualPartitions.removeAt(_selectedIndex! + 1);
                            }
                            _selectedIndex = null;
                         });
                         Navigator.pop(c);
                      }, 
                      child: const Text("Oluştur")
                   )
                ]
             );
          });
       }
    );
  }

  void _actionDelete(InstallerState state) {
    if (_selectedIndex == null || _selectedIndex! >= state.manualPartitions.length) return;
    final part = state.manualPartitions[_selectedIndex!];
    if (part['isFreeSpace'] == true) return; // Zaten boşluk olanı silinmez

    setState(() {
       part['isFreeSpace'] = true;
       part['type'] = 'unallocated';
       part['name'] = 'Free Space';
       part['mount'] = 'unmounted';
       part['flags'] = '';
       part['isPlanned'] = true;

       // Merge Free Spaces (Yukarıdan Aşağıya)
       for (int i = 0; i < state.manualPartitions.length - 1; i++) {
          if (state.manualPartitions[i]['isFreeSpace'] == true && state.manualPartitions[i+1]['isFreeSpace'] == true) {
             state.manualPartitions[i]['sizeBytes'] = (state.manualPartitions[i]['sizeBytes'] as int) + (state.manualPartitions[i+1]['sizeBytes'] as int);
             state.manualPartitions.removeAt(i+1);
             i--; // Yinelenen döngü kontrolü
          }
       }
       _selectedIndex = null;
    });
  }

  void _openFormatDialog(BuildContext context, InstallerState state) {
    if (_selectedIndex == null || _selectedIndex! >= state.manualPartitions.length) return;
    
    final part = state.manualPartitions[_selectedIndex!];
    if (part['isFreeSpace'] == true) return; // Free space formatlanmaz, bölüm oluşturulur

    String tempFormat = ['btrfs', 'ext4', 'xfs', 'fat32', 'linux-swap', 'unallocated'].contains(part['type']) 
        ? part['type'] : 'btrfs';
    String tempMount = ['/', '/home', '/boot', '/boot/efi', '[SWAP]', 'unmounted'].contains(part['mount']) 
        ? part['mount'] : 'unmounted';
    
    showDialog(
       context: context,
       builder: (c) {
          return StatefulBuilder(builder: (c, setDialogState) {
             return AlertDialog(
                title: Text("Bölümü Formatla: ${part['name']}"),
                content: Column(
                   mainAxisSize: MainAxisSize.min,
                   children: [
                      const Text("DİKKAT: İşlem planlanacaktır, hemen uygulanmaz.", style: TextStyle(color: Colors.orange, fontSize: 12)),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                         value: tempFormat,
                         decoration: const InputDecoration(labelText: 'Dosya Sistemi (File System)'),
                         items: ['btrfs', 'ext4', 'xfs', 'fat32', 'linux-swap', 'unallocated'].map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                         onChanged: (v) => setDialogState(() => tempFormat = v!),
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                         value: tempMount,
                         decoration: const InputDecoration(labelText: 'Bağlama Noktası (Mount Point)'),
                         items: ['/', '/home', '/boot', '/boot/efi', '[SWAP]', 'unmounted'].map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                         onChanged: (v) => setDialogState(() => tempMount = v!),
                      ),
                   ],
                ),
                actions: [
                   TextButton(onPressed: () => Navigator.pop(c), child: const Text("İptal")),
                   ElevatedButton(
                      onPressed: () {
                         setState(() {
                            part['type'] = tempFormat;
                            part['mount'] = tempMount;
                            if (tempMount == '/boot/efi' || tempFormat == 'fat32') part['flags'] = 'boot, esp';
                            part['isPlanned'] = true; // Sisteme format atılacağı bildiriliyor
                         });
                         Navigator.pop(c);
                      }, 
                      child: const Text("Format Planla")
                   )
                ]
             );
          });
       }
    );
  }

  void _openResizeDialog(BuildContext context, InstallerState state) {
    if (_selectedIndex == null || _selectedIndex! >= state.manualPartitions.length) return;
    
    final part = state.manualPartitions[_selectedIndex!];
    // Kullanıcı yeni eklediği planlı bir bölümü (henüz diske yazılmamış) veya zaten boş olan alanı küçültmemelidir.
    if (part['isFreeSpace'] == true || part['isPlanned'] == true) return; 

    final maxMb = (part['sizeBytes'] as int) ~/ (1024 * 1024);
    final textController = TextEditingController(text: maxMb.toString());

    showDialog(
       context: context,
       builder: (c) {
          return StatefulBuilder(builder: (c, setDialogState) {
             return AlertDialog(
                title: Text("Bölümü Küçült: ${part['name']}"),
                content: Column(
                   mainAxisSize: MainAxisSize.min,
                   children: [
                      const Text("DİKKAT: Veri kaybı riski nedeniyle, sistemin varsayılan Resize yeteneklerine güvenmek yerine bu işlemi kurulum öncesi Windows üzerinden yapmanız daha güvenlidir.", style: TextStyle(color: Colors.orange, fontSize: 12)),
                      const SizedBox(height: 16),
                      Text("Mevcut Boyut: $maxMb MB", style: const TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 16),
                      TextField(
                         controller: textController,
                         keyboardType: TextInputType.number,
                         inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                         decoration: InputDecoration(
                            labelText: 'Yeni Boyut (MB) [Maksimum: $maxMb MB]',
                         ),
                         onChanged: (v) {
                            int? parsed = int.tryParse(v);
                            if (parsed != null && parsed > maxMb) {
                               textController.text = maxMb.toString();
                            }
                         },
                      ),
                   ],
                ),
                actions: [
                   TextButton(onPressed: () => Navigator.pop(c), child: const Text("İptal")),
                   ElevatedButton(
                      onPressed: () {
                         int chosenMb = int.tryParse(textController.text) ?? maxMb;
                         if (chosenMb <= 0 || chosenMb >= maxMb) return;
                         
                         int newBytes = chosenMb * 1024 * 1024;
                         int remainingBytes = (part['sizeBytes'] as int) - newBytes;

                         setState(() {
                            part['sizeBytes'] = newBytes;
                            part['isResized'] = true; // Yükleyici son adımda bunu yakalayacak

                            // Kestiğimiz alanı yeni "Free Space" olaral hemen altına ekliyoruz
                            state.manualPartitions.insert(_selectedIndex! + 1, {
                               'name': 'Free Space',
                               'type': 'unallocated',
                               'sizeBytes': remainingBytes,
                               'mount': 'unmounted',
                               'flags': '',
                               'isFreeSpace': true, // Gerçek boş alan yaratıldı
                               'isPlanned': false 
                            });
                         });
                         Navigator.pop(c);
                      }, 
                      child: const Text("Ayarla")
                   )
                ]
             );
          });
       }
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<InstallerState>(context);
    final theme = Theme.of(context);
    final isDark = state.themeMode == 'dark';
    final textColor = isDark ? Colors.white : Colors.black87;

    bool isSelectedFreeSpace = false;
    bool hasSelection = _selectedIndex != null && _selectedIndex! < state.manualPartitions.length;
    if (hasSelection) {
       isSelectedFreeSpace = state.manualPartitions[_selectedIndex!]['isFreeSpace'] == true;
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 20),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: theme.colorScheme.primary.withOpacity(0.5)),
                ),
                child: Text(
                  state.t('part_badge'),
                  style: TextStyle(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                state.t('part_title'),
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: textColor,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                state.selectedDisk.isEmpty 
                    ? state.t('part_desc') 
                    : "${state.t('part_desc')}\nSeçilen Hedef Disk: ${state.selectedDisk}",
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: textColor.withOpacity(0.6),
                ),
              ),
            ],
          ),
        ),

        // Partition Table
        Expanded(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 20),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: theme.cardColor.withOpacity(isDark ? 0.3 : 0.6),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withOpacity(0.1)),
            ),
            child: Column(
              children: [
                // Table Header
                Padding(
                  padding: const EdgeInsets.only(bottom: 12, left: 16, right: 16),
                  child: Row(
                    children: [
                      Expanded(flex: 2, child: Text("BÖLÜM (DEVICE)", style: _headerStyle(textColor))),
                      Expanded(flex: 2, child: Text("FORMAT (TYPE)", style: _headerStyle(textColor))),
                      Expanded(flex: 2, child: Text("BOYUT (SIZE)", style: _headerStyle(textColor))),
                      Expanded(flex: 3, child: Text("BAĞLANTI (MOUNT POINT)", style: _headerStyle(textColor))),
                      Expanded(flex: 2, child: Text("DURUM (FLAGS)", style: _headerStyle(textColor))),
                    ],
                  ),
                ),
                const Divider(color: Colors.white24, height: 1),
                const SizedBox(height: 12),
                
                // Table Body
                Expanded(
                  child: _isLoading 
                    ? const Center(child: CircularProgressIndicator()) 
                    : ListView.builder(
                    itemCount: state.manualPartitions.length,
                    itemBuilder: (context, index) {
                      final part = state.manualPartitions[index];
                      final isSelected = _selectedIndex == index;
                      final isPlanned = part['isPlanned'] == true;
                      final isFreeSpace = part['isFreeSpace'] == true;
                      
                      return GestureDetector(
                        onTap: () => setState(() => _selectedIndex = index),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
                          decoration: BoxDecoration(
                            color: isSelected 
                                ? theme.colorScheme.primary.withOpacity(0.3) 
                                : (isPlanned && !isFreeSpace ? theme.colorScheme.secondary.withOpacity(0.1) : Colors.transparent),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: isSelected ? theme.colorScheme.primary : (isFreeSpace ? Colors.grey.withOpacity(0.3) : Colors.transparent),
                            ),
                          ),
                          child: Row(
                            children: [
                              Expanded(flex: 2, child: Text(part["name"], style: TextStyle(color: isFreeSpace ? Colors.grey : textColor, fontStyle: isFreeSpace ? FontStyle.italic : FontStyle.normal, fontWeight: isFreeSpace ? FontWeight.normal : FontWeight.bold))),
                              Expanded(flex: 2, child: Text(part["type"], style: TextStyle(color: _getTypeColor(part["type"])))),
                              Expanded(flex: 2, child: Text(_formatBytes(part["sizeBytes"]), style: TextStyle(color: textColor.withOpacity(0.8)))),
                              Expanded(flex: 3, child: Text(part["mount"] ?? '-', style: TextStyle(color: textColor.withOpacity(isFreeSpace ? 0.3 : 0.8)))),
                              Expanded(flex: 2, child: Text(
                                isPlanned && !isFreeSpace ? "Planlandı ⚠️" : (part["flags"] ?? ''), 
                                style: TextStyle(color: isPlanned ? Colors.orange : Colors.grey, fontSize: 12, fontWeight: isPlanned ? FontWeight.bold : FontWeight.normal)
                              )),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                
                // Partition Actions
                const SizedBox(height: 20),
                const Divider(color: Colors.white24, height: 1),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _actionBtn(context, state.t('part_add'), Icons.add, isSelectedFreeSpace ? () => _openAddDialog(context, state) : null),
                    _actionBtn(context, "Küçült", Icons.compress, (!isSelectedFreeSpace && hasSelection) ? () => _openResizeDialog(context, state) : null),
                    _actionBtn(context, state.t('part_delete'), Icons.remove, (!isSelectedFreeSpace && hasSelection) ? () => _actionDelete(state) : null),
                    _actionBtn(context, state.t('part_format'), Icons.build, (!isSelectedFreeSpace && hasSelection) ? () => _openFormatDialog(context, state) : null),
                  ],
                ),
              ],
            ),
          ),
        ),

        // Navigation
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
                   bool hasRoot = false;
                   bool hasEfi = false;
                   int rootSize = 0;
                   int efiSize = 0;
                   String rootType = '';
                   String efiType = '';
                   bool hasSwap = false;
                   String swapType = '';
                   bool hasBoot = false;
                   int bootSize = 0;
                   String bootType = '';

                   for (var p in state.manualPartitions) {
                       if (p['isFreeSpace'] == true) continue;
                       
                       final size = p['sizeBytes'] as int;
                       final mb = size ~/ (1024 * 1024);
                       final mount = p['mount'];
                       final type = p['type'];

                       if (mount == '/') {
                           hasRoot = true;
                           rootSize += mb;
                           rootType = type;
                       } else if (mount == '/boot/efi') {
                           hasEfi = true;
                           efiSize += mb;
                           efiType = type;
                       } else if (mount == '/boot') {
                           hasBoot = true;
                           bootSize += mb;
                           bootType = type;
                       } else if (mount == '[SWAP]') {
                           hasSwap = true;
                           swapType = type;
                       }
                   }

                   void showError(String msg) {
                     ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.redAccent, duration: const Duration(seconds: 4)));
                   }

                   // 1) Kök Dizini (Root) Kontrolleri
                   if (!hasRoot) return showError("Kurulum için bir Kök Dizin ( / ) bağlama noktası oluşturmalısınız.");
                   if (rootSize < 40000) return showError("Kök dizin (/) için en az 40 GB (yaklaşık 40000 MB) alan oluşturmalısınız. (Sistem paketleri için gereklidir.)");
                   if (rootType == 'fat32' || rootType == 'ntfs') return showError("Kök dizin (/) dosya formatı fat32 veya ntfs olamaz. Lütfen linux odaklı bir format (ör: ext4, btrfs, xfs) seçin.");

                   // 2) EFI Kontrolleri
                   if (!hasEfi) return showError("Mount noktası /boot/efi olan bir EFI başlangıç dizinine ihtiyacınız var.");
                   if (efiSize < 100 || efiSize > 2500) return showError("EFI (/boot/efi) boyutu en az 100 MB ve en fazla 2500 MB olmalıdır.");
                   if (efiType != 'fat32') return showError("UEFI sistemlerde başlatıcı (EFI) bölümünün dosya sistemi muhakkak 'fat32' olmalıdır.");

                   // 3) İsteğe Bağlı Boot Kontrolleri
                   if (hasBoot) {
                      if (bootSize < 500) return showError("Ayrı bir /boot dizini oluşturduysanız boyutu linux çekirdeği için en az 500 MB olmalıdır.");
                      if (bootType == 'fat32' || bootType == 'ntfs') return showError("/boot dosya sistemi linux tabanlı (örn: ext4) olmalıdır. 'fat32' formatı yalnızca /boot/efi için lazımdır.");
                   }

                   // 4) SWAP Format Kontrolü
                   if (hasSwap && swapType != 'linux-swap') return showError("Takas alanı (SWAP) dosya sistemi 'linux-swap' olmalıdır.");

                   // 5) SWAP Uyarı Pop-Up Yönetimi
                   if (!hasSwap) {
                      showDialog(
                         context: context,
                         builder: (c) => AlertDialog(
                            title: const Text("Takas Alanı (SWAP) Eksik", style: TextStyle(color: Colors.orange)),
                            content: const Text(
                               "Tablonuzda bir SWAP alanı veya mount noktası bulunamadı.\n\n"
                               "Avantajı: Takas alanı (SWAP), sistem belleği (RAM) tamamen dolduğunda ani çöküşleri engeller ve uyku moduna (hibernate) destek sağlar.\n\n"
                               "Dezavantajı: Disk üzerinde alan kaplar.\n\n"
                               "Linux için genellikle en az 4GB SWAP önerilir. Yine de SWAP olmadan kuruluma geçmek istiyor musunuz?"
                            ),
                            actions: [
                               TextButton(
                                  onPressed: () => Navigator.pop(c),
                                  child: const Text("Geri Dön ve Ayır")
                               ),
                               ElevatedButton(
                                  onPressed: () {
                                     Navigator.pop(c);
                                     state.nextStep(); // Geçerli tabloyı kabul et ve devam et
                                  },
                                  style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
                                  child: const Text("SWAP Olmadan İlerle", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold))
                               )
                            ]
                         )
                      );
                   } else {
                      // Tüm engeller aşıldı ve Swap alanı da var, doğrudan ileri git
                      state.nextStep();
                   }
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
        fontSize: 11,
        fontWeight: FontWeight.bold,
        letterSpacing: 1.2,
        color: textColor.withOpacity(0.5),
      );

  Color _getTypeColor(String type) {
    switch (type) {
      case 'ext4': return Colors.orange;
      case 'btrfs': return Colors.blue;
      case 'fat32': return Colors.green;
      case 'linux-swap': return Colors.redAccent;
      case 'unallocated': return Colors.grey;
      default: return Colors.grey;
    }
  }

  Widget _actionBtn(BuildContext context, String label, IconData icon, VoidCallback? onPressed) {
    final theme = Theme.of(context);
    final isDisabled = onPressed == null;
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: isDisabled ? Colors.grey : theme.colorScheme.primary,
        side: BorderSide(color: isDisabled ? Colors.grey.withOpacity(0.3) : theme.colorScheme.primary.withOpacity(0.5)),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      ),
    );
  }
}
