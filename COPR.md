# COPR Packaging

This repository uses `make_srpm` for COPR. The source build creates the
application source tarball from the checked-out Git tree, and the RPM build
bootstraps a pinned Flutter SDK inside the build chroot.

## Why This Setup Exists

Fedora 43 COPR chroots do not provide a `flutter` RPM package. Because of that,
using:

```spec
BuildRequires: flutter
```

causes the build to fail during `dnf5 builddep` with:

```text
No match for argument: flutter
```

The spec therefore downloads the official Flutter SDK archive during `%build`,
verifies its SHA-256 checksum, enables Linux desktop support, precaches Linux
artifacts, and then runs the normal Flutter build.

## Required COPR Settings

Keep **internet access enabled** for this package in COPR. The RPM build needs
network access for:

- downloading the pinned Flutter SDK archive
- Flutter Linux artifact precache during the first build in a clean chroot

If internet access is disabled, the build will fail even if the SRPM phase
passes.

## Files Used By COPR

- `ro-installer.spec`
- `.copr/Makefile`

## How The Build Works

1. COPR clones this repository from GitHub.
2. COPR runs `.copr/Makefile` with `make_srpm`.
3. `.copr/Makefile` creates `ro-installer-<version>.tar.gz` from the checked-out
   tree.
4. COPR builds the SRPM.
5. During the RPM build, `ro-installer.spec` downloads the pinned Flutter SDK,
   verifies it, runs `flutter pub get`, and builds the Linux release bundle.

## Local Reproduction

If COPR gives you a build task URL, reproduce it locally with:

```bash
sudo dnf install copr-rpmbuild
/usr/bin/copr-rpmbuild --verbose --drop-resultdir \
  --task-url https://copr.fedorainfracloud.org/backend/get-build-task/TASKID \
  --chroot fedora-43-x86_64
```

To test only SRPM generation from the repo checkout:

```bash
mkdir -p dist
make -f .copr/Makefile srpm outdir="$PWD/dist" spec="$PWD/ro-installer.spec"
```

## Updating Flutter

When updating Flutter for COPR:

1. Update `flutter_version`
2. Update `flutter_channel` if needed
3. Update `flutter_sha256`
4. Push to GitHub and trigger a fresh COPR build

The release metadata can be checked from the official Flutter release index:

- https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json

## Recommended COPR Source Method

Use:

- Source Type: `git`
- Spec file: `ro-installer.spec`
- SRPM build method: `make_srpm`
- Subdirectory: empty

`rpkg` is not needed for this repository.
