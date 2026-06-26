import 'dart:convert';

import '../../models/storage_plan.dart';
import '../storage_topology_guard.dart';
import 'stage_context.dart';
import 'stage_result.dart';

/// AŞAMA 3: Biçimlendirme (Formatting)
///
/// Bölümleri dosya sistemiyle biçimlendirir:
/// - EFI → FAT32
/// - Root → BTRFS
/// - SWAP → linux-swap
/// - Manuel modda: Kullanıcının planladığı bölümler biçimlendirilir
class FormattingStage {
  const FormattingStage();

  Future<StageResult> execute(StageContext ctx) async {
    final selectedDisk = ctx.state['selectedDisk'] as String;
    final partitionMethod = ctx.state['partitionMethod'] as String;
    final String rootFs = ctx.state['fileSystem'] ?? 'btrfs';
    if (rootFs != 'btrfs') {
      return StageResult.fail(
        'Ro-ASD yalnızca Btrfs dosya sistemiyle kurulabilir: $rootFs',
      );
    }
    final topologyFailure = await _validateUnsupportedStorageTopology(
      ctx,
      selectedDisk,
    );
    if (topologyFailure != null) {
      return topologyFailure;
    }

    ctx.log('════════════════════════════════════════════');
    ctx.log(
      '[AŞAMA 3] Biçimlendirme Başlatılıyor (Dosya Sistemi: ${rootFs.toUpperCase()})',
    );
    ctx.log('════════════════════════════════════════════');

    late final StoragePlan storagePlan;
    try {
      storagePlan = StoragePlanBuilder.fromState(ctx.state);
      ctx.state['_formatStoragePlan'] = jsonEncode(storagePlan.toJson());
    } on StoragePlanException catch (e) {
      return StageResult.fail(e.message);
    }

    switch (partitionMethod) {
      case 'full':
        return _formatFullDisk(ctx, selectedDisk, rootFs, storagePlan);
      case 'alongside':
        return _formatAlongside(ctx, selectedDisk, rootFs, storagePlan);
      case 'free_space':
        return _formatAlongside(ctx, selectedDisk, rootFs, storagePlan);
      case 'manual':
        return _formatManualPartitions(ctx, storagePlan);
      default:
        return StageResult.fail(
          'Bilinmeyen bölümleme yöntemi: $partitionMethod',
        );
    }
  }

  /// Tam disk modunda EFI ve Root bölümlerini biçimlendirir
  Future<StageResult> _formatFullDisk(
    StageContext ctx,
    String selectedDisk,
    String rootFs,
    StoragePlan storagePlan,
  ) async {
    ctx.progress(
      0.2,
      'stage_progress_format_full_disk',
      'Bölümler biçimlendiriliyor... (${rootFs.toUpperCase()})',
      {'fs': rootFs.toUpperCase()},
    );

    final efiPart = _partitionPath(selectedDisk, 1);
    final swapPart = _partitionPath(selectedDisk, 2);
    final rootPart = _partitionPath(selectedDisk, 3);

    // EFI bölümünü FAT32 olarak biçimlendir
    var planFailure = _requirePlannedDestructiveOperation(
      storagePlan,
      type: 'format_efi',
      target: efiPart,
    );
    if (planFailure != null) return planFailure;
    if (!await ctx.runCmd(
      'mkfs.fat',
      ['-F32', efiPart],
      ctx.log,
      isMock: ctx.isMock,
    )) {
      return StageResult.fail('EFI bölümü biçimlendirilemedi: $efiPart');
    }

    planFailure = _requirePlannedDestructiveOperation(
      storagePlan,
      type: 'format_swap',
      target: swapPart,
    );
    if (planFailure != null) return planFailure;
    if (!await ctx.runCmd('mkswap', [swapPart], ctx.log, isMock: ctx.isMock)) {
      return StageResult.fail('SWAP bölümü biçimlendirilemedi: $swapPart');
    }

    // Root bölümünü seçilen dosya sistemiyle biçimlendir
    planFailure = _requirePlannedDestructiveOperation(
      storagePlan,
      type: 'format_btrfs_root',
      target: rootPart,
    );
    if (planFailure != null) return planFailure;
    if (!await _formatPartition(ctx, rootPart, rootFs)) {
      return StageResult.fail('Root bölümü biçimlendirilemedi: $rootPart');
    }

    ctx.state['_resolvedSwapPart'] = swapPart;
    ctx.state['_resolvedRootPart'] = rootPart;

    ctx.log('[AŞAMA 3] Tam disk biçimlendirme tamamlandı.');
    return StageResult.ok(
      ctx.t(
        'stage_result_format_full_done',
        'Tam disk biçimlendirme tamamlandı.',
      ),
    );
  }

  /// Alongside (yanına kurulum) modunda SWAP ve Root bölümlerini biçimlendirir
  Future<StageResult> _formatAlongside(
    StageContext ctx,
    String selectedDisk,
    String rootFs,
    StoragePlan storagePlan,
  ) async {
    ctx.progress(
      0.25,
      'stage_progress_format_alongside',
      'Yeni bölümler biçimlendiriliyor (${rootFs.toUpperCase()})...',
      {'fs': rootFs.toUpperCase()},
    );

    // Alongside modunda oluşturulan bölümleri bul
    String swapPart = '';
    String rootPart = '';
    final expectedSwapStart = ctx.state['_resolvedSwapStartSector'] as int?;
    final expectedRootStart = ctx.state['_resolvedRootStartSector'] as int?;

    try {
      final lsblkResult = await ctx.commandRunner.run('lsblk', [
        '-J',
        '-b',
        '-o',
        'NAME,PARTLABEL,START',
        selectedDisk,
      ]);
      if (lsblkResult.exitCode == 0) {
        final parsed = jsonDecode(lsblkResult.stdout);
        final devices = parsed['blockdevices'] as List<dynamic>;
        if (devices.isNotEmpty && devices.first.containsKey('children')) {
          final children = devices.first['children'] as List<dynamic>;
          for (var child in children) {
            final partLabel = (child['partlabel'] ?? '').toString();
            final childName = child['name'].toString();
            final childStart = child['start'] is int
                ? child['start'] as int
                : int.tryParse((child['start'] ?? '').toString());
            if (partLabel == 'RoASD_Swap' &&
                (expectedSwapStart == null ||
                    childStart == expectedSwapStart)) {
              swapPart = '/dev/$childName';
            }
            if (partLabel == 'RoASD_Root' &&
                (expectedRootStart == null ||
                    childStart == expectedRootStart)) {
              rootPart = '/dev/$childName';
            }
          }
        }
      }
    } catch (e) {
      ctx.log('UYARI: Bölüm etiketleri okunamadı, indeks bazlı deneniyor...');
    }

    // Etiket bazlı bulunamadıysa indeks bazlı dene
    if (swapPart.isEmpty || rootPart.isEmpty) {
      try {
        final sgResult = await ctx.commandRunner.run('sgdisk', [
          '-p',
          selectedDisk,
        ]);
        if (sgResult.exitCode == 0) {
          final lines = sgResult.stdout
              .split('\n')
              .where((l) => RegExp(r'^\s+\d+').hasMatch(l))
              .toList();
          if (lines.length >= 2) {
            final swapNum = lines[lines.length - 2].trim().split(
              RegExp(r'\s+'),
            )[0];
            final rootNum = lines[lines.length - 1].trim().split(
              RegExp(r'\s+'),
            )[0];
            final suffix =
                (selectedDisk.contains('nvme') || selectedDisk.contains('loop'))
                ? 'p'
                : '';
            swapPart = '$selectedDisk$suffix$swapNum';
            rootPart = '$selectedDisk$suffix$rootNum';
          }
        }
      } catch (e) {
        ctx.log('HATA: Bölümler bulunamadı: $e');
        return StageResult.fail('Alongside bölümleri bulunamadı.');
      }
    }

    if (swapPart.isEmpty || rootPart.isEmpty) {
      return StageResult.fail(
        'FATAL: Yeni oluşturulan SWAP ve ROOT bölümleri bulunamadı!',
      );
    }
    ctx.log('Bulunan bölümler → SWAP: $swapPart, ROOT: $rootPart');

    // SWAP biçimlendir
    var planFailure = _requirePlannedDestructiveOperation(
      storagePlan,
      type: 'create_swap',
      target: selectedDisk,
    );
    if (planFailure != null) return planFailure;
    if (!await ctx.runCmd('mkswap', [swapPart], ctx.log, isMock: ctx.isMock)) {
      return StageResult.fail('SWAP bölümü biçimlendirilemedi: $swapPart');
    }

    // Root biçimlendir
    planFailure = _requirePlannedDestructiveOperation(
      storagePlan,
      type: 'create_btrfs_root',
      target: selectedDisk,
    );
    if (planFailure != null) return planFailure;
    if (!await _formatPartition(ctx, rootPart, rootFs)) {
      return StageResult.fail('Root bölümü biçimlendirilemedi: $rootPart');
    }

    // Bulunan bölüm yollarını state'e ekle (bağlama aşaması için)
    ctx.state['_resolvedSwapPart'] = swapPart;
    ctx.state['_resolvedRootPart'] = rootPart;

    ctx.log('[AŞAMA 3] Alongside biçimlendirme tamamlandı.');
    return StageResult.ok(
      ctx.t(
        'stage_result_format_alongside_done',
        'Alongside biçimlendirme tamamlandı.',
      ),
    );
  }

  /// Manuel modda kullanıcının planladığı bölümleri biçimlendirir
  Future<StageResult> _formatManualPartitions(
    StageContext ctx,
    StoragePlan storagePlan,
  ) async {
    final manualPartitions = ctx.state['manualPartitions'] as List<dynamic>;

    ctx.progress(
      0.1,
      'stage_progress_format_manual_plan',
      'Kullanıcının disk yapılandırma planı uygulanıyor...',
    );

    for (var p in manualPartitions) {
      if (p['isFreeSpace'] == true || p['isPlanned'] != true) continue;

      final partName = (p['name'] ?? '').toString();
      if (partName.isEmpty) {
        continue;
      }

      final formatOnInstall = p.containsKey('formatOnInstall')
          ? p['formatOnInstall'] == true
          : true;
      if (!formatOnInstall) {
        ctx.log('Mevcut bölüm korunuyor, biçimlendirme atlandı: $partName');
        continue;
      }

      final fsType = _normalizeFsType((p['type'] ?? '').toString());

      final planFailure = _requirePlannedDestructiveOperation(
        storagePlan,
        type: 'format_partition',
        target: partName,
        details: {
          'mount': (p['mount'] ?? 'unmounted').toString(),
          'fsType': (p['type'] ?? '').toString(),
          'formatOnInstall': true,
        },
      );
      if (planFailure != null) return planFailure;
      if (!await _formatPartition(ctx, partName, fsType)) {
        return StageResult.fail(
          'Bölüm biçimlendirilemedi: $partName ($fsType)',
        );
      }
    }

    ctx.log('[AŞAMA 3] Manuel bölüm biçimlendirme tamamlandı.');
    return StageResult.ok(
      ctx.t(
        'stage_result_format_manual_done',
        'Manuel bölüm biçimlendirme tamamlandı.',
      ),
    );
  }

  /// Belirtilen bölümü verilen dosya sistemiyle biçimlendirir
  Future<bool> _formatPartition(
    StageContext ctx,
    String partition,
    String fsType,
  ) async {
    switch (fsType) {
      case 'fat32':
      case 'vfat':
        return ctx.runCmd(
          'mkfs.fat',
          ['-F32', partition],
          ctx.log,
          isMock: ctx.isMock,
        );
      case 'btrfs':
        return ctx.runCmd(
          'mkfs.btrfs',
          ['-f', partition],
          ctx.log,
          isMock: ctx.isMock,
        );
      case 'linux-swap':
      case 'swap':
        return ctx.runCmd('mkswap', [partition], ctx.log, isMock: ctx.isMock);
      default:
        ctx.log('HATA: Desteklenmeyen dosya sistemi türü: $fsType');
        return false;
    }
  }

  String _normalizeFsType(String fsType) {
    switch (fsType) {
      case 'vfat':
        return 'fat32';
      case 'swap':
        return 'linux-swap';
      case 'btrfs':
      case 'fat32':
      case 'linux-swap':
        return fsType;
      default:
        return 'unsupported';
    }
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
      'Storage plan dışı destructive format işlemi engellendi: $type -> $target',
    );
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
        'Disk topolojisi dogrulanamadi; format islemi baslatilmadi: '
        '${report.inspectionError}',
      );
    }
    if (!report.hasBlockers) {
      return null;
    }
    return StageResult.fail(unsupportedStorageTopologyMessage(report));
  }

  String _partitionPath(String disk, int partitionNumber) {
    final needsP =
        disk.contains('nvme') ||
        disk.contains('loop') ||
        disk.contains('mmcblk');
    return needsP ? '${disk}p$partitionNumber' : '$disk$partitionNumber';
  }
}
