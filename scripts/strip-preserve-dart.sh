#!/usr/bin/bash
set -euo pipefail

# dart compile exe appends its snapshot after the ELF image. Even stripping
# only .comment truncates that snapshot. Preserve this one packaged executable;
# every other ELF in the Flutter bundle still uses Fedora's normal strip tool.
if [[ -n "${RPM_BUILD_ROOT:-}" && "$RPM_BUILD_ROOT" != / ]]; then
  for argument in "$@"; do
    if [[ "$argument" == "$RPM_BUILD_ROOT/usr/libexec/ro-installer-backend" ||
          ( "$argument" == ./usr/libexec/ro-installer-backend && "$PWD" == "$RPM_BUILD_ROOT" ) ]]; then
      exit 0
    fi
  done
fi
exec /usr/bin/strip "$@"
