import 'stage_context.dart';
import 'stage_result.dart';

/// AŞAMA 5: Dosya Kopyalama (File Copy / Rsync)
///
/// Live işletim sisteminin kök dosya sistemini hedef diske kopyalar:
/// - Sanal dosya sistemlerini (tmpfs, proc, sys vb.) dışlar
/// - xattr desteklemeyen dosya sistemlerini (vfat, ntfs vb.) ayrıca kopyalar
/// - /boot/efi dizinini her zaman özel olarak ele alır
class FileCopyStage {
  const FileCopyStage();

  Future<StageResult> execute(StageContext ctx) async {
    ctx.log('════════════════════════════════════════════');
    ctx.log('[AŞAMA 5] Dosya Kopyalama Başlatılıyor');
    ctx.log('════════════════════════════════════════════');

    // ── Dinamik dışlama listesi oluştur ──
    ctx.onProgress(0.4, 'Dinamik bağlama noktaları ve xattr desteği taranıyor...');

    List<String> dynamicExcludes = [];
    List<String> noXattrDirs = []; // Ayrıca kopyalanacak (vfat, ntfs vb.)

    try {
      final findmntResult = await ctx.commandRunner.run('findmnt', ['-rn', '-o', 'TARGET,FSTYPE']);
      if (findmntResult.exitCode == 0) {
        final lines = findmntResult.stdout.split('\n');
        const virtualFs = 'tmpfs|devtmpfs|proc|sysfs|cgroup|cgroup2|pstore|efivarfs';
        const noXattrFs = 'vfat|fat32|ntfs|ntfs-3g|exfat';

        for (var line in lines) {
          final parts = line.trim().split(RegExp(r'\s+'));
          if (parts.length < 2) continue;
          final target = parts[0];
          final fsType = parts[1];

          // "/" (root) veya "/mnt" (target) dışındakileri kontrol et
          if (target == '/' || target.startsWith('/mnt') || target.startsWith('/media/RoASD')) continue;

          if (RegExp(virtualFs).hasMatch(fsType)) {
            dynamicExcludes.add('--exclude=$target/*');
            dynamicExcludes.add('--exclude=$target');
          } else if (RegExp(noXattrFs).hasMatch(fsType)) {
            dynamicExcludes.add('--exclude=$target/*');
            dynamicExcludes.add('--exclude=$target');
            noXattrDirs.add(target);
          }
        }
      }
    } catch (e) {
      ctx.log('UYARI: findmnt taraması başarısız oldu, varsayılan kopyalama yapılıyor.');
    }

    // /boot/efi dizinini her halükarda dışla ve kopyalanacaklar listesine ekle
    if (!noXattrDirs.contains('/boot/efi')) {
      dynamicExcludes.add('--exclude=/boot/efi/*');
      dynamicExcludes.add('--exclude=/boot/efi');
      noXattrDirs.add('/boot/efi');
    }

    // ── Ana rsync kopyalama ──
    ctx.onProgress(0.41, 'Live İşletim Sistemi kök dosya hedef diske aktarılıyor...');
    ctx.onProgress(0.42, 'Bu işlem disk hızına bağlı olarak 5-15 dakika sürebilir. (Rsync Çalışıyor...)');

    List<String> rsyncArgs = [
      '-aAX',
      '--exclude=/dev/*',
      '--exclude=/proc/*',
      '--exclude=/sys/*',
      '--exclude=/tmp/*',
      '--exclude=/run/*',
      '--exclude=/mnt/*',
      '--exclude=/media/*',
      '--exclude=/lost+found',
      '--exclude=/etc/machine-id',
      '--exclude=/etc/kernel/cmdline',
      '--exclude=/var/log/audit/*',
      '--exclude=/boot/loader/entries/*',
      '--exclude=/boot/grub2/grubenv',
      ...dynamicExcludes,
      '/',   // Kaynak: Çalışan Live Kök
      '/mnt/' // Hedef
    ];

    bool rsyncOk = await ctx.runCmd('rsync', rsyncArgs, ctx.log, isMock: ctx.isMock, allowedExitCodes: [0, 23]);

    if (!rsyncOk) {
      ctx.log('Ana Rsync işlemi başarısız oldu (Hata Kodu 23 uyarısı dahi geçilemedi).');
      return StageResult.fail('Dosya kopyalama (rsync) başarısız oldu.');
    }

    // ── xattr desteklemeyenler için ikincil kopyalama ──
    for (var dir in noXattrDirs) {
      ctx.onProgress(-1.0, '$dir ayrıca kopyalanıyor (xattr\'sız)...');
      await ctx.runCmd('mkdir', ['-p', '/mnt$dir'], ctx.log, isMock: ctx.isMock);
      await ctx.runCmd('rsync', ['-aA', '--no-xattrs', '$dir/', '/mnt$dir/'], ctx.log, isMock: ctx.isMock);
    }

    ctx.log('[AŞAMA 5] Dosya kopyalama tamamlandı.');
    return StageResult.ok('Dosya kopyalama tamamlandı.');
  }
}
