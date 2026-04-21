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
      final result = await _commandRunner.run('lsblk', ['-J', '-b', '-o', 'NAME,FSTYPE,SIZE,MOUNTPOINT,PARTFLAGS', diskName]);
      if (result.exitCode == 0) {
        final Map<String, dynamic> parsed = jsonDecode(result.stdout);
        if (parsed.containsKey('blockdevices')) {
          final devices = parsed['blockdevices'] as List<dynamic>;
          if (devices.isNotEmpty) {
             final diskSize = devices.first['size'] is int ? devices.first['size'] as int : int.tryParse(devices.first['size'].toString()) ?? 0;
             int usedSpace = 0;

             if (devices.first.containsKey('children')) {
                 final children = devices.first['children'] as List<dynamic>;
                 for (var child in children) {
                    final int sizeBytes = child['size'] is int ? child['size'] as int : int.tryParse(child['size'].toString()) ?? 0;
                    usedSpace += sizeBytes;
                    
                    String mountPointStr = "";
                    if (child.containsKey('mountpoints') && child['mountpoints'] != null) {
                       final mpList = child['mountpoints'] as List<dynamic>;
                       if (mpList.isNotEmpty && mpList.first != null) {
                          mountPointStr = mpList.join(', ');
                       }
                    } else if (child.containsKey('mountpoint') && child['mountpoint'] != null) {
                       mountPointStr = child['mountpoint'].toString();
                    }
                    
                    partitionList.add({
                      'name': '/dev/${child['name']}',
                      'type': child['fstype'] ?? 'unknown',
                      'sizeBytes': sizeBytes,
                      'mount': mountPointStr.isEmpty ? 'unmounted' : mountPointStr,
                      'flags': child['partflags'] ?? '',
                      'isPlanned': false,
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
                    'flags': '',
                    'isPlanned': false,
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
                    'flags': '',
                    'isPlanned': false,
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
}
