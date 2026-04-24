# COPR Guide

This repository is prepared for COPR builds with the `SCM` source type and the
`make srpm` workflow.

## Build Method

Use `make srpm` for this project.

Why:

1. This is the upstream application repository, not a DistGit-style packaging repository.
2. The provided `.copr/Makefile` creates the source archive directly from the checked-out tree.
3. The workflow stays explicit, reproducible, and compatible with GitHub-triggered COPR builds.

Files used by COPR:

- `ro-installer.spec`
- `.copr/Makefile`
- `LICENSE`

Command executed by COPR:

```bash
make -f .copr/Makefile srpm outdir="<outdir>" spec="ro-installer.spec"
```

## COPR Package Settings

Configure the package with these values:

1. `Source Type`: `SCM`
2. `SCM Type`: `git`
3. `Clone URL`: `https://github.com/Project-Ro-ASD/ro-Installer.git`
4. `Committish`: `main`
5. `Subdirectory`: leave empty
6. `Spec File`: `ro-installer.spec`
7. `SRPM Build Method`: `make srpm`
8. `Auto-rebuild`: enabled

## GitHub Webhook

After creating the SCM package in COPR:

1. Open the COPR project.
2. Go to `Settings -> Integrations`.
3. Copy the GitHub webhook URL.
4. In GitHub open `Settings -> Webhooks -> Add webhook`.
5. Paste the COPR URL into `Payload URL`.
6. Set content type to `application/json`.
7. Enable push events and save.

## Local SRPM Test

```bash
mkdir -p dist
make -f .copr/Makefile srpm outdir="$PWD/dist" spec="ro-installer.spec"
```

Expected output for the current release:

- `dist/ro-installer-3.0.0.tar.gz`
- `dist/ro-installer-3.0.0-1*.src.rpm`

Optional local rebuild with `mock`:

```bash
mock -r fedora-rawhide-x86_64 --rebuild dist/*.src.rpm
```

## Note About Flutter

The RPM build expects a Fedora-compatible environment with the required build
dependencies available to the spec. Keep the build declarative and avoid adding
ad-hoc downloads outside the packaging workflow.
