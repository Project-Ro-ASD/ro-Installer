#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ISO_PATH="${RO_ASD_TEST_ISO:-}"

failures=0
warnings=0

info() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  warnings=$((warnings + 1))
  printf '[WARN] %s\n' "$*" >&2
}

fail() {
  failures=$((failures + 1))
  printf '[FAIL] %s\n' "$*" >&2
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "Required command not found: $1"
    return 1
  fi
}

usage() {
  cat <<'EOF'
Usage:
  scripts/03-audit-iso.sh [ISO_PATH]

Checks the Ro-ASD live ISO for the boot regressions that are easy to miss:
- El Torito UEFI image and hidden ESP contents
- GRUB live root parameters, safe graphics fallback, and GPU driver policy
- initrd dracut live modules
- Ro live kernel config and Intel/NVIDIA firmware manifests
- build, enabled repo, and installed package manifests
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -gt 0 ]]; then
  ISO_PATH="$1"
fi

if [[ -z "${ISO_PATH}" ]]; then
  for latest_file in \
    "${REPO_ROOT}/iso-release/latest-iso-path.txt" \
    "${REPO_ROOT}/iso-realese/latest-iso-path.txt"; do
    if [[ -f "${latest_file}" ]]; then
      candidate="$(<"${latest_file}")"
      if [[ -f "${candidate}" ]]; then
        ISO_PATH="${candidate}"
        break
      fi
      rebased="$(dirname "${latest_file}")/$(basename "${candidate}")"
      if [[ -f "${rebased}" ]]; then
        ISO_PATH="${rebased}"
        break
      fi
    fi
  done
fi

if [[ -z "${ISO_PATH}" || ! -f "${ISO_PATH}" ]]; then
  fail "ISO not found. Pass ISO_PATH or build one first."
fi

need_cmd xorriso || true
need_cmd dd || true
need_cmd mdir || true
need_cmd lsinitrd || true
need_cmd sha256sum || true

if (( failures > 0 )); then
  exit 1
fi

tmpdir="$(mktemp -d)"
cleanup() {
  rm -rf "${tmpdir}"
}
trap cleanup EXIT

info "ISO: ${ISO_PATH}"

xorriso_report="${tmpdir}/xorriso.txt"
xorriso -indev "${ISO_PATH}" -report_el_torito plain -report_system_area plain -end > "${xorriso_report}" 2>&1

volume_id="$(awk -F"'" '/Volume id/ {print $2; exit}' "${xorriso_report}")"
if [[ -z "${volume_id}" ]]; then
  fail "Could not read ISO volume id."
else
  info "Volume id: ${volume_id}"
fi

uefi_line="$(awk '/El Torito boot img :[[:space:]]+2[[:space:]]+UEFI/ {print; exit}' "${xorriso_report}")"
if [[ -z "${uefi_line}" ]]; then
  fail "UEFI El Torito boot image not found."
else
  uefi_size_512="$(awk '{print $(NF-1)}' <<<"${uefi_line}")"
  uefi_lba_2048="$(awk '{print $NF}' <<<"${uefi_line}")"
  info "UEFI image: LBA=${uefi_lba_2048}, size512=${uefi_size_512}"
  if [[ "${uefi_size_512}" =~ ^[0-9]+$ && "${uefi_lba_2048}" =~ ^[0-9]+$ ]]; then
    if (( uefi_size_512 % 4 != 0 )); then
      fail "UEFI image size is not aligned to 2048-byte sectors: ${uefi_size_512}"
    else
      dd if="${ISO_PATH}" of="${tmpdir}/esp.img" bs=2048 skip="${uefi_lba_2048}" count="$((uefi_size_512 / 4))" status=none
      esp_list="${tmpdir}/esp-list.txt"
      if mdir -i "${tmpdir}/esp.img" -/ :: > "${esp_list}"; then
        esp_compact="$(tr '[:upper:]' '[:lower:]' < "${esp_list}" | tr -d '[:space:]')"
        [[ "${esp_compact}" == *bootx64* ]] || fail "Hidden ESP is missing EFI/BOOT/BOOTX64.EFI."
        [[ "${esp_compact}" == *grubx64* ]] || fail "Hidden ESP is missing EFI/BOOT/grubx64.efi."
        [[ "${esp_compact}" == *grubcfg* ]] || fail "Hidden ESP is missing EFI/BOOT/grub.cfg."
      else
        fail "Could not list hidden ESP with mdir."
      fi
    fi
  else
    fail "Could not parse UEFI image line: ${uefi_line}"
  fi
fi

grub_cfg="${tmpdir}/grub.cfg"
xorriso -osirrox on -indev "${ISO_PATH}" -extract /boot/grub2/grub.cfg "${grub_cfg}" -end >/dev/null 2>&1 || true
if [[ -s "${grub_cfg}" ]]; then
  extract_menuentry() {
    local title="$1"
    awk -v title="${title}" '
      index($0, "menuentry \"" title "\"") {capture=1}
      capture {print}
      capture && /^[[:space:]]*}/ {exit}
    ' "${grub_cfg}"
  }

  grep -Fq "CDLABEL=${volume_id}" "${grub_cfg}" || fail "GRUB does not reference current ISO label ${volume_id}."
  grep -Fq 'rd.live.dir=LiveOS' "${grub_cfg}" || fail "GRUB is missing rd.live.dir=LiveOS."
  grep -Fq 'rd.live.squashimg=squashfs.img' "${grub_cfg}" || fail "GRUB is missing rd.live.squashimg=squashfs.img."
  grep -Fq 'rd.retry=180' "${grub_cfg}" || fail "GRUB is missing rd.retry=180."
  grep -Fq 'Start Ro-ASD Live in safe graphics mode' "${grub_cfg}" || fail "Safe graphics GRUB entry missing."
  grep -Fq 'Start Ro-ASD Live with X11 session' "${grub_cfg}" || fail "X11 live session GRUB entry missing."
  grep -Fq 'Start Ro-ASD Live with X11 software rendering' "${grub_cfg}" || fail "X11 software rendering GRUB entry missing."
  grep -Fq 'Start Ro-ASD Live with nouveau GSP disabled' "${grub_cfg}" || fail "nouveau GSP disabled GRUB entry missing."
  grep -Fq 'Start Ro-ASD Live with nouveau disabled' "${grub_cfg}" || fail "nouveau disabled GRUB entry missing."

  normal_entry="$(extract_menuentry 'Start Ro-ASD Live')"
  safe_entry="$(extract_menuentry 'Start Ro-ASD Live in safe graphics mode')"
  x11_entry="$(extract_menuentry 'Start Ro-ASD Live with X11 session')"
  software_entry="$(extract_menuentry 'Start Ro-ASD Live with X11 software rendering')"
  gsp_off_entry="$(extract_menuentry 'Start Ro-ASD Live with nouveau GSP disabled')"
  nouveau_disabled_entry="$(extract_menuentry 'Start Ro-ASD Live with nouveau disabled')"
  [[ -n "${normal_entry}" ]] || fail "Normal GRUB live entry could not be parsed."
  [[ -n "${safe_entry}" ]] || fail "Safe graphics GRUB entry could not be parsed."
  [[ -n "${x11_entry}" ]] || fail "X11 live session GRUB entry could not be parsed."
  [[ -n "${software_entry}" ]] || fail "X11 software rendering GRUB entry could not be parsed."
  [[ -n "${gsp_off_entry}" ]] || fail "nouveau GSP disabled GRUB entry could not be parsed."
  [[ -n "${nouveau_disabled_entry}" ]] || fail "nouveau disabled GRUB entry could not be parsed."

  if grep -Eq 'rd\.driver\.blacklist=[^[:space:]]*(i915|xe)|modprobe\.blacklist=[^[:space:]]*(i915|xe)|i915\.modeset=0|xe\.modeset=0' "${grub_cfg}"; then
    fail "GRUB blacklists or disables i915/xe; Intel graphics must stay available in all live entries."
  fi
  if grep -Eq 'nouveau\.modeset=0' "${grub_cfg}"; then
    fail "GRUB uses nouveau.modeset=0; use the explicit nouveau-disabled diagnostic entry instead."
  fi
  if grep -Fq 'nomodeset' <<<"${normal_entry}"; then
    fail "Normal GRUB entry contains nomodeset; only safe graphics may disable KMS."
  fi
  if grep -Eq 'rd\.driver\.blacklist=[^[:space:]]*(nouveau|i915|xe)|modprobe\.blacklist=[^[:space:]]*(nouveau|i915|xe)|nouveau\.modeset=0|i915\.modeset=0|xe\.modeset=0|nouveau\.config=NvGspRm=0|ro\.live\.software_render=1' <<<"${normal_entry}"; then
    fail "Normal GRUB entry contains diagnostic graphics overrides."
  fi
  grep -Fq 'nomodeset' <<<"${safe_entry}" || fail "Safe graphics GRUB entry is missing nomodeset."
  if grep -Eq 'rd\.driver\.blacklist=[^[:space:]]*(nouveau|i915|xe)|modprobe\.blacklist=[^[:space:]]*(nouveau|i915|xe)|nouveau\.config=NvGspRm=0|ro\.live\.software_render=1' <<<"${safe_entry}"; then
    fail "Safe graphics GRUB entry contains vendor-specific diagnostics; it should only add nomodeset."
  fi
  grep -Fq 'ro.live.session=x11' <<<"${x11_entry}" || fail "X11 GRUB entry is missing ro.live.session=x11."
  if grep -Fq 'ro.live.software_render=1' <<<"${x11_entry}"; then
    fail "X11 GRUB entry unexpectedly enables software rendering."
  fi
  grep -Fq 'ro.live.session=x11' <<<"${software_entry}" || fail "Software rendering GRUB entry is missing ro.live.session=x11."
  grep -Fq 'ro.live.software_render=1' <<<"${software_entry}" || fail "Software rendering GRUB entry is missing ro.live.software_render=1."
  grep -Fq 'nouveau.config=NvGspRm=0' <<<"${gsp_off_entry}" || fail "nouveau GSP disabled entry is missing nouveau.config=NvGspRm=0."
  if grep -Eq 'rd\.driver\.blacklist=[^[:space:]]*nouveau|modprobe\.blacklist=[^[:space:]]*nouveau' <<<"${gsp_off_entry}"; then
    fail "nouveau GSP disabled entry must keep nouveau loaded; blacklist belongs only to the nouveau disabled entry."
  fi
  grep -Eq 'rd\.driver\.blacklist=[^[:space:]]*nouveau' <<<"${nouveau_disabled_entry}" || fail "nouveau disabled entry is missing rd.driver.blacklist=nouveau."
  grep -Eq 'modprobe\.blacklist=[^[:space:]]*nouveau' <<<"${nouveau_disabled_entry}" || fail "nouveau disabled entry is missing modprobe.blacklist=nouveau."
  all_nouveau_blacklists="$(grep -E 'rd\.driver\.blacklist=[^[:space:]]*nouveau|modprobe\.blacklist=[^[:space:]]*nouveau' "${grub_cfg}" || true)"
  expected_nouveau_blacklists="$(grep -E 'rd\.driver\.blacklist=[^[:space:]]*nouveau|modprobe\.blacklist=[^[:space:]]*nouveau' <<<"${nouveau_disabled_entry}" || true)"
  if [[ "${all_nouveau_blacklists}" != "${expected_nouveau_blacklists}" ]]; then
    fail "nouveau blacklist is allowed only in the explicit nouveau disabled diagnostic entry."
  fi
  if grep -Fq 'Fedora-KDE-Live-43' "${grub_cfg}"; then
    fail "GRUB still references old Fedora CDLABEL."
  fi
else
  fail "Could not extract boot/grub2/grub.cfg."
fi

initrd="${tmpdir}/initrd"
xorriso -osirrox on -indev "${ISO_PATH}" -extract /boot/x86_64/loader/initrd "${initrd}" -end >/dev/null 2>&1 || true
if [[ -s "${initrd}" ]]; then
  modules="$(lsinitrd -m "${initrd}" 2>/dev/null || true)"
  grep -qx 'dmsquash-live' <<<"${modules}" || fail "initrd missing dmsquash-live module."
  grep -qx 'livenet' <<<"${modules}" || fail "initrd missing livenet module."
  grep -qx 'pollcdrom' <<<"${modules}" || fail "initrd missing pollcdrom module."
  info "initrd live modules: $(grep -E '^(dmsquash-live|livenet|pollcdrom)$' <<<"${modules}" | paste -sd' ' -)"
else
  fail "Could not extract boot/x86_64/loader/initrd."
fi

read_manifest_value() {
  local file="$1"
  local key="$2"
  awk -F= -v key="${key}" '$1 == key {print $2; exit}' "${file}"
}

kernel_config_manifest="${tmpdir}/ro-live-kernel-config-check.txt"
xorriso -osirrox on -indev "${ISO_PATH}" -extract /ro-live-kernel-config-check.txt "${kernel_config_manifest}" -end >/dev/null 2>&1 || true
if [[ -s "${kernel_config_manifest}" ]]; then
  required_kernel_options=(
    CONFIG_DRM_I915
    CONFIG_DRM_XE
    CONFIG_DRM_NOUVEAU
    CONFIG_DRM_SIMPLEDRM
    CONFIG_VMD
    CONFIG_TYPEC
    CONFIG_I2C_HID_ACPI
    CONFIG_MMC
  )
  config_source="$(read_manifest_value "${kernel_config_manifest}" CONFIG_SOURCE)"
  if [[ -z "${config_source}" || "${config_source}" == "missing" ]]; then
    fail "Ro live kernel config manifest does not point to a readable kernel config."
  fi
  for option in "${required_kernel_options[@]}"; do
    value="$(read_manifest_value "${kernel_config_manifest}" "${option}")"
    if [[ "${value}" != "y" && "${value}" != "m" ]]; then
      fail "Ro live kernel config ${option} is '${value:-missing}', expected y or m."
    fi
  done
else
  fail "Ro live kernel config manifest missing from ISO root."
fi

firmware_manifest="${tmpdir}/ro-live-firmware-check.txt"
xorriso -osirrox on -indev "${ISO_PATH}" -extract /ro-live-firmware-check.txt "${firmware_manifest}" -end >/dev/null 2>&1 || true
if [[ -s "${firmware_manifest}" ]]; then
  for key in FIRMWARE_I915 FIRMWARE_XE FIRMWARE_NVIDIA_GSP; do
    value="$(read_manifest_value "${firmware_manifest}" "${key}")"
    if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
      fail "Firmware manifest ${key} is '${value:-missing}', expected at least one file."
    elif (( value < 1 )); then
      fail "Firmware manifest ${key} is 0, expected at least one file."
    fi
  done
else
  fail "Ro live firmware manifest missing from ISO root."
fi

optional_missing="${tmpdir}/ro-optional-apps-missing.txt"
xorriso -osirrox on -indev "${ISO_PATH}" -extract /ro-optional-apps-missing.txt "${optional_missing}" -end >/dev/null 2>&1 || true
if [[ -s "${optional_missing}" ]]; then
  warn "Optional Ro desktop apps missing from this ISO: $(paste -sd' ' "${optional_missing}")"
fi

build_manifest="${tmpdir}/ro-build-manifest.txt"
xorriso -osirrox on -indev "${ISO_PATH}" -extract /ro-build-manifest.txt "${build_manifest}" -end >/dev/null 2>&1 || true
if [[ -s "${build_manifest}" ]]; then
  for key in \
    manifest_version \
    build_timestamp_utc \
    git_commit \
    git_dirty \
    source_iso_sha256 \
    rpm_sha256 \
    beta_tag \
    volume_id \
    image_mode \
    ro_live_kernel_version \
    release_policy_sha256; do
    value="$(read_manifest_value "${build_manifest}" "${key}")"
    [[ -n "${value}" ]] || fail "Build manifest missing ${key}."
  done
else
  fail "Build manifest missing from ISO root."
fi

release_policy="${tmpdir}/ro-release-policy.txt"
xorriso -osirrox on -indev "${ISO_PATH}" -extract /ro-release-policy.txt "${release_policy}" -end >/dev/null 2>&1 || true
if [[ -s "${release_policy}" ]]; then
  for key in \
    policy_version \
    system_role \
    kernel_policy \
    selected_kernel_channels \
    fedora_stock_kernel_policy \
    ro_repo_package_gpgcheck \
    ro_repo_metadata_gpgcheck \
    copr_kernel_package_gpgcheck \
    copr_kernel_metadata_gpgcheck \
    copr_kernel_metadata_reason \
    safe_graphics_policy \
    target_cmdline_policy; do
    value="$(read_manifest_value "${release_policy}" "${key}")"
    [[ -n "${value}" ]] || fail "Release policy missing ${key}."
  done
  [[ "$(read_manifest_value "${release_policy}" system_role)" == "live-iso" ]] || fail "Release policy has unexpected system_role."
  [[ "$(read_manifest_value "${release_policy}" kernel_policy)" == "ro-kernel-only" ]] || fail "Release policy must require ro-kernel-only."
  [[ "$(read_manifest_value "${release_policy}" selected_kernel_channels)" == "stable" ]] || fail "Live ISO release policy must use stable kernel channel."
  [[ "$(read_manifest_value "${release_policy}" ro_repo_package_gpgcheck)" == "1" ]] || fail "Release policy must require Ro repo package GPG."
  [[ "$(read_manifest_value "${release_policy}" ro_repo_metadata_gpgcheck)" == "1" ]] || fail "Release policy must require Ro repo metadata GPG."
  [[ "$(read_manifest_value "${release_policy}" copr_kernel_package_gpgcheck)" == "1" ]] || fail "Release policy must require COPR package GPG."
  [[ "$(read_manifest_value "${release_policy}" copr_kernel_metadata_gpgcheck)" == "0" ]] || fail "Release policy must record COPR metadata GPG as disabled."
  [[ "$(read_manifest_value "${release_policy}" copr_kernel_metadata_reason)" == "copr_metadata_signatures_not_available" ]] || fail "Release policy must explain COPR metadata GPG exception."
  expected_policy_sha=""
  if [[ -s "${build_manifest}" ]]; then
    expected_policy_sha="$(read_manifest_value "${build_manifest}" release_policy_sha256)"
  fi
  if [[ -n "${expected_policy_sha}" ]]; then
    actual_policy_sha="$(sha256sum "${release_policy}" | awk '{print $1}')"
    [[ "${actual_policy_sha}" == "${expected_policy_sha}" ]] || fail "Release policy sha256 does not match build manifest."
  else
    fail "Build manifest missing release_policy_sha256."
  fi
else
  fail "Release policy missing from ISO root."
fi

rpm_manifest="${tmpdir}/ro-live-rpm-manifest.txt"
xorriso -osirrox on -indev "${ISO_PATH}" -extract /ro-live-rpm-manifest.txt "${rpm_manifest}" -end >/dev/null 2>&1 || true
if [[ -s "${rpm_manifest}" ]]; then
  grep -Eq '^ro-installer-' "${rpm_manifest}" || fail "RPM manifest missing ro-installer package."
  grep -Eq '^ro-kernel-stable-core-' "${rpm_manifest}" || fail "RPM manifest missing ro-kernel-stable-core package."
  grep -Eq '^ro-kernel-stable-modules-' "${rpm_manifest}" || fail "RPM manifest missing ro-kernel-stable-modules package."
  grep -Eq '^ro-assist-' "${rpm_manifest}" || fail "RPM manifest missing ro-assist package."
  grep -Eq '^ro-control-' "${rpm_manifest}" || fail "RPM manifest missing ro-control package."
else
  fail "RPM manifest missing from ISO root."
fi

repo_manifest="${tmpdir}/ro-live-repolist.txt"
xorriso -osirrox on -indev "${ISO_PATH}" -extract /ro-live-repolist.txt "${repo_manifest}" -end >/dev/null 2>&1 || true
if [[ -s "${repo_manifest}" ]]; then
  grep -Fq 'ro-repo' "${repo_manifest}" || fail "Repo manifest missing ro-repo."
  grep -Fq 'ro-repo-noarch' "${repo_manifest}" || fail "Repo manifest missing ro-repo-noarch."
  grep -Fq 'ro-kernel-stable' "${repo_manifest}" || fail "Repo manifest missing ro-kernel-stable COPR."
else
  fail "Repo manifest missing from ISO root."
fi

if (( failures > 0 )); then
  printf '[RESULT] %d failure(s), %d warning(s). ISO is not release-ready.\n' "${failures}" "${warnings}" >&2
  exit 1
fi

printf '[RESULT] ISO audit passed with %d warning(s).\n' "${warnings}"
