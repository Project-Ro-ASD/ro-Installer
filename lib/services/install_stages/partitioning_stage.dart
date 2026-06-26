import 'dart:convert';

import '../../models/storage_plan.dart';
import '../storage_topology_guard.dart';
import '../../utils/manual_partition_sizing.dart';
import 'stage_context.dart';
import 'stage_result.dart';

/// AŞAMA 2: Bölümleme (Partitioning)
///
/// Seçilen yönteme göre disk bölümlerini oluşturur:
/// - 'full': Tüm diski silip EFI + SWAP + Root oluşturur
/// - 'alongside': Mevcut sisteme zarar vermeden yanına SWAP + Root oluşturur
/// - 'manual': Kullanıcının UI'da belirlediği planı uygular (format işlemi bir sonraki aşamada)
///
/// Bu aşama sadece bölüm tablolarını oluşturur, biçimlendirme yapmaz.
class PartitioningStage {
  const PartitioningStage();

  static const int _minAlongsideLinuxBytes = 40 * 1024 * 1024 * 1024;
  static const int _minRootBytes = 40 * 1024 * 1024 * 1024;
  static const int _minSourcePartitionBytes = 40 * 1024 * 1024 * 1024;
  static const int _sourcePartitionExtraMarginBytes = 10 * 1024 * 1024 * 1024;
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

    final contractFailure = _validateBtrfsOnlyContract(ctx.state);
    if (contractFailure != null) {
      return StageResult.fail(contractFailure);
    }
    final topologyFailure = await _validateUnsupportedStorageTopology(
      ctx,
      selectedDisk,
    );
    if (topologyFailure != null) {
      return topologyFailure;
    }
    late final StoragePlan storagePlan;
    try {
      storagePlan = StoragePlanBuilder.fromState(ctx.state);
      final storagePlanJson = jsonEncode(storagePlan.toJson());
      ctx.state['_storagePlan'] = storagePlanJson;
      ctx.log('Storage plan hazirlandi: $storagePlanJson');
    } on StoragePlanException catch (e) {
      return StageResult.fail(e.message);
    }

    switch (partitionMethod) {
      case 'full':
        return _fullDiskPartition(ctx, selectedDisk, storagePlan);
      case 'alongside':
        return _alongsidePartition(ctx, selectedDisk, storagePlan);
      case 'free_space':
        return _freeSpacePartition(ctx, selectedDisk, storagePlan);
      case 'manual':
        return _manualPartition(ctx, selectedDisk, storagePlan);
      default:
        return StageResult.fail(
          'Bilinmeyen bölümleme yöntemi: $partitionMethod',
        );
    }
  }

  /// Tüm diski silip yeniden bölümlendirir:
  /// EFI (512MB) + hibernate uyumlu SWAP + Root (kalan)
  Future<StageResult> _fullDiskPartition(
    StageContext ctx,
    String selectedDisk,
    StoragePlan storagePlan,
  ) async {
    ctx.progress(
      0.05,
      'stage_progress_partition_reset_disk',
      'Disk sıfırlanıyor ve bağlantılar kesiliyor...',
    );

    // Wipefs ile disk imzalarını temizle
    final wipePlanFailure = _requirePlannedDestructiveOperation(
      storagePlan,
      type: 'wipe_disk',
      target: selectedDisk,
    );
    if (wipePlanFailure != null) return wipePlanFailure;
    if (!await ctx.runCmd(
      'wipefs',
      ['-a', selectedDisk],
      ctx.log,
      isMock: ctx.isMock,
    )) {
      return StageResult.fail('Disk imzaları temizlenemedi: $selectedDisk');
    }

    ctx.progress(
      0.1,
      'stage_progress_partition_full_disk',
      'Tüm disk sıfırlanıyor ve yapılandırılıyor: $selectedDisk',
      {'disk': selectedDisk},
    );

    final ramMB = await _getSystemRamMB(ctx);
    final swapMB = _calculateSwapMB(ramMB);
    final swapBytes = swapMB * 1024 * 1024;
    final diskBytes = await _readDiskSizeBytes(ctx, selectedDisk);
    if (diskBytes != null) {
      final requiredBytes = 512 * 1024 * 1024 + swapBytes + _minRootBytes;
      if (diskBytes < requiredBytes) {
        return StageResult.fail(
          'Disk hibernate uyumlu SWAP ve en az 40 GB root alanı için küçük. '
          'Gereken minimum: ${_bytesToGiB(requiredBytes)} GB.',
        );
      }
    }
    ctx.log('Sistem RAM: ${ramMB}MB → Hibernate uyumlu SWAP: ${swapMB}MB');

    final hasSgdisk = await _hasCommand(ctx, 'sgdisk');

    if (hasSgdisk) {
      final createEfiPlanFailure = _requirePlannedDestructiveOperation(
        storagePlan,
        type: 'create_efi',
        target: selectedDisk,
      );
      if (createEfiPlanFailure != null) return createEfiPlanFailure;
      final createSwapPlanFailure = _requirePlannedDestructiveOperation(
        storagePlan,
        type: 'create_swap',
        target: selectedDisk,
      );
      if (createSwapPlanFailure != null) return createSwapPlanFailure;
      final createRootPlanFailure = _requirePlannedDestructiveOperation(
        storagePlan,
        type: 'create_btrfs_root',
        target: selectedDisk,
      );
      if (createRootPlanFailure != null) return createRootPlanFailure;

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
        [
          '-n',
          '2:0:+${swapMB}M',
          '-t',
          '2:8200',
          '-c',
          '2:RoASD_Swap',
          selectedDisk,
        ],
        ctx.log,
        isMock: ctx.isMock,
      )) {
        return StageResult.fail('SWAP bölümü oluşturulamadı.');
      }

      if (!await ctx.runCmd(
        'sgdisk',
        ['-n', '3:0:0', '-t', '3:8300', '-c', '3:RoASD_Root', selectedDisk],
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

      final createEfiPlanFailure = _requirePlannedDestructiveOperation(
        storagePlan,
        type: 'create_efi',
        target: selectedDisk,
      );
      if (createEfiPlanFailure != null) return createEfiPlanFailure;
      final createSwapPlanFailure = _requirePlannedDestructiveOperation(
        storagePlan,
        type: 'create_swap',
        target: selectedDisk,
      );
      if (createSwapPlanFailure != null) return createSwapPlanFailure;
      final createRootPlanFailure = _requirePlannedDestructiveOperation(
        storagePlan,
        type: 'create_btrfs_root',
        target: selectedDisk,
      );
      if (createRootPlanFailure != null) return createRootPlanFailure;

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
        [
          '-s',
          selectedDisk,
          'mkpart',
          'SWAP',
          'linux-swap',
          '513MiB',
          '${513 + swapMB}MiB',
        ],
        ctx.log,
        isMock: ctx.isMock,
      )) {
        return StageResult.fail('SWAP bölümü parted ile oluşturulamadı.');
      }

      if (!await ctx.runCmd(
        'parted',
        ['-s', selectedDisk, 'mkpart', 'ROOT', '${513 + swapMB}MiB', '100%'],
        ctx.log,
        isMock: ctx.isMock,
      )) {
        return StageResult.fail('Root bölümü parted ile oluşturulamadı.');
      }
    }

    // Kernel'ın yeni bölüm tablosunu okuması için bekle
    final rescanFailure = await _rescanDisk(ctx, selectedDisk);
    if (rescanFailure != null) return rescanFailure;

    ctx.state['_resolvedSwapPart'] = _partitionPath(selectedDisk, 2);
    ctx.state['_resolvedRootPart'] = _partitionPath(selectedDisk, 3);
    ctx.log('[AŞAMA 2] Tam disk bölümleme tamamlandı.');
    return StageResult.ok(
      ctx.t(
        'stage_result_partition_full_done',
        'Tam disk bölümleme tamamlandı: EFI + SWAP + Root',
      ),
    );
  }

  /// Mevcut sisteme zarar vermeden yanına SWAP + Root bölümleri oluşturur
  Future<StageResult> _alongsidePartition(
    StageContext ctx,
    String selectedDisk,
    StoragePlan storagePlan,
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

    final preflightFailure = await _preflightAlongsideInstall(
      ctx,
      selectedDisk,
    );
    if (preflightFailure != null) {
      return preflightFailure;
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
    final backupPath = _gptBackupPath(ctx, 'alongside', selectedDisk);
    if (!await ctx.runCmd(
      'sgdisk',
      ['--backup=$backupPath', selectedDisk],
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
    final requiredLinuxBytes = swapBytes + _minRootBytes;
    ctx.log('Sistem RAM: ${ramMB}MB → Hibernate uyumlu SWAP: ${swapMB}MB');
    if (targetLinuxBytes < requiredLinuxBytes) {
      return StageResult.fail(
        'Secilen yanina kurulum alani hibernate uyumlu SWAP ve en az 40 GB root icin yeterli degil. '
        'En az ${_bytesToGiB(requiredLinuxBytes)} GB ayirmaniz gerekiyor.',
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
        final minimumSourceBytes = _minimumSourcePartitionBytes(
          candidateSizeBytes,
        );
        if (newCandidateSizeBytes < minimumSourceBytes) {
          return StageResult.fail(
            'Kaynak bolumde guvenli tampon alan birakilamiyor. Daha kucuk bir Linux alani secin.',
          );
        }

        ctx.progress(
          0.12,
          'stage_progress_partition_shrink_source',
          'Kaynak bolum guvenli sekilde kucultuluyor...',
        );
        final shrinkResult = await _shrinkAlongsideCandidate(
          ctx,
          storagePlan: storagePlan,
          planOperationType: 'shrink_source_partition',
          selectedDisk: selectedDisk,
          partitionPath: shrinkCandidatePartition,
          partitionFs: shrinkCandidateFs,
          partitionNumber: candidateNumber,
          currentSizeBytes: candidateSizeBytes,
          newPartitionSizeBytes: newCandidateSizeBytes,
          newPartitionEndSector: newCandidateEnd,
          backupPath: backupPath,
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
    final createSwapPlanFailure = _requirePlannedDestructiveOperation(
      storagePlan,
      type: 'create_swap',
      target: selectedDisk,
    );
    if (createSwapPlanFailure != null) return createSwapPlanFailure;
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
      await _restoreAlongsideBackup(ctx, selectedDisk, backupPath: backupPath);
      return StageResult.fail('SWAP bolumu olusturulamadi.');
    }

    ctx.progress(
      0.2,
      'stage_progress_partition_create_root',
      'Yeni kok dizin bolumu olusturuluyor...',
    );
    final createRootPlanFailure = _requirePlannedDestructiveOperation(
      storagePlan,
      type: 'create_btrfs_root',
      target: selectedDisk,
    );
    if (createRootPlanFailure != null) return createRootPlanFailure;
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
      await _restoreAlongsideBackup(ctx, selectedDisk, backupPath: backupPath);
      return StageResult.fail('Root bölümü oluşturulamadı.');
    }

    // Kernel'ın yeni bölüm tablosunu okuması için bekle
    final rescanFailure = await _rescanDisk(ctx, selectedDisk);
    if (rescanFailure != null) return rescanFailure;

    ctx.log(
      'Alongside yerlesimi → SWAP: ${resolvedLayout.swapStartSector}-${resolvedLayout.swapEndSector}, ROOT: ${resolvedLayout.rootStartSector}-${resolvedLayout.rootEndSector}',
    );
    ctx.state['_resolvedSwapStartSector'] = resolvedLayout.swapStartSector;
    ctx.state['_resolvedRootStartSector'] = resolvedLayout.rootStartSector;
    ctx.log('[AŞAMA 2] Yanına kurulum bölümleme tamamlandı.');
    return StageResult.ok(
      ctx.t(
        'stage_result_partition_alongside_done',
        'Yanına kurulum bölümleme tamamlandı: SWAP + Root',
      ),
    );
  }

  Future<StageResult?> _preflightAlongsideInstall(
    StageContext ctx,
    String selectedDisk,
  ) async {
    ctx.progress(
      0.03,
      'stage_progress_partition_preflight',
      'Yanına kurulum güvenlik ön kontrolü yapılıyor...',
    );

    final blockers = _readStringSet(ctx.state['alongsideBlockers']);
    const hardBlockers = {
      'boot_mode_not_uefi',
      'partition_table_not_gpt',
      'missing_efi',
      'bitlocker_enabled',
      'ntfs_hibernated_or_fast_startup',
      'ntfs_check_failed',
      'ntfs_resize_tool_missing',
      'unsupported_storage_topology',
    };
    for (final blocker in hardBlockers) {
      if (blockers.contains(blocker)) {
        return StageResult.fail(_alongsideBlockerMessage(blocker));
      }
    }

    final bootMode = (ctx.state['diskBootMode'] ?? '').toString();
    if (bootMode.isNotEmpty && bootMode != 'unknown' && bootMode != 'uefi') {
      return StageResult.fail(_alongsideBlockerMessage('boot_mode_not_uefi'));
    }
    if (!ctx.isMock && (bootMode.isEmpty || bootMode == 'unknown')) {
      final uefiResult = await ctx.commandRunner.run('test', [
        '-d',
        '/sys/firmware/efi',
      ]);
      if (uefiResult.exitCode != 0) {
        return StageResult.fail(_alongsideBlockerMessage('boot_mode_not_uefi'));
      }
    }

    var partitionTable = (ctx.state['diskPartitionTable'] ?? '')
        .toString()
        .toLowerCase();
    if (!ctx.isMock &&
        (partitionTable.isEmpty || partitionTable == 'unknown')) {
      final pttypeResult = await ctx.commandRunner.run('lsblk', [
        '-dn',
        '-o',
        'PTTYPE',
        selectedDisk,
      ]);
      if (pttypeResult.exitCode == 0) {
        partitionTable = pttypeResult.stdout.trim().toLowerCase();
      }
    }
    if (partitionTable.isNotEmpty &&
        partitionTable != 'unknown' &&
        partitionTable != 'gpt') {
      return StageResult.fail(
        _alongsideBlockerMessage('partition_table_not_gpt'),
      );
    }
    if (!ctx.isMock &&
        (partitionTable.isEmpty || partitionTable == 'unknown')) {
      return StageResult.fail(
        _alongsideBlockerMessage('partition_table_not_gpt'),
      );
    }

    final hasExistingEfiValue = ctx.state['hasExistingEfi'];
    final existingEfiPartition = (ctx.state['existingEfiPartition'] ?? '')
        .toString();
    if (hasExistingEfiValue == false ||
        (!ctx.isMock &&
            hasExistingEfiValue != true &&
            existingEfiPartition.isEmpty)) {
      return StageResult.fail(_alongsideBlockerMessage('missing_efi'));
    }

    return null;
  }

  /// Onceden ayrilmis bos alana SWAP + Root bolumleri olusturur.
  ///
  /// Bu akista mevcut bolum kucultme veya tasima yapilmaz. UI tarafinda
  /// secilen `selectedFreeSpace` segmentinin sector araligi kullanilir.
  Future<StageResult> _freeSpacePartition(
    StageContext ctx,
    String selectedDisk,
    StoragePlan storagePlan,
  ) async {
    if (!await _hasCommand(ctx, 'sgdisk')) {
      return StageResult.fail(
        'sgdisk bulunamadi. Ayrilmis alana kurulum icin gdisk/sgdisk paketi kurulu olmali.',
      );
    }

    final hasExistingEfi = ctx.state['hasExistingEfi'] == true;
    final existingEfiPart = (ctx.state['existingEfiPartition'] ?? '')
        .toString();
    if (!hasExistingEfi || existingEfiPart.isEmpty) {
      return StageResult.fail(
        'Ayrilmis alana kurulum icin mevcut ve kullanilabilir bir EFI bolumu gerekli.',
      );
    }
    final partitionTable = (ctx.state['diskPartitionTable'] ?? '').toString();
    if (partitionTable.isNotEmpty &&
        partitionTable != 'unknown' &&
        partitionTable != 'gpt') {
      return StageResult.fail(
        'Ayrilmis alana kurulum yalnizca GPT disklerde desteklenir.',
      );
    }

    if (!ctx.isMock) {
      final uefiResult = await ctx.commandRunner.run('test', [
        '-d',
        '/sys/firmware/efi',
      ]);
      if (uefiResult.exitCode != 0) {
        return StageResult.fail(
          'Ayrilmis alana kurulum yalnizca UEFI modunda desteklenir.',
        );
      }
    }

    final selectedFreeSpace =
        ctx.state['selectedFreeSpace'] as Map<String, dynamic>? ?? const {};
    final freeStart = selectedFreeSpace['startSector'] as int?;
    final freeEnd = selectedFreeSpace['endSector'] as int?;
    if (freeStart == null || freeEnd == null || freeEnd <= freeStart) {
      return StageResult.fail(
        'Ayrilmis alana kurulum icin gecerli bir bos alan secilmedi.',
      );
    }
    final allocationPlanFailure = _requirePlannedDestructiveOperation(
      storagePlan,
      type: 'allocate_selected_free_space',
      target: selectedDisk,
      details: {'startSector': freeStart, 'endSector': freeEnd},
    );
    if (allocationPlanFailure != null) return allocationPlanFailure;

    ctx.progress(
      0.05,
      'stage_progress_partition_backup_table',
      'Güvenlik: Mevcut bölüm tablosu yedekleniyor...',
    );
    final backupPath = _gptBackupPath(ctx, 'free-space', selectedDisk);
    if (!await ctx.runCmd(
      'sgdisk',
      ['--backup=$backupPath', selectedDisk],
      ctx.log,
      isMock: ctx.isMock,
    )) {
      return StageResult.fail(
        'GPT yedegi alinamadi. Ayrilmis alana kurulum baslatilamiyor.',
      );
    }

    final int ramMB = await _getSystemRamMB(ctx);
    final int swapMB = _calculateSwapMB(ramMB);
    final int swapBytes = swapMB * 1024 * 1024;
    final int sectorSize = await _readSectorSize(ctx, selectedDisk);
    final int freeBytes = _sectorsToBytes(freeEnd - freeStart + 1, sectorSize);
    final int requiredBytes = swapBytes + _minRootBytes;
    ctx.log(
      'Ayrilmis alan: ${_bytesToGiB(freeBytes)} GB, RAM: ${ramMB}MB → SWAP: ${swapMB}MB',
    );
    if (freeBytes < requiredBytes) {
      return StageResult.fail(
        'Secilen bos alan hibernate uyumlu SWAP ve en az 40 GB root icin yeterli degil. '
        'Gereken minimum: ${_bytesToGiB(requiredBytes)} GB.',
      );
    }

    final alignSectors = ((1024 * 1024) / sectorSize).ceil();
    final swapSectors = _bytesToSectors(swapBytes, sectorSize);
    final swapStart = _alignUp(freeStart, alignSectors);
    final swapEnd = swapStart + swapSectors - 1;
    final rootStart = _alignUp(swapEnd + 1, alignSectors);
    final rootEnd = freeEnd;
    final rootBytes = _sectorsToBytes(rootEnd - rootStart + 1, sectorSize);
    final layout = rootStart <= rootEnd && rootBytes >= _minRootBytes
        ? _AlongsideLayout(
            swapStartSector: swapStart,
            swapEndSector: swapEnd,
            rootStartSector: rootStart,
            rootEndSector: rootEnd,
          )
        : null;
    if (layout == null) {
      return StageResult.fail(
        'Secilen bos alanda hizalama sonrasi SWAP + Root yerlesimi hesaplanamadi.',
      );
    }

    ctx.progress(
      0.12,
      'stage_progress_partition_create_swap',
      'Ayrılmış alanda yeni SWAP bölümü oluşturuluyor...',
    );
    final createSwapPlanFailure = _requirePlannedDestructiveOperation(
      storagePlan,
      type: 'create_swap',
      target: selectedDisk,
    );
    if (createSwapPlanFailure != null) return createSwapPlanFailure;
    if (!await ctx.runCmd(
      'sgdisk',
      [
        '-n',
        '0:${layout.swapStartSector}:${layout.swapEndSector}',
        '-t',
        '0:8200',
        '-c',
        '0:RoASD_Swap',
        selectedDisk,
      ],
      ctx.log,
      isMock: ctx.isMock,
    )) {
      await _restoreAlongsideBackup(ctx, selectedDisk, backupPath: backupPath);
      return StageResult.fail('SWAP bolumu olusturulamadi.');
    }

    ctx.progress(
      0.18,
      'stage_progress_partition_create_root',
      'Ayrılmış alanda yeni kök dizin bölümü oluşturuluyor...',
    );
    final createRootPlanFailure = _requirePlannedDestructiveOperation(
      storagePlan,
      type: 'create_btrfs_root',
      target: selectedDisk,
    );
    if (createRootPlanFailure != null) return createRootPlanFailure;
    if (!await ctx.runCmd(
      'sgdisk',
      [
        '-n',
        '0:${layout.rootStartSector}:${layout.rootEndSector}',
        '-t',
        '0:8300',
        '-c',
        '0:RoASD_Root',
        selectedDisk,
      ],
      ctx.log,
      isMock: ctx.isMock,
    )) {
      await _restoreAlongsideBackup(ctx, selectedDisk, backupPath: backupPath);
      return StageResult.fail('Root bölümü oluşturulamadı.');
    }

    final rescanFailure = await _rescanDisk(ctx, selectedDisk);
    if (rescanFailure != null) return rescanFailure;

    ctx.state['_resolvedSwapStartSector'] = layout.swapStartSector;
    ctx.state['_resolvedRootStartSector'] = layout.rootStartSector;
    ctx.log(
      'Ayrilmis alan yerlesimi → SWAP: ${layout.swapStartSector}-${layout.swapEndSector}, ROOT: ${layout.rootStartSector}-${layout.rootEndSector}',
    );
    ctx.log('[AŞAMA 2] Ayrılmış alana kurulum bölümleme tamamlandı.');
    return StageResult.ok(
      ctx.t(
        'stage_result_partition_free_space_done',
        'Ayrılmış alana kurulum bölümleme tamamlandı: SWAP + Root',
      ),
    );
  }

  /// UI üzerinden oluşturulmuş 'manualPartitions' listesini fiziksel diske uygular
  Future<StageResult> _manualPartition(
    StageContext ctx,
    String selectedDisk,
    StoragePlan storagePlan,
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

    final manualBackupPath = _gptBackupPath(ctx, 'manual', selectedDisk);
    if (!await ctx.runCmd(
      'sgdisk',
      ['--backup=$manualBackupPath', selectedDisk],
      ctx.log,
      isMock: ctx.isMock,
    )) {
      return StageResult.fail(
        'GPT yedegi alinamadi. Manuel bolumleme guvenli sekilde baslatilamiyor.',
      );
    }

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

    // 2. Açık silme planı olan bölümleri bul ve SİL.
    final plannedNames = manualPartitions
        .where((p) => p is Map<String, dynamic> && p['isFreeSpace'] != true)
        .map((p) => (p['name'] ?? '').toString())
        .where((name) => name.isNotEmpty)
        .toSet();
    final deletedNames = <String>{};
    for (final rawPart in manualPartitions) {
      if (rawPart is! Map<String, dynamic>) continue;
      final rawDeleted = rawPart['deletedPartitionNames'];
      if (rawDeleted is Iterable) {
        deletedNames.addAll(
          rawDeleted
              .map((entry) => entry.toString())
              .where((entry) => entry.isNotEmpty),
        );
      }
    }
    for (var currentName in originalPartNames) {
      if (!plannedNames.contains(currentName)) {
        if (!deletedNames.contains(currentName)) {
          return StageResult.fail(
            'Mevcut bölüm açık silme planı olmadan plandan eksildi: $currentName',
          );
        }
        // Bölüm numarasını bul (sda1 -> 1, nvme0n1p2 -> 2)
        final match = RegExp(r'(\d+)$').firstMatch(currentName);
        if (match != null) {
          final partNum = match.group(1)!;
          ctx.log('Bölüm siliniyor: $currentName (No: $partNum)');
          final deletePlanFailure = _requirePlannedDestructiveOperation(
            storagePlan,
            type: 'delete_partition',
            target: currentName,
          );
          if (deletePlanFailure != null) return deletePlanFailure;
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
    final deleteRescanFailure = await _rescanDisk(ctx, selectedDisk);
    if (deleteRescanFailure != null) return deleteRescanFailure;

    final sectorSize = await _readSectorSize(ctx, selectedDisk);
    final alignSectors = (kManualPartitionAlignmentBytes / sectorSize).ceil();

    // 3. Mevcut bölümlerde planlanmış küçültmeleri uygula
    for (final rawPart in manualPartitions) {
      final p = rawPart as Map<String, dynamic>;
      if (p['isFreeSpace'] == true || p['isResized'] != true) {
        continue;
      }

      final name = (p['name'] ?? '').toString();
      if (name.isEmpty || name.startsWith('New Partition')) {
        return StageResult.fail('Manuel resize icin gecersiz bolum adi: $name');
      }

      final diskLayout = await _readDiskLayout(ctx, selectedDisk, sectorSize);
      if (diskLayout == null) {
        return StageResult.fail(
          'Disk yerlesimi okunamadi. Manuel resize durduruldu.',
        );
      }

      final candidate = diskLayout.partitions
          .cast<Map<String, dynamic>?>()
          .firstWhere(
            (part) => part != null && part['path'] == name,
            orElse: () => null,
          );
      if (candidate == null) {
        return StageResult.fail('Resize bolumu bulunamadi: $name');
      }

      final newSizeBytes = p['sizeBytes'] as int;
      final candidateStart = candidate['startSector'] as int;
      final candidateSizeBytes = candidate['sizeBytes'] as int;
      final candidateNumber = candidate['number'] as int;
      final newEndSector =
          p['endSector'] as int? ??
          candidateStart + _bytesToSectors(newSizeBytes, sectorSize) - 1;

      if (newSizeBytes >= candidateSizeBytes) {
        continue;
      }
      if (candidateNumber <= 0) {
        return StageResult.fail('Resize bolum numarasi cozumlenemedi: $name');
      }

      ctx.progress(
        0.08,
        'stage_progress_partition_shrink_source',
        'Kaynak bolum guvenli sekilde kucultuluyor...',
      );
      final resizeResult = await _shrinkAlongsideCandidate(
        ctx,
        storagePlan: storagePlan,
        planOperationType: 'resize_partition',
        selectedDisk: selectedDisk,
        partitionPath: name,
        partitionFs: _normalizeManualFsType((p['type'] ?? '').toString()),
        partitionNumber: candidateNumber,
        currentSizeBytes: candidateSizeBytes,
        newPartitionSizeBytes: newSizeBytes,
        newPartitionEndSector: newEndSector,
        backupPath: manualBackupPath,
      );
      if (!resizeResult.success) {
        return resizeResult;
      }
    }

    // 4. YENİ Bölümleri oluştur
    // Oluşturulmuş bölümleri takip etmek için (aktifler listesi)
    final activePartNames = List<String>.from(originalPartNames)
      ..removeWhere((n) => !plannedNames.contains(n));

    for (var i = 0; i < manualPartitions.length; i++) {
      final p = manualPartitions[i] as Map<String, dynamic>;
      if (p['isFreeSpace'] == true) continue;

      final name = p['name'] as String;

      // UI tarafından 'New Partition' olarak isimlendirilmiş yeni bölümler
      if (name.startsWith('New Partition') || name == 'New Partition') {
        final requestedSizeBytes = p['sizeBytes'] as int;
        final requestedSizeMB = requestedSizeBytes ~/ (1024 * 1024);
        final createPlanDetails = _manualPartitionPlanDetails(p);

        final diskLayout = await _readDiskLayout(ctx, selectedDisk, sectorSize);
        if (diskLayout == null) {
          return StageResult.fail(
            'Disk yerlesimi okunamadi. Manuel bolum olusturma durduruldu.',
          );
        }

        final requestedSectors = _bytesToSectors(
          requestedSizeBytes,
          sectorSize,
        );
        final plannedStartSector = p['startSector'] as int?;
        final plannedEndSector =
            p['endSector'] as int? ??
            (plannedStartSector == null
                ? null
                : plannedStartSector + requestedSectors - 1);
        final largestFreeRange =
            plannedStartSector != null && plannedEndSector != null
            ? _findAlignedFreeRangeForPlannedPartition(
                diskLayout,
                plannedStartSector: plannedStartSector,
                plannedEndSector: plannedEndSector,
                alignSectors: alignSectors,
              )
            : _findLargestAlignedFreeRange(diskLayout, alignSectors);
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
        final createPlanFailure = _requirePlannedDestructiveOperation(
          storagePlan,
          type: 'create_partition',
          target: name,
          details: createPlanDetails,
        );
        if (createPlanFailure != null) return createPlanFailure;
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

        final createRescanFailure = await _rescanDisk(ctx, selectedDisk);
        if (createRescanFailure != null) return createRescanFailure;

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

  _FreeRange? _findAlignedFreeRangeForPlannedPartition(
    _DiskLayout layout, {
    required int plannedStartSector,
    required int plannedEndSector,
    required int alignSectors,
  }) {
    var cursor = _gptFirstUsableSector;

    _FreeRange? matchRange(int rawStart, int rawEnd) {
      final alignedStart = _alignUp(rawStart, alignSectors);
      final start = _alignUp(
        plannedStartSector < alignedStart ? alignedStart : plannedStartSector,
        alignSectors,
      );
      if (start > rawEnd || plannedEndSector > rawEnd) {
        return null;
      }
      return _FreeRange(startSector: start, endSector: rawEnd);
    }

    for (final partition in layout.partitions) {
      final partitionStart = partition['startSector'] as int;
      final partitionEnd = partition['endSector'] as int;
      final range = matchRange(cursor, partitionStart - 1);
      if (range != null) {
        return range;
      }
      cursor = partitionEnd + 1;
    }

    return matchRange(cursor, layout.lastUsableSector);
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
    required StoragePlan storagePlan,
    required String planOperationType,
    required String selectedDisk,
    required String partitionPath,
    required String partitionFs,
    required int partitionNumber,
    required int currentSizeBytes,
    required int newPartitionSizeBytes,
    required int newPartitionEndSector,
    required String backupPath,
  }) async {
    if (newPartitionSizeBytes >= currentSizeBytes) {
      return StageResult.ok(
        ctx.t(
          'stage_result_partition_shrink_not_needed',
          'Mevcut bos alan yeterli, shrink gerekmiyor.',
        ),
      );
    }
    final shrinkPlanFailure = _requirePlannedDestructiveOperation(
      storagePlan,
      type: planOperationType,
      target: partitionPath,
    );
    if (shrinkPlanFailure != null) return shrinkPlanFailure;

    final fsTargetBytes = newPartitionSizeBytes > _filesystemSafetyMarginBytes
        ? newPartitionSizeBytes - _filesystemSafetyMarginBytes
        : newPartitionSizeBytes;

    if (partitionFs == 'ntfs') {
      final safetyIssue = await _checkNtfsResizeSafety(ctx, partitionPath);
      if (safetyIssue != null) {
        return StageResult.fail(_alongsideBlockerMessage(safetyIssue));
      }
      ctx.progress(
        0.12,
        'stage_progress_partition_resize_ntfs',
        'NTFS dosya sistemi küçültülüyor...',
      );
      if (!await ctx.runCmd(
        'ntfsresize',
        ['--force', '--size', '$fsTargetBytes', partitionPath],
        ctx.log,
        isMock: ctx.isMock,
      )) {
        await _restoreAlongsideBackup(
          ctx,
          selectedDisk,
          backupPath: backupPath,
        );
        return StageResult.fail(
          'NTFS dosya sistemi kucultulemedi: $partitionPath',
        );
      }
    } else if (partitionFs == 'btrfs') {
      ctx.progress(
        0.12,
        'stage_progress_partition_resize_btrfs',
        'BTRFS dosya sistemi küçültülüyor...',
      );
      final btrfsResult = await _shrinkBtrfsFilesystem(
        ctx,
        partitionPath: partitionPath,
        fsTargetBytes: fsTargetBytes,
      );
      if (!btrfsResult.success) {
        await _restoreAlongsideBackup(
          ctx,
          selectedDisk,
          backupPath: backupPath,
        );
        return btrfsResult;
      }
    } else {
      return StageResult.fail(
        'Desteklenmeyen shrink dosya sistemi: $partitionFs',
      );
    }

    ctx.progress(
      0.14,
      'stage_progress_partition_resize_partition_entry',
      'Bölüm tablosundaki kaynak bölüm sınırı güncelleniyor...',
    );
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
      await _restoreAlongsideBackup(ctx, selectedDisk, backupPath: backupPath);
      return StageResult.fail(
        'Bölüm sonu güvenli şekilde küçültülemedi: $partitionPath',
      );
    }

    ctx.progress(
      0.15,
      'stage_progress_partition_rescan_disk',
      'Disk bölümleri yeniden taranıyor...',
    );
    final rescanFailure = await _rescanDisk(ctx, selectedDisk);
    if (rescanFailure != null) return rescanFailure;

    ctx.log(
      'Shrink tamamlandi: $partitionPath → yeni boyut ${newPartitionSizeBytes ~/ (1024 * 1024 * 1024)} GB',
    );
    return StageResult.ok(
      ctx.t('stage_result_partition_shrink_done', 'Shrink tamamlandi.'),
    );
  }

  Future<StageResult> _shrinkBtrfsFilesystem(
    StageContext ctx, {
    required String partitionPath,
    required int fsTargetBytes,
  }) async {
    if (!await _hasCommand(ctx, 'btrfs')) {
      return StageResult.fail('BTRFS shrink araci eksik: btrfs-progs gerekli.');
    }

    final mountPoint =
        '/tmp/ro-installer-btrfs-shrink-${_safePathComponent(partitionPath)}';
    var mounted = false;

    Future<StageResult> failAfterUnmount(String message) async {
      if (mounted) {
        await ctx.runCmd('umount', [mountPoint], ctx.log, isMock: ctx.isMock);
      }
      return StageResult.fail(message);
    }

    if (!await ctx.runCmd(
      'mkdir',
      ['-p', mountPoint],
      ctx.log,
      isMock: ctx.isMock,
    )) {
      return StageResult.fail('BTRFS gecici baglama dizini olusturulamadi.');
    }

    if (!await ctx.runCmd(
      'mount',
      ['-o', 'subvolid=5', partitionPath, mountPoint],
      ctx.log,
      isMock: ctx.isMock,
    )) {
      if (!await ctx.runCmd(
        'mount',
        [partitionPath, mountPoint],
        ctx.log,
        isMock: ctx.isMock,
      )) {
        return StageResult.fail(
          'BTRFS bolumu gecici olarak baglanamadi: $partitionPath',
        );
      }
    }
    mounted = true;

    final showResult = await ctx.commandRunner.run('btrfs', [
      'filesystem',
      'show',
      '--raw',
      mountPoint,
    ]);
    if (showResult.exitCode != 0) {
      return failAfterUnmount('BTRFS aygit bilgisi okunamadi.');
    }
    final deviceCount = _parseBtrfsDeviceCount(showResult.stdout);
    if (deviceCount != null && deviceCount > 1) {
      return failAfterUnmount(
        'Cok aygitli BTRFS dosya sistemi otomatik kucultme icin desteklenmiyor.',
      );
    }

    final minSizeResult = await ctx.commandRunner.run('btrfs', [
      'inspect-internal',
      'min-dev-size',
      mountPoint,
    ]);
    final minSizeBytes = minSizeResult.exitCode == 0
        ? _parseFirstInteger(minSizeResult.stdout)
        : null;
    if (minSizeBytes == null) {
      return failAfterUnmount(
        'BTRFS minimum shrink siniri okunamadi; guvenli olmayan resize durduruldu.',
      );
    }
    if (fsTargetBytes <= minSizeBytes + _filesystemSafetyMarginBytes) {
      return failAfterUnmount(
        'BTRFS bolumu istenen boyuta guvenli sekilde kucultulemiyor.',
      );
    }

    if (!await ctx.runCmd(
      'btrfs',
      ['filesystem', 'resize', '$fsTargetBytes', mountPoint],
      ctx.log,
      isMock: ctx.isMock,
    )) {
      return failAfterUnmount(
        'BTRFS dosya sistemi kucultulemedi: $partitionPath',
      );
    }

    await ctx.runCmd('sync', const <String>[], ctx.log, isMock: ctx.isMock);
    if (!await ctx.runCmd(
      'umount',
      [mountPoint],
      ctx.log,
      isMock: ctx.isMock,
    )) {
      return StageResult.fail(
        'BTRFS gecici baglama noktasi ayrilamadi: $mountPoint',
      );
    }
    mounted = false;

    return StageResult.ok('BTRFS shrink tamamlandi.');
  }

  int? _parseBtrfsDeviceCount(String output) {
    final totalMatch = RegExp(
      r'Total\s+devices\s+(\d+)',
      caseSensitive: false,
    ).firstMatch(output);
    if (totalMatch != null) {
      return int.tryParse(totalMatch.group(1)!);
    }
    final deviceMatches = RegExp(
      r'^\s*devid\s+\d+',
      multiLine: true,
      caseSensitive: false,
    ).allMatches(output);
    if (deviceMatches.isNotEmpty) {
      return deviceMatches.length;
    }
    return null;
  }

  int? _parseFirstInteger(String output) {
    final match = RegExp(r'\d+').firstMatch(output);
    return match == null ? null : int.tryParse(match.group(0)!);
  }

  String _safePathComponent(String value) {
    return value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  }

  String _gptBackupPath(StageContext ctx, String scope, String selectedDisk) {
    if (ctx.isMock) {
      return '/tmp/ro-installer-gpt-$scope-mock.bin';
    }
    final safeDisk = _safePathComponent(selectedDisk);
    final stamp = DateTime.now().toUtc().microsecondsSinceEpoch;
    return '/tmp/ro-installer-gpt-$scope-$safeDisk-$stamp.bin';
  }

  Set<String> _readStringSet(Object? rawValue) {
    if (rawValue is Iterable) {
      return rawValue.map((value) => value.toString()).toSet();
    }
    if (rawValue is String && rawValue.isNotEmpty) {
      return {rawValue};
    }
    return <String>{};
  }

  String? _validateBtrfsOnlyContract(Map<String, dynamic> state) {
    final rootFs = (state['fileSystem'] ?? 'btrfs').toString();
    if (rootFs != 'btrfs') {
      return 'Ro-ASD yalnızca Btrfs root dosya sistemini destekler: $rootFs';
    }

    final partitionMethod = (state['partitionMethod'] ?? '').toString();
    if (partitionMethod != 'manual') {
      return null;
    }

    final manualPartitions =
        state['manualPartitions'] as List<dynamic>? ?? const [];
    for (final rawPart in manualPartitions) {
      if (rawPart is! Map<String, dynamic> || rawPart['isFreeSpace'] == true) {
        continue;
      }
      final mount = (rawPart['mount'] ?? 'unmounted').toString();
      final type = (rawPart['type'] ?? '').toString();
      if (mount == '/boot/efi') {
        if (type != 'fat32' && type != 'vfat') {
          return 'Manuel kurulumda EFI bölümü FAT32 olmalıdır: ${rawPart['name']}';
        }
        continue;
      }
      if (mount == '[SWAP]') {
        if (type != 'linux-swap' && type != 'swap') {
          return 'Manuel kurulumda swap bölümü linux-swap olmalıdır: ${rawPart['name']}';
        }
        continue;
      }
      if (mount != 'unmounted' && type != 'btrfs') {
        return 'Manuel kurulumda mount edilen bölümler Btrfs olmalıdır: ${rawPart['name']} ($type)';
      }
    }
    return null;
  }

  Future<StageResult?> _validateUnsupportedStorageTopology(
    StageContext ctx,
    String selectedDisk,
  ) async {
    var report = unsupportedStorageTopologyFromState(ctx.state);
    if (!report.hasBlockers && !ctx.isMock) {
      report = await detectUnsupportedStorageTopologyOnDisk(
        ctx.commandRunner,
        selectedDisk,
      );
    }
    if (report.inspectionFailed) {
      return StageResult.fail(
        'Disk topolojisi dogrulanamadi; destructive islem baslatilmadi: '
        '${report.inspectionError}',
      );
    }
    if (!report.hasBlockers) {
      return null;
    }
    return StageResult.fail(unsupportedStorageTopologyMessage(report));
  }

  StageResult? _requirePlannedDestructiveOperation(
    StoragePlan storagePlan, {
    required String type,
    required String target,
    Map<String, dynamic> details = const <String, dynamic>{},
  }) {
    if (storagePlan.hasOperation(
      type,
      target,
      destructiveOnly: true,
      details: details,
    )) {
      return null;
    }
    return StageResult.fail(
      'Storage plan dışı destructive disk işlemi engellendi: $type -> $target',
    );
  }

  Map<String, dynamic> _manualPartitionPlanDetails(Map<String, dynamic> part) {
    final formatOnInstall = part.containsKey('formatOnInstall')
        ? part['formatOnInstall'] == true
        : part['isPlanned'] == true;
    return {
      'mount': (part['mount'] ?? 'unmounted').toString(),
      'fsType': (part['type'] ?? '').toString(),
      'formatOnInstall': formatOnInstall,
      'isResized': part['isResized'] == true,
      if (part['sizeBytes'] != null) 'sizeBytes': part['sizeBytes'],
      if (part['startSector'] != null) 'startSector': part['startSector'],
      if (part['endSector'] != null) 'endSector': part['endSector'],
    };
  }

  String _alongsideBlockerMessage(String code) {
    switch (code) {
      case 'boot_mode_not_uefi':
        return 'Yanina kurulum yalnizca UEFI modunda desteklenir. BIOS/Legacy modda mevcut EFI guvenli kullanilamaz.';
      case 'partition_table_not_gpt':
        return 'Yanina kurulum yalnizca GPT disklerde desteklenir. MBR/unknown bolum tablosunda otomatik resize guvenli degil.';
      case 'missing_efi':
        return 'Yanina kurulum icin mevcut ve kullanilabilir bir EFI bolumu gerekli.';
      case 'bitlocker_enabled':
        return 'BitLocker etkin gorunuyor. Windows bolumu otomatik kucultulmeyecek.';
      case 'ntfs_hibernated_or_fast_startup':
        return 'Windows hibernation/Fast Startup acik gorunuyor. Windows tamamen kapatilmadan NTFS kucultme yapilmiyor.';
      case 'ntfs_dirty':
        return 'NTFS bolumu kirli veya tutarsiz gorunuyor. Sınırlı onarım sonrası güvenli küçültme onayı alınamadı.';
      case 'ntfs_repair_tool_missing':
        return 'ntfsfix bulunamadi. NTFS kirli bayragi otomatik temizlenemiyor.';
      case 'ntfs_repair_failed':
        return 'ntfsfix NTFS kirli bayragini temizleyemedi. Windows tarafinda chkdsk/onarim gerekli.';
      case 'ntfs_resize_tool_missing':
        return 'ntfsresize bulunamadi. NTFS bolumu guvenli sekilde kucultulemez.';
      case 'ntfs_check_failed':
        return 'NTFS on kontrolu basarisiz oldu. Bolum kucultme islemi baslatilmadi.';
      case 'unsupported_storage_topology':
        return 'Bu disk LUKS/LVM/RAID/multipath veya nested block-device yapisi iceriyor. Stable kurulum bu topolojide disk yazma islemi baslatmaz.';
      default:
        return 'Yanina kurulum on kontrolu basarisiz: $code';
    }
  }

  Future<String?> _checkNtfsResizeSafety(
    StageContext ctx,
    String partitionPath,
  ) async {
    if (!await _hasCommand(ctx, 'ntfsresize')) {
      return 'ntfs_resize_tool_missing';
    }

    ctx.progress(
      0.11,
      'stage_progress_partition_check_ntfs',
      'NTFS küçültme ön kontrolü yapılıyor...',
    );
    final stopwatch = Stopwatch()..start();
    final result = await ctx.commandRunner.run(
      'ntfsresize',
      ['--info', '--force', partitionPath],
      isMock: ctx.isMock,
      onLog: (event) => ctx.log(event.displayMessage),
    );
    stopwatch.stop();
    ctx.log(
      '[SÜRE] ntfsresize --info --force $partitionPath -> exit=${result.exitCode} duration=${_formatDuration(stopwatch.elapsed)}',
    );

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
      return _repairDirtyNtfsAndRecheck(ctx, partitionPath);
    }
    if (!result.started) {
      return 'ntfs_resize_tool_missing';
    }
    if (result.exitCode != 0) {
      return 'ntfs_check_failed';
    }
    return null;
  }

  Future<String?> _repairDirtyNtfsAndRecheck(
    StageContext ctx,
    String partitionPath,
  ) async {
    if (!await _hasCommand(ctx, 'ntfsfix')) {
      return 'ntfs_repair_tool_missing';
    }

    ctx.progress(
      0.115,
      'stage_progress_partition_repair_ntfs',
      'NTFS kirli bayrağı sınırlı onarımla temizleniyor...',
    );
    final repairStopwatch = Stopwatch()..start();
    final repairResult = await ctx.commandRunner.run(
      'ntfsfix',
      ['-d', partitionPath],
      isMock: ctx.isMock,
      onLog: (event) => ctx.log(event.displayMessage),
    );
    repairStopwatch.stop();
    ctx.log(
      '[SÜRE] ntfsfix -d $partitionPath -> exit=${repairResult.exitCode} duration=${_formatDuration(repairStopwatch.elapsed)}',
    );
    if (!repairResult.started) {
      return 'ntfs_repair_tool_missing';
    }
    if (repairResult.exitCode != 0) {
      return 'ntfs_repair_failed';
    }

    final recheckStopwatch = Stopwatch()..start();
    final recheckResult = await ctx.commandRunner.run(
      'ntfsresize',
      ['--info', '--force', partitionPath],
      isMock: ctx.isMock,
      onLog: (event) => ctx.log(event.displayMessage),
    );
    recheckStopwatch.stop();
    ctx.log(
      '[SÜRE] ntfsresize --info --force $partitionPath (onarım sonrası) -> exit=${recheckResult.exitCode} duration=${_formatDuration(recheckStopwatch.elapsed)}',
    );

    final recheckText = '${recheckResult.stdout}\n${recheckResult.stderr}'
        .toLowerCase();
    if (recheckText.contains('bitlocker')) {
      return 'bitlocker_enabled';
    }
    if (recheckText.contains('hibernat') ||
        recheckText.contains('fast restart') ||
        recheckText.contains('fast startup') ||
        recheckText.contains('resume and shutdown windows fully')) {
      return 'ntfs_hibernated_or_fast_startup';
    }
    if (recheckText.contains('dirty') ||
        recheckText.contains('inconsistent') ||
        recheckText.contains('chkdsk')) {
      return 'ntfs_dirty';
    }
    if (!recheckResult.started) {
      return 'ntfs_resize_tool_missing';
    }
    if (recheckResult.exitCode != 0) {
      return 'ntfs_check_failed';
    }
    return null;
  }

  String _formatDuration(Duration duration) {
    final ms = duration.inMilliseconds;
    if (ms < 1000) {
      return '${ms}ms';
    }
    return '${(ms / 1000).toStringAsFixed(1)}s';
  }

  Future<StageResult?> _rescanDisk(
    StageContext ctx,
    String selectedDisk,
  ) async {
    if (!await ctx.runCmd(
      'partprobe',
      [selectedDisk],
      ctx.log,
      isMock: ctx.isMock,
    )) {
      return StageResult.fail(
        'Disk bolum tablosu yeniden okunamadi: $selectedDisk',
      );
    }
    if (!ctx.isMock) {
      if (!await ctx.runCmd(
        'udevadm',
        ['settle'],
        ctx.log,
        isMock: ctx.isMock,
      )) {
        return StageResult.fail(
          'udev yeni bolumleri kararlı hale getiremedi: $selectedDisk',
        );
      }
      await Future.delayed(const Duration(seconds: 2));
    }
    return null;
  }

  Future<void> _restoreAlongsideBackup(
    StageContext ctx,
    String selectedDisk, {
    required String backupPath,
  }) async {
    ctx.log('UYARI: GPT yedegi geri yukleniyor...');
    await ctx.runCmd(
      'sgdisk',
      ['--load-backup=$backupPath', selectedDisk],
      ctx.log,
      isMock: ctx.isMock,
    );
    await _rescanDisk(ctx, selectedDisk);
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

  Future<int?> _readDiskSizeBytes(StageContext ctx, String selectedDisk) async {
    if (ctx.isMock) {
      return null;
    }

    final result = await ctx.commandRunner.run('blockdev', [
      '--getsize64',
      selectedDisk,
    ]);
    final size = int.tryParse(result.stdout.trim());
    if (result.exitCode == 0 && size != null && size > 0) {
      return size;
    }
    return null;
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
    final normalizedRamMB = ramMB > 0 ? ramMB : 4096;
    final hibernateMarginMB = normalizedRamMB <= 8192 ? 1024 : 2048;
    final hibernateSwapMB = normalizedRamMB + hibernateMarginMB;
    final lowRamSwapMB = normalizedRamMB <= 4096
        ? normalizedRamMB * 2
        : hibernateSwapMB;
    final rawSwapMB = lowRamSwapMB > hibernateSwapMB
        ? lowRamSwapMB
        : hibernateSwapMB;
    return ((rawSwapMB + 511) ~/ 512) * 512;
  }

  String _partitionPath(String disk, int partitionNumber) {
    final needsP =
        disk.contains('nvme') ||
        disk.contains('loop') ||
        disk.contains('mmcblk');
    return needsP ? '${disk}p$partitionNumber' : '$disk$partitionNumber';
  }

  int _bytesToGiB(int bytes) {
    return (bytes + 1024 * 1024 * 1024 - 1) ~/ (1024 * 1024 * 1024);
  }

  int _minimumSourcePartitionBytes(int currentSizeBytes) {
    final percentReserve = (currentSizeBytes * 0.10).round();
    final baseReserve = percentReserve > _minSourcePartitionBytes
        ? percentReserve
        : _minSourcePartitionBytes;
    return baseReserve + _sourcePartitionExtraMarginBytes;
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
