#!/bin/bash
# Preserve the graphical user's UID and complete desktop session environment.
set -eu
BINARY=/usr/bin/ro-installer
if [ ! -x "$BINARY" ]; then
    printf '%s\n' 'Ro-Installer executable is missing; reinstall the ro-installer RPM.' >&2
    exit 1
fi
exec "$BINARY" "$@"
