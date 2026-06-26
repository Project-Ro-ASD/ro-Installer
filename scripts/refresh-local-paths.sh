#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

info() {
  printf '[BILGI] %s\n' "$*"
}

warn() {
  printf '[UYARI] %s\n' "$*" >&2
}

newest_file() {
  local dir="$1"
  local pattern="$2"
  local candidate newest=""

  while IFS= read -r -d '' candidate; do
    if [[ -z "${newest}" || "${candidate}" -nt "${newest}" ]]; then
      newest="${candidate}"
    fi
  done < <(find "${dir}" -maxdepth 1 -type f -name "${pattern}" -print0 2>/dev/null)

  printf '%s\n' "${newest}"
}

refresh_latest_file() {
  local label="$1"
  local output_file="$2"
  local artifact_dir="$3"
  local pattern="$4"
  local current=""
  local rebased=""
  local artifact=""

  if [[ -f "${output_file}" ]]; then
    current="$(<"${output_file}")"
    if [[ -f "${current}" ]]; then
      artifact="${current}"
    elif [[ -n "${current}" ]]; then
      rebased="${artifact_dir}/$(basename "${current}")"
      if [[ -f "${rebased}" ]]; then
        artifact="${rebased}"
      fi
    fi
  fi

  if [[ -z "${artifact}" ]]; then
    artifact="$(newest_file "${artifact_dir}" "${pattern}")"
  fi

  if [[ -z "${artifact}" ]]; then
    warn "${label} artifact bulunamadi: ${artifact_dir}/${pattern}"
    return 0
  fi

  mkdir -p "$(dirname "${output_file}")"
  printf '%s\n' "${artifact}" > "${output_file}"
  info "${label}: ${artifact}"
}

refresh_iso_latest_file() {
  local output_file="${REPO_ROOT}/iso-release/latest-iso-path.txt"
  local legacy_output_file="${REPO_ROOT}/iso-realese/latest-iso-path.txt"
  local current=""
  local rebased=""
  local artifact=""
  local artifact_dir=""
  local current_file=""

  for current_file in "${output_file}" "${legacy_output_file}"; do
    if [[ -f "${current_file}" ]]; then
      current="$(<"${current_file}")"
      if [[ -f "${current}" ]]; then
        artifact="${current}"
        break
      fi
      for artifact_dir in "${REPO_ROOT}/iso-release" "${REPO_ROOT}/iso-realese"; do
        rebased="${artifact_dir}/$(basename "${current}")"
        if [[ -f "${rebased}" ]]; then
          artifact="${rebased}"
          break 2
        fi
      done
    fi
  done

  if [[ -z "${artifact}" ]]; then
    for artifact_dir in "${REPO_ROOT}/iso-release" "${REPO_ROOT}/iso-realese"; do
      current="$(newest_file "${artifact_dir}" "Ro-ASD-beta*.iso")"
      if [[ -n "${current}" && ( -z "${artifact}" || "${current}" -nt "${artifact}" ) ]]; then
        artifact="${current}"
      fi
    done
  fi

  if [[ -z "${artifact}" ]]; then
    warn "ISO artifact bulunamadi: iso-release veya iso-realese altinda Ro-ASD-beta*.iso"
    return 0
  fi

  mkdir -p "$(dirname "${output_file}")"
  printf '%s\n' "${artifact}" > "${output_file}"
  info "ISO: ${artifact}"
}

refresh_iso_latest_file

refresh_latest_file \
  "RPM" \
  "${REPO_ROOT}/rpm-outputs/latest-rpm-path.txt" \
  "${REPO_ROOT}/rpm-outputs" \
  "ro-installer-*.rpm"

info "Yerel path dosyalari guncellendi."
