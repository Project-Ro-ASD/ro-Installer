# COPR Guide

This repository is prepared for COPR builds using the **SCM source type** and
the **make srpm** SRPM generation method.

## Why `make srpm` instead of `rpkg`?

Use `make srpm` for this repository.

Reason:

1. This is an upstream application repository, not a dedicated DistGit-style
   `rpkg` repository.
2. COPR documents that `rpkg` is the default SCM method, but it also notes
   that modern `rpkg` workflows expect rpkg-util v3 templating conventions.
3. `make srpm` lets us generate the exact source archive from the checked out
   tree and then call `rpmbuild -bs` ourselves.
4. That keeps the packaging logic simple and explicit for GitHub webhook builds.

Relevant official COPR documentation:

- SCM source type and SRPM build methods:
  https://docs.pagure.org/copr.copr/user_documentation.html
- Local package building with `rpkg`:
  https://docs.pagure.org/copr.copr/building_package.html

## Files Used by COPR

- `ro-installer.spec`
- `.copr/Makefile`
- `LICENSE`

The Makefile target that COPR runs is:

```bash
make -f .copr/Makefile srpm outdir="<outdir>" spec="ro-installer.spec"
```

That target:

1. reads `Name` and `Version` from the spec file
2. creates `ro-installer-<version>.tar.gz` from the checked out source tree
3. runs `rpmbuild -bs`
4. places the resulting `.src.rpm` into `outdir`

Important:

- COPR runs `make srpm` in a minimal source chroot
- do not assume tools like `git` are available there
- the provided `.copr/Makefile` therefore uses `cp` and `tar`, not `git archive`

## How to Configure COPR

Create or edit the package in COPR with these settings:

1. **Source Type**: `SCM`
2. **SCM Type**: `git`
3. **Clone URL**:
   `https://github.com/Project-Ro-ASD/ro-Installer.git`
4. **Committish**:
   `main`
5. **Subdirectory**:
   leave empty
6. **Spec File**:
   `ro-installer.spec`
7. **SRPM Build Method**:
   `make srpm`
8. **Auto-rebuild**:
   enable it

## GitHub Webhook Setup

Once the SCM package exists in COPR:

1. Open the COPR project
2. Go to **Settings** -> **Integrations**
3. Copy the GitHub webhook URL
4. In GitHub open:
   `Settings -> Webhooks -> Add webhook`
5. Paste the COPR webhook URL as **Payload URL**
6. Set **Content type** to `application/json`
7. Enable push events
8. Save

Official COPR GitHub webhook documentation:

- https://docs.pagure.org/copr.copr/user_documentation.html

## Local Test Workflow

If you want to test the SRPM generation locally:

```bash
mkdir -p dist
make -f .copr/Makefile srpm outdir="$PWD/dist" spec="ro-installer.spec"
```

That should produce:

- `dist/ro-installer-1.2.7.tar.gz`
- `dist/ro-installer-1.2.7-1*.src.rpm`

If `mock` is available, rebuild the SRPM locally:

```bash
mock -r fedora-rawhide-x86_64 --rebuild dist/*.src.rpm
```

## Important Dependency Note

The spec currently uses:

```spec
BuildRequires: flutter
```

This means the selected COPR chroot must have an RPM package providing the
Flutter SDK. If your target chroot does not provide `flutter`, the build will
fail before compilation starts.

In that case you need one of these:

1. an additional repository enabled in COPR that provides `flutter`
2. a dedicated COPR package for `flutter`

Do not rely on downloading Flutter from the Internet during `%build`; keep the
build declarative and reproducible.
