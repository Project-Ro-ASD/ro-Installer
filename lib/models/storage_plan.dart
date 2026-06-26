class StoragePlan {
  const StoragePlan({
    required this.planId,
    required this.mode,
    required this.targetDisk,
    required this.fileSystem,
    required this.operations,
  });

  final String planId;
  final String mode;
  final String targetDisk;
  final String fileSystem;
  final List<StoragePlanOperation> operations;

  List<StoragePlanOperation> get destructiveOperations =>
      operations.where((operation) => operation.destructive).toList();

  bool hasOperation(
    String type,
    String target, {
    bool destructiveOnly = false,
    Map<String, dynamic> details = const <String, dynamic>{},
  }) {
    return operations.any(
      (operation) =>
          operation.type == type &&
          operation.target == target &&
          (!destructiveOnly || operation.destructive) &&
          operation.matchesDetails(details),
    );
  }

  Map<String, dynamic> toJson() => {
    'planId': planId,
    'mode': mode,
    'targetDisk': targetDisk,
    'fileSystem': fileSystem,
    'operations': operations.map((operation) => operation.toJson()).toList(),
    'destructiveOperations': destructiveOperations
        .map((operation) => operation.toJson())
        .toList(),
  };
}

class StoragePlanOperation {
  const StoragePlanOperation({
    required this.type,
    required this.target,
    this.destructive = false,
    this.details = const <String, dynamic>{},
  });

  final String type;
  final String target;
  final bool destructive;
  final Map<String, dynamic> details;

  bool matchesDetails(Map<String, dynamic> expectedDetails) {
    for (final entry in expectedDetails.entries) {
      if (!details.containsKey(entry.key) ||
          details[entry.key] != entry.value) {
        return false;
      }
    }
    return true;
  }

  Map<String, dynamic> toJson() => {
    'type': type,
    'target': target,
    'destructive': destructive,
    if (details.isNotEmpty) 'details': details,
  };
}

class StoragePlanException implements Exception {
  const StoragePlanException(this.message);

  final String message;

  @override
  String toString() => message;
}

class StoragePlanBuilder {
  const StoragePlanBuilder._();

  static StoragePlan fromState(Map<String, dynamic> state) {
    final mode = (state['partitionMethod'] ?? 'full').toString();
    final targetDisk = (state['selectedDisk'] ?? '').toString();
    final fileSystem = (state['fileSystem'] ?? 'btrfs').toString();
    if (targetDisk.isEmpty) {
      throw const StoragePlanException('Storage plan hedef diski bos olamaz.');
    }
    if (fileSystem != 'btrfs') {
      throw StoragePlanException(
        'Ro-ASD storage plan yalnızca Btrfs root destekler: $fileSystem',
      );
    }

    final operations = switch (mode) {
      'full' => _fullDiskOperations(targetDisk),
      'alongside' => _alongsideOperations(state, targetDisk),
      'free_space' => _freeSpaceOperations(state, targetDisk),
      'manual' => _manualOperations(state),
      _ => throw StoragePlanException('Bilinmeyen storage plan yöntemi: $mode'),
    };

    return StoragePlan(
      planId: _planId(mode, targetDisk),
      mode: mode,
      targetDisk: targetDisk,
      fileSystem: fileSystem,
      operations: List.unmodifiable(operations),
    );
  }

  static List<StoragePlanOperation> _fullDiskOperations(String targetDisk) => [
    StoragePlanOperation(
      type: 'wipe_disk',
      target: targetDisk,
      destructive: true,
    ),
    StoragePlanOperation(
      type: 'create_efi',
      target: targetDisk,
      destructive: true,
    ),
    StoragePlanOperation(
      type: 'create_swap',
      target: targetDisk,
      destructive: true,
    ),
    StoragePlanOperation(
      type: 'create_btrfs_root',
      target: targetDisk,
      destructive: true,
    ),
    StoragePlanOperation(
      type: 'format_efi',
      target: _partitionPath(targetDisk, 1),
      destructive: true,
    ),
    StoragePlanOperation(
      type: 'format_swap',
      target: _partitionPath(targetDisk, 2),
      destructive: true,
    ),
    StoragePlanOperation(
      type: 'format_btrfs_root',
      target: _partitionPath(targetDisk, 3),
      destructive: true,
    ),
  ];

  static List<StoragePlanOperation> _alongsideOperations(
    Map<String, dynamic> state,
    String targetDisk,
  ) {
    final existingEfi = (state['existingEfiPartition'] ?? '').toString();
    final operations = <StoragePlanOperation>[
      StoragePlanOperation(
        type: 'use_existing_efi',
        target: existingEfi.isEmpty ? '<pending-existing-efi>' : existingEfi,
      ),
    ];
    final shrinkCandidate = (state['shrinkCandidatePartition'] ?? '')
        .toString();
    if (shrinkCandidate.isNotEmpty) {
      operations.add(
        StoragePlanOperation(
          type: 'shrink_source_partition',
          target: shrinkCandidate,
          destructive: true,
          details: {'sourceFs': (state['shrinkCandidateFs'] ?? '').toString()},
        ),
      );
    }
    operations.addAll([
      StoragePlanOperation(
        type: 'create_swap',
        target: targetDisk,
        destructive: true,
      ),
      StoragePlanOperation(
        type: 'create_btrfs_root',
        target: targetDisk,
        destructive: true,
      ),
    ]);
    return operations;
  }

  static List<StoragePlanOperation> _freeSpaceOperations(
    Map<String, dynamic> state,
    String targetDisk,
  ) {
    final existingEfi = (state['existingEfiPartition'] ?? '').toString();
    final selectedFreeSpace = state['selectedFreeSpace'];
    final freeSpaceDetails = selectedFreeSpace is Map
        ? Map<String, dynamic>.from(selectedFreeSpace)
        : <String, dynamic>{};
    return [
      StoragePlanOperation(
        type: 'use_existing_efi',
        target: existingEfi.isEmpty ? '<pending-existing-efi>' : existingEfi,
      ),
      StoragePlanOperation(
        type: 'allocate_selected_free_space',
        target: targetDisk,
        destructive: true,
        details: freeSpaceDetails,
      ),
      StoragePlanOperation(
        type: 'create_swap',
        target: targetDisk,
        destructive: true,
      ),
      StoragePlanOperation(
        type: 'create_btrfs_root',
        target: targetDisk,
        destructive: true,
      ),
    ];
  }

  static List<StoragePlanOperation> _manualOperations(
    Map<String, dynamic> state,
  ) {
    final manualPartitions =
        state['manualPartitions'] as List<dynamic>? ?? const [];
    if (manualPartitions.isEmpty) {
      throw const StoragePlanException('Manuel storage plan boş olamaz.');
    }

    final operations = <StoragePlanOperation>[];
    for (final rawPart in manualPartitions) {
      if (rawPart is! Map<String, dynamic>) continue;
      final deletedNames = rawPart['deletedPartitionNames'];
      if (deletedNames is Iterable) {
        for (final deletedName in deletedNames) {
          final target = deletedName.toString();
          if (target.isNotEmpty) {
            operations.add(
              StoragePlanOperation(
                type: 'delete_partition',
                target: target,
                destructive: true,
              ),
            );
          }
        }
      }
      if (rawPart['isFreeSpace'] == true) continue;

      final name = (rawPart['name'] ?? '').toString();
      final mount = (rawPart['mount'] ?? 'unmounted').toString();
      final fsType = (rawPart['type'] ?? '').toString();
      final isNewPartition =
          name == 'New Partition' || name.startsWith('New Partition');
      final isResized = rawPart['isResized'] == true;
      final formatOnInstall = rawPart.containsKey('formatOnInstall')
          ? rawPart['formatOnInstall'] == true
          : rawPart['isPlanned'] == true;
      if (mount == '/boot/efi' && fsType != 'fat32' && fsType != 'vfat') {
        throw StoragePlanException('EFI bolumu FAT32 olmalidir: $name');
      }
      if (mount == '[SWAP]' && fsType != 'linux-swap' && fsType != 'swap') {
        throw StoragePlanException('Swap bolumu linux-swap olmalidir: $name');
      }
      if (mount != 'unmounted' &&
          mount != '/boot/efi' &&
          mount != '[SWAP]' &&
          fsType != 'btrfs') {
        throw StoragePlanException(
          'Mount edilen manuel bolumler Btrfs olmalidir: $name ($fsType)',
        );
      }
      final operationType = isNewPartition
          ? 'create_partition'
          : isResized
          ? 'resize_partition'
          : formatOnInstall
          ? 'format_partition'
          : 'keep';
      operations.add(
        StoragePlanOperation(
          type: operationType,
          target: name,
          destructive: operationType != 'keep',
          details: {
            'mount': mount,
            'fsType': fsType,
            'formatOnInstall': formatOnInstall,
            'isResized': isResized,
            if (rawPart['sizeBytes'] != null) 'sizeBytes': rawPart['sizeBytes'],
            if (rawPart['startSector'] != null)
              'startSector': rawPart['startSector'],
            if (rawPart['endSector'] != null) 'endSector': rawPart['endSector'],
          },
        ),
      );
    }
    return operations;
  }

  static String _planId(String mode, String targetDisk) {
    final safeDisk = targetDisk.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return '$mode-$safeDisk';
  }

  static String _partitionPath(String disk, int partitionNumber) {
    final needsP =
        disk.contains('nvme') ||
        disk.contains('loop') ||
        disk.contains('mmcblk');
    return needsP ? '${disk}p$partitionNumber' : '$disk$partitionNumber';
  }
}
