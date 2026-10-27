#!/usr/bin/env python3
"""Require all four real-tool I01 regressions to pass without skips."""

import json
import shutil
import subprocess
import sys


TEST_PATH = "test/services/install_stages/kernel_index_permissions_test.dart"
EXPECTED_TESTS = frozenset({
    "0077 parent: real depmod repairs Live indexes before dracut and after plugins",
    "unprivileged real modprobe resolves rebuilt builtin alias indexes",
    "depmod failure before dracut aborts preparation",
    "depmod failure after kernel-install aborts preparation",
})


def validate_report(output):
    tests = {}
    completed = set()
    successful_run = False
    for line in output.splitlines():
        if not line.strip():
            continue
        event = json.loads(line)
        kind = event.get("type")
        if successful_run:
            raise ValueError("events after test runner completion")
        if kind == "testStart":
            test = event["test"]
            if test["name"] in EXPECTED_TESTS:
                if test["id"] in tests or test["name"] in tests.values():
                    raise ValueError("duplicate I01 test start")
                tests[test["id"]] = test["name"]
        elif kind == "testDone" and event["testID"] in tests:
            name = tests[event["testID"]]
            if event.get("skipped") is not False or event.get("result") != "success":
                raise ValueError(f"I01 regression failed or skipped: {name}")
            if name in completed:
                raise ValueError("duplicate I01 test completion")
            completed.add(name)
        elif kind == "testDone" and event.get("hidden") is not True:
            raise ValueError("unexpected test outside the four I01 regressions")
        elif kind == "error":
            raise ValueError("test runner reported an error")
        elif kind == "done":
            if completed != EXPECTED_TESTS or event.get("success") is not True:
                raise ValueError("invalid test runner completion")
            successful_run = True
    if completed != EXPECTED_TESTS or not successful_run:
        raise ValueError(f"expected four completed I01 tests; got {sorted(completed)}")


def main():
    missing = [tool for tool in ("depmod", "modprobe", "flutter") if not shutil.which(tool)]
    if missing:
        print(f"I01 acceptance requires real tools: {', '.join(missing)} (Fedora: kmod)", file=sys.stderr)
        return 1
    result = subprocess.run(["flutter", "test", "--no-pub", "--reporter=json", TEST_PATH],
                            capture_output=True, text=True)
    print(result.stdout, end="")
    print(result.stderr, end="", file=sys.stderr)
    try:
        if result.returncode:
            raise ValueError(f"flutter test exited {result.returncode}")
        validate_report(result.stdout)
    except (ValueError, KeyError, TypeError) as error:
        print(f"I01 acceptance failed: {error}", file=sys.stderr)
        return 1
    print("I01 acceptance: 4 PASS, 0 FAIL, 0 SKIP")
    return 0


if __name__ == "__main__":
    sys.exit(main())
