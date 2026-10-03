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

# Legacy ISO helpers remain syntax-checked while they are in the repository;
# their composition and release policies are not Installer product invariants.
check_shell_syntax() {
  local file
  local result=0
  for file in test_qemu_vm.sh test_qemu_guest_runner.sh scripts/*.sh linux/*.sh; do
    bash -n "${file}" || result=1
  done
  return "${result}"
}

run_check "shell script syntax" check_shell_syntax

run_check "QMP helper python syntax" \
  python3 -m py_compile linux/qmp_send_keys.py

if command -v flutter >/dev/null 2>&1; then
  run_check "flutter analyze" flutter analyze
  run_check "flutter test" flutter test
else
  fail "flutter bulunamadi; stable kabul icin flutter analyze/test zorunlu"
fi

if command -v dart >/dev/null 2>&1; then
  run_check "i18n audit" dart run tool/i18n_audit.dart
else
  fail "dart bulunamadi; stable kabul icin i18n audit zorunlu"
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

# Ro-Compose owns repository wiring, image composition, and baseline kernel
# policy. Do not require the legacy Ro/COPR/ISO release-policy implementation.
run_check "COPR source tarball hijyeni" \
  sh -c 'rg -q "git archive" .copr/Makefile && rg -q "Source tarball contains forbidden files" .copr/Makefile && rg -q "sha256sum" .copr/Makefile && rg -q "/docs/old/ export-ignore" .gitattributes && rg -q "/docs/road.md export-ignore" .gitattributes && rg -q "/docs/road-plan.md export-ignore" .gitattributes && rg -q "/gerçeksistemdenloglar/ export-ignore" .gitattributes && ! rg -q "cp -a \\." .copr/Makefile'

require_rpm_build_policy() {
  rg -q 'ALLOW_NODEPS=0' scripts/01-build-rpm.sh || return 1
  rg -q -- '--allow-nodeps' scripts/01-build-rpm.sh || return 1
  rg -q 'rpmbuild_nodeps=' scripts/01-build-rpm.sh || return 1
  rg -q 'audit_source_tarball' scripts/01-build-rpm.sh || return 1
  rg -q 'source_tarball_sha256=' scripts/01-build-rpm.sh || return 1
  rg -q 'latest-rpm-manifest.txt' scripts/01-build-rpm.sh || return 1
  rg -q '^%license LICENSE$' ro-installer.spec || return 1
  rg -q '^%doc README.md$' ro-installer.spec || return 1
  ! rg -q '^%doc docs/road.md$' ro-installer.spec || return 1
  rg -q '^Requires:[[:space:]]+%\{_bindir\}/udevadm$' ro-installer.spec || return 1
}

run_check "RPM build hijyeni" require_rpm_build_policy

require_log_artifact_contract() {
  rg -q 'diagnosticContractVersion' lib/services/install_artifact_collector.dart || return 1
  rg -q 'diagnosticSectionIds' lib/services/install_artifact_collector.dart || return 1
  rg -q 'ARTIFACT_SECTION' lib/services/install_artifact_collector.dart || return 1
  rg -q 'journalctl' lib/services/install_artifact_collector.dart || return 1
  rg -q 'dmesg' lib/services/install_artifact_collector.dart || return 1
  rg -q 'manifestPath' lib/services/install_log_export_service.dart || return 1
  rg -q 'ro-installer-install-session' lib/services/install_log_export_service.dart || return 1
  rg -q 'collectionContract' lib/services/install_log_export_service.dart || return 1
  rg -q 'RUN_MANIFEST' scripts/qemu-boot-iso.sh || return 1
  rg -q 'QEMU_LOG' scripts/qemu-boot-iso.sh || return 1
  rg -q 'artifact_kind=ro-asd-qemu-iso-boot' scripts/qemu-boot-iso.sh || return 1
  rg -q 'serial_log=' scripts/qemu-boot-iso.sh || return 1
  rg -q 'qemu_log=' scripts/qemu-boot-iso.sh || return 1
}

run_check "log ve hata artefakt sozlesmesi" require_log_artifact_contract

require_document_lifecycle_policy() {
  local extra_markdown
  rg -q 'Do not commit local planning notes' README.md || return 1
  ! rg -q 'docs/road|docs/old|road-plan|durum.md|plan.md|test.md|eksikler.md|optimizasyon.md' README.md || return 1
  rg -q '^/docs/road.md$' .gitignore || return 1
  rg -q '^/docs/road-plan.md$' .gitignore || return 1
  rg -q '^/docs/old/$' .gitignore || return 1
  rg -q '^/docs/old/ export-ignore$' .gitattributes || return 1

  extra_markdown="$(
    while IFS= read -r file; do
      [[ -e "${file}" ]] || continue
      [[ "${file}" == "README.md" ]] || printf '%s\n' "${file}"
    done < <(git ls-files '*.md')
  )"
  if [[ -n "${extra_markdown}" ]]; then
    printf '%s\n' "${extra_markdown}" >&2
    return 1
  fi
}

run_check "dokuman yasam dongusu ve aktif markdown siniri" require_document_lifecycle_policy

require_github_rpm_ci_hygiene() {
  # Retain source cleanliness and RPM evidence without pinning a Fedora release,
  # workflow filename, SDK path, or action version.
  rg -q 'scripts/01-build-rpm.sh --no-chain --source-mode git --require-clean-git' .github/workflows/*.yml || return 1
  rg -q 'actions/upload-artifact@' .github/workflows/*.yml || return 1
  rg -q 'rpm-outputs/\*.rpm' .github/workflows/*.yml || return 1
  rg -q 'latest-rpm-manifest.txt' .github/workflows/*.yml || return 1
}

run_check "GitHub RPM source ve artefakt hijyeni" require_github_rpm_ci_hygiene

require_qemu_test_contract() {
  rg -q 'qemu-boot-iso.sh' scripts/test-qemu.sh || return 1
  rg -q 'test_qemu_vm.sh' scripts/test-qemu.sh || return 1
  rg -q 'suite.*smoke' scripts/test-qemu.sh || return 1
  rg -q 'RO_INSTALLER_TEST_ISO' test_qemu_vm.sh || return 1
  rg -q -- '--enforce-lockfile' test_qemu_vm.sh || return 1
  rg -q -- 'build linux --release --no-pub' test_qemu_vm.sh || return 1
  rg -q '.dart_tool/flutter_build' test_qemu_vm.sh || return 1
  rg -q 'pubspec.lock dosyasini degistirdi' test_qemu_vm.sh || return 1
  rg -Fq 'DISK_SIZE="${DISK_SIZE:-64G}"' test_qemu_vm.sh || return 1
  rg -q 'DISK_SIZE="64G"' scripts/test-qemu.sh || return 1
  rg -q 'HOST_VM_LOG_DIR="\$RUN_DIR/guest-logs"' test_qemu_vm.sh || return 1
  rg -q 'Installer failure summary bulundu' test_qemu_vm.sh || return 1
  rg -q 'RO_INSTALLER_GUEST_RUNNER_INSTALL_EXIT' test_qemu_guest_runner.sh || return 1
  rg -q 'GUEST_RUNNER_START_TIMEOUT_SECONDS' test_qemu_vm.sh || return 1
  rg -Fq 'QEMU_DISPLAY_MODE="${QEMU_DISPLAY_MODE:-headless}"' test_qemu_vm.sh || return 1
  rg -Fq 'QEMU_DISPLAY_MODE="${QEMU_MODE}"' scripts/test-qemu.sh || return 1
  rg -q 'Guest runner baslangic marker' test_qemu_vm.sh || return 1
  rg -Fq 'QMP_KEY_DELAY_MS="${QMP_KEY_DELAY_MS:-90}"' test_qemu_vm.sh || return 1
  ! rg -q 'version=9p2000' test_qemu_vm.sh || return 1
  ! rg -q 'RO_INSTALLER_VM_LOG_DIR=\$GUEST_VM_LOG_DIR' test_qemu_vm.sh || return 1
  rg -Fq 'HOST_MOUNT_IN_GUEST="${HOST_MOUNT_IN_GUEST:-/run/ro-host}"' test_qemu_vm.sh || return 1
  rg -Fq 'HOST_MOUNT="${HOST_MOUNT:-/run/ro-host}"' test_qemu_guest_runner.sh || return 1
  ! rg -q '/mnt/host' test_qemu_vm.sh test_qemu_guest_runner.sh || return 1
  rg -q 'HOST_LOG_DIR="\$PROFILE_DIR/guest-logs"' test_qemu_guest_runner.sh || return 1
  rg -q 'write_runner_state "started"' test_qemu_guest_runner.sh || return 1
  rg -q 'runner-state.txt' test_qemu_vm.sh || return 1
  rg -q 'sudo -n tee /dev/ttyS0' test_qemu_guest_runner.sh || return 1
}

run_check "QEMU install test ve log sozlesmesi" require_qemu_test_contract

forbid_pattern \
  "live sudo politikasi NOPASSWD ALL degil" \
  'NOPASSWD:[[:space:]]*ALL' \
  scripts linux lib

forbid_pattern \
  "urun build'inde prototip C++ backend yok" \
  'ro_backend|add_subdirectory\("backend"\)|SystemCommand::execute|popen\(' \
  linux lib scripts ro-installer.spec

forbid_pattern \
  "urun assetleri ignored prototip klasorune bagli degil" \
  'stitch_velvet_nebula_installer_redesign/product-logo\.png' \
  lib pubspec.yaml

if [ "${failures}" -ne 0 ]; then
  printf '[SONUC] Stable kapisi basarisiz: %s hata\n' "${failures}" >&2
  exit 1
fi

printf '[SONUC] Stable kapisi basarili\n'
