/// Package-neutral discovery shared by boot preparation and technical validation.
/// Output is one tab-separated version/image pair per complete prepared candidate.
const preparedKernelDiscoveryScript = r'''
discover_prepared_kernels() {
  versions="$(
    for kdir in /usr/lib/modules/* /lib/modules/*; do
      [ -d "$kdir" ] || continue
      printf '%s\n' "${kdir##*/}"
    done | LC_ALL=C sort -u
  )"
  found=0
  while IFS= read -r kver; do
    [ -n "$kver" ] || continue
    image=""
    for candidate in "/boot/vmlinuz-$kver" "/usr/lib/modules/$kver/vmlinuz" "/lib/modules/$kver/vmlinuz"; do
      if [ -f "$candidate" ] && [ -s "$candidate" ]; then
        image="$candidate"
        break
      fi
    done
    if [ -z "$image" ]; then
      echo "Skipping incomplete prepared kernel: $kver (no matching kernel image)" >&2
      continue
    fi
    printf '%s\t%s\n' "$kver" "$image"
    found=1
  done <<VERSIONS
$versions
VERSIONS
  if [ "$found" -ne 1 ]; then
    echo "No complete prepared kernel candidate found" >&2
    return 1
  fi
}
''';
