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
      'free_space' => throw const StoragePlanException(
        'Verified FreeSpaceInstallationPlan required.',
      ),
      'manual' => throw const StoragePlanException(
        'Verified ManualInstallationPlan required.',
      ),
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
      type: 'format_btrfs_root',
      target: _partitionPath(targetDisk, 2),
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
