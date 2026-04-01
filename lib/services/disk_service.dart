import 'dart:convert';
import 'command_runner.dart';

class DiskService {
  DiskService._();
  static final DiskService instance = DiskService._();
  final CommandRunner _commandRunner = CommandRunner.instance;

  // EFI System Partition GPT Type UUID (Standart)
  static const String _efiPartTypeUUID = 'c12a7328-f81f-11d2-ba4b-00a0c93ec93b';

  Future<List<Map<String, dynamic>>> getDisks() async {
    List<Map<String, dynamic>> diskList = [];

    try {
      final result = await _commandRunner.run('lsblk', ['-J', '-b', '-o', 'NAME,MODEL,SIZE,TYPE,RM,MOUNTPOINTS']);
      if (result.exitCode == 0) {
        final Map<String, dynamic> parsed = jsonDecode(result.stdout);
        if (parsed.containsKey('blockdevices')) {
          final devices = parsed['blockdevices'] as List<dynamic>;
          
          for (var d in devices) {
            if (d['type'] != 'disk') continue;
            final name = d['name'].toString();
            if (name.startsWith('zram') || name.startsWith('loop') || name.startsWith('sr')) continue;

            bool isLive = false;
            if (d['rm'] == true) {
              isLive = true; 
            }

            bool hasCriticalMount = false;
            bool isHostOS = false;
            if (d.containsKey('children')) {
               for (var child in (d['children'] as List<dynamic>)) {
                  if (child.containsKey('mountpoints') && child['mountpoints'] != null) {
                     for (var mp in (child['mountpoints'] as List<dynamic>)) {
                        if (mp.toString().contains('/run/initramfs') || mp.toString().contains('/live')) {
                           hasCriticalMount = true;
                           isLive = true;
                        }
                        if (mp == '/' || mp == '/boot') {
                           isHostOS = true;
                        }
                     }
                  }
               }
            }
            
            diskList.add({
              'name': '/dev/$name',
              'model': d['model'] ?? 'Unknown Drive',
              'size': d['size'] ?? 0,
              'type': d['type'] ?? 'disk',
              'isLive': isLive || hasCriticalMount,
              'isHostOS': isHostOS,
              'isSafe': false,
            });
          }
        }
      }
    } catch (e) {
      // Komut başarısız olursa boş liste döner
    }

    return diskList;
  }

  /// Seçilen disk hakkında detaylı bilgi toplar:
  /// - Diskte mevcut bir işletim sistemi var mı? (Windows/Linux)
  /// - Mevcut bir EFI System Partition (ESP) var mı?
  /// - Diskte ne kadar boş (unallocated) alan var?
  Future<Map<String, dynamic>> detectDiskDetails(String diskName) async {
    bool hasExistingOS = false;
    String detectedOS = '';
    bool hasEfiPartition = false;
    String efiPartitionName = '';
    int freeSpaceBytes = 0;
    int totalUsedBytes = 0;
    int totalDiskBytes = 0;

    try {
      // === ADIM 1: lsblk ile bölüm bilgilerini al ===
      final lsblkResult = await _commandRunner.run('lsblk', [
        '-J', '-b', '-o', 'NAME,FSTYPE,SIZE,PARTTYPE,MOUNTPOINTS', diskName
      ]);

      if (lsblkResult.exitCode == 0) {
        final Map<String, dynamic> parsed = jsonDecode(lsblkResult.stdout);
        if (parsed.containsKey('blockdevices')) {
          final devices = parsed['blockdevices'] as List<dynamic>;
          if (devices.isNotEmpty) {
            final disk = devices.first;
            totalDiskBytes = disk['size'] is int
                ? disk['size'] as int
                : int.tryParse(disk['size'].toString()) ?? 0;

            if (disk.containsKey('children')) {
              final children = disk['children'] as List<dynamic>;
              
              bool foundNtfs = false;
              bool foundLinuxFs = false;

              for (var child in children) {
                final int partSize = child['size'] is int
                    ? child['size'] as int
                    : int.tryParse(child['size'].toString()) ?? 0;
                totalUsedBytes += partSize;

                final String fsType = (child['fstype'] ?? '').toString().toLowerCase();
                final String partType = (child['parttype'] ?? '').toString().toLowerCase();
                final String childName = child['name'].toString();

                // NTFS algılama → Windows
                if (fsType == 'ntfs') {
                  foundNtfs = true;
                }

                // Linux dosya sistemi algılama
                if (['ext4', 'btrfs', 'xfs', 'ext3'].contains(fsType)) {
                  // Sadece Live ortamda mount edilmemiş olanları say (aksi halde Live USB'nin kendi bölümünü yakalar)
                  bool isMountedAsLive = false;
                  if (child.containsKey('mountpoints') && child['mountpoints'] != null) {
                    for (var mp in (child['mountpoints'] as List<dynamic>)) {
                      if (mp != null && (mp.toString().contains('/run/initramfs') || mp.toString().contains('/live'))) {
                        isMountedAsLive = true;
                      }
                    }
                  }
                  if (!isMountedAsLive) {
                    foundLinuxFs = true;
                  }
                }

                // EFI System Partition algılama (GPT Type UUID ile)
                if (partType == _efiPartTypeUUID || fsType == 'vfat') {
                  // vfat tek başına yeterli değil, parttype ile teyit edilmeli
                  if (partType == _efiPartTypeUUID) {
                    hasEfiPartition = true;
                    efiPartitionName = '/dev/$childName';
                  }
                }
              }

              // OS kararını ver
              if (foundNtfs && hasEfiPartition) {
                hasExistingOS = true;
                detectedOS = 'Windows';
              } else if (foundNtfs) {
                hasExistingOS = true;
                detectedOS = 'Windows';
              } else if (foundLinuxFs) {
                hasExistingOS = true;
                detectedOS = 'Linux';
              }
            }
          }
        }
      }

      // === ADIM 2: Boş alan hesaplaması ===
      // sgdisk ile daha doğru sonuç alınır
      final sgdiskResult = await _commandRunner.run('sgdisk', ['-p', diskName]);
      if (sgdiskResult.exitCode == 0) {
        // sgdisk çıktısından "Total free space" satırını ara
        // Alternatif olarak lsblk'den basit hesaplama kullanılabilir
        freeSpaceBytes = totalDiskBytes - totalUsedBytes;
        if (freeSpaceBytes < 0) freeSpaceBytes = 0;
      } else {
        // sgdisk başarısız olursa lsblk verilerini kullan
        freeSpaceBytes = totalDiskBytes - totalUsedBytes;
        if (freeSpaceBytes < 0) freeSpaceBytes = 0;
      }

    } catch (e) {
      // Hata durumunda güvenli varsayılanlar
      freeSpaceBytes = 0;
    }

    return {
      'hasExistingOS': hasExistingOS,
      'detectedOS': detectedOS,
      'hasEfiPartition': hasEfiPartition,
      'efiPartitionName': efiPartitionName,
      'freeSpaceBytes': freeSpaceBytes,
    };
  }
}
