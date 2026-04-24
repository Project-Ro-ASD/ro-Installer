import 'dart:convert';
import 'command_runner.dart';

class DiskService {
  DiskService({CommandRunner? commandRunner})
    : _commandRunner = commandRunner ?? CommandRunner.instance;

  /// Varsayılan singleton erişimi (geriye uyumluluk için)
  static final DiskService instance = DiskService();

  final CommandRunner _commandRunner;

  // EFI System Partition GPT Type UUID (Standart)
  static const String _efiPartTypeUUID = 'c12a7328-f81f-11d2-ba4b-00a0c93ec93b';
  static const List<String> _supportedShrinkFs = ['ntfs', 'ext4'];
  static const int _minAlongsideLinuxBytes = 40 * 1024 * 1024 * 1024;
  static const int _minSourcePartitionBytes = 40 * 1024 * 1024 * 1024;

  Future<List<Map<String, dynamic>>> getDisks() async {
    List<Map<String, dynamic>> diskList = [];

    try {
      final result = await _commandRunner.run('lsblk', [
        '-J',
        '-b',
        '-o',
        'NAME,MODEL,SIZE,TYPE,RM,MOUNTPOINTS',
      ]);
      if (result.exitCode == 0) {
        final Map<String, dynamic> parsed = jsonDecode(result.stdout);
        if (parsed.containsKey('blockdevices')) {
          final devices = parsed['blockdevices'] as List<dynamic>;

          for (var d in devices) {
            if (d['type'] != 'disk') continue;
            final name = d['name'].toString();
            if (name.startsWith('zram') ||
                name.startsWith('loop') ||
                name.startsWith('sr')) {
              continue;
            }

            bool isLive = false;
            if (d['rm'] == true) {
              isLive = true;
            }

            bool hasCriticalMount = false;
            bool isHostOS = false;
            if (d.containsKey('children')) {
              for (var child in (d['children'] as List<dynamic>)) {
                if (child.containsKey('mountpoints') &&
                    child['mountpoints'] != null) {
                  for (var mp in (child['mountpoints'] as List<dynamic>)) {
                    if (mp.toString().contains('/run/initramfs') ||
                        mp.toString().contains('/live')) {
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
    int sectorSize = 512;
    int largestFreeContiguousBytes = 0;
    int alongsideMaxLinuxBytes = 0;
    String bootMode = 'unknown';
    String partitionTable = 'unknown';
    String shrinkCandidatePartition = '';
    String shrinkCandidateFs = '';
    int shrinkCandidateSizeBytes = 0;
    int gapAfterShrinkCandidateBytes = 0;
    bool bitlockerDetected = false;
    final alongsideBlockers = <String>[];
    final partitions = <Map<String, dynamic>>[];

    try {
      bootMode = await _detectBootMode();

      // === ADIM 1: lsblk ile bölüm bilgilerini al ===
      final lsblkResult = await _commandRunner.run('lsblk', [
        '-J',
        '-b',
        '-o',
        'NAME,FSTYPE,SIZE,START,PARTTYPE,PTTYPE,MOUNTPOINTS',
        diskName,
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
            sectorSize = await _readSectorSize(diskName);
            partitionTable = (disk['pttype'] ?? 'unknown')
                .toString()
                .toLowerCase();

            if (disk.containsKey('children')) {
              final children = disk['children'] as List<dynamic>;

              bool foundNtfs = false;
              bool foundLinuxFs = false;

              for (var child in children) {
                final int partSize = child['size'] is int
                    ? child['size'] as int
                    : int.tryParse(child['size'].toString()) ?? 0;
                totalUsedBytes += partSize;

                final String fsType = (child['fstype'] ?? '')
                    .toString()
                    .toLowerCase();
                final String partType = (child['parttype'] ?? '')
                    .toString()
                    .toLowerCase();
                final String childName = child['name'].toString();
                final partPath = '/dev/$childName';
                final startSector = child['start'] is int
                    ? child['start'] as int
                    : int.tryParse((child['start'] ?? '').toString());
                final sectorCount = sectorSize > 0
                    ? ((partSize + sectorSize - 1) ~/ sectorSize)
                    : 0;
                final endSector = (startSector != null && sectorCount > 0)
                    ? startSector + sectorCount - 1
                    : null;
                final blkidType = await _readBlkidType(partPath);
                final normalizedFs = blkidType.isNotEmpty ? blkidType : fsType;
                if (normalizedFs == 'bitlocker') {
                  bitlockerDetected = true;
                }

                // NTFS algılama → Windows
                if (normalizedFs == 'ntfs') {
                  foundNtfs = true;
                }

                // Linux dosya sistemi algılama
                if (['ext4', 'btrfs', 'xfs', 'ext3'].contains(normalizedFs)) {
                  // Sadece Live ortamda mount edilmemiş olanları say (aksi halde Live USB'nin kendi bölümünü yakalar)
                  bool isMountedAsLive = false;
                  if (child.containsKey('mountpoints') &&
                      child['mountpoints'] != null) {
                    for (var mp in (child['mountpoints'] as List<dynamic>)) {
                      if (mp != null &&
                          (mp.toString().contains('/run/initramfs') ||
                              mp.toString().contains('/live'))) {
                        isMountedAsLive = true;
                      }
                    }
                  }
                  if (!isMountedAsLive) {
                    foundLinuxFs = true;
                  }
                }

                // EFI System Partition algılama (GPT Type UUID ile)
                if (partType == _efiPartTypeUUID || normalizedFs == 'vfat') {
                  // vfat tek başına yeterli değil, parttype ile teyit edilmeli
                  if (partType == _efiPartTypeUUID) {
                    hasEfiPartition = true;
                    efiPartitionName = partPath;
                  }
                }

                partitions.add({
                  'path': partPath,
                  'fsType': normalizedFs,
                  'partType': partType,
                  'sizeBytes': partSize,
                  'isEfi': partType == _efiPartTypeUUID,
                  'startSector': startSector,
                  'endSector': endSector,
                });
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

    final shrinkCandidate = _pickShrinkCandidate(partitions, detectedOS);
    String? shrinkSafetyIssue;
    bool canShrinkCandidateBeUsed = false;
    if (shrinkCandidate != null) {
      shrinkCandidatePartition = shrinkCandidate['path'] as String;
      shrinkCandidateFs = shrinkCandidate['fsType'] as String;
      shrinkCandidateSizeBytes = shrinkCandidate['sizeBytes'] as int;
      final candidateType = shrinkCandidate['fsType'] as String;
      final candidatePath = shrinkCandidate['path'] as String;

      if (candidateType == 'bitlocker') {
        shrinkSafetyIssue = 'bitlocker_enabled';
      } else if (candidateType == 'ntfs') {
        shrinkSafetyIssue = await _checkNtfsSafety(candidatePath);
      } else if (candidateType == 'ext4') {
        if (!await _hasCommand('resize2fs')) {
          shrinkSafetyIssue = 'ext4_resize_tool_missing';
        } else if (!await _hasCommand('e2fsck')) {
          shrinkSafetyIssue = 'ext4_check_tool_missing';
        }
      }

      if (shrinkSafetyIssue == null) {
        canShrinkCandidateBeUsed = true;
      }
    }

    largestFreeContiguousBytes = _computeLargestFreeContiguousBytes(
      partitions,
      totalDiskBytes,
      sectorSize,
      partitionTable,
    );
    if (shrinkCandidate != null && canShrinkCandidateBeUsed) {
      gapAfterShrinkCandidateBytes = _computeGapAfterCandidateBytes(
        partitions,
        shrinkCandidate['path'] as String,
        totalDiskBytes,
        sectorSize,
        partitionTable,
      );
      final shrinkableBytes =
          (shrinkCandidate['sizeBytes'] as int) - _minSourcePartitionBytes;
      alongsideMaxLinuxBytes =
          gapAfterShrinkCandidateBytes +
          (shrinkableBytes > 0 ? shrinkableBytes : 0);
    }
    if (largestFreeContiguousBytes > alongsideMaxLinuxBytes) {
      alongsideMaxLinuxBytes = largestFreeContiguousBytes;
    }

    if (bootMode != 'uefi') {
      alongsideBlockers.add('boot_mode_not_uefi');
    }
    if (partitionTable != 'gpt') {
      alongsideBlockers.add('partition_table_not_gpt');
    }
    if (!hasExistingOS) {
      alongsideBlockers.add('no_existing_os');
    }
    if (!hasEfiPartition) {
      alongsideBlockers.add('missing_efi');
    }
    if (bitlockerDetected) {
      alongsideBlockers.add('bitlocker_enabled');
    }
    if (alongsideMaxLinuxBytes < _minAlongsideLinuxBytes) {
      if (shrinkCandidate == null &&
          largestFreeContiguousBytes < _minAlongsideLinuxBytes) {
        alongsideBlockers.add('no_shrink_candidate');
      }
      if (shrinkSafetyIssue != null) {
        alongsideBlockers.add(shrinkSafetyIssue);
      } else {
        alongsideBlockers.add('alongside_minimum_not_met');
      }
    }

    return {
      'hasExistingOS': hasExistingOS,
      'detectedOS': detectedOS,
      'hasEfiPartition': hasEfiPartition,
      'efiPartitionName': efiPartitionName,
      'freeSpaceBytes': freeSpaceBytes,
      'largestFreeContiguousBytes': largestFreeContiguousBytes,
      'bootMode': bootMode,
      'partitionTable': partitionTable,
      'shrinkCandidatePartition': shrinkCandidatePartition,
      'shrinkCandidateFs': shrinkCandidateFs,
      'shrinkCandidateSizeBytes': shrinkCandidateSizeBytes,
      'alongsideMaxLinuxSizeBytes': alongsideMaxLinuxBytes,
      'alongsideBlockers': alongsideBlockers,
    };
  }

  Future<String> _detectBootMode() async {
    final result = await _commandRunner.run('test', [
      '-d',
      '/sys/firmware/efi',
    ]);
    return result.exitCode == 0 ? 'uefi' : 'bios';
  }

  Future<bool> _hasCommand(String command) async {
    final result = await _commandRunner.run('sh', [
      '-c',
      'command -v $command >/dev/null 2>&1',
    ]);
    return result.started && result.exitCode == 0;
  }

  Future<String> _readBlkidType(String device) async {
    final result = await _commandRunner.run('blkid', [
      '-s',
      'TYPE',
      '-o',
      'value',
      device,
    ]);
    if (result.exitCode != 0) {
      return '';
    }
    return result.stdout.trim().toLowerCase();
  }

  Future<int> _readSectorSize(String device) async {
    final result = await _commandRunner.run('blockdev', ['--getss', device]);
    if (result.exitCode != 0) {
      return 512;
    }
    return int.tryParse(result.stdout.trim()) ?? 512;
  }

  Map<String, dynamic>? _pickShrinkCandidate(
    List<Map<String, dynamic>> partitions,
    String detectedOS,
  ) {
    if (partitions.isEmpty) {
      return null;
    }

    final candidates =
        partitions
            .where(
              (part) =>
                  _supportedShrinkFs.contains(part['fsType']) &&
                  part['isEfi'] != true,
            )
            .toList()
          ..sort(
            (a, b) => ((b['sizeBytes'] as int?) ?? 0).compareTo(
              (a['sizeBytes'] as int?) ?? 0,
            ),
          );

    if (candidates.isEmpty) {
      return null;
    }

    if (detectedOS == 'Windows') {
      return candidates.cast<Map<String, dynamic>>().firstWhere(
        (part) => part['fsType'] == 'ntfs',
        orElse: () => candidates.first,
      );
    }

    if (detectedOS == 'Linux') {
      return candidates.cast<Map<String, dynamic>>().firstWhere(
        (part) => part['fsType'] == 'ext4',
        orElse: () => candidates.first,
      );
    }

    return candidates.first;
  }

  Future<String?> _checkNtfsSafety(String device) async {
    if (!await _hasCommand('ntfsresize')) {
      return 'ntfs_resize_tool_missing';
    }

    final result = await _commandRunner.run('ntfsresize', [
      '--info',
      '--force',
      device,
    ]);
    final text = '${result.stdout}\n${result.stderr}'.toLowerCase();

    if (text.contains('bitlocker')) {
      return 'bitlocker_enabled';
    }
    if (text.contains('hibernat') ||
        text.contains('fast restart') ||
        text.contains('fast startup') ||
        text.contains('resume and shutdown windows fully')) {
      return 'ntfs_hibernated_or_fast_startup';
    }
    if (text.contains('dirty') ||
        text.contains('inconsistent') ||
        text.contains('chkdsk')) {
      return 'ntfs_dirty';
    }
    if (result.exitCode != 0) {
      return 'ntfs_check_failed';
    }
    return null;
  }

  int _computeLargestFreeContiguousBytes(
    List<Map<String, dynamic>> partitions,
    int totalDiskBytes,
    int sectorSize,
    String partitionTable,
  ) {
    if (sectorSize <= 0 || totalDiskBytes <= 0) {
      return 0;
    }

    final sorted =
        partitions
            .where(
              (part) => part['startSector'] is int && part['endSector'] is int,
            )
            .cast<Map<String, dynamic>>()
            .toList()
          ..sort(
            (a, b) =>
                (a['startSector'] as int).compareTo(b['startSector'] as int),
          );

    final totalSectors = totalDiskBytes ~/ sectorSize;
    if (totalSectors <= 0) {
      return 0;
    }

    final firstUsable = partitionTable == 'gpt' ? 34 : 0;
    final lastUsable = partitionTable == 'gpt'
        ? totalSectors - 34
        : totalSectors - 1;
    if (lastUsable <= firstUsable) {
      return 0;
    }

    var cursor = firstUsable;
    var largest = 0;
    for (final part in sorted) {
      final start = part['startSector'] as int;
      final end = part['endSector'] as int;
      if (start > cursor) {
        final freeSectors = start - cursor;
        if (freeSectors > largest) {
          largest = freeSectors;
        }
      }
      if (end + 1 > cursor) {
        cursor = end + 1;
      }
    }

    if (lastUsable >= cursor) {
      final tailFree = lastUsable - cursor + 1;
      if (tailFree > largest) {
        largest = tailFree;
      }
    }

    return largest * sectorSize;
  }

  int _computeGapAfterCandidateBytes(
    List<Map<String, dynamic>> partitions,
    String candidatePath,
    int totalDiskBytes,
    int sectorSize,
    String partitionTable,
  ) {
    if (sectorSize <= 0 || totalDiskBytes <= 0) {
      return 0;
    }

    final sorted =
        partitions
            .where(
              (part) => part['startSector'] is int && part['endSector'] is int,
            )
            .cast<Map<String, dynamic>>()
            .toList()
          ..sort(
            (a, b) =>
                (a['startSector'] as int).compareTo(b['startSector'] as int),
          );

    if (sorted.isEmpty) {
      return 0;
    }

    final index = sorted.indexWhere((part) => part['path'] == candidatePath);
    if (index == -1) {
      return 0;
    }

    final totalSectors = totalDiskBytes ~/ sectorSize;
    final lastUsable = partitionTable == 'gpt'
        ? totalSectors - 34
        : totalSectors - 1;
    final candidateEnd = sorted[index]['endSector'] as int;
    final nextStart = index < sorted.length - 1
        ? sorted[index + 1]['startSector'] as int
        : lastUsable + 1;
    final gapSectors = nextStart - candidateEnd - 1;
    if (gapSectors <= 0) {
      return 0;
    }
    return gapSectors * sectorSize;
  }
}
