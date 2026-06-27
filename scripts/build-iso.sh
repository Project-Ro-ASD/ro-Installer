#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_DIR="${REPO_ROOT}/outputs/logs"
mkdir -p "${LOG_DIR}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_DIR}/build-iso-${TIMESTAMP}.log"

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
  scripts/build-iso.sh [options]

Purpose:
  Build a Ro-ASD ISO in one command:
    1. download the GitHub release RPM by default
    2. remix the Fedora KDE live ISO
    3. run the static ISO audit gate

Options:
  --source-iso PATH       Source Fedora KDE live ISO. If omitted, 02-build-iso
                          uses the first Fedora-KDE-Desktop-Live-*.iso in repo root.
  --rpm PATH              Use an existing ro-installer RPM.
  --rpm-source MODE       RPM source: github or local. Default: github.
                          github downloads release asset with gh.
                          local builds RPM with scripts/01-build-rpm.sh.
  --github-repo OWNER/REPO
                          GitHub repository for RPM release assets.
                          Default: origin remote, then Project-Ro-ASD/ro-Installer.
  --github-tag TAG        Release tag to download. Default: latest non-draft release.
  --beta N|betaN          Output ISO beta number. Default: auto increment.
  --version X.Y.Z         RPM version override.
  --release N             RPM release override.
  --source-mode MODE      RPM source mode: worktree or git. Default: worktree.
  --require-clean-git     Refuse RPM build when git worktree is dirty.
  --allow-nodeps          Pass --allow-nodeps to rpmbuild; not release evidence.
  --output-dir PATH       ISO output directory. Default: iso-release.
  --work-root PATH        ISO temporary work root. Default: outputs/iso-work.
  --keep-workdir          Keep ISO temporary workdir after success.
  --enable-ro-theme       Enable Ro theme in the live ISO. Default.
  --disable-ro-theme      Disable Ro theme in the live ISO.
  --no-host-auto-install  Do not let the ISO script install missing host tools.
  --allow-unsigned-ro-repo
                          Pass through to ISO build for local test ISOs when
                          Ro-Repo has unsigned packages/metadata.
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

resolve_existing_file() {
  local label="$1"
  local path="$2"
  local resolved
  resolved="$(normalize_path "${path}")"
  [[ -f "${resolved}" ]] || fail "${label} not found: ${path}"
  printf '%s\n' "${resolved}"
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

read_latest_file() {
  local file="$1"
  if [[ -f "${file}" ]]; then
    local value
    value="$(<"${file}")"
    if [[ -n "${value}" ]]; then
      printf '%s\n' "${value}"
      return 0
    fi
  fi
  return 1
}

need_cmd() {
  local missing=0
  local cmd
  for cmd in "$@"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      info "[MISSING] '${cmd}' not found."
      missing=1
    fi
  done
  [[ ${missing} -eq 0 ]] || fail "Missing required command(s): $*"
}

github_repo_from_origin() {
  local remote=""
  remote="$(git -C "${REPO_ROOT}" config --get remote.origin.url 2>/dev/null || true)"
  case "${remote}" in
    git@github.com:*.git)
      remote="${remote#git@github.com:}"
      printf '%s\n' "${remote%.git}"
      ;;
    git@github.com:*)
      printf '%s\n' "${remote#git@github.com:}"
      ;;
    https://github.com/*.git)
      remote="${remote#https://github.com/}"
      printf '%s\n' "${remote%.git}"
      ;;
    https://github.com/*)
      printf '%s\n' "${remote#https://github.com/}"
      ;;
    *)
      printf 'Project-Ro-ASD/ro-Installer\n'
      ;;
  esac
}

resolve_github_tag() {
  if [[ -n "${GITHUB_TAG}" && "${GITHUB_TAG}" != "latest" ]]; then
    printf '%s\n' "${GITHUB_TAG}"
    return 0
  fi

  local latest_tag=""
  latest_tag="$(
    gh release list \
      --repo "${GITHUB_REPO}" \
      --limit 20 \
      --json tagName,isDraft \
      --jq 'map(select(.isDraft == false))[0].tagName' 2>/dev/null || true
  )"
  [[ -n "${latest_tag}" && "${latest_tag}" != "null" ]] ||
    fail "Could not resolve latest GitHub release tag for ${GITHUB_REPO}. Use --github-tag TAG."
  printf '%s\n' "${latest_tag}"
}

download_github_rpm() {
  need_cmd gh

  local tag
  local download_dir
  local downloaded_rpm

  tag="$(resolve_github_tag)"
  download_dir="${REPO_ROOT}/outputs/github-rpm/${tag}-${TIMESTAMP}"
  mkdir -p "${download_dir}"

  info "GitHub RPM source: repo=${GITHUB_REPO} tag=${tag}"
  gh release download "${tag}" \
    --repo "${GITHUB_REPO}" \
    --pattern '*.rpm' \
    --dir "${download_dir}" \
    --clobber
  gh release download "${tag}" \
    --repo "${GITHUB_REPO}" \
    --pattern '*.rpm.sha256' \
    --dir "${download_dir}" \
    --clobber >/dev/null 2>&1 || true

  downloaded_rpm="$(
    find "${download_dir}" -maxdepth 1 -type f \
      -name 'ro-installer-*.rpm' ! -name '*.src.rpm' \
      -print | sort | head -n 1
  )"
  [[ -n "${downloaded_rpm}" ]] || fail "GitHub release did not provide a ro-installer RPM asset: ${GITHUB_REPO}@${tag}"

  printf '%s\n' "${downloaded_rpm}" > "${REPO_ROOT}/rpm-outputs/latest-rpm-path.txt"
  RPM_PATH="${downloaded_rpm}"
}

RPM_PATH=""
RPM_SOURCE="${RO_INSTALLER_RPM_SOURCE:-github}"
RPM_ARGS=(--no-chain)
ISO_ARGS=()
GITHUB_REPO="${RO_INSTALLER_GITHUB_REPO:-}"
GITHUB_TAG="${RO_INSTALLER_RPM_TAG:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-iso)
      [[ $# -ge 2 ]] || fail "--source-iso needs a value."
      ISO_ARGS+=(--source-iso "$(resolve_existing_file "Source ISO" "$2")")
      shift 2
      ;;
    --rpm)
      [[ $# -ge 2 ]] || fail "--rpm needs a value."
      RPM_PATH="$(resolve_existing_file "RPM" "$2")"
      RPM_SOURCE="path"
      shift 2
      ;;
    --rpm-source)
      [[ $# -ge 2 ]] || fail "--rpm-source needs a value."
      RPM_SOURCE="$2"
      shift 2
      ;;
    --github-repo)
      [[ $# -ge 2 ]] || fail "--github-repo needs a value."
      GITHUB_REPO="$2"
      shift 2
      ;;
    --github-tag)
      [[ $# -ge 2 ]] || fail "--github-tag needs a value."
      GITHUB_TAG="$2"
      shift 2
      ;;
    --beta)
      [[ $# -ge 2 ]] || fail "--beta needs a value."
      ISO_ARGS+=(--beta "$2")
      shift 2
      ;;
    --version)
      [[ $# -ge 2 ]] || fail "--version needs a value."
      RPM_ARGS+=(--version "$2")
      shift 2
      ;;
    --release)
      [[ $# -ge 2 ]] || fail "--release needs a value."
      RPM_ARGS+=(--release "$2")
      shift 2
      ;;
    --source-mode)
      [[ $# -ge 2 ]] || fail "--source-mode needs a value."
      RPM_ARGS+=(--source-mode "$2")
      shift 2
      ;;
    --require-clean-git)
      RPM_ARGS+=(--require-clean-git)
      shift
      ;;
    --allow-nodeps)
      RPM_ARGS+=(--allow-nodeps)
      shift
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || fail "--output-dir needs a value."
      ISO_ARGS+=(--output-dir "$(normalize_path "$2")")
      shift 2
      ;;
    --work-root)
      [[ $# -ge 2 ]] || fail "--work-root needs a value."
      ISO_ARGS+=(--work-root "$(normalize_path "$2")")
      shift 2
      ;;
    --keep-workdir)
      ISO_ARGS+=(--keep-workdir)
      shift
      ;;
    --enable-ro-theme)
      ISO_ARGS+=(--enable-ro-theme)
      shift
      ;;
    --disable-ro-theme)
      ISO_ARGS+=(--disable-ro-theme)
      shift
      ;;
    --no-host-auto-install)
      ISO_ARGS+=(--no-host-auto-install)
      shift
      ;;
    --allow-unsigned-ro-repo)
      ISO_ARGS+=(--allow-unsigned-ro-repo)
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

cd "${REPO_ROOT}"
mkdir -p "${REPO_ROOT}/rpm-outputs"

case "${RPM_SOURCE}" in
  github|local|path) ;;
  *) fail "--rpm-source must be github or local. Got: ${RPM_SOURCE}" ;;
esac

if [[ -z "${GITHUB_REPO}" ]]; then
  GITHUB_REPO="$(github_repo_from_origin)"
fi

info "Ro-ASD ISO build started."
info "Repo: ${REPO_ROOT}"
info "Wrapper log: ${LOG_FILE}"
info "RPM source: ${RPM_SOURCE}"

case "${RPM_SOURCE}" in
  github)
    download_github_rpm
    RPM_PATH="$(resolve_existing_file "GitHub RPM" "${RPM_PATH}")"
    ;;
  local)
    RPM_CMD=("${SCRIPT_DIR}/01-build-rpm.sh" "${RPM_ARGS[@]}")
    info "Local RPM stage: $(shell_join "${RPM_CMD[@]}")"
    "${RPM_CMD[@]}"

    RPM_PATH="$(read_latest_file "${REPO_ROOT}/rpm-outputs/latest-rpm-path.txt" || true)"
    [[ -n "${RPM_PATH}" ]] || fail "RPM stage finished but rpm-outputs/latest-rpm-path.txt is missing."
    RPM_PATH="$(resolve_existing_file "Built RPM" "${RPM_PATH}")"
    ;;
  path)
    info "RPM stage skipped; using existing RPM: ${RPM_PATH}"
    ;;
esac

ISO_CMD=("${SCRIPT_DIR}/02-build-iso.sh" --rpm "${RPM_PATH}" "${ISO_ARGS[@]}")
info "ISO stage: $(shell_join "${ISO_CMD[@]}")"
"${ISO_CMD[@]}"

ISO_PATH="$(read_latest_file "${REPO_ROOT}/iso-release/latest-iso-path.txt" || true)"
ISO_MANIFEST="$(read_latest_file "${REPO_ROOT}/iso-release/latest-iso-manifest.txt" || true)"

if [[ -n "${ISO_PATH}" ]]; then
  ISO_PATH="$(resolve_existing_file "Built ISO" "${ISO_PATH}")"
  info "ISO ready: ${ISO_PATH}"
fi
if [[ -n "${ISO_MANIFEST}" && -f "${ISO_MANIFEST}" ]]; then
  info "ISO manifest: ${ISO_MANIFEST}"
fi

info "Ro-ASD ISO build finished."
