#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SOURCE_ISO=""
LIVE_ROOT="/"
WORK_ROOT="${REPO_ROOT}/outputs/copy-benchmark-work"
KEEP_WORKDIR=0
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage:
  scripts/04-benchmark-copy-paths.sh --source-iso PATH [options]

Benchmarks copy candidates without installing to a disk:
- live-root rsync copy from the running filesystem
- ISO LiveOS payload extraction plus rsync from the extracted payload

Options:
  --source-iso PATH  Source Ro-ASD/Fedora live ISO.
  --live-root PATH   Live root path to copy for the rsync baseline (default: /).
  --work-root PATH   Temporary benchmark work root (default: outputs/copy-benchmark-work).
  --keep-workdir     Keep temporary benchmark directories.
  --dry-run          Validate inputs and required tools, then exit without copying.
  -h, --help         Show help.
EOF
}

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" >&2
}

die() {
  log "[FATAL] $*" >&2
  exit 1
}

cmd_exists() {
  command -v "$1" >/dev/null 2>&1
}

need_cmd() {
  cmd_exists "$1" || die "Required command not found: $1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-iso)
      [[ $# -ge 2 ]] || die "--source-iso needs a value."
      SOURCE_ISO="$2"
      shift 2
      ;;
    --live-root)
      [[ $# -ge 2 ]] || die "--live-root needs a value."
      LIVE_ROOT="$2"
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
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

[[ -n "${SOURCE_ISO}" ]] || die "--source-iso is required."
[[ -f "${SOURCE_ISO}" ]] || die "Source ISO not found: ${SOURCE_ISO}"
[[ -d "${LIVE_ROOT}" ]] || die "Live root path not found: ${LIVE_ROOT}"

need_cmd rsync
need_cmd xorriso
need_cmd file
need_cmd find
need_cmd du
need_cmd awk
need_cmd date

if (( DRY_RUN == 1 )); then
  log "Dry-run OK. Inputs and required base tools are available."
  exit 0
fi

mkdir -p "${WORK_ROOT}" "${REPO_ROOT}/outputs/logs"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${REPO_ROOT}/outputs/logs/04-benchmark-copy-paths-${TIMESTAMP}.log"
SUMMARY_FILE="${REPO_ROOT}/outputs/logs/04-benchmark-copy-paths-${TIMESTAMP}.summary"
WORK_DIR="$(mktemp -d "${WORK_ROOT}/run-${TIMESTAMP}.XXXXXX")"

exec > >(tee -a "${LOG_FILE}") 2>&1

cleanup() {
  if (( KEEP_WORKDIR == 0 )); then
    rm -rf "${WORK_DIR}"
  else
    log "Keeping workdir: ${WORK_DIR}"
  fi
}
trap cleanup EXIT

RSYNC_EXCLUDES=(
  --exclude=/dev/*
  --exclude=/proc/*
  --exclude=/sys/*
  --exclude=/tmp/*
  --exclude=/run/*
  --exclude=/mnt/*
  --exclude=/media/*
  --exclude=/lost+found
  --exclude=/.cache/*
  --exclude=/etc/machine-id
  --exclude=/etc/kernel/cmdline
  --exclude=/home/*/.cache/*
  --exclude=/root/.cache/*
  --exclude=/var/cache/dnf/*
  --exclude=/var/cache/PackageKit/*
  --exclude=/var/tmp/*
  --exclude=/var/log/audit/*
  --exclude=/boot/loader/entries/*
  --exclude=/boot/grub2/grubenv
  --exclude=/boot/efi/*
  --exclude=/boot/efi
)

now_ns() {
  date +%s%N
}

elapsed_ms() {
  local start_ns="$1"
  local end_ns="$2"
  awk -v start="${start_ns}" -v end="${end_ns}" 'BEGIN { printf "%.0f", (end - start) / 1000000 }'
}

tree_bytes() {
  du -sb "$1" | awk '{print $1}'
}

tree_files() {
  find "$1" -xdev -type f | wc -l | awk '{print $1}'
}

record_result() {
  local label="$1"
  local elapsed="$2"
  local target="$3"
  local exit_code="$4"
  local bytes="0"
  local files="0"
  if [[ -d "${target}" ]]; then
    bytes="$(tree_bytes "${target}")"
    files="$(tree_files "${target}")"
  fi
  printf '%s elapsed_ms=%s exit=%s bytes=%s files=%s target=%s\n' \
    "${label}" "${elapsed}" "${exit_code}" "${bytes}" "${files}" "${target}" \
    | tee -a "${SUMMARY_FILE}"
}

run_rsync_live_root() {
  local target="${WORK_DIR}/target-rsync-live"
  mkdir -p "${target}"
  log "Benchmarking live-root rsync from ${LIVE_ROOT} to ${target}"
  local start
  local end
  local rc=0
  start="$(now_ns)"
  rsync -aAX --numeric-ids --info=stats2 --human-readable \
    "${RSYNC_EXCLUDES[@]}" \
    "${LIVE_ROOT%/}/" "${target}/" || rc=$?
  end="$(now_ns)"
  record_result "live_root_rsync" "$(elapsed_ms "${start}" "${end}")" "${target}" "${rc}"
  return "${rc}"
}

extract_payload_root() {
  local payload_img="${WORK_DIR}/squashfs.img"
  local payload_root="${WORK_DIR}/payload-root"
  mkdir -p "${payload_root}"
  log "Extracting /LiveOS/squashfs.img from ${SOURCE_ISO}"
  xorriso -osirrox on -indev "${SOURCE_ISO}" \
    -extract /LiveOS/squashfs.img "${payload_img}" -end >/dev/null

  local file_info
  file_info="$(file -b "${payload_img}")"
  log "LiveOS payload type: ${file_info}"
  if grep -qi 'squashfs' <<<"${file_info}"; then
    need_cmd unsquashfs
    unsquashfs -d "${payload_root}" "${payload_img}" >/dev/null
  elif grep -qi 'erofs' <<<"${file_info}"; then
    need_cmd fsck.erofs
    fsck.erofs --extract="${payload_root}" "${payload_img}"
  else
    die "Unsupported LiveOS payload type: ${file_info}"
  fi

  if [[ -f "${payload_root}/LiveOS/rootfs.img" && ! -x "${payload_root}/usr/bin/env" ]]; then
    die "Nested LiveOS/rootfs.img layout detected; benchmark script does not mount nested rootfs images."
  fi

  printf '%s\n' "${payload_root}"
}

run_payload_copy() {
  local target="${WORK_DIR}/target-payload"
  mkdir -p "${target}"
  local start
  local end
  local rc=0
  log "Benchmarking ISO payload extraction plus rsync to ${target}"
  start="$(now_ns)"
  local payload_root
  payload_root="$(extract_payload_root)" || rc=$?
  if (( rc == 0 )); then
    rsync -aAX --numeric-ids --info=stats2 --human-readable \
      "${RSYNC_EXCLUDES[@]}" \
      "${payload_root%/}/" "${target}/" || rc=$?
  fi
  end="$(now_ns)"
  record_result "iso_payload_extract_rsync" "$(elapsed_ms "${start}" "${end}")" "${target}" "${rc}"
  return "${rc}"
}

log "Copy benchmark started."
log "ISO: ${SOURCE_ISO}"
log "Live root: ${LIVE_ROOT}"
log "Work dir: ${WORK_DIR}"
printf '# ro-Installer copy benchmark\n' > "${SUMMARY_FILE}"

run_rsync_live_root || true
run_payload_copy || true

log "Summary: ${SUMMARY_FILE}"
log "Detailed log: ${LOG_FILE}"
