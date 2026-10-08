#!/usr/bin/env python3
"""Check the built RPM's helper payload, ownership, modes and polkit binding."""

import json
from pathlib import Path
import re
import stat
import subprocess
import sys
import xml.etree.ElementTree as ET


HELPER = "/usr/libexec/ro-installer-helper"
POLICY = "/usr/share/polkit-1/actions/org.roasd.installer.helper.policy"


def check_policy(raw):
    root = ET.fromstring(raw)
    actions = root.findall("action")
    if len(actions) != 1 or actions[0].get("id") != "org.roasd.installer.helper":
        raise ValueError("helper policy must contain exactly its dedicated action")
    action = actions[0]
    annotations = action.findall("annotate")
    if (len(annotations) != 1
            or annotations[0].get("key") != "org.freedesktop.policykit.exec.path"
            or annotations[0].text != HELPER):
        raise ValueError("helper policy must bind only the exact helper path")
    expected = {"allow_any": "no", "allow_inactive": "no", "allow_active": "auth_admin"}
    defaults = action.find("defaults")
    if (defaults is None or len(action.findall("defaults")) != 1 or len(defaults) != 3
            or {node.tag: node.text for node in defaults} != expected):
        raise ValueError("helper policy defaults must deny non-active callers and avoid retained authorization")


def extract_member(rpm, name):
    with subprocess.Popen(["rpm2cpio", str(rpm)], stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL) as producer:
        try:
            result = subprocess.run(
                ["cpio", "--extract", "--to-stdout", "--quiet", "." + name],
                stdin=producer.stdout, capture_output=True, check=True, timeout=60,
            )
            producer.stdout.close()
            if producer.wait(timeout=5) != 0 or not result.stdout:
                raise ValueError("RPM payload member is absent or unreadable")
            return result.stdout
        finally:
            if producer.poll() is None:
                producer.kill()
                producer.wait()


def check_package(rpm):
    result = subprocess.run(
        ["rpm", "-qp", "--qf",
         "[%{FILENAMES}|%{FILEMODES}|%{FILEUSERNAME}|%{FILEGROUPNAME}\n]", str(rpm)],
        text=True, capture_output=True, check=True, timeout=15,
    )
    files = {}
    for line in result.stdout.splitlines():
        path, mode, user, group = line.split("|")
        if path in files:
            raise ValueError("duplicate RPM path")
        files[path] = (int(mode), user, group)
        if (path.startswith("/etc/sudoers") or path.startswith("/etc/polkit-1/rules.d/")
                or path.startswith("/usr/share/polkit-1/rules.d/")):
            raise ValueError("installer RPM must not ship sudoers or live-only allow rules")
    for path, permissions in ((HELPER, 0o755), (POLICY, 0o644)):
        mode, user, group = files[path]
        if not stat.S_ISREG(mode) or stat.S_IMODE(mode) != permissions or (user, group) != ("root", "root"):
            raise ValueError("helper payload ownership, type or mode is incorrect")
    helper = extract_member(rpm, HELPER)
    policy = extract_member(rpm, POLICY)
    if not helper.startswith(b"#!/usr/bin/python3 -I\n"):
        raise ValueError("helper must use the isolated system Python interpreter")
    if re.search(rb"NOPASSWD\s*:", helper + policy):
        raise ValueError("helper payload must not introduce passwordless sudo")
    check_policy(policy)
    return {"helper": HELPER, "policy": POLICY,
            "ownership": {"user": "root", "group": "root"}, "ok": True}


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: check-helper-package.py RPM_PATH")
    print(json.dumps(check_package(Path(sys.argv[1]).resolve())))
