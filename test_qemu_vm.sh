#!/bin/bash
set -euo pipefail

# Ro-Installer - Otomatik QEMU/KVM Sanal Laboratuvarı
#
# Varsayılan akış:
# 1. Linux release binary derlenir
# 2. Fedora Live ISO bir kez ISO'dan açılır
# 3. QMP üzerinden Live oturuma komut enjekte edilir
# 4. Guest tarafında profil tabanlı otomatik kurulum başlatılır
# 5. Kurulu sistem reboot eder
# 6. İlk açılışta smoke service seri porta "RO_INSTALLER_VM_BOOT_OK" yazar
# 7. VM kapanır ve host script başarıyı raporlar

MODE="${1:-auto}"
PROFILE_RELATIVE_PATH="${2:-test/fixtures/profile_full_btrfs.json}"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_ROOT="$PROJECT_DIR/outputs/vm"
STAMP="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$RUN_ROOT/$STAMP"

DISK_SIZE="${DISK_SIZE:-64G}"
MEMORY_MB="${MEMORY_MB:-4096}"
CPU_COUNT="${CPU_COUNT:-4}"
LIVE_BOOT_WAIT_SECONDS="${LIVE_BOOT_WAIT_SECONDS:-120}"
AUTO_TEST_TIMEOUT_SECONDS="${AUTO_TEST_TIMEOUT_SECONDS:-1800}"
GUEST_RUNNER_START_TIMEOUT_SECONDS="${GUEST_RUNNER_START_TIMEOUT_SECONDS:-300}"
QMP_KEY_DELAY_MS="${QMP_KEY_DELAY_MS:-90}"
BOOT_MENU_WAIT_SECONDS="${BOOT_MENU_WAIT_SECONDS:-20}"
VM_GUEST_DISK="${VM_GUEST_DISK:-/dev/vda}"
QEMU_DISPLAY_MODE="${QEMU_DISPLAY_MODE:-headless}"
HOST_MOUNT_IN_GUEST="${HOST_MOUNT_IN_GUEST:-/run/ro-host}"

DISK_IMAGE="$RUN_DIR/test_disk.qcow2"
SERIAL_LOG="$RUN_DIR/serial.log"
QMP_SOCKET="$RUN_DIR/qmp.sock"
OVMF_VARS_COPY="$RUN_DIR/OVMF_VARS.fd"
HOST_VM_LOG_DIR="$RUN_DIR/guest-logs"
GENERATED_PROFILE_RELATIVE_PATH="outputs/vm/$STAMP/auto_profile.json"
GENERATED_PROFILE_PATH="$PROJECT_DIR/$GENERATED_PROFILE_RELATIVE_PATH"

mkdir -p "$RUN_DIR"
mkdir -p "$HOST_VM_LOG_DIR"

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

HOST_PREFIX=()
if [ -x "/usr/bin/flatpak-spawn" ] && ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
  HOST_PREFIX=(/usr/bin/flatpak-spawn --host)
fi

run_host() {
  "${HOST_PREFIX[@]}" "$@"
}

host_sh() {
  "${HOST_PREFIX[@]}" sh -lc "$1"
}

cleanup() {
  if [ -n "${QEMU_PID:-}" ] && kill -0 "$QEMU_PID" 2>/dev/null; then
    kill "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
  fi
}

trap cleanup EXIT INT TERM

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "$1 bulunamadi."
  fi
}

require_host_cmd() {
  if ! host_sh "command -v '$1' >/dev/null 2>&1"; then
    fail "$1 bulunamadi."
  fi
}

resolve_host_compilers() {
  local clang_c="/usr/bin/clang"
  local clang_cxx="/usr/bin/clang++"

  if [ -x "$clang_c" ] && [ -x "$clang_cxx" ]; then
    printf '%s\n%s\n' "$clang_c" "$clang_cxx"
    return 0
  fi

  local path_cxx=""
  path_cxx="$(command -v clang++ 2>/dev/null || true)"
  if [ -n "$path_cxx" ] && [ "$path_cxx" = "$HOME/.local/bin/clang++" ]; then
    fail "PATH icindeki clang++ Flatpak sarmalayicisi gorunuyor: $path_cxx. Host makinede gercek clang kurulu degil. 'sudo dnf install clang' kurup tekrar deneyin."
  fi

  fail "Host makinede /usr/bin/clang ve /usr/bin/clang++ bulunamadi. 'sudo dnf install clang' kurup tekrar deneyin."
}

resolve_flutter() {
  if command -v flutter >/dev/null 2>&1; then
    command -v flutter
    return 0
  fi

  if [ -x "$HOME/development/flutter/bin/flutter" ]; then
    printf '%s\n' "$HOME/development/flutter/bin/flutter"
    return 0
  fi

  fail "flutter bulunamadi. FLUTTER_BIN tanimlayin veya PATH duzenleyin."
}

resolve_iso() {
  local explicit="${RO_INSTALLER_TEST_ISO:-}"
  if [ -n "$explicit" ]; then
    [ -f "$explicit" ] || fail "Belirtilen ISO bulunamadi: $explicit"
    printf '%s\n' "$explicit"
    return 0
  fi

  local latest_file latest_dir candidate found newest search_dir
  for latest_file in \
    "$PROJECT_DIR/iso-release/latest-iso-path.txt" \
    "$PROJECT_DIR/iso-realese/latest-iso-path.txt"; do
    if [ -f "$latest_file" ]; then
      candidate="$(cat "$latest_file")"
      if [ -f "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
      fi

      latest_dir="$(dirname "$latest_file")"
      candidate="$latest_dir/$(basename "$candidate")"
      if [ -f "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    fi
  done

  newest=""
  for search_dir in "$PROJECT_DIR/iso-release" "$PROJECT_DIR/iso-realese" "$PROJECT_DIR"; do
    [ -d "$search_dir" ] || continue
    found="$(find "$search_dir" -maxdepth 1 -type f \( -name 'Ro-ASD-beta*.iso' -o -name '*.iso' \) | sort | tail -n 1)"
    if [ -n "$found" ] && { [ -z "$newest" ] || [ "$found" -nt "$newest" ]; }; then
      newest="$found"
    fi
  done

  [ -n "$newest" ] || fail "Ro-ASD/Fedora Live ISO bulunamadi. RO_INSTALLER_TEST_ISO ile yol verebilirsiniz."
  printf '%s\n' "$newest"
}

resolve_profile_source() {
  if [ -f "$PROFILE_RELATIVE_PATH" ]; then
    printf '%s\n' "$PROFILE_RELATIVE_PATH"
    return 0
  fi

  if [ -f "$PROJECT_DIR/$PROFILE_RELATIVE_PATH" ]; then
    printf '%s\n' "$PROJECT_DIR/$PROFILE_RELATIVE_PATH"
    return 0
  fi

  fail "Profil bulunamadi: $PROFILE_RELATIVE_PATH"
}

resolve_ovmf() {
  local code=""
  local vars=""

  if [ -f "/usr/share/edk2/ovmf/OVMF_CODE.fd" ]; then
    code="/usr/share/edk2/ovmf/OVMF_CODE.fd"
    vars="/usr/share/edk2/ovmf/OVMF_VARS.fd"
  elif [ -f "/usr/share/OVMF/OVMF_CODE.fd" ]; then
    code="/usr/share/OVMF/OVMF_CODE.fd"
    vars="/usr/share/OVMF/OVMF_VARS.fd"
  elif [ -f "/usr/share/edk2/ovmf/x64/OVMF_CODE.fd" ]; then
    code="/usr/share/edk2/ovmf/x64/OVMF_CODE.fd"
    vars="/usr/share/edk2/ovmf/x64/OVMF_VARS.fd"
  fi

  [ -n "$code" ] || fail "OVMF_CODE.fd bulunamadi. Gerekli paketler: edk2-ovmf"
  [ -n "$vars" ] || fail "OVMF_VARS.fd bulunamadi. Gerekli paketler: edk2-ovmf"
  [ -f "$vars" ] || fail "OVMF_VARS.fd bulunamadi: $vars"

  printf '%s\n%s\n' "$code" "$vars"
}

build_installer() {
  local flutter_bin
  local host_cc
  local host_cxx
  local flutter_build_dir
  local cmake_release_dir
  local lock_sha_before
  local lock_sha_after
  flutter_bin="$(resolve_flutter)"
  mapfile -t _compilers < <(resolve_host_compilers)
  host_cc="${_compilers[0]}"
  host_cxx="${_compilers[1]}"
  flutter_build_dir="$PROJECT_DIR/.dart_tool/flutter_build"
  cmake_release_dir="$PROJECT_DIR/build/linux/x64/release"

  info "Linux release binary derleniyor..."
  info "C derleyicisi: $host_cc"
  info "C++ derleyicisi: $host_cxx"

  [ -f "$PROJECT_DIR/pubspec.lock" ] || fail "pubspec.lock bulunamadi; deterministik VM testi icin lockfile zorunlu."
  lock_sha_before="$(sha256sum "$PROJECT_DIR/pubspec.lock" | awk '{print $1}')"
  "$flutter_bin" pub get --enforce-lockfile
  lock_sha_after="$(sha256sum "$PROJECT_DIR/pubspec.lock" | awk '{print $1}')"
  if [ "$lock_sha_before" != "$lock_sha_after" ]; then
    fail "flutter pub get pubspec.lock dosyasini degistirdi. VM testi lockfile'i sessizce guncellemez."
  fi

  if [ -d "$flutter_build_dir" ]; then
    info "Flutter build cache temizleniyor: $flutter_build_dir"
    rm -rf "$flutter_build_dir"
  fi

  if [ -d "$cmake_release_dir" ]; then
    info "Linux release build dizini temizleniyor: $cmake_release_dir"
    rm -rf "$cmake_release_dir"
  fi

  CC="$host_cc" CXX="$host_cxx" "$flutter_bin" build linux --release --no-pub
}

prepare_vm_profile() {
  [ -n "${PROFILE_SOURCE_PATH:-}" ] || fail "Profil kaynak yolu hazir degil."

  info "VM profili hazirlaniyor..."
  info "Kaynak profil: $PROFILE_SOURCE_PATH"
  info "Guest disk yolu: $VM_GUEST_DISK"
  info "Uretilen profil: $GENERATED_PROFILE_PATH"

  VM_PROFILE_SOURCE="$PROFILE_SOURCE_PATH" \
  VM_PROFILE_TARGET="$GENERATED_PROFILE_PATH" \
  VM_GUEST_DISK="$VM_GUEST_DISK" \
  python3 - <<'PY'
import json
import os

source = os.environ['VM_PROFILE_SOURCE']
target = os.environ['VM_PROFILE_TARGET']
guest_disk = os.environ['VM_GUEST_DISK']

with open(source, 'r', encoding='utf-8') as handle:
    profile = json.load(handle)

profile['selectedDisk'] = guest_disk

os.makedirs(os.path.dirname(target), exist_ok=True)
with open(target, 'w', encoding='utf-8') as handle:
    json.dump(profile, handle, ensure_ascii=True, indent=2)
    handle.write('\n')
PY
}

prepare_disk() {
  info "QCOW2 disk olusturuluyor: $DISK_IMAGE ($DISK_SIZE)"
  run_host qemu-img create -f qcow2 "$DISK_IMAGE" "$DISK_SIZE" >/dev/null
}

wait_for_qmp_socket() {
  local timeout=30
  local waited=0

  until [ -S "$QMP_SOCKET" ]; do
    sleep 1
    waited=$((waited + 1))
    if [ "$waited" -ge "$timeout" ]; then
      fail "QMP socket hazir olmadi: $QMP_SOCKET"
    fi
  done
}

wait_for_serial_pattern() {
  local pattern="$1"
  local timeout="${2:-30}"
  local waited=0

  while [ "$waited" -lt "$timeout" ]; do
    if [ -f "$SERIAL_LOG" ] && grep -qE "$pattern" "$SERIAL_LOG"; then
      return 0
    fi

    if [ -n "${QEMU_PID:-}" ] && ! kill -0 "$QEMU_PID" 2>/dev/null; then
      return 1
    fi

    sleep 1
    waited=$((waited + 1))
  done

  return 1
}

select_live_boot_entry() {
  info "Live ISO boot menusu bekleniyor..."

  if ! wait_for_serial_pattern 'Start (Ro-ASD|Fedora).*Live|Start Fedora' "$BOOT_MENU_WAIT_SECONDS"; then
    warn "Boot menusu $BOOT_MENU_WAIT_SECONDS saniyede algilanamadi. Varsayilan ISO girdisi ile devam edilecek."
    return 0
  fi

  info "Ilk live boot girdisi seciliyor..."
  python3 "$PROJECT_DIR/linux/qmp_send_keys.py" \
    --socket "$QMP_SOCKET" \
    --combo home

  sleep 1

  python3 "$PROJECT_DIR/linux/qmp_send_keys.py" \
    --socket "$QMP_SOCKET" \
    --combo ret
}

run_manual_mode() {
  info "Manual mod secildi."
  info "Profil tabanli guest runner hazir: $PROJECT_DIR/test_qemu_guest_runner.sh"
  warn "Bu modda komut enjeksiyonu yapilmaz; VM ekrani ile siz ilgilenirsiniz."

  run_host qemu-system-x86_64 \
    -name "ro-installer-manual" \
    -enable-kvm \
    -m "$MEMORY_MB" \
    -cpu host \
    -smp "$CPU_COUNT" \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$OVMF_VARS_COPY" \
    -cdrom "$ISO_FILE" \
    -drive file="$DISK_IMAGE",format=qcow2,if=virtio \
    -fsdev local,security_model=passthrough,id=fsdev0,path="$PROJECT_DIR" \
    -device virtio-9p-pci,id=fs0,fsdev=fsdev0,mount_tag=hostshare \
    -net nic,model=virtio -net user \
    -vga virtio \
    -serial file:"$SERIAL_LOG" \
    -boot order=c,once=d,menu=on
}

launch_auto_vm() {
  local display_args=()

  case "$QEMU_DISPLAY_MODE" in
    headless)
      display_args=(-display none)
      ;;
    gui)
      display_args=()
      ;;
    *)
      fail "Gecersiz QEMU_DISPLAY_MODE: $QEMU_DISPLAY_MODE (headless|gui)"
      ;;
  esac

  info "QEMU otomatik test ortami baslatiliyor (display: $QEMU_DISPLAY_MODE)..."

  run_host qemu-system-x86_64 \
    -name "ro-installer-auto" \
    -enable-kvm \
    -m "$MEMORY_MB" \
    -cpu host \
    -smp "$CPU_COUNT" \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$OVMF_VARS_COPY" \
    -cdrom "$ISO_FILE" \
    -drive file="$DISK_IMAGE",format=qcow2,if=virtio \
    -fsdev local,security_model=passthrough,id=fsdev0,path="$PROJECT_DIR" \
    -device virtio-9p-pci,id=fs0,fsdev=fsdev0,mount_tag=hostshare \
    -net nic,model=virtio -net user \
    -vga virtio \
    "${display_args[@]}" \
    -serial file:"$SERIAL_LOG" \
    -qmp unix:"$QMP_SOCKET",server=on,wait=off \
    -boot order=c,once=d,menu=off &

  QEMU_PID="$!"
  wait_for_qmp_socket
  info "QEMU PID: $QEMU_PID"
}

send_guest_command() {
  local command_text="$1"

  info "Live ortamda komut enjeksiyonu icin $LIVE_BOOT_WAIT_SECONDS saniye bekleniyor..."
  sleep "$LIVE_BOOT_WAIT_SECONDS"

  info "Konsole aciliyor (Ctrl+Alt+T)..."
  python3 "$PROJECT_DIR/linux/qmp_send_keys.py" \
    --socket "$QMP_SOCKET" \
    --delay-ms "$QMP_KEY_DELAY_MS" \
    --combo ctrl-alt-t

  sleep 3

  info "Guest terminaline runner komutu gonderiliyor..."
  python3 "$PROJECT_DIR/linux/qmp_send_keys.py" \
    --socket "$QMP_SOCKET" \
    --text "$command_text" \
    --delay-ms "$QMP_KEY_DELAY_MS" \
    --enter

  info "Komut gonderildi. Kurulum, reboot ve smoke test bekleniyor."
  info "Zaman asimi: $AUTO_TEST_TIMEOUT_SECONDS saniye. Seri log: $SERIAL_LOG"
}

monitor_auto_test() {
  local deadline=$((SECONDS + AUTO_TEST_TIMEOUT_SECONDS))
  local next_progress=60
  local failed_summary
  local elapsed
  local runner_state_file="${HOST_VM_LOG_DIR}/runner-state.txt"

  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ -f "$SERIAL_LOG" ] && grep -q 'RO_INSTALLER_VM_BOOT_OK' "$SERIAL_LOG"; then
      info "Smoke test marker bulundu."
      return 0
    fi

    failed_summary="$(find "$HOST_VM_LOG_DIR" -maxdepth 1 -type f -name '*.summary.json' -print 2>/dev/null | sort | tail -n 1)"
    if [ -n "$failed_summary" ] && grep -q '"success"[[:space:]]*:[[:space:]]*false' "$failed_summary"; then
      warn "Installer failure summary bulundu: $failed_summary"
      return 1
    fi

    elapsed=$((AUTO_TEST_TIMEOUT_SECONDS - (deadline - SECONDS)))
    if [ "$elapsed" -ge "$GUEST_RUNNER_START_TIMEOUT_SECONDS" ]; then
      if [[ ! -s "$runner_state_file" ]] && ! grep -q 'RO_INSTALLER_GUEST_RUNNER_START' "$SERIAL_LOG" 2>/dev/null; then
        warn "Guest runner baslangic marker'i ${GUEST_RUNNER_START_TIMEOUT_SECONDS}s icinde gorulmedi; komut enjeksiyonu baslamamis olabilir."
        return 1
      fi
    fi

    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
      break
    fi

    local remaining=$((deadline - SECONDS))
    elapsed=$((AUTO_TEST_TIMEOUT_SECONDS - remaining))
    if [ "$elapsed" -ge "$next_progress" ]; then
      info "Otomatik test suruyor... gecen: ${elapsed}s, kalan en fazla: ${remaining}s"
      next_progress=$((next_progress + 60))
    fi

    sleep 5
  done

  return 1
}

print_failure_context() {
  local latest_summary=""
  local latest_install_log=""
  local runner_state_file="${HOST_VM_LOG_DIR}/runner-state.txt"

  warn "Otomatik VM testi basarisiz oldu."
  warn "Calisma dizini: $RUN_DIR"
  warn "Seri log: $SERIAL_LOG"
  if [ -s "$runner_state_file" ]; then
    warn "Guest runner state: $runner_state_file"
    cat "$runner_state_file" >&2 || true
  elif ! grep -q 'RO_INSTALLER_GUEST_RUNNER_START' "$SERIAL_LOG" 2>/dev/null; then
    warn "Guest runner baslangic marker'i seri logda yok; QMP klavye enjeksiyonu live oturumda komutu baslatamamis olabilir."
  fi
  latest_summary="$(find "$HOST_VM_LOG_DIR" -maxdepth 1 -type f -name '*.summary.json' -print 2>/dev/null | sort | tail -n 1)"
  latest_install_log="$(find "$HOST_VM_LOG_DIR" -maxdepth 1 -type f -name '*.log' -print 2>/dev/null | sort | tail -n 1)"
  if [ -z "$latest_summary" ] && [ -z "$latest_install_log" ]; then
    warn "Guest log dizininde installer artefakti yok: $HOST_VM_LOG_DIR"
  fi
  if [ -n "$latest_summary" ]; then
    warn "Installer summary: $latest_summary"
    cat "$latest_summary" >&2 || true
  fi
  if [ -n "$latest_install_log" ]; then
    warn "Installer log son satirlari: $latest_install_log"
    tail -n 80 "$latest_install_log" >&2 || true
  fi
  if [ -f "$SERIAL_LOG" ]; then
    warn "Seri log son satirlari:"
    tail -n 40 "$SERIAL_LOG" >&2 || true
  fi
}

require_host_cmd qemu-system-x86_64
require_host_cmd qemu-img
require_cmd python3

FLUTTER_BIN="$(resolve_flutter)"
ISO_FILE="$(resolve_iso)"
PROFILE_SOURCE_PATH="$(resolve_profile_source)"
mapfile -t OVMF_INFO < <(host_sh '
if [ -f "/usr/share/edk2/ovmf/OVMF_CODE.fd" ]; then
  printf "%s\n%s\n" "/usr/share/edk2/ovmf/OVMF_CODE.fd" "/usr/share/edk2/ovmf/OVMF_VARS.fd"
elif [ -f "/usr/share/OVMF/OVMF_CODE.fd" ]; then
  printf "%s\n%s\n" "/usr/share/OVMF/OVMF_CODE.fd" "/usr/share/OVMF/OVMF_VARS.fd"
elif [ -f "/usr/share/edk2/ovmf/x64/OVMF_CODE.fd" ]; then
  printf "%s\n%s\n" "/usr/share/edk2/ovmf/x64/OVMF_CODE.fd" "/usr/share/edk2/ovmf/x64/OVMF_VARS.fd"
fi
')
OVMF_CODE="${OVMF_INFO[0]}"
OVMF_VARS_TEMPLATE="${OVMF_INFO[1]}"
[ -n "$OVMF_CODE" ] || fail "OVMF_CODE.fd bulunamadi. Gerekli paketler: edk2-ovmf"
[ -n "$OVMF_VARS_TEMPLATE" ] || fail "OVMF_VARS.fd bulunamadi. Gerekli paketler: edk2-ovmf"

info "Flutter: $FLUTTER_BIN"
info "ISO: $ISO_FILE"
info "Profil: $PROFILE_SOURCE_PATH"
info "OVMF CODE: $OVMF_CODE"
info "OVMF VARS: $OVMF_VARS_TEMPLATE"
info "Calisma dizini: $RUN_DIR"
info "Guest log dizini: $HOST_VM_LOG_DIR"
info "QEMU display modu: $QEMU_DISPLAY_MODE"
info "QMP tus gecikmesi: ${QMP_KEY_DELAY_MS}ms"
info "Guest host paylasim mount noktasi: $HOST_MOUNT_IN_GUEST"

build_installer
prepare_vm_profile
prepare_disk
run_host cp "$OVMF_VARS_TEMPLATE" "$OVMF_VARS_COPY"

if [ "$MODE" = "manual" ]; then
  run_manual_mode
  exit 0
fi

if [ "$MODE" != "auto" ]; then
  fail "Gecersiz mod: $MODE (kullanim: ./test_qemu_vm.sh [auto|manual] [profil])"
fi

RUN_DIALOG_COMMAND="sudo mkdir -p $HOST_MOUNT_IN_GUEST; sudo mount -t 9p -o trans=virtio hostshare $HOST_MOUNT_IN_GUEST; sh $HOST_MOUNT_IN_GUEST/test_qemu_guest_runner.sh $HOST_MOUNT_IN_GUEST/$GENERATED_PROFILE_RELATIVE_PATH"

launch_auto_vm
select_live_boot_entry
send_guest_command "$RUN_DIALOG_COMMAND"

if monitor_auto_test; then
  info "Otomatik VM testi basarili."
  info "Seri log: $SERIAL_LOG"
  exit 0
fi

print_failure_context
exit 1
