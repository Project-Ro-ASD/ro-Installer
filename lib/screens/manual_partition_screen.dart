import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/installer_state.dart';

class ManualPartitionScreen extends StatefulWidget {
  const ManualPartitionScreen({super.key});

  @override
  State<ManualPartitionScreen> createState() => _ManualPartitionScreenState();
}

class _ManualPartitionScreenState extends State<ManualPartitionScreen> {
  // Simülasyon için sahte disk bölümleri
  final List<Map<String, String>> _mockPartitions = [
    {"name": "/dev/sda1", "type": "fat32", "size": "512 MB", "mount": "/boot/efi", "flags": "boot, esp"},
    {"name": "/dev/sda2", "type": "ext4", "size": "120 GB", "mount": "/", "flags": ""},
    {"name": "/dev/sda3", "type": "btrfs", "size": "370 GB", "mount": "/home", "flags": ""},
    {"name": "/dev/sda4", "type": "linux-swap", "size": "9.5 GB", "mount": "[SWAP]", "flags": ""},
  ];

  int? _selectedIndex;

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<InstallerState>(context);
    final theme = Theme.of(context);
    final isDark = state.themeMode == 'dark';
    final textColor = isDark ? Colors.white : Colors.black87;

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
                state.t('part_title'), // Manual Partitioning
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: textColor,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                state.selectedDisk.isEmpty 
                    ? state.t('part_desc') 
                    : "${state.t('part_desc')}\nSelected Disk: ${state.selectedDisk}",
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
                      Expanded(flex: 2, child: Text("DEVICE", style: _headerStyle(textColor))),
                      Expanded(flex: 2, child: Text("TYPE", style: _headerStyle(textColor))),
                      Expanded(flex: 2, child: Text("SIZE", style: _headerStyle(textColor))),
                      Expanded(flex: 3, child: Text("MOUNT POINT", style: _headerStyle(textColor))),
                      Expanded(flex: 2, child: Text("FLAGS", style: _headerStyle(textColor))),
                    ],
                  ),
                ),
                const Divider(color: Colors.white24, height: 1),
                const SizedBox(height: 12),
                
                // Table Body
                Expanded(
                  child: ListView.builder(
                    itemCount: _mockPartitions.length + 1, // +1 for "Free Space"
                    itemBuilder: (context, index) {
                      if (index == _mockPartitions.length) {
                        return _buildFreeSpaceRow(textColor, theme, index);
                      }
                      
                      final part = _mockPartitions[index];
                      final isSelected = _selectedIndex == index;
                      
                      return GestureDetector(
                        onTap: () => setState(() => _selectedIndex = index),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
                          decoration: BoxDecoration(
                            color: isSelected ? theme.colorScheme.primary.withOpacity(0.2) : Colors.transparent,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: isSelected ? theme.colorScheme.primary : Colors.transparent,
                            ),
                          ),
                          child: Row(
                            children: [
                              Expanded(flex: 2, child: Text(part["name"]!, style: TextStyle(color: textColor, fontWeight: FontWeight.bold))),
                              Expanded(flex: 2, child: Text(part["type"]!, style: TextStyle(color: _getTypeColor(part["type"]!)))),
                              Expanded(flex: 2, child: Text(part["size"]!, style: TextStyle(color: textColor.withOpacity(0.8)))),
                              Expanded(flex: 3, child: Text(part["mount"]!, style: TextStyle(color: textColor.withOpacity(0.8)))),
                              Expanded(flex: 2, child: Text(part["flags"]!, style: const TextStyle(color: Colors.grey, fontSize: 12))),
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
                    _actionBtn(context, state.t('part_add'), Icons.add),
                    _actionBtn(context, state.t('part_delete'), Icons.remove),
                    _actionBtn(context, state.t('part_format'), Icons.build),
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

  Widget _buildFreeSpaceRow(Color textColor, ThemeData theme, int index) {
    final isSelected = _selectedIndex == index;
    return GestureDetector(
      onTap: () => setState(() => _selectedIndex = index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
        decoration: BoxDecoration(
          color: isSelected ? theme.colorScheme.primary.withOpacity(0.2) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? theme.colorScheme.primary : Colors.transparent,
          ),
        ),
        child: Row(
          children: [
            Expanded(flex: 2, child: Text("Free Space", style: TextStyle(color: Colors.grey.shade400, fontStyle: FontStyle.italic))),
            const Expanded(flex: 2, child: Text("unallocated", style: TextStyle(color: Colors.grey))),
            Expanded(flex: 2, child: Text("1.2 GB", style: TextStyle(color: textColor.withOpacity(0.8)))),
            const Expanded(flex: 3, child: Text("-", style: TextStyle(color: Colors.grey))),
            const Expanded(flex: 2, child: Text("", style: TextStyle(color: Colors.grey))),
          ],
        ),
      ),
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
      default: return Colors.grey;
    }
  }

  Widget _actionBtn(BuildContext context, String label, IconData icon) {
    final theme = Theme.of(context);
    return OutlinedButton.icon(
      onPressed: () {},
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: theme.colorScheme.primary,
        side: BorderSide(color: theme.colorScheme.primary.withOpacity(0.5)),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      ),
    );
  }
}
