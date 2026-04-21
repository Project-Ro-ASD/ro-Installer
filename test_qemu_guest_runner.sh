#!/bin/sh
set -eu

HOST_MOUNT="${HOST_MOUNT:-/mnt/host}"
PROFILE_PATH="${1:-${RO_INSTALLER_VM_PROFILE:-$HOST_MOUNT/test/fixtures/profile_full_btrfs.json}}"
BINARY_PATH="${RO_INSTALLER_VM_BINARY:-$HOST_MOUNT/build/linux/x64/release/bundle/ro_installer}"
HOST_LOG_DIR="${RO_INSTALLER_VM_LOG_DIR:-$HOST_MOUNT/outputs/vm-logs}"
LOCAL_LOG_DIR="${RO_INSTALLER_LOCAL_LOG_DIR:-/tmp/ro-installer/logs}"

mkdir -p "$LOCAL_LOG_DIR"
mkdir -p "$HOST_LOG_DIR" 2>/dev/null || true
cd "$HOST_MOUNT"

if [ ! -f "$PROFILE_PATH" ]; then
  echo "[HATA] Profil bulunamadi: $PROFILE_PATH" >&2
  exit 1
fi

if [ ! -x "$BINARY_PATH" ]; then
  echo "[HATA] Derlenmis binary bulunamadi: $BINARY_PATH" >&2
  exit 1
fi

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

find "$LOCAL_LOG_DIR" -maxdepth 1 -type f -exec cp "{}" "$HOST_LOG_DIR"/ \; 2>/dev/null || true

exit "$status"
