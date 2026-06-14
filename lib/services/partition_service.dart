import 'dart:convert';
import 'command_runner.dart';

class PartitionService {
  PartitionService({CommandRunner? commandRunner})
    : _commandRunner = commandRunner ?? CommandRunner.instance;

  /// Varsayılan singleton erişimi (geriye uyumluluk için)
  static final PartitionService instance = PartitionService();

  static const int _minimumFreeSpaceBytes = 10 * 1024 * 1024;

  final CommandRunner _commandRunner;

  Future<List<Map<String, dynamic>>> getPartitions(String diskName) async {
    final partitionList = <Map<String, dynamic>>[];

    try {
      final sectorSize = await _readSectorSize(diskName);
      final result = await _commandRunner.run('lsblk', [
        '-J',
        '-b',
        '-o',
        'NAME,FSTYPE,SIZE,START,MOUNTPOINTS,MOUNTPOINT,PARTFLAGS,TYPE,PTTYPE',
        diskName,
      ]);
      if (result.exitCode == 0) {
        final parsed = jsonDecode(result.stdout) as Map<String, dynamic>;
        if (parsed.containsKey('blockdevices')) {
          final devices = parsed['blockdevices'] as List<dynamic>;
          if (devices.isNotEmpty) {
            final disk = devices.first as Map<String, dynamic>;
            final diskSize = disk['size'] is int
                ? disk['size'] as int
                : int.tryParse(disk['size'].toString()) ?? 0;
            final partitionTable = (disk['pttype'] ?? 'unknown')
                .toString()
                .toLowerCase();
            final parsedPartitions = <Map<String, dynamic>>[];

            if (disk.containsKey('children')) {
              final children = disk['children'] as List<dynamic>;
              for (final rawChild in children) {
                final child = rawChild as Map<String, dynamic>;
                if ((child['type'] ?? 'part').toString() != 'part') {
                  continue;
                }

                final sizeBytes = child['size'] is int
                    ? child['size'] as int
                    : int.tryParse(child['size'].toString()) ?? 0;
                final startSector = child['start'] is int
                    ? child['start'] as int
                    : int.tryParse((child['start'] ?? '').toString());
                final sectorCount = sectorSize > 0
                    ? ((sizeBytes + sectorSize - 1) ~/ sectorSize)
                    : 0;
                final endSector = startSector != null && sectorCount > 0
                    ? startSector + sectorCount - 1
                    : null;

                final partitionEntry = <String, dynamic>{
                  'name': '/dev/${child['name']}',
                  'type': _normalizeFsType(
                    (child['fstype'] ?? 'unknown').toString(),
                  ),
                  'sizeBytes': sizeBytes,
                  'mount': 'unmounted',
                  'currentMount': _currentMount(child),
                  'flags': child['partflags'] ?? '',
                  'isPlanned': false,
                  'formatOnInstall': false,
                  'isFreeSpace': false,
                };
                if (startSector != null) {
                  partitionEntry['startSector'] = startSector;
                }
                if (endSector != null) {
                  partitionEntry['endSector'] = endSector;
                }
                if (sectorSize > 0) {
                  partitionEntry['sectorSize'] = sectorSize;
                }
                parsedPartitions.add(partitionEntry);
              }
            }

            parsedPartitions.sort((left, right) {
              final leftStart = left['startSector'] as int?;
              final rightStart = right['startSector'] as int?;
              if (leftStart == null && rightStart == null) {
                return 0;
              }
              if (leftStart == null) {
                return 1;
              }
              if (rightStart == null) {
                return -1;
              }
              return leftStart.compareTo(rightStart);
            });

            final hasCompleteGeometry = parsedPartitions.every(
              (partition) =>
                  partition['startSector'] is int &&
                  partition['endSector'] is int,
            );

            if (sectorSize > 0 && diskSize > 0 && hasCompleteGeometry) {
              final totalSectors = diskSize ~/ sectorSize;
              final firstUsable = partitionTable == 'gpt' ? 34 : 0;
              final lastUsable = partitionTable == 'gpt'
                  ? totalSectors - 34
                  : totalSectors - 1;
              var cursor = firstUsable;

              for (final partition in parsedPartitions) {
                final start = partition['startSector'] as int?;
                final end = partition['endSector'] as int?;
                if (start != null && end != null) {
                  _appendFreeSpace(
                    partitionList,
                    startSector: cursor,
                    endSector: start - 1,
                    sectorSize: sectorSize,
                  );
                  partitionList.add(partition);
                  if (end + 1 > cursor) {
                    cursor = end + 1;
                  }
                } else {
                  partitionList.add(partition);
                }
              }

              _appendFreeSpace(
                partitionList,
                startSector: cursor,
                endSector: lastUsable,
                sectorSize: sectorSize,
              );
            } else {
              partitionList.addAll(parsedPartitions);

              final usedSpace = parsedPartitions.fold<int>(
                0,
                (sum, partition) => sum + (partition['sizeBytes'] as int),
              );
              final freeBytes = diskSize - usedSpace;
              if (freeBytes > _minimumFreeSpaceBytes) {
                partitionList.add(_freeSpaceEntry(sizeBytes: freeBytes));
              }
            }

            // Eğer hiç children yoksa (Ham disk) hepsini boş alan yap
            if (partitionList.isEmpty && diskSize > 0) {
              partitionList.add(
                _freeSpaceEntry(
                  sizeBytes: diskSize,
                  startSector: sectorSize > 0 ? 0 : null,
                  endSector: sectorSize > 0
                      ? (diskSize ~/ sectorSize) - 1
                      : null,
                  sectorSize: sectorSize,
                ),
              );
            }
          }
        }
      }
    } catch (e) {
      // Hata durumu
    }

    return partitionList;
  }

  Future<int> _readSectorSize(String device) async {
    final result = await _commandRunner.run('blockdev', ['--getss', device]);
    if (result.exitCode != 0) {
      return 512;
    }
    return int.tryParse(result.stdout.trim()) ?? 512;
  }

  void _appendFreeSpace(
    List<Map<String, dynamic>> partitionList, {
    required int startSector,
    required int endSector,
    required int sectorSize,
  }) {
    if (endSector < startSector || sectorSize <= 0) {
      return;
    }
    final freeBytes = (endSector - startSector + 1) * sectorSize;
    if (freeBytes <= _minimumFreeSpaceBytes) {
      return;
    }
    partitionList.add(
      _freeSpaceEntry(
        sizeBytes: freeBytes,
        startSector: startSector,
        endSector: endSector,
        sectorSize: sectorSize,
      ),
    );
  }

  Map<String, dynamic> _freeSpaceEntry({
    required int sizeBytes,
    int? startSector,
    int? endSector,
    int? sectorSize,
  }) {
    final entry = <String, dynamic>{
      'name': 'Free Space',
      'type': 'unallocated',
      'sizeBytes': sizeBytes,
      'mount': 'unmounted',
      'currentMount': 'unmounted',
      'flags': '',
      'isPlanned': false,
      'formatOnInstall': false,
      'isFreeSpace': true,
    };
    if (startSector != null) {
      entry['startSector'] = startSector;
    }
    if (endSector != null) {
      entry['endSector'] = endSector;
    }
    if (sectorSize != null && sectorSize > 0) {
      entry['sectorSize'] = sectorSize;
    }
    return entry;
  }

  String _currentMount(Map<String, dynamic> child) {
    if (child.containsKey('mountpoints') && child['mountpoints'] != null) {
      final mpList = child['mountpoints'] as List<dynamic>;
      final normalizedMounts = mpList
          .whereType<String>()
          .where((value) => value.trim().isNotEmpty)
          .toList();
      if (normalizedMounts.isNotEmpty) {
        return normalizedMounts.join(', ');
      }
    } else if (child.containsKey('mountpoint') && child['mountpoint'] != null) {
      final mountpoint = child['mountpoint'].toString().trim();
      if (mountpoint.isNotEmpty) {
        return mountpoint;
      }
    }
    return 'unmounted';
  }

  String _normalizeFsType(String fsType) {
    switch (fsType) {
      case 'vfat':
        return 'fat32';
      case 'swap':
        return 'linux-swap';
      default:
        return fsType;
    }
  }
}
