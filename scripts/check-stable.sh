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
  scripts/build-iso.sh \
  scripts/test-qemu.sh \
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

require_ro_repo_metadata_gpg() {
  local file
  local key_count
  local metadata_count
  for file in lib/services/install_stages/chroot_config_stage.dart; do
    rg -n 'project-ro-asd.github.io/Ro-Repo' "${file}" >/dev/null
    metadata_count="$(rg -c '^repo_gpgcheck=1$' "${file}" || true)"
    key_count="$(rg -c '^gpgkey=https://project-ro-asd.github.io/Ro-Repo/RPM-GPG-KEY-ro-asd$' "${file}" || true)"
    [[ "${metadata_count}" -ge 2 ]]
    [[ "${key_count}" -ge 2 ]]
  done
  rg -q 'ro_repo_gpgcheck=1' scripts/02-build-iso.sh
  rg -q 'ro_repo_metadata_gpgcheck=1' scripts/02-build-iso.sh
  rg -q 'ro_repo_signatures_not_published' scripts/02-build-iso.sh
  rg -q -- '--allow-unsigned-ro-repo' scripts/02-build-iso.sh
}

run_check "Ro repo metadata GPG zorunlu" require_ro_repo_metadata_gpg

require_ro_release_policy_contract() {
  rg -q 'kernel_policy=ro-kernel-only' lib/services/install_stages/chroot_config_stage.dart
  rg -q 'kernel_policy=ro-kernel-only' scripts/02-build-iso.sh
  rg -q 'kernel_policy=ro-kernel-only' lib/services/install_stages/post_install_validation_stage.dart
  rg -q 'Release policy missing from ISO root' scripts/03-audit-iso.sh
  rg -q 'copr_kernel_metadata_gpgcheck=0' lib/services/install_stages/chroot_config_stage.dart
  rg -q 'copr_kernel_metadata_gpgcheck=0' scripts/02-build-iso.sh
  rg -q 'copr_kernel_metadata_gpgcheck=0' lib/services/install_stages/post_install_validation_stage.dart
  rg -q '/ro-release-policy.txt' scripts/02-build-iso.sh
  rg -q 'release_policy_sha256' scripts/02-build-iso.sh
  rg -q 'release_policy_sha256' scripts/03-audit-iso.sh
  rg -q 'Ro-Repo is not release-signed' scripts/02-build-iso.sh
  rg -q 'Release policy must require Ro repo package and metadata GPG' scripts/03-audit-iso.sh
  rg -q 'dnf_retry' scripts/02-build-iso.sh
  rg -q -- "--disablerepo='copr:copr.fedorainfracloud.org:hynkzz:ro-kernel-stable'" scripts/02-build-iso.sh
  rg -q 'timeout=180' scripts/02-build-iso.sh
  rg -q 'validate_executable_runtime' scripts/02-build-iso.sh
  rg -q 'validate_executable_runtime' lib/services/install_stages/post_install_validation_stage.dart
  rg -q '/usr/libexec/ro-assist/ro-assist' scripts/02-build-iso.sh
  rg -q '/usr/libexec/ro-assist/ro-assist' lib/services/install_stages/post_install_validation_stage.dart
  rg -q 'is not a dynamic ELF executable' lib/services/install_stages/post_install_validation_stage.dart
  rg -q "count_firmware '\\*/i915/\\*.bin\\*'" scripts/02-build-iso.sh
  rg -q "count_firmware '\\*/xe/\\*.bin\\*'" scripts/02-build-iso.sh
  rg -q "count_firmware '\\*/nvidia/\\*/gsp\\*.bin\\*'" scripts/02-build-iso.sh
}

run_check "Ro release policy kaniti zorunlu" require_ro_release_policy_contract

run_check "COPR source tarball hijyeni" \
  sh -c 'rg -q "git archive" .copr/Makefile && rg -q "Source tarball contains forbidden files" .copr/Makefile && rg -q "sha256sum" .copr/Makefile && rg -q "/docs/old/ export-ignore" .gitattributes && rg -q "/docs/road.md export-ignore" .gitattributes && rg -q "/docs/road-plan.md export-ignore" .gitattributes && rg -q "/gerçeksistemdenloglar/ export-ignore" .gitattributes && rg -q "/iso-release/ export-ignore" .gitattributes && rg -q "iso-release" .copr/Makefile && ! rg -q "cp -a \\." .copr/Makefile'

require_rpm_build_policy() {
  rg -q 'ALLOW_NODEPS=0' scripts/01-build-rpm.sh
  rg -q -- '--allow-nodeps' scripts/01-build-rpm.sh
  rg -q 'rpmbuild_nodeps=' scripts/01-build-rpm.sh
  rg -q 'audit_source_tarball' scripts/01-build-rpm.sh
  rg -q 'source_tarball_sha256=' scripts/01-build-rpm.sh
  rg -q 'latest-rpm-manifest.txt' scripts/01-build-rpm.sh
  rg -q '^%license LICENSE$' ro-installer.spec
  rg -q '^%doc README.md$' ro-installer.spec
  ! rg -q '^%doc docs/road.md$' ro-installer.spec
  rg -q '^Requires:[[:space:]]+%\{_sbindir\}/ntfsresize$' ro-installer.spec
  rg -q '^Requires:[[:space:]]+%\{_bindir\}/udevadm$' ro-installer.spec
}

run_check "RPM build policy ve runtime bagimliliklari" require_rpm_build_policy

require_log_artifact_contract() {
  rg -q 'diagnosticContractVersion' lib/services/install_artifact_collector.dart
  rg -q 'diagnosticSectionIds' lib/services/install_artifact_collector.dart
  rg -q 'ARTIFACT_SECTION' lib/services/install_artifact_collector.dart
  rg -q 'artifact_title_release_policy' lib/services/install_artifact_collector.dart
  rg -q 'journalctl' lib/services/install_artifact_collector.dart
  rg -q 'dmesg' lib/services/install_artifact_collector.dart
  rg -q 'manifestPath' lib/services/install_log_export_service.dart
  rg -q 'ro-installer-install-session' lib/services/install_log_export_service.dart
  rg -q 'collectionContract' lib/services/install_log_export_service.dart
  rg -q 'RUN_MANIFEST' scripts/qemu-boot-iso.sh
  rg -q 'QEMU_LOG' scripts/qemu-boot-iso.sh
  rg -q 'artifact_kind=ro-asd-qemu-iso-boot' scripts/qemu-boot-iso.sh
  rg -q 'serial_log=' scripts/qemu-boot-iso.sh
  rg -q 'qemu_log=' scripts/qemu-boot-iso.sh
}

run_check "log ve hata artefakt sozlesmesi" require_log_artifact_contract

require_document_lifecycle_policy() {
  local extra_markdown
  rg -q 'Do not commit local planning notes' README.md
  ! rg -q 'docs/road|docs/old|road-plan|durum.md|plan.md|test.md|eksikler.md|optimizasyon.md' README.md
  rg -q '^/docs/road.md$' .gitignore
  rg -q '^/docs/road-plan.md$' .gitignore
  rg -q '^/docs/old/$' .gitignore
  rg -q '^/docs/old/ export-ignore$' .gitattributes

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

require_github_rpm_ci_policy() {
  local workflow=".github/workflows/rpm-fedora43.yml"
  [[ -f "${workflow}" ]]
  rg -q 'fedora:43' "${workflow}"
  rg -q '/opt/flutter/bin' "${workflow}"
  ! rg -q '^[[:space:]]+flutter[[:space:]]*\\$' "${workflow}"
  rg -q 'scripts/01-build-rpm.sh --no-chain --source-mode git --require-clean-git' "${workflow}"
  rg -q 'actions/upload-artifact@v4' "${workflow}"
  rg -q 'softprops/action-gh-release@v2' "${workflow}"
  rg -q 'rpm-outputs/\*.rpm' "${workflow}"
  rg -q 'latest-rpm-manifest.txt' "${workflow}"
}

run_check "GitHub Fedora 43 RPM CI sozlesmesi" require_github_rpm_ci_policy

require_release_entrypoint_policy() {
  rg -q 'scripts/01-build-rpm.sh' scripts/build-iso.sh
  rg -q 'scripts/02-build-iso.sh' scripts/build-iso.sh
  rg -q 'gh release download' scripts/build-iso.sh
  rg -q 'RPM_SOURCE=".*github' scripts/build-iso.sh
  rg -q -- '--rpm-source' scripts/build-iso.sh
  rg -q -- '--github-tag' scripts/build-iso.sh
  rg -q -- '--allow-unsigned-ro-repo' scripts/build-iso.sh
  rg -q 'rpm-outputs/latest-rpm-path.txt' scripts/build-iso.sh
  rg -q 'iso-release/latest-iso-path.txt' scripts/build-iso.sh
  rg -q '03-audit-iso.sh' scripts/test-qemu.sh
  rg -q 'detect_audit_policy_from_manifest' scripts/test-qemu.sh
  rg -q 'allow_unsigned_ro_repo=1' scripts/test-qemu.sh
  rg -q -- '--allow-unsigned-ro-repo' scripts/test-qemu.sh
  rg -q 'qemu-boot-iso.sh' scripts/test-qemu.sh
  rg -q 'test_qemu_vm.sh' scripts/test-qemu.sh
  rg -q 'suite.*smoke' scripts/test-qemu.sh
  rg -q 'RO_INSTALLER_TEST_ISO' test_qemu_vm.sh
  rg -q 'iso-release/latest-iso-path.txt' test_qemu_vm.sh
  rg -q -- '--enforce-lockfile' test_qemu_vm.sh
  rg -q -- 'build linux --release --no-pub' test_qemu_vm.sh
  rg -q '.dart_tool/flutter_build' test_qemu_vm.sh
  rg -q 'pubspec.lock dosyasini degistirdi' test_qemu_vm.sh
  rg -Fq 'DISK_SIZE="${DISK_SIZE:-64G}"' test_qemu_vm.sh
  rg -q 'DISK_SIZE="64G"' scripts/test-qemu.sh
  rg -q 'HOST_VM_LOG_DIR="\$RUN_DIR/guest-logs"' test_qemu_vm.sh
  rg -q 'Installer failure summary bulundu' test_qemu_vm.sh
  rg -q 'RO_INSTALLER_GUEST_RUNNER_INSTALL_EXIT' test_qemu_guest_runner.sh
  rg -q 'GUEST_RUNNER_START_TIMEOUT_SECONDS' test_qemu_vm.sh
  rg -Fq 'QEMU_DISPLAY_MODE="${QEMU_DISPLAY_MODE:-headless}"' test_qemu_vm.sh
  rg -Fq 'QEMU_DISPLAY_MODE="${QEMU_MODE}"' scripts/test-qemu.sh
  rg -q 'Guest runner baslangic marker' test_qemu_vm.sh
  rg -Fq 'QMP_KEY_DELAY_MS="${QMP_KEY_DELAY_MS:-90}"' test_qemu_vm.sh
  ! rg -q 'version=9p2000' test_qemu_vm.sh
  ! rg -q 'RO_INSTALLER_VM_LOG_DIR=\$GUEST_VM_LOG_DIR' test_qemu_vm.sh
  rg -Fq 'HOST_MOUNT_IN_GUEST="${HOST_MOUNT_IN_GUEST:-/run/ro-host}"' test_qemu_vm.sh
  rg -Fq 'HOST_MOUNT="${HOST_MOUNT:-/run/ro-host}"' test_qemu_guest_runner.sh
  ! rg -q '/mnt/host' test_qemu_vm.sh test_qemu_guest_runner.sh
  rg -q 'HOST_LOG_DIR="\$PROFILE_DIR/guest-logs"' test_qemu_guest_runner.sh
  rg -q 'write_runner_state "started"' test_qemu_guest_runner.sh
  rg -q 'runner-state.txt' test_qemu_vm.sh
  rg -q 'sudo -n tee /dev/ttyS0' test_qemu_guest_runner.sh
}

run_check "tek komut ISO/QEMU entrypoint sozlesmesi" require_release_entrypoint_policy

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
