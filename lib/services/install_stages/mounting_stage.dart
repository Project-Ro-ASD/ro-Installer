import 'stage_context.dart';
import 'stage_result.dart';

/// AŞAMA 4: Bağlama (Mounting)
///
/// Biçimlendirilmiş bölümleri /mnt hedefine bağlar:
/// - BTRFS ise: @ ve @home subvolume'ları oluşturur ve bağlar
/// - EXT4/XFS ise: doğrudan bağlar
/// - EFI bölümünü /mnt/boot/efi'ye bağlar
/// - SWAP varsa aktif eder
class MountingStage {
  const MountingStage();

  Future<StageResult> execute(StageContext ctx) async {
    final selectedDisk = ctx.state['selectedDisk'] as String;
    final partitionMethod = ctx.state['partitionMethod'] as String;
    final String rootFs = ctx.state['fileSystem'] ?? 'btrfs';

    ctx.log('════════════════════════════════════════════');
    ctx.log('[AŞAMA 4] Bağlama Başlatılıyor (Hedef: /mnt)');
    ctx.log('════════════════════════════════════════════');

    // Önce mevcut /mnt bağlantılarını temizle
    ctx.onProgress(0.3, 'Bölümler (/mnt) hedefine bağlanıyor...');
    await ctx.runCmd('sh', ['-c', 'umount -R /mnt 2>/dev/null || true'], ctx.log, isMock: ctx.isMock);

    switch (partitionMethod) {
      case 'full':
        return _mountFullDisk(ctx, selectedDisk, rootFs);
      case 'alongside':
        return _mountAlongside(ctx, selectedDisk, rootFs);
      case 'manual':
        return _mountManualPartitions(ctx);
      default:
        return StageResult.fail('Bilinmeyen bölümleme yöntemi: $partitionMethod');
    }
  }

  /// Tam disk modunda bağlama
  Future<StageResult> _mountFullDisk(StageContext ctx, String selectedDisk, String rootFs) async {
    String efiPart = '${selectedDisk}1';
    String rootPart = '${selectedDisk}2';
    if (selectedDisk.contains('nvme') || selectedDisk.contains('loop')) {
      efiPart = '${selectedDisk}p1';
      rootPart = '${selectedDisk}p2';
    }

    // Root bölümünü bağla
    if (!await _mountRoot(ctx, rootPart, rootFs)) {
      return StageResult.fail('Root bölümü bağlanamadı: $rootPart');
    }

    // EFI bölümünü bağla
    if (!await _mountEfi(ctx, efiPart)) {
      return StageResult.fail('EFI bölümü bağlanamadı: $efiPart');
    }

    ctx.log('[AŞAMA 4] Tam disk bağlama tamamlandı.');
    return StageResult.ok('Tam disk bağlama tamamlandı.');
  }

  /// Alongside modunda bağlama
  Future<StageResult> _mountAlongside(StageContext ctx, String selectedDisk, String rootFs) async {
    final String rootPart = ctx.state['_resolvedRootPart'] ?? '';
    final String swapPart = ctx.state['_resolvedSwapPart'] ?? '';
    final bool hasExistingEfi = ctx.state['hasExistingEfi'] == true;
    final String existingEfiPart = (ctx.state['existingEfiPartition'] ?? '') as String;

    if (rootPart.isEmpty) {
      return StageResult.fail('Root bölüm yolu bulunamadı (formatting aşamasından gelmedi).');
    }

    // Root bölümünü bağla
    if (!await _mountRoot(ctx, rootPart, rootFs)) {
      return StageResult.fail('Root bölümü bağlanamadı: $rootPart');
    }

    // EFI bölümünü bağla (mevcut olanı kullan, formatlamadan)
    if (hasExistingEfi && existingEfiPart.isNotEmpty) {
      ctx.log('Mevcut EFI bölümü kullanılıyor (formatlanmayacak): $existingEfiPart');
      if (!await _mountEfi(ctx, existingEfiPart)) {
        return StageResult.fail('Mevcut EFI bölümü bağlanamadı: $existingEfiPart');
      }
    } else {
      ctx.log('UYARI: Mevcut EFI bulunamadı, bootloader kurulumu başarısız olabilir.');
    }

    // SWAP'ı aktif et
    if (swapPart.isNotEmpty) {
      await ctx.runCmd('swapon', [swapPart], ctx.log, isMock: ctx.isMock);
    }

    ctx.log('[AŞAMA 4] Alongside bağlama tamamlandı.');
    return StageResult.ok('Alongside bağlama tamamlandı.');
  }

  /// Manuel modda bağlama
  Future<StageResult> _mountManualPartitions(StageContext ctx) async {
    final manualPartitions = ctx.state['manualPartitions'] as List<dynamic>;

    // Önce root (/) bölümünü bul ve bağla
    var rootPart = manualPartitions.firstWhere(
      (p) => p['mount'] == '/',
      orElse: () => null,
    );
    if (rootPart == null) {
      return StageResult.fail('Root partisiz bir sistem! / montaj noktasını bulamadım.');
    }

    if (!await ctx.runCmd('mount', [rootPart['name'], '/mnt'], ctx.log, isMock: ctx.isMock)) {
      return StageResult.fail('Root bölümü bağlanamadı: ${rootPart['name']}');
    }

    // Diğer bölümleri bağla (/ ve SWAP hariç)
    for (var p in manualPartitions) {
      if (p['isFreeSpace'] == true || p['mount'] == '/' || p['mount'] == 'unmounted' || p['mount'] == '[SWAP]') continue;
      String mntPoint = '/mnt${p['mount']}';
      if (!await ctx.runCmd('mkdir', ['-p', mntPoint], ctx.log, isMock: ctx.isMock)) {
        return StageResult.fail('Bağlama noktası oluşturulamadı: $mntPoint');
      }
      if (!await ctx.runCmd('mount', [p['name'], mntPoint], ctx.log, isMock: ctx.isMock)) {
        return StageResult.fail('Bölüm bağlanamadı: ${p['name']} → $mntPoint');
      }
    }

    // SWAP bölümlerini aktif et
    for (var p in manualPartitions) {
      if (p['mount'] == '[SWAP]') {
        await ctx.runCmd('swapon', [p['name']], ctx.log, isMock: ctx.isMock);
      }
    }

    ctx.log('[AŞAMA 4] Manuel bölüm bağlama tamamlandı.');
    return StageResult.ok('Manuel bölüm bağlama tamamlandı.');
  }

  /// Root bölümünü bağlar. BTRFS ise subvolume oluşturur.
  Future<bool> _mountRoot(StageContext ctx, String rootPart, String rootFs) async {
    if (rootFs == 'btrfs') {
      // Önce geçici bağla, subvolume'ları oluştur
      if (!await ctx.runCmd('mount', [rootPart, '/mnt'], ctx.log, isMock: ctx.isMock)) return false;
      if (!await ctx.runCmd('btrfs', ['subvolume', 'create', '/mnt/@'], ctx.log, isMock: ctx.isMock)) return false;
      if (!await ctx.runCmd('btrfs', ['subvolume', 'create', '/mnt/@home'], ctx.log, isMock: ctx.isMock)) return false;
      await ctx.runCmd('umount', ['/mnt'], ctx.log, isMock: ctx.isMock);

      // Subvolume'ları bağla (fstab ile tutarlı seçenekler: compress=zstd:1)
      if (!await ctx.runCmd('mount', ['-o', 'subvol=@,compress=zstd:1', rootPart, '/mnt'], ctx.log, isMock: ctx.isMock)) return false;
      if (!await ctx.runCmd('mkdir', ['-p', '/mnt/home'], ctx.log, isMock: ctx.isMock)) return false;
      if (!await ctx.runCmd('mount', ['-o', 'subvol=@home,compress=zstd:1', rootPart, '/mnt/home'], ctx.log, isMock: ctx.isMock)) return false;
    } else {
      if (!await ctx.runCmd('mount', [rootPart, '/mnt'], ctx.log, isMock: ctx.isMock)) return false;
    }
    return true;
  }

  /// EFI bölümünü /mnt/boot/efi'ye bağlar
  Future<bool> _mountEfi(StageContext ctx, String efiPart) async {
    if (!await ctx.runCmd('mkdir', ['-p', '/mnt/boot/efi'], ctx.log, isMock: ctx.isMock)) return false;
    if (!await ctx.runCmd('mount', [efiPart, '/mnt/boot/efi'], ctx.log, isMock: ctx.isMock)) return false;
    return true;
  }
}
