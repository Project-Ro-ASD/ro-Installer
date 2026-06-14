#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_DIR="${REPO_ROOT}/outputs/logs"
mkdir -p "${LOG_DIR}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_DIR}/02-build-iso-${TIMESTAMP}.log"

exec > >(tee -a "${LOG_FILE}") 2>&1

on_error() {
  local rc=$?
  echo "[ERROR] line=${BASH_LINENO[0]} cmd='${BASH_COMMAND}' exit_code=${rc}"
  echo "[ERROR] Detailed log: ${LOG_FILE}"
  exit "${rc}"
}
trap on_error ERR

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
  log "[FATAL] $*"
  log "[FATAL] Detailed log: ${LOG_FILE}"
  exit 1
}

cmd_exists() {
  command -v "$1" >/dev/null 2>&1
}

collect_missing_cmds() {
  local -n _required_ref="$1"
  local -n _missing_ref="$2"
  _missing_ref=()
  local cmd
  for cmd in "${_required_ref[@]}"; do
    if ! cmd_exists "${cmd}"; then
      _missing_ref+=("${cmd}")
    fi
  done
}

pkg_for_cmd() {
  case "$1" in
    xorriso) echo "xorriso" ;;
    unsquashfs|mksquashfs) echo "squashfs-tools" ;;
    fsck.erofs|mkfs.erofs) echo "erofs-utils" ;;
    erofsfuse) echo "erofs-fuse" ;;
    mdir) echo "mtools" ;;
    lsinitrd|dracut) echo "dracut" ;;
    setfiles) echo "policycoreutils" ;;
    blkid|chroot|mount|umount) echo "util-linux" ;;
    dd) echo "coreutils" ;;
    sed) echo "sed" ;;
    grep) echo "grep" ;;
    awk) echo "gawk" ;;
    iconv) echo "glibc-common" ;;
    *) return 1 ;;
  esac
}

ensure_host_tools() {
  local -a required_cmds=("$@")
  local -a missing_cmds=()
  collect_missing_cmds required_cmds missing_cmds
  if [[ ${#missing_cmds[@]} -eq 0 ]]; then
    return 0
  fi

  local cmd
  for cmd in "${missing_cmds[@]}"; do
    log "[MISSING] '${cmd}' not found."
  done

  if ! cmd_exists dnf; then
    die "Missing host tools and 'dnf' is unavailable for auto-install. Install: xorriso squashfs-tools erofs-utils mtools dracut util-linux sed grep gawk glibc-common policycoreutils"
  fi

  local -a pkgs=()
  local pkg=""
  for cmd in "${missing_cmds[@]}"; do
    pkg="$(pkg_for_cmd "${cmd}" || true)"
    if [[ -n "${pkg}" ]]; then
      pkgs+=("${pkg}")
    fi
  done

  if [[ ${#pkgs[@]} -eq 0 ]]; then
    die "Missing tools detected but no package mapping available."
  fi

  mapfile -t pkgs < <(printf '%s\n' "${pkgs[@]}" | awk 'NF && !seen[$0]++')
  log "Installing missing host packages: ${pkgs[*]}"
  dnf -y install "${pkgs[@]}"

  collect_missing_cmds required_cmds missing_cmds
  if [[ ${#missing_cmds[@]} -ne 0 ]]; then
    for cmd in "${missing_cmds[@]}"; do
      log "[MISSING] '${cmd}' still unavailable after install."
    done
    die "Host tool auto-install did not resolve all missing commands."
  fi
}

show_help() {
  cat <<'EOF'
Usage:
  scripts/02-build-iso.sh [options]

Options:
  --rpm PATH           Built ro-installer RPM path (default: rpm-outputs/latest-rpm-path.txt).
  --enable-ro-theme    Install and activate Ro theme from Ro repo. Enabled by default.
  --ro-theme-rpm PATH  Deprecated; accepted for compatibility and ignored.
  --source-iso PATH    Source Fedora KDE live ISO path.
  --beta N|betaN       Output ISO beta number. Default: auto increment.
  --output-dir PATH    Output directory (default: iso-realese).
  --work-root PATH     Temporary work root (default: outputs/iso-work).
  --keep-workdir       Keep temporary workdir even on success.
  -h, --help           Show help.
EOF
}

RPM_PATH=""
ENABLE_RO_THEME=1
SOURCE_ISO=""
BETA_INPUT="auto"
OUTPUT_DIR="${REPO_ROOT}/iso-realese"
WORK_ROOT="${REPO_ROOT}/outputs/iso-work"
KEEP_WORKDIR=0
SHOW_HELP=0
ORIGINAL_ARGS=("$@")

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rpm)
      [[ $# -ge 2 ]] || die "--rpm needs a value."
      RPM_PATH="$2"
      shift 2
      ;;
    --source-iso)
      [[ $# -ge 2 ]] || die "--source-iso needs a value."
      SOURCE_ISO="$2"
      shift 2
      ;;
    --live-kernel|--ro-kernel-dir)
      [[ $# -ge 2 ]] || die "$1 needs a value."
      log "[WARN] $1 is ignored. The ISO now installs ro-kernel-stable from COPR for live boot."
      shift 2
      ;;
    --ro-theme-rpm)
      [[ $# -ge 2 ]] || die "--ro-theme-rpm needs a value."
      log "[WARN] --ro-theme-rpm is deprecated and ignored. ro-theme is installed from Ro repo."
      shift 2
      ;;
    --enable-ro-theme)
      ENABLE_RO_THEME=1
      shift
      ;;
    --disable-ro-theme)
      ENABLE_RO_THEME=0
      shift
      ;;
    --beta)
      [[ $# -ge 2 ]] || die "--beta needs a value."
      BETA_INPUT="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || die "--output-dir needs a value."
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --work-root)
      [[ $# -ge 2 ]] || die "--work-root needs a value."
      WORK_ROOT="$2"
      shift 2
      ;;
    --keep-workdir)
      KEEP_WORKDIR=1
      shift
      ;;
    -h|--help)
      SHOW_HELP=1
      shift
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

if [[ ${SHOW_HELP} -eq 1 ]]; then
  show_help
  exit 0
fi

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo --preserve-env=PATH "$0" "${ORIGINAL_ARGS[@]}"
  fi
  die "This script needs root privileges. Run with sudo."
fi

ensure_host_tools xorriso unsquashfs mksquashfs fsck.erofs mkfs.erofs blkid chroot mount umount sed grep awk iconv setfiles dd mdir lsinitrd

if [[ -z "${RPM_PATH}" ]]; then
  if [[ -f "${REPO_ROOT}/rpm-outputs/latest-rpm-path.txt" ]]; then
    RPM_PATH="$(<"${REPO_ROOT}/rpm-outputs/latest-rpm-path.txt")"
  fi
fi
[[ -n "${RPM_PATH}" ]] || die "RPM path not provided and latest-rpm-path.txt not found."
[[ -f "${RPM_PATH}" ]] || die "RPM file not found: ${RPM_PATH}"

if [[ -z "${SOURCE_ISO}" ]]; then
  SOURCE_ISO="$(find "${REPO_ROOT}" -maxdepth 1 -type f -name 'Fedora-KDE-Desktop-Live-*.iso' | head -n 1 || true)"
fi
[[ -n "${SOURCE_ISO}" ]] || die "Source ISO not found. Use --source-iso PATH."
[[ -f "${SOURCE_ISO}" ]] || die "Source ISO not found: ${SOURCE_ISO}"
mkdir -p "${OUTPUT_DIR}" "${WORK_ROOT}"

next_beta_number() {
  local max=0
  local file name num
  for file in "${OUTPUT_DIR}"/Ro-ASD-beta*.iso; do
    [[ -e "${file}" ]] || continue
    name="$(basename "${file}")"
    num="${name#Ro-ASD-beta}"
    num="${num%.iso}"
    if [[ "${num}" =~ ^[0-9]+$ ]] && (( num > max )); then
      max="${num}"
    fi
  done
  echo $((max + 1))
}

if [[ "${BETA_INPUT}" == "auto" ]]; then
  BETA_NUM="$(next_beta_number)"
elif [[ "${BETA_INPUT}" =~ ^beta([0-9]+)$ ]]; then
  BETA_NUM="${BASH_REMATCH[1]}"
elif [[ "${BETA_INPUT}" =~ ^[0-9]+$ ]]; then
  BETA_NUM="${BETA_INPUT}"
else
  die "Invalid --beta value: ${BETA_INPUT}"
fi

BETA_TAG="beta${BETA_NUM}"
OUTPUT_ISO="${OUTPUT_DIR}/Ro-ASD-${BETA_TAG}.iso"
[[ ! -e "${OUTPUT_ISO}" ]] || die "Output ISO already exists: ${OUTPUT_ISO}"

VOLUME_ID="RO-ASD-BETA${BETA_NUM}"
if (( ${#VOLUME_ID} > 32 )); then
  VOLUME_ID="${VOLUME_ID:0:32}"
fi

WORK_BASE="${WORK_ROOT}/build-${BETA_TAG}-${TIMESTAMP}"
SQUASHFS_ORIG="${WORK_BASE}/LiveOS/squashfs.img.orig"
SQUASHFS_NEW="${WORK_BASE}/LiveOS/squashfs.img"
GRUB_CFG_LOCAL="${WORK_BASE}/boot/grub2/grub.cfg"
LIVE_KERNEL_LOCAL="${WORK_BASE}/boot/x86_64/loader/linux"
LIVE_INITRD_LOCAL="${WORK_BASE}/boot/x86_64/loader/initrd"
BOOTX64_CSV_LOCAL="${WORK_BASE}/EFI/fedora/BOOTX64.CSV"
BOOTIA32_CSV_LOCAL="${WORK_BASE}/EFI/fedora/BOOTIA32.CSV"
LOWER_DIR="${WORK_BASE}/mnt/lower"
UPPER_DIR="${WORK_BASE}/mnt/upper"
OVERLAY_WORK_DIR="${WORK_BASE}/mnt/work"
MERGED_DIR="${WORK_BASE}/mnt/merged"
INNER_ROOTFS_DIR="${WORK_BASE}/mnt/inner-rootfs"
mkdir -p "${WORK_BASE}" "${OUTPUT_DIR}"

BASE_MOUNTS=()
CHROOT_MOUNTS=()
SUCCESS=0
IMAGE_MODE=""
IMAGE_FSTYPE=""
TARGET_ROOT_DIR=""

mount_base_squash() {
  mkdir -p "${LOWER_DIR}"
  mount -t squashfs -o loop,ro "${SQUASHFS_ORIG}" "${LOWER_DIR}"
  BASE_MOUNTS+=("${LOWER_DIR}")
}

mount_base_erofs() {
  mkdir -p "${LOWER_DIR}"
  if mount -t erofs -o loop,ro "${SQUASHFS_ORIG}" "${LOWER_DIR}"; then
    BASE_MOUNTS+=("${LOWER_DIR}")
    return 0
  fi
  return 1
}

extract_base_erofs_fuse() {
  local fuse_dir="${WORK_BASE}/mnt/erofs-fuse"
  local unmount_cmd="umount"

  cmd_exists erofsfuse || return 1

  mkdir -p "${fuse_dir}" "${MERGED_DIR}"
  log "Trying erofsfuse extraction fallback..."
  if ! erofsfuse "${SQUASHFS_ORIG}" "${fuse_dir}"; then
    rm -rf "${fuse_dir}"
    return 1
  fi

  if cmd_exists fusermount3; then
    unmount_cmd="fusermount3 -u"
  elif cmd_exists fusermount; then
    unmount_cmd="fusermount -u"
  fi

  if rsync -aHAX --numeric-ids "${fuse_dir}/" "${MERGED_DIR}/"; then
    ${unmount_cmd} "${fuse_dir}" 2>/dev/null || umount -lf "${fuse_dir}" 2>/dev/null || true
    rm -rf "${fuse_dir}"
    return 0
  fi

  ${unmount_cmd} "${fuse_dir}" 2>/dev/null || umount -lf "${fuse_dir}" 2>/dev/null || true
  rm -rf "${fuse_dir}"
  return 1
}

extract_base_erofs() {
  mkdir -p "${MERGED_DIR}"
  log "Extracting erofs image with fsck.erofs fallback..."
  if fsck.erofs --extract="${MERGED_DIR}" "${SQUASHFS_ORIG}"; then
    return 0
  fi

  log "[WARN] fsck.erofs extraction failed."
  if extract_base_erofs_fuse; then
    return 0
  fi

  log "[ERROR] Could not read this Fedora Live EROFS image with host tools."
  log "[ERROR] Fedora 42+ live media uses EROFS. This ISO appears to need newer erofs kernel/userspace support than this host currently provides."
  log "[ERROR] On Fedora, update the tools and retry:"
  log "[ERROR]   sudo dnf upgrade --refresh --enablerepo=updates-testing erofs-utils erofs-fuse"
  log "[ERROR]   sudo dnf install -y erofs-utils erofs-fuse"
  log "[ERROR] Then verify with: fsck.erofs --version"
  return 1
}

mount_base_loop_rw() {
  mkdir -p "${MERGED_DIR}"
  cp --reflink=auto "${SQUASHFS_ORIG}" "${SQUASHFS_NEW}"
  mount -o loop,rw "${SQUASHFS_NEW}" "${MERGED_DIR}"
  BASE_MOUNTS+=("${MERGED_DIR}")
}

mount_base_overlay() {
  mkdir -p "${UPPER_DIR}" "${OVERLAY_WORK_DIR}" "${MERGED_DIR}"
  mount -t overlay overlay \
    -o "lowerdir=${LOWER_DIR},upperdir=${UPPER_DIR},workdir=${OVERLAY_WORK_DIR}" \
    "${MERGED_DIR}"
  BASE_MOUNTS+=("${MERGED_DIR}")
}

mount_chroot_bind() {
  local src="$1"
  local dst="$2"
  mkdir -p "${dst}"
  mount --bind "${src}" "${dst}"
  CHROOT_MOUNTS+=("${dst}")
}

mount_chroot_fs() {
  local type="$1"
  local src="$2"
  local dst="$3"
  mkdir -p "${dst}"
  mount -t "${type}" "${src}" "${dst}"
  CHROOT_MOUNTS+=("${dst}")
}

cleanup_chroot_mounts() {
  local idx
  for (( idx=${#CHROOT_MOUNTS[@]}-1; idx>=0; idx-- )); do
    umount -lf "${CHROOT_MOUNTS[$idx]}" 2>/dev/null || true
  done
  CHROOT_MOUNTS=()
}

cleanup_all_mounts() {
  local idx
  cleanup_chroot_mounts
  for (( idx=${#BASE_MOUNTS[@]}-1; idx>=0; idx-- )); do
    umount -lf "${BASE_MOUNTS[$idx]}" 2>/dev/null || true
  done
  BASE_MOUNTS=()
}

finalize_cleanup() {
  cleanup_all_mounts
  if [[ ${KEEP_WORKDIR} -eq 0 ]]; then
    rm -rf "${WORK_BASE}"
  fi
}
trap finalize_cleanup EXIT

log "Source ISO: ${SOURCE_ISO}"
log "RPM: ${RPM_PATH}"
log "Live boot kernel: ro-kernel-stable from COPR"
log "Ro repositories: ro-repo + ro-repo-noarch + Ro kernel COPR"
log "Ro desktop apps: ro-assist + ro-control from Ro repo"
if [[ ${ENABLE_RO_THEME} -eq 1 ]]; then
  log "Ro theme: ro-theme from Ro repo"
else
  log "Ro theme: disabled"
fi
log "Output ISO: ${OUTPUT_ISO}"
log "Volume ID: ${VOLUME_ID}"

SOURCE_BYTES="$(stat -c '%s' "${SOURCE_ISO}")"
SOURCE_KB="$(((SOURCE_BYTES + 1023) / 1024))"
WORK_FS="$(df -Pk "${WORK_ROOT}" | awk 'NR==2 {print $1}')"
OUTPUT_FS="$(df -Pk "${OUTPUT_DIR}" | awk 'NR==2 {print $1}')"
WORK_AVAIL_KB="$(df -Pk "${WORK_ROOT}" | awk 'NR==2 {print $4}')"
OUTPUT_AVAIL_KB="$(df -Pk "${OUTPUT_DIR}" | awk 'NR==2 {print $4}')"

# Bu akista tepe kullanim:
# - Asama 1 (squashfs uretilirken): eski squashfs + yeni squashfs + overlay degisiklikleri
# - Asama 2 (iso yazilirken): yeni squashfs + yeni iso
WORK_NEED_KB=$((SOURCE_KB * 2 + 1024 * 1024))   # +1 GiB pay
OUTPUT_NEED_KB=$((SOURCE_KB + 512 * 1024))      # +512 MiB pay

if [[ "${WORK_FS}" == "${OUTPUT_FS}" ]]; then
  if (( WORK_AVAIL_KB < WORK_NEED_KB )); then
    die "Not enough free space on filesystem ${WORK_FS}. Need ~$(awk "BEGIN {printf \"%.1f\", ${WORK_NEED_KB}/1024/1024}") GiB, available ~$(awk "BEGIN {printf \"%.1f\", ${WORK_AVAIL_KB}/1024/1024}") GiB. Free space or use --work-root/--output-dir on a larger disk."
  fi
else
  if (( WORK_AVAIL_KB < WORK_NEED_KB )); then
    die "Not enough free space under ${WORK_ROOT}. Need ~$(awk "BEGIN {printf \"%.1f\", ${WORK_NEED_KB}/1024/1024}") GiB, available ~$(awk "BEGIN {printf \"%.1f\", ${WORK_AVAIL_KB}/1024/1024}") GiB."
  fi
  if (( OUTPUT_AVAIL_KB < OUTPUT_NEED_KB )); then
    die "Not enough free space under ${OUTPUT_DIR}. Need ~$(awk "BEGIN {printf \"%.1f\", ${OUTPUT_NEED_KB}/1024/1024}") GiB, available ~$(awk "BEGIN {printf \"%.1f\", ${OUTPUT_AVAIL_KB}/1024/1024}") GiB."
  fi
fi

extract_iso_file() {
  local iso_src="$1"
  local local_dst="$2"
  mkdir -p "$(dirname "${local_dst}")"
  xorriso -osirrox on -indev "${SOURCE_ISO}" -extract "${iso_src}" "${local_dst}" -end
}

extract_iso_file_optional() {
  local iso_src="$1"
  local local_dst="$2"
  mkdir -p "$(dirname "${local_dst}")"
  if xorriso -osirrox on -indev "${SOURCE_ISO}" -extract "${iso_src}" "${local_dst}" -end; then
    return 0
  fi
  rm -f "${local_dst}"
  log "[WARN] Optional ISO path not found: ${iso_src}"
}

verify_source_iso_checksum() {
  local source_dir source_name checksum_file
  source_dir="$(dirname "${SOURCE_ISO}")"
  source_name="$(basename "${SOURCE_ISO}")"

  checksum_file="$(find "${source_dir}" -maxdepth 1 -type f -name '*CHECKSUM' -print | sort | head -n 1 || true)"
  if [[ -z "${checksum_file}" ]]; then
    log "[WARN] No Fedora CHECKSUM file found next to source ISO; skipping source ISO checksum verification."
    log "[WARN] Place the official *CHECKSUM file beside ${source_name} to catch corrupt downloads before build."
    return 0
  fi

  if ! grep -Fq "${source_name}" "${checksum_file}"; then
    log "[WARN] CHECKSUM file does not mention ${source_name}: ${checksum_file}"
    return 0
  fi

  log "Verifying source ISO checksum with ${checksum_file}..."
  (
    cd "${source_dir}"
    sha256sum -c "$(basename "${checksum_file}")" --ignore-missing
  ) || die "Source ISO checksum verification failed: ${SOURCE_ISO}"
}

log "Extracting required files from source ISO..."
verify_source_iso_checksum
extract_iso_file "/LiveOS/squashfs.img" "${SQUASHFS_ORIG}"
extract_iso_file "/boot/grub2/grub.cfg" "${GRUB_CFG_LOCAL}"
extract_iso_file_optional "/EFI/fedora/BOOTX64.CSV" "${BOOTX64_CSV_LOCAL}"
extract_iso_file_optional "/EFI/fedora/BOOTIA32.CSV" "${BOOTIA32_CSV_LOCAL}"

RPM_BASENAME="$(basename "${RPM_PATH}")"

IMAGE_FSTYPE="$(blkid -p -o value -s TYPE "${SQUASHFS_ORIG}" 2>/dev/null || true)"
if [[ -z "${IMAGE_FSTYPE}" ]] && command -v file >/dev/null 2>&1; then
  if file "${SQUASHFS_ORIG}" | grep -qi 'squashfs'; then
    IMAGE_FSTYPE="squashfs"
  fi
fi
log "Detected LiveOS image filesystem type: ${IMAGE_FSTYPE:-unknown}"

if [[ "${IMAGE_FSTYPE}" == "squashfs" ]]; then
  IMAGE_MODE="overlay_squashfs"
  log "Mounting base squashfs (ro) and overlay (rw)..."
  mount_base_squash
  if [[ -f "${LOWER_DIR}/LiveOS/rootfs.img" ]] && [[ ! -x "${LOWER_DIR}/usr/bin/env" ]]; then
    die "Unsupported live layout detected: outer squashfs contains LiveOS/rootfs.img. Bu betik su an bu layout'u otomatik patchlemiyor."
  fi
  mount_base_overlay
elif [[ "${IMAGE_FSTYPE}" == "erofs" ]]; then
  log "Mounting base erofs (ro) and overlay (rw)..."
  if mount_base_erofs; then
    IMAGE_MODE="overlay_erofs"
    mount_base_overlay
  else
    IMAGE_MODE="extracted_erofs"
    log "[WARN] Kernel erofs mount failed; using fsck.erofs extraction fallback."
    extract_base_erofs
  fi
else
  IMAGE_MODE="loop_rw_image"
  log "Mounting LiveOS image as writable loop filesystem..."
  mount_base_loop_rw
fi

TARGET_ROOT_DIR="${MERGED_DIR}"
if [[ ! -x "${TARGET_ROOT_DIR}/usr/bin/env" ]]; then
  if [[ "${IMAGE_MODE}" == "loop_rw_image" && -f "${MERGED_DIR}/LiveOS/rootfs.img" ]]; then
    log "Detected nested LiveOS/rootfs.img layout; mounting inner rootfs image..."
    mkdir -p "${INNER_ROOTFS_DIR}"
    mount -o loop,rw "${MERGED_DIR}/LiveOS/rootfs.img" "${INNER_ROOTFS_DIR}"
    BASE_MOUNTS+=("${INNER_ROOTFS_DIR}")
    TARGET_ROOT_DIR="${INNER_ROOTFS_DIR}"
  fi
fi

if [[ ! -x "${TARGET_ROOT_DIR}/usr/bin/env" ]]; then
  die "Mounted image does not look like a Linux root filesystem (/usr/bin/env missing)."
fi

install -Dm644 "${RPM_PATH}" "${TARGET_ROOT_DIR}/var/tmp/${RPM_BASENAME}"
RO_THEME_RPM_ARG="__ro-theme-disabled__"
if [[ ${ENABLE_RO_THEME} -eq 1 ]]; then
  RO_THEME_RPM_ARG="__ro-theme-from-ro-repo__"
fi
if [[ -f /etc/resolv.conf ]]; then
  cp -Lf /etc/resolv.conf "${TARGET_ROOT_DIR}/etc/resolv.conf"
fi

log "Mounting pseudo filesystems for chroot..."
mount_chroot_bind /dev "${TARGET_ROOT_DIR}/dev"
mount_chroot_bind /dev/pts "${TARGET_ROOT_DIR}/dev/pts"
mount_chroot_fs proc proc "${TARGET_ROOT_DIR}/proc"
mount_chroot_fs sysfs sysfs "${TARGET_ROOT_DIR}/sys"

cat > "${TARGET_ROOT_DIR}/var/tmp/ro-live-customize.sh" <<'CHROOT_SCRIPT'
#!/usr/bin/env bash
set -euxo pipefail

installer_rpm="$1"
enable_ro_theme="$2"
theme_source="$3"
shift 3

write_ro_repos() {
  mkdir -p /etc/yum.repos.d
  cat > /etc/yum.repos.d/ro-repo.repo <<'EOF'
[ro-repo]
name=Acik Kaynak Gelistirme Toplulugu Repo
baseurl=https://project-ro-asd.github.io/Ro-Repo/$basearch/
enabled=1
gpgcheck=0
EOF

  cat > /etc/yum.repos.d/ro-repo-noarch.repo <<'EOF'
[ro-repo-noarch]
name=Acik Kaynak Gelistirme Toplulugu Repo - Noarch
baseurl=https://project-ro-asd.github.io/Ro-Repo/noarch/
enabled=1
gpgcheck=0
EOF

  cat > /etc/yum.repos.d/ro-kernel-stable-copr.repo <<'EOF'
[copr:copr.fedorainfracloud.org:hynkzz:ro-kernel-stable]
name=Copr repo for ro-kernel-stable owned by hynkzz
baseurl=https://download.copr.fedorainfracloud.org/results/hynkzz/ro-kernel-stable/fedora-$releasever-$basearch/
type=rpm-md
skip_if_unavailable=False
gpgcheck=1
gpgkey=https://download.copr.fedorainfracloud.org/results/hynkzz/ro-kernel-stable/pubkey.gpg
repo_gpgcheck=0
enabled=1
enabled_metadata=1
EOF

  cat > /etc/yum.repos.d/ro-kernel-experimental-copr.repo <<'EOF'
[copr:copr.fedorainfracloud.org:hynkzz:ro-Kernel-Experimental]
name=Copr repo for ro-Kernel-Experimental owned by hynkzz
baseurl=https://download.copr.fedorainfracloud.org/results/hynkzz/ro-Kernel-Experimental/fedora-$releasever-$basearch/
type=rpm-md
skip_if_unavailable=True
gpgcheck=1
gpgkey=https://download.copr.fedorainfracloud.org/results/hynkzz/ro-Kernel-Experimental/pubkey.gpg
repo_gpgcheck=0
enabled=0
enabled_metadata=1
EOF
}

write_ro_kernel_protection() {
  mkdir -p /etc/dnf/protected.d
  cat > /etc/dnf/protected.d/ro-kernel.conf <<'EOF'
ro-kernel-stable
ro-kernel-stable-core
ro-kernel-stable-modules
ro-kernel-stable-devel
ro-kernel-experimental
ro-kernel-experimental-core
ro-kernel-experimental-modules
ro-kernel-experimental-devel
EOF
}

write_stock_kernel_excludes() {
  mkdir -p /etc/dnf
  touch /etc/dnf/dnf.conf
  if ! grep -q '^\[main\]' /etc/dnf/dnf.conf; then
    printf '\n[main]\n' >> /etc/dnf/dnf.conf
  fi
  sed -i '/^# Ro-ASD stock kernel policy$/,/^# End Ro-ASD stock kernel policy$/d' /etc/dnf/dnf.conf
  cat >> /etc/dnf/dnf.conf <<'EOF'
# Ro-ASD stock kernel policy
excludepkgs=kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra kernel-devel kernel-devel-matched kernel-debug kernel-debug-core kernel-debug-modules kernel-debug-modules-core kernel-debug-modules-extra kernel-debug-devel kernel-uki kernel-uki-core kernel-uki-modules kernel-uki-modules-core kernel-uki-modules-extra
# End Ro-ASD stock kernel policy
EOF
}

remove_fedora_stock_kernels() {
  local stock_kernel_packages=(
    kernel
    kernel-core
    kernel-modules
    kernel-modules-core
    kernel-modules-extra
    kernel-devel
    kernel-devel-matched
    kernel-debug
    kernel-debug-core
    kernel-debug-modules
    kernel-debug-modules-core
    kernel-debug-modules-extra
    kernel-debug-devel
    kernel-uki
    kernel-uki-core
    kernel-uki-modules
    kernel-uki-modules-core
    kernel-uki-modules-extra
  )

  dnf -y remove "${stock_kernel_packages[@]}" || true
  if rpm -qa | grep -Eq '^(kernel|kernel-core|kernel-modules|kernel-modules-core|kernel-modules-extra|kernel-devel|kernel-devel-matched|kernel-debug|kernel-debug-core|kernel-debug-modules|kernel-debug-modules-core|kernel-debug-modules-extra|kernel-debug-devel|kernel-uki|kernel-uki-core|kernel-uki-modules|kernel-uki-modules-core|kernel-uki-modules-extra)-[0-9]'; then
    rpm -qa | grep -E '^(kernel|kernel-core|kernel-modules|kernel-modules-core|kernel-modules-extra|kernel-devel|kernel-devel-matched|kernel-debug|kernel-debug-core|kernel-debug-modules|kernel-debug-modules-core|kernel-debug-modules-extra|kernel-debug-devel|kernel-uki|kernel-uki-core|kernel-uki-modules|kernel-uki-modules-core|kernel-uki-modules-extra)-[0-9]' >&2 || true
    echo "[ERROR] Fedora stock kernel packages remain installed." >&2
    return 1
  fi
}

install_ro_stable_kernel() {
  local stable_packages=(
    ro-kernel-stable
    ro-kernel-stable-core
    ro-kernel-stable-modules
    ro-kernel-stable-devel
  )

  dnf -y --refresh --setopt=install_weak_deps=False install "${stable_packages[@]}"
  rpm -q "${stable_packages[@]}"
  remove_fedora_stock_kernels
}

prepare_live_ro_kernel_artifacts() {
  local stable_kver=""
  local image=""
  local module_dir=""

  stable_kver="$(rpm -ql ro-kernel-stable-core ro-kernel-stable-modules 2>/dev/null | awk -F/ '
    $2 == "lib" && $3 == "modules" && $4 != "" { print $4 }
    $2 == "usr" && $3 == "lib" && $4 == "modules" && $5 != "" { print $5 }
  ' | sort -u | grep -E 'ro[_-]stable|ro_stable|ro-stable' | sort -V | tail -n 1)"

  if [[ -z "${stable_kver}" ]]; then
    stable_kver="$(find /lib/modules /usr/lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | grep -E 'ro[_-]stable|ro_stable|ro-stable' | sort -V | tail -n 1)"
  fi
  [[ -n "${stable_kver}" ]] || {
    echo "[ERROR] Could not detect ro-kernel-stable module version." >&2
    return 1
  }

  module_dir="/lib/modules/${stable_kver}"
  [[ -d "${module_dir}" ]] || module_dir="/usr/lib/modules/${stable_kver}"
  [[ -d "${module_dir}" ]] || {
    echo "[ERROR] Module directory missing for ${stable_kver}." >&2
    return 1
  }

  image="/boot/vmlinuz-${stable_kver}"
  if [[ ! -f "${image}" ]]; then
    image="${module_dir}/vmlinuz"
  fi
  [[ -f "${image}" ]] || {
    echo "[ERROR] Kernel image missing for ${stable_kver}." >&2
    return 1
  }

  dracut -f --no-hostonly --add 'dmsquash-live livenet pollcdrom' /var/tmp/ro-live-initrd.img "${stable_kver}"
  test -s /var/tmp/ro-live-initrd.img
  printf '%s\n' "${stable_kver}" > /var/tmp/ro-live-kernel-version
  printf '%s\n' "${image}" > /var/tmp/ro-live-kernel-image
}

write_live_kernel_config_manifest() {
  local stable_kver
  local module_dir
  local config_file=""
  local option
  local value
  local required_options=(
    CONFIG_DRM_I915
    CONFIG_DRM_XE
    CONFIG_DRM_NOUVEAU
    CONFIG_DRM_SIMPLEDRM
    CONFIG_VMD
    CONFIG_TYPEC
    CONFIG_I2C_HID_ACPI
    CONFIG_MMC
  )

  stable_kver="$(< /var/tmp/ro-live-kernel-version)"
  module_dir="/lib/modules/${stable_kver}"
  [[ -d "${module_dir}" ]] || module_dir="/usr/lib/modules/${stable_kver}"

  for candidate in "/boot/config-${stable_kver}" "${module_dir}/config"; do
    if [[ -f "${candidate}" ]]; then
      config_file="${candidate}"
      break
    fi
  done

  {
    printf 'kernel=%s\n' "${stable_kver}"
    if [[ -z "${config_file}" ]]; then
      printf 'CONFIG_SOURCE=missing\n'
      for option in "${required_options[@]}"; do
        printf '%s=missing\n' "${option}"
      done
      return 0
    fi

    printf 'CONFIG_SOURCE=%s\n' "${config_file}"
    for option in "${required_options[@]}"; do
      value="$(grep -E "^${option}=(y|m)$" "${config_file}" | tail -n 1 || true)"
      if [[ -n "${value}" ]]; then
        printf '%s\n' "${value}"
      elif grep -Eq "^# ${option} is not set$" "${config_file}"; then
        printf '%s=n\n' "${option}"
      else
        printf '%s=missing\n' "${option}"
      fi
    done
  } > /var/tmp/ro-live-kernel-config-check.txt
}

write_live_firmware_manifest() {
  local firmware_dirs=()
  local root
  local count

  for root in /usr/lib/firmware /lib/firmware; do
    [[ -d "${root}" ]] && firmware_dirs+=("${root}")
  done

  count_firmware() {
    local pattern="$1"
    if [[ ${#firmware_dirs[@]} -eq 0 ]]; then
      printf '0\n'
      return 0
    fi
    count="$(find "${firmware_dirs[@]}" -type f -path "${pattern}" 2>/dev/null | sort -u | wc -l)"
    printf '%s\n' "${count//[[:space:]]/}"
  }

  {
    printf 'FIRMWARE_I915=%s\n' "$(count_firmware '*/i915/*.bin')"
    printf 'FIRMWARE_XE=%s\n' "$(count_firmware '*/xe/*.bin')"
    printf 'FIRMWARE_NVIDIA_GSP=%s\n' "$(count_firmware '*/nvidia/*/gsp*.bin')"
  } > /var/tmp/ro-live-firmware-check.txt
}

write_ro_theme_defaults() {
  mkdir -p /etc/sddm.conf.d /etc/xdg
  cat > /etc/sddm.conf.d/99-ro-theme.conf <<'EOF'
[Theme]
Current=Ro
EOF

  cat > /etc/xdg/kdeglobals <<'EOF'
[KDE]
LookAndFeelPackage=org.ro.dark
ColorScheme=RoDark

[General]
TerminalApplication=kitty
TerminalService=kitty.desktop

[Icons]
Theme=breeze
EOF

  cat > /etc/xdg/plasmarc <<'EOF'
[Theme]
name=RoDark
EOF

  cat > /etc/xdg/ksplashrc <<'EOF'
[KSplash]
Engine=KSplashQML
Theme=org.ro.dark
EOF

  cat > /etc/xdg/kscreenlockerrc <<'EOF'
[Greeter]
WallpaperPlugin=org.kde.image

[Greeter][Wallpaper][org.kde.image][General]
Image=file:///usr/share/plasma/look-and-feel/org.ro.dark/contents/lockscreen/assets/login.jpg
PreviewImage=file:///usr/share/plasma/look-and-feel/org.ro.dark/contents/lockscreen/assets/login.jpg
EOF

  cat > /etc/xdg/kwinrc <<'EOF'
[org.kde.kdecoration2]
library=org.kde.breeze
theme=Breeze

[Plugins]
kwin4_effect_scaleEnabled=false
kwin4_effect_glideEnabled=false
kwin4_effect_squashEnabled=false
kwin4_effect_magiclampEnabled=false
magiclampEnabled=false
kwin4_effect_windowapertureEnabled=false
kwin4_effect_frozenappEnabled=false
ro-smooth-motionEnabled=false
EOF

  local plymouth_theme="ro-theme"
  if [[ ! -e /usr/lib64/plymouth/script.so && ! -e /usr/lib/plymouth/script.so ]]; then
    plymouth_theme="bgrt"
  fi

  if command -v plymouth-set-default-theme >/dev/null 2>&1; then
    plymouth-set-default-theme "${plymouth_theme}" || true
  elif [[ -x /usr/libexec/plymouth/plymouth-set-default-theme ]]; then
    /usr/libexec/plymouth/plymouth-set-default-theme "${plymouth_theme}" || true
  fi
}

disable_ro_theme_defaults() {
  rm -f /etc/sddm.conf.d/99-ro-theme.conf /etc/sddm.conf.d/ro-theme.conf

  if command -v plymouth-set-default-theme >/dev/null 2>&1; then
    plymouth-set-default-theme bgrt || plymouth-set-default-theme spinner || true
  elif [[ -x /usr/libexec/plymouth/plymouth-set-default-theme ]]; then
    /usr/libexec/plymouth/plymouth-set-default-theme bgrt || /usr/libexec/plymouth/plymouth-set-default-theme spinner || true
  fi
}

write_live_graphics_compat() {
  local live_session="plasma.desktop"

  if [[ -f /usr/share/wayland-sessions/plasma.desktop ]]; then
    live_session="plasma.desktop"
  elif [[ -f /usr/share/wayland-sessions/plasmawayland.desktop ]]; then
    live_session="plasmawayland.desktop"
  elif [[ -f /usr/share/xsessions/plasmax11.desktop ]]; then
    echo "[WARN] Plasma Wayland session not found; falling back to X11 live session." >&2
    live_session="plasmax11.desktop"
  elif [[ -f /usr/share/xsessions/plasma.desktop ]]; then
    echo "[WARN] Plasma Wayland session not found; falling back to X11 live session." >&2
    live_session="plasma.desktop"
  fi

  # Keep the live installer close to Fedora KDE defaults: prefer Wayland when
  # present and leave nouveau/i915/xe selection to the stock Fedora stack.
  cat > /etc/sddm.conf <<EOF
[Autologin]
User=liveuser
Session=${live_session}
EOF

  mkdir -p /usr/libexec /etc/systemd/system

  cat > /usr/libexec/ro-live-session-compat.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

cmdline="$(cat /proc/cmdline 2>/dev/null || true)"

has_arg() {
  local needle="$1"
  [[ " ${cmdline} " == *" ${needle} "* ]]
}

pick_session() {
  local mode="$1"
  case "${mode}" in
    x11)
      if [[ -f /usr/share/xsessions/plasmax11.desktop ]]; then
        printf '%s\n' plasmax11.desktop
      elif [[ -f /usr/share/xsessions/plasma.desktop ]]; then
        printf '%s\n' plasma.desktop
      else
        printf '%s\n' plasma.desktop
      fi
      ;;
    wayland|*)
      if [[ -f /usr/share/wayland-sessions/plasma.desktop ]]; then
        printf '%s\n' plasma.desktop
      elif [[ -f /usr/share/wayland-sessions/plasmawayland.desktop ]]; then
        printf '%s\n' plasmawayland.desktop
      elif [[ -f /usr/share/xsessions/plasmax11.desktop ]]; then
        printf '%s\n' plasmax11.desktop
      elif [[ -f /usr/share/xsessions/plasma.desktop ]]; then
        printf '%s\n' plasma.desktop
      else
        printf '%s\n' plasma.desktop
      fi
      ;;
  esac
}

session_mode="wayland"
if has_arg "ro.live.session=x11"; then
  session_mode="x11"
elif has_arg "ro.live.session=wayland"; then
  session_mode="wayland"
fi

live_session="$(pick_session "${session_mode}")"
cat > /etc/sddm.conf <<SDDM_EOF
[Autologin]
User=liveuser
Session=${live_session}
SDDM_EOF

if has_arg "ro.live.software_render=1"; then
  mkdir -p /etc/environment.d
  cat > /etc/environment.d/20-ro-live-graphics.conf <<'ENV_EOF'
LIBGL_ALWAYS_SOFTWARE=1
QT_QUICK_BACKEND=software
KWIN_COMPOSE=Q
ENV_EOF
else
  rm -f /etc/environment.d/20-ro-live-graphics.conf 2>/dev/null || true
fi
EOF
  chmod 0755 /usr/libexec/ro-live-session-compat.sh

  cat > /etc/systemd/system/ro-live-session-compat.service <<'EOF'
[Unit]
Description=Ro-ASD live session compatibility selector
DefaultDependencies=no
After=local-fs.target
Before=sddm.service display-manager.service
ConditionPathExists=/run/initramfs/live

[Service]
Type=oneshot
ExecStart=/usr/libexec/ro-live-session-compat.sh

[Install]
WantedBy=graphical.target
EOF

  ln -sfn /usr/lib/systemd/system/graphical.target /etc/systemd/system/default.target
  systemctl enable ro-live-session-compat.service 2>/dev/null || true
  systemctl enable sddm.service 2>/dev/null || true
}

write_live_cursor_compat() {
  mkdir -p \
    /etc/xdg/plasma-workspace/env \
    /etc/environment.d \
    /etc/xdg \
    /etc/gtk-3.0 \
    /etc/gtk-4.0

  # Live installer oturumunda hardware cursor plane sorunlari imleci
  # aralikli gorunmez yapabiliyor. KWin icin software cursor yalnizca
  # live oturumda acilir; kurulu sistemde ChrootConfigStage temizler.
  cat > /etc/xdg/plasma-workspace/env/10-ro-live-cursor.sh <<'EOF'
#!/bin/sh
export KWIN_FORCE_SW_CURSOR=1
export XCURSOR_THEME=breeze_cursors
export XCURSOR_SIZE=24
EOF
  chmod 0755 /etc/xdg/plasma-workspace/env/10-ro-live-cursor.sh

  cat > /etc/environment.d/10-ro-live-cursor.conf <<'EOF'
KWIN_FORCE_SW_CURSOR=1
XCURSOR_THEME=breeze_cursors
XCURSOR_SIZE=24
EOF

  cat > /etc/xdg/kcminputrc <<'EOF'
[Mouse]
cursorTheme=breeze_cursors
cursorSize=24
EOF

  cat > /etc/gtk-3.0/settings.ini <<'EOF'
[Settings]
gtk-cursor-theme-name=breeze_cursors
gtk-cursor-theme-size=24
EOF

  cat > /etc/gtk-4.0/settings.ini <<'EOF'
[Settings]
gtk-cursor-theme-name=breeze_cursors
gtk-cursor-theme-size=24
EOF
}

validate_kde_wayland_runtime() {
  local ldd_log="/var/tmp/ro-kwin-wayland-ldd.log"
  local abi_path

  echo "[INFO] Validating KDE Wayland runtime ABI..."
  if ! ldd -r /usr/bin/kwin_wayland > "${ldd_log}" 2>&1; then
    cat "${ldd_log}" >&2 || true
    echo "[ERROR] kwin_wayland dynamic linker check failed." >&2
    return 1
  fi

  if grep -q 'undefined symbol' "${ldd_log}"; then
    cat "${ldd_log}" >&2 || true
    echo "[ERROR] KDE Wayland runtime has unresolved symbols; package set is ABI-inconsistent." >&2
    echo "[ERROR] Relevant package owners:" >&2
    for abi_path in \
      /usr/bin/kwin_wayland \
      /lib64/libkwin.so.6 \
      /lib64/libkdecorations3.so.* \
      /lib64/libkdecorations3private.so.* \
      /lib64/libQt6Core.so.6 \
      /lib64/libQt6Gui.so.6; do
      if [[ -e "${abi_path}" ]]; then
        rpm -qf "${abi_path}" || true
      fi
    done | sort -u >&2
    return 1
  fi

  rm -f "${ldd_log}"
}

validate_ro_desktop_apps() {
  local ro_assist_bin
  local ro_control_bin
  rpm -q ro-assist ro-control
  ro_assist_bin="$(command -v ro-assist)"
  ro_control_bin="$(command -v ro-control)"
  test -x "${ro_assist_bin}"
  test -x "${ro_control_bin}"
  ldd -r "${ro_assist_bin}"
  ldd -r "${ro_control_bin}"
}

upgrade_kde_wayland_runtime() {
  local kde_runtime_pkgs=(
    kdecoration
    kwin
    kwin-common
    kwin-libs
  )

  # DNF install does not necessarily upgrade already-installed packages. Keep
  # KWin and KDecoration on the same Plasma ABI before running ldd -r.
  dnf -y --refresh --best upgrade "${kde_runtime_pkgs[@]}"
  rpm -q "${kde_runtime_pkgs[@]}"
}

disable_kde_welcome() {
  dnf -y remove plasma-welcome || true
  mkdir -p /etc/xdg/autostart
  cat > /etc/xdg/autostart/org.kde.plasma-welcome.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=KDE Welcome
Hidden=true
NoDisplay=true
EOF
}

write_ro_repos
test -f /etc/yum.repos.d/ro-repo.repo
test -f /etc/yum.repos.d/ro-repo-noarch.repo
test -f /etc/yum.repos.d/ro-kernel-stable-copr.repo
test -f /etc/yum.repos.d/ro-kernel-experimental-copr.repo
install_pkgs=(
  "${installer_rpm}"
  gdisk
  kdecoration
  ro-assist
  ro-control
)
if [[ "${enable_ro_theme}" == "1" ]]; then
  install_pkgs+=(ro-theme)
fi
dnf -y --refresh --setopt=install_weak_deps=False install "${install_pkgs[@]}"
upgrade_kde_wayland_runtime
command -v sgdisk
command -v ro-installer
rpm -q gdisk kdecoration ro-installer ro-assist ro-control
validate_ro_desktop_apps
test -x /usr/bin/startplasma-wayland
test -x /usr/bin/kwin_wayland
test -f /usr/share/wayland-sessions/plasma.desktop -o -f /usr/share/wayland-sessions/plasmawayland.desktop
validate_kde_wayland_runtime
if [[ "${enable_ro_theme}" == "1" ]]; then
  rpm -q ro-theme
fi

echo "[INFO] Installing ro-kernel-stable and removing Fedora stock live kernel/modules."
write_ro_kernel_protection
install_ro_stable_kernel
write_stock_kernel_excludes
prepare_live_ro_kernel_artifacts
write_live_kernel_config_manifest
write_live_firmware_manifest

validate_kde_wayland_runtime
disable_kde_welcome
if [[ "${enable_ro_theme}" == "1" ]]; then
  write_ro_theme_defaults
  test -f /usr/share/plasma/look-and-feel/org.ro.dark/metadata.json
  test -f /usr/share/color-schemes/RoDark.colors
  test -f /usr/share/sddm/themes/Ro/Main.qml
  test -f /usr/share/plymouth/themes/ro-theme/ro-theme.plymouth
else
  disable_ro_theme_defaults
fi
write_live_graphics_compat
write_live_cursor_compat

dnf clean all
cleanup_rpms=("${installer_rpm}")
rm -f "${cleanup_rpms[@]}"
CHROOT_SCRIPT
chmod 0755 "${TARGET_ROOT_DIR}/var/tmp/ro-live-customize.sh"

if [[ ${ENABLE_RO_THEME} -eq 1 ]]; then
  log "Installing installer, Ro theme, Ro desktop apps and Ro kernel policy inside live rootfs..."
else
  log "Installing installer, Ro desktop apps and Ro kernel policy inside live rootfs (Ro theme disabled)..."
fi
chroot "${TARGET_ROOT_DIR}" /usr/bin/env bash -euxo pipefail /var/tmp/ro-live-customize.sh "/var/tmp/${RPM_BASENAME}" "${ENABLE_RO_THEME}" "${RO_THEME_RPM_ARG}"

RO_LIVE_KERNEL_IMAGE_REL="$(<"${TARGET_ROOT_DIR}/var/tmp/ro-live-kernel-image")"
RO_LIVE_KERNEL_VERSION="$(<"${TARGET_ROOT_DIR}/var/tmp/ro-live-kernel-version")"
[[ -f "${TARGET_ROOT_DIR}${RO_LIVE_KERNEL_IMAGE_REL}" ]] || die "ro-kernel-stable image not found in live root: ${RO_LIVE_KERNEL_IMAGE_REL}"
[[ -s "${TARGET_ROOT_DIR}/var/tmp/ro-live-initrd.img" ]] || die "ro-kernel-stable live initrd was not generated."
install -Dm644 "${TARGET_ROOT_DIR}${RO_LIVE_KERNEL_IMAGE_REL}" "${LIVE_KERNEL_LOCAL}"
install -Dm644 "${TARGET_ROOT_DIR}/var/tmp/ro-live-initrd.img" "${LIVE_INITRD_LOCAL}"
install -Dm644 "${TARGET_ROOT_DIR}/var/tmp/ro-live-kernel-config-check.txt" "${WORK_BASE}/ro-live-kernel-config-check.txt"
install -Dm644 "${TARGET_ROOT_DIR}/var/tmp/ro-live-firmware-check.txt" "${WORK_BASE}/ro-live-firmware-check.txt"
log "Prepared live boot kernel from ro-kernel-stable: ${RO_LIVE_KERNEL_VERSION}"
rm -f "${WORK_BASE}/ro-optional-apps-missing.txt"

cleanup_chroot_mounts

rm -f \
  "${TARGET_ROOT_DIR}/var/tmp/ro-live-initrd.img" \
  "${TARGET_ROOT_DIR}/var/tmp/ro-live-kernel-version" \
  "${TARGET_ROOT_DIR}/var/tmp/ro-live-kernel-image" \
  "${TARGET_ROOT_DIR}/var/tmp/ro-live-kernel-config-check.txt" \
  "${TARGET_ROOT_DIR}/var/tmp/ro-live-firmware-check.txt" \
  "${TARGET_ROOT_DIR}/var/tmp/ro-live-customize.sh"

log "Live ISO boot kernel/initrd replaced with ro-kernel-stable artifacts."

log "Creating live autostart and passwordless sudo policy for installer..."
install -d "${TARGET_ROOT_DIR}/etc/xdg/autostart"
cat > "${TARGET_ROOT_DIR}/etc/xdg/autostart/ro-Installer.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Version=1.0
Name=Ro-ASD Installer Live AutoStart
Comment=Starts Ro-ASD installer in the live session
Exec=/usr/bin/env RO_INSTALLER_LIVE_SESSION=1 RO_INSTALLER_COMMAND_SUDO=1 /usr/bin/ro-installer
TryExec=/usr/bin/ro-installer
Terminal=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
X-KDE-autostart-after=panel
EOF

install -d "${TARGET_ROOT_DIR}/etc/sudoers.d"
cat > "${TARGET_ROOT_DIR}/etc/sudoers.d/ro-installer-live" <<'EOF'
Defaults:liveuser !requiretty
liveuser ALL=(ALL) NOPASSWD: ALL
%wheel ALL=(ALL) NOPASSWD: ALL
EOF
chmod 0440 "${TARGET_ROOT_DIR}/etc/sudoers.d/ro-installer-live"

rewrite_os_release() {
  local file="$1"
  [[ -e "${file}" ]] || return 0
  if [[ -L "${file}" ]]; then
    file="$(readlink -f "${file}")"
  fi
  [[ -f "${file}" ]] || return 0
  sed -i \
    -e 's/^NAME=.*/NAME="Ro-ASD"/' \
    -e "s/^PRETTY_NAME=.*/PRETTY_NAME=\"Ro-ASD ${BETA_TAG} Live\"/" \
    -e 's/^VARIANT=.*/VARIANT="Ro-ASD"/' \
    -e 's/^VARIANT_ID=.*/VARIANT_ID=roasd/' \
    "${file}"
}

log "Updating visible distro branding inside live rootfs..."
rewrite_os_release "${TARGET_ROOT_DIR}/usr/lib/os-release"
rewrite_os_release "${TARGET_ROOT_DIR}/etc/os-release"

for release_file in \
  "${TARGET_ROOT_DIR}/etc/fedora-release" \
  "${TARGET_ROOT_DIR}/etc/system-release" \
  "${TARGET_ROOT_DIR}/etc/issue" \
  "${TARGET_ROOT_DIR}/etc/issue.net"; do
  if [[ -e "${release_file}" ]]; then
    printf 'Ro-ASD %s Live\n' "${BETA_TAG}" > "${release_file}"
  fi
done

OLD_LABEL="$(blkid -o value -s LABEL "${SOURCE_ISO}" || true)"
if [[ -z "${OLD_LABEL}" ]]; then
  OLD_LABEL="$(grep -Eo 'CDLABEL=[^ ]+' "${GRUB_CFG_LOCAL}" | head -n 1 | cut -d'=' -f2 || true)"
fi
[[ -n "${OLD_LABEL}" ]] || die "Could not detect old ISO volume label."

log "Patching boot menu and live root label references..."
LIVE_ROOT_ARGS="root=live:CDLABEL=${VOLUME_ID} rd.live.image rd.live.dir=LiveOS rd.live.squashimg=squashfs.img rd.retry=180 plymouth.enable=0"
LIVE_LOG_ARGS="rd.debug rd.info rd.live.debug rd.shell rd.udev.log_level=debug udev.log_level=debug systemd.log_level=debug systemd.log_target=console systemd.journald.forward_to_console=1 systemd.journald.max_level_console=debug log_buf_len=4M ignore_loglevel printk.devkmsg=on"
LIVE_TEXT_ARGS="systemd.unit=multi-user.target systemd.log_level=info systemd.log_target=console"
LIVE_SERIAL_ARGS="console=tty0 console=ttyS0,115200n8"
LIVE_SAFE_GRAPHICS_ARGS="nomodeset"
LIVE_X11_ARGS="ro.live.session=x11"
LIVE_SOFTWARE_RENDER_ARGS="ro.live.session=x11 ro.live.software_render=1"
LIVE_NOUVEAU_GSP_OFF_ARGS="nouveau.config=NvGspRm=0"
LIVE_NOUVEAU_DISABLED_ARGS="rd.driver.blacklist=nouveau modprobe.blacklist=nouveau"
LIVE_INITRD_BREAK_ARGS="rd.break=pre-pivot"
if [[ -f "${GRUB_CFG_LOCAL}" ]]; then
  sed -i \
    -e 's/Fedora-KDE-Desktop-Live/Ro-ASD Live/g' \
    -e "s/CDLABEL=${OLD_LABEL}/CDLABEL=${VOLUME_ID}/g" \
    -e 's/set default="1"/set default="0"/' \
    -e 's/quiet rhgb  //g' \
    "${GRUB_CFG_LOCAL}"
  sed -i \
    -e "s#root=live:CDLABEL=${VOLUME_ID} rd.live.image#${LIVE_ROOT_ARGS}#g" \
    "${GRUB_CFG_LOCAL}"
fi

patch_utf16_csv() {
  local file="$1"
  local tmp_utf8 tmp_utf16
  [[ -f "${file}" ]] || return 0
  tmp_utf8="$(mktemp)"
  tmp_utf16="$(mktemp)"
  iconv -f UTF-16 -t UTF-8 "${file}" > "${tmp_utf8}"
  sed -i 's/Fedora/Ro-ASD/g' "${tmp_utf8}"
  iconv -f UTF-8 -t UTF-16 "${tmp_utf8}" > "${tmp_utf16}"
  cat "${tmp_utf16}" > "${file}"
  rm -f "${tmp_utf8}" "${tmp_utf16}"
}

patch_utf16_csv "${BOOTX64_CSV_LOCAL}"
patch_utf16_csv "${BOOTIA32_CSV_LOCAL}"

add_live_debug_grub_entries() {
  local file="$1"
  local tmp
  [[ -f "${file}" ]] || return 0
  if grep -Fq "Start Ro-ASD Live with visible boot logs" "${file}"; then
    return 0
  fi

  tmp="$(mktemp)"
  awk \
    -v live="${LIVE_ROOT_ARGS}" \
    -v logargs="${LIVE_LOG_ARGS}" \
    -v textargs="${LIVE_TEXT_ARGS}" \
    -v serial="${LIVE_SERIAL_ARGS}" \
    -v safegraphics="${LIVE_SAFE_GRAPHICS_ARGS}" \
    -v x11args="${LIVE_X11_ARGS}" \
    -v softargs="${LIVE_SOFTWARE_RENDER_ARGS}" \
    -v gspoffargs="${LIVE_NOUVEAU_GSP_OFF_ARGS}" \
    -v nouveaudisabled="${LIVE_NOUVEAU_DISABLED_ARGS}" \
    -v initrdbreak="${LIVE_INITRD_BREAK_ARGS}" '
    /submenu "Troubleshooting -->" \{/ && !inserted {
      print
      print "\tmenuentry \"Start Ro-ASD Live with visible boot logs\" --class fedora --class gnu-linux --class gnu --class os {"
      print "\t\tlinux ($root)/boot/x86_64/loader/linux " live " " logargs " " serial
      print "\t\tinitrd ($root)/boot/x86_64/loader/initrd"
      print "\t}"
      print "\tmenuentry \"Start Ro-ASD Live in initrd shell before switch-root\" --class fedora --class gnu-linux --class gnu --class os {"
      print "\t\tlinux ($root)/boot/x86_64/loader/linux " live " " logargs " " initrdbreak " " serial
      print "\t\tinitrd ($root)/boot/x86_64/loader/initrd"
      print "\t}"
      print "\tmenuentry \"Start Ro-ASD Live in text console\" --class fedora --class gnu-linux --class gnu --class os {"
      print "\t\tlinux ($root)/boot/x86_64/loader/linux " live " " textargs " " serial
      print "\t\tinitrd ($root)/boot/x86_64/loader/initrd"
      print "\t}"
      print "\tmenuentry \"Start Ro-ASD Live in safe graphics mode\" --class fedora --class gnu-linux --class gnu --class os {"
      print "\t\tlinux ($root)/boot/x86_64/loader/linux " live " " safegraphics " " serial
      print "\t\tinitrd ($root)/boot/x86_64/loader/initrd"
      print "\t}"
      print "\tmenuentry \"Start Ro-ASD Live with X11 session\" --class fedora --class gnu-linux --class gnu --class os {"
      print "\t\tlinux ($root)/boot/x86_64/loader/linux " live " " x11args " " serial
      print "\t\tinitrd ($root)/boot/x86_64/loader/initrd"
      print "\t}"
      print "\tmenuentry \"Start Ro-ASD Live with X11 software rendering\" --class fedora --class gnu-linux --class gnu --class os {"
      print "\t\tlinux ($root)/boot/x86_64/loader/linux " live " " softargs " " serial
      print "\t\tinitrd ($root)/boot/x86_64/loader/initrd"
      print "\t}"
      print "\tmenuentry \"Start Ro-ASD Live with nouveau GSP disabled\" --class fedora --class gnu-linux --class gnu --class os {"
      print "\t\tlinux ($root)/boot/x86_64/loader/linux " live " " gspoffargs " " serial
      print "\t\tinitrd ($root)/boot/x86_64/loader/initrd"
      print "\t}"
      print "\tmenuentry \"Start Ro-ASD Live with nouveau disabled\" --class fedora --class gnu-linux --class gnu --class os {"
      print "\t\tlinux ($root)/boot/x86_64/loader/linux " live " " nouveaudisabled " " serial
      print "\t\tinitrd ($root)/boot/x86_64/loader/initrd"
      print "\t}"
      inserted=1
      next
    }
    { print }
  ' "${file}" > "${tmp}"
  cat "${tmp}" > "${file}"
  rm -f "${tmp}"
}

add_live_debug_grub_entries "${GRUB_CFG_LOCAL}"

relabel_live_root_selinux() {
  local file_contexts="${TARGET_ROOT_DIR}/etc/selinux/targeted/contexts/files/file_contexts"
  local file_contexts_dir
  local label_path
  local policy_file

  if [[ ! -f "${file_contexts}" ]]; then
    log "[WARN] SELinux file_contexts not found in live root; skipping relabel."
    return 0
  fi

  policy_file="$(find "${TARGET_ROOT_DIR}/etc/selinux/targeted/policy" -maxdepth 1 -type f -name 'policy.*' -print 2>/dev/null | sort -V | tail -n 1 || true)"
  if [[ -z "${policy_file}" ]]; then
    die "SELinux policy file not found in live root; cannot relabel safely."
  fi

  file_contexts_dir="$(dirname "${file_contexts}")"
  find "${file_contexts_dir}" -maxdepth 1 -type f -name 'file_contexts*.bin' -delete

  log "Relabeling live root SELinux contexts..."
  setfiles -F -c "${policy_file}" -r "${TARGET_ROOT_DIR}" "${file_contexts}" "${TARGET_ROOT_DIR}" || die "SELinux relabel failed for live root."

  for label_path in \
    /usr/libexec/Xorg \
    /usr/bin/Xorg \
    /usr/bin/sddm \
    /usr/libexec/sddm-helper \
    /usr/lib/systemd/system-generators/anaconda-generator \
    /usr/lib/systemd/system-generators/kdump-dep-generator.sh; do
    if [[ -e "${TARGET_ROOT_DIR}${label_path}" ]]; then
      ls -Zd "${TARGET_ROOT_DIR}${label_path}" || true
    fi
  done
}

relabel_live_root_selinux

if [[ "${IMAGE_MODE}" == "overlay_squashfs" ]]; then
  log "Rebuilding squashfs image..."
  mksquashfs "${TARGET_ROOT_DIR}" "${SQUASHFS_NEW}" -comp xz -noappend
  cleanup_all_mounts
  rm -f "${SQUASHFS_ORIG}"
  rm -rf "${LOWER_DIR}" "${UPPER_DIR}" "${OVERLAY_WORK_DIR}" "${MERGED_DIR}"
elif [[ "${IMAGE_MODE}" == "overlay_erofs" || "${IMAGE_MODE}" == "extracted_erofs" ]]; then
  if ! cmd_exists mkfs.erofs; then
    log "[MISSING] 'mkfs.erofs' not found. Installing erofs-utils..."
    if ! cmd_exists dnf; then
      die "mkfs.erofs missing and dnf unavailable. Install erofs-utils."
    fi
    dnf -y install erofs-utils
  fi
  cmd_exists mkfs.erofs || die "mkfs.erofs still unavailable after erofs-utils install."
  log "Rebuilding erofs image..."
  mkfs.erofs -zlz4hc "${SQUASHFS_NEW}" "${TARGET_ROOT_DIR}"
  cleanup_all_mounts
  rm -f "${SQUASHFS_ORIG}"
  rm -rf "${LOWER_DIR}" "${UPPER_DIR}" "${OVERLAY_WORK_DIR}" "${MERGED_DIR}"
elif [[ "${IMAGE_MODE}" == "loop_rw_image" ]]; then
  log "Finalizing writable loop image..."
  sync
  cleanup_all_mounts
else
  die "Internal error: unknown image mode '${IMAGE_MODE}'."
fi

log "Repacking ISO with original boot layout replay..."
XORRISO_CMD=(
  -indev "${SOURCE_ISO}"
  -outdev "${OUTPUT_ISO}"
  -overwrite on
  -boot_image any replay
  -volid "${VOLUME_ID}"
  -map "${SQUASHFS_NEW}" /LiveOS/squashfs.img
  -map "${GRUB_CFG_LOCAL}" /boot/grub2/grub.cfg
  -map "${LIVE_KERNEL_LOCAL}" /boot/x86_64/loader/linux
  -map "${LIVE_INITRD_LOCAL}" /boot/x86_64/loader/initrd
  -map "${WORK_BASE}/ro-live-kernel-config-check.txt" /ro-live-kernel-config-check.txt
  -map "${WORK_BASE}/ro-live-firmware-check.txt" /ro-live-firmware-check.txt
)

if [[ -f "${BOOTX64_CSV_LOCAL}" ]]; then
  XORRISO_CMD+=(-map "${BOOTX64_CSV_LOCAL}" /EFI/fedora/BOOTX64.CSV)
fi
if [[ -f "${BOOTIA32_CSV_LOCAL}" ]]; then
  XORRISO_CMD+=(-map "${BOOTIA32_CSV_LOCAL}" /EFI/fedora/BOOTIA32.CSV)
fi

XORRISO_CMD+=(-commit -end)
xorriso "${XORRISO_CMD[@]}"

if command -v implantisomd5 >/dev/null 2>&1; then
  log "Writing implanted md5..."
  implantisomd5 "${OUTPUT_ISO}" || true
fi

log "Auditing ISO boot readiness..."
"${REPO_ROOT}/scripts/03-audit-iso.sh" "${OUTPUT_ISO}"

printf '%s\n' "${OUTPUT_ISO}" > "${OUTPUT_DIR}/latest-iso-path.txt"
NEW_LABEL="$(blkid -o value -s LABEL "${OUTPUT_ISO}" || true)"
log "ISO created: ${OUTPUT_ISO}"
log "ISO label: ${NEW_LABEL:-unknown}"
log "Detailed log: ${LOG_FILE}"

SUCCESS=1
