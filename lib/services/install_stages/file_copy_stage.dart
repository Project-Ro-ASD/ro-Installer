import 'dart:convert';

import 'stage_context.dart';
import 'stage_result.dart';

/// AŞAMA 5: Dosya Kopyalama (File Copy / Rsync)
///
/// Live işletim sisteminin kök dosya sistemini hedef diske kopyalar:
/// - Sanal dosya sistemlerini (tmpfs, proc, sys vb.) dışlar
/// - Yabancı mount'ları dışlar; belirsiz sistem mount'larında durur
/// - Prepared-root /boot/efi dizinini xattr'sız, zorunlu kontrolle kopyalar
class FileCopyStage {
  const FileCopyStage();

  Future<StageResult> execute(StageContext ctx) async {
    ctx.log('════════════════════════════════════════════');
    ctx.log('[AŞAMA 5] Dosya Kopyalama Başlatılıyor');
    ctx.log('════════════════════════════════════════════');

    // ── Dinamik dışlama listesi oluştur ──
    ctx.progress(
      0.4,
      'stage_progress_copy_scan_mounts',
      'Dinamik bağlama noktaları ve xattr desteği taranıyor...',
    );

    // The prepared KIWI root includes /boot and its EFI payload. Mounts
    // outside that root are not additional installation sources.
    final dynamicExcludes = await inspectSource(ctx);
    if (dynamicExcludes == null) {
      return StageResult.fail(
        'Kaynak bağlama topolojisi doğrulanamadı; kopyalama durduruldu.',
      );
    }
    for (final path in requiredFiles) {
      if (!await _hasFile(ctx, path)) {
        return StageResult.fail('Zorunlu kaynak dosyası okunamadı: $path');
      }
    }

    // ── Ana rsync kopyalama ──
    ctx.progress(
      0.41,
      'stage_progress_copy_live_root',
      'Live İşletim Sistemi kök dosya hedef diske aktarılıyor...',
    );
    ctx.progress(
      0.42,
      'stage_progress_copy_rsync_duration',
      'Bu işlem disk hızına bağlı olarak 5-15 dakika sürebilir. (Rsync Çalışıyor...)',
    );

    List<String> rsyncArgs = [
      '-aAX',
      '--numeric-ids',
      '--info=progress2,stats2',
      '--human-readable',
      '--exclude=/dev/*',
      '--exclude=/proc/*',
      '--exclude=/sys/*',
      '--exclude=/tmp/*',
      '--exclude=/run/*',
      '--exclude=/mnt/*',
      '--exclude=/media/*',
      '--exclude=/lost+found',
      '--exclude=/.cache/*',
      '--exclude=/etc/machine-id',
      '--exclude=/var/lib/dbus/machine-id',
      '--exclude=/etc/hostname',
      '--exclude=/etc/kernel/cmdline',
      '--exclude=/home/*/.cache/*',
      '--exclude=/home/liveuser',
      '--exclude=/root/.cache/*',
      '--exclude=/var/cache/dnf/*',
      '--exclude=/var/cache/PackageKit/*',
      '--exclude=/var/tmp/*',
      '--exclude=/var/log/audit/*',
      '--exclude=/boot/loader/entries/*',
      '--exclude=/boot/grub2/grubenv',
      ...dynamicExcludes,
      '/', // Kaynak: Çalışan Live Kök
      '/mnt/', // Hedef
    ];

    if (!await _copy(ctx, 'copy.main', rsyncArgs)) {
      return StageResult.fail(
        'Ana dosya aktarımı başarısız; eksik veya kısmi kopya kabul edilmedi.',
      );
    }
    for (final path in requiredFiles.where(
      (p) => !p.startsWith('/boot/efi/'),
    )) {
      if (!await _hasFile(ctx, '/mnt$path')) {
        return StageResult.fail('Zorunlu hedef dosyası eksik: $path');
      }
    }

    // Only the prepared EFI directory is a secondary source. In particular,
    // arbitrary FAT/NTFS/removable mounts must never be imported here.
    const dir = '/boot/efi';
    ctx.progress(
      -1.0,
      'stage_progress_copy_extra_dir',
      "$dir ayrıca kopyalanıyor (xattr'sız)...",
      {'dir': dir},
    );
    if (!await _runChecked(ctx, 'mkdir', ['-p', '/mnt$dir'])) {
      return StageResult.fail('EFI hedef dizini oluşturulamadı: $dir');
    }
    if (!await _copy(ctx, 'copy.efi', [
      '-aA',
      '--numeric-ids',
      '--no-xattrs',
      '$dir/',
      '/mnt$dir/',
    ])) {
      return StageResult.fail('EFI dosya aktarımı başarısız: $dir');
    }
    for (final path in requiredFiles.where((p) => p.startsWith('/boot/efi/'))) {
      if (!await _hasFile(ctx, '/mnt$path')) {
        return StageResult.fail('Zorunlu EFI hedef dosyası eksik: $path');
      }
    }

    ctx.log('[AŞAMA 5] Dosya kopyalama tamamlandı.');
    return StageResult.ok(
      ctx.t('stage_result_copy_done', 'Dosya kopyalama tamamlandı.'),
    );
  }

  static const requiredFiles = [
    '/usr/lib/os-release',
    '/usr/lib/systemd/systemd',
    '/boot/efi/EFI/fedora/shimx64.efi',
    '/boot/efi/EFI/fedora/grubx64.efi',
  ];

  Future<bool> _hasFile(StageContext ctx, String path) async {
    try {
      for (final flag in ['-f', '-s']) {
        final result = await ctx.commandRunner.run('test', [
          flag,
          path,
        ], isMock: ctx.isMock);
        if (!result.started || result.exitCode != 0) return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _copy(
    StageContext ctx,
    String operation,
    List<String> args,
  ) async {
    final observer = ctx.observation;
    if (observer == null) return _runChecked(ctx, 'rsync', args);
    return observer.span(
      operation,
      () => _runChecked(ctx, 'rsync', args),
      success: (ok) => ok,
    );
  }

  Future<bool> _runChecked(
    StageContext ctx,
    String cmd,
    List<String> args,
  ) async {
    try {
      // Raw filenames/stderr can contain secrets. Report only the fixed
      // operation failure above; do not introduce another raw-output channel.
      return await ctx.runCmd(
        cmd,
        args,
        (_) {},
        isMock: ctx.isMock,
        allowedExitCodes: const [0],
      );
    } catch (_) {
      return false;
    }
  }

  Future<List<String>?> inspectSource(StageContext ctx) async {
    final excluded = <String>{'/boot/efi'};
    if (!ctx.isMock) {
      try {
        final result = await ctx.commandRunner.run('findmnt', [
          '--json',
          '--list',
          '--output',
          'TARGET,FSTYPE',
        ]);
        if (!result.started || result.exitCode != 0) return null;
        final data = jsonDecode(result.stdout);
        if (data is! Map || data['filesystems'] is! List) return null;
        final mounts = data['filesystems'] as List;
        final seen = <String>{};
        var hasRoot = false;
        for (final mount in mounts) {
          if (mount is! Map) return null;
          final target = mount['target'];
          final type = mount['fstype'];
          if (target is! String ||
              type is! String ||
              !_validPath(target) ||
              !RegExp(r'^[a-zA-Z0-9._-]+$').hasMatch(type) ||
              !seen.add(target) ||
              mount.containsKey('children')) {
            return null;
          }
          if (target == '/') {
            if (!const {
              'overlay',
              'btrfs',
              'ext4',
              'xfs',
              'erofs',
              'squashfs',
            }.contains(type)) {
              return null;
            }
            hasRoot = true;
            continue;
          }
          if (requiredFiles.any((path) => _within(path, target))) return null;
          if (_within(target, '/mnt')) {
            continue; // Already excluded, recursively.
          }
          if (!_virtualFilesystems.contains(type) &&
              _systemDirectories.any((dir) => _within(target, dir))) {
            // A mounted /boot, /usr, etc. could hide required prepared files.
            // Without source provenance, neither copy it nor silently omit it.
            return null;
          }
          if (_within(target, '/boot')) return null;
          excluded.add(target);
        }
        if (!hasRoot) return null;
      } catch (_) {
        return null; // No raw findmnt output or exception text in user errors.
      }
    }
    return [
      for (final path in excluded) ...[
        '--exclude=${_escapePattern(path)}/*',
        '--exclude=${_escapePattern(path)}',
      ],
    ];
  }

  static const _systemDirectories = {
    '/boot',
    '/usr',
    '/etc',
    '/var',
    '/opt',
    '/home',
    '/root',
    '/bin',
    '/sbin',
    '/lib',
    '/lib64',
  };
  static const _virtualFilesystems = {
    'tmpfs',
    'devtmpfs',
    'proc',
    'sysfs',
    'cgroup',
    'cgroup2',
    'pstore',
    'efivarfs',
    'devpts',
    'mqueue',
    'hugetlbfs',
    'securityfs',
    'debugfs',
    'tracefs',
    'configfs',
    'fusectl',
    'selinuxfs',
    'bpf',
    'rpc_pipefs',
    'autofs',
  };

  static bool _within(String path, String parent) =>
      path == parent || path.startsWith('$parent/');

  static bool _validPath(String path) =>
      path == '/' ||
      (path.startsWith('/') &&
          !RegExp(r'[\x00-\x1f\x7f]').hasMatch(path) &&
          path
              .substring(1)
              .split('/')
              .every((p) => p.isNotEmpty && p != '.' && p != '..'));

  static String _escapePattern(String path) =>
      path.replaceAllMapped(RegExp(r'[\\*?\[\]]'), (match) => '\\${match[0]}');
}
