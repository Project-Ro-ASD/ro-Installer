#!/bin/sh
set -eu

# Ignore inherited PATH, including nonempty restricted QGA service values.
# An explicit harness override uses the same policy as the host command shell.
GUEST_COMMAND_PATH="${GUEST_COMMAND_PATH-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
case ":$GUEST_COMMAND_PATH" in
  :|*::*|*:|*:[!/]*)
    echo "GUEST_COMMAND_PATH must contain only nonempty absolute directories." >&2
    exit 1
    ;;
esac
PATH="$GUEST_COMMAND_PATH"
export PATH

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

# QGA's system service has no graphical-session environment. The Linux
# Flutter runner still initializes GTK in auto mode. Use the existing live
# Wayland socket without changing compositor permissions or ISO contents.
if [ "${RO_INSTALLER_VM_USE_LIVE_DISPLAY:-0}" = 1 ]; then
  display_timeout="${RO_INSTALLER_VM_DISPLAY_TIMEOUT_SECONDS:-120}"
  case "$display_timeout" in
    ''|*[!0-9]*) echo "Invalid live display timeout: $display_timeout" >&2; exit 1 ;;
  esac
  runtime_root="${RO_INSTALLER_VM_RUNTIME_ROOT:-/run/user}"
  waited=0
  while :; do
    display_socket=""
    for candidate in "$runtime_root"/*/wayland-*; do
      [ -S "$candidate" ] || continue
      if [ -n "$display_socket" ]; then
        write_runner_state "display-ambiguous"
        echo "Multiple live Wayland sockets found under $runtime_root" >&2
        exit 1
      fi
      display_socket="$candidate"
    done
    [ -z "$display_socket" ] || break
    if [ "$waited" -ge "$display_timeout" ]; then
      write_runner_state "display-not-ready"
      echo "Live Wayland display not ready within ${display_timeout}s under $runtime_root" >&2
      exit 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  XDG_RUNTIME_DIR="$(dirname "$display_socket")"
  WAYLAND_DISPLAY="$(basename "$display_socket")"
  GDK_BACKEND=wayland
  export XDG_RUNTIME_DIR WAYLAND_DISPLAY GDK_BACKEND
fi

write_runner_state "install-started"
serial_marker "RO_INSTALLER_GUEST_RUNNER_INSTALL_START profile=$PROFILE_PATH"
# QGA runs as root; interactive manual use retains the existing sudo path.
ROOT_PREFIX=""
if [ "$(id -u)" -ne 0 ]; then
  ROOT_PREFIX="sudo"
fi
if $ROOT_PREFIX env \
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
# Do not mark a partial or failed copy as successful.
if ! cp -a "$LOCAL_LOG_DIR"/. "$HOST_LOG_DIR"/; then
  write_runner_state "log-copy-failed-${status}"
  serial_marker "RO_INSTALLER_GUEST_RUNNER_LOG_COPY_FAILED status=$status"
  [ "$status" -ne 0 ] || status=1
  exit "$status"
fi
write_runner_state "logs-copied-${status}"
serial_marker "RO_INSTALLER_GUEST_RUNNER_LOG_COPY_DONE status=$status"

exit "$status"
