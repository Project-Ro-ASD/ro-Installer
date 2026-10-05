#!/usr/bin/env python3
"""Build component-artifact-manifest-v1.json for an exact ro-installer RPM set."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import subprocess


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def rpm_header(path: pathlib.Path) -> dict[str, object]:
    query = (
        "%{NAME}\t%{EPOCHNUM}\t%{VERSION}\t%{RELEASE}\t%{ARCH}\t"
        "%{SOURCERPM}\t%|SOURCEPACKAGE?{true}:{false}|"
    )
    output = subprocess.check_output(
        ["rpm", "-qp", "--qf", query, str(path)], text=True
    )
    values = output.split("\t")
    if len(values) != 7:
        raise SystemExit(f"unexpected RPM header for {path.name}: {output!r}")

    name, epoch, version, release, architecture, source_rpm, is_source = values
    if is_source == "true":
        architecture = "src"
        source_rpm_value = None
    else:
        source_rpm_value = source_rpm

    return {
        "filename": path.name,
        "name": name,
        "epoch": int(epoch or 0),
        "version": version,
        "release": release,
        "architecture": architecture,
        "source_rpm": source_rpm_value,
        "producer_artifact_sha256": sha256(path),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--artifacts-dir", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--release-id", required=True)
    parser.add_argument("--workflow-run", required=True)
    args = parser.parse_args()

    rpms = sorted(args.artifacts_dir.glob("*.rpm"))
    if len(rpms) != 2:
        raise SystemExit(
            "ro-installer release must contain exactly 2 RPMs "
            f"(x86_64, src); found {[path.name for path in rpms]}"
        )

    artifacts = [rpm_header(path) for path in rpms]
    architectures = sorted(str(item["architecture"]) for item in artifacts)
    if architectures != ["src", "x86_64"]:
        raise SystemExit(f"unexpected RPM architecture set: {architectures}")

    for item in artifacts:
        if item["name"] != "ro-installer":
            raise SystemExit(
                f"unexpected package name in {item['filename']}: {item['name']}"
            )
        if not str(item["release"]).endswith(".fc44"):
            raise SystemExit(f"RPM is not a Fedora 44 build: {item['filename']}")

    source_names = {
        str(item["filename"])
        for item in artifacts
        if item["architecture"] == "src"
    }
    if len(source_names) != 1:
        raise SystemExit(f"expected one published SRPM, found {sorted(source_names)}")

    for item in artifacts:
        if item["architecture"] != "src" and item["source_rpm"] not in source_names:
            raise SystemExit(
                f"binary RPM {item['filename']} does not point at "
                f"the published SRPM {item['source_rpm']}"
            )

    manifest = {
        "schema_version": 1,
        "component": "ro-installer",
        "source_repository": args.repository,
        "source_commit": args.commit,
        "release_tag": args.tag,
        "release_id": int(args.release_id),
        "workflow_run": int(args.workflow_run),
        "fedora_release": 44,
        "artifacts": artifacts,
        "provenance": {
            "provider": "github-actions",
            "subject_digest": f"git:{args.commit}",
        },
        "attestation": {
            "provider": "github-artifact-attestations",
            "verification": (
                "gh attestation verify with exact repository, commit "
                "and signer workflow"
            ),
        },
        "sbom": None,
    }

    args.output.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
