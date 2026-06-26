#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_DIR="${REPO_ROOT}/outputs/logs"
mkdir -p "${LOG_DIR}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_DIR}/01-build-rpm-${TIMESTAMP}.log"

exec > >(tee -a "${LOG_FILE}") 2>&1

on_error() {
  local rc=$?
  echo "[ERROR] satir=${BASH_LINENO[0]} komut='${BASH_COMMAND}' cikis_kodu=${rc}"
  echo "[ERROR] Detayli log: ${LOG_FILE}"
  exit "${rc}"
}
trap on_error ERR

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
  log "[FATAL] $*"
  log "[FATAL] Detayli log: ${LOG_FILE}"
  exit 1
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

git_value() {
  local fallback="$1"
  shift
  if command -v git >/dev/null 2>&1 && git -C "${REPO_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "${REPO_ROOT}" "$@" 2>/dev/null || printf '%s\n' "${fallback}"
  else
    printf '%s\n' "${fallback}"
  fi
}

git_dirty_state() {
  if ! command -v git >/dev/null 2>&1 || ! git -C "${REPO_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'unknown\n'
    return 0
  fi
  if [[ -z "$(git -C "${REPO_ROOT}" status --porcelain --untracked-files=all)" ]]; then
    printf 'clean\n'
  else
    printf 'dirty\n'
  fi
}

ensure_clean_git() {
  if [[ "$(git_dirty_state)" != "clean" ]]; then
    die "--require-clean-git verildi ama calisma agaci temiz degil."
  fi
}

need_cmd() {
  local missing=0
  for cmd in "$@"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      log "[MISSING] '${cmd}' bulunamadi."
      missing=1
    fi
  done
  if [[ ${missing} -ne 0 ]]; then
    die "Gerekli host araclari eksik. Fedora icin onerilen kurulum: sudo dnf install -y rpm-build rsync tar flutter clang cmake ninja-build gtk3-devel pkgconf-pkg-config"
  fi
}

need_pkg_config_module() {
  local module="$1"
  local package_hint="$2"
  if ! pkg-config --exists "${module}"; then
    die "Gerekli pkg-config modulu bulunamadi: ${module}. Fedora icin: sudo dnf install -y ${package_hint}"
  fi
}

add_flutter_path_if_present() {
  local dir="$1"
  if [[ -n "${dir}" && -x "${dir}/flutter" ]]; then
    case ":${PATH}:" in
      *":${dir}:"*) ;;
      *) export PATH="${dir}:${PATH}" ;;
    esac
    return 0
  fi
  return 1
}

discover_flutter() {
  if command -v flutter >/dev/null 2>&1; then
    return 0
  fi

  if [[ -n "${FLUTTER_HOME:-}" ]]; then
    add_flutter_path_if_present "${FLUTTER_HOME}/bin" && return 0
  fi
  if [[ -n "${FLUTTER_ROOT:-}" ]]; then
    add_flutter_path_if_present "${FLUTTER_ROOT}/bin" && return 0
  fi

  add_flutter_path_if_present "${REPO_ROOT}/.flutter/bin" && return 0
  add_flutter_path_if_present "${REPO_ROOT}/flutter/bin" && return 0
  add_flutter_path_if_present "${HOME:-}/development/flutter/bin" && return 0

  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    local sudo_home=""
    sudo_home="$(getent passwd "${SUDO_USER}" 2>/dev/null | cut -d: -f6 || true)"
    add_flutter_path_if_present "${sudo_home}/development/flutter/bin" && return 0
    add_flutter_path_if_present "/home/${SUDO_USER}/development/flutter/bin" && return 0
  fi

  return 1
}

show_help() {
  cat <<'EOF'
Kullanim:
  scripts/01-build-rpm.sh [secenekler]

Secenekler:
  --no-chain            RPM'den sonra ISO adimini calistirma.
  --source-iso PATH     Zincir calisacaksa kaynak Fedora KDE ISO yolu.
  --beta N|betaN        Zincir calisacaksa ISO beta numarasini sabitle.
  --version X.Y.Z       RPM versiyonu (varsayilan: pubspec.yaml).
  --release N           RPM release numarasi (varsayilan: pubspec build no ya da 1).
  --source-mode MODE    Kaynak paket modu: worktree veya git (varsayilan: worktree).
  --require-clean-git   Release kosusunda kirli git agacini reddet.
  --allow-nodeps        rpmbuild dependency kapisini atla; release kaniti sayilmaz.
  --no-host-auto-install
                         Zincir ISO build eksik host araclarini dnf ile kurmasin.
  -h, --help            Yardim metni.
EOF
}

CHAIN_ISO=1
SOURCE_ISO=""
BETA_ARG=""
APP_VERSION=""
APP_RELEASE=""
ISO_NO_HOST_AUTO_INSTALL=0
SOURCE_MODE="${RO_INSTALLER_RPM_SOURCE_MODE:-worktree}"
REQUIRE_CLEAN_GIT=0
ALLOW_NODEPS=0
ORIGINAL_ARGS=("$@")

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-chain)
      CHAIN_ISO=0
      shift
      ;;
    --source-iso)
      [[ $# -ge 2 ]] || die "--source-iso bir deger ister."
      SOURCE_ISO="$2"
      shift 2
      ;;
    --beta)
      [[ $# -ge 2 ]] || die "--beta bir deger ister."
      BETA_ARG="$2"
      shift 2
      ;;
    --version)
      [[ $# -ge 2 ]] || die "--version bir deger ister."
      APP_VERSION="$2"
      shift 2
      ;;
    --release)
      [[ $# -ge 2 ]] || die "--release bir deger ister."
      APP_RELEASE="$2"
      shift 2
      ;;
    --source-mode)
      [[ $# -ge 2 ]] || die "--source-mode bir deger ister."
      SOURCE_MODE="$2"
      shift 2
      ;;
    --require-clean-git)
      REQUIRE_CLEAN_GIT=1
      shift
      ;;
    --allow-nodeps)
      ALLOW_NODEPS=1
      shift
      ;;
    --no-host-auto-install)
      ISO_NO_HOST_AUTO_INSTALL=1
      shift
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      die "Bilinmeyen arguman: $1"
      ;;
  esac
done

discover_flutter || true
need_cmd rpmbuild rsync tar gzip sha256sum awk sed grep find flutter clang clang++ cmake ninja pkg-config
need_pkg_config_module gtk+-3.0 gtk3-devel
log "Flutter: $(command -v flutter)"

case "${SOURCE_MODE}" in
  worktree|git) ;;
  *) die "--source-mode sadece worktree veya git olabilir. Verilen: ${SOURCE_MODE}" ;;
esac

if [[ ${REQUIRE_CLEAN_GIT} -eq 1 ]]; then
  ensure_clean_git
fi

if [[ -z "${APP_VERSION}" || -z "${APP_RELEASE}" ]]; then
  PUBSPEC_VERSION="$(awk '/^version:/ {print $2; exit}' "${REPO_ROOT}/pubspec.yaml" || true)"
  [[ -n "${PUBSPEC_VERSION}" ]] || die "pubspec.yaml icinde surum okunamadi."
  if [[ -z "${APP_VERSION}" ]]; then
    APP_VERSION="${PUBSPEC_VERSION%%+*}"
  fi
  if [[ -z "${APP_RELEASE}" ]]; then
    if [[ "${PUBSPEC_VERSION}" == *"+"* ]]; then
      APP_RELEASE="${PUBSPEC_VERSION##*+}"
    else
      APP_RELEASE="1"
    fi
  fi
fi

APP_VERSION="${APP_VERSION//-/_}"
if [[ ! "${APP_RELEASE}" =~ ^[0-9]+$ ]]; then
  die "RPM release sayisal olmali. Verilen: ${APP_RELEASE}"
fi

SPEC_FILE="${REPO_ROOT}/ro-installer.spec"
[[ -f "${SPEC_FILE}" ]] || die "Spec dosyasi bulunamadi: ${SPEC_FILE}"

RPM_OUT_DIR="${REPO_ROOT}/rpm-outputs"
RPMBUILD_TOPDIR="${REPO_ROOT}/outputs/rpmbuild"
STAGE_SRC_PARENT="${RPMBUILD_TOPDIR}/stage-src"
STAGE_SRC_DIR="${STAGE_SRC_PARENT}/ro-installer-${APP_VERSION}"

SOURCE_EXCLUDES=(
  ".git"
  ".git/"
  ".idea"
  ".idea/"
  ".codex"
  ".codex/"
  ".agents"
  ".agents/"
  ".dart_tool"
  ".dart_tool/"
  ".pub-cache"
  ".pub-cache/"
  ".pub"
  ".pub/"
  "build"
  "build/"
  "coverage"
  "coverage/"
  "COPR.md"
  "docs/old"
  "docs/old/"
  "docs/road.md"
  "docs/road-plan.md"
  "docs/git-yukleme-notu.md"
  "docs/grafik-driver-politikasi.md"
  "docs/profesyonel-installer-ana-plani.md"
  "docs/ro-apps-packaging-notu.md"
  "docs/siyah-ekran-kernel-notlari.md"
  "docs/sonraki-adim-notu.md"
  "docs/yeni-makine-qemu-rehberi.md"
  "durum.md"
  "eksikler.md"
  "gerçeksistemdenloglar"
  "gerçeksistemdenloglar/"
  "implementation_plan.md"
  "kernel-black-screen-diagnostics.md"
  "optimizasyon.md"
  "plan.md"
  "test.md"
  "outputs"
  "outputs/"
  "rpm-outputs"
  "rpm-outputs/"
  "iso-release"
  "iso-release/"
  "iso-realese"
  "iso-realese/"
  "linux/flutter/ephemeral"
  "linux/flutter/ephemeral/"
  "__pycache__"
  "__pycache__/"
  ".copr-srpm-tmp"
  ".copr-srpm-tmp/"
  "*.iso"
  "*.qcow2"
  "*.fd"
  "*.rpm"
  "*.src.rpm"
  "*.tar.gz"
  "*.pyc"
  "*.log"
  ".git.broken-*"
  ".git.broken-*/"
  "stitch_velvet_nebula_installer_redesign"
  "stitch_velvet_nebula_installer_redesign/"
)

audit_staged_source() {
  local bad
  bad="$(
    cd "${STAGE_SRC_DIR}" && find . -mindepth 1 \
      \( \
        -path './.git' -o \
        -path './.git/*' -o \
        -path './.idea' -o \
        -path './.idea/*' -o \
        -path './.codex' -o \
        -path './.codex/*' -o \
        -path './.agents' -o \
        -path './.agents/*' -o \
        -path './.dart_tool' -o \
        -path './.dart_tool/*' -o \
        -path './build' -o \
        -path './build/*' -o \
        -path './coverage' -o \
        -path './coverage/*' -o \
        -path './COPR.md' -o \
        -path './docs/old' -o \
        -path './docs/old/*' -o \
        -path './docs/road.md' -o \
        -path './docs/road-plan.md' -o \
        -path './docs/git-yukleme-notu.md' -o \
        -path './docs/grafik-driver-politikasi.md' -o \
        -path './docs/profesyonel-installer-ana-plani.md' -o \
        -path './docs/ro-apps-packaging-notu.md' -o \
        -path './docs/siyah-ekran-kernel-notlari.md' -o \
        -path './docs/sonraki-adim-notu.md' -o \
        -path './docs/yeni-makine-qemu-rehberi.md' -o \
        -path './durum.md' -o \
        -path './eksikler.md' -o \
        -path './gerçeksistemdenloglar' -o \
        -path './gerçeksistemdenloglar/*' -o \
        -path './implementation_plan.md' -o \
        -path './kernel-black-screen-diagnostics.md' -o \
        -path './optimizasyon.md' -o \
        -path './plan.md' -o \
        -path './test.md' -o \
        -path './outputs' -o \
        -path './outputs/*' -o \
        -path './rpm-outputs' -o \
        -path './rpm-outputs/*' -o \
        -path './iso-release' -o \
        -path './iso-release/*' -o \
        -path './iso-realese' -o \
        -path './iso-realese/*' -o \
        -path './linux/flutter/ephemeral' -o \
        -path './linux/flutter/ephemeral/*' -o \
        -path './__pycache__' -o \
        -path './__pycache__/*' -o \
        -path './stitch_velvet_nebula_installer_redesign' -o \
        -path './stitch_velvet_nebula_installer_redesign/*' -o \
        -name '*.iso' -o \
        -name '*.qcow2' -o \
        -name '*.fd' -o \
        -name '*.rpm' -o \
        -name '*.src.rpm' -o \
        -name '*.tar.gz' -o \
        -name '*.pyc' -o \
        -name '*.log' \
      \) -print | sed 's#^\./##' | head -n 50 || true
  )"
  [[ -z "${bad}" ]] || die "Kaynak agacinda paketlenmemesi gereken dosya var: ${bad}"
}

audit_source_tarball() {
  local tarball="$1"
  local bad
  bad="$(
    tar -tzf "${tarball}" | grep -E '(^|/)(\.git|\.idea|\.codex|\.agents|\.dart_tool|build|coverage|docs/old|gerçeksistemdenloglar|outputs|rpm-outputs|iso-release|iso-realese|linux/flutter/ephemeral|__pycache__)(/|$)|(^|/)(COPR|durum|eksikler|implementation_plan|kernel-black-screen-diagnostics|optimizasyon|plan|test)\.md$|(^|/)docs/(road|road-plan|git-yukleme-notu|grafik-driver-politikasi|profesyonel-installer-ana-plani|ro-apps-packaging-notu|siyah-ekran-kernel-notlari|sonraki-adim-notu|yeni-makine-qemu-rehberi)\.md$|\.(iso|qcow2|fd|rpm|src\.rpm|tar\.gz|pyc|log)$' | head -n 50 || true
  )"
  [[ -z "${bad}" ]] || die "Kaynak tarball kirli dosya iceriyor: ${bad}"
}

create_source_tarball() {
  local tarball="$1"
  local rsync_args=()
  local pattern

  case "${SOURCE_MODE}" in
    git)
      command -v git >/dev/null 2>&1 || die "--source-mode git icin git gerekli."
      git -C "${REPO_ROOT}" rev-parse --verify HEAD >/dev/null 2>&1 ||
        die "--source-mode git icin gecici olmayan bir HEAD gerekli."
      if [[ "$(git_dirty_state)" != "clean" ]]; then
        log "[WARN] Git agaci kirli; --source-mode git sadece committed HEAD icerigini paketler."
      fi
      git -C "${REPO_ROOT}" archive --worktree-attributes --format=tar --prefix="ro-installer-${APP_VERSION}/" HEAD | gzip -cn > "${tarball}"
      ;;
    worktree)
      for pattern in "${SOURCE_EXCLUDES[@]}"; do
        rsync_args+=("--exclude" "${pattern}")
      done
      rsync -a --delete "${rsync_args[@]}" "${REPO_ROOT}/" "${STAGE_SRC_DIR}/"
      audit_staged_source
      tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
        -czf "${tarball}" -C "${STAGE_SRC_PARENT}" "ro-installer-${APP_VERSION}"
      ;;
  esac

  audit_source_tarball "${tarball}"
}

mkdir -p \
  "${RPM_OUT_DIR}" \
  "${RPMBUILD_TOPDIR}/BUILD" \
  "${RPMBUILD_TOPDIR}/BUILDROOT" \
  "${RPMBUILD_TOPDIR}/RPMS" \
  "${RPMBUILD_TOPDIR}/SOURCES" \
  "${RPMBUILD_TOPDIR}/SPECS" \
  "${RPMBUILD_TOPDIR}/SRPMS"

rm -rf "${STAGE_SRC_PARENT}"
mkdir -p "${STAGE_SRC_DIR}"

SOURCE_TARBALL="${RPMBUILD_TOPDIR}/SOURCES/ro-installer-${APP_VERSION}.tar.gz"
log "RPM kaynak agaci hazirlaniyor (source-mode=${SOURCE_MODE})..."
log "Source tarball olusturuluyor: ${SOURCE_TARBALL}"
create_source_tarball "${SOURCE_TARBALL}"
SOURCE_TARBALL_SHA256="$(sha256_file "${SOURCE_TARBALL}")"
SOURCE_FILE_LIST="${RPM_OUT_DIR}/ro-installer-${APP_VERSION}-${APP_RELEASE}.source-files.txt"
tar -tzf "${SOURCE_TARBALL}" > "${SOURCE_FILE_LIST}"

cp -f "${SPEC_FILE}" "${RPMBUILD_TOPDIR}/SPECS/ro-installer.spec"

log "rpmbuild baslatiliyor (version=${APP_VERSION}, release=${APP_RELEASE})..."
RPMBUILD_ARGS=(
  -ba
  "${RPMBUILD_TOPDIR}/SPECS/ro-installer.spec"
  --define
  "_topdir ${RPMBUILD_TOPDIR}"
  --define
  "app_version ${APP_VERSION}"
  --define
  "app_release ${APP_RELEASE}"
)
if [[ ${ALLOW_NODEPS} -eq 1 ]]; then
  log "[WARN] --allow-nodeps kullaniliyor; bu RPM build release kaniti sayilmaz."
  RPMBUILD_ARGS=(-ba --nodeps "${RPMBUILD_TOPDIR}/SPECS/ro-installer.spec" "${RPMBUILD_ARGS[@]:2}")
fi
rpmbuild "${RPMBUILD_ARGS[@]}"

RPM_ARTIFACT="$(find "${RPMBUILD_TOPDIR}/RPMS" -type f -name "ro-installer-${APP_VERSION}-${APP_RELEASE}*.rpm" | head -n 1 || true)"
if [[ -z "${RPM_ARTIFACT}" ]]; then
  RPM_ARTIFACT="$(find "${RPMBUILD_TOPDIR}/RPMS" -type f -name "ro-installer-*.rpm" | head -n 1 || true)"
fi
[[ -n "${RPM_ARTIFACT}" ]] || die "RPM artifact bulunamadi."

FINAL_RPM="${RPM_OUT_DIR}/$(basename "${RPM_ARTIFACT}")"
cp -f "${RPM_ARTIFACT}" "${FINAL_RPM}"
FINAL_RPM_SHA256="$(sha256_file "${FINAL_RPM}")"
FINAL_RPM_SHA256_FILE="${FINAL_RPM}.sha256"
RPM_BUILD_MANIFEST="${RPM_OUT_DIR}/$(basename "${FINAL_RPM%.rpm}").build-manifest.txt"
printf '%s  %s\n' "${FINAL_RPM_SHA256}" "$(basename "${FINAL_RPM}")" > "${FINAL_RPM_SHA256_FILE}"
{
  printf 'manifest_version=1\n'
  printf 'build_timestamp_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'build_command=%q' "$0"
  printf ' %q' "${ORIGINAL_ARGS[@]}"
  printf '\n'
  printf 'repo_root=%s\n' "${REPO_ROOT}"
  printf 'git_commit=%s\n' "$(git_value unknown rev-parse --verify HEAD)"
  printf 'git_branch=%s\n' "$(git_value unknown branch --show-current)"
  printf 'git_dirty=%s\n' "$(git_dirty_state)"
  printf 'source_mode=%s\n' "${SOURCE_MODE}"
  printf 'require_clean_git=%s\n' "${REQUIRE_CLEAN_GIT}"
  printf 'rpmbuild_nodeps=%s\n' "${ALLOW_NODEPS}"
  printf 'app_version=%s\n' "${APP_VERSION}"
  printf 'app_release=%s\n' "${APP_RELEASE}"
  printf 'spec_file=%s\n' "${SPEC_FILE}"
  printf 'source_tarball=%s\n' "${SOURCE_TARBALL}"
  printf 'source_tarball_sha256=%s\n' "${SOURCE_TARBALL_SHA256}"
  printf 'source_file_list=%s\n' "${SOURCE_FILE_LIST}"
  printf 'rpm_path=%s\n' "${FINAL_RPM}"
  printf 'rpm_sha256=%s\n' "${FINAL_RPM_SHA256}"
  printf 'rpm_sha256_file=%s\n' "${FINAL_RPM_SHA256_FILE}"
  printf 'log_file=%s\n' "${LOG_FILE}"
} > "${RPM_BUILD_MANIFEST}"
printf '%s\n' "${FINAL_RPM}" > "${RPM_OUT_DIR}/latest-rpm-path.txt"
printf '%s\n' "${RPM_BUILD_MANIFEST}" > "${RPM_OUT_DIR}/latest-rpm-manifest.txt"

log "RPM basarili: ${FINAL_RPM}"
log "RPM sha256: ${FINAL_RPM_SHA256}"
log "RPM sha256 dosyasi: ${FINAL_RPM_SHA256_FILE}"
log "RPM build manifesti: ${RPM_BUILD_MANIFEST}"
log "Log dosyasi: ${LOG_FILE}"

if [[ ${CHAIN_ISO} -eq 1 ]]; then
  ISO_SCRIPT="${SCRIPT_DIR}/02-build-iso.sh"
  [[ -x "${ISO_SCRIPT}" ]] || die "ISO script'i calistirilabilir degil: ${ISO_SCRIPT}"

  ISO_CMD=("${ISO_SCRIPT}" "--rpm" "${FINAL_RPM}")
  if [[ -n "${SOURCE_ISO}" ]]; then
    ISO_CMD+=("--source-iso" "${SOURCE_ISO}")
  fi
  if [[ -n "${BETA_ARG}" ]]; then
    ISO_CMD+=("--beta" "${BETA_ARG}")
  fi
  if [[ ${ISO_NO_HOST_AUTO_INSTALL} -eq 1 ]]; then
    ISO_CMD+=("--no-host-auto-install")
  fi

  log "RPM tamamlandi, ISO asamasina geciliyor..."
  "${ISO_CMD[@]}"
fi

log "Asama tamamlandi."
