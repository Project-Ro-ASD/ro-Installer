import 'dart:convert';

import '../../utils/manual_partition_sizing.dart';
import 'stage_context.dart';
import 'stage_result.dart';

/// AŞAMA 2: Bölümleme (Partitioning)
///
/// Seçilen yönteme göre disk bölümlerini oluşturur:
/// - 'full': Tüm diski silip EFI + Root oluşturur
/// - 'alongside': Mevcut sisteme zarar vermeden yanına SWAP + Root oluşturur
/// - 'manual': Kullanıcının UI'da belirlediği planı uygular (format işlemi bir sonraki aşamada)
///
/// Bu aşama sadece bölüm tablolarını oluşturur, biçimlendirme yapmaz.
class PartitioningStage {
  const PartitioningStage();

  static const int _minAlongsideLinuxBytes = 40 * 1024 * 1024 * 1024;
  static const int _minSourcePartitionBytes = 40 * 1024 * 1024 * 1024;
  static const int _filesystemSafetyMarginBytes = 64 * 1024 * 1024;
  static const int _gptFirstUsableSector = 34;

  Future<bool> _hasCommand(StageContext ctx, String command) async {
    if (ctx.isMock) {
      return true;
    }

    final result = await ctx.commandRunner.run('sh', [
      '-c',
      'command -v $command >/dev/null 2>&1',
    ]);
    return result.started && result.exitCode == 0;
  }

  Future<StageResult> execute(StageContext ctx) async {
    final selectedDisk = ctx.state['selectedDisk'] as String;
    final partitionMethod = ctx.state['partitionMethod'] as String;

    ctx.log('════════════════════════════════════════════');
    ctx.log(
      '[AŞAMA 2] Bölümleme Başlatılıyor: $selectedDisk (Yöntem: $partitionMethod)',
    );
    ctx.log('════════════════════════════════════════════');

    switch (partitionMethod) {
      case 'full':
        return _fullDiskPartition(ctx, selectedDisk);
      case 'alongside':
        return _alongsidePartition(ctx, selectedDisk);
      case 'manual':
        return _manualPartition(ctx, selectedDisk);
      default:
        return StageResult.fail(
          'Bilinmeyen bölümleme yöntemi: $partitionMethod',
        );
    }
  }

  /// Tüm diski silip yeniden bölümlendirir: EFI (512MB) + Root (kalan)
  Future<StageResult> _fullDiskPartition(
    StageContext ctx,
    String selectedDisk,
  ) async {
    ctx.progress(
      0.05,
      'stage_progress_partition_reset_disk',
      'Disk sıfırlanıyor ve bağlantılar kesiliyor...',
    );

    // Wipefs ile disk imzalarını temizle
    await ctx.runCmd(
      'wipefs',
      ['-a', selectedDisk],
      ctx.log,
      isMock: ctx.isMock,
    );

    ctx.progress(
      0.1,
      'stage_progress_partition_full_disk',
      'Tüm disk sıfırlanıyor ve yapılandırılıyor: $selectedDisk',
      {'disk': selectedDisk},
    );

    final hasSgdisk = await _hasCommand(ctx, 'sgdisk');

    if (hasSgdisk) {
      if (!await ctx.runCmd(
        'sgdisk',
        ['-Z', selectedDisk],
        ctx.log,
        isMock: ctx.isMock,
      )) {
        return StageResult.fail(
          'Disk GPT tablosu sıfırlanamadı: $selectedDisk',
        );
      }

      if (!await ctx.runCmd(
        'sgdisk',
        ['-n', '1:0:+512M', '-t', '1:ef00', selectedDisk],
        ctx.log,
        isMock: ctx.isMock,
      )) {
        return StageResult.fail('EFI bölümü oluşturulamadı.');
      }

      if (!await ctx.runCmd(
        'sgdisk',
        ['-n', '2:0:0', selectedDisk],
        ctx.log,
        isMock: ctx.isMock,
      )) {
        return StageResult.fail('Root bölümü oluşturulamadı.');
      }
    } else {
      final hasParted = await _hasCommand(ctx, 'parted');
      if (!hasParted) {
        return StageResult.fail(
          'Disk araclari eksik: sgdisk bulunamadi ve parted fallback yolu da mevcut degil.',
        );
      }

      ctx.log(
        '[UYARI] sgdisk bulunamadi, full kurulum icin parted fallback kullaniliyor.',
      );

      if (!await ctx.runCmd(
        'parted',
        ['-s', selectedDisk, 'mklabel', 'gpt'],
        ctx.log,
        isMock: ctx.isMock,
      )) {
        return StageResult.fail('GPT etiketi parted ile oluşturulamadı.');
      }

      if (!await ctx.runCmd(
        'parted',
        ['-s', selectedDisk, 'mkpart', 'ESP', 'fat32', '1MiB', '513MiB'],
        ctx.log,
        isMock: ctx.isMock,
      )) {
        return StageResult.fail('EFI bölümü parted ile oluşturulamadı.');
      }

      if (!await ctx.runCmd(
        'parted',
        ['-s', selectedDisk, 'set', '1', 'esp', 'on'],
        ctx.log,
        isMock: ctx.isMock,
      )) {
        return StageResult.fail('EFI bayrağı parted ile ayarlanamadı.');
      }

      if (!await ctx.runCmd(
        'parted',
        ['-s', selectedDisk, 'mkpart', 'ROOT', '513MiB', '100%'],
        ctx.log,
        isMock: ctx.isMock,
      )) {
        return StageResult.fail('Root bölümü parted ile oluşturulamadı.');
      }
    }

    // Kernel'ın yeni bölüm tablosunu okuması için bekle
    await ctx.runCmd('partprobe', [selectedDisk], ctx.log, isMock: ctx.isMock);
    await Future.delayed(Duration(seconds: ctx.isMock ? 0 : 3));

    ctx.log('[AŞAMA 2] Tam disk bölümleme tamamlandı.');
    return StageResult.ok(
      ctx.t(
        'stage_result_partition_full_done',
        'Tam disk bölümleme tamamlandı: EFI + Root',
      ),
    );
  }

  /// Mevcut sisteme zarar vermeden yanına SWAP + Root bölümleri oluşturur
  Future<StageResult> _alongsidePartition(
    StageContext ctx,
    String selectedDisk,
  ) async {
    if (!await _hasCommand(ctx, 'sgdisk')) {
      return StageResult.fail(
        'sgdisk bulunamadi. Yanina kurulum icin gdisk/sgdisk paketi kurulu olmali.',
      );
    }
    if (!await _hasCommand(ctx, 'parted')) {
      return StageResult.fail(
        'parted bulunamadi. Yanina kurulum icin parted paketi kurulu olmali.',
      );
    }

    final double linuxGB =
        (ctx.state['linuxDiskSizeGB'] as num?)?.toDouble() ?? 60.0;
    final shrinkCandidatePartition =
        (ctx.state['shrinkCandidatePartition'] ?? '').toString();
    final shrinkCandidateFs = (ctx.state['shrinkCandidateFs'] ?? '')
        .toString()
        .toLowerCase();

    final targetLinuxBytes = (linuxGB * 1024 * 1024 * 1024).round().clamp(
      _minAlongsideLinuxBytes,
      1 << 62,
    );

    ctx.progress(
      0.05,
      'stage_progress_partition_backup_table',
      'Güvenlik: Mevcut bölüm tablosu yedekleniyor...',
    );
    if (!await ctx.runCmd(
      'sgdisk',
      ['--backup=/tmp/gpt_backup_alongside.bin', selectedDisk],
      ctx.log,
      isMock: ctx.isMock,
    )) {
      return StageResult.fail(
        'GPT yedegi alinamadi. Yanina kurulum guvenli sekilde baslatilamiyor.',
      );
    }

    // RAM'e göre SWAP boyutu hesapla
    final int ramMB = await _getSystemRamMB(ctx);
    final int swapMB = _calculateSwapMB(ramMB);
    final int swapBytes = swapMB * 1024 * 1024;
    ctx.log('Sistem RAM: ${ramMB}MB → Hesaplanan SWAP: ${swapMB}MB');
    if (targetLinuxBytes <= swapBytes) {
      return StageResult.fail(
        'Secilen yanina kurulum alani SWAP icin bile yeterli degil. En az 40 GB ayirmaniz gerekiyor.',
      );
    }

    final sectorSize = await _readSectorSize(ctx, selectedDisk);
    final diskLayout = await _readDiskLayout(ctx, selectedDisk, sectorSize);
    if (diskLayout == null) {
      return StageResult.fail(
        'Disk yerlesimi okunamadi. Yanina kur akisi durduruldu.',
      );
    }

    final alignSectors = ((1024 * 1024) / sectorSize).ceil();
    final swapSectors = _bytesToSectors(swapBytes, sectorSize);
    final rootSectors = _bytesToSectors(
      targetLinuxBytes - swapBytes,
      sectorSize,
    );

    ctx.progress(
      0.08,
      'stage_progress_partition_find_free_space',
      'Diskte bitisik bos alan araniyor...',
    );
    _AlongsideLayout? layout;

    final largestFree = await _readLargestFreeRange(ctx, selectedDisk);
    if (largestFree != null) {
      layout = _planAlongsideLayout(
        freeStart: largestFree.startSector,
        freeEnd: largestFree.endSector,
        swapSectors: swapSectors,
        rootSectors: rootSectors,
        alignSectors: alignSectors,
      );
      if (layout != null) {
        ctx.log(
          'Mevcut bitisik bos alan yeterli bulundu: ${largestFree.startSector}-${largestFree.endSector}',
        );
      }
    }

    if (layout == null) {
      if (shrinkCandidatePartition.isEmpty || shrinkCandidateFs.isEmpty) {
        return StageResult.fail(
          'Yeterli bitisik bos alan yok ve kucultulebilir bir kaynak bolum secilmemis.',
        );
      }

      final candidate = diskLayout.partitions
          .cast<Map<String, dynamic>?>()
          .firstWhere(
            (part) => part != null && part['path'] == shrinkCandidatePartition,
            orElse: () => null,
          );
      if (candidate == null) {
        return StageResult.fail(
          'Shrink adayi bolum bulunamadi: $shrinkCandidatePartition',
        );
      }

      final candidateStart = candidate['startSector'] as int;
      final candidateEnd = candidate['endSector'] as int;
      final candidateSizeBytes = candidate['sizeBytes'] as int;
      final candidateNumber = candidate['number'] as int;
      if (candidateNumber <= 0) {
        return StageResult.fail(
          'Shrink bolum numarasi cozumlenemedi: $shrinkCandidatePartition',
        );
      }
      final candidateIndex = diskLayout.partitions.indexOf(candidate);
      final contiguousEnd = candidateIndex < diskLayout.partitions.length - 1
          ? (diskLayout.partitions[candidateIndex + 1]['startSector'] as int) -
                1
          : diskLayout.lastUsableSector;

      layout = _planAlongsideLayout(
        freeStart: candidateEnd + 1,
        freeEnd: contiguousEnd,
        swapSectors: swapSectors,
        rootSectors: rootSectors,
        alignSectors: alignSectors,
      );

      if (layout == null) {
        final desiredLayout = _planAlongsideLayoutEndingAt(
          freeEnd: contiguousEnd,
          swapSectors: swapSectors,
          rootSectors: rootSectors,
          alignSectors: alignSectors,
        );
        if (desiredLayout == null) {
          return StageResult.fail(
            'Yeni yanina kurulum yerlesimi hesaplanamadi. Istenen alan disk geometrisine sigmiyor.',
          );
        }

        final newCandidateEnd = desiredLayout.swapStartSector - 1;
        final newCandidateSizeBytes =
            (newCandidateEnd - candidateStart + 1) * sectorSize;
        if (newCandidateSizeBytes < _minSourcePartitionBytes) {
          return StageResult.fail(
            'Kaynak bolumde en az 40 GB birakilamiyor. Daha kucuk bir Linux alani secin.',
          );
        }

        ctx.progress(
          0.12,
          'stage_progress_partition_shrink_source',
          'Kaynak bolum guvenli sekilde kucultuluyor...',
        );
        final shrinkResult = await _shrinkAlongsideCandidate(
          ctx,
          selectedDisk: selectedDisk,
          partitionPath: shrinkCandidatePartition,
          partitionFs: shrinkCandidateFs,
          partitionNumber: candidateNumber,
          currentSizeBytes: candidateSizeBytes,
          newPartitionSizeBytes: newCandidateSizeBytes,
          newPartitionEndSector: newCandidateEnd,
        );
        if (!shrinkResult.success) {
          return shrinkResult;
        }

        layout = desiredLayout;
      }
    }

    final resolvedLayout = layout;

    ctx.progress(
      0.16,
      'stage_progress_partition_create_swap',
      'Yeni SWAP bolumu olusturuluyor...',
    );
    if (!await ctx.runCmd(
      'sgdisk',
      [
        '-n',
        '0:${resolvedLayout.swapStartSector}:${resolvedLayout.swapEndSector}',
        '-t',
        '0:8200',
        '-c',
        '0:RoASD_Swap',
        selectedDisk,
      ],
      ctx.log,
      isMock: ctx.isMock,
    )) {
      await _restoreAlongsideBackup(ctx, selectedDisk);
      return StageResult.fail('SWAP bolumu olusturulamadi.');
    }

    ctx.progress(
      0.2,
      'stage_progress_partition_create_root',
      'Yeni kok dizin bolumu olusturuluyor...',
    );
    if (!await ctx.runCmd(
      'sgdisk',
      [
        '-n',
        '0:${resolvedLayout.rootStartSector}:${resolvedLayout.rootEndSector}',
        '-t',
        '0:8300',
        '-c',
        '0:RoASD_Root',
        selectedDisk,
      ],
      ctx.log,
      isMock: ctx.isMock,
    )) {
      await _restoreAlongsideBackup(ctx, selectedDisk);
      return StageResult.fail('Root bölümü oluşturulamadı.');
    }

    // Kernel'ın yeni bölüm tablosunu okuması için bekle
    await ctx.runCmd('partprobe', [selectedDisk], ctx.log, isMock: ctx.isMock);
    await Future.delayed(Duration(seconds: ctx.isMock ? 0 : 3));

    ctx.log(
      'Alongside yerlesimi → SWAP: ${resolvedLayout.swapStartSector}-${resolvedLayout.swapEndSector}, ROOT: ${resolvedLayout.rootStartSector}-${resolvedLayout.rootEndSector}',
    );
    ctx.log('[AŞAMA 2] Yanına kurulum bölümleme tamamlandı.');
    return StageResult.ok(
      ctx.t(
        'stage_result_partition_alongside_done',
        'Yanına kurulum bölümleme tamamlandı: SWAP + Root',
      ),
    );
  }

  /// UI üzerinden oluşturulmuş 'manualPartitions' listesini fiziksel diske uygular
  Future<StageResult> _manualPartition(
    StageContext ctx,
    String selectedDisk,
  ) async {
    if (!await _hasCommand(ctx, 'sgdisk')) {
      return StageResult.fail(
        'sgdisk bulunamadi. Manuel bolumleme icin gdisk/sgdisk paketi kurulu olmali.',
      );
    }

    final manualPartitions =
        ctx.state['manualPartitions'] as List<dynamic>? ?? [];
    if (manualPartitions.isEmpty) {
      return StageResult.fail('Manuel bölümleme planı boş.');
    }

    ctx.progress(
      0.05,
      'stage_progress_partition_apply_manual_plan',
      'Manuel plan diske uygulanıyor...',
    );

    // 1. Mevcut bölümleri tespit et (Silinenleri bulmak için)
    final currentPartsResult = await ctx.commandRunner.run('lsblk', [
      '-rn',
      '-o',
      'NAME,TYPE',
      selectedDisk,
    ]);
    final List<String> originalPartNames = [];
    if (currentPartsResult.exitCode == 0) {
      for (var line in currentPartsResult.stdout.trim().split('\n')) {
        final parts = line.split(RegExp(r'\s+'));
        if (parts.length >= 2 && parts[1] == 'part') {
          originalPartNames.add('/dev/${parts[0]}');
        }
      }
    }

    // 2. Silinmesi gerekenleri bul ve SİL
    final plannedNames = manualPartitions
        .map((p) => p['name'] as String)
        .toList();
    for (var currentName in originalPartNames) {
      if (!plannedNames.contains(currentName)) {
        // Bölüm numarasını bul (sda1 -> 1, nvme0n1p2 -> 2)
        final match = RegExp(r'(\d+)$').firstMatch(currentName);
        if (match != null) {
          final partNum = match.group(1)!;
          ctx.log('Bölüm siliniyor: $currentName (No: $partNum)');
          if (!await ctx.runCmd(
            'sgdisk',
            ['-d', partNum, selectedDisk],
            ctx.log,
            isMock: ctx.isMock,
          )) {
            return StageResult.fail('Bölüm silinemedi: $currentName');
          }
        }
      }
    }

    // Disk tablosunu güncelle
    await ctx.runCmd('partprobe', [selectedDisk], ctx.log, isMock: ctx.isMock);
    if (!ctx.isMock) await Future.delayed(const Duration(seconds: 1));

    final sectorSize = await _readSectorSize(ctx, selectedDisk);
    final alignSectors = (kManualPartitionAlignmentBytes / sectorSize).ceil();

    // 3. YENİ Bölümleri oluştur
    // Oluşturulmuş bölümleri takip etmek için (aktifler listesi)
    final activePartNames = List<String>.from(originalPartNames)
      ..removeWhere((n) => !plannedNames.contains(n));

    for (var i = 0; i < manualPartitions.length; i++) {
      final p = manualPartitions[i] as Map<String, dynamic>;
      if (p['isFreeSpace'] == true) continue;

      final name = p['name'] as String;

      if (p['isResized'] == true) {
        ctx.log(
          'UYARI: Bölüm boyutlandırma (Resize) canlı kurulumda desteklenmez. Bölüm ($name) orijinal boyutunda kalacaktır.',
        );
      }

      // UI tarafından 'New Partition' olarak isimlendirilmiş yeni bölümler
      if (name.startsWith('New Partition') || name == 'New Partition') {
        final requestedSizeBytes = p['sizeBytes'] as int;
        final requestedSizeMB = requestedSizeBytes ~/ (1024 * 1024);

        final diskLayout = await _readDiskLayout(ctx, selectedDisk, sectorSize);
        if (diskLayout == null) {
          return StageResult.fail(
            'Disk yerlesimi okunamadi. Manuel bolum olusturma durduruldu.',
          );
        }

        final largestFreeRange = _findLargestAlignedFreeRange(
          diskLayout,
          alignSectors,
        );
        if (largestFreeRange == null) {
          return StageResult.fail('Yeni bolum icin uygun bos alan bulunamadi.');
        }

        final availableSectors =
            largestFreeRange.endSector - largestFreeRange.startSector + 1;
        final availableBytes = _sectorsToBytes(availableSectors, sectorSize);
        final plannedSizeBytes = fitManualPartitionBytesToAvailable(
          requestedSizeBytes,
          availableBytes,
        );
        if (plannedSizeBytes == null) {
          final maxSizeMB = availableBytes ~/ (1024 * 1024);
          return StageResult.fail(
            'Bolum olusturulamadi: istenen ${requestedSizeMB}MB, kullanilabilir en fazla ${maxSizeMB}MB.',
          );
        }

        final plannedSectors = _bytesToSectors(plannedSizeBytes, sectorSize);
        final startSector = largestFreeRange.startSector;
        final endSector = startSector + plannedSectors - 1;
        final actualSizeBytes = _sectorsToBytes(plannedSectors, sectorSize);
        final actualSizeMB = actualSizeBytes ~/ (1024 * 1024);

        final fsType = _normalizeManualFsType((p['type'] ?? '').toString());
        String typeCode = '8300'; // Linux filesystem
        if (fsType == 'fat32') typeCode = 'ef00'; // EFI
        if (fsType == 'linux-swap') typeCode = '8200'; // SWAP

        if (actualSizeBytes != requestedSizeBytes) {
          ctx.log(
            'UYARI: Istenen ${requestedSizeMB}MB alan, GPT/hizalama guvenlik payi nedeniyle ${actualSizeMB}MB olarak ayarlandi.',
          );
          p['sizeBytes'] = actualSizeBytes;
        }

        ctx.progress(
          0.1 + (i * 0.05),
          'stage_progress_partition_create_manual',
          'Yeni bölüm oluşturuluyor: ${actualSizeMB}MB ($fsType)',
          {'size': actualSizeMB.toString(), 'fs': fsType},
        );
        ctx.log(
          'Manuel bos alan secimi → $startSector-${largestFreeRange.endSector}, olusturulacak bolum → $startSector-$endSector',
        );

        // Bölümü diske yaz
        if (!await ctx.runCmd(
          'sgdisk',
          [
            '-n',
            '0:$startSector:$endSector',
            '-t',
            '0:$typeCode',
            selectedDisk,
          ],
          ctx.log,
          isMock: ctx.isMock,
        )) {
          return StageResult.fail('Bolum olusturulamadi: ${actualSizeMB}MB');
        }

        await ctx.runCmd(
          'partprobe',
          [selectedDisk],
          ctx.log,
          isMock: ctx.isMock,
        );
        if (!ctx.isMock) await Future.delayed(const Duration(seconds: 2));

        // Yeni oluşan bölümün gerçek (/dev/sdX) adını bul
        final newPartsResult = await ctx.commandRunner.run('lsblk', [
          '-rn',
          '-o',
          'NAME,TYPE',
          selectedDisk,
        ]);
        String? newPartName;
        if (newPartsResult.exitCode == 0) {
          for (var line in newPartsResult.stdout.trim().split('\n')) {
            final parts = line.split(RegExp(r'\s+'));
            if (parts.length >= 2 && parts[1] == 'part') {
              final cand = '/dev/${parts[0]}';
              // Eğer mevcut aktif listede yoksa, bu bizim az önce oluşturduğumuz bölümdür
              if (!activePartNames.contains(cand)) {
                newPartName = cand;
                activePartNames.add(cand);
                break;
              }
            }
          }
        }

        if (newPartName != null) {
          ctx.log('Atanan bölüm adı: $newPartName');
          p['name'] =
              newPartName; // Format aşamasının kullanabilmesi için ismi referanstan güncelliyoruz
        } else {
          if (!ctx.isMock) {
            return StageResult.fail(
              'Yeni bölüm oluşturuldu ancak adı tespit edilemedi.',
            );
          }
          p['name'] = '${selectedDisk}X'; // Mock testi için sahte isim
        }
      }
    }

    ctx.log('[AŞAMA 2] Manuel bölümleme fiziksel diske uygulandı.');
    return StageResult.ok(
      ctx.t(
        'stage_result_partition_manual_done',
        'Manuel bölümleme planı diske uygulandı.',
      ),
    );
  }

  Future<int> _readSectorSize(StageContext ctx, String disk) async {
    final result = await ctx.commandRunner.run('blockdev', ['--getss', disk]);
    if (result.exitCode != 0) {
      return 512;
    }
    return int.tryParse(result.stdout.trim()) ?? 512;
  }

  Future<_DiskLayout?> _readDiskLayout(
    StageContext ctx,
    String disk,
    int sectorSize,
  ) async {
    final result = await ctx.commandRunner.run('lsblk', [
      '-J',
      '-b',
      '-o',
      'NAME,PATH,TYPE,SIZE,START,FSTYPE',
      disk,
    ]);
    if (result.exitCode != 0) {
      return null;
    }

    final parsed = jsonDecode(result.stdout) as Map<String, dynamic>;
    final devices = parsed['blockdevices'] as List<dynamic>? ?? const [];
    if (devices.isEmpty) {
      return null;
    }

    final diskEntry = devices.first as Map<String, dynamic>;
    final diskSizeBytes = diskEntry['size'] is int
        ? diskEntry['size'] as int
        : int.tryParse((diskEntry['size'] ?? '').toString()) ?? 0;
    final totalSectors = sectorSize > 0 ? diskSizeBytes ~/ sectorSize : 0;
    final lastUsableSector = totalSectors > 34
        ? totalSectors - 34
        : totalSectors - 1;
    final partitions = <Map<String, dynamic>>[];

    for (final raw in diskEntry['children'] as List<dynamic>? ?? const []) {
      final part = raw as Map<String, dynamic>;
      final path = (part['path'] ?? '').toString();
      final sizeBytes = part['size'] is int
          ? part['size'] as int
          : int.tryParse((part['size'] ?? '').toString()) ?? 0;
      final startSector = part['start'] is int
          ? part['start'] as int
          : int.tryParse((part['start'] ?? '').toString());
      if (path.isEmpty || startSector == null || sizeBytes <= 0) {
        continue;
      }

      final sectorCount = _bytesToSectors(sizeBytes, sectorSize);
      final endSector = startSector + sectorCount - 1;
      partitions.add({
        'path': path,
        'number': _partitionNumber(path),
        'fsType': (part['fstype'] ?? '').toString().toLowerCase(),
        'sizeBytes': sizeBytes,
        'startSector': startSector,
        'endSector': endSector,
      });
    }

    partitions.sort(
      (a, b) => (a['startSector'] as int).compareTo(b['startSector'] as int),
    );

    return _DiskLayout(
      partitions: partitions,
      lastUsableSector: lastUsableSector,
    );
  }

  Future<_FreeRange?> _readLargestFreeRange(
    StageContext ctx,
    String selectedDisk,
  ) async {
    final startResult = await ctx.commandRunner.run('sgdisk', [
      '-F',
      selectedDisk,
    ]);
    final endResult = await ctx.commandRunner.run('sgdisk', [
      '-E',
      selectedDisk,
    ]);
    final startSector = int.tryParse(startResult.stdout.trim());
    final endSector = int.tryParse(endResult.stdout.trim());
    if (startResult.exitCode != 0 ||
        endResult.exitCode != 0 ||
        startSector == null ||
        endSector == null ||
        endSector < startSector) {
      return null;
    }
    return _FreeRange(startSector: startSector, endSector: endSector);
  }

  _FreeRange? _findLargestAlignedFreeRange(
    _DiskLayout layout,
    int alignSectors,
  ) {
    _FreeRange? bestRange;
    var bestSectors = 0;
    var cursor = _gptFirstUsableSector;

    void considerRange(int rawStart, int rawEnd) {
      final alignedStart = _alignUp(rawStart, alignSectors);
      if (alignedStart > rawEnd) {
        return;
      }

      final rangeSectors = rawEnd - alignedStart + 1;
      if (rangeSectors > bestSectors) {
        bestSectors = rangeSectors;
        bestRange = _FreeRange(startSector: alignedStart, endSector: rawEnd);
      }
    }

    for (final partition in layout.partitions) {
      final partitionStart = partition['startSector'] as int;
      final partitionEnd = partition['endSector'] as int;
      considerRange(cursor, partitionStart - 1);
      cursor = partitionEnd + 1;
    }

    considerRange(cursor, layout.lastUsableSector);
    return bestRange;
  }

  _AlongsideLayout? _planAlongsideLayout({
    required int freeStart,
    required int freeEnd,
    required int swapSectors,
    required int rootSectors,
    required int alignSectors,
  }) {
    final swapStart = _alignUp(freeStart, alignSectors);
    final swapEnd = swapStart + swapSectors - 1;
    final rootStart = _alignUp(swapEnd + 1, alignSectors);
    final rootEnd = rootStart + rootSectors - 1;
    if (rootEnd > freeEnd) {
      return null;
    }
    return _AlongsideLayout(
      swapStartSector: swapStart,
      swapEndSector: swapEnd,
      rootStartSector: rootStart,
      rootEndSector: rootEnd,
    );
  }

  _AlongsideLayout? _planAlongsideLayoutEndingAt({
    required int freeEnd,
    required int swapSectors,
    required int rootSectors,
    required int alignSectors,
  }) {
    final rootStart = _alignDown(freeEnd - rootSectors + 1, alignSectors);
    if (rootStart <= 0) {
      return null;
    }
    final rootEnd = rootStart + rootSectors - 1;
    final swapEnd = rootStart - 1;
    final swapStart = _alignDown(swapEnd - swapSectors + 1, alignSectors);
    if (swapStart <= 0) {
      return null;
    }
    final actualSwapEnd = swapStart + swapSectors - 1;
    if (actualSwapEnd >= rootStart) {
      return null;
    }
    return _AlongsideLayout(
      swapStartSector: swapStart,
      swapEndSector: actualSwapEnd,
      rootStartSector: rootStart,
      rootEndSector: rootEnd,
    );
  }

  Future<StageResult> _shrinkAlongsideCandidate(
    StageContext ctx, {
    required String selectedDisk,
    required String partitionPath,
    required String partitionFs,
    required int partitionNumber,
    required int currentSizeBytes,
    required int newPartitionSizeBytes,
    required int newPartitionEndSector,
  }) async {
    if (newPartitionSizeBytes >= currentSizeBytes) {
      return StageResult.ok(
        ctx.t(
          'stage_result_partition_shrink_not_needed',
          'Mevcut bos alan yeterli, shrink gerekmiyor.',
        ),
      );
    }

    final fsTargetBytes = newPartitionSizeBytes > _filesystemSafetyMarginBytes
        ? newPartitionSizeBytes - _filesystemSafetyMarginBytes
        : newPartitionSizeBytes;

    if (partitionFs == 'ntfs') {
      if (!await _hasCommand(ctx, 'ntfsresize')) {
        return StageResult.fail('ntfsresize bulunamadi.');
      }
      if (!await ctx.runCmd(
        'ntfsresize',
        ['--force', '--size', '$fsTargetBytes', partitionPath],
        ctx.log,
        isMock: ctx.isMock,
      )) {
        return StageResult.fail(
          'NTFS dosya sistemi kucultulemedi: $partitionPath',
        );
      }
    } else if (partitionFs == 'ext4') {
      if (!await _hasCommand(ctx, 'e2fsck') ||
          !await _hasCommand(ctx, 'resize2fs')) {
        return StageResult.fail(
          'EXT4 shrink araci eksik. e2fsck ve resize2fs gerekli.',
        );
      }
      if (!await ctx.runCmd(
        'e2fsck',
        ['-f', '-p', partitionPath],
        ctx.log,
        isMock: ctx.isMock,
        allowedExitCodes: const [0, 1, 2],
      )) {
        return StageResult.fail(
          'EXT4 dosya sistemi denetimi basarisiz: $partitionPath',
        );
      }
      final resizeKiB = fsTargetBytes ~/ 1024;
      if (!await ctx.runCmd(
        'resize2fs',
        [partitionPath, '${resizeKiB}K'],
        ctx.log,
        isMock: ctx.isMock,
      )) {
        return StageResult.fail(
          'EXT4 dosya sistemi kucultulemedi: $partitionPath',
        );
      }
    } else {
      return StageResult.fail(
        'Desteklenmeyen shrink dosya sistemi: $partitionFs',
      );
    }

    if (!await ctx.runCmd(
      'parted',
      [
        '-s',
        selectedDisk,
        'unit',
        's',
        'resizepart',
        '$partitionNumber',
        '${newPartitionEndSector}s',
      ],
      ctx.log,
      isMock: ctx.isMock,
    )) {
      await _restoreAlongsideBackup(ctx, selectedDisk);
      return StageResult.fail(
        'Bölüm sonu güvenli şekilde küçültülemedi: $partitionPath',
      );
    }

    await ctx.runCmd('partprobe', [selectedDisk], ctx.log, isMock: ctx.isMock);
    if (!ctx.isMock) {
      await Future.delayed(const Duration(seconds: 2));
    }

    ctx.log(
      'Shrink tamamlandi: $partitionPath → yeni boyut ${newPartitionSizeBytes ~/ (1024 * 1024 * 1024)} GB',
    );
    return StageResult.ok(
      ctx.t('stage_result_partition_shrink_done', 'Shrink tamamlandi.'),
    );
  }

  Future<void> _restoreAlongsideBackup(
    StageContext ctx,
    String selectedDisk,
  ) async {
    ctx.log('UYARI: GPT yedegi geri yukleniyor...');
    await ctx.runCmd(
      'sgdisk',
      ['--load-backup=/tmp/gpt_backup_alongside.bin', selectedDisk],
      ctx.log,
      isMock: ctx.isMock,
    );
    await ctx.runCmd('partprobe', [selectedDisk], ctx.log, isMock: ctx.isMock);
  }

  int _partitionNumber(String path) {
    final match = RegExp(r'(\d+)$').firstMatch(path);
    return int.tryParse(match?.group(1) ?? '') ?? 0;
  }

  int _bytesToSectors(int bytes, int sectorSize) {
    if (bytes <= 0 || sectorSize <= 0) {
      return 0;
    }
    return (bytes + sectorSize - 1) ~/ sectorSize;
  }

  int _sectorsToBytes(int sectors, int sectorSize) {
    if (sectors <= 0 || sectorSize <= 0) {
      return 0;
    }
    return sectors * sectorSize;
  }

  int _alignUp(int value, int alignment) {
    if (alignment <= 1) {
      return value;
    }
    final remainder = value % alignment;
    return remainder == 0 ? value : value + alignment - remainder;
  }

  int _alignDown(int value, int alignment) {
    if (alignment <= 1) {
      return value;
    }
    return value - (value % alignment);
  }

  /// Sistem RAM miktarını MB cinsinden okur (/proc/meminfo)
  Future<int> _getSystemRamMB(StageContext ctx) async {
    try {
      final result = await ctx.commandRunner.run('grep', [
        'MemTotal',
        '/proc/meminfo',
      ]);
      if (result.exitCode == 0) {
        final match = RegExp(r'(\d+)').firstMatch(result.stdout);
        if (match != null) {
          final kb = int.parse(match.group(1)!);
          return kb ~/ 1024;
        }
      }
    } catch (e) {
      // Okunamazsa varsayılan değer
    }
    return 4096; // Varsayılan 4 GB
  }

  String _normalizeManualFsType(String fsType) {
    switch (fsType) {
      case 'vfat':
        return 'fat32';
      case 'swap':
        return 'linux-swap';
      default:
        return fsType;
    }
  }

  /// RAM'e göre dinamik SWAP boyutu hesaplar (MB cinsinden)
  int _calculateSwapMB(int ramMB) {
    if (ramMB <= 2048) return ramMB * 2;
    if (ramMB <= 8192) return ramMB;
    if (ramMB <= 16384) return ramMB ~/ 2;
    return 8192; // 8 GB üst sınır
  }
}

class _DiskLayout {
  const _DiskLayout({required this.partitions, required this.lastUsableSector});

  final List<Map<String, dynamic>> partitions;
  final int lastUsableSector;
}

class _FreeRange {
  const _FreeRange({required this.startSector, required this.endSector});

  final int startSector;
  final int endSector;
}

class _AlongsideLayout {
  const _AlongsideLayout({
    required this.swapStartSector,
    required this.swapEndSector,
    required this.rootStartSector,
    required this.rootEndSector,
  });

  final int swapStartSector;
  final int swapEndSector;
  final int rootStartSector;
  final int rootEndSector;
}
