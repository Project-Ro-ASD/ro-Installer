import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/partition_service.dart';
import '../state/installer_state.dart';
import '../theme/app_theme.dart';
import '../utils/manual_partition_sizing.dart';
import '../widgets/nebula_ui.dart';

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

  void _loadPartitions({bool forceReload = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        return;
      }

      final state = Provider.of<InstallerState>(context, listen: false);
      setState(() => _isLoading = true);

      if ((forceReload || state.manualPartitions.isEmpty) &&
          state.selectedDisk.isNotEmpty) {
        final realParts = await PartitionService.instance.getPartitions(
          state.selectedDisk,
        );
        if (mounted) {
          state.manualPartitions = realParts;
          _selectedIndex = null;
        }
      }

      if (mounted) {
        setState(() => _isLoading = false);
      }
    });
  }

  String _filesystemForMount(String mount, {String fallback = 'btrfs'}) {
    final normalizedFallback = _normalizeFilesystemType(fallback);
    switch (mount) {
      case '/boot/efi':
        return 'fat32';
      case '[SWAP]':
        return 'linux-swap';
      default:
        if ([
          'btrfs',
          'ext4',
          'xfs',
          'fat32',
          'linux-swap',
        ].contains(normalizedFallback)) {
          return normalizedFallback;
        }
        return 'btrfs';
    }
  }

  String _normalizeFilesystemType(String type) {
    switch (type) {
      case 'vfat':
        return 'fat32';
      case 'swap':
        return 'linux-swap';
      default:
        return type;
    }
  }

  bool _canMergeSelection(InstallerState state) {
    if (_selectedIndex == null ||
        _selectedIndex! < 0 ||
        _selectedIndex! >= state.manualPartitions.length) {
      return false;
    }

    final part = state.manualPartitions[_selectedIndex!];
    if (part['isFreeSpace'] != true) {
      return false;
    }

    final hasPrev =
        _selectedIndex! > 0 &&
        state.manualPartitions[_selectedIndex! - 1]['isFreeSpace'] == true;
    final hasNext =
        _selectedIndex! < state.manualPartitions.length - 1 &&
        state.manualPartitions[_selectedIndex! + 1]['isFreeSpace'] == true;
    return hasPrev || hasNext;
  }

  void _mergeSelectedFreeSpace(InstallerState state) {
    if (!_canMergeSelection(state)) {
      return;
    }

    var start = _selectedIndex!;
    var end = _selectedIndex!;
    var totalBytes =
        state.manualPartitions[_selectedIndex!]['sizeBytes'] as int;

    while (start > 0 &&
        state.manualPartitions[start - 1]['isFreeSpace'] == true) {
      start--;
      totalBytes += state.manualPartitions[start]['sizeBytes'] as int;
    }

    while (end < state.manualPartitions.length - 1 &&
        state.manualPartitions[end + 1]['isFreeSpace'] == true) {
      end++;
      totalBytes += state.manualPartitions[end]['sizeBytes'] as int;
    }

    setState(() {
      state.manualPartitions.replaceRange(start, end + 1, [
        {
          'name': 'Free Space',
          'type': 'unallocated',
          'sizeBytes': totalBytes,
          'mount': 'unmounted',
          'currentMount': 'unmounted',
          'flags': '',
          'isFreeSpace': true,
          'isPlanned': true,
          'formatOnInstall': false,
        },
      ]);
      _selectedIndex = start;
    });
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  void _openAddDialog(BuildContext context, InstallerState state) {
    if (_selectedIndex == null ||
        _selectedIndex! >= state.manualPartitions.length) {
      return;
    }

    final part = state.manualPartitions[_selectedIndex!];
    if (part['isFreeSpace'] != true) {
      return;
    }

    final rawFreeBytes = part['sizeBytes'] as int;
    final isTrailingFreeSpace =
        _selectedIndex == state.manualPartitions.length - 1;
    final maxUsableBytes = manualMaxNewPartitionBytes(
      rawFreeBytes,
      reserveTrailingSafetyGap: isTrailingFreeSpace,
    );
    final maxMb = maxUsableBytes ~/ (1024 * 1024);
    final rawMaxMb = rawFreeBytes ~/ (1024 * 1024);
    if (maxMb <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(state.t('part_no_usable_space')),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    var tempMount = '/';
    final textController = TextEditingController(text: maxMb.toString());

    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return AlertDialog(
              title: Text(state.t('part_create_title')),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    state.t('part_planned_warning'),
                    style: const TextStyle(color: Colors.orange, fontSize: 12),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: textController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(
                      labelText: state.t('part_size_label', {
                        'max': maxMb.toString(),
                      }),
                      helperText: rawMaxMb != maxMb
                          ? state.t('part_reserved_gap_hint', {
                              'size': (rawMaxMb - maxMb).toString(),
                            })
                          : null,
                    ),
                    onChanged: (value) {
                      final parsed = int.tryParse(value);
                      if (parsed != null && parsed > maxMb) {
                        textController.text = maxMb.toString();
                      }
                    },
                  ),
                  const SizedBox(height: 16),
                  _ManualDialogDropdown(
                    label: state.t('part_mount_point_label'),
                    icon: Icons.alt_route_rounded,
                    value: tempMount,
                    items: const [
                      '/',
                      '/home',
                      '/boot',
                      '/boot/efi',
                      '[SWAP]',
                      'unmounted',
                    ],
                    onChanged: (value) =>
                        setDialogState(() => tempMount = value),
                  ),
                  const SizedBox(height: 16),
                  _ManualValuePreview(
                    label: state.t('part_filesystem_label'),
                    value: _filesystemForMount(tempMount).toUpperCase(),
                    icon: Icons.data_object_rounded,
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: Text(state.t('cancel')),
                ),
                ElevatedButton(
                  onPressed: () {
                    var chosenMb = int.tryParse(textController.text) ?? maxMb;
                    if (chosenMb <= 0) {
                      return;
                    }
                    if (chosenMb > maxMb) {
                      chosenMb = maxMb;
                    }

                    final newBytes = chosenMb * 1024 * 1024;
                    final remainingBytes =
                        (part['sizeBytes'] as int) - newBytes;

                    setState(() {
                      state.manualPartitions.insert(_selectedIndex!, {
                        'name': 'New Partition',
                        'type': _filesystemForMount(tempMount),
                        'sizeBytes': newBytes,
                        'mount': tempMount,
                        'currentMount': 'unmounted',
                        'flags': tempMount == '/boot/efi' ? 'boot, esp' : '',
                        'isFreeSpace': false,
                        'isPlanned': true,
                        'formatOnInstall': true,
                      });

                      if (remainingBytes > 10 * 1024 * 1024) {
                        state.manualPartitions[_selectedIndex! +
                                1]['sizeBytes'] =
                            remainingBytes;
                      } else {
                        state.manualPartitions.removeAt(_selectedIndex! + 1);
                      }
                      _selectedIndex = null;
                    });
                    Navigator.pop(dialogContext);
                  },
                  child: Text(state.t('part_create_action')),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _actionDelete(InstallerState state) {
    if (_selectedIndex == null ||
        _selectedIndex! >= state.manualPartitions.length) {
      return;
    }

    final part = state.manualPartitions[_selectedIndex!];
    if (part['isFreeSpace'] == true) {
      return;
    }

    setState(() {
      part['isFreeSpace'] = true;
      part['type'] = 'unallocated';
      part['name'] = 'Free Space';
      part['mount'] = 'unmounted';
      part['currentMount'] = 'unmounted';
      part['flags'] = '';
      part['isPlanned'] = true;
      part['formatOnInstall'] = false;

      for (var i = 0; i < state.manualPartitions.length - 1; i++) {
        if (state.manualPartitions[i]['isFreeSpace'] == true &&
            state.manualPartitions[i + 1]['isFreeSpace'] == true) {
          state.manualPartitions[i]['sizeBytes'] =
              (state.manualPartitions[i]['sizeBytes'] as int) +
              (state.manualPartitions[i + 1]['sizeBytes'] as int);
          state.manualPartitions.removeAt(i + 1);
          i--;
        }
      }
      _selectedIndex = null;
    });
  }

  void _openAssignDialog(BuildContext context, InstallerState state) {
    if (_selectedIndex == null ||
        _selectedIndex! >= state.manualPartitions.length) {
      return;
    }

    final part = state.manualPartitions[_selectedIndex!];
    if (part['isFreeSpace'] == true) {
      return;
    }

    final partName = (part['name'] ?? '').toString();
    final existingType = _normalizeFilesystemType(
      (part['type'] ?? 'btrfs').toString(),
    );
    final isNewPartition =
        partName.startsWith('New Partition') || partName == 'New Partition';
    var tempMount =
        [
          '/',
          '/home',
          '/boot',
          '/boot/efi',
          '[SWAP]',
          'unmounted',
        ].contains(part['mount'])
        ? part['mount'] as String
        : 'unmounted';
    var tempFormatOnInstall = isNewPartition
        ? part['formatOnInstall'] != false
        : part['formatOnInstall'] == true;

    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            final previewFs = tempFormatOnInstall
                ? _filesystemForMount(tempMount, fallback: existingType)
                : existingType;
            final formatHint = tempFormatOnInstall
                ? state.t('part_format_hint_rewrite')
                : state.t('part_format_hint_keep');
            return AlertDialog(
              title: Text(state.t('part_use_title', {'part': partName})),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    state.t('part_planned_warning'),
                    style: const TextStyle(color: Colors.orange, fontSize: 12),
                  ),
                  const SizedBox(height: 16),
                  _ManualDialogDropdown(
                    label: state.t('part_mount_point_label'),
                    icon: Icons.alt_route_rounded,
                    value: tempMount,
                    items: const [
                      '/',
                      '/home',
                      '/boot',
                      '/boot/efi',
                      '[SWAP]',
                      'unmounted',
                    ],
                    onChanged: (value) =>
                        setDialogState(() => tempMount = value),
                  ),
                  const SizedBox(height: 16),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: Text(state.t('part_format_on_install')),
                    subtitle: Text(formatHint),
                    value: tempFormatOnInstall,
                    onChanged: (value) => setDialogState(() {
                      tempFormatOnInstall = value;
                    }),
                  ),
                  const SizedBox(height: 16),
                  _ManualValuePreview(
                    label: state.t('part_filesystem_label'),
                    value: previewFs.toUpperCase(),
                    icon: Icons.data_object_rounded,
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: Text(state.t('cancel')),
                ),
                ElevatedButton(
                  onPressed: () {
                    final resolvedFs = tempFormatOnInstall
                        ? _filesystemForMount(tempMount, fallback: existingType)
                        : existingType;
                    final shouldPlan =
                        isNewPartition ||
                        tempMount != 'unmounted' ||
                        tempFormatOnInstall;
                    setState(() {
                      part['type'] = resolvedFs;
                      part['mount'] = tempMount;
                      if (tempMount == '/boot/efi' &&
                          ((part['flags'] ?? '') as String).isEmpty) {
                        part['flags'] = 'boot, esp';
                      } else if (isNewPartition && tempMount != '/boot/efi') {
                        part['flags'] = '';
                      }
                      part['isPlanned'] = shouldPlan;
                      part['formatOnInstall'] =
                          shouldPlan && tempFormatOnInstall;
                    });
                    Navigator.pop(dialogContext);
                  },
                  child: Text(state.t('part_save_plan')),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // ignore: unused_element
  void _openResizeDialog(BuildContext context, InstallerState state) {
    if (_selectedIndex == null ||
        _selectedIndex! >= state.manualPartitions.length) {
      return;
    }

    final part = state.manualPartitions[_selectedIndex!];
    if (part['isFreeSpace'] == true || part['isPlanned'] == true) {
      return;
    }

    final maxMb = (part['sizeBytes'] as int) ~/ (1024 * 1024);
    final textController = TextEditingController(text: maxMb.toString());

    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return AlertDialog(
              title: Text(
                state.t('part_resize_title', {
                  'part': (part['name'] ?? '').toString(),
                }),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    state.t('part_resize_warning'),
                    style: const TextStyle(color: Colors.orange, fontSize: 12),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    state.t('part_current_size', {'size': '$maxMb MB'}),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: textController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(
                      labelText: state.t('part_new_size_label', {
                        'max': maxMb.toString(),
                      }),
                    ),
                    onChanged: (value) {
                      final parsed = int.tryParse(value);
                      if (parsed != null && parsed > maxMb) {
                        textController.text = maxMb.toString();
                      }
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: Text(state.t('cancel')),
                ),
                ElevatedButton(
                  onPressed: () {
                    var chosenMb = int.tryParse(textController.text) ?? maxMb;
                    if (chosenMb <= 0 || chosenMb >= maxMb) {
                      return;
                    }

                    final newBytes = chosenMb * 1024 * 1024;
                    final remainingBytes =
                        (part['sizeBytes'] as int) - newBytes;

                    setState(() {
                      part['sizeBytes'] = newBytes;
                      part['isResized'] = true;

                      state.manualPartitions.insert(_selectedIndex! + 1, {
                        'name': 'Free Space',
                        'type': 'unallocated',
                        'sizeBytes': remainingBytes,
                        'mount': 'unmounted',
                        'currentMount': 'unmounted',
                        'flags': '',
                        'isFreeSpace': true,
                        'isPlanned': false,
                        'formatOnInstall': false,
                      });
                    });
                    Navigator.pop(dialogContext);
                  },
                  child: Text(state.t('part_apply_action')),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _validateAndContinue(InstallerState state) {
    var hasRoot = false;
    var hasEfi = false;
    var rootSize = 0;
    var efiSize = 0;
    var rootType = '';
    var efiType = '';
    var hasSwap = false;
    var swapType = '';
    var rootWillBeFormatted = false;
    var bootWillBeFormatted = false;
    var hasBoot = false;
    var bootSize = 0;
    var bootType = '';

    for (final partition in state.manualPartitions) {
      if (partition['isFreeSpace'] == true) {
        continue;
      }

      final size = partition['sizeBytes'] as int;
      final mb = size ~/ (1024 * 1024);
      final mount = partition['mount'];
      final type = _normalizeFilesystemType(
        (partition['type'] ?? 'unknown').toString(),
      );
      final formatOnInstall = partition.containsKey('formatOnInstall')
          ? partition['formatOnInstall'] == true
          : partition['isPlanned'] == true;

      if (mount == '/') {
        hasRoot = true;
        rootSize += mb;
        rootType = type;
        rootWillBeFormatted = formatOnInstall;
      } else if (mount == '/boot/efi') {
        hasEfi = true;
        efiSize += mb;
        efiType = type;
      } else if (mount == '/boot') {
        hasBoot = true;
        bootSize += mb;
        bootType = type;
        bootWillBeFormatted = formatOnInstall;
      } else if (mount == '[SWAP]') {
        hasSwap = true;
        swapType = type;
      }
    }

    void showError(String message) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.redAccent,
          duration: const Duration(seconds: 4),
        ),
      );
    }

    if (!hasRoot) {
      return showError(state.t('part_err_missing_root'));
    }
    if (rootSize < 20000) {
      return showError(state.t('part_err_root_small'));
    }
    if (rootType != 'btrfs') {
      return showError(state.t('part_err_root_fs'));
    }
    if (!rootWillBeFormatted) {
      return showError(state.t('part_err_root_format'));
    }

    if (!hasEfi) {
      return showError(state.t('part_err_missing_efi'));
    }
    if (efiSize < 100 || efiSize > 2500) {
      return showError(state.t('part_err_efi_size'));
    }
    if (efiType != 'fat32') {
      return showError(state.t('part_err_efi_fs'));
    }

    if (hasBoot) {
      if (bootSize < 500) {
        return showError(state.t('part_err_boot_small'));
      }
      if (bootType != 'btrfs') {
        return showError(state.t('part_err_boot_fs'));
      }
      if (!bootWillBeFormatted) {
        return showError(state.t('part_err_boot_format'));
      }
    }

    if (hasSwap && swapType != 'linux-swap') {
      return showError(state.t('part_err_swap_fs'));
    }

    if (!hasSwap) {
      return showError(state.t('part_err_missing_swap'));
    }

    state.nextStep();
  }

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<InstallerState>(context);
    final theme = Theme.of(context);
    final hasSelection =
        _selectedIndex != null &&
        _selectedIndex! < state.manualPartitions.length;
    final selectedPart = hasSelection
        ? state.manualPartitions[_selectedIndex!]
        : null;
    final isSelectedFreeSpace = selectedPart?['isFreeSpace'] == true;
    final plannedCount = state.manualPartitions
        .where((part) => part['isPlanned'] == true)
        .length;
    final canMerge = _canMergeSelection(state);

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 1220;

        final inventoryPanel = _PartitionInventoryPanel(
          isLoading: _isLoading,
          selectedDisk: state.selectedDisk,
          partitions: state.manualPartitions,
          selectedIndex: _selectedIndex,
          onSelect: (index) => setState(() => _selectedIndex = index),
          formatBytes: _formatBytes,
        );

        final controlPanel = _PartitionControlPanel(
          selectedPart: selectedPart,
          formatBytes: _formatBytes,
          onAdd: isSelectedFreeSpace
              ? () => _openAddDialog(context, state)
              : null,
          onResize: null,
          onMerge: canMerge ? () => _mergeSelectedFreeSpace(state) : null,
          onDelete: hasSelection && !isSelectedFreeSpace
              ? () => _actionDelete(state)
              : null,
          onFormat: hasSelection && !isSelectedFreeSpace
              ? () => _openAssignDialog(context, state)
              : null,
          onReload: () => _loadPartitions(forceReload: true),
        );

        return Column(
          children: [
            const SizedBox(height: 8),
            _ManualWorkspaceHeader(
              diskLabel: state.selectedDisk,
              entryCount: state.manualPartitions.length,
              plannedCount: plannedCount,
              selectedName: selectedPart?['name']?.toString(),
            ),
            const SizedBox(height: 14),
            if (compact)
              Expanded(
                child: Column(
                  children: [
                    Expanded(flex: 7, child: inventoryPanel),
                    const SizedBox(height: 12),
                    Expanded(flex: 5, child: controlPanel),
                  ],
                ),
              )
            else
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 8, child: inventoryPanel),
                    const SizedBox(width: 16),
                    Expanded(flex: 5, child: controlPanel),
                  ],
                ),
              ),
            const SizedBox(height: 16),
            Row(
              children: [
                NebulaSecondaryButton(
                  label: state.t('prev'),
                  icon: Icons.arrow_back_rounded,
                  onPressed: state.previousStep,
                ),
                const Spacer(),
                if (!compact)
                  Padding(
                    padding: const EdgeInsets.only(right: 16),
                    child: Text(
                      state.t('part_validation_note'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: context.installerVisuals.mutedForeground,
                      ),
                    ),
                  ),
                NebulaPrimaryButton(
                  label: state.t('next'),
                  icon: Icons.arrow_forward_rounded,
                  onPressed: () => _validateAndContinue(state),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _ManualWorkspaceHeader extends StatelessWidget {
  const _ManualWorkspaceHeader({
    required this.diskLabel,
    required this.entryCount,
    required this.plannedCount,
    this.selectedName,
  });

  final String diskLabel;
  final int entryCount;
  final int plannedCount;
  final String? selectedName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = Provider.of<InstallerState>(context, listen: false);

    return NebulaPanel(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Expanded(
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  state.t('part_workspace_title'),
                  style: theme.textTheme.titleMedium,
                ),
                _CompactInfoChip(
                  label: diskLabel.isEmpty
                      ? state.t('part_no_disk_selected')
                      : diskLabel,
                  color: theme.colorScheme.primary,
                  icon: Icons.storage_rounded,
                ),
                _CompactInfoChip(
                  label: state.t('part_block_count', {
                    'count': entryCount.toString(),
                  }),
                  color: theme.colorScheme.tertiary,
                  icon: Icons.view_list_rounded,
                ),
                _CompactInfoChip(
                  label: state.t('part_plan_count', {
                    'count': plannedCount.toString(),
                  }),
                  color: plannedCount > 0
                      ? theme.colorScheme.secondary
                      : theme.colorScheme.outline,
                  icon: Icons.auto_fix_high_rounded,
                ),
                if (selectedName != null)
                  _CompactInfoChip(
                    label: selectedName!,
                    color: theme.colorScheme.primary,
                    icon: Icons.radio_button_checked_rounded,
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            state.t('part_requirement_summary'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: context.installerVisuals.mutedForeground,
            ),
          ),
        ],
      ),
    );
  }
}

class _PartitionInventoryPanel extends StatelessWidget {
  const _PartitionInventoryPanel({
    required this.isLoading,
    required this.selectedDisk,
    required this.partitions,
    required this.selectedIndex,
    required this.onSelect,
    required this.formatBytes,
  });

  final bool isLoading;
  final String selectedDisk;
  final List<Map<String, dynamic>> partitions;
  final int? selectedIndex;
  final ValueChanged<int> onSelect;
  final String Function(int bytes) formatBytes;

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<InstallerState>(context, listen: false);
    Widget body;
    if (isLoading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (partitions.isEmpty) {
      body = Center(
        child: Text(
          state.t('part_map_not_loaded'),
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: context.installerVisuals.mutedForeground,
          ),
        ),
      );
    } else {
      body = Column(
        children: [
          const _PartitionTableHeader(),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.separated(
              itemCount: partitions.length,
              itemBuilder: (context, index) {
                final part = partitions[index];
                return _PartitionCard(
                  partition: part,
                  selected: selectedIndex == index,
                  onTap: () => onSelect(index),
                  sizeLabel: formatBytes(part['sizeBytes'] as int),
                );
              },
              separatorBuilder: (context, index) => const SizedBox(height: 8),
            ),
          ),
        ],
      );
    }

    return NebulaPanel(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  selectedDisk.isEmpty
                      ? state.t('part_selected_disk_waiting')
                      : state.t('part_disk_map_title', {'disk': selectedDisk}),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Text(
                state.t('part_raw_map_hint'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: context.installerVisuals.mutedForeground,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _DiskTimelineBar(
            partitions: partitions,
            selectedIndex: selectedIndex,
            formatBytes: formatBytes,
          ),
          const SizedBox(height: 12),
          Expanded(child: body),
        ],
      ),
    );
  }
}

class _PartitionControlPanel extends StatelessWidget {
  const _PartitionControlPanel({
    required this.selectedPart,
    required this.formatBytes,
    required this.onAdd,
    required this.onResize,
    required this.onMerge,
    required this.onDelete,
    required this.onFormat,
    required this.onReload,
  });

  final Map<String, dynamic>? selectedPart;
  final String Function(int bytes) formatBytes;
  final VoidCallback? onAdd;
  final VoidCallback? onResize;
  final VoidCallback? onMerge;
  final VoidCallback? onDelete;
  final VoidCallback? onFormat;
  final VoidCallback onReload;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = Provider.of<InstallerState>(context, listen: false);
    final tone = _partitionTone(selectedPart);

    return NebulaPanel(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (selectedPart == null)
            Text(
              state.t('part_select_row_hint'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: context.installerVisuals.mutedForeground,
                height: 1.4,
              ),
            )
          else ...[
            Row(
              children: [
                Icon(tone.icon, color: tone.color, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _partitionDisplayName(state, selectedPart!['name']),
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _CompactInfoChip(
                  label: (selectedPart!['type'] ?? 'unknown').toString(),
                  color: tone.color,
                  icon: tone.icon,
                ),
                _CompactInfoChip(
                  label: formatBytes(selectedPart!['sizeBytes'] as int),
                  color: theme.colorScheme.primary,
                  icon: Icons.straighten_rounded,
                ),
                _CompactInfoChip(
                  label: (selectedPart!['mount'] ?? 'unmounted').toString(),
                  color: theme.colorScheme.tertiary,
                  icon: Icons.drive_file_move_rounded,
                ),
                if (_currentMountLabel(selectedPart) != null)
                  _CompactInfoChip(
                    label: state.t('part_live_mount', {
                      'mount': _currentMountLabel(selectedPart)!,
                    }),
                    color: theme.colorScheme.outline,
                    icon: Icons.my_location_rounded,
                  ),
                if (((selectedPart!['flags'] ?? '') as String).isNotEmpty)
                  _CompactInfoChip(
                    label: selectedPart!['flags'].toString(),
                    color: theme.colorScheme.secondary,
                    icon: Icons.flag_rounded,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (selectedPart!['isPlanned'] == true)
              Text(
                _plannedStatusDescription(state, selectedPart!),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: _formatsOnInstall(selectedPart!)
                      ? theme.colorScheme.secondary
                      : theme.colorScheme.primary,
                ),
              ),
          ],
          const SizedBox(height: 14),
          Divider(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.34),
          ),
          const SizedBox(height: 14),
          Text(state.t('part_tools'), style: theme.textTheme.titleSmall),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _ActionTile(
                label: state.t('part_action_add'),
                icon: Icons.add_rounded,
                onPressed: onAdd,
              ),
              _ActionTile(
                label: state.t('part_action_resize'),
                icon: Icons.compress_rounded,
                onPressed: onResize,
              ),
              _ActionTile(
                label: state.t('part_action_merge'),
                icon: Icons.merge_type_rounded,
                onPressed: onMerge,
              ),
              _ActionTile(
                label: state.t('part_action_delete'),
                icon: Icons.remove_circle_outline_rounded,
                onPressed: onDelete,
              ),
              _ActionTile(
                label: state.t('part_action_assign'),
                icon: Icons.build_rounded,
                onPressed: onFormat,
              ),
              _ActionTile(
                label: state.t('part_action_rescan'),
                icon: Icons.refresh_rounded,
                onPressed: onReload,
              ),
            ],
          ),
          const SizedBox(height: 14),
          Divider(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.34),
          ),
          const SizedBox(height: 14),
          Text(state.t('part_rules'), style: theme.textTheme.titleSmall),
          const SizedBox(height: 10),
          _RequirementLine(text: state.t('part_rule_root')),
          const SizedBox(height: 8),
          _RequirementLine(text: state.t('part_rule_efi')),
          const SizedBox(height: 8),
          _RequirementLine(text: state.t('part_rule_boot')),
          const SizedBox(height: 8),
          _RequirementLine(text: state.t('part_rule_swap')),
          const SizedBox(height: 8),
          const _RequirementLine(
            text:
                'Mevcut EFI korunabilir. Kok (/) ve ayri /boot kullanilacaksa kurulumda bicimlendirilmesi zorunludur.',
          ),
          const SizedBox(height: 8),
          const _RequirementLine(
            text:
                'Canli bolum kucultme ilk guvenli surumde kapali tutuluyor. Simdilik yeni bolum, silme, bicimlendirme ve mevcut bolumu yeniden kullanma akislarina odaklaniliyor.',
          ),
        ],
      ),
    );
  }
}

class _PartitionCard extends StatelessWidget {
  const _PartitionCard({
    required this.partition,
    required this.selected,
    required this.onTap,
    required this.sizeLabel,
  });

  final Map<String, dynamic> partition;
  final bool selected;
  final VoidCallback onTap;
  final String sizeLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = Provider.of<InstallerState>(context, listen: false);
    final tone = _partitionTone(partition);
    final planned = partition['isPlanned'] == true;
    final free = partition['isFreeSpace'] == true;
    late final IconData statusIcon;
    late final Color statusColor;

    if (planned) {
      if (_formatsOnInstall(partition)) {
        statusIcon = Icons.build_circle_rounded;
        statusColor = theme.colorScheme.secondary;
      } else {
        statusIcon = Icons.alt_route_rounded;
        statusColor = theme.colorScheme.primary;
      }
    } else if (selected) {
      statusIcon = Icons.check_circle_rounded;
      statusColor = tone.color;
    } else {
      statusIcon = Icons.circle_outlined;
      statusColor = theme.colorScheme.outline.withValues(alpha: 0.7);
    }

    return AnimatedContainer(
      duration: context.installerMotion.medium,
      curve: context.installerMotion.enterCurve,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: selected
              ? tone.color.withValues(alpha: 0.78)
              : theme.colorScheme.outlineVariant.withValues(alpha: 0.36),
          width: selected ? 1.6 : 1,
        ),
        boxShadow: selected
            ? [
                BoxShadow(
                  color: tone.color.withValues(alpha: 0.16),
                  blurRadius: 24,
                  spreadRadius: -12,
                ),
              ]
            : const [],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: tone.color.withValues(alpha: 0.14),
                  ),
                  child: Icon(tone.icon, color: tone.color, size: 18),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 4,
                  child: Text(
                    _partitionDisplayName(state, partition['name']),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: free
                          ? context.installerVisuals.mutedForeground
                          : theme.colorScheme.onSurface,
                    ),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    (partition['type'] ?? 'unknown').toString(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: tone.color,
                    ),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(sizeLabel, style: theme.textTheme.bodySmall),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    (partition['mount'] ?? 'unmounted').toString(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: context.installerVisuals.mutedForeground,
                    ),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    ((partition['flags'] ?? '') as String).isEmpty
                        ? '-'
                        : partition['flags'].toString(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: context.installerVisuals.mutedForeground,
                    ),
                  ),
                ),
                SizedBox(
                  width: 32,
                  child: Icon(statusIcon, size: 18, color: statusColor),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DiskTimelineBar extends StatelessWidget {
  const _DiskTimelineBar({
    required this.partitions,
    required this.selectedIndex,
    required this.formatBytes,
  });

  final List<Map<String, dynamic>> partitions;
  final int? selectedIndex;
  final String Function(int bytes) formatBytes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = Provider.of<InstallerState>(context, listen: false);

    if (partitions.isEmpty) {
      return const SizedBox.shrink();
    }

    final totalBytes = partitions.fold<int>(
      0,
      (sum, part) => sum + ((part['sizeBytes'] as int?) ?? 0),
    );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: theme.colorScheme.surface.withValues(alpha: 0.18),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.34),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                state.t('part_disk_timeline'),
                style: theme.textTheme.titleSmall,
              ),
              const Spacer(),
              Text(
                state.t('part_block_count', {
                  'count': partitions.length.toString(),
                }),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: context.installerVisuals.mutedForeground,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              for (var i = 0; i < partitions.length; i++)
                Expanded(
                  flex: _segmentFlex(
                    (partitions[i]['sizeBytes'] as int?) ?? 0,
                    totalBytes,
                  ),
                  child: Container(
                    height: 20,
                    margin: EdgeInsets.only(
                      right: i == partitions.length - 1 ? 0 : 4,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      color: _partitionTone(partitions[i]).color.withValues(
                        alpha: selectedIndex == i ? 0.9 : 0.46,
                      ),
                      border: Border.all(
                        color: selectedIndex == i
                            ? Colors.white.withValues(alpha: 0.7)
                            : Colors.transparent,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < partitions.length; i++)
                _CompactInfoChip(
                  label:
                      '${_partitionDisplayName(state, partitions[i]['name'])} • ${formatBytes((partitions[i]['sizeBytes'] as int?) ?? 0)}',
                  color: _partitionTone(partitions[i]).color,
                  icon: _partitionTone(partitions[i]).icon,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PartitionTableHeader extends StatelessWidget {
  const _PartitionTableHeader();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = Provider.of<InstallerState>(context, listen: false);

    TextStyle? labelStyle = theme.textTheme.bodySmall?.copyWith(
      color: context.installerVisuals.mutedForeground,
      fontWeight: FontWeight.w600,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          const SizedBox(width: 46),
          Expanded(
            flex: 4,
            child: Text(state.t('part_col_partition'), style: labelStyle),
          ),
          Expanded(
            flex: 2,
            child: Text(state.t('part_col_type'), style: labelStyle),
          ),
          Expanded(
            flex: 2,
            child: Text(state.t('part_col_size'), style: labelStyle),
          ),
          Expanded(
            flex: 2,
            child: Text(state.t('part_col_mount'), style: labelStyle),
          ),
          Expanded(
            flex: 2,
            child: Text(state.t('part_col_flags'), style: labelStyle),
          ),
          const SizedBox(width: 32),
        ],
      ),
    );
  }
}

class _CompactInfoChip extends StatelessWidget {
  const _CompactInfoChip({
    required this.label,
    required this.color,
    required this.icon,
  });

  final String label;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = onPressed != null;

    return SizedBox(
      width: 150,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onPressed,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: theme.colorScheme.surface.withValues(
                alpha: enabled ? 0.2 : 0.12,
              ),
              border: Border.all(
                color: enabled
                    ? theme.colorScheme.outlineVariant.withValues(alpha: 0.42)
                    : theme.colorScheme.outlineVariant.withValues(alpha: 0.22),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 17,
                  color: enabled
                      ? theme.colorScheme.primary
                      : theme.colorScheme.outline,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: enabled
                          ? theme.colorScheme.onSurface
                          : theme.colorScheme.outline,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ManualValuePreview extends StatelessWidget {
  const _ManualValuePreview({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: theme.colorScheme.surface.withValues(alpha: 0.2),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.34),
        ),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 10),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: context.installerVisuals.mutedForeground,
            ),
          ),
          const Spacer(),
          Text(
            value,
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

class _RequirementLine extends StatelessWidget {
  const _RequirementLine({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.check_rounded,
          size: 18,
          color: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: context.installerVisuals.mutedForeground,
            ),
          ),
        ),
      ],
    );
  }
}

class _ManualDialogDropdown extends StatelessWidget {
  const _ManualDialogDropdown({
    required this.label,
    required this.icon,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final String label;
  final IconData icon;
  final String value;
  final List<String> items;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: context.installerVisuals.mutedForeground,
          ),
        ),
        const SizedBox(height: 8),
        NebulaDropdown<String>(
          value: value,
          dense: true,
          leadingIcon: icon,
          maxMenuHeight: 260,
          items: items
              .map(
                (item) => NebulaDropdownItem<String>(
                  value: item,
                  label: item,
                  icon: icon,
                ),
              )
              .toList(),
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class _PartitionTone {
  const _PartitionTone({required this.icon, required this.color});

  final IconData icon;
  final Color color;
}

String? _currentMountLabel(Map<String, dynamic>? partition) {
  if (partition == null) {
    return null;
  }

  final value = (partition['currentMount'] ?? 'unmounted').toString().trim();
  if (value.isEmpty || value == 'unmounted') {
    return null;
  }
  return value;
}

bool _formatsOnInstall(Map<String, dynamic> partition) {
  if (partition['formatOnInstall'] != null) {
    return partition['formatOnInstall'] == true;
  }
  return partition['isPlanned'] == true;
}

String _partitionDisplayName(InstallerState state, dynamic name) {
  final value = (name ?? 'Partition').toString();
  return switch (value) {
    'New Partition' => state.t('part_name_new'),
    'Free Space' => state.t('part_name_free_space'),
    'Partition' => state.t('part_name_partition'),
    _ => value,
  };
}

String _plannedStatusDescription(
  InstallerState state,
  Map<String, dynamic> partition,
) {
  final mount = (partition['mount'] ?? 'unmounted').toString();
  if (_formatsOnInstall(partition)) {
    return mount == 'unmounted'
        ? state.t('part_planned_format_unmounted')
        : state.t('part_planned_format_mount', {'mount': mount});
  }

  return mount == 'unmounted'
      ? state.t('part_planned_none')
      : state.t('part_planned_reuse_mount', {'mount': mount});
}

_PartitionTone _partitionTone(Map<String, dynamic>? partition) {
  if (partition == null) {
    return const _PartitionTone(
      icon: Icons.blur_on_rounded,
      color: Colors.grey,
    );
  }

  if (partition['isFreeSpace'] == true) {
    return const _PartitionTone(
      icon: Icons.space_dashboard_rounded,
      color: Colors.grey,
    );
  }

  switch ((partition['type'] ?? '').toString()) {
    case 'ext4':
      return const _PartitionTone(
        icon: Icons.folder_open_rounded,
        color: Color(0xFFFFA24D),
      );
    case 'btrfs':
      return const _PartitionTone(
        icon: Icons.layers_rounded,
        color: Color(0xFF74A9FF),
      );
    case 'xfs':
      return const _PartitionTone(
        icon: Icons.speed_rounded,
        color: Color(0xFF62D6FF),
      );
    case 'fat32':
    case 'vfat':
      return const _PartitionTone(
        icon: Icons.usb_rounded,
        color: Color(0xFF6BE7B1),
      );
    case 'linux-swap':
    case 'swap':
      return const _PartitionTone(
        icon: Icons.swap_horiz_rounded,
        color: Colors.redAccent,
      );
    default:
      return const _PartitionTone(
        icon: Icons.storage_rounded,
        color: Colors.grey,
      );
  }
}

int _segmentFlex(int bytes, int totalBytes) {
  if (bytes <= 0 || totalBytes <= 0) {
    return 1;
  }

  final ratio = bytes / totalBytes;
  final flex = (ratio * 100).round();
  if (flex < 1) {
    return 1;
  }
  return flex;
}
