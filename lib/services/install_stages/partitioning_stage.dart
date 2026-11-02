import 'full_disk_readiness.dart';
import 'manual_partitioning.dart';
import 'dart:convert';

import '../../models/storage_plan.dart';
import '../../models/approved_full_disk_plan.dart';
import '../../models/free_space_installation_plan.dart';
import '../../models/gpt_disk_snapshot.dart';
import '../../models/standard_storage_layout.dart';
import '../storage_topology_guard.dart';
import 'stage_context.dart';
import 'stage_result.dart';

/// AŞAMA 2: Bölümleme (Partitioning)
///
/// Seçilen yönteme göre disk bölümlerini oluşturur:
/// - 'full': Tüm diski silip EFI + Btrfs Root oluşturur
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
    if (!ctx.approvedStateMatches) {
      return StageResult.fail('Onaylanan disk planı değişti.');
    }
    final selectedDisk = ctx.state['selectedDisk'] as String;
    final partitionMethod = ctx.state['partitionMethod'] as String;
    if (partitionMethod == 'manual') return partitionApprovedManual(ctx);

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
    if (partitionMethod == 'free_space') {
      return _freeSpacePartition(ctx, selectedDisk);
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
      default:
        return StageResult.fail(
          'Bilinmeyen bölümleme yöntemi: $partitionMethod',
        );
    }
  }

  /// Tüm diski silip yeniden bölümlendirir:
  /// EFI (512 MiB) + Btrfs Root (kalan)
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

    final diskBytes = await _readDiskSizeBytes(ctx, selectedDisk);
    if (!ctx.isMock && diskBytes == null) {
      return StageResult.fail('Hedef disk boyutu güvenli şekilde okunamadı.');
    }
    if (diskBytes != null &&
        diskBytes < StandardStorageLayout.minimumDiskBytes) {
      return StageResult.fail(
        'Disk geçici prepared-root güvenlik sınırı için küçük. '
        'Bu sınır nihai Ro-ASD minimumu değildir.',
      );
    }

    final hasSgdisk = await _hasCommand(ctx, 'sgdisk');
    if (!hasSgdisk && !await _hasCommand(ctx, 'parted')) {
      return StageResult.fail(
        'Disk araçları eksik: sgdisk ve parted bulunamadı.',
      );
    }

    // Wipefs ile disk imzalarını temizle
    final wipePlanFailure = _requirePlannedDestructiveOperation(
      storagePlan,
      type: 'wipe_disk',
      target: selectedDisk,
    );
    if (wipePlanFailure != null) return wipePlanFailure;
    // All read-only planning/tool checks are complete. The helper revalidates
    // the confirmed disk under its installation lock at this exact boundary.
    await ctx.beforeFirstMutation?.call();
    if (!matchesApprovedPlan(ctx.state, expected: ctx.approvedPlan)) {
      return StageResult.fail('Onaylanan disk planı değişti.');
    }
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

    if (hasSgdisk) {
      final createEfiPlanFailure = _requirePlannedDestructiveOperation(
        storagePlan,
        type: 'create_efi',
        target: selectedDisk,
      );
      if (createEfiPlanFailure != null) return createEfiPlanFailure;
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
        ['-n', '2:0:0', '-t', '2:8300', '-c', '2:RoASD_Root', selectedDisk],
        ctx.log,
        isMock: ctx.isMock,
      )) {
        return StageResult.fail('Root bölümü oluşturulamadı.');
      }
    } else {
      ctx.log(
        '[UYARI] sgdisk bulunamadi, full kurulum icin parted fallback kullaniliyor.',
      );

      final createEfiPlanFailure = _requirePlannedDestructiveOperation(
        storagePlan,
        type: 'create_efi',
        target: selectedDisk,
      );
      if (createEfiPlanFailure != null) return createEfiPlanFailure;
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
        ['-s', selectedDisk, 'mkpart', 'ROOT', '513MiB', '100%'],
        ctx.log,
        isMock: ctx.isMock,
      )) {
        return StageResult.fail('Root bölümü parted ile oluşturulamadı.');
      }
    }

    // Kernel'ın yeni bölüm tablosunu okuması için bekle
    final rescanFailure = await _rescanDisk(
      ctx,
      selectedDisk,
      fullWriter: hasSgdisk
          ? FullDiskPartitionWriter.sgdisk
          : FullDiskPartitionWriter.parted,
    );
    if (rescanFailure != null) return rescanFailure;

    ctx.state.remove('_resolvedSwapPart');
    ctx.state['_resolvedRootPart'] = _partitionPath(selectedDisk, 2);
    ctx.log('[AŞAMA 2] Tam disk bölümleme tamamlandı.');
    return StageResult.ok(
      ctx.t(
        'stage_result_partition_full_done',
        'Tam disk bölümleme tamamlandı: EFI + Btrfs Root',
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
  ) async {
    final approved = ctx.approvedFreeSpacePlan;
    if (approved == null || !approved.matchesState(ctx.state)) {
      return StageResult.fail('Doğrulanmış boş alan onayı gerekli.');
    }
    ctx.state['_storagePlan'] = jsonEncode(approved.plan.intentJson);
    if (!await _hasCommand(ctx, 'sfdisk')) {
      return StageResult.fail('sfdisk bulunamadı.');
    }
    try {
      final before = await ctx.probeFreeSpaceMetadata();
      if (!samePlanValue(before['snapshot'], approved.plan.snapshot.json) ||
          before['preservationFingerprint'] !=
              approved.preservationFingerprint) {
        return StageResult.fail('Boş alan planı değişti.');
      }
      await ctx.beforeFirstMutation?.call();
      if (!ctx.approvedStateMatches) {
        return StageResult.fail('Onaylanan boş alan planı değişti.');
      }
      final lines = <String>[];
      for (final role in ['esp', 'root']) {
        final spec = approved.plan.intentJson[role] as Map;
        final type = role == 'esp'
            ? FreeSpaceInstallationPlan.espTypeGuid
            : FreeSpaceInstallationPlan.linuxTypeGuid;
        final guid = role == 'esp' ? approved.espGuid : approved.rootGuid;
        final name = role == 'esp' ? 'RoASD_EFI' : 'RoASD_Root';
        lines.add(
          '${spec['number']} : start=${spec['startSector']}, size=${(spec['endSector'] as int) - (spec['startSector'] as int) + 1}, type=$type, uuid=$guid, name="$name"',
        );
      }
      final result = await ctx.commandRunner.run(
        'sfdisk',
        [
          '--append',
          '--no-reread',
          '--no-tell-kernel',
          '--wipe',
          'never',
          '--wipe-partitions',
          'never',
          selectedDisk,
        ],
        stdinText: '${lines.join('\n')}\n',
        isMock: ctx.isMock,
      );
      if (!result.started || result.exitCode != 0) {
        return StageResult.fail('Boş alanda bölüm oluşturulamadı.');
      }
      final rescan = await _rescanDisk(ctx, selectedDisk);
      if (rescan != null) return rescan;
      final after = await ctx.probeFreeSpaceMetadata();
      final layout = approved.verifyCreated(
        GptDiskSnapshot.fromJson(after['snapshot']),
        after['preservationFingerprint'] as String,
      );
      ctx.bindCreatedFreeSpaceLayout(layout);
      ctx.state['_resolvedRootPart'] = layout.rootPath;
      ctx.state['_resolvedEfiPart'] = layout.espPath;
      return StageResult.ok('Boş alanda EFI ve Btrfs bölümleri doğrulandı.');
    } catch (_) {
      return StageResult.fail('GPT koruma ve bölüm kimliği doğrulanamadı.');
    }
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
    String selectedDisk, {
    FullDiskPartitionWriter? fullWriter,
  }) async {
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
      if (ctx.approvedPlan != null) {
        if (fullWriter == null ||
            !await waitForFullDiskLayout(ctx, writer: fullWriter)) {
          return StageResult.fail('Onaylanan tam disk yerleşimi hazır değil.');
        }
      } else {
        await Future.delayed(const Duration(seconds: 2));
      }
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
