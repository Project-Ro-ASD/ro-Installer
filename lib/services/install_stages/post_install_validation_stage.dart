import 'stage_context.dart';
import 'stage_result.dart';
import '../target_system_settings.dart';

const postInstallNoFedoraKernelValidationScript = r'''
if rpm -qa | grep -Eq '^(kernel|kernel-core|kernel-modules|kernel-modules-core|kernel-modules-extra|kernel-devel|kernel-devel-matched|kernel-debug|kernel-debug-core|kernel-debug-modules|kernel-debug-modules-core|kernel-debug-modules-extra|kernel-debug-devel|kernel-uki|kernel-uki-core|kernel-uki-modules|kernel-uki-modules-core|kernel-uki-modules-extra)-[0-9]'; then
  rpm -qa | grep -E '^(kernel|kernel-core|kernel-modules|kernel-modules-core|kernel-modules-extra|kernel-devel|kernel-devel-matched|kernel-debug|kernel-debug-core|kernel-debug-modules|kernel-debug-modules-core|kernel-debug-modules-extra|kernel-debug-devel|kernel-uki|kernel-uki-core|kernel-uki-modules|kernel-uki-modules-core|kernel-uki-modules-extra)-[0-9]' >&2 || true
  exit 1
fi
''';

const postInstallStableKernelValidationScript = r'''
for pkg in \
  ro-kernel-stable \
  ro-kernel-stable-core \
  ro-kernel-stable-modules \
  ro-kernel-stable-devel; do
  rpm -q "$pkg" >/dev/null 2>&1 || rpm -qa | grep -Eq "^${pkg}-" || exit 1
done
''';

const postInstallExperimentalKernelValidationScript = r'''
for pkg in \
  ro-kernel-experimental \
  ro-kernel-experimental-core \
  ro-kernel-experimental-modules \
  ro-kernel-experimental-devel; do
  rpm -q "$pkg" >/dev/null 2>&1 || rpm -qa | grep -Eq "^${pkg}-" || exit 1
done
''';

const postInstallRoRepoValidationScript = r'''
set -e
test -f /etc/yum.repos.d/ro-repo.repo
test -f /etc/yum.repos.d/ro-repo-noarch.repo
test -f /etc/yum.repos.d/ro-kernel-stable-copr.repo
test -f /etc/yum.repos.d/ro-kernel-experimental-copr.repo
test -f /etc/ro-asd/release-policy.conf
test -f /etc/dnf/protected.d/ro-kernel.conf
grep -q 'https://project-ro-asd.github.io/Ro-Repo/$basearch/' /etc/yum.repos.d/ro-repo.repo
grep -q 'https://project-ro-asd.github.io/Ro-Repo/noarch/' /etc/yum.repos.d/ro-repo-noarch.repo
grep -q '^gpgcheck=1$' /etc/yum.repos.d/ro-repo.repo
grep -q '^repo_gpgcheck=1$' /etc/yum.repos.d/ro-repo.repo
grep -q '^gpgkey=https://project-ro-asd.github.io/Ro-Repo/RPM-GPG-KEY-ro-asd$' /etc/yum.repos.d/ro-repo.repo
grep -q '^gpgcheck=1$' /etc/yum.repos.d/ro-repo-noarch.repo
grep -q '^repo_gpgcheck=1$' /etc/yum.repos.d/ro-repo-noarch.repo
grep -q '^gpgkey=https://project-ro-asd.github.io/Ro-Repo/RPM-GPG-KEY-ro-asd$' /etc/yum.repos.d/ro-repo-noarch.repo
grep -q 'hynkzz/ro-kernel-stable' /etc/yum.repos.d/ro-kernel-stable-copr.repo
grep -q '^gpgcheck=1$' /etc/yum.repos.d/ro-kernel-stable-copr.repo
grep -q '^repo_gpgcheck=0$' /etc/yum.repos.d/ro-kernel-stable-copr.repo
grep -q '^gpgkey=https://download.copr.fedorainfracloud.org/results/hynkzz/ro-kernel-stable/pubkey.gpg$' /etc/yum.repos.d/ro-kernel-stable-copr.repo
grep -q 'hynkzz/ro-Kernel-Experimental' /etc/yum.repos.d/ro-kernel-experimental-copr.repo
grep -q '^gpgcheck=1$' /etc/yum.repos.d/ro-kernel-experimental-copr.repo
grep -q '^repo_gpgcheck=0$' /etc/yum.repos.d/ro-kernel-experimental-copr.repo
grep -q '^gpgkey=https://download.copr.fedorainfracloud.org/results/hynkzz/ro-Kernel-Experimental/pubkey.gpg$' /etc/yum.repos.d/ro-kernel-experimental-copr.repo
grep -q '^policy_version=1$' /etc/ro-asd/release-policy.conf
grep -q '^system_role=installed-target$' /etc/ro-asd/release-policy.conf
grep -q '^kernel_policy=ro-kernel-only$' /etc/ro-asd/release-policy.conf
grep -Eq '^selected_kernel_channels=(stable|experimental|experimental,stable|stable,experimental)$' /etc/ro-asd/release-policy.conf
grep -q '^fedora_stock_kernel_policy=removed-and-excluded$' /etc/ro-asd/release-policy.conf
grep -q '^ro_repo_package_gpgcheck=1$' /etc/ro-asd/release-policy.conf
grep -q '^ro_repo_metadata_gpgcheck=1$' /etc/ro-asd/release-policy.conf
grep -q '^copr_kernel_package_gpgcheck=1$' /etc/ro-asd/release-policy.conf
grep -q '^copr_kernel_metadata_gpgcheck=0$' /etc/ro-asd/release-policy.conf
grep -q '^copr_kernel_metadata_reason=copr_metadata_signatures_not_available$' /etc/ro-asd/release-policy.conf
grep -q '^safe_graphics_policy=live-only$' /etc/ro-asd/release-policy.conf
grep -q '^target_cmdline_policy=no-live-or-debug-gpu-args$' /etc/ro-asd/release-policy.conf
grep -Eq '^ro-kernel-(stable|experimental)' /etc/dnf/protected.d/ro-kernel.conf
grep -q '^excludepkgs=kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra kernel-devel kernel-devel-matched kernel-debug kernel-debug-core kernel-debug-modules kernel-debug-modules-core kernel-debug-modules-extra kernel-debug-devel kernel-uki kernel-uki-core kernel-uki-modules kernel-uki-modules-core kernel-uki-modules-extra$' /etc/dnf/dnf.conf
''';

const postInstallRoDesktopAppsValidationScript = r'''
set -e
validate_executable_runtime() {
  binary="$1"
  file_info=""
  ldd_output=""

  test -x "$binary"

  if command -v file >/dev/null 2>&1; then
    file_info="$(file -L "$binary")"
    echo "[INFO] $file_info"
    case "$file_info" in
      *"ELF "*"dynamically linked"*)
        ldd -r "$binary"
        ;;
      *"ELF "*"statically linked"*|*"script"*|*"text executable"*)
        echo "[INFO] $binary is not a dynamic ELF executable; ldd -r is not applicable."
        ;;
      *)
        echo "[ERROR] Unsupported executable type for $binary: $file_info" >&2
        return 1
        ;;
    esac
    return 0
  fi

  if ldd_output="$(ldd -r "$binary" 2>&1)"; then
    printf '%s\n' "$ldd_output"
    return 0
  fi

  printf '%s\n' "$ldd_output" >&2
  case "$ldd_output" in
    *"not a dynamic executable"*)
      echo "[INFO] $binary is not a dynamic ELF executable; ldd -r is not applicable."
      ;;
    *)
      return 1
      ;;
  esac
}

rpm -q ro-assist ro-control
ro_assist_bin="$(command -v ro-assist)"
ro_control_bin="$(command -v ro-control)"
validate_executable_runtime "$ro_assist_bin"
if [ -x /usr/libexec/ro-assist/ro-assist ]; then
  validate_executable_runtime /usr/libexec/ro-assist/ro-assist
fi
validate_executable_runtime "$ro_control_bin"
''';

const postInstallKernelImageValidationScript = r'''
for kdir in /lib/modules/*; do
  [ -d "$kdir" ] || continue
  kver="${kdir##*/}"
  if [ -f "/boot/vmlinuz-$kver" ] || [ -f "$kdir/vmlinuz" ]; then
    exit 0
  fi
done
exit 1
''';

const postInstallNoLiveUserSddmValidationScript = r'''
if grep -R -I -E '(^User=liveuser$|liveuser)' \
  /mnt/etc/sddm.conf \
  /mnt/etc/sddm.conf.d \
  /mnt/var/lib/sddm \
  /mnt/var/lib/AccountsService 2>/dev/null; then
  exit 1
fi
''';

const postInstallBrandingValidationScript = r'''
set -e
test -f /usr/lib/os-release
grep -q '^NAME="Ro-ASD"$' /usr/lib/os-release
grep -q '^PRETTY_NAME="Ro-ASD"$' /usr/lib/os-release
grep -q '^VARIANT_ID=roasd$' /usr/lib/os-release
for release_file in /etc/fedora-release /etc/system-release /etc/issue /etc/issue.net; do
  [ -e "$release_file" ] || continue
  grep -q '^Ro-ASD' "$release_file"
  ! grep -qi 'Fedora' "$release_file"
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

const postInstallSwapResumeValidationScript = r'''
swap_uuid="$(awk '$3 == "swap" && $1 ~ /^UUID=/ { sub(/^UUID=/, "", $1); print $1; exit }' /mnt/etc/fstab)"
test -n "$swap_uuid"
grep -Eq "(^|[[:space:]])resume=UUID=${swap_uuid}([[:space:]]|$)" /mnt/etc/kernel/cmdline
grep -R -E "^[[:space:]]*options[[:space:]].*resume=UUID=${swap_uuid}([[:space:]]|$)" /mnt/boot/loader/entries/*.conf >/dev/null
''';

const postInstallNoGpuDebugArgsValidationScript = r'''
if grep -R -E '(^|[[:space:]])(nomodeset|ro\.live\.software_render=1|ro\.live\.session=[^[:space:]]*|nouveau\.config=[^[:space:]]*|nouveau\.modeset=0|i915\.modeset=0|xe\.modeset=0|rd\.driver\.blacklist=[^[:space:]]*(nouveau|i915|xe)|modprobe\.blacklist=[^[:space:]]*(nouveau|i915|xe)|blacklist=(nouveau|i915|xe))([[:space:]]|$)' /mnt/etc/kernel/cmdline /mnt/boot/loader/entries >/dev/null 2>&1; then
  exit 1
fi
''';

/// AŞAMA 8: Kurulum Sonrası Doğrulama
///
/// Kurulumun "tamamlandı" sayılabilmesi için hedef sistemde
/// boot için kritik dosya ve girdileri doğrular:
/// - /etc/fstab mevcut mu
/// - /etc/kernel/cmdline mevcut mu
/// - BLS girdileri mevcut mu
/// - fstab sözdizimi doğrulanıyor mu
/// - fstab, kernel cmdline ve BLS kök/EFI/resume UUID'leri tutarlı mı
/// - Live ISO parametreleri hedef sisteme sızmış mı
/// - BTRFS kurulumlarında rootflags=subvol=@ mevcut mu
class PostInstallValidationStage {
  const PostInstallValidationStage();

  Future<StageResult> execute(StageContext ctx) async {
    ctx.log('════════════════════════════════════════════');
    ctx.log('[AŞAMA 8] Kurulum Sonrası Doğrulama Başlatılıyor');
    ctx.log('════════════════════════════════════════════');

    ctx.progress(
      0.97,
      'stage_progress_post_validate_boot',
      'Kurulu sistemin boot doğrulaması yapılıyor...',
    );

    final localeSettings = resolveTargetLocaleSettings(
      selectedLanguage: (ctx.state['selectedLanguage'] ?? 'en').toString(),
      selectedLocale: (ctx.state['selectedLocale'] ?? '').toString(),
    );
    final keyboardSettings = resolveTargetKeyboardSettings(
      (ctx.state['selectedKeyboard'] ?? 'trq').toString(),
    );
    final timezone = (ctx.state['selectedTimezone'] ?? 'Europe/Istanbul')
        .toString();

    StageResult? failure = await _requireCommand(ctx, 'test', [
      '-f',
      '/mnt/etc/fstab',
    ], '/mnt/etc/fstab bulunamadı.');
    if (failure != null) return failure;

    failure = await _requireCommand(ctx, 'test', [
      '-f',
      '/mnt/etc/kernel/cmdline',
    ], '/mnt/etc/kernel/cmdline bulunamadı.');
    if (failure != null) return failure;

    failure = await _requireCommand(ctx, 'test', [
      '-f',
      '/mnt/etc/locale.conf',
    ], '/mnt/etc/locale.conf bulunamadı.');
    if (failure != null) return failure;

    failure = await _requireCommand(ctx, 'sh', [
      '-c',
      'grep -q "^LANG=${localeSettings.locale}\$" /mnt/etc/locale.conf',
    ], '/etc/locale.conf beklenen locale değerini içermiyor.');
    if (failure != null) return failure;

    failure = await _requireCommand(ctx, 'test', [
      '-f',
      '/mnt/etc/vconsole.conf',
    ], '/mnt/etc/vconsole.conf bulunamadı.');
    if (failure != null) return failure;

    failure = await _requireCommand(ctx, 'sh', [
      '-c',
      'grep -q "^KEYMAP=${keyboardSettings.consoleKeymap}\$" /mnt/etc/vconsole.conf',
    ], '/etc/vconsole.conf beklenen klavye düzenini içermiyor.');
    if (failure != null) return failure;

    failure = await _requireCommand(ctx, 'test', [
      '-f',
      '/mnt/etc/X11/xorg.conf.d/00-keyboard.conf',
    ], '/mnt/etc/X11/xorg.conf.d/00-keyboard.conf bulunamadı.');
    if (failure != null) return failure;

    failure = await _requireCommand(ctx, 'sh', [
      '-c',
      'grep -q \'Option "XkbLayout" "${keyboardSettings.x11Layout}"\' /mnt/etc/X11/xorg.conf.d/00-keyboard.conf',
    ], 'Grafik oturum klavye yerleşimi beklenen değeri içermiyor.');
    if (failure != null) return failure;

    if (keyboardSettings.hasVariant) {
      failure = await _requireCommand(ctx, 'sh', [
        '-c',
        'grep -q \'Option "XkbVariant" "${keyboardSettings.x11Variant}"\' /mnt/etc/X11/xorg.conf.d/00-keyboard.conf',
      ], 'Grafik oturum klavye varyantı beklenen değeri içermiyor.');
      if (failure != null) return failure;
    }

    failure = await _requireCommand(ctx, 'sh', [
      '-c',
      '[ "\$(readlink /mnt/etc/localtime)" = "/usr/share/zoneinfo/$timezone" ]',
    ], '/etc/localtime beklenen saat dilimine işaret etmiyor.');
    if (failure != null) return failure;

    failure = await _requireCommand(ctx, 'chroot', [
      '/mnt',
      'bash',
      '-c',
      postInstallBrandingValidationScript,
    ], 'Ro-ASD sistem kimliği hedef sistemde doğrulanamadı.');
    if (failure != null) return failure;

    failure = await _requireCommand(ctx, 'sh', [
      '-c',
      'ls /mnt/boot/loader/entries/*.conf >/dev/null 2>&1',
    ], 'BLS giriş dosyaları bulunamadı.');
    if (failure != null) return failure;

    failure = await _requireCommand(
      ctx,
      'chroot',
      ['/mnt', 'sh', '-c', postInstallNoFedoraKernelValidationScript],
      'Fedora stock kernel paketleri hedef sistemde kalmış görünüyor.',
    );
    if (failure != null) return failure;

    final selectedKernelChannels = _selectedKernelChannels(ctx.state);
    if (selectedKernelChannels.contains('stable')) {
      failure = await _requireCommand(ctx, 'chroot', [
        '/mnt',
        'sh',
        '-c',
        postInstallStableKernelValidationScript,
      ], 'Stable Ro kernel paketleri hedef sistemde doğrulanamadı.');
      if (failure != null) return failure;
    }

    if (selectedKernelChannels.contains('experimental')) {
      failure = await _requireCommand(
        ctx,
        'chroot',
        ['/mnt', 'sh', '-c', postInstallExperimentalKernelValidationScript],
        'Experimental kernel binary paketleri hedef sistemde doğrulanamadı.',
      );
      if (failure != null) return failure;
    }

    failure = await _requireCommand(
      ctx,
      'chroot',
      ['/mnt', 'sh', '-c', postInstallRoRepoValidationScript],
      'Ro repo ve kernel COPR repo dosyaları hedef sistemde doğrulanamadı.',
    );
    if (failure != null) return failure;

    failure = await _requireCommand(
      ctx,
      'chroot',
      ['/mnt', 'sh', '-c', postInstallRoDesktopAppsValidationScript],
      'Ro uygulamaları hedef sistemde doğrulanamadı: ro-assist, ro-control.',
    );
    if (failure != null) return failure;

    failure = await _requireCommand(ctx, 'chroot', [
      '/mnt',
      'rpm',
      '-q',
      'ro-theme',
    ], 'Ro tema paketi hedef sistemde doğrulanamadı.');
    if (failure != null) return failure;

    failure = await _requireCommand(ctx, 'test', [
      '-f',
      '/mnt/usr/share/plasma/look-and-feel/org.ro.dark/metadata.json',
    ], 'Ro dark global theme hedef sistemde bulunamadı.');
    if (failure != null) return failure;

    failure = await _requireCommand(ctx, 'test', [
      '-f',
      '/mnt/usr/share/color-schemes/RoDark.colors',
    ], 'RoDark renk şeması hedef sistemde bulunamadı.');
    if (failure != null) return failure;

    failure = await _requireCommand(ctx, 'test', [
      '-f',
      '/mnt/usr/share/sddm/themes/Ro/Main.qml',
    ], 'Ro SDDM teması hedef sistemde bulunamadı.');
    if (failure != null) return failure;

    failure = await _requireCommand(ctx, 'test', [
      '-f',
      '/mnt/usr/share/plymouth/themes/ro-theme/ro-theme.plymouth',
    ], 'Ro Plymouth teması hedef sistemde bulunamadı.');
    if (failure != null) return failure;

    failure = await _requireCommand(ctx, 'sh', [
      '-c',
      'grep -q "^LookAndFeelPackage=org.ro.dark\$" /mnt/etc/xdg/kdeglobals && grep -q "^ColorScheme=RoDark\$" /mnt/etc/xdg/kdeglobals',
    ], 'Ro tema KDE varsayılanları hedef sistemde etkin değil.');
    if (failure != null) return failure;

    failure = await _requireCommand(ctx, 'sh', [
      '-c',
      'grep -q "^name=RoDark\$" /mnt/etc/xdg/plasmarc',
    ], 'RoDark Plasma style hedef sistemde varsayılan değil.');
    if (failure != null) return failure;

    failure = await _requireCommand(ctx, 'sh', [
      '-c',
      'grep -q "^Theme=org.ro.dark\$" /mnt/etc/xdg/ksplashrc',
    ], 'Ro dark splash teması hedef sistemde varsayılan değil.');
    if (failure != null) return failure;

    failure = await _requireCommand(ctx, 'test', [
      '!',
      '-e',
      '/mnt/usr/bin/ro-installer',
    ], 'ro-installer kurulu sistemde kalmış görünüyor.');
    if (failure != null) return failure;

    failure = await _requireCommand(ctx, 'test', [
      '!',
      '-e',
      '/mnt/usr/bin/ro_installer',
    ], 'ro_installer kurulu sistemde kalmış görünüyor.');
    if (failure != null) return failure;

    failure = await _requireCommand(ctx, 'test', [
      '!',
      '-e',
      '/mnt/usr/libexec/ro-installer-launcher.sh',
    ], 'ro-installer launcher kurulu sistemde kalmış görünüyor.');
    if (failure != null) return failure;

    failure = await _requireCommand(ctx, 'test', [
      '!',
      '-e',
      '/mnt/usr/share/polkit-1/actions/org.roasd.installer.policy',
    ], 'ro-installer polkit policy kurulu sistemde kalmış görünüyor.');
    if (failure != null) return failure;

    failure = await _requireCommand(ctx, 'test', [
      '!',
      '-e',
      '/mnt/etc/polkit-1/rules.d/49-ro-installer-live.rules',
    ], 'Canlı oturum polkit kuralı hedef sisteme sızmış görünüyor.');
    if (failure != null) return failure;

    failure = await _requireCommand(ctx, 'test', [
      '!',
      '-e',
      '/mnt/etc/sudoers.d/ro-installer-live',
    ], 'Canlı oturum sudoers kuralı hedef sisteme sızmış görünüyor.');
    if (failure != null) return failure;

    failure = await _requireCommand(ctx, 'chroot', [
      '/mnt',
      'sh',
      '-c',
      '! getent passwd liveuser >/dev/null 2>&1',
    ], 'liveuser hesabı hedef sistemde kalmış görünüyor.');
    if (failure != null) return failure;

    failure = await _requireCommand(ctx, 'sh', [
      '-c',
      postInstallNoLiveUserSddmValidationScript,
    ], 'SDDM liveuser kalıntısı hedef sisteme sızmış görünüyor.');
    if (failure != null) return failure;

    failure = await _requireCommand(
      ctx,
      'chroot',
      ['/mnt', 'bash', '-c', postInstallPlasmaLauncherValidationScript],
      'Plasma panelinde eksik .desktop dosyasına işaret eden launcher kalmış görünüyor.',
    );
    if (failure != null) return failure;

    failure = await _requireCommand(
      ctx,
      'chroot',
      ['/mnt', 'rpm', '-q', 'dracut', 'grub2-efi-x64', 'shim-x64'],
      'Bootloader için gerekli paketler hedef sistemde doğrulanamadı.',
    );
    if (failure != null) return failure;

    failure = await _requireCommand(ctx, 'chroot', [
      '/mnt',
      'rpm',
      '-q',
      ...localeSettings.requiredPackages,
    ], 'Secilen dil destek paketleri hedef sistemde doğrulanamadı.');
    if (failure != null) return failure;

    failure = await _requireCommand(ctx, 'chroot', [
      '/mnt',
      'sh',
      '-c',
      postInstallKernelImageValidationScript,
    ], 'Kernel modül sürümüyle eşleşen kernel imajı bulunamadı.');
    if (failure != null) return failure;

    failure = await _requireCommand(ctx, 'sh', [
      '-c',
      'ls /mnt/boot/initramfs-*.img >/dev/null 2>&1',
    ], 'Initramfs dosyası /mnt/boot altında bulunamadı.');
    if (failure != null) return failure;

    failure = await _requireCommand(
      ctx,
      'test',
      ['-f', '/mnt/boot/efi/EFI/fedora/shimx64.efi'],
      'EFI shim dosyası /mnt/boot/efi/EFI/fedora/shimx64.efi bulunamadı.',
    );
    if (failure != null) return failure;

    failure = await _requireCommand(
      ctx,
      'test',
      ['-f', '/mnt/boot/efi/EFI/fedora/grubx64.efi'],
      'EFI GRUB binary dosyası /mnt/boot/efi/EFI/fedora/grubx64.efi bulunamadı.',
    );
    if (failure != null) return failure;

    failure = await _requireCommand(
      ctx,
      'test',
      ['-f', '/mnt/boot/efi/EFI/fedora/grub.cfg'],
      'EFI GRUB stub dosyası /mnt/boot/efi/EFI/fedora/grub.cfg bulunamadı.',
    );
    if (failure != null) return failure;

    failure = await _requireCommand(
      ctx,
      'sh',
      [
        '-c',
        r'grep -q "configfile \$prefix/grub.cfg" /mnt/boot/efi/EFI/fedora/grub.cfg',
      ],
      'EFI GRUB stub dosyası /boot/grub2/grub.cfg yönlendirmesini içermiyor.',
    );
    if (failure != null) return failure;

    failure = await _requireCommand(ctx, 'sh', [
      '-c',
      'ls /mnt/boot/efi/EFI/fedora/* >/dev/null 2>&1',
    ], 'EFI boot dosyaları /mnt/boot/efi/EFI/fedora altında bulunamadı.');
    if (failure != null) return failure;

    failure = await _requireCommand(ctx, 'findmnt', [
      '--verify',
      '--tab-file',
      '/mnt/etc/fstab',
    ], '/etc/fstab doğrulaması başarısız.');
    if (failure != null) return failure;

    final rootFs = (ctx.state['fileSystem'] ?? 'btrfs').toString();
    failure = await _validateBootReferences(ctx, rootFs);
    if (failure != null) return failure;

    if (!await ctx.runCmd(
      'sh',
      [
        '-c',
        'if grep -R -E "rd.live.image|inst.stage2|CDLABEL|root=live:" /mnt/etc/kernel/cmdline /mnt/boot/loader/entries >/dev/null 2>&1; then exit 1; else exit 0; fi',
      ],
      ctx.log,
      isMock: ctx.isMock,
    )) {
      return StageResult.fail(
        'Live ISO boot parametreleri hedef sisteme sızmış görünüyor.',
      );
    }

    failure = await _requireCommand(
      ctx,
      'sh',
      ['-c', postInstallNoGpuDebugArgsValidationScript],
      'Live/debug grafik boot parametreleri hedef sisteme sızmış görünüyor.',
    );
    if (failure != null) return failure;

    if (rootFs == 'btrfs') {
      failure = await _requireCommand(ctx, 'sh', [
        '-c',
        'grep -q "rootflags=subvol=@" /mnt/etc/kernel/cmdline',
      ], 'BTRFS kurulumunda rootflags=subvol=@ eksik.');
      if (failure != null) return failure;
    }

    if (_installationShouldHaveSwap(ctx.state)) {
      failure = await _requireCommand(ctx, 'sh', [
        '-c',
        'grep -Eq "[[:space:]]swap[[:space:]]" /mnt/etc/fstab',
      ], 'Hibernate için SWAP fstab girdisi eksik.');
      if (failure != null) return failure;

      failure = await _requireCommand(ctx, 'sh', [
        '-c',
        postInstallSwapResumeValidationScript,
      ], 'Hibernate için resume UUID, fstab SWAP girdisiyle eşleşmiyor.');
      if (failure != null) return failure;
    }

    ctx.log('[AŞAMA 8] Kurulum sonrası doğrulama başarıyla tamamlandı.');
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

  Future<StageResult?> _validateBootReferences(
    StageContext ctx,
    String rootFs,
  ) async {
    final rootUuid = await _readFindmntValue(
      ctx,
      mountPoint: '/mnt',
      field: 'UUID',
      errorMessage: 'Root bölümü UUID değeri okunamadı.',
    );
    if (rootUuid == null) {
      return StageResult.fail('Root bölümü UUID değeri okunamadı.');
    }

    var failure = await _requireCommand(ctx, 'sh', [
      '-c',
      'grep -Eq "^UUID=$rootUuid[[:space:]]+/[[:space:]]" /mnt/etc/fstab',
    ], '/etc/fstab root bölüm UUID girdisini içermiyor.');
    if (failure != null) return failure;

    failure = await _requireCommand(
      ctx,
      'sh',
      [
        '-c',
        'grep -Eq "(^|[[:space:]])root=UUID=$rootUuid([[:space:]]|\$)" /mnt/etc/kernel/cmdline',
      ],
      '/etc/kernel/cmdline root=UUID değerini hedef root bölümüyle eşleştirmiyor.',
    );
    if (failure != null) return failure;

    failure = await _requireCommand(ctx, 'sh', [
      '-c',
      'grep -R -E "^[[:space:]]*linux[[:space:]]+/[^[:space:]]*vmlinuz[^[:space:]]*" /mnt/boot/loader/entries/*.conf >/dev/null',
    ], 'BLS girişlerinde kernel imajı yolu bulunamadı.');
    if (failure != null) return failure;

    failure = await _requireCommand(ctx, 'sh', [
      '-c',
      'grep -R -E "^[[:space:]]*initrd[[:space:]]+/[^[:space:]]*initramfs[^[:space:]]*" /mnt/boot/loader/entries/*.conf >/dev/null',
    ], 'BLS girişlerinde initramfs yolu bulunamadı.');
    if (failure != null) return failure;

    failure = await _requireCommand(
      ctx,
      'sh',
      [
        '-c',
        'grep -R -E "^[[:space:]]*options[[:space:]].*root=UUID=$rootUuid([[:space:]]|\$)" /mnt/boot/loader/entries/*.conf >/dev/null',
      ],
      'BLS girişleri root=UUID değerini hedef root bölümüyle eşleştirmiyor.',
    );
    if (failure != null) return failure;

    if (rootFs == 'btrfs') {
      failure = await _requireCommand(ctx, 'sh', [
        '-c',
        'grep -R -E "^[[:space:]]*options[[:space:]].*rootflags=subvol=@" /mnt/boot/loader/entries/*.conf >/dev/null',
      ], 'BTRFS kurulumunda BLS rootflags=subvol=@ girdisi eksik.');
      if (failure != null) return failure;
    }

    final efiUuid = await _readFindmntValue(
      ctx,
      mountPoint: '/mnt/boot/efi',
      field: 'UUID',
      errorMessage: 'EFI bölümü UUID değeri okunamadı.',
    );
    if (efiUuid == null) {
      return StageResult.fail('EFI bölümü UUID değeri okunamadı.');
    }

    failure = await _requireCommand(ctx, 'sh', [
      '-c',
      'grep -Eq "^UUID=$efiUuid[[:space:]]+/boot/efi[[:space:]]+vfat[[:space:]]" /mnt/etc/fstab',
    ], '/etc/fstab EFI bölüm UUID girdisini içermiyor.');
    if (failure != null) return failure;

    return null;
  }

  Future<String?> _readFindmntValue(
    StageContext ctx, {
    required String mountPoint,
    required String field,
    required String errorMessage,
  }) async {
    if (ctx.isMock) {
      return mountPoint == '/mnt/boot/efi' ? 'MOCK-EFI-UUID' : 'MOCK-ROOT-UUID';
    }

    final result = await ctx.commandRunner.run('findmnt', [
      '-rn',
      '-o',
      field,
      mountPoint,
    ]);
    final value = result.stdout.trim().split('\n').first.trim();
    if (result.exitCode == 0 && value.isNotEmpty) {
      return value;
    }

    ctx.log('HATA: $errorMessage');
    return null;
  }
}

bool _installationShouldHaveSwap(Map<String, dynamic> state) {
  final partitionMethod = (state['partitionMethod'] ?? 'full').toString();
  if (partitionMethod == 'full' ||
      partitionMethod == 'alongside' ||
      partitionMethod == 'free_space') {
    return true;
  }

  if (partitionMethod == 'manual') {
    final manualPartitions =
        state['manualPartitions'] as List<dynamic>? ?? const [];
    return manualPartitions.any(
      (part) =>
          part is Map<String, dynamic> &&
          part['isFreeSpace'] != true &&
          part['mount'] == '[SWAP]',
    );
  }

  return false;
}

Set<String> _selectedKernelChannels(Map<String, dynamic> state) {
  final raw = state['selectedKernelChannels'];
  if (raw is Iterable) {
    final channels = raw
        .map((entry) => entry.toString().trim().toLowerCase())
        .where((entry) => entry.isNotEmpty)
        .toSet();
    return channels.isEmpty ? {'stable'} : channels;
  }

  if (raw is String && raw.trim().isNotEmpty) {
    final channels = raw
        .split(RegExp(r'[, ]+'))
        .map((entry) => entry.trim().toLowerCase())
        .where((entry) => entry.isNotEmpty)
        .toSet();
    return channels.isEmpty ? {'stable'} : channels;
  }

  final legacyKernel = (state['kernel'] ?? state['kernelType'] ?? '')
      .toString()
      .trim()
      .toLowerCase();
  if (legacyKernel == 'experimental') {
    return {'stable', 'experimental'};
  }

  return {'stable'};
}
