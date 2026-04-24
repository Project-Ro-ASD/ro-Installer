import 'dart:convert';
import 'command_runner.dart';

class PartitionService {
  PartitionService({CommandRunner? commandRunner})
    : _commandRunner = commandRunner ?? CommandRunner.instance;

  /// Varsayılan singleton erişimi (geriye uyumluluk için)
  static final PartitionService instance = PartitionService();

  final CommandRunner _commandRunner;

  Future<List<Map<String, dynamic>>> getPartitions(String diskName) async {
    List<Map<String, dynamic>> partitionList = [];

    try {
      final result = await _commandRunner.run('lsblk', [
        '-J',
        '-b',
        '-o',
        'NAME,FSTYPE,SIZE,MOUNTPOINT,PARTFLAGS',
        diskName,
      ]);
      if (result.exitCode == 0) {
        final Map<String, dynamic> parsed = jsonDecode(result.stdout);
        if (parsed.containsKey('blockdevices')) {
          final devices = parsed['blockdevices'] as List<dynamic>;
          if (devices.isNotEmpty) {
            final diskSize = devices.first['size'] is int
                ? devices.first['size'] as int
                : int.tryParse(devices.first['size'].toString()) ?? 0;
            int usedSpace = 0;

            if (devices.first.containsKey('children')) {
              final children = devices.first['children'] as List<dynamic>;
              for (var child in children) {
                final int sizeBytes = child['size'] is int
                    ? child['size'] as int
                    : int.tryParse(child['size'].toString()) ?? 0;
                usedSpace += sizeBytes;

                String currentMount = 'unmounted';
                if (child.containsKey('mountpoints') &&
                    child['mountpoints'] != null) {
                  final mpList = child['mountpoints'] as List<dynamic>;
                  final normalizedMounts = mpList
                      .whereType<String>()
                      .where((value) => value.trim().isNotEmpty)
                      .toList();
                  if (normalizedMounts.isNotEmpty) {
                    currentMount = normalizedMounts.join(', ');
                  }
                } else if (child.containsKey('mountpoint') &&
                    child['mountpoint'] != null) {
                  final mountpoint = child['mountpoint'].toString().trim();
                  if (mountpoint.isNotEmpty) {
                    currentMount = mountpoint;
                  }
                }

                partitionList.add({
                  'name': '/dev/${child['name']}',
                  'type': _normalizeFsType(
                    (child['fstype'] ?? 'unknown').toString(),
                  ),
                  'sizeBytes': sizeBytes,
                  'mount': 'unmounted',
                  'currentMount': currentMount,
                  'flags': child['partflags'] ?? '',
                  'isPlanned': false,
                  'formatOnInstall': false,
                  'isFreeSpace': false,
                });
              }
            }

            // Geriye kalan disk alanı varsa (10 MB tolerans) sona Free Space ekle
            int freeBytes = diskSize - usedSpace;
            if (freeBytes > 10 * 1024 * 1024) {
              partitionList.add({
                'name': 'Free Space',
                'type': 'unallocated',
                'sizeBytes': freeBytes,
                'mount': 'unmounted',
                'currentMount': 'unmounted',
                'flags': '',
                'isPlanned': false,
                'formatOnInstall': false,
                'isFreeSpace': true,
              });
            }

            // Eğer hiç children yoksa (Ham disk) hepsini boş alan yap
            if (partitionList.isEmpty && diskSize > 0) {
              partitionList.add({
                'name': 'Free Space',
                'type': 'unallocated',
                'sizeBytes': diskSize,
                'mount': 'unmounted',
                'currentMount': 'unmounted',
                'flags': '',
                'isPlanned': false,
                'formatOnInstall': false,
                'isFreeSpace': true,
              });
            }
          }
        }
      }
    } catch (e) {
      // Hata durumu
    }

    return partitionList;
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
