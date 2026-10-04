import 'dart:convert';

import '../../models/installer_handoff.dart';
import 'prepared_kernel_artifacts.dart';
import 'stage_context.dart';
import 'stage_result.dart';

const postInstallKernelImageValidationScript =
    'set -e\n$preparedKernelDiscoveryScript'
    r'''
candidates="$(discover_prepared_kernels)"
while IFS="$(printf '\t')" read -r kver image; do
  test -s "/boot/initramfs-$kver.img"
done <<CANDIDATES
$candidates
CANDIDATES
''';

const postInstallNoLiveUserSddmValidationScript = r'''
set -e
for path in /mnt/etc/sddm.conf /mnt/etc/sddm.conf.d /mnt/var/lib/sddm /mnt/var/lib/AccountsService; do
  if [ -e "$path" ] || [ -L "$path" ]; then
    status=0
    grep -R -I -E '(^User=liveuser$|liveuser)' "$path" >/dev/null 2>&1 || status=$?
    [ "$status" -eq 1 ]
  fi
done
''';

const postInstallPlasmaLauncherValidationScript = r'''
set -e
bad=0
desktop_id_exists() {
  local desktop_id="$1"
  [ -f "/usr/share/applications/${desktop_id}" ] ||
    [ -f "/usr/local/share/applications/${desktop_id}" ] ||
    [ -f "/var/lib/flatpak/exports/share/applications/${desktop_id}" ]
}

while IFS= read -r file; do
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" == launchers=* ]] || continue
    IFS=',' read -r -a launchers <<< "${line#launchers=}"
    for item in "${launchers[@]}"; do
      [[ "$item" == applications:* ]] || continue
      desktop_id="${item#applications:}"
      if ! desktop_id_exists "$desktop_id"; then
        printf 'Missing launcher desktop id in %s: %s\n' "$file" "$desktop_id" >&2
        bad=1
      fi
    done
  done < "$file"
done < <(
  find \
    /etc/xdg \
    /etc/skel \
    /home \
    /root \
    -path '*/.config/plasma-org.kde.plasma.desktop-appletsrc' \
    -type f 2>/dev/null || true
)
exit "$bad"
''';

const postInstallNoGpuDebugArgsValidationScript = r'''
status=0
grep -R -E '(^|[[:space:]])(nomodeset|ro\.live\.software_render=1|ro\.live\.session=[^[:space:]]*|nouveau\.config=[^[:space:]]*|nouveau\.modeset=0|i915\.modeset=0|xe\.modeset=0|rd\.driver\.blacklist=[^[:space:]]*(nouveau|i915|xe)|modprobe\.blacklist=[^[:space:]]*(nouveau|i915|xe)|blacklist=(nouveau|i915|xe))([[:space:]]|$)' /mnt/etc/kernel/cmdline /mnt/boot/loader/entries >/dev/null 2>&1 || status=$?
[ "$status" -eq 1 ]
''';

/// IDs are checked without printing their contents. Absolute D-Bus links are
/// interpreted in the target namespace, rather than followed on the live host.
const postInstallMachineIdentityValidationScript = r'''
set -e
test -f /mnt/etc/machine-id
test -r /mnt/etc/machine-id
test ! -L /mnt/etc/machine-id
[ "$(wc -c < /mnt/etc/machine-id)" -le 33 ]
identity="$(cat /mnt/etc/machine-id)"
[ "${#identity}" -eq 32 ]
case "$identity" in
  *[!0123456789abcdefABCDEF]*|00000000000000000000000000000000) exit 1 ;;
esac
if [ -r /etc/machine-id ]; then
  live_identity="$(cat /etc/machine-id)"
  [ "$(printf '%s' "$identity" | tr A-F a-f)" != "$(printf '%s' "$live_identity" | tr A-F a-f)" ]
fi
dbus=/mnt/var/lib/dbus/machine-id
if [ -L "$dbus" ]; then
  link="$(readlink "$dbus")"
  [ "$link" = /etc/machine-id ] ||
    [ "$(readlink -f "$dbus")" = /mnt/etc/machine-id ]
else
  test -f "$dbus"
  test -r "$dbus"
  cmp -s /mnt/etc/machine-id "$dbus"
fi
''';

/// Status 1 alone is ambiguous: RPM database/tool failures must not pass.
/// Enumerate the DB successfully and require the C-locale absence diagnostic.
const postInstallInstallerRemovalValidationScript = r'''
set -e
export LC_ALL=C
packages="$(rpm -qa --qf '%{NAME}\n')"
status=0
result="$(rpm -q ro-installer 2>&1)" || status=$?
[ "$status" -eq 1 ]
[ "$result" = "package ro-installer is not installed" ]
if printf '%s\n' "$packages" | grep -Fxq ro-installer; then exit 1; fi
''';

const postInstallStandardStorageValidationScript = r'''
set -e
root_uuid="$1"
efi_uuid="$2"
while read -r subvol mountpoint; do
  target="/mnt$mountpoint"
  [ "$mountpoint" != / ] || target=/mnt
  actual="$(findmnt -rn -o FSTYPE,UUID,FSROOT --mountpoint "$target")"
  set -- $actual
  [ "$#" -eq 3 ]
  [ "$1" = btrfs ] && [ "$2" = "$root_uuid" ] && [ "$3" = "/$subvol" ] || exit 1
  awk -v uuid="UUID=$root_uuid" -v point="$mountpoint" -v subvol="$subvol" '
    $2 == point {
      rows++
      if ($1 != uuid || $3 != "btrfs") exit 1
      n=split($4, opts, ",")
      for (i=1; i<=n; i++) if (opts[i] == "subvol=" subvol) found++
    }
    END { if (rows != 1 || found != 1) exit 1 }
  ' /mnt/etc/fstab
done <<'LAYOUT'
root /
home /home
var_log /var/log
var_cache /var/cache
var_tmp /var/tmp
LAYOUT
actual="$(findmnt -rn -o FSTYPE,UUID --mountpoint /mnt/boot/efi)"
set -- $actual
[ "$#" -eq 2 ] && [ "$1" = vfat ] && [ "$2" = "$efi_uuid" ] || exit 1
awk -v uuid="UUID=$efi_uuid" '
  $2 == "/boot/efi" { rows++; if ($1 != uuid || $3 != "vfat") bad=1 }
  $3 == "swap" || $2 == "/boot" { bad=1 }
  END { exit bad || rows != 1 }
' /mnt/etc/fstab
status=0
findmnt -rn --mountpoint /mnt/boot >/dev/null || status=$?
[ "$status" -eq 1 ]
''';

/// Validate installed options everywhere, then match each prepared kernel to a
/// BLS entry by version and actual referenced artifacts, independent of filename.
const postInstallBlsValidationScript =
    'set -e\n$preparedKernelDiscoveryScript'
    r'''
root_uuid="$1"
validate_options() {
  awk -v uuid="root=UUID=$root_uuid" '
    {
      for (i=1; i<=NF; i++) {
        if ($i == uuid) root++
        if ($i == "rootflags=subvol=root") subvol++
        if ($i ~ /^root=/ && $i != uuid) bad=1
        if ($i ~ /^rootflags=/ && $i != "rootflags=subvol=root") bad=1
        if ($i ~ /^resume=/ || $i ~ /rd.live.image|inst.stage2|CDLABEL|root=live:/) bad=1
      }
    }
    END { exit bad || root != 1 || subvol != 1 }
  '
}
resolve_boot_path() {
  case "$1" in /*) ;; *) return 1 ;; esac
  case "$1" in */../*|*/..|*/./*|*/.|*//*) return 1 ;; esac
  case "$1" in
    # GRUB sees the Btrfs top level; validation runs inside the root subvolume.
    /root/boot/*) boot_file="/boot/${1#/root/boot/}" ;;
    /root|/root/*) return 1 ;;
    *)
      if [ -f "$1" ] && [ -s "$1" ]; then
        boot_file="$1"
      else
        # Traditional BLS paths are relative to the boot filesystem.
        boot_file="/boot$1"
      fi
      ;;
  esac
  test -f "$boot_file" && test -s "$boot_file" || return 1
  printf '%s\n' "$boot_file"
}
test -r /etc/kernel/cmdline
validate_options < /etc/kernel/cmdline
for entry in /boot/loader/entries/*.conf; do
  test -r "$entry"
  options="$(awk '$1 == "options" { $1=""; print }' "$entry")"
  printf '%s\n' "$options" | validate_options
done
candidates="$(discover_prepared_kernels)"
while IFS="$(printf '\t')" read -r kver image; do
  matched=0
  for entry in /boot/loader/entries/*.conf; do
    version="$(awk '$1 == "version" { print $2 }' "$entry")"
    [ "$version" = "$kver" ] || continue
    linux="$(awk '$1 == "linux" { print $2 }' "$entry")"
    linux_file="$(resolve_boot_path "$linux")" || continue
    cmp -s "$linux_file" "$image" || continue
    initrd_matched=0
    initrd_valid=1
    initrds="$(awk '$1 == "initrd" { for (i=2; i<=NF; i++) print $i }' "$entry")"
    while IFS= read -r initrd; do
      [ -n "$initrd" ] || continue
      case "$initrd" in
        '$tuned_initrd') continue ;;
        *'$'*) initrd_valid=0; break ;;
      esac
      initrd_file="$(resolve_boot_path "$initrd")" || { initrd_valid=0; break; }
      if cmp -s "$initrd_file" "/boot/initramfs-$kver.img"; then initrd_matched=1; fi
    done <<INITRDS
$initrds
INITRDS
    if [ "$initrd_valid" -eq 1 ] && [ "$initrd_matched" -eq 1 ]; then matched=1; break; fi
  done
  if [ "$matched" -ne 1 ]; then
    echo "No coherent BLS entry for prepared kernel: $kver" >&2
    exit 1
  fi
done <<CANDIDATES
$candidates
CANDIDATES
''';

const postInstallGrubStubValidationScript = r'''
set -e
root_uuid="$1"
stub=/mnt/boot/efi/EFI/fedora/grub.cfg
test -r "$stub"
awk -v search="search --no-floppy --fs-uuid --set=dev $root_uuid" '
  $1 == "search" { searches++; if ($0 != search) bad=1 }
  $1 == "set" && $2 ~ /^prefix=/ {
    prefixes++; if ($0 != "set prefix=($dev)/root/boot/grub2") bad=1
  }
  $1 == "configfile" { redirects++; if ($0 != "configfile $prefix/grub.cfg") bad=1 }
  END { exit bad || searches != 1 || prefixes != 1 || redirects != 1 }
' "$stub"
if grep -Fq '/@/boot/grub2' "$stub"; then exit 1; fi
test -s /mnt/boot/grub2/grub.cfg
''';

/// Stage 8 verifies deployed storage, boot artifacts, cleanup, identity and
/// firstboot handoff. It does not enforce Compose product composition policy.
class PostInstallValidationStage {
  const PostInstallValidationStage();

  Future<StageResult> execute(StageContext ctx) async {
    if ((ctx.state['partitionMethod'] ?? 'full') != 'full' ||
        (ctx.state['fileSystem'] ?? 'btrfs') != 'btrfs') {
      return StageResult.fail(
        'Technical validation requires full/Btrfs storage.',
      );
    }
    ctx.log('[AŞAMA 8] Teknik kurulum doğrulaması başlatılıyor.');
    ctx.progress(
      0.97,
      'stage_progress_post_validate_boot',
      'Kurulu sistemin boot doğrulaması yapılıyor...',
    );

    StageResult? failure = await _requireCommand(ctx, 'test', [
      '-f',
      '/mnt/etc/fstab',
    ], '/etc/fstab bulunamadı.');
    if (failure != null) return failure;
    failure = await _validateHandoff(ctx);
    if (failure != null) return failure;
    failure = await _requireCommand(ctx, 'sh', [
      '-c',
      postInstallMachineIdentityValidationScript,
    ], 'Hedef machine-id veya D-Bus kimliği geçersiz.');
    if (failure != null) return failure;
    failure = await _requireCommand(ctx, 'chroot', [
      '/mnt',
      'sh',
      '-c',
      postInstallInstallerRemovalValidationScript,
    ], 'Installer RPM kaldırılması veya hedef RPM veritabanı doğrulanamadı.');
    if (failure != null) return failure;

    for (final path in [
      '/usr/bin/ro-installer',
      '/usr/bin/ro_installer',
      '/usr/libexec/ro-installer-launcher.sh',
      '/usr/share/polkit-1/actions/org.roasd.installer.policy',
      '/etc/polkit-1/rules.d/49-ro-installer-live.rules',
      '/etc/sudoers.d/ro-installer-live',
    ]) {
      failure = await _requireCommand(ctx, 'test', [
        '!',
        '-e',
        '/mnt$path',
      ], 'Installer/live dosyası hedefte kalmış: $path');
      if (failure != null) return failure;
      failure = await _requireCommand(ctx, 'test', [
        '!',
        '-L',
        '/mnt$path',
      ], 'Installer/live symlink hedefte kalmış: $path');
      if (failure != null) return failure;
    }
    failure = await _requireCommand(ctx, 'chroot', [
      '/mnt',
      'sh',
      '-c',
      'status=0; getent passwd liveuser >/dev/null || status=\$?; [ "\$status" -eq 2 ]',
    ], 'liveuser hesabı kalmış veya hesap veritabanı okunamadı.');
    if (failure != null) return failure;
    failure = await _requireCommand(ctx, 'sh', [
      '-c',
      postInstallNoLiveUserSddmValidationScript,
    ], 'SDDM liveuser/autologin kalıntısı hedefe sızmış.');
    if (failure != null) return failure;
    failure = await _requireCommand(ctx, 'chroot', [
      '/mnt',
      'bash',
      '-c',
      postInstallPlasmaLauncherValidationScript,
    ], 'Plasma launcher hedefi bulunamadı.');
    if (failure != null) return failure;

    failure = await _requireCommand(ctx, 'findmnt', [
      '--verify',
      '--tab-file',
      '/mnt/etc/fstab',
    ], '/etc/fstab doğrulaması başarısız.');
    if (failure != null) return failure;
    final rootUuid = await _readUuid(ctx, '/mnt');
    if (rootUuid == null) return StageResult.fail('Root UUID okunamadı.');
    final efiUuid = await _readUuid(ctx, '/mnt/boot/efi');
    if (efiUuid == null) return StageResult.fail('EFI UUID okunamadı.');
    failure = await _requireCommand(ctx, 'sh', [
      '-c',
      postInstallStandardStorageValidationScript,
      'storage-validation',
      rootUuid,
      efiUuid,
    ], 'Standart Btrfs mount/fstab veya ESP sözleşmesi tutarsız.');
    if (failure != null) return failure;
    failure = await _requireCommand(ctx, 'chroot', [
      '/mnt',
      'sh',
      '-c',
      postInstallKernelImageValidationScript,
    ], 'Tam kernel adayı veya eşleşen initramfs bulunamadı.');
    if (failure != null) return failure;
    failure = await _requireCommand(ctx, 'chroot', [
      '/mnt',
      'sh',
      '-c',
      postInstallBlsValidationScript,
      'bls-validation',
      rootUuid,
    ], 'Kernel cmdline veya kernel başına BLS referansları tutarsız.');
    if (failure != null) return failure;
    failure = await _requireCommand(ctx, 'sh', [
      '-c',
      postInstallNoGpuDebugArgsValidationScript,
    ], 'Live/debug GPU boot argümanları hedefe sızmış.');
    if (failure != null) return failure;
    for (final binary in ['shimx64.efi', 'grubx64.efi']) {
      failure = await _requireCommand(ctx, 'test', [
        '-s',
        '/mnt/boot/efi/EFI/fedora/$binary',
      ], 'EFI boot binary bulunamadı veya boş: $binary');
      if (failure != null) return failure;
    }
    failure = await _requireCommand(ctx, 'sh', [
      '-c',
      postInstallGrubStubValidationScript,
      'grub-validation',
      rootUuid,
    ], 'GRUB stub UUID/prefix/yönlendirme veya ana grub.cfg tutarsız.');
    if (failure != null) return failure;

    ctx.log('[AŞAMA 8] Teknik doğrulama tamamlandı.');
    return StageResult.ok(
      ctx.t(
        'stage_result_post_validation_done',
        'Kurulum sonrası doğrulama tamamlandı.',
      ),
    );
  }

  Future<StageResult?> _requireCommand(
    StageContext ctx,
    String cmd,
    List<String> args,
    String errorMessage,
  ) async {
    final ok = await ctx.runCmd(cmd, args, ctx.log, isMock: ctx.isMock);
    if (ok) return null;
    ctx.log('HATA: $errorMessage');
    return StageResult.fail(errorMessage);
  }

  Future<String?> _readUuid(StageContext ctx, String mountPoint) async {
    if (ctx.isMock) return mountPoint == '/mnt' ? 'MOCK-ROOT' : 'MOCK-EFI';
    final result = await ctx.commandRunner.run('findmnt', [
      '-rn',
      '-o',
      'UUID',
      '--mountpoint',
      mountPoint,
    ]);
    final value = result.stdout.trim();
    return result.started &&
            result.exitCode == 0 &&
            RegExp(r'^[A-Za-z0-9-]+$').hasMatch(value)
        ? value
        : null;
  }

  Future<StageResult?> _validateHandoff(StageContext ctx) async {
    if (ctx.isMock) return null;
    try {
      final values = <Object?>[];
      for (final path in [installerSeedPath, installMetadataPath]) {
        final result = await ctx.commandRunner.run('cat', ['/mnt$path']);
        if (!result.started || result.exitCode != 0) {
          return StageResult.fail(
            'Firstboot seed veya install metadata okunamadı.',
          );
        }
        values.add(jsonDecode(result.stdout));
      }
      if (isValidInstallerHandoff(values[0], values[1])) return null;
    } catch (_) {
      // JSON parse errors can include source excerpts; never log them.
    }
    return StageResult.fail(
      'Firstboot seed veya install metadata v1 sözleşmesi geçersiz.',
    );
  }
}
