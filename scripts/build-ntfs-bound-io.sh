#!/usr/bin/env bash
# Build the private per-child adapter; no global preload configuration.
set -euo pipefail
[[ $# == 1 && -n $1 ]] || { echo 'usage: build-ntfs-bound-io.sh OUTPUT' >&2; exit 2; }
source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
/usr/bin/clang -std=gnu11 -O2 -g -shared -fPIC \
  -D_FORTIFY_SOURCE=3 -fstack-protector-strong -fstack-clash-protection \
  -fcf-protection -fno-omit-frame-pointer -Wall -Wextra -Werror \
  -Wl,-z,defs,-z,relro,-z,now,-z,noexecstack,--as-needed \
  "${source_root}/linux/ro_installer_ntfs_bound_io.c" -o "$1" -ldl
