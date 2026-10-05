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

# Syntax-check the active Installer packaging and external-ISO test helpers.
check_shell_syntax() {
  local file
  local result=0
  for file in test_qemu_vm.sh test_qemu_guest_runner.sh scripts/*.sh linux/*.sh; do
    bash -n "${file}" || result=1
  done
  return "${result}"
}

run_check "shell script syntax" check_shell_syntax

run_check "QEMU SPICE harness tests (no VM boot)" \
  python3 test/scripts/qemu_spice_test.py

run_check "QMP/QGA helper python syntax" \
  python3 -m py_compile linux/qmp_send_keys.py linux/qga_client.py

run_check "QGA transport tests (fake Unix server)" \
  python3 test/scripts/qga_client_test.py

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

# Ro-Compose owns repository wiring, image composition, and baseline kernels.
# Installer gates retain architecture-neutral RPM source hygiene.
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
  rg -q 'scripts/01-build-rpm.sh --source-mode git --require-clean-git' .github/workflows/*.yml || return 1
  rg -q 'actions/upload-artifact@' .github/workflows/*.yml || return 1
  rg -q 'rpm-outputs/\*.rpm' .github/workflows/*.yml || return 1
  rg -q 'latest-rpm-manifest.txt' .github/workflows/*.yml || return 1
}

run_check "GitHub RPM source ve artefakt hijyeni" require_github_rpm_ci_hygiene

require_fedora44_packaging_baseline() {
  local workflow=".github/workflows/rpm-fedora44.yml"
  [[ -f "$workflow" && ! -e .github/workflows/rpm-fedora43.yml ]] || return 1
  rg -q '^      image: fedora:44$' "$workflow" || return 1
  rg -q 'scripts/01-build-rpm.sh --source-mode git --require-clean-git' "$workflow" || return 1
  rg -q '^          name: ro-installer-rpm-fedora44$' "$workflow" || return 1
  if rg -q 'name:.*fedora43' "$workflow"; then return 1; fi
  rg -Fq 'RPM_PATH="$(cat rpm-outputs/latest-rpm-path.txt)"' "$workflow" || return 1
  rg -Fq 'test -f "$RPM_PATH"' "$workflow" || return 1
  rg -Fq "rpm -qp --qf '%{NAME} %{VERSION} %{RELEASE} %{ARCH}\\n' \"\$RPM_PATH\"" "$workflow" || return 1
  rg -Fq "RPM_RELEASE=\"\$(rpm -qp --qf '%{RELEASE}' \"\$RPM_PATH\")\"" "$workflow" || return 1
  rg -Fq '*.fc44) ;;' "$workflow" || return 1
  rg -Fq '*) echo "Expected Fedora 44 RPM release, got: $RPM_RELEASE" >&2; exit 1 ;;' "$workflow" || return 1
  rg -Fq 'dnf -y --setopt=install_weak_deps=False install "$RPM_PATH"' "$workflow" || return 1
  rg -q '^          rpm -q ro-installer$' "$workflow" || return 1
}

run_check "Fedora 44 RPM packaging baseline" require_fedora44_packaging_baseline

require_ro_repo_release_producer_contract() {
  local ci_workflow=".github/workflows/rpm-fedora44.yml"
  local release_workflow=".github/workflows/release.yml"
  local manifest_builder="scripts/build-ro-repo-manifest.py"

  [[ -f "$release_workflow" && -f "$manifest_builder" ]] || return 1

  ! rg -q '^[[:space:]]+tags:' "$ci_workflow" || return 1
  ! rg -q '^[[:space:]]+release:' "$ci_workflow" || return 1
  ! rg -q 'action-gh-release|gh release upload|releases/tags' "$ci_workflow" || return 1

  rg -q '^name: Release
  local script
  for script in scripts/qemu-boot-iso.sh scripts/test-qemu.sh; do
    rg -q 'RO_ASD_TEST_ISO' "${script}" || return 1
  done
  for script in scripts/qemu-boot-iso.sh scripts/test-qemu.sh test_qemu_vm.sh; do
    rg -q 'external Compose-produced test ISO is required' "${script}" || return 1
  done
  ! rg -n 'iso-release|iso-realese|latest-iso|Ro-ASD-beta|find .*\*\.iso' scripts/qemu-boot-iso.sh scripts/test-qemu.sh test_qemu_vm.sh || return 1
  rg -q 'RO_INSTALLER_GUEST_RUNNER_START' test_qemu_guest_runner.sh || return 1
  rg -q 'RO_INSTALLER_VM_BOOT_OK' test_qemu_vm.sh || return 1
  rg -q 'hostshare' test_qemu_vm.sh || return 1
  rg -q 'build/linux/x64/release/bundle/ro_installer' test_qemu_guest_runner.sh || return 1

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
  rg -q 'QGA_READY_TIMEOUT_SECONDS' test_qemu_vm.sh || return 1
  rg -Fq 'QEMU_DISPLAY_MODE="${QEMU_DISPLAY_MODE:-headless}"' test_qemu_vm.sh || return 1
  rg -Fq 'QEMU_DISPLAY_MODE="${QEMU_MODE}"' scripts/test-qemu.sh || return 1
  rg -q 'Guest runner baslangic marker' test_qemu_vm.sh || return 1
  rg -q 'org.qemu.guest_agent.0' test_qemu_vm.sh || return 1
  rg -q 'RO_INSTALLER_AUTO_REBOOT=0' test_qemu_vm.sh || return 1
  rg -q 'runner-logs-copied-0' test_qemu_vm.sh || return 1
  rg -q 'orchestrate_guest_install' test_qemu_vm.sh || return 1
  ! rg -q -- '--text|ctrl-alt-t|GUEST_TERMINAL_OPEN_WAIT_SECONDS' test_qemu_vm.sh || return 1
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

require_external_iso_boundary() {
  local file
  for file in scripts/build-iso.sh scripts/02-build-iso.sh scripts/03-audit-iso.sh scripts/04-benchmark-copy-paths.sh kernel.txt; do
    [[ ! -e "${file}" ]] || return 1
  done
  ! rg -n --glob '!check-stable.sh' \
    'build-iso\.sh|audit-iso\.sh|benchmark-copy-paths\.sh|iso-(release|realese)/latest-iso|CHAIN_ISO|(^|[[:space:]])(xorriso|mksquashfs|mkisofs|genisoimage)([[:space:]]|$)' \
    scripts linux/*.sh test_qemu_vm.sh test_qemu_guest_runner.sh || return 1
  ! rg -q -- '--no-chain|--source-iso|--beta|--no-host-auto-install' scripts/01-build-rpm.sh || return 1
  ! rg -q -- '--suite audit|--skip-audit|--allow-unsigned-ro-repo' scripts/test-qemu.sh || return 1
}

run_check "Installer ISO uretmez; test ISO harici giristir" require_external_iso_boundary

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
 "$release_workflow" || return 1
  rg -q '^[[:space:]]+tags:' "$release_workflow" || return 1
  rg -q 'scripts/01-build-rpm.sh --source-mode git --require-clean-git' "$release_workflow" || return 1
  rg -q 'component-artifact-manifest-v1.json' "$release_workflow" || return 1
  rg -q 'actions/attest@' "$release_workflow" || return 1
  rg -q 'id-token:[[:space:]]+write' "$release_workflow" || return 1
  rg -q 'attestations:[[:space:]]+write' "$release_workflow" || return 1
  rg -q 'artifact-metadata:[[:space:]]+write' "$release_workflow" || return 1
  rg -q 'tag/release reuse is forbidden' "$release_workflow" || return 1
  rg -Fq '[[ "${#EXPECTED[@]}" -eq 4 ]]' "$release_workflow" || return 1

  rg -q '"component":[[:space:]]*"ro-installer"' "$manifest_builder" || return 1
  rg -q '"source_repository":[[:space:]]*args.repository' "$manifest_builder" || return 1
  rg -q '"source_commit":[[:space:]]*args.commit' "$manifest_builder" || return 1
  rg -q '"release_id":[[:space:]]*int\(args.release_id\)' "$manifest_builder" || return 1
  rg -q '"workflow_run":[[:space:]]*int\(args.workflow_run\)' "$manifest_builder" || return 1
}

run_check "Ro-Repo immutable release producer contract" require_ro_repo_release_producer_contract

require_qemu_test_contract() {
  local script
  for script in scripts/qemu-boot-iso.sh scripts/test-qemu.sh; do
    rg -q 'RO_ASD_TEST_ISO' "${script}" || return 1
  done
  for script in scripts/qemu-boot-iso.sh scripts/test-qemu.sh test_qemu_vm.sh; do
    rg -q 'external Compose-produced test ISO is required' "${script}" || return 1
  done
  ! rg -n 'iso-release|iso-realese|latest-iso|Ro-ASD-beta|find .*\*\.iso' scripts/qemu-boot-iso.sh scripts/test-qemu.sh test_qemu_vm.sh || return 1
  rg -q 'RO_INSTALLER_GUEST_RUNNER_START' test_qemu_guest_runner.sh || return 1
  rg -q 'RO_INSTALLER_VM_BOOT_OK' test_qemu_vm.sh || return 1
  rg -q 'hostshare' test_qemu_vm.sh || return 1
  rg -q 'build/linux/x64/release/bundle/ro_installer' test_qemu_guest_runner.sh || return 1

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
  rg -q 'QGA_READY_TIMEOUT_SECONDS' test_qemu_vm.sh || return 1
  rg -Fq 'QEMU_DISPLAY_MODE="${QEMU_DISPLAY_MODE:-headless}"' test_qemu_vm.sh || return 1
  rg -Fq 'QEMU_DISPLAY_MODE="${QEMU_MODE}"' scripts/test-qemu.sh || return 1
  rg -q 'Guest runner baslangic marker' test_qemu_vm.sh || return 1
  rg -q 'org.qemu.guest_agent.0' test_qemu_vm.sh || return 1
  rg -q 'RO_INSTALLER_AUTO_REBOOT=0' test_qemu_vm.sh || return 1
  rg -q 'runner-logs-copied-0' test_qemu_vm.sh || return 1
  rg -q 'orchestrate_guest_install' test_qemu_vm.sh || return 1
  ! rg -q -- '--text|ctrl-alt-t|GUEST_TERMINAL_OPEN_WAIT_SECONDS' test_qemu_vm.sh || return 1
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

require_external_iso_boundary() {
  local file
  for file in scripts/build-iso.sh scripts/02-build-iso.sh scripts/03-audit-iso.sh scripts/04-benchmark-copy-paths.sh kernel.txt; do
    [[ ! -e "${file}" ]] || return 1
  done
  ! rg -n --glob '!check-stable.sh' \
    'build-iso\.sh|audit-iso\.sh|benchmark-copy-paths\.sh|iso-(release|realese)/latest-iso|CHAIN_ISO|(^|[[:space:]])(xorriso|mksquashfs|mkisofs|genisoimage)([[:space:]]|$)' \
    scripts linux/*.sh test_qemu_vm.sh test_qemu_guest_runner.sh || return 1
  ! rg -q -- '--no-chain|--source-iso|--beta|--no-host-auto-install' scripts/01-build-rpm.sh || return 1
  ! rg -q -- '--suite audit|--skip-audit|--allow-unsigned-ro-repo' scripts/test-qemu.sh || return 1
}

run_check "Installer ISO uretmez; test ISO harici giristir" require_external_iso_boundary

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
