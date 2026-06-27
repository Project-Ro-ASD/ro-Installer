#!/bin/sh
set -eu

HOST_MOUNT="${HOST_MOUNT:-/run/ro-host}"
PROFILE_PATH="${1:-${RO_INSTALLER_VM_PROFILE:-$HOST_MOUNT/test/fixtures/profile_full_btrfs.json}}"
BINARY_PATH="${RO_INSTALLER_VM_BINARY:-$HOST_MOUNT/build/linux/x64/release/bundle/ro_installer}"
LOCAL_LOG_DIR="${RO_INSTALLER_LOCAL_LOG_DIR:-/tmp/ro-installer/logs}"
PROFILE_DIR="$(dirname "$PROFILE_PATH")"

if [ -n "${RO_INSTALLER_VM_LOG_DIR:-}" ]; then
  HOST_LOG_DIR="$RO_INSTALLER_VM_LOG_DIR"
else
  case "$PROFILE_DIR" in
    "$HOST_MOUNT"/outputs/vm/*)
      HOST_LOG_DIR="$PROFILE_DIR/guest-logs"
      ;;
    *)
      HOST_LOG_DIR="$HOST_MOUNT/outputs/vm-logs"
      ;;
  esac
fi

serial_marker() {
  if [ -w /dev/ttyS0 ]; then
    printf '%s\n' "$*" > /dev/ttyS0 2>/dev/null || true
  elif command -v sudo >/dev/null 2>&1; then
    printf '%s\n' "$*" | sudo -n tee /dev/ttyS0 >/dev/null 2>&1 || true
  fi
}

write_runner_state() {
  state="$1"
  tmp_state_file="$HOST_LOG_DIR/runner-state.txt.tmp"

  if ! mkdir -p "$HOST_LOG_DIR" 2>/dev/null; then
    return 0
  fi

  if {
    printf 'state=%s\n' "$state"
    date '+timestamp=%FT%T%z'
    printf 'profile=%s\n' "$PROFILE_PATH"
    printf 'binary=%s\n' "$BINARY_PATH"
  } 2>/dev/null > "$tmp_state_file"; then
    mv "$tmp_state_file" "$HOST_LOG_DIR/runner-state.txt" 2>/dev/null || true
  else
    rm -f "$tmp_state_file" 2>/dev/null || true
  fi
  : 2>/dev/null > "$HOST_LOG_DIR/runner-${state}" || true
}

mkdir -p "$LOCAL_LOG_DIR"
mkdir -p "$HOST_LOG_DIR" 2>/dev/null || true
write_runner_state "started"
serial_marker "RO_INSTALLER_GUEST_RUNNER_START"
cd "$HOST_MOUNT"

if [ ! -f "$PROFILE_PATH" ]; then
  write_runner_state "profile-missing"
  serial_marker "RO_INSTALLER_GUEST_RUNNER_PROFILE_MISSING path=$PROFILE_PATH"
  echo "[HATA] Profil bulunamadi: $PROFILE_PATH" >&2
  exit 1
fi

if [ ! -x "$BINARY_PATH" ]; then
  write_runner_state "binary-missing"
  serial_marker "RO_INSTALLER_GUEST_RUNNER_BINARY_MISSING path=$BINARY_PATH"
  echo "[HATA] Derlenmis binary bulunamadi: $BINARY_PATH" >&2
  exit 1
fi

write_runner_state "install-started"
serial_marker "RO_INSTALLER_GUEST_RUNNER_INSTALL_START profile=$PROFILE_PATH"
if sudo env \
  RO_INSTALLER_AUTO_PROFILE="$PROFILE_PATH" \
  RO_INSTALLER_AUTO_REBOOT="${RO_INSTALLER_AUTO_REBOOT:-1}" \
  RO_INSTALLER_VM_TEST_MODE="${RO_INSTALLER_VM_TEST_MODE:-1}" \
  RO_INSTALLER_LOG_DIR="$LOCAL_LOG_DIR" \
  RO_INSTALLER_EXTRA_KERNEL_ARGS="${RO_INSTALLER_EXTRA_KERNEL_ARGS:-}" \
  "$BINARY_PATH"; then
  status=0
else
  status=$?
fi
write_runner_state "install-exited-${status}"
serial_marker "RO_INSTALLER_GUEST_RUNNER_INSTALL_EXIT status=$status"

mkdir -p "$HOST_LOG_DIR" 2>/dev/null || true
find "$LOCAL_LOG_DIR" -maxdepth 1 -type f -exec cp "{}" "$HOST_LOG_DIR"/ \; 2>/dev/null || true
write_runner_state "logs-copied-${status}"
serial_marker "RO_INSTALLER_GUEST_RUNNER_LOG_COPY_DONE status=$status"

exit "$status"
