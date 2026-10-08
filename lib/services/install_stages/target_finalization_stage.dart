import 'dart:convert';

import '../../models/standard_storage_layout.dart';
import '../../models/installer_handoff.dart';
import '../command_runner.dart';
import 'stage_context.dart';
import 'stage_result.dart';

const targetLiveCleanupScript = r'''
set -e
for service in livesys.service livesys-late.service ro-live-session-compat.service; do
  systemctl disable "$service" 2>/dev/null || true
done
# Never unlink files still owned by an installed RPM.
while IFS= read -r path; do
  [ -e "$path" ] || [ -L "$path" ] || continue
  if rpm -qf "$path" >/dev/null 2>&1; then continue; fi
  case "$path" in
    /usr/lib64/ro-installer|/usr/lib/ro-installer) rm -rf -- "$path" ;;
    *) rm -f -- "$path" ;;
  esac
done <<'LIVE_PATHS'
/etc/systemd/system/livesys.service
/etc/systemd/system/livesys-late.service
/etc/systemd/system/ro-live-session-compat.service
/usr/lib/systemd/system/livesys.service
/usr/lib/systemd/system/livesys-late.service
/usr/lib/systemd/system/ro-live-session-compat.service
/usr/libexec/ro-live-session-compat.sh
/etc/sddm.conf.d/10-ro-live-graphics.conf
/etc/sddm.conf.d/10-ro-live-wayland.conf
/etc/xdg/plasma-workspace/env/10-ro-live-cursor.sh
/etc/environment.d/10-ro-live-cursor.conf
/etc/environment.d/20-ro-live-graphics.conf
/etc/systemd/system/upower.service.d/10-ro-live-kernel-compat.conf
/etc/systemd/system/irqbalance.service.d/10-ro-live-kernel-compat.conf
/etc/xdg/autostart/ro-Installer.desktop
/usr/bin/ro-installer
/usr/bin/ro_installer
/usr/share/applications/ro-installer.desktop
/usr/libexec/ro-installer-launcher.sh
/usr/libexec/ro-installer-helper
/usr/libexec/ro-installer-backend
/usr/lib64/ro-installer
/usr/lib/ro-installer
/usr/share/polkit-1/actions/org.roasd.installer.helper.policy
/usr/share/polkit-1/actions/org.roasd.installer.policy
/etc/polkit-1/rules.d/49-ro-installer-live.rules
/etc/sudoers.d/ro-installer-live
/var/lib/AccountsService/users/liveuser
/var/lib/AccountsService/icons/liveuser
LIVE_PATHS
if getent passwd liveuser >/dev/null 2>&1; then
  userdel -r liveuser
fi
# Remove only the live autologin settings, preserving composed SDDM configuration.
for file in /etc/sddm.conf /etc/sddm.conf.d/*.conf; do
  [ -f "$file" ] || continue
  sed -i '/^User=liveuser$/d' "$file"
done
rm -f /var/lib/sddm/state.conf
rm -rf /var/lib/sddm/.cache /var/lib/sddm/.config /var/lib/sddm/.local
''';

const _plasmaLauncherCleanupScript = r'''
set -e

desktop_id_exists() {
  local desktop_id="$1"
  [ -f "/usr/share/applications/${desktop_id}" ] ||
    [ -f "/usr/local/share/applications/${desktop_id}" ] ||
    [ -f "/var/lib/flatpak/exports/share/applications/${desktop_id}" ]
}

append_launcher() {
  local current="$1"
  local item="$2"
  if [ -z "$current" ]; then
    printf '%s' "$item"
  else
    printf '%s,%s' "$current" "$item"
  fi
}

sanitize_launcher_file() {
  local file="$1"
  [ -f "$file" ] || return 0
  local tmp="${file}.ro-clean"
  local changed=0

  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" == launchers=* ]]; then
      local raw="${line#launchers=}"
      local cleaned=""
      local item desktop_id
      IFS=',' read -r -a launchers <<< "$raw"
      for item in "${launchers[@]}"; do
        [ -n "$item" ] || continue
        if [[ "$item" == applications:* ]]; then
          desktop_id="${item#applications:}"
          if desktop_id_exists "$desktop_id"; then
            cleaned="$(append_launcher "$cleaned" "$item")"
          else
            changed=1
          fi
        else
          cleaned="$(append_launcher "$cleaned" "$item")"
        fi
      done
      printf 'launchers=%s\n' "$cleaned"
    else
      printf '%s\n' "$line"
    fi
  done < "$file" > "$tmp"

  if [ "$changed" -eq 1 ]; then
    cat "$tmp" > "$file"
  fi
  rm -f "$tmp"
}

while IFS= read -r file; do
  sanitize_launcher_file "$file"
done < <(
  find \
    /etc/xdg \
    /etc/skel \
    /home \
    /root \
    -path '*/.config/plasma-org.kde.plasma.desktop-appletsrc' \
    -type f 2>/dev/null || true
)

rm -f /home/*/.cache/icon-cache.kcache /home/*/.cache/ksycoca* 2>/dev/null || true
''';

/// Stage 6: narrow, offline finalization of the Compose-prepared target.
class TargetFinalizationStage {
  const TargetFinalizationStage();

  Future<StageResult> execute(StageContext ctx) async {
    if ((ctx.state['partitionMethod'] ?? 'full') != 'full' ||
        (ctx.state['fileSystem'] ?? 'btrfs') != 'btrfs') {
      return StageResult.fail(
        'Target finalization requires the full/Btrfs MVP layout.',
      );
    }
    ctx.log('[AŞAMA 6] Hedef Sonlandırma Başlatılıyor');
    ctx.progress(
      0.7,
      'stage_progress_target_bind_mounts',
      'Hedef sistem bağlamaları hazırlanıyor...',
    );
    StageResult? failure;
    // Rsync tarafından dışlanan dizinlerin bağlama noktalarını oluştur
    failure = await _requireCommand(ctx, 'mkdir', [
      '-p',
      '/mnt/dev',
      '/mnt/proc',
      '/mnt/sys',
      '/mnt/run',
      '/mnt/tmp',
    ], 'Chroot bağlama dizinleri oluşturulamadı.');
    if (failure != null) return failure;

    // /tmp için tmpfs mount et (os-prober ve dracut için şart)
    failure = await _requireCommand(ctx, 'mount', [
      '-t',
      'tmpfs',
      'tmpfs',
      '/mnt/tmp',
    ], '/mnt/tmp için tmpfs bağlanamadı.');
    if (failure != null) return failure;

    // --rbind: /dev/pts, /dev/shm, /sys/firmware/efi/efivars gibi alt mount'ları da dahil eder
    // Bu dracut ve grub2-install için EFI ve cihaz erişiminde kritik önemdedir
    failure = await _requireCommand(ctx, 'mount', [
      '--rbind',
      '/dev',
      '/mnt/dev',
    ], '/dev bağı hedef sisteme aktarılamadı.');
    if (failure != null) return failure;
    failure = await _requireCommand(ctx, 'mount', [
      '--make-rslave',
      '/mnt/dev',
    ], '/mnt/dev için rslave ayarı uygulanamadı.');
    if (failure != null) return failure;
    failure = await _requireCommand(ctx, 'mount', [
      '--rbind',
      '/proc',
      '/mnt/proc',
    ], '/proc bağı hedef sisteme aktarılamadı.');
    if (failure != null) return failure;
    failure = await _requireCommand(ctx, 'mount', [
      '--make-rslave',
      '/mnt/proc',
    ], '/mnt/proc için rslave ayarı uygulanamadı.');
    if (failure != null) return failure;
    failure = await _requireCommand(ctx, 'mount', [
      '--rbind',
      '/sys',
      '/mnt/sys',
    ], '/sys bağı hedef sisteme aktarılamadı.');
    if (failure != null) return failure;
    failure = await _requireCommand(ctx, 'mount', [
      '--make-rslave',
      '/mnt/sys',
    ], '/mnt/sys için rslave ayarı uygulanamadı.');
    if (failure != null) return failure;
    failure = await _requireCommand(ctx, 'mount', [
      '--rbind',
      '/run',
      '/mnt/run',
    ], '/run bağı hedef sisteme aktarılamadı.');
    if (failure != null) return failure;
    failure = await _requireCommand(ctx, 'mount', [
      '--make-rslave',
      '/mnt/run',
    ], '/mnt/run için rslave ayarı uygulanamadı.');
    if (failure != null) return failure;

    // Clear both possible copied IDs. --root uses offline random generation,
    // rather than borrowing identity from the bind-mounted live /run.
    failure = await _requireCommand(ctx, 'rm', [
      '-f',
      '/mnt/etc/machine-id',
      '/mnt/var/lib/dbus/machine-id',
    ], 'Kopyalanmış machine-id temizlenemedi.');
    if (failure != null) return failure;
    failure = await _requireCommand(ctx, 'systemd-machine-id-setup', [
      '--root=/mnt',
    ], 'Machine ID oluşturulamadı.');
    if (failure != null) return failure;
    failure = await _requireCommand(ctx, 'mkdir', [
      '-p',
      '/mnt/var/lib/dbus',
    ], 'D-Bus dizini oluşturulamadı.');
    if (failure != null) return failure;
    failure = await _requireCommand(ctx, 'ln', [
      '-sf',
      '/etc/machine-id',
      '/mnt/var/lib/dbus/machine-id',
    ], 'D-Bus machine-id bağı oluşturulamadı.');
    if (failure != null) return failure;

    ctx.progress(
      0.82,
      'stage_progress_target_cleanup_live',
      'Live kalıntıları temizleniyor...',
    );
    failure = await _removeInstallerPackage(ctx);
    if (failure != null) return failure;
    failure = await _requireCommand(ctx, 'chroot', [
      '/mnt',
      'sh',
      '-c',
      targetLiveCleanupScript,
    ], 'Live kalıntıları temizlenemedi.');
    if (failure != null) return failure;
    failure = await _requireCommand(ctx, 'chroot', [
      '/mnt',
      'bash',
      '-c',
      _plasmaLauncherCleanupScript,
    ], 'Plasma launcher kalıntıları temizlenemedi.');
    if (failure != null) return failure;

    ctx.progress(
      0.85,
      'stage_progress_target_fstab_selinux',
      'Fstab ve hedef handoff hazırlanıyor...',
    );
    final disk = (ctx.state['selectedDisk'] ?? '').toString();
    final rootUuid = await _lookupUuid(ctx, _partitionPath(disk, 2));
    final espUuid = await _lookupUuid(ctx, _partitionPath(disk, 1));
    if (rootUuid == null || espUuid == null) {
      return StageResult.fail('/etc/fstab için UUID okunamadı.');
    }
    final fstab = StringBuffer('# /etc/fstab generated by ro-Installer\n');
    for (final entry in StandardStorageLayout.subvolumes.entries) {
      fstab.writeln(
        'UUID=$rootUuid ${entry.value} btrfs '
        'defaults,${StandardStorageLayout.mountOptions(entry.key)} 0 0',
      );
    }
    fstab.writeln(
      'UUID=$espUuid /boot/efi vfat umask=0077,shortname=winnt 0 2',
    );
    failure = await _writeTargetFile(ctx, '/mnt/etc/fstab', fstab.toString());
    if (failure != null) return failure;
    failure = await _requireCommand(ctx, 'findmnt', [
      '--verify',
      '--tab-file',
      '/mnt/etc/fstab',
    ], '/etc/fstab doğrulanamadı.');
    if (failure != null) return failure;

    failure = await _requireCommand(ctx, 'mkdir', [
      '-p',
      '/mnt/var/lib/ro-asd/firstboot',
      '/mnt/var/lib/ro-asd/install',
    ], 'Firstboot ve metadata dizinleri oluşturulamadı.');
    if (failure != null) return failure;
    final seed = installerSeed(
      (ctx.state['selectedLanguage'] ?? 'tr').toString(),
    );
    for (final entry in {
      installerSeedPath: seed,
      installMetadataPath: installMetadata(),
    }.entries) {
      failure = await _writeTargetFile(
        ctx,
        '/mnt${entry.key}',
        '${jsonEncode(entry.value)}\n',
      );
      if (failure != null) return failure;
      failure = await _requireCommand(ctx, 'chmod', [
        '0644',
        '/mnt${entry.key}',
      ], 'Handoff dosya izinleri ayarlanamadı.');
      if (failure != null) return failure;
    }
    if (ctx.state['vmTestMode'] == true) {
      ctx.progress(
        0.86,
        'stage_progress_target_vm_smoke',
        'VM test ilk acilis servisi hazirlaniyor...',
      );
      failure = await _requireCommand(ctx, 'sh', [
        '-c',
        '''
cat > /mnt/etc/systemd/system/ro-installer-vm-smoke.service << 'EOF'
[Unit]
Description=Ro-Installer VM Smoke Test Marker
After=local-fs.target systemd-user-sessions.service
ConditionPathExists=!/var/lib/ro-installer-vm-smoke.done

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo RO_INSTALLER_VM_BOOT_OK > /dev/ttyS0; touch /var/lib/ro-installer-vm-smoke.done; systemctl --no-block poweroff'
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF
        ''',
      ], 'VM smoke test servisi olusturulamadi.');
      if (failure != null) return failure;
      failure = await _requireCommand(ctx, 'chroot', [
        '/mnt',
        'systemctl',
        'enable',
        'ro-installer-vm-smoke.service',
      ], 'VM smoke test servisi etkinlestirilemedi.');
      if (failure != null) return failure;
    }

    failure = await _requireCommand(ctx, 'touch', [
      '/mnt/.autorelabel',
    ], 'SELinux autorelabel işareti oluşturulamadı.');
    if (failure != null) return failure;
    return StageResult.ok(
      ctx.t(
        'stage_result_target_finalization_done',
        'Hedef sonlandırma tamamlandı.',
      ),
    );
  }

  Future<StageResult?> _removeInstallerPackage(StageContext ctx) async {
    // Enumerating the DB distinguishes an unreadable DB from an absent package.
    Future<CommandResult> query() => ctx.commandRunner.run('chroot', [
      '/mnt',
      'rpm',
      '-qa',
      '--qf',
      '%{NAME}\n',
    ], isMock: ctx.isMock);
    final before = await query();
    if (!before.started || before.exitCode != 0) {
      return StageResult.fail('Hedef RPM veritabanı okunamadı.');
    }
    if (!before.stdout.split('\n').contains('ro-installer')) return null;
    final failure = await _requireCommand(ctx, 'chroot', [
      '/mnt',
      'rpm',
      '-e',
      'ro-installer',
    ], 'ro-installer RPM kaldırma başarısız.');
    if (failure != null) return failure;
    final after = await query();
    if (!after.started ||
        after.exitCode != 0 ||
        after.stdout.split('\n').contains('ro-installer')) {
      return StageResult.fail(
        'ro-installer hedef RPM veritabanında kalmış görünüyor.',
      );
    }
    return null;
  }

  Future<StageResult?> _writeTargetFile(
    StageContext ctx,
    String path,
    String content,
  ) async {
    // Fixed command and separate path argument; all content travels over stdin.
    final result = await ctx.commandRunner.run(
      'sh',
      ['-c', r'cat > "$1"', 'ro-installer-write', path],
      stdinText: content,
      isMock: ctx.isMock,
      onLog: (event) => ctx.log(event.displayMessage),
    );
    return result.started && result.exitCode == 0
        ? null
        : StageResult.fail('Hedef dosya yazılamadı: $path');
  }

  Future<StageResult?> _requireCommand(
    StageContext ctx,
    String cmd,
    List<String> args,
    String errorMessage, {
    List<int> allowedExitCodes = const [0],
  }) async {
    final ok = await ctx.runCmd(
      cmd,
      args,
      ctx.log,
      isMock: ctx.isMock,
      allowedExitCodes: allowedExitCodes,
    );
    if (ok) {
      return null;
    }

    ctx.log('HATA: $errorMessage');
    return StageResult.fail(errorMessage);
  }

  Future<String?> _lookupUuid(StageContext ctx, String device) async {
    if (ctx.isMock) {
      final deviceId = device
          .split('/')
          .last
          .replaceAll(RegExp(r'[^A-Za-z0-9]'), '')
          .toUpperCase();
      return 'MOCK-$deviceId';
    }

    final result = await ctx.commandRunner.run('blkid', [
      '-s',
      'UUID',
      '-o',
      'value',
      device,
    ]);
    final uuid = result.stdout.trim();
    if (result.exitCode == 0 && uuid.isNotEmpty) {
      return uuid;
    }

    ctx.log('HATA: UUID okunamadı: $device');
    return null;
  }

  String _partitionPath(String disk, int partitionNumber) {
    final needsP =
        disk.contains('nvme') ||
        disk.contains('loop') ||
        disk.contains('mmcblk');
    return needsP ? '${disk}p$partitionNumber' : '$disk$partitionNumber';
  }
}
