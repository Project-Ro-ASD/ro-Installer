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

  Future<StageResult> execute(StageContext ctx) async {
    final selectedDisk = ctx.state['selectedDisk'] as String;
    final partitionMethod = ctx.state['partitionMethod'] as String;

    ctx.log('════════════════════════════════════════════');
    ctx.log('[AŞAMA 2] Bölümleme Başlatılıyor: $selectedDisk (Yöntem: $partitionMethod)');
    ctx.log('════════════════════════════════════════════');

    switch (partitionMethod) {
      case 'full':
        return _fullDiskPartition(ctx, selectedDisk);
      case 'alongside':
        return _alongsidePartition(ctx, selectedDisk);
      case 'manual':
        return _manualPartition(ctx, selectedDisk);
      default:
        return StageResult.fail('Bilinmeyen bölümleme yöntemi: $partitionMethod');
    }
  }

  /// Tüm diski silip yeniden bölümlendirir: EFI (512MB) + Root (kalan)
  Future<StageResult> _fullDiskPartition(StageContext ctx, String selectedDisk) async {
    ctx.onProgress(0.05, 'Disk sıfırlanıyor ve bağlantılar kesiliyor...');

    // Wipefs ile disk imzalarını temizle
    await ctx.runCmd('wipefs', ['-a', selectedDisk], ctx.log, isMock: ctx.isMock);

    ctx.onProgress(0.1, 'Tüm disk sıfırlanıyor ve yapılandırılıyor: $selectedDisk');

    // GPT tablosunu sıfırla
    if (!await ctx.runCmd('sgdisk', ['-Z', selectedDisk], ctx.log, isMock: ctx.isMock)) {
      return StageResult.fail('Disk GPT tablosu sıfırlanamadı: $selectedDisk');
    }

    // Bölüm 1: EFI System Partition (512MB)
    if (!await ctx.runCmd('sgdisk', ['-n', '1:0:+512M', '-t', '1:ef00', selectedDisk], ctx.log, isMock: ctx.isMock)) {
      return StageResult.fail('EFI bölümü oluşturulamadı.');
    }

    // Bölüm 2: Root (kalan alan)
    if (!await ctx.runCmd('sgdisk', ['-n', '2:0:0', selectedDisk], ctx.log, isMock: ctx.isMock)) {
      return StageResult.fail('Root bölümü oluşturulamadı.');
    }

    // Kernel'ın yeni bölüm tablosunu okuması için bekle
    await ctx.runCmd('partprobe', [selectedDisk], ctx.log, isMock: ctx.isMock);
    await Future.delayed(Duration(seconds: ctx.isMock ? 0 : 3));

    ctx.log('[AŞAMA 2] Tam disk bölümleme tamamlandı.');
    return StageResult.ok('Tam disk bölümleme tamamlandı: EFI + Root');
  }

  /// Mevcut sisteme zarar vermeden yanına SWAP + Root bölümleri oluşturur
  Future<StageResult> _alongsidePartition(StageContext ctx, String selectedDisk) async {
    final double linuxGB = (ctx.state['linuxDiskSizeGB'] as num?)?.toDouble() ?? 60.0;

    ctx.onProgress(0.05, 'Güvenlik: Mevcut bölüm tablosu yedekleniyor...');
    await ctx.runCmd('sgdisk', ['--backup=/tmp/gpt_backup_alongside.bin', selectedDisk], ctx.log, isMock: ctx.isMock);

    // RAM'e göre SWAP boyutu hesapla
    final int ramMB = await _getSystemRamMB(ctx);
    final int swapMB = _calculateSwapMB(ramMB);
    final int swapGB = (swapMB / 1024).ceil();
    ctx.log('Sistem RAM: ${ramMB}MB → Hesaplanan SWAP: ${swapMB}MB (${swapGB}GB)');

    // SWAP bölümü oluştur
    ctx.onProgress(0.1, 'SWAP bölümü oluşturuluyor ($swapGB GB, RAM: ${(ramMB / 1024).toStringAsFixed(1)} GB)...');
    if (!await ctx.runCmd('sgdisk', ['-n', '0:0:+${swapGB}G', '-t', '0:8200', '-c', '0:RoASD_Swap', selectedDisk], ctx.log, isMock: ctx.isMock)) {
      ctx.log('HATA: SWAP bölümü oluşturulamadı. Yedeklenen tablo: /tmp/gpt_backup_alongside.bin');
      return StageResult.fail('SWAP bölümü oluşturulamadı.');
    }

    // Root bölümü oluştur
    int rootGB = (linuxGB - swapGB).toInt();
    if (rootGB < 40) rootGB = 40;
    ctx.onProgress(0.15, 'Kök dizin (Root) bölümü oluşturuluyor ($rootGB GB)...');
    if (!await ctx.runCmd('sgdisk', ['-n', '0:0:+${rootGB}G', '-t', '0:8300', '-c', '0:RoASD_Root', selectedDisk], ctx.log, isMock: ctx.isMock)) {
      ctx.log('HATA: Root bölümü oluşturulamadı. Yedeklenen tablo: /tmp/gpt_backup_alongside.bin');
      return StageResult.fail('Root bölümü oluşturulamadı.');
    }

    // Kernel'ın yeni bölüm tablosunu okuması için bekle
    await ctx.runCmd('partprobe', [selectedDisk], ctx.log, isMock: ctx.isMock);
    await Future.delayed(Duration(seconds: ctx.isMock ? 0 : 3));

    ctx.log('[AŞAMA 2] Yanına kurulum bölümleme tamamlandı.');
    return StageResult.ok('Yanına kurulum bölümleme tamamlandı: SWAP + Root');
  }

  /// UI üzerinden oluşturulmuş 'manualPartitions' listesini fiziksel diske uygular
  Future<StageResult> _manualPartition(StageContext ctx, String selectedDisk) async {
    final manualPartitions = ctx.state['manualPartitions'] as List<dynamic>? ?? [];
    if (manualPartitions.isEmpty) {
      return StageResult.fail('Manuel bölümleme planı boş.');
    }
    
    ctx.onProgress(0.05, 'Manuel plan diske uygulanıyor...');

    // 1. Mevcut bölümleri tespit et (Silinenleri bulmak için)
    final currentPartsResult = await ctx.commandRunner.run('lsblk', ['-rn', '-o', 'NAME,TYPE', selectedDisk]);
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
    final plannedNames = manualPartitions.map((p) => p['name'] as String).toList();
    for (var currentName in originalPartNames) {
      if (!plannedNames.contains(currentName)) {
        // Bölüm numarasını bul (sda1 -> 1, nvme0n1p2 -> 2)
        final match = RegExp(r'(\d+)$').firstMatch(currentName);
        if (match != null) {
          final partNum = match.group(1)!;
          ctx.log('Bölüm siliniyor: $currentName (No: $partNum)');
          if (!await ctx.runCmd('sgdisk', ['-d', partNum, selectedDisk], ctx.log, isMock: ctx.isMock)) {
             return StageResult.fail('Bölüm silinemedi: $currentName');
          }
        }
      }
    }

    // Disk tablosunu güncelle
    await ctx.runCmd('partprobe', [selectedDisk], ctx.log, isMock: ctx.isMock);
    if (!ctx.isMock) await Future.delayed(const Duration(seconds: 1));

    // 3. YENİ Bölümleri oluştur
    // Oluşturulmuş bölümleri takip etmek için (aktifler listesi)
    final activePartNames = List<String>.from(originalPartNames)..removeWhere((n) => !plannedNames.contains(n));

    for (var i = 0; i < manualPartitions.length; i++) {
      final p = manualPartitions[i] as Map<String, dynamic>;
      if (p['isFreeSpace'] == true) continue;
      
      final name = p['name'] as String;
      
      if (p['isResized'] == true) {
         ctx.log('UYARI: Bölüm boyutlandırma (Resize) canlı kurulumda desteklenmez. Bölüm ($name) orijinal boyutunda kalacaktır.');
      }
      
      // UI tarafından 'New Partition' olarak isimlendirilmiş yeni bölümler
      if (name.startsWith('New Partition') || name == 'New Partition') {
        final sizeBytes = p['sizeBytes'] as int;
        final sizeMB = (sizeBytes / (1024 * 1024)).ceil();
        
        final fsType = p['type'] as String;
        String typeCode = '8300'; // Linux filesystem
        if (fsType == 'fat32') typeCode = 'ef00'; // EFI
        if (fsType == 'linux-swap') typeCode = '8200'; // SWAP
        
        ctx.onProgress(0.1 + (i * 0.05), 'Yeni bölüm oluşturuluyor: ${sizeMB}MB ($fsType)');
        
        // Bölümü diske yaz
        if (!await ctx.runCmd('sgdisk', ['-n', '0:0:+${sizeMB}M', '-t', '0:$typeCode', selectedDisk], ctx.log, isMock: ctx.isMock)) {
           return StageResult.fail('Bölüm oluşturulamadı: ${sizeMB}MB');
        }
        
        await ctx.runCmd('partprobe', [selectedDisk], ctx.log, isMock: ctx.isMock);
        if (!ctx.isMock) await Future.delayed(const Duration(seconds: 2));
        
        // Yeni oluşan bölümün gerçek (/dev/sdX) adını bul
        final newPartsResult = await ctx.commandRunner.run('lsblk', ['-rn', '-o', 'NAME,TYPE', selectedDisk]);
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
           p['name'] = newPartName; // Format aşamasının kullanabilmesi için ismi referanstan güncelliyoruz
        } else {
           if (!ctx.isMock) return StageResult.fail('Yeni bölüm oluşturuldu ancak adı tespit edilemedi.');
           p['name'] = '${selectedDisk}X'; // Mock testi için sahte isim
        }
      }
    }

    ctx.log('[AŞAMA 2] Manuel bölümleme fiziksel diske uygulandı.');
    return StageResult.ok('Manuel bölümleme planı diske uygulandı.');
  }

  /// Sistem RAM miktarını MB cinsinden okur (/proc/meminfo)
  Future<int> _getSystemRamMB(StageContext ctx) async {
    try {
      final result = await ctx.commandRunner.run('grep', ['MemTotal', '/proc/meminfo']);
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

  /// RAM'e göre dinamik SWAP boyutu hesaplar (MB cinsinden)
  int _calculateSwapMB(int ramMB) {
    if (ramMB <= 2048) return ramMB * 2;
    if (ramMB <= 8192) return ramMB;
    if (ramMB <= 16384) return ramMB ~/ 2;
    return 8192; // 8 GB üst sınır
  }
}
