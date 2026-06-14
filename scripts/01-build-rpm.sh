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
  -h, --help            Yardim metni.
EOF
}

CHAIN_ISO=1
SOURCE_ISO=""
BETA_ARG=""
APP_VERSION=""
APP_RELEASE=""

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
need_cmd rpmbuild rsync tar awk sed grep flutter clang clang++ cmake ninja pkg-config
need_pkg_config_module gtk+-3.0 gtk3-devel
log "Flutter: $(command -v flutter)"

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

log "RPM kaynak agaci hazirlaniyor..."
rsync -a --delete \
  --exclude ".git/" \
  --exclude ".idea/" \
  --exclude ".dart_tool/" \
  --exclude "build/" \
  --exclude "outputs/" \
  --exclude "rpm-outputs/" \
  --exclude "iso-realese/" \
  --exclude "linux/flutter/ephemeral/" \
  --exclude "*.iso" \
  --exclude "*.qcow2" \
  --exclude "*.fd" \
  "${REPO_ROOT}/" "${STAGE_SRC_DIR}/"

SOURCE_TARBALL="${RPMBUILD_TOPDIR}/SOURCES/ro-installer-${APP_VERSION}.tar.gz"
log "Source tarball olusturuluyor: ${SOURCE_TARBALL}"
tar -czf "${SOURCE_TARBALL}" -C "${STAGE_SRC_PARENT}" "ro-installer-${APP_VERSION}"

cp -f "${SPEC_FILE}" "${RPMBUILD_TOPDIR}/SPECS/ro-installer.spec"

log "rpmbuild baslatiliyor (version=${APP_VERSION}, release=${APP_RELEASE})..."
rpmbuild -ba --nodeps "${RPMBUILD_TOPDIR}/SPECS/ro-installer.spec" \
  --define "_topdir ${RPMBUILD_TOPDIR}" \
  --define "app_version ${APP_VERSION}" \
  --define "app_release ${APP_RELEASE}"

RPM_ARTIFACT="$(find "${RPMBUILD_TOPDIR}/RPMS" -type f -name "ro-installer-${APP_VERSION}-${APP_RELEASE}*.rpm" | head -n 1 || true)"
if [[ -z "${RPM_ARTIFACT}" ]]; then
  RPM_ARTIFACT="$(find "${RPMBUILD_TOPDIR}/RPMS" -type f -name "ro-installer-*.rpm" | head -n 1 || true)"
fi
[[ -n "${RPM_ARTIFACT}" ]] || die "RPM artifact bulunamadi."

FINAL_RPM="${RPM_OUT_DIR}/$(basename "${RPM_ARTIFACT}")"
cp -f "${RPM_ARTIFACT}" "${FINAL_RPM}"
printf '%s\n' "${FINAL_RPM}" > "${RPM_OUT_DIR}/latest-rpm-path.txt"

log "RPM basarili: ${FINAL_RPM}"
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

  log "RPM tamamlandi, ISO asamasina geciliyor..."
  "${ISO_CMD[@]}"
fi

log "Asama tamamlandi."
