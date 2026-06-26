import 'dart:convert';

import 'stage_context.dart';
import 'stage_result.dart';

/// AŞAMA 1: Disk Hazırlığı
///
/// Kurulum öncesi diski hazırlar:
/// - Tüm mevcut bağlantıları (mount) kaldırır
/// - Swap alanlarını kapatır
///
/// Bu aşama, disk üzerinde güvenli bir şekilde çalışılabilmesi
/// için ön koşulları sağlar.
class DiskPreparationStage {
  const DiskPreparationStage();

  Future<StageResult> execute(StageContext ctx) async {
    final selectedDisk = ctx.state['selectedDisk'] as String;

    ctx.log('════════════════════════════════════════════');
    ctx.log('[AŞAMA 1] Disk Hazırlığı Başlatılıyor: $selectedDisk');
    ctx.log('════════════════════════════════════════════');

    ctx.progress(
      0.02,
      'stage_progress_disk_check_mounts',
      'Disk bağlantıları kontrol ediliyor...',
    );

    // 1. Diskteki hedef bölümlerin mevcut bağlantılarını ayır (umount)
    ctx.log('Diskteki mevcut bağlantılar kaldırılıyor...');
    final mountedPartitions = await _mountedTargetPartitions(ctx, selectedDisk);
    if (mountedPartitions == null) {
      return StageResult.fail(
        'Hedef disk bölümleri güvenli şekilde listelenemedi: $selectedDisk',
      );
    }
    if (mountedPartitions.isEmpty) {
      ctx.log('Hedef diskte ayrılacak aktif mount bulunamadı.');
    }
    for (final partition in mountedPartitions.reversed) {
      if (!await ctx.runCmd(
        'umount',
        ['-f', partition],
        ctx.log,
        isMock: ctx.isMock,
      )) {
        return StageResult.fail('Bölüm bağlantısı kaldırılamadı: $partition');
      }
    }

    // 2. Takas alanlarını kapat
    ctx.log('Takas (swap) alanları kapatılıyor...');
    await ctx.runCmd('swapoff', ['-a'], ctx.log, isMock: ctx.isMock);

    ctx.log('[AŞAMA 1] Disk hazırlığı tamamlandı.');
    return StageResult.ok(
      ctx.t('stage_result_disk_prepared', 'Disk hazırlığı tamamlandı: {disk}', {
        'disk': selectedDisk,
      }),
    );
  }

  Future<List<String>?> _mountedTargetPartitions(
    StageContext ctx,
    String selectedDisk,
  ) async {
    final result = await ctx.commandRunner.run('lsblk', [
      '-J',
      '-o',
      'NAME,TYPE,MOUNTPOINTS',
      selectedDisk,
    ], isMock: ctx.isMock);
    if (!result.started || result.exitCode != 0) {
      ctx.log('HATA: lsblk hedef disk bölümlerini listeleyemedi.');
      if (result.stderr.isNotEmpty) {
        ctx.log(result.stderr.trim());
      }
      return null;
    }

    if (result.stdout.trim().isEmpty) {
      return const [];
    }

    try {
      final decoded = jsonDecode(result.stdout) as Map<String, dynamic>;
      final devices = decoded['blockdevices'] as List<dynamic>? ?? const [];
      final mounted = <String>[];
      for (final rawDevice in devices) {
        if (rawDevice is Map<String, dynamic>) {
          _collectMountedPartitions(rawDevice, mounted);
        }
      }
      return mounted;
    } catch (e) {
      ctx.log('HATA: lsblk JSON çıktısı çözümlenemedi: $e');
      return null;
    }
  }

  void _collectMountedPartitions(
    Map<String, dynamic> device,
    List<String> mounted,
  ) {
    final type = (device['type'] ?? '').toString();
    final name = (device['name'] ?? '').toString();
    if (type == 'part' && name.isNotEmpty && _hasMountpoints(device)) {
      mounted.add(_devPath(name));
    }

    final children = device['children'] as List<dynamic>? ?? const [];
    for (final child in children) {
      if (child is Map<String, dynamic>) {
        _collectMountedPartitions(child, mounted);
      }
    }
  }

  bool _hasMountpoints(Map<String, dynamic> device) {
    final mountpoints = device['mountpoints'];
    if (mountpoints is Iterable) {
      return mountpoints.any((value) => value != null && '$value'.isNotEmpty);
    }
    final mountpoint = device['mountpoint'];
    if (mountpoint != null && '$mountpoint'.isNotEmpty) {
      return true;
    }
    return false;
  }

  String _devPath(String name) =>
      name.startsWith('/dev/') ? name : '/dev/$name';
}
