# Ro-Installer

Ro-Installer is the system installer for Ro-ASD, a Fedora KDE based Linux
distribution. It installs the prepared Ro-Compose filesystem onto a target disk
and validates the resulting system. Ro-Installer is not a distro builder.

## Release identity and integration readiness

The approved source version is `2.5.0+1`, producing
`ro-installer-2.5.0-1.fc44.x86_64.rpm` and
`ro-installer-2.5.0-1.fc44.src.rpm` in CI. It includes the merged P0-01 through
P0-05 reliability and acceptance work. This is source/release preparation;
`v2.5.0` has not been tagged or published by this change.

Published `v2.4.5` binds commit
`a402892ad5380bc7b26e4b66ce748d3a911b2446` and predates those P0 changes.
The new version avoids reusing its `2.4.5-1.fc44` identity for different source
content. Published tags, releases and artifacts stay immutable. CI artifacts
remain review fixtures; they do not authorize release or repository publication.

The released baseline includes PR #22–24 (privileged helper, user-session GUI and
fail-closed live/root topology checks) and PR #25, merged on 2026-10-09.
PR #25 target finalization removes the copied `/etc/plasma-setup-done` marker
and only the Live user's autologin keys in `/etc/plasmalogin.conf`. It preserves
other users, sections, session settings and KDE's temporary
`/etc/plasmalogin.conf.d/99-plasma-setup.conf`. Existing SDDM residue, Live user
and installer removal remain in place, along with the v1 firstboot seed and
metadata. The existing target-finalization fixtures execute the production
cleanup script against temporary files and cover idempotence and preservation.

Acceptance evidence has three separate levels:

1. Code checks: the complete Flutter suite, analysis, i18n and
   `scripts/check-stable.sh`, including the existing Plasma Setup regressions.
2. Fedora 44 package checks: build Flutter and the Dart backend, inspect RPM
   payload permissions, install the binary, run the invalid-protocol backend
   smoke test, match binary/SRPM identity, and generate/check the manifest and
   `SHA256SUMS`. PR artifacts are verification fixtures, not published releases
   or release attestations.
3. Compose ISO GUI/firstboot acceptance: still required in the subsequent
   Ro-image-compose stage. Green package CI does not prove Plasma Setup runs on
   a physical computer. No ISO build or QEMU install is required for this PR.

Pubspec, spec defaults and both displayed UI versions are aligned to 2.5.0.
After review and separate operator approval of publication, freeze the accepted
source commit and recheck that `v2.5.0` remains unused. Source-version approval
alone does not authorize merge, tag creation or publication. Do not recreate or
move `v2.4.5`. A future approved `v2.5.0` tag triggers
`.github/workflows/release.yml`, which builds the exact RPM/SRPM pair, binds the
manifest to the real release ID and run, attests both RPMs, `SHA256SUMS` and
`component-artifact-manifest-v1.json`, and verifies the four immutable assets.
The workflow publishes automatically after its checks; pushing the tag is the
publication action and requires operator approval. Verify that workflow's
attestations and exact asset digests before Ro-Repo V2 admission. Never reuse
an existing version or substitute PR fixture metadata for release provenance.

Integration requires admission of the exact approved release artifact into
Ro-Repo, a signed immutable snapshot and an ISO input pinned to that snapshot's
digest and exact NEVRA. A newer Installer checkout cannot update an older ISO.
Before physical acceptance, verify the installed Live RPM against that chain
and record namespace acceptance separately. Local namespace PASS does not turn
CI UNAVAILABLE or an untested ISO/firstboot chain into acceptance.

## Architecture and Ownership

Ro-Installer owns:

- Target disk discovery and safety, partitioning, formatting, and mounting.
- Deployment of the prepared Ro-Compose filesystem.
- Narrow target finalization, bootloader setup, and technical post-install
  validation.
- Cleanup and a minimal firstboot handoff.
- Automated profile-based installation and QEMU test support.

Ro-Compose owns image composition and supplies the supported baseline kernel.
Ro-ASD Initial Setup / Plasma Setup owns first-user configuration and first-boot
OOBE: final user accounts, passwords, hostname, locale, timezone, keyboard, and
theme configuration. Ro-Assist will own future kernel-management UX and Btrfs
recovery/snapshot management.

Ro-Installer does not own general ISO composition/remixing, runtime Internet
dependency, runtime DNF package installation as product policy, repository
creation/wiring, COPR configuration, distro identity rewriting, kernel
selection/channel policy, or replacing Fedora kernels with custom kernels.

## Standard Storage Contract

The production GUI supports full-disk installation and create-only installation
inside an existing GPT free extent. `GptDiskSnapshot` and
`FreeSpaceInstallationPlan` provide deterministic planning; helper v2 probes
authoritative metadata and revalidates the approved extent before mutation.
The models validate normalized sector geometry, primary/backup entry-array
reservations, partition identities, overlap and GPT slot capacity. Plans bind
the device sequence, table fingerprint and partition inventory to one complete
current free extent. The normalized input is not a disk probe or authorization.

The proposed layout creates a dedicated 512 MiB ESP and Btrfs root inside that
extent, keeping existing partitions and their EFI files separate. It uses no
disk swap, shrinking, wiping or shared-ESP formatting. Allocation uses integer
sector arithmetic and 1 MiB alignment; the existing temporary root-space safety
floor applies. The legacy free-space executor is replaced by this verified
create-only path; root-auto profiles remain full-disk only.

### Read-only free-space admission (helper v2)

`probe-free-space` accepts only `{protocolVersion:2, operation, disk}` and returns
a typed `snapshot`. `validate-free-space-plan` accepts the disk, `expectedDevice`,
`tableFingerprint` and `selectedExtent: {startSector, endSector}` and returns a
recomputed compact `plan`. Both use the existing root authorization, topology
guards and installer lease; validation reads fresh metadata instead of trusting
caller-supplied inventory or partition operations. V1 rejects both operations.

The isolated `ro_installer_gpt.py` worker opens only the validated block device
read-only, checks its descriptor identity/geometry/disk sequence, and verifies
the protective MBR, both GPT headers, entry-array CRCs and matching table copies
against the [UEFI GPT format](https://uefi.org/specs/UEFI/2.11/05_GUID_Partition_Table_Format.html).
It reserves at least 16 KiB for each entry array, reads metadata twice, and
compares partition numbers and byte geometry with kernel sysfs data. Hybrid,
damaged, stale or unsupported tables are rejected; no repair path exists.

The SHA-256 fingerprint uses the `ro-gpt-snapshot-v1` domain, disk size/sector
size/array LBAs and length-prefixed PMBR, primary header, primary reserved array,
backup reserved array and backup header bytes. Names remain inside this digest;
raw partition names never enter public output. The compact intent contains only
device/table identity, selected extent and the independently computed ESP/root
numbers and ranges.

Probe limits are 512/4096-byte sectors, 4096 entries of at most 1024 bytes, up to
32 occupied partitions and a 7168-byte snapshot. The worker has a ten-second
deadline and bounded combined output; exceeding a bound fails rather than
truncating inventory. Its root-owned package payload is checked alongside the
helper. A validated proposal alone is not a write authorization.

### Create-only free-space installation (GUI/helper v2)

The GUI scans the selected disk, lists eligible extents and confirms a dedicated
512 MiB FAT32 ESP plus Btrfs root. Selection changes invalidate both the proposal
and confirmation; delayed scans and dialogs cannot approve a superseded choice.
`install-free-space` requires `disk`, `expectedDevice`, `confirmDestructive: true`
and the compact `confirmedPlan`; optional `uiLanguage` and `includeCopyProgress`
retain their existing contracts. Public requests cannot supply source inventory,
partition GUIDs, preservation proofs, commands or partition-path overrides. V1
rejects this operation.

Under the installer lease, the helper recomputes the intent from fresh GPT data,
allocates unique partition GUIDs and binds a private approval to the backend's
ready/continue gate. `sfdisk --append` adds exactly the planned two entries with
signature wiping disabled. After kernel rescan, both GPT copies and sysfs must
identify the new partitions exactly. A separate SHA-256 preservation proof masks
only those two owned entries and the header/entry-array CRC fields; every other
metadata byte must remain unchanged. Existing partition identities, ranges,
attributes and hashed names remain protected.

Only the verified new devices enter formatting, mount ownership, fstab,
bootloader and final validation. GPT identity and preservation are checked again
before each format and mounting. A mismatch stops execution; there is no automatic
GPT restore or retry after partial creation. Existing EFI filesystems are not
mounted or reused. This mode disables GRUB os-prober to avoid scanning existing
systems; their firmware entries remain the route to those systems.

Execution accepts at most 30 existing partitions, leaving room for the two new
entries within the probe limit. The complete private backend frame must fit
8192 bytes; oversized inventories fail before backend launch. Damaged, hybrid or
unsupported layouts are rejected rather than repaired. Full-disk behavior and
its older protocol compatibility remain unchanged.

### Manual storage planning

`ManualInstallationPlan` is a pure, immutable planning model used by helper v2
and the installation engine. The GUI editor selects these typed roles. Legacy
`manualPartitions` maps cannot authorize execution. Read-only validation and
installation admission are separate operations.

Its versioned input contains one normalized GPT `snapshot` and exactly two
choices: `esp` and `root`. Existing choices specify a partition number and an
explicit boolean `formatOnInstall`; new choices specify integer `startSector`
and `endSector`. See `test/fixtures/manual_installation_plan_v1.json`. Paths,
GUIDs, flags, filesystem claims and operations cannot be overridden by a choice.
The compact intent binds the complete source fingerprint, device identity,
resolved role geometry and preserve/format decision to the standard Btrfs layout.

Root always requires formatting, a Linux data partition type and the temporary
40 GiB safety floor. ESP requires the ESP type and at least 512 MiB; existing ESPs
may explicitly be formatted or reused. Selected existing partitions must have
zero GPT attributes. These conservative planning limits do not prove filesystem
type, available EFI space or safe reuse. ESP reuse preserves the filesystem but
allows later boot-file writes; only unselected partitions are classified as
untouched.

New partitions must lie entirely within current free extents, align to 1 MiB,
remain disjoint and fit unused GPT slots. Slots are assigned deterministically
with ESP first; the post-create inventory must fit the 32-partition probe limit.
There is no delete, resize, root-preservation, separate-home or disk-swap plan.

### Confirmed full-disk device readiness

After partition creation, confirmed full-disk installs run the existing
`partprobe` and `udevadm settle` steps, then verify readiness instead of sleeping
unconditionally. The isolated GPT reader checks both GPT copies, device identity
and kernel partition geometry. The engine requires exactly the approved EFI/root
roles, types, attributes, capacity and writer-specific boundaries. `sgdisk` uses
the last usable sector; the `parted` fallback ends at the preceding MiB boundary.

Transient probe failures receive bounded retries and command timeouts. A readable
wrong layout, changed device, expired retry window or revoked approval stops the
stage before formatting. Target identity is checked before the probe and again
before acceptance. This replaces the fixed two-second delay for confirmed full
installs; legacy full and other storage modes retain their existing readiness
paths. Hardware performance gains require separate measurement.

### Create-only free-space readiness

After create-only free-space partitioning, readiness uses the exact GPT/kernel
inventory and preservation proof instead of an unconditional two-second delay.
A ready disk proceeds immediately; unsuccessful worker reads receive bounded
retries, while readable wrong identities, geometry or metadata fail immediately.
Whole-device identity and the captured approval are rechecked before accepting
the layout. Formatting retains its separate fresh-layout checks.

### NTFS shrink planning

`NtfsShrinkInstallationPlan` is a pure proposal for a future alongside path.
It keeps the original immutable GPT snapshot and records expected geometry
separately, rather than presenting changed geometry with an old fingerprint.
The proposal binds one Microsoft basic-data source, an existing reusable ESP,
and one newly allocated Btrfs root slot. Only the source end may move; recovery
and other partitions keep their positions. A contiguous following gap can reduce
the required shrink. Any MiB-aligned free extent large enough for the requested
root rejects shrink as unnecessary, including gaps elsewhere on the disk.
The Python `ntfs_shrink_plan` independently reconstructs the same intent from a
normalized snapshot. Shared fixtures check both implementations against fixed
geometry and rejection cases, including 512-byte and 4096-byte sectors.

New root ranges align to MiB boundaries and retain the temporary 40 GiB root
floor. The source must retain at least 40 GiB and at least 1 GiB above the supplied
filesystem minimum. These are conservative planning limits, not Windows minimum
requirements or evidence that resizing is safe. The supplied minimum is an
untrusted planning input until independently reproduced by privileged inspection.
GPT partition type alone does not establish NTFS, clean state, lack of encryption
or safe Windows shutdown.

The model performs no disk or filesystem IO and grants no execution authority.
Alongside installation remains rejected by the engine/helper. Restricted metadata
proofs, resize failure handling and GUI confirmation require separate integration.

The helper v2 `assess-ntfs-shrink` operation accepts only the selected disk
identity, observed GPT fingerprint, source/ESP numbers and requested root size.
Under the installation lease it rebuilds the geometry, opens the exact source
partition read-only/exclusively, checks its sysfs/FD identity and sector size,
and runs the bounded private reader with that descriptor. Device/GPT and source
identity are checked again before returning the computed intent and inspection.
The caller cannot supply a filesystem minimum, descriptor or execution plan.
Worker children inherit the lease; the process group is stopped before its
leader is reaped. The response is assessment data, not permission to resize or
a filesystem eligibility check for the ESP. `HelperClient.assessNtfsShrink`
reconstructs the Dart plan from the returned minimum and rejects a response that
does not match the selected snapshot and exact intent.

For future writer integration, `verified_ntfs_snapshot` computes a distinct raw
GPT preservation proof that masks only the selected source's eight-byte end
field, one new root entry and the dependent CRCs. Names, source identity/start,
other entries, PMBR and reserved-array padding stay protected. The separate
`verify_ntfs_created_layout` check requires the exact planned source end, root
geometry and allocated GUID as well as an unchanged proof. These are pure
verification primitives; they do not add a worker CLI or enable installation.

The private `ntfs_gpt_update_plan` reconstructs immutable byte patches from a
fresh, double-read snapshot and preservation proof. It changes only the source
end, the allocated root entry and their CRCs, keeping each copy's reserved bytes.
An in-memory overlay must pass the existing complete GPT and exact-layout checks;
a final source read rejects drift during planning. Patches are grouped backup
first, primary second. A future applier must durably flush the backup group before
touching the primary and verify the completed table. Planning performs no writes
and supplies neither atomicity nor filesystem resize authority.

### Read-only NTFS inspection primitive

The root-only `ro_installer_ntfs.py` worker accepts an inherited read-only block
FD, size and sector size. It verifies NTFS/backup boot geometry and a distinct
low-level NTFS signature, opens metadata with the packaged libntfs-3g ABI 89 in
read-only forensic mode, and explicitly checks clean NTFS 3.1 volume information,
hibernation state and the journal. A bounded root-directory scan uses the on-volume
`$UpCase` mapping, rejects ambiguous hibernation names and requires existing
hibernation headers to be entirely zero. Cached or unsupported journal versions
are rejected.

A fixed `ntfsresize --info --no-action -P` invocation provides the estimated
minimum. Bounded output, tool deadlines and process resource limits constrain
inspection, and core dumps are disabled. Metadata is checked again after the estimate. Only numeric geometry,
minimum size and an inspection fingerprint leave the worker; raw labels, UUIDs,
paths and diagnostics do not. The fingerprint covers the inspected fields, not
all filesystem data. The fixed metadata flags follow the
[exported volume API](https://github.com/tuxera/ntfs-3g/blob/edge/include/ntfs-3g/volume.h).

The packaged worker is mode 0644; the helper assessment binds its source FD and
installation lease. Assessment does not grant resize authority. Private ownership
proofs, a target-size dry run, writer validation and failure handling remain
required before alongside execution can be enabled.

A separate private `inspect_resized_fd` primitive validates a completed resize
before any future GPT update. It binds protected boot fields to the captured
original record, requires the exact decimal target geometry and matching backup
at the target end, and checks MFT/Mirror bounds. It accepts exactly the
resize-produced dirty bit while retaining the hibernation and journal checks.
Its allocation probe uses `--info --no-action --force` only after that post-state
check; initial eligibility still uses the strict clean-state path without force.
Native volume open must also reject mismatched `$MFT`/`$MFTMirr` records before
allocation probing; regressions exercise this with otherwise valid boot geometry
and update-sequence fixups in both initial and post-resize inspection.
Metadata and boot records must remain stable across inspection. This primitive
has no CLI mode or write authority; dependency qualification and writer/failure
integration are still required.

A private `prepare_resize_target` primitive now binds an exact MiB-aligned
shrink target to a fresh inspection, keeps the 40 GiB retained-source floor and 1 GiB
headroom above the observed minimum, and requires a successful fixed
`ntfsresize --no-action -P --size` trial. Geometry, boot/metadata, the inspection
fingerprint and the toolchain are checked again before returning preparation
evidence. No CLI or helper operation exposes this primitive.

Preparation requires `ntfsresize` and both owning Fedora x86_64 packages
(`ntfsprogs`, `ntfs-3g-libs`) to agree on release, epoch and build revision,
with a calendar release of at least
[2026.9.28](https://github.com/tuxera/ntfs-3g/releases/tag/2026.9.28).
Unknown, older or mismatched packages fail closed; this is a compatibility gate,
not executable integrity attestation. Existing read-only assessment remains
available with its current dependencies. Future write admission must regenerate
preparation under the caller's exclusive device/lease checks and still requires
a validated write boundary, post-checks and failure handling.

The private target trial uses a per-child, root-owned native descriptor adapter.
A fixed nonnumeric procfd alias duplicates the inherited open file description
with close-on-exec and exact access mode; destructive flags and unsupported
file types fail. Ignoring or losing the adapter leaves an unopenable alias,
with no device-path fallback. Other tool invocations keep their existing
read-only behavior. The shared object is built with one hardened recipe used
by both RPM packaging and native regressions; the worker and payload audit
check its ownership, mode and ELF type. It is never configured as a global preload.
This adapter does not grant write authority or complete alongside installation.

### Read-only manual validation (helper v2)

`validate-manual-plan` accepts `disk`, `expectedDevice`, `tableFingerprint` and
the two minimal `esp`/`root` choices. It recomputes the compact intent from fresh
GPT data under the installer lease. No inventory, commands, partition paths or
write authorization are accepted; v1 rejects the operation. The client requires
an exact match to its independently computed intent.

A separate isolated `ro_installer_manual.py` worker checks existing role devices
through read-only, no-follow, exclusive descriptors. Kernel partition number,
geometry, device identity and disk sequence must match before and after probing.
The fixed `blkid -p -o export` child receives the verified descriptor through
`/proc/self/fd`, inherits the installer lease, and has a two-second deadline and
4096-byte combined output cap. Only unambiguous FAT32 ESPs and Btrfs/ext4/XFS
root filesystems are eligible; encrypted, RAID/LVM, missing and ambiguous
signatures fail closed. Newly planned partitions need no existing filesystem.
Raw labels, UUIDs and probe diagnostics remain inside the worker.

Both GPT copies and kernel geometry are reprobed after filesystem checks, and
the helper rechecks the whole device before returning. The GPT reader retains
its no-subprocess contract. Both workers are root-owned, mode 0644 package
payloads. This read-only result is not approval to format or reuse an ESP. Installation
admission additionally checks filesystem safety, available space, boot-file
collisions and ownership, then revalidates at the first-mutation gate.

### Private manual target ownership

`ApprovedManualPlan` defines the private helper-to-backend ownership envelope:
source snapshot, exact compact intent, helper-allocated GUIDs for new roles only,
and a preservation fingerprint. Existing role identities cannot be reassigned;
new GUIDs must be distinct from every existing partition and the disk GUID.
A captured approval rejects state-copy deletion, mode changes and replacement
with a different valid plan.

Manual layouts may add zero, one or two partitions. The private manual worker's
`--layout` read mode masks only the corresponding new GPT entries plus the
header/entry-array CRC fields when computing the preservation proof. Every
existing entry remains protected, including a root selected for filesystem
formatting. The original GPT worker's public two-slot flag remains unchanged.

`CreatedManualLayout` resolves root/ESP paths only after exact post-create
inventory, range, type, GUID, attributes and preservation checks. Public helper
requests cannot supply this private ownership envelope; installation admission
constructs it from fresh observations under the installer lease.

### Protected reusable ESP mounts

The internal mount session can inspect a reusable ESP read-only, bound to the
exact private manual approval. Source EFI files are traversed without following
links, with byte/count/depth limits and case-collision checks. The fixed worker
returns only numeric allocation estimates and available space from the verified
mount descriptor. Cluster rounding, directory growth and operational headroom
are reserved; unsupported source entries and insufficient space fail closed.

After resolved manual targets are bound, reused ESPs cannot use the ordinary
writable mount path. Preparation reserves a new `EFI/fedora` directory only if
that namespace does not exist, binds the ESP read-only at `/mnt/boot/efi`, and
leaves only that new subtree writable. The temporary full writable staging mount
must disappear before protection is considered ready. Capacity and collision
checks run again before namespace creation. Existing `EFI/fedora` content is
rejected rather than taken over.

Mount ownership includes per-mount flags, device, root subtree and mount ID.
The read-only bind explicitly retains `nosuid,nodev,noexec`; Linux distinguishes
these [per-mount flags from filesystem-wide flags](https://man7.org/linux/man-pages/man2/mount.2.html).
Partial failures remain tracked for cleanup. Wrong subtrees, unexpected flag or
namespace changes, foreign mounts and busy resources cannot produce success.
The original full/free-space mount allowlists remain separate.

The manual executor copies only the new `EFI/fedora` subtree when reusing an
ESP. Kernel installation uses `--boot-path=/boot`, with boot entries inside the
new root filesystem; protected mounts are checked before boot work and final
validation. Writes outside the owned ESP subtree fail. Installed-system update
policy is separate from this installation-time mount protection.

### Manual installation (helper v2)

`install-manual` requires `disk`, `expectedDevice`, `confirmDestructive: true`
and the exact compact `confirmedPlan`. Optional language and copy-progress
fields follow the existing v2 install contract. Helper v1 rejects this operation.
The helper independently recomputes the intent, checks reusable FAT32 with
read-only `fsck.fat -n` and an unambiguous UUID lookup, and rejects existing
Btrfs roots with unsupported multi-device or seeding superblocks. New GUIDs
are allocated only for new roles. The private ready/continue exchange binds
the complete approval to fresh device, filesystem and GPT observations.

Execution appends only the zero, one or two approved new partitions. Existing
GPT entries are preserved and each format requires a fresh ownership check.
Root is always formatted as Btrfs; an existing ESP is formatted only when
explicitly selected, otherwise its new boot namespace uses protected mounts.
Source EFI capacity is checked before mutation, including for formatted ESPs.
There is no delete, shrink, filesystem-preserving root reuse, separate-home or
disk-swap execution path. A failed append is reported without attempting a
whole-table rollback. The legacy manual-map executor has been removed.

The GUI reads a fresh GPT inventory and lets the user select existing EFI/root
partitions or specify aligned new ranges in a listed free extent, using integer
MiB offsets and sizes. Existing ESPs default to reuse; formatting is an explicit
choice. The helper validates the typed proposal before the confirmation dialog.
The dialog identifies both targets, sizes and create/format/reuse actions, and
warns about root data loss and the selected EFI policy. Changing the disk, mode,
range or format choice invalidates approval, including an already open dialog.
Installation sends the same compact intent through helper v2 and requires its
terminal installed-success result.

The standard automatic Ro-ASD profile is x86_64, UEFI, GPT, and Btrfs, with ZRAM
and no dedicated disk swap partition. The standard rollback-aware Btrfs layout is:

| Subvolume | Mount point |
| --- | --- |
| `root` | `/` |
| `home` | `/home` |
| `var_log` | `/var/log` |
| `var_cache` | `/var/cache` |
| `var_tmp` | `/var/tmp` |

For each complete prepared kernel, the installer regenerates its initramfs and
passes that exact nonempty, readable regular file to `kernel-install add`.
Fedora's packaged dracut plugin then skips duplicate generation. The pre-dracut
and post-plugin `depmod` calls retain their narrow `0022` masks; other work keeps
the inherited restrictive mask. Missing, empty or symlink initramfs output stops
boot preparation before plugins run. A real-package plugin regression checks
this reuse behavior alongside the I01 kernel-index tests.

`/boot` belongs inside the root Btrfs snapshot scope. The ESP remains FAT32 and
is mounted at `/boot/efi`.

Full-disk erase and create-only free-space installation have GUI flows. Manual
installation has a typed GUI and helper v2 execution contract. Alongside
shrink, replace-existing-OS, reinstall-preserve-home and LUKS remain future
milestones. Manual installation may later support ext4/XFS targets; these
filesystems are valid for reliable normal Ro-ASD operation, but Ro-ASD must not
promise Btrfs snapshot/rollback/recovery features on them.

File-copy acceptance requires exit 0 for the main rsync and every EFI mkdir/rsync.
Partial-transfer exit 23 and other failures stop stage 5 before finalization or
bootloader stages. Nonempty systemd/os-release and Fedora shim/GRUB files are
checked in both source and destination; this is a small required-file guard,
not a full image manifest or post-reboot integrity proof. Copy errors contain
fixed operation/path messages, without forwarding raw rsync filenames/stderr.

The prepared KIWI/Fedora root contains `/boot` and `/boot/efi`; it is copied
with the existing `-aAX --numeric-ids` options. A valid `findmnt` JSON snapshot
is mandatory outside simulation. Foreign mounts are excluded literally
(including spaces and glob characters); mounted system source directories
without provenance fail closed. Only the prepared `/boot/efi` directory gets
the secondary `-aA --numeric-ids --no-xattrs` copy. Arbitrary FAT/NTFS mounts
are never extra sources. Live runtime/cache trees and `/home/liveuser` are
excluded; Initial Setup and account cleanup keep their existing contract.
No `--one-file-system`, `-H`, or `-S` policy is added: hardlink identity is not
preserved and sparse allocation is not guaranteed. Copy fixtures use real
rsync and ACL tools (`rsync`, `acl` on Fedora) on disposable directories.
They do not mount images or certify FAT32/SELinux/power-loss behavior;
privileged UID/GID and device-node coverage is reported per environment.

## Implementation Status

The current installation contract uses full-disk Btrfs deployment, narrow target
finalization, package-neutral prepared-kernel boot setup, technical validation,
and the v1 firstboot handoff. Repository, kernel composition, application, theme,
and distro branding policy belong to Ro-Compose.

Installer-owned ISO production, static ISO composition audit, and ISO payload
extraction benchmarking have been removed. Compose now provides the
`installer-test-iso` target and an external integration ISO for Installer E2E.
The canonical installed product profile is `desktop-standard`, with `live-iso`
and `installer-test-iso` as Compose targets. Full install/reboot E2E acceptance
remains in progress until a real run reaches `RO_INSTALLER_VM_BOOT_OK`.

Destructive disk operations remain guarded by storage planning and validation.
The current stable path rejects LUKS, LVM, RAID, multipath, and nested storage
topologies before destructive disk writes.

## User-session GUI and Privileged Installation (PR-A2)

The desktop launcher starts `/usr/bin/ro-installer` as the current graphical
user without changing UID, Wayland/X11, XDG_RUNTIME_DIR or theme environment.
Interactive main never reexecutes the GUI as root. `CommandRunner` executes
commands directly; `RO_INSTALLER_COMMAND_SUDO` has no effect. Normal `lsblk`,
`uname`, EFI checks and `nmcli` queries need no helper authorization. Explicit
root automatic-profile/QEMU execution remains separate and uses the existing
engine through the same isolated session; its root check ignores UID environment variables.

The interactive privilege boundary is now:

```text
user GUI → /usr/bin/pkexec --disable-internal-agent
         /usr/libexec/ro-installer-helper --protocol=1
         → /usr/libexec/ro-installer-session --backend
         → /usr/libexec/ro-installer-backend --privileged-backend-v1
         → existing Dart InstallService and its nine stages
```

The same RPM owns the isolated Python helper and the compiled, non-GUI Dart
backend and session supervisor, all root:root 0755. The backend is built with `dart compile exe`;
partitioning/install logic remains in the existing Dart stages. Only the
helper-specific `org.roasd.installer.helper` polkit action remains, bound to
exactly `/usr/libexec/ro-installer-helper`, with defaults no/no/auth_admin.
There is no retained authorization, root-GUI policy, sudoers or live-only allow
rule. A future active/local liveuser rule belongs to Ro-image-compose.

P0-03 gives GUI and root-auto the same persistent kernel installation lock and
root session supervisor. Before any engine child it creates a new mount namespace,
marks propagation recursively private and verifies it; failure has no host fallback.
Only the exact root engine PID may use the private internal command socket. Every
command child inherits the same lock description; surviving descendants are drained
before the lease is released. The GUI helper request schema and polkit action stay
unchanged. Root-auto preserves existing profile/test/display options; a custom VM
binary can continue only when it is the exact inode of the already-running root
parent executable. Active target disks are rejected on both paths, without global
swapoff or force-unmounting user resources.

After namespace setup, the root session acquires a blocking logind inhibitor for
sleep and shutdown through the fixed system-bus socket. It owns a close-on-exec
copy of the returned descriptor through engine execution and owned-child cleanup,
then releases it before an optional successful-install reboot. Acquisition has a
bounded method deadline; failure prevents engine startup and is recorded as
`POWER_INHIBIT_FAILED`. GUI and root-auto share this behavior. The inhibitor
covers ordinary power-management requests; it cannot prevent forced power loss.
Native descriptor-ownership regressions use a private D-Bus and synthetic replies.

Before stage 1, read-only preflight checks source topology and required EFI/system
files, runtime tools, target capacity and the existing
`/usr/lib/ro-asd/release.json` Ro-ASD/Fedora 44 x86_64 metadata contract. This is
compatibility validation, not cryptographic source attestation. No new Compose
marker is required. A bounded read-only rsync inventory uses the same source
filters as copying and measures total logical file bytes and entry count, even
when destination files already exist. The selected root range must fit that
source plus a 20% growth reserve, 16 KiB per entry and 2 GiB operational headroom,
rounded up to MiB. Full-disk planning also reserves its ESP and alignment space;
free-space and manual planning use the captured root partition, not whole-disk
capacity. The temporary 40 GiB floor still applies. This conservative budget
does not credit compression or guarantee later source growth will fit, and the
inventory adds a source scan with a deadline. Device identity and empty target inventory are
rechecked before the first mutation, retaining the helper ready/continue handshake. The
fixed runtime-tool catalogue is checked by one shell invocation using positional
arguments and `command -v`; tool discovery never executes the discovered tools.
Its aggregate timing uses `preflight.tools`, while historical per-tool timing IDs
remain accepted when reading older session records.

A typed mount session records only validated resources it creates, including
partial rbind results. Foreign `/mnt` mounts, replaced IDs, changed namespaces and
symlink mount targets cause refusal. Cleanup checks ownership, removes individual
owned leaf mounts and verifies the final inventory. No recursive, lazy or forced
unmount is used. Primary and cleanup errors stay separate; any cleanup failure
prevents success. GUI terminal state depends on the validated helper result, never
on 100% progress. Export failure cannot change the result on either entry path.
Namespace isolation does not roll back formatting or file content, isolate swap,
or protect against malicious root processes, power loss or SIGKILL.

Run `python3 -B test/scripts/namespace_acceptance.py` separately from fake tests.
It uses only a fresh `/tmp` tree inside disposable user/mount namespaces, exercises
the production namespace primitive, real nested rbind and individual cleanup, and
checks that the parent mount inventory stayed unchanged. Exit 77 explicitly means
UNAVAILABLE and full security acceptance **NO-GO**; it is never a passing isolation
test. Fedora PR CI preserves the JSON and warns when kernel capabilities prevent
this probe. Synthetic Dart mount graphs, real IPC/flock/child-lifetime fixtures and
this Linux probe provide distinct evidence; none is a physical installation test.

RPM stripping preserves only `/usr/libexec/ro-installer-backend`, because Dart
appends its AOT snapshot after the ELF image and strip would truncate it. Other
bundle ELF files retain normal Fedora processing. A real RPM fixture verifies
the snapshot bytes, and Fedora 44 CI executes the installed backend with an
invalid protocol request that exits before any disk operation.

### Disk discovery and confirmation

`DiskDiscoveryResult` distinguishes successful empty discovery, command start
failure, nonzero exit, timeout, incompatible JSON and topology/parsing failure.
Enumeration has a ten-second timeout. Blank virtio disks with null/empty MODEL,
boolean RM, `[null]` mountpoints, and absent/empty children are supported.
Malformed independent entries are excluded with a visible warning while valid
disks remain. Null children is not assumed to prove a blank disk. Ambiguous
identities fail the entire discovery. The UI never displays stderr or exception
text as a disk-discovery message and clears stale selection/confirmation on
refresh.

Only after selecting a disk does the GUI request an authorized `probe-disk`.
The destructive confirmation displays the authoritative path/size and retains
`{path,majorMinor,size,diskSequence}`. Installation sends that exact identity;
GUI metadata cannot override it. Authorization cancellation (126), denial (127),
missing pkexec, protocol failure and helper errors are distinct client errors.
There is no sudo or root-GUI fallback.

### Helper protocol v1

stdin is exactly one UTF-8 JSON object, at most 16 KiB, closed within five
seconds. Only no arguments or `--protocol=1` are supported. Every shown field is
required; additional/duplicate fields, unknown versions/operations, non-finite
numbers and malformed JSON are rejected. Each example is a separate invocation:

```json
{"protocolVersion":1,"operation":"audit-live"}
```

```json
{"protocolVersion":1,"operation":"probe-disk","disk":"/dev/vda"}
```

```json
{"protocolVersion":1,"operation":"install-full-disk","disk":"/dev/vda","partitionMethod":"full","fileSystem":"btrfs","confirmDestructive":true,"expectedDevice":{"majorMinor":"252:0","size":68719476736,"diskSequence":11}}
```

Replace the example identity with the actual probe. Size is bytes and diskSequence
is the kernel device generation. Only canonical /dev names are accepted. There
are no command/argv/environment/source/destination/chroot/profile/test-mode fields.
Root authority comes from effective UID, never environment variables.

Stdout is NDJSON. Audit/probe emit one `type:result` envelope with
`{protocolVersion, type, operation, ok}` plus respectively `audit` or `device`.
Audit reports runtime facts and `installationImplemented:true`; it does not
certify live-image provenance. Install emits bounded progress followed by exactly
one result. A successful final result requires explicit backend success and a
zero backend exit; EOF/crash/malformed output can never imply success:

```json
{"protocolVersion":1,"type":"progress","stage":2,"progress":0.2,"messageKey":"install_stage_partitioning"}
{"protocolVersion":1,"type":"result","operation":"install-full-disk","ok":true,"installed":true}
```

Errors have `ok:false,error:{code,message}` with constant messages. Stage is
0–9; messageKey must match the fixed stage-key table in `helper_protocol.dart`.
Progress is finite and within 0–1. Heartbeats repeat current progress every five
seconds during long commands; no raw command output is forwarded. Messages are
at most 8 KiB; each stream is limited to 4 MiB / 16,384 messages. Backend/authorization
stderr is discarded with a 64 KiB cap. Client probe requests have a two-minute
conversation timeout; disk enumeration's timeout is separate.

| Exit | Meaning / structured codes |
| --- | --- |
| 0 | Successful audit, probe or complete installation |
| 2 | INVALID_REQUEST, REQUEST_TOO_LARGE, REQUEST_TIMEOUT |
| 3 | ROOT_REQUIRED |
| 4 | DEVICE_NOT_FOUND, NOT_BLOCK_DEVICE, UNSAFE_DEVICE, AMBIGUOUS_TOPOLOGY, DEVICE_CHANGED, UNSUPPORTED_PLATFORM |
| 5 | BUSY, UNSAFE_LOCK |
| 7 | SYSTEM_ERROR |
| 8 | INSTALL_FAILED |
| 9 | BACKEND_ERROR |

### Confirmed full-disk plan (GUI v2)

The production GUI snapshots the freshly probed disk identity and the fixed
full-disk/Btrfs plan before displaying the destructive confirmation. The dialog
shows that all data will be erased, with a 512 MiB FAT32 ESP, Btrfs in the
remaining space and no disk swap. Disk selection/configuration changes and
back navigation invalidate the approval; selection revisions also reject a
dialog whose disk was changed away and back while it was open. Language changes
do not alter disk approval. Production GUI v2 refuses identity-only confirmation.

Its install request includes `confirmedPlan` (schema version 1). The exact
data-only shape is demonstrated in
`test/fixtures/approved_full_disk_plan_v1.json`: disk path/major-minor/size/disk
sequence, GPT/ESP/filesystem/layout/subvolume contract, and the five fixed
destructive storage operations. Both helper and backend recompute and strictly
compare the supported plan, including nested JSON types, unknown fields and
operation order. The ready/continue exchange echoes that same plan alongside
the existing disk identity gate under the installation lock. No GUI-supplied
command, partition path override or arbitrary operation is accepted.

The engine retains a separate typed approval; deleting or replacing its state
copy cannot downgrade execution to the legacy path. It checks the approval
before the first mutation and rechecks the partitioning/formatting stages.
Rsync, partition geometry, format argv, mount ownership and cleanup contracts
are unchanged. This binds the supported full-disk intent, not a snapshot of
the disk's existing partition contents. Manual/alongside approval requires a separate plan design; free-space approval
uses the independent contract above. The plan is not a signature, authorization
token or proof of a human click; polkit and authoritative device checks remain
the privilege boundary.

Public v1 rejects `confirmedPlan`; old v2 callers may omit it and retain the
existing fixed-mode contract. Root-auto remains on its existing profile and
supervisor admission path. The new GUI-plan guarantee applies only when this
capability is present, and the production GUI always supplies it. No supported
installation mode is added by this feature.

### Live copy measurements (explicit helper v2 capability)

V2 `install-full-disk` and `install-free-space` requests can opt in with
`includeCopyProgress: true`.
V1, audit and probe reject the field; existing v2 clients that omit it receive
the existing response types. The GUI opts in and receives typed frames:

```json
{"protocolVersion":2,"type":"copy-progress","phase":"main","bytesProcessed":4096,"bytesPerSecond":1024,"etaSeconds":12}
```

Phases are `main` and `efi`, with separate counters. `bytesProcessed` is rsync's
logical file-data progress, not physical writes, network traffic or a verified
file count. Bytes and rate are bounded integers; rate and ETA may be null.
There is no invented total-byte count from a rounded percentage. Numeric rsync
progress is parsed with bounded, anchored rules, and at most one sample per
second per phase is emitted. Filenames, stderr and arbitrary command output
cannot enter these frames. Rsync exit status and required-file checks remain
authoritative; progress or callback failure never constitutes installation
success.

ETA estimates only the current copy, never finalization, bootloader work or
the whole installation. It is shown only after warm-up and positive measured
throughput, when rsync reports a complete file list (`to-chk`, not `ir-chk`)
and a remaining-time estimate below 100%. It is absent during discovery,
stalls, completion or unknown output. The GUI removes measurements after
three seconds without a fresh sample, at the next stage and at the terminal
result. The existing overall stage progress is unchanged and still requires
an authenticated successful terminal result. Session-report v1 `bytesTransferred`
and `throughput` remain null; live copy counters are not persisted as a
misleading session-wide transfer total. Automated tests use temporary dirs,
stub processes and fake runners; they do not install onto disks or boot VMs.

### Backend handshake, scope and cancellation

The helper clears inherited environment, sets cwd `/` and umask 077, and chooses
all executable paths/argv. Its only child APIs are fixed read-only lsblk and
the fixed backend. The backend receives only
`{protocolVersion:1,operation:"install-full-disk",disk,expectedDevice}`. It
requires root and constructs a fixed full/Btrfs engine state, with no GUI
state/environment/profile overrides. Its initial request must arrive within
five seconds; total stdin is capped at 32 KiB.

For a v2 install, the public request may also contain `uiLanguage`, restricted
to the canonical codes in `assets/i18n/locales.json`: tr, en, es, de, fr, pt_BR,
it, ru, ar, fa, zh_CN and ja. The helper forwards only this validated hint in
the backend request. The GUI sends its selected language; target finalization
writes it to the existing `installer_ui_language_hint` seed field. Missing
hints retain the legacy `en` backend default. V1 public requests, audit and
probe reject this field. Invalid types/codes fail before the engine starts;
there is no silent protocol downgrade. This hint does not configure the target
locale, keyboard or timezone; Initial Setup still owns those choices.

The helper holds `/run/ro-installer/install.lock` for the complete backend
lifetime, in a root-owned 0700 directory with a root-owned 0600 persistent,
non-symlink inode. The backend inherits the locked descriptor so its kernel
lease remains held even if the helper is killed. It validates stat/sysfs/lsblk
identity and topology, compares
the confirmed major:minor/size/diskSequence and repeats validation before spawn.
After all partitioning read-only planning/tool checks, immediately before the
first wipefs, the existing Dart stage invokes its mutation callback. The backend
emits `{protocolVersion:1,type:"ready"}` and waits up to fifteen seconds. The
helper independently validates the device again and sends
`{protocolVersion:1,type:"continue",device:{path,majorMinor,size,diskSequence}}`.
The backend requires an exact matching identity before continuing. Its final
message is `{protocolVersion:1,type:"result",ok,code}` with OK, INSTALL_FAILED or
BACKEND_ERROR. The helper checks framing, schema, explicit success and process
exit before emitting the GUI's final result.

PR-A1 guards remain: partitions, aliases, removable/read-only disks, live/root
backing devices, mounted-device ancestors, active swap, nested target storage
and ambiguous topology are refused. Loop and overlay backing storage are traced.
Mounted Btrfs membership, unknown filesystems and stacked mounts still fail closed.
For KIWI/Fedora live boots, a loop's sysfs `backing_file` may retain a pre-pivot
name such as `/LiveOS/squashfs.img` although the ISO is now mounted at
`/run/initramfs/live`. The helper reads the fixed, read-only `LOOP_GET_STATUS64`
ioctl from the canonical loop device, checks its block identity and loop number,
and resolves the kernel-reported backing superblock through current mountinfo.
It does not guess a replacement pathname or treat missing backing metadata as
harmless. Unmounted/unresolved backing, cycles, unavailable ioctl/sysfs and
unsupported block-file backing fail closed. Missing topology data is
`AMBIGUOUS_TOPOLOGY`; `DEVICE_NOT_FOUND` means the selected /dev node is absent.
The kernel ABI is defined in [linux/loop.h](https://github.com/torvalds/linux/blob/master/include/uapi/linux/loop.h);
the [loop driver](https://github.com/torvalds/linux/blob/master/drivers/block/loop.c)
obtains backing device/inode from the open file, independent of its old name.

Only the standalone [document portal](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.Documents.html)
`fuse.portal` / `portal` mount at `/run/user/<uid>/doc`,
with an anonymous `0:*` device, is treated as a document-export namespace.
Every real mount and active swap is still independently checked. Other FUSE
filesystems remain unknown; a portal used as loop/overlay backing is rejected.
The Fedora 44 KIWI fixture covers ISO → loop → erofs → overlay, ZRAM and portal,
plus protected media, missing/ambiguous data and identity-change regressions.

Only x86_64 UEFI, Btrfs, GPT and the existing Btrfs subvolume layout are
authorized through full erase, verified free-space or typed manual contracts
above. Automatic layouts use a 512 MiB ESP; manual ESPs require at least that
size. No disk swap is created. Helper disk preparation does not globally
swapoff/unmount; ZRAM remains system policy. Alongside shrink,
ext4/XFS, LUKS/LVM/RAID/multipath and arbitrary swap are not authorized.

PR-A2 does not support cancellation after entering installation. Navigation and
target changes are disabled, and closing the GUI does not cancel the independent
backend session. The helper ignores terminal interruption and continues without
GUI output while retaining the lock. Protocol failure after authorization drains
the backend without forwarding data and returns failure after exit. A two-hour
helper watchdog kills a stalled backend process group and reports failure; this
is recovery from a stuck operation, not safe rollback. Any partial failure or
watchdog expiry requires inspecting target/mount state before retrying. There is
no automatic retry or promise of recovery from power loss/helper SIGKILL, even
though the backend retains the lock after helper death.

Before entering installation, the top bar always shows a localized Exit button
on Welcome and Disk, including small VM viewports. It closes only the user GUI
through Flutter's Linux application-exit channel; no reboot or privileged command
is needed. It disappears on entering Install, including before the delayed engine
start, and never represents cancellation of an already running backend. The full
storage caption states EFI + Btrfs with ZRAM and no disk swap partition.

### Installed-target cleanup and validation

Target finalization strictly enumerates the RPM DB before removal and verifies
absence after removal; an unreadable RPM DB never means successful absence.
Narrow cleanup and post-install checks cover the installer RPM, both /usr/bin
symlinks, lib/lib64 bundle directories, desktop file, launcher, helper, backend,
old/new installer polkit policies, future 49-ro-installer-live.rules and legacy
ro-installer-live sudoers file. Both existing paths and dangling symlinks fail
validation. Unrelated system polkit files are preserved. The runtime /run lock
is excluded from the prepared-root copy.

The stable gate runs helper protocol/storage/locking/backend/launcher/RPM tests
and the full Flutter suite. Package CI additionally checks the compiled backend,
helper ownership/modes and exact helper policy in the actual Fedora 44 product
RPM, rejects old root-GUI policy/sudoers/allow rules, and verifies installability.
Current sources retain these helper and storage protections; deploying the
P0 changes requires a newly approved release identity and exact artifacts.

For ISO acceptance, run a real Compose ISO with an active graphical polkit agent,
validate its live/root topology and authorization, then perform full install and
reboot to RO_INSTALLER_VM_BOOT_OK. Package CI does not establish Plasma Setup GUI/firstboot or physical-hardware
acceptance; that verification belongs to the subsequent Ro-image-compose stage.

## Technology and Repository Layout

- Flutter and Dart for the Linux desktop application.
- `lib/`: Flutter UI, installer state, services, storage planning, and stages.
- `bin/`: fixed non-GUI privileged Dart backend entrypoint.
- `assets/`: product images, branding, and localization data.
- `linux/`: Linux desktop integration, launcher, policy, and helper scripts.
- `scripts/`: RPM packaging, stable-gate automation, and external-ISO QEMU test
  helpers.
- `test/`: unit, service, stage, profile, storage, log, and script contract tests.
- `tool/`: development checks, including the i18n audit.
- `ro-installer.spec`: RPM packaging.
- `.github/workflows/`: CI automation. Fedora 44 is the current supported RPM packaging/CI
  baseline; that exact Fedora release is not an architectural requirement.

## Testing

Before a pull request, run the code and contract checks that match the changed
area. The full local acceptance gate is:

```bash
flutter analyze
flutter test
dart run tool/i18n_audit.dart
bash scripts/check-stable.sh
```

The stable gate retains shell/Python syntax, Flutter analysis/tests, i18n,
destructive-disk safeguards, password/command redaction coverage, restricted
sudo policy, RPM source/build hygiene, and diagnostic/log artifact contracts.
It does not require Installer-owned ISO composition, repository wiring, COPR
kernel policy, or a custom-kernel-only release policy. Remaining shell scripts
are syntax-checked; the gate also guards the external-ISO testing boundary.

Ro-Installer does not build or remix test ISOs. QEMU integration requires a
known-good external Compose-produced live/test ISO, supplied explicitly:

```bash
scripts/test-qemu.sh --suite check --iso /path/to/compose-test.iso
RO_ASD_TEST_ISO=/path/to/compose-test.iso scripts/test-qemu.sh --suite smoke
scripts/test-qemu.sh --suite install --iso /path/to/compose-test.iso
RO_INSTALLER_TEST_ISO=/path/to/compose-test.iso ./test_qemu_vm.sh auto
```

The QEMU suites are `check`, `boot`, `smoke`, `install`, and `all`. The boot
helper and wrapper accept `--iso PATH` or `RO_ASD_TEST_ISO`; the full install
harness requires `RO_INSTALLER_TEST_ISO`. Missing or unreadable input stops
before building the Installer or launching QEMU. No repository-local ISO is
selected automatically.

The automated install harness accepts these `QEMU_DISPLAY_MODE` values:

| Mode | Use |
| --- | --- |
| `headless` (default) | CI / unattended, no display window |
| `gui` | Native QEMU display |
| `spice` | Recommended local interactive mode with clipboard |

```bash
RO_INSTALLER_TEST_ISO=/absolute/path/to/Ro-ASD-44-integration-0001-x86_64.iso \
QEMU_DISPLAY_MODE=spice \
./test_qemu_vm.sh auto
```

Host requirements are `qemu-system-x86_64`, `qemu-img`, and OVMF firmware
(Fedora packages: `qemu-system-x86`, `qemu-img`, `edk2-ovmf`). Only `spice`
requires a SPICE-enabled QEMU build and `remote-viewer` (`virt-viewer`, version
8.0 or newer for UNIX socket connection files). Preflight checks the viewer and
QEMU UNIX socket capability before building or starting the installation.

SPICE uses `$RUN_DIR/spice.sock` in a private per-run directory, with no TCP
listener, password, or credentials. QEMU runs with `-display none` and the
standard `com.redhat.spice.0` virtio-serial agent channel. The harness waits up
to 10 seconds for the socket, then launches `remote-viewer "$RUN_DIR/spice.vv"`.
Viewer output is retained in `$RUN_DIR/remote-viewer.log`. Closing the viewer
leaves QEMU and the automated test running; cleanup terminates both processes
best-effort and retains the run directory and logs after failures. Manual mode
also supports SPICE; its existing native-window behavior remains for other modes.

Guest clipboard requires `spice-vdagent` running in the Compose-produced live
image. It belongs to the live image environment, not Installer dependencies.
The clipboard path is host desktop → remote-viewer → SPICE → virtio-serial
vdagent channel → spice-vdagent in the live guest. QMP does not synchronize
clipboard content, and no custom clipboard scripts or SSH are used.

SPICE is for local human viewing and clipboard/input; QMP remains machine
control and short boot-menu key combinations. QGA executes guest commands,
9p transports files, and the serial `RO_INSTALLER_VM_BOOT_OK` marker is the final
boot authority, independent of QGA availability and viewer exit status.

Automation follows external Compose ISO → QEMU UEFI → QGA readiness → QGA
`guest-exec` → 9p mount → `test_qemu_guest_runner.sh` → Installer with
`RO_INSTALLER_AUTO_REBOOT=0` → logs copied to host → QGA reboot → installed
target → serial `RO_INSTALLER_VM_BOOT_OK` → smoke-service poweroff. The runner's
manual default for automatic reboot remains unchanged.

All display modes expose `$RUN_DIR/qga.sock`, a Unix-only socket under the
private (0700) run directory. One `virtio-serial-pci,id=virtio_serial0` controller
carries QGA on port 1 (`org.qemu.guest_agent.0`) and, in SPICE mode, vdagent on
port 2 (`com.redhat.spice.0`). The external live ISO must contain an enabled
`qemu-guest-agent.service`; the named device lets it start without terminal input.

The host retries socket connection, protocol synchronization and `guest-ping`
for `QGA_READY_TIMEOUT_SECONDS` (default 300). Each connection uses
[`guest-sync-delimited`](https://www.qemu.org/docs/master/interop/qemu-ga-ref.html#command-guest-sync-delimited)
with a fresh token and sentinel to discard stale stream data. Readiness timeout
fails closed and points to `qga.log`, `serial.log`, and the run directory.
There is no keyboard fallback. `/bin/sh -c` runs the quoted mkdir → mount →
runner chain with `&&`, without interactive sudo.
Install and reboot shells explicitly export `GUEST_COMMAND_PATH` (default
`/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`) before external
commands. The guest runner resets and exports PATH before its first external
command using the same default or explicit harness override, ignoring inherited
service/shell PATH. Empty overrides, empty entries, and relative directories
are rejected; custom mount/profile/PATH values are shell-quoted.

Because the Flutter Linux runner initializes GTK even in auto mode, the QGA harness waits up to 120 seconds for one existing live
Wayland socket under `/run/user` and passes its `XDG_RUNTIME_DIR`,
`WAYLAND_DISPLAY`, and `GDK_BACKEND=wayland`. Missing or ambiguous displays
fail closed; compositor permissions are unchanged. Execution/status polling is
bounded by `AUTO_TEST_TIMEOUT_SECONDS` (default 1800); unexpected agent loss
or a nonzero runner exit fails without reboot, retaining available diagnostics.

Before reboot the host requires `runner-install-exited-0`, `runner-logs-copied-0`
and the fixed success markers. The guest runner captures root-auto's sanitized
output as `backend-output.log`; copying that file is part of acceptance. Copy failures fail the
E2E. QGA acknowledges the reboot shell's PID before the host returns to serial
monitoring; a short guest delay lets that acknowledgement arrive before
`systemctl reboot` disconnects the agent. Serial boot monitoring has its own
`AUTO_TEST_TIMEOUT_SECONDS` bound. Focused tests require no VM:
`python3 test/scripts/qemu_spice_test.py` and
`python3 test/scripts/qga_client_test.py` (also covered by the stable gate).

The install harness builds the current Flutter Linux release binary and exposes
the current bundle and sanitized profile through a 9p host share. The live guest
runs that Installer against a disposable VM disk, reboots, and the harness
observes the existing installed-target smoke marker. Serial logs, guest runner
state, Installer session/failure artifacts, and boot markers remain available.
This mechanism does not require the external ISO to contain the same Installer
build. The external Compose `installer-test-iso` integration image is available;
full installation, technical validation, reboot, and smoke-marker acceptance
are still in progress.

RPM packaging is independent: `scripts/01-build-rpm.sh` writes the source
tarball, RPM, checksum, manifest, and latest RPM pointers, then exits. It performs
no ISO action. `scripts/refresh-local-paths.sh` repairs local RPM pointers only.

Storage, bootloader, RPM, and QEMU changes should include the relevant artifact
or log evidence in the pull request. The existing RPM workflow publishes RPM
artifacts for review when it runs in GitHub Actions.

## Session records and diagnostic exports

Both GUI and root-auto use the existing root session supervisor. It writes
typed JSONL and atomic summary checkpoints beneath the fixed
`/run/ro-installer/records/<128-bit-random-id>/` location, using root-owned 0700
directories and 0600 regular, singly linked files. Paths are opened relative to
validated directory descriptors without following symlinks. No environment or
GUI parameter selects this privileged destination. `RO_INSTALLER_LOG_DIR` no
longer controls root-auto output. No historical-session reader is exposed.

The single contract is `linux/ro-installer-observability.json`; run
`python3 scripts/generate-observability-schema.py --check` to verify the Dart
validator's generated copy. Events accept only fixed operation/error identifiers,
stage numbers, status, UTC timestamps and bounded numeric measurements. They
exclude command lines, profiles, environment, stream output and exceptions.
Limits are 1 KiB/event, 20,000 events and 4 MiB/event file, 8 KiB/summary,
32 sessions and a 64 MiB logical store budget (including active reservations).
Filesystem allocation and tmpfs bookkeeping are additional. A full store never
silently deletes records; unavailable, failed, truncated and incomplete logging
remain independent of the installation result and cleanup result.

Engine timings use `Stopwatch`; supervisor/command timings use
`time.monotonic_ns()`. Process-local epochs are never subtracted across processes.
Nine stage measurements and preflight, main/EFI copy, diagnostics, cleanup and
engine spans overlap: do not sum them together. Unstarted stages have null
duration; interrupted operations retain partial duration when observable.
Transferred bytes and throughput are null because they are not measured.
Functional command capture is separately bounded: parsed stdout retains at most
1 Mi characters, stderr and unparsed rsync streams 64 Ki characters each, and
log lines 8 Ki characters. Oversized parsed stdout is drained, then fails closed
with `-126/COMMAND_OUTPUT_LIMIT`, without parsing a truncated prefix. Rsync's
actual exit status and flags remain authoritative. Logging limits never change
command exit status. This bounds retained data, not total stream traffic.

GUI explicitly selects helper `--protocol=2`. The existing operations and v1
strict request/terminal checks are preserved. V2 adds exactly one bounded
`session-report` response for the current install, before the helper terminal
result. A missing/invalid report body is reported separately; malformed framing,
duplicates, ordering errors or unauthenticated terminal results still fail
closed. V1 has no report response or silent downgrade. Root-auto emits the same
safe report in a `RO_INSTALLER_SESSION_REPORT` stdout frame. Reboot, when already
requested, is delegated to the supervisor after record finalization while its
session lease remains held.

`/run` is transient: reboot or power loss removes these root records. The GUI
exports its validated report before reboot with its own user privileges and
disables reboot while export is pending. The separate
`/usr/libexec/ro-installer-export` refuses root. It publishes a 0700 bundle with
0600 `install.log`, `summary.json` and a hash `manifest.json`, using exclusive
creation, fsync and Linux atomic no-replace directory rename. Consumers accept
published `install-*` directories with a complete verified manifest; `.install-*`
directories are unpublished. Failure before publication leaves no valid partial
bundle. `EXPORT_PUBLISH_UNCONFIRMED` means publication happened but parent fsync
failed: a complete package may exist, without a durability claim. Filesystems
without the required rename primitive return a safe error. Existing files are
never replaced. Default exports use XDG state or `~/.local/state/ro-installer/exports`;
user-side `RO_INSTALLER_LOG_DIR` overrides do not grant root access.

Free-text exports redact known secret aliases, argv values, nested JSON,
URL credentials/query tokens and final status; errors use fixed codes. Regex
redaction cannot recognize every unknown secret. The structured report's safety
comes from excluding free text. Automatic privileged journal/dmesg/file dumps
are replaced by structured diagnostics metadata. No logs are automatically
copied to the installed target or sent to a server.

Security regressions use disposable directories, fake disk commands and real
process/IPC faults. The synthetic benchmark
`python3 -B test/fixtures/observability_benchmark.py --runs 5` reports independent
process samples, retained memory, bytes and file operations; it is not physical
installation performance evidence. CI's namespace result remains separately
PASS/FAIL/UNAVAILABLE; UNAVAILABLE leaves full security acceptance **NO-GO**.

## Contributing

Pull requests should stay focused and describe the user-visible behavior,
storage or boot risk, and verification performed. Changes that affect disk
writes, boot configuration, package trust, release artifacts, or CI should
include tests or an explicit explanation of the remaining verification gap.

Do not commit local planning notes, generated build output, debug captures, VM
disks, ISO files, RPM files, or workspace-specific editor state. Keep active
architecture documentation in this README. The sole retained historical report
is `docs/I01-kernel-index-permissions-20261021.md`; preserve it as reviewed I01
evidence. These are the two allowed source Markdown files. Additional historical
reports and raw test evidence belong in ignored `outputs/` directories or CI
artifacts, with commands, toolchain versions, source commit and PASS/FAIL/SKIP
counts recorded alongside the logs.

`scripts/check-source-policy.py --mode checkout` requires the actual worktree
root and a successful, nonempty Git source listing. Its automatic mode selects
checkout only when the source root has its own `.git` marker; extracted RPM
sources are checked as archives by inspecting shipped files, even below an
unrelated parent checkout. Generated build/output directories are excluded from
archive inspection. Missing required documents, unexpected source Markdown and
Git errors in a checkout fail acceptance. CI checks the real checkout before
RPM build; RPM `%check` also checks the extracted source tree.

Stable acceptance requires real `depmod` and `modprobe` (Fedora package `kmod`).
The initramfs-reuse regression also requires the packaged Fedora
`50-dracut.install` plugin (`dracut`); it is a required check, not an optional skip.
The dedicated I01 acceptance runner requires all four kernel-index regressions
to complete successfully with zero skips, in addition to the full Flutter
suite. The two optional physical-log corpus tests remain separately reported
skips when their intentionally uncommitted input is absent. CI keeps its pinned
Flutter SDK; local evidence must record any toolchain difference.
