#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

MODE="gui"
ISO_PATH="${RO_ASD_TEST_ISO:-}"
DISK_SIZE="${DISK_SIZE:-30G}"
MEMORY_MB="${MEMORY_MB:-4096}"
CPU_COUNT="${CPU_COUNT:-4}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-0}"
VIDEO_BACKEND="${QEMU_VIDEO:-virtio}"
BOOT_ENTRY="${QEMU_BOOT_ENTRY:-start}"
SSH_PORT="${QEMU_SSH_PORT:-2222}"
NO_KVM=0
CHECK_ONLY=0

RUN_ROOT="${REPO_ROOT}/outputs/qemu-iso-test"
STAMP="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="${RUN_ROOT}/${STAMP}"
DISK_IMAGE="${RUN_DIR}/test-disk.qcow2"
SERIAL_LOG="${RUN_DIR}/serial.log"
QEMU_LOG="${RUN_DIR}/qemu.log"
RUN_MANIFEST="${RUN_DIR}/run-manifest.txt"
QMP_SOCKET="${RUN_DIR}/qmp.sock"
OVMF_VARS_COPY="${RUN_DIR}/OVMF_VARS.fd"

info() {
  printf '[BILGI] %s\n' "$*"
}

warn() {
  printf '[UYARI] %s\n' "$*" >&2
}

fail() {
  printf '[HATA] %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Kullanim:
  scripts/qemu-boot-iso.sh [secenekler]

Amac:
  iso-release altinda uretilen Ro-ASD ISO'yu UEFI/OVMF ile QEMU'da baslatir.
  Installer'i otomatik calistirmaz; once ISO boot ve live masaustu kontrolu icindir.

Secenekler:
  --iso PATH        Test edilecek ISO. Varsayilan: RO_ASD_TEST_ISO, latest-iso-path.txt,
                    sonra iso-release/Ro-ASD-beta*.iso icindeki en yeni dosya.
  --gui            QEMU penceresi ac. Varsayilan mod.
  --headless       Grafik pencere acmadan baslat. Erken crash kontrolu icin kullanisli.
  --timeout SEC    Bu sure dolunca QEMU hala calisiyorsa testi basarili sayip kapatir.
                    0 verilirse QEMU kapanana kadar bekler. Varsayilan: 0.
  --disk-size SIZE  Sanal disk boyutu. Varsayilan: 30G.
  --memory MB      RAM. Varsayilan: 4096.
  --cpus N         CPU cekirdek sayisi. Varsayilan: 4.
  --video NAME     Sanal ekran karti: vmware, virtio, virtio-gl, cirrus, std, qxl.
                   Varsayilan: virtio. QEMU icin once virtio denenmelidir.
  --boot-entry NAME GRUB girdisini QMP ile otomatik sec: default, start,
                    media-check, debug, text, basic. Varsayilan: start.
                    debug/text/basic serial log icin console=ttyS0 girdilerini secer.
  --ssh-port PORT  Host 127.0.0.1:PORT -> guest :22 yonlendirmesi.
                   Varsayilan: 2222. Kapatmak icin 0 ver.
  --no-kvm         KVM yerine TCG emulasyon kullan.
  --check          Sadece host gereksinimlerini ve ISO/OVMF cozumlemesini kontrol et.
  -h, --help       Yardim.

Ornekler:
  scripts/qemu-boot-iso.sh
  scripts/qemu-boot-iso.sh --iso iso-release/Ro-ASD-beta1.iso --memory 8192
  scripts/qemu-boot-iso.sh --boot-entry debug --video virtio
  scripts/qemu-boot-iso.sh --headless --timeout 180 --boot-entry text
  scripts/qemu-boot-iso.sh --boot-entry text --ssh-port 2222
EOF
}

install_hint() {
  cat >&2 <<'EOF'

Eksik araclari kurmak icin:

Fedora:
  sudo dnf install -y qemu-system-x86 qemu-img edk2-ovmf

Debian/Ubuntu:
  sudo apt update
  sudo apt install -y qemu-system-x86 qemu-utils ovmf

Arch:
  sudo pacman -S --needed qemu-full edk2-ovmf

KVM izni icin:
  sudo usermod -aG kvm "$USER"
  # Sonra oturumu kapatip acin veya yeni shell icin:
  newgrp kvm
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iso)
      [[ $# -ge 2 ]] || fail "--iso bir deger ister."
      ISO_PATH="$2"
      shift 2
      ;;
    --gui)
      MODE="gui"
      shift
      ;;
    --headless)
      MODE="headless"
      shift
      ;;
    --timeout)
      [[ $# -ge 2 ]] || fail "--timeout bir deger ister."
      TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --disk-size)
      [[ $# -ge 2 ]] || fail "--disk-size bir deger ister."
      DISK_SIZE="$2"
      shift 2
      ;;
    --memory)
      [[ $# -ge 2 ]] || fail "--memory bir deger ister."
      MEMORY_MB="$2"
      shift 2
      ;;
    --cpus)
      [[ $# -ge 2 ]] || fail "--cpus bir deger ister."
      CPU_COUNT="$2"
      shift 2
      ;;
    --video)
      [[ $# -ge 2 ]] || fail "--video bir deger ister."
      VIDEO_BACKEND="$2"
      shift 2
      ;;
    --boot-entry)
      [[ $# -ge 2 ]] || fail "--boot-entry bir deger ister."
      BOOT_ENTRY="$2"
      shift 2
      ;;
    --ssh-port)
      [[ $# -ge 2 ]] || fail "--ssh-port bir deger ister."
      SSH_PORT="$2"
      shift 2
      ;;
    --no-kvm)
      NO_KVM=1
      shift
      ;;
    --check)
      CHECK_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Bilinmeyen arguman: $1"
      ;;
  esac
done

if [[ ! "${TIMEOUT_SECONDS}" =~ ^[0-9]+$ ]]; then
  fail "--timeout sayisal olmali: ${TIMEOUT_SECONDS}"
fi
if [[ ! "${MEMORY_MB}" =~ ^[0-9]+$ ]]; then
  fail "--memory MB cinsinden sayisal olmali: ${MEMORY_MB}"
fi
if [[ ! "${CPU_COUNT}" =~ ^[0-9]+$ ]]; then
  fail "--cpus sayisal olmali: ${CPU_COUNT}"
fi
if [[ ! "${SSH_PORT}" =~ ^[0-9]+$ ]]; then
  fail "--ssh-port sayisal olmali: ${SSH_PORT}"
fi
if (( SSH_PORT > 65535 )); then
  fail "--ssh-port 0-65535 araliginda olmali: ${SSH_PORT}"
fi
case "${VIDEO_BACKEND}" in
  vmware|virtio|virtio-gl|cirrus|std|qxl) ;;
  *) fail "--video gecersiz: ${VIDEO_BACKEND}. Gecerli degerler: vmware, virtio, virtio-gl, cirrus, std, qxl." ;;
esac
case "${BOOT_ENTRY}" in
  default|start|media-check|debug|text|basic) ;;
  *) fail "--boot-entry gecersiz: ${BOOT_ENTRY}. Gecerli degerler: default, start, media-check, debug, text, basic." ;;
esac

require_tools() {
  local missing=()
  local cmd
  for cmd in qemu-system-x86_64 qemu-img; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      missing+=("${cmd}")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    warn "Eksik host araclari: ${missing[*]}"
    install_hint
    exit 1
  fi
}

resolve_iso() {
  local candidate=""

  if [[ -n "${ISO_PATH}" ]]; then
    if [[ "${ISO_PATH}" != /* ]]; then
      candidate="${REPO_ROOT}/${ISO_PATH}"
    else
      candidate="${ISO_PATH}"
    fi
    [[ -f "${candidate}" ]] || fail "ISO bulunamadi: ${ISO_PATH}"
    printf '%s\n' "${candidate}"
    return 0
  fi

  local latest_file latest_dir
  for latest_file in \
    "${REPO_ROOT}/iso-release/latest-iso-path.txt" \
    "${REPO_ROOT}/iso-realese/latest-iso-path.txt"; do
    if [[ -f "${latest_file}" ]]; then
      candidate="$(<"${latest_file}")"
      if [[ -f "${candidate}" ]]; then
        printf '%s\n' "${candidate}"
        return 0
      fi

      latest_dir="$(dirname "${latest_file}")"
      local rebased="${latest_dir}/$(basename "${candidate}")"
      if [[ -f "${rebased}" ]]; then
        warn "latest-iso-path.txt eski makine yolunu gosteriyor; mevcut repo icindeki dosya kullaniliyor: ${rebased}"
        printf '%s\n' "${rebased}"
        return 0
      fi
    fi
  done

  local newest=""
  for latest_dir in "${REPO_ROOT}/iso-release" "${REPO_ROOT}/iso-realese"; do
    while IFS= read -r -d '' candidate; do
      if [[ -z "${newest}" || "${candidate}" -nt "${newest}" ]]; then
        newest="${candidate}"
      fi
    done < <(find "${latest_dir}" -maxdepth 1 -type f -name 'Ro-ASD-beta*.iso' -print0 2>/dev/null)
  done

  [[ -n "${newest}" ]] || fail "Uretilmis Ro-ASD ISO bulunamadi. Once scripts/02-build-iso.sh ile ISO uretin veya --iso PATH verin."
  printf '%s\n' "${newest}"
}

resolve_ovmf() {
  local pair code vars
  local pairs=(
    "/usr/share/edk2/ovmf/OVMF_CODE.fd:/usr/share/edk2/ovmf/OVMF_VARS.fd"
    "/usr/share/edk2/ovmf/x64/OVMF_CODE.fd:/usr/share/edk2/ovmf/x64/OVMF_VARS.fd"
    "/usr/share/edk2-ovmf/x64/OVMF_CODE.fd:/usr/share/edk2-ovmf/x64/OVMF_VARS.fd"
    "/usr/share/OVMF/OVMF_CODE.fd:/usr/share/OVMF/OVMF_VARS.fd"
    "/usr/share/OVMF/OVMF_CODE_4M.fd:/usr/share/OVMF/OVMF_VARS_4M.fd"
    "/usr/share/qemu/OVMF_CODE.fd:/usr/share/qemu/OVMF_VARS.fd"
  )

  for pair in "${pairs[@]}"; do
    code="${pair%%:*}"
    vars="${pair#*:}"
    if [[ -f "${code}" && -f "${vars}" ]]; then
      printf '%s\n%s\n' "${code}" "${vars}"
      return 0
    fi
  done

  warn "OVMF firmware dosyalari bulunamadi."
  install_hint
  exit 1
}

require_tools
ISO_FILE="$(resolve_iso)"
mapfile -t OVMF_INFO < <(resolve_ovmf)
OVMF_CODE="${OVMF_INFO[0]}"
OVMF_VARS_TEMPLATE="${OVMF_INFO[1]}"

info "Repo: ${REPO_ROOT}"
info "ISO: ${ISO_FILE}"
info "OVMF CODE: ${OVMF_CODE}"
info "OVMF VARS: ${OVMF_VARS_TEMPLATE}"
info "Mod: ${MODE}"
info "RAM/CPU/Disk: ${MEMORY_MB}MB / ${CPU_COUNT} CPU / ${DISK_SIZE}"
info "Video: ${VIDEO_BACKEND}"
info "Boot girdisi: ${BOOT_ENTRY}"
if (( SSH_PORT > 0 )); then
  info "SSH yonlendirme: host 127.0.0.1:${SSH_PORT} -> guest :22"
else
  info "SSH yonlendirme: kapali"
fi

if [[ ${CHECK_ONLY} -eq 1 ]]; then
  if [[ ${NO_KVM} -eq 0 && -e /dev/kvm ]]; then
    if [[ -r /dev/kvm && -w /dev/kvm ]]; then
      info "KVM: kullanilabilir."
    else
      warn "KVM var ama bu kullanicinin izni yok. 'sudo usermod -aG kvm \"$USER\"' sonrasi yeniden oturum acin."
    fi
  else
    warn "KVM kullanilmayacak; TCG emulasyon daha yavas calisir."
  fi
  info "Kontrol tamam."
  exit 0
fi

mkdir -p "${RUN_DIR}"
qemu-img create -f qcow2 "${DISK_IMAGE}" "${DISK_SIZE}" >/dev/null
cp -f "${OVMF_VARS_TEMPLATE}" "${OVMF_VARS_COPY}"

QEMU_ACCEL_ARGS=()
if [[ ${NO_KVM} -eq 0 && -e /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
  QEMU_ACCEL_ARGS=(-enable-kvm -cpu host)
else
  warn "KVM kullanilamiyor; QEMU TCG emulasyonla acilacak ve daha yavas olabilir."
  QEMU_ACCEL_ARGS=(-accel tcg,thread=multi -cpu max)
fi

QEMU_DISPLAY_ARGS=()
if [[ "${MODE}" == "headless" ]]; then
  QEMU_DISPLAY_ARGS=(-display none)
elif [[ "${MODE}" != "gui" ]]; then
  fail "Gecersiz mod: ${MODE}"
fi

QEMU_VIDEO_ARGS=()
case "${VIDEO_BACKEND}" in
  vmware)
    QEMU_VIDEO_ARGS=(-vga vmware)
    ;;
  virtio)
    QEMU_VIDEO_ARGS=(-device virtio-vga)
    ;;
  virtio-gl)
    if [[ "${MODE}" == "headless" ]]; then
      fail "--video virtio-gl grafik pencere gerektirir; --gui ile kullanin."
    fi
    QEMU_VIDEO_ARGS=(-display gtk,gl=on -device virtio-vga-gl)
    QEMU_DISPLAY_ARGS=()
    ;;
  cirrus)
    QEMU_VIDEO_ARGS=(-device cirrus-vga)
    ;;
  std)
    QEMU_VIDEO_ARGS=(-vga std)
    ;;
  qxl)
    QEMU_VIDEO_ARGS=(-vga qxl)
    ;;
esac

QEMU_NETDEV_ARG="user,id=net0"
if (( SSH_PORT > 0 )); then
  QEMU_NETDEV_ARG+=",hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22"
fi

QEMU_CMD=(
  qemu-system-x86_64
  -name "ro-asd-iso-boot"
  -machine q35
  "${QEMU_ACCEL_ARGS[@]}"
  -m "${MEMORY_MB}"
  -smp "${CPU_COUNT}"
  -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}"
  -drive "if=pflash,format=raw,file=${OVMF_VARS_COPY}"
  -cdrom "${ISO_FILE}"
  -drive "file=${DISK_IMAGE},format=qcow2,if=virtio"
  -netdev "${QEMU_NETDEV_ARG}"
  -device virtio-net-pci,netdev=net0
  "${QEMU_VIDEO_ARGS[@]}"
  -serial "file:${SERIAL_LOG}"
  -qmp "unix:${QMP_SOCKET},server=on,wait=off"
  -boot order=d,menu=on
  "${QEMU_DISPLAY_ARGS[@]}"
)

write_run_manifest() {
  local iso_sha256="unavailable"
  local qemu_command=""

  if command -v sha256sum >/dev/null 2>&1; then
    iso_sha256="$(sha256sum "${ISO_FILE}" | awk '{print $1}')"
  fi
  printf -v qemu_command '%q ' "${QEMU_CMD[@]}"

  cat > "${RUN_MANIFEST}" <<EOF
schema_version=1
artifact_kind=ro-asd-qemu-iso-boot
created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
repo_root=${REPO_ROOT}
iso_file=${ISO_FILE}
iso_sha256=${iso_sha256}
run_dir=${RUN_DIR}
disk_image=${DISK_IMAGE}
serial_log=${SERIAL_LOG}
qemu_log=${QEMU_LOG}
qmp_socket=${QMP_SOCKET}
ovmf_code=${OVMF_CODE}
ovmf_vars_template=${OVMF_VARS_TEMPLATE}
ovmf_vars_copy=${OVMF_VARS_COPY}
mode=${MODE}
memory_mb=${MEMORY_MB}
cpu_count=${CPU_COUNT}
disk_size=${DISK_SIZE}
video_backend=${VIDEO_BACKEND}
boot_entry=${BOOT_ENTRY}
ssh_port=${SSH_PORT}
no_kvm=${NO_KVM}
timeout_seconds=${TIMEOUT_SECONDS}
qemu_command=${qemu_command}
EOF
}

info "Calisma dizini: ${RUN_DIR}"
info "Serial log: ${SERIAL_LOG}"
info "QEMU log: ${QEMU_LOG}"
info "Run manifest: ${RUN_MANIFEST}"
info "QMP socket: ${QMP_SOCKET}"
if (( SSH_PORT > 0 )); then
  info "Guest icinde sshd acildiktan sonra hosttan baglan: ssh -p ${SSH_PORT} liveuser@127.0.0.1"
fi
info "QEMU baslatiliyor..."

QEMU_PID=""
cleanup() {
  if [[ -n "${QEMU_PID}" ]] && kill -0 "${QEMU_PID}" 2>/dev/null; then
    kill "${QEMU_PID}" 2>/dev/null || true
    wait "${QEMU_PID}" 2>/dev/null || true
  fi
}
trap cleanup INT TERM

write_run_manifest
"${QEMU_CMD[@]}" >"${QEMU_LOG}" 2>&1 &
QEMU_PID="$!"

wait_for_qmp_socket() {
  local timeout=20
  local waited=0

  until [[ -S "${QMP_SOCKET}" ]]; do
    if ! kill -0 "${QEMU_PID}" 2>/dev/null; then
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
    if (( waited >= timeout )); then
      return 1
    fi
  done

  return 0
}

wait_for_boot_menu() {
  local timeout=25
  local waited=0

  while (( waited < timeout )); do
    if [[ -f "${SERIAL_LOG}" ]] && grep -aEq 'Start (Ro-ASD|Fedora).*Live|Troubleshooting' "${SERIAL_LOG}"; then
      return 0
    fi
    if ! kill -0 "${QEMU_PID}" 2>/dev/null; then
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done

  return 1
}

send_key() {
  local combo="$1"
  python3 "${REPO_ROOT}/linux/qmp_send_keys.py" \
    --socket "${QMP_SOCKET}" \
    --combo "${combo}" \
    --delay-ms 70 >/dev/null
}

select_boot_entry() {
  [[ "${BOOT_ENTRY}" != "default" ]] || return 0

  if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 bulunamadi; GRUB girdisi otomatik secilemedi. Varsayilan girdiden devam ediliyor."
    return 0
  fi
  if [[ ! -f "${REPO_ROOT}/linux/qmp_send_keys.py" ]]; then
    warn "QMP tus gonderme araci bulunamadi; GRUB girdisi otomatik secilemedi."
    return 0
  fi
  if ! wait_for_qmp_socket; then
    warn "QMP socket hazir olmadi; GRUB girdisi otomatik secilemedi."
    return 0
  fi
  if ! wait_for_boot_menu; then
    warn "GRUB menusu serial logda algilanamadi; varsayilan girdiden devam ediliyor."
    return 0
  fi

  info "GRUB girdisi seciliyor: ${BOOT_ENTRY}"
  send_key home
  sleep 1

  case "${BOOT_ENTRY}" in
    start)
      send_key ret
      ;;
    media-check)
      send_key down
      send_key ret
      ;;
    debug)
      send_key down
      send_key down
      send_key ret
      sleep 1
      send_key home
      send_key ret
      ;;
    text)
      send_key down
      send_key down
      send_key ret
      sleep 1
      send_key home
      send_key down
      send_key ret
      ;;
    basic)
      send_key down
      send_key down
      send_key ret
      sleep 1
      send_key home
      send_key down
      send_key down
      send_key ret
      ;;
  esac
}

select_boot_entry

if (( TIMEOUT_SECONDS > 0 )); then
  deadline=$((SECONDS + TIMEOUT_SECONDS))
  while kill -0 "${QEMU_PID}" 2>/dev/null; do
    if (( SECONDS >= deadline )); then
      info "Timeout doldu ve QEMU hala calisiyor; erken boot crash gorunmedi."
      info "Artefaktlar: ${RUN_MANIFEST}"
      cleanup
      exit 0
    fi
    sleep 1
  done

  wait "${QEMU_PID}"
  rc=$?
  fail "QEMU timeout dolmadan kapandi. Cikis kodu: ${rc}. Manifest: ${RUN_MANIFEST}. Serial log: ${SERIAL_LOG}. QEMU log: ${QEMU_LOG}"
fi

wait "${QEMU_PID}"
