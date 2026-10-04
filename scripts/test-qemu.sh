#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_DIR="${REPO_ROOT}/outputs/logs"
mkdir -p "${LOG_DIR}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_DIR}/test-qemu-${TIMESTAMP}.log"

exec > >(tee -a "${LOG_FILE}") 2>&1

on_error() {
  local rc=$?
  echo "[ERROR] line=${BASH_LINENO[0]} cmd='${BASH_COMMAND}' exit_code=${rc}"
  echo "[ERROR] Detailed log: ${LOG_FILE}"
  exit "${rc}"
}
trap on_error ERR

info() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

fail() {
  info "[FATAL] $*"
  info "[FATAL] Detailed log: ${LOG_FILE}"
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  scripts/test-qemu.sh [options]

Suites:
  --suite check     Resolve ISO, QEMU tools, and OVMF only.
  --suite boot      Run QEMU ISO boot only.
  --suite smoke     Run short headless external-ISO boot. Default.
  --suite install   Run profile-based full installer VM test.
  --suite all       Run smoke + full installer VM test.

Options:
  --iso PATH              External Compose test ISO; or set RO_ASD_TEST_ISO.
  --profile PATH          Installer profile for --suite install.
                          Default: test/fixtures/profile_full_btrfs.json.
  --gui                   Open a QEMU window. Also applies to full install.
  --headless              Run QEMU without a display. Default.
  --timeout SEC           Boot smoke timeout. Default: 240.
  --install-timeout SEC   Full install timeout. Default: 1800.
  --disk-size SIZE        VM disk size. Default: 64G.
  --memory MB             VM memory. Default: 4096.
  --cpus N                VM CPU count. Default: 4.
  --video NAME            qemu-boot-iso video backend. Default: virtio.
  --boot-entry NAME       qemu-boot-iso GRUB entry. Default: text.
  --ssh-port PORT         Host SSH forward for qemu-boot-iso. Default: 0.
  --no-kvm                Use TCG for boot/check suites. Full install needs KVM.
  -h, --help              Show help.
EOF
}

normalize_path() {
  local path="$1"
  if [[ "${path}" == /* ]]; then
    printf '%s\n' "${path}"
  else
    printf '%s\n' "${REPO_ROOT}/${path}"
  fi
}

shell_join() {
  local arg
  local joined=""
  for arg in "$@"; do
    printf -v arg '%q' "${arg}"
    joined+="${arg} "
  done
  printf '%s' "${joined% }"
}

resolve_iso() {
  [[ -n "${ISO_PATH}" ]] ||
    fail "An external Compose-produced test ISO is required. Pass --iso PATH or set RO_ASD_TEST_ISO." >&2
  local candidate
  candidate="$(normalize_path "${ISO_PATH}")"
  [[ -f "${candidate}" && -r "${candidate}" ]] || fail "ISO not found or unreadable: ${ISO_PATH}" >&2
  printf '%s\n' "${candidate}"
}

qemu_boot_args() {
  QEMU_ARGS=(
    --iso "${RESOLVED_ISO}"
    --timeout "${TIMEOUT_SECONDS}"
    --disk-size "${DISK_SIZE}"
    --memory "${MEMORY_MB}"
    --cpus "${CPU_COUNT}"
    --video "${VIDEO_BACKEND}"
    --boot-entry "${BOOT_ENTRY}"
    --ssh-port "${SSH_PORT}"
  )
  if [[ "${QEMU_MODE}" == "gui" ]]; then
    QEMU_ARGS+=(--gui)
  else
    QEMU_ARGS+=(--headless)
  fi
  if [[ ${NO_KVM} -eq 1 ]]; then
    QEMU_ARGS+=(--no-kvm)
  fi
}

run_qemu_check() {
  qemu_boot_args
  local cmd=("${SCRIPT_DIR}/qemu-boot-iso.sh" "${QEMU_ARGS[@]}" --check)
  info "QEMU prerequisite check: $(shell_join "${cmd[@]}")"
  "${cmd[@]}"
}

run_boot_smoke() {
  qemu_boot_args
  local cmd=("${SCRIPT_DIR}/qemu-boot-iso.sh" "${QEMU_ARGS[@]}")
  info "QEMU boot smoke: $(shell_join "${cmd[@]}")"
  "${cmd[@]}"
}

run_full_install() {
  [[ ${NO_KVM} -eq 0 ]] || fail "--suite install currently needs KVM; rerun without --no-kvm."

  local profile_path
  profile_path="$(normalize_path "${PROFILE_PATH}")"
  [[ -f "${profile_path}" ]] || fail "Profile not found: ${PROFILE_PATH}"

  local cmd=("${REPO_ROOT}/test_qemu_vm.sh" auto "${profile_path}")
  info "QEMU full installer test: $(shell_join "${cmd[@]}")"
  (
    cd "${REPO_ROOT}"
    RO_INSTALLER_TEST_ISO="${RESOLVED_ISO}" \
    DISK_SIZE="${DISK_SIZE}" \
    MEMORY_MB="${MEMORY_MB}" \
    CPU_COUNT="${CPU_COUNT}" \
    QEMU_DISPLAY_MODE="${QEMU_MODE}" \
    AUTO_TEST_TIMEOUT_SECONDS="${INSTALL_TIMEOUT_SECONDS}" \
    "${cmd[@]}"
  )
}

SUITE="smoke"
ISO_PATH="${RO_ASD_TEST_ISO:-}"
PROFILE_PATH="test/fixtures/profile_full_btrfs.json"
QEMU_MODE="headless"
TIMEOUT_SECONDS=240
INSTALL_TIMEOUT_SECONDS=1800
DISK_SIZE="64G"
MEMORY_MB=4096
CPU_COUNT=4
VIDEO_BACKEND="virtio"
BOOT_ENTRY="text"
SSH_PORT=0
NO_KVM=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --suite)
      [[ $# -ge 2 ]] || fail "--suite needs a value."
      SUITE="$2"
      shift 2
      ;;
    --iso)
      [[ $# -ge 2 ]] || fail "--iso needs a value."
      ISO_PATH="$2"
      shift 2
      ;;
    --profile)
      [[ $# -ge 2 ]] || fail "--profile needs a value."
      PROFILE_PATH="$2"
      shift 2
      ;;
    --gui)
      QEMU_MODE="gui"
      shift
      ;;
    --headless)
      QEMU_MODE="headless"
      shift
      ;;
    --timeout)
      [[ $# -ge 2 ]] || fail "--timeout needs a value."
      TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --install-timeout)
      [[ $# -ge 2 ]] || fail "--install-timeout needs a value."
      INSTALL_TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --disk-size)
      [[ $# -ge 2 ]] || fail "--disk-size needs a value."
      DISK_SIZE="$2"
      shift 2
      ;;
    --memory)
      [[ $# -ge 2 ]] || fail "--memory needs a value."
      MEMORY_MB="$2"
      shift 2
      ;;
    --cpus)
      [[ $# -ge 2 ]] || fail "--cpus needs a value."
      CPU_COUNT="$2"
      shift 2
      ;;
    --video)
      [[ $# -ge 2 ]] || fail "--video needs a value."
      VIDEO_BACKEND="$2"
      shift 2
      ;;
    --boot-entry)
      [[ $# -ge 2 ]] || fail "--boot-entry needs a value."
      BOOT_ENTRY="$2"
      shift 2
      ;;
    --ssh-port)
      [[ $# -ge 2 ]] || fail "--ssh-port needs a value."
      SSH_PORT="$2"
      shift 2
      ;;
    --no-kvm)
      NO_KVM=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

case "${SUITE}" in
  check|boot|smoke|install|all) ;;
  *) fail "--suite must be one of: check, boot, smoke, install, all. Got: ${SUITE}" ;;
esac

for numeric in TIMEOUT_SECONDS INSTALL_TIMEOUT_SECONDS MEMORY_MB CPU_COUNT SSH_PORT; do
  value="${!numeric}"
  [[ "${value}" =~ ^[0-9]+$ ]] || fail "${numeric} must be numeric. Got: ${value}"
done

cd "${REPO_ROOT}"
RESOLVED_ISO="$(resolve_iso)"

info "Ro-ASD QEMU test started."
info "Repo: ${REPO_ROOT}"
info "ISO: ${RESOLVED_ISO}"
info "Suite: ${SUITE}"
info "Wrapper log: ${LOG_FILE}"

case "${SUITE}" in
  check)
    run_qemu_check
    ;;
  boot)
    run_boot_smoke
    ;;
  smoke)
    run_boot_smoke
    ;;
  install)
    run_full_install
    ;;
  all)
    run_boot_smoke
    run_full_install
    ;;
esac

info "Ro-ASD QEMU test finished."
