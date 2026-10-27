#!/usr/bin/env python3
"""Check tracked documentation in a checkout, or shipped files in an archive."""

import argparse
import os
from pathlib import Path
import subprocess
import sys


ALLOWED_MARKDOWN = frozenset({
    "README.md",
    "docs/I01-kernel-index-permissions-20261021.md",
})
# Flutter/RPM checks create these after source extraction. They are not sources.
GENERATED_DIRECTORIES = frozenset({
    ".git", ".dart_tool", "build", "outputs", "rpm-outputs",
})


def documentation_paths(root, mode):
    if mode == "checkout":
        top = subprocess.run(["git", "-C", str(root), "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True, check=True)
        if Path(top.stdout.strip()).resolve() != root:
            raise ValueError("checkout must be the Git worktree root, not a build subdirectory")
        listed = subprocess.run(["git", "-C", str(root), "ls-files", "--cached", "-z"],
                                capture_output=True, text=True, check=True)
        paths = {p for p in listed.stdout.split("\0") if p}
        if not paths:
            raise ValueError("Git returned an empty tracked source list")
        return {p for p in paths if Path(p).suffix.lower() == ".md"}

    paths = set()
    for directory, children, files in os.walk(root):
        if Path(directory) == root:
            children[:] = [p for p in children if p not in GENERATED_DIRECTORIES]
        for name in files:
            if Path(name).suffix.lower() == ".md":
                paths.add((Path(directory) / name).relative_to(root).as_posix())
    return paths


def check(root, mode):
    marker = root / ".git"
    if mode == "auto":
        mode = "checkout" if os.path.lexists(marker) else "archive"
    if mode == "archive" and os.path.lexists(marker):
        raise ValueError("archive mode requires an extracted source tree without .git")
    paths = documentation_paths(root, mode)
    missing = ALLOWED_MARKDOWN - paths
    unexpected = paths - ALLOWED_MARKDOWN
    if missing or unexpected:
        raise ValueError(f"documentation policy: missing={sorted(missing)}, unexpected={sorted(unexpected)}")
    for path in ALLOWED_MARKDOWN:
        file = root / path
        if not file.is_file() or file.is_symlink():
            raise ValueError(f"required documentation is missing or a symlink: {path}")
    print(f"Documentation policy OK ({mode}): {len(paths)} allowed Markdown files")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--mode", choices=("auto", "checkout", "archive"), default="auto")
    args = parser.parse_args()
    try:
        check(args.root.resolve(), args.mode)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Documentation policy failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
