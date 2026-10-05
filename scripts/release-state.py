#!/usr/bin/env python3
"""Resolve the exact GitHub Release state for one immutable tag."""

from __future__ import annotations

import argparse
import json
import pathlib
import sys


def classify(releases: object, tag: str) -> dict[str, object]:
    if not isinstance(releases, list):
        raise ValueError("release list must be a JSON array")

    matches = [
        item for item in releases
        if isinstance(item, dict) and item.get("tagName") == tag
    ]

    if len(matches) > 1:
        raise ValueError(f"multiple releases found for tag {tag}")

    if not matches:
        return {"state": "absent", "release_id": None}

    item = matches[0]
    release_id = item.get("databaseId")
    is_draft = item.get("isDraft")

    if not isinstance(release_id, int) or release_id <= 0:
        raise ValueError(f"invalid release databaseId for tag {tag}: {release_id!r}")
    if not isinstance(is_draft, bool):
        raise ValueError(f"invalid isDraft for tag {tag}: {is_draft!r}")

    return {
        "state": "draft" if is_draft else "published",
        "release_id": release_id,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", required=True)
    parser.add_argument("--input", type=pathlib.Path)
    args = parser.parse_args()

    if args.input:
        data = json.loads(args.input.read_text(encoding="utf-8"))
    else:
        data = json.load(sys.stdin)

    print(json.dumps(classify(data, args.tag), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
