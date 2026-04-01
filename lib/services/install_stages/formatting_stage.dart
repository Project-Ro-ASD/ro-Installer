import 'dart:convert';
import 'stage_context.dart';
import 'stage_result.dart';

/// AŞAMA 3: Biçimlendirme (Formatting)
///
/// Bölümleri dosya sistemiyle biçimlendirir:
/// - EFI → FAT32
/// - Root → BTRFS / EXT4 / XFS (kullanıcı seçimine göre)
/// - SWAP → linux-swap
/// - Manuel modda: Kullanıcının planladığı bölümler biçimlendirilir
class FormattingStage {
  const FormattingStage();

  Future<StageResult> execute(StageContext ctx) async {
    final selectedDisk = ctx.state['selectedDisk'] as String;
    final partitionMethod = ctx.state['partitionMethod'] as String;
    final String rootFs = ctx.state['fileSystem'] ?? 'btrfs';

    ctx.log('════════════════════════════════════════════');
    ctx.log('[AŞAMA 3] Biçimlendirme Başlatılıyor (Dosya Sistemi: ${rootFs.toUpperCase()})');
    ctx.log('════════════════════════════════════════════');

    switch (partitionMethod) {
      case 'full':
        return _formatFullDisk(ctx, selectedDisk, rootFs);
      case 'alongside':
        return _formatAlongside(ctx, selectedDisk, rootFs);
      case 'manual':
        return _formatManualPartitions(ctx);
      default:
        return StageResult.fail('Bilinmeyen bölümleme yöntemi: $partitionMethod');
    }
  }

  /// Tam disk modunda EFI ve Root bölümlerini biçimlendirir
  Future<StageResult> _formatFullDisk(StageContext ctx, String selectedDisk, String rootFs) async {
    ctx.onProgress(0.2, 'Bölümler biçimlendiriliyor... (${rootFs.toUpperCase()})');

    String efiPart = '${selectedDisk}1';
    String rootPart = '${selectedDisk}2';
    if (selectedDisk.contains('nvme') || selectedDisk.contains('loop')) {
      efiPart = '${selectedDisk}p1';
      rootPart = '${selectedDisk}p2';
    }

    // EFI bölümünü FAT32 olarak biçimlendir
    if (!await ctx.runCmd('mkfs.fat', ['-F32', efiPart], ctx.log, isMock: ctx.isMock)) {
      return StageResult.fail('EFI bölümü biçimlendirilemedi: $efiPart');
    }

    // Root bölümünü seçilen dosya sistemiyle biçimlendir
    if (!await _formatPartition(ctx, rootPart, rootFs)) {
      return StageResult.fail('Root bölümü biçimlendirilemedi: $rootPart');
    }

    ctx.log('[AŞAMA 3] Tam disk biçimlendirme tamamlandı.');
    return StageResult.ok('Tam disk biçimlendirme tamamlandı.');
  }

  /// Alongside (yanına kurulum) modunda SWAP ve Root bölümlerini biçimlendirir
  Future<StageResult> _formatAlongside(StageContext ctx, String selectedDisk, String rootFs) async {
    ctx.onProgress(0.25, 'Yeni bölümler biçimlendiriliyor (${rootFs.toUpperCase()})...');

    // Alongside modunda oluşturulan bölümleri bul
    String swapPart = '';
    String rootPart = '';

    try {
      final lsblkResult = await ctx.commandRunner.run('lsblk', ['-J', '-b', '-o', 'NAME,PARTLABEL', selectedDisk]);
      if (lsblkResult.exitCode == 0) {
        final parsed = jsonDecode(lsblkResult.stdout);
        final devices = parsed['blockdevices'] as List<dynamic>;
        if (devices.isNotEmpty && devices.first.containsKey('children')) {
          final children = devices.first['children'] as List<dynamic>;
          for (var child in children) {
            final partLabel = (child['partlabel'] ?? '').toString();
            final childName = child['name'].toString();
            if (partLabel == 'RoASD_Swap') swapPart = '/dev/$childName';
            if (partLabel == 'RoASD_Root') rootPart = '/dev/$childName';
          }
        }
      }
    } catch (e) {
      ctx.log('UYARI: Bölüm etiketleri okunamadı, indeks bazlı deneniyor...');
    }

    // Etiket bazlı bulunamadıysa indeks bazlı dene
    if (swapPart.isEmpty || rootPart.isEmpty) {
      try {
        final sgResult = await ctx.commandRunner.run('sgdisk', ['-p', selectedDisk]);
        if (sgResult.exitCode == 0) {
          final lines = sgResult.stdout.split('\n').where((l) => RegExp(r'^\s+\d+').hasMatch(l)).toList();
          if (lines.length >= 2) {
            final swapNum = lines[lines.length - 2].trim().split(RegExp(r'\s+'))[0];
            final rootNum = lines[lines.length - 1].trim().split(RegExp(r'\s+'))[0];
            final suffix = (selectedDisk.contains('nvme') || selectedDisk.contains('loop')) ? 'p' : '';
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
      return StageResult.fail('FATAL: Yeni oluşturulan SWAP ve ROOT bölümleri bulunamadı!');
    }
    ctx.log('Bulunan bölümler → SWAP: $swapPart, ROOT: $rootPart');

    // SWAP biçimlendir
    if (!await ctx.runCmd('mkswap', [swapPart], ctx.log, isMock: ctx.isMock)) {
      return StageResult.fail('SWAP bölümü biçimlendirilemedi: $swapPart');
    }

    // Root biçimlendir
    if (!await _formatPartition(ctx, rootPart, rootFs)) {
      return StageResult.fail('Root bölümü biçimlendirilemedi: $rootPart');
    }

    // Bulunan bölüm yollarını state'e ekle (bağlama aşaması için)
    ctx.state['_resolvedSwapPart'] = swapPart;
    ctx.state['_resolvedRootPart'] = rootPart;

    ctx.log('[AŞAMA 3] Alongside biçimlendirme tamamlandı.');
    return StageResult.ok('Alongside biçimlendirme tamamlandı.');
  }

  /// Manuel modda kullanıcının planladığı bölümleri biçimlendirir
  Future<StageResult> _formatManualPartitions(StageContext ctx) async {
    final manualPartitions = ctx.state['manualPartitions'] as List<dynamic>;

    ctx.onProgress(0.1, 'Kullanıcının disk yapılandırma planı uygulanıyor...');

    for (var p in manualPartitions) {
      if (p['isFreeSpace'] == true || p['isPlanned'] != true) continue;
      String partName = p['name'];
      String fsType = p['type'];

      if (!await _formatPartition(ctx, partName, fsType)) {
        return StageResult.fail('Bölüm biçimlendirilemedi: $partName ($fsType)');
      }
    }

    ctx.log('[AŞAMA 3] Manuel bölüm biçimlendirme tamamlandı.');
    return StageResult.ok('Manuel bölüm biçimlendirme tamamlandı.');
  }

  /// Belirtilen bölümü verilen dosya sistemiyle biçimlendirir
  Future<bool> _formatPartition(StageContext ctx, String partition, String fsType) async {
    switch (fsType) {
      case 'fat32':
        return ctx.runCmd('mkfs.fat', ['-F32', partition], ctx.log, isMock: ctx.isMock);
      case 'btrfs':
        return ctx.runCmd('mkfs.btrfs', ['-f', partition], ctx.log, isMock: ctx.isMock);
      case 'ext4':
        return ctx.runCmd('mkfs.ext4', ['-F', partition], ctx.log, isMock: ctx.isMock);
      case 'xfs':
        return ctx.runCmd('mkfs.xfs', ['-f', partition], ctx.log, isMock: ctx.isMock);
      case 'linux-swap':
        return ctx.runCmd('mkswap', [partition], ctx.log, isMock: ctx.isMock);
      default:
        ctx.log('UYARI: Bilinmeyen dosya sistemi türü: $fsType — biçimlendirme atlanıyor.');
        return true;
    }
  }
}
