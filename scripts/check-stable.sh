#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

failures=0

info() {
  printf '[CHECK] %s\n' "$*"
}

pass() {
  printf '[ OK ] %s\n' "$*"
}

fail() {
  printf '[FAIL] %s\n' "$*" >&2
  failures=$((failures + 1))
}

run_check() {
  local label="$1"
  shift
  info "$label"
  if "$@"; then
    pass "$label"
  else
    fail "$label"
  fi
}

forbid_pattern() {
  local label="$1"
  local pattern="$2"
  shift 2
  info "$label"
  if rg -n --glob '!scripts/check-stable.sh' "${pattern}" "$@"; then
    fail "$label"
  else
    pass "$label"
  fi
}

require_cmd() {
  local cmd="$1"
  if command -v "${cmd}" >/dev/null 2>&1; then
    pass "${cmd} mevcut"
  else
    fail "${cmd} bulunamadi"
    return 1
  fi
}

require_cmd rg || true
require_cmd python3 || true

run_check "shell script syntax" \
  bash -n \
  test_qemu_vm.sh \
  test_qemu_guest_runner.sh \
  scripts/01-build-rpm.sh \
  scripts/02-build-iso.sh \
  scripts/03-audit-iso.sh \
  scripts/04-benchmark-copy-paths.sh \
  scripts/qemu-boot-iso.sh

run_check "QMP helper python syntax" \
  python3 -m py_compile linux/qmp_send_keys.py

if command -v flutter >/dev/null 2>&1; then
  run_check "flutter analyze" flutter analyze
  run_check "flutter test" flutter test
else
  fail "flutter bulunamadi; stable kabul icin flutter analyze/test zorunlu"
fi

forbid_pattern \
  "disk komutlarinda shell wildcard yok" \
  'umount -f .*\*|selectedDisk\*' \
  lib scripts test_qemu_vm.sh test_qemu_guest_runner.sh

forbid_pattern \
  "parola chpasswd shell argumanina yazilmiyor" \
  'echo .*\| *chpasswd|root:root' \
  lib scripts

forbid_pattern \
  "RPM GPG kontrolleri kapali degil" \
  '(^|[[:space:]])gpgcheck=0($|[[:space:]])' \
  lib scripts ro-installer.spec

require_ro_repo_metadata_gpg() {
  local file
  local key_count
  local metadata_count
  for file in lib/services/install_stages/chroot_config_stage.dart scripts/02-build-iso.sh; do
    rg -n 'project-ro-asd.github.io/Ro-Repo' "${file}" >/dev/null
    metadata_count="$(rg -c '^repo_gpgcheck=1$' "${file}" || true)"
    key_count="$(rg -c '^gpgkey=https://project-ro-asd.github.io/Ro-Repo/RPM-GPG-KEY-ro-asd$' "${file}" || true)"
    [[ "${metadata_count}" -ge 2 ]]
    [[ "${key_count}" -ge 2 ]]
  done
}

run_check "Ro repo metadata GPG zorunlu" require_ro_repo_metadata_gpg

forbid_pattern \
  "live sudo politikasi NOPASSWD ALL degil" \
  'NOPASSWD:[[:space:]]*ALL' \
  scripts linux lib

if [ "${failures}" -ne 0 ]; then
  printf '[SONUC] Stable kapisi basarisiz: %s hata\n' "${failures}" >&2
  exit 1
fi

printf '[SONUC] Stable kapisi basarili\n'
