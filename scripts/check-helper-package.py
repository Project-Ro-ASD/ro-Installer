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
BACKEND = "/usr/libexec/ro-installer-backend"
SESSION = "/usr/libexec/ro-installer-session"
EXPORT = "/usr/libexec/ro-installer-export"
RECORDS = "/usr/libexec/ro_installer_records.py"
GPT = "/usr/libexec/ro_installer_gpt.py"
MANUAL = "/usr/libexec/ro_installer_manual.py"
NTFS = "/usr/libexec/ro_installer_ntfs.py"
NTFS_COMMIT = "/usr/libexec/ro_installer_ntfs_commit.py"
BOUND_IO = "/usr/libexec/ro-installer-ntfs-bound-io.so"
SCHEMA = "/usr/libexec/ro-installer-observability.json"
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
    for path, permissions in ((HELPER, 0o755), (BACKEND, 0o755), (SESSION, 0o755), (EXPORT, 0o755), (RECORDS, 0o644), (GPT, 0o644), (MANUAL, 0o644), (NTFS, 0o644), (NTFS_COMMIT, 0o644), (BOUND_IO, 0o644), (SCHEMA, 0o644), (POLICY, 0o644)):
        if path not in files:
            raise ValueError("required helper payload is missing")
        mode, user, group = files[path]
        if not stat.S_ISREG(mode) or stat.S_IMODE(mode) != permissions or (user, group) != ("root", "root"):
            raise ValueError("helper payload ownership, type or mode is incorrect")
    if "/usr/share/polkit-1/actions/org.roasd.installer.policy" in files:
        raise ValueError("obsolete root-GUI action must not be packaged")
    backend = extract_member(rpm, BACKEND)
    if not backend.startswith(b"\x7fELF"):
        raise ValueError("backend must be the compiled Dart executable")
    exporter = extract_member(rpm, EXPORT)
    if not exporter.startswith(b"#!/usr/bin/python3 -I\n"):
        raise ValueError("user exporter must use isolated Python")
    schema=json.loads(extract_member(rpm,SCHEMA))
    if schema['version'] != 1 or schema['limits']['reportBytes'] != 4096:
        raise ValueError("unexpected observability contract")
    extract_member(rpm,RECORDS)
    if not extract_member(rpm,GPT).startswith(b'#!/usr/bin/python3 -I\n'):
        raise ValueError('GPT worker must use isolated system Python')
    if not extract_member(rpm,MANUAL).startswith(b'#!/usr/bin/python3 -I\n'):
        raise ValueError('Manual worker must use isolated system Python')
    if not extract_member(rpm, NTFS).startswith(b'#!/usr/bin/python3 -I\n'):
        raise ValueError('NTFS worker must use isolated system Python')
    if not extract_member(rpm, NTFS_COMMIT).startswith(b'#!/usr/bin/python3 -I\n'):
        raise ValueError('Private NTFS commit module must use isolated system Python')
    adapter = extract_member(rpm, BOUND_IO)
    if (len(adapter) < 20 or adapter[:7] != b'\x7fELF\x02\x01\x01'
            or adapter[16:20] != b'\x03\x00\x3e\x00'):
        raise ValueError('NTFS adapter must be a Linux x86_64 shared ELF object')
    session = extract_member(rpm, SESSION)
    if not session.startswith(b"#!/usr/bin/python3 -I\n"):
        raise ValueError("session must use isolated system Python")
    helper = extract_member(rpm, HELPER)
    policy = extract_member(rpm, POLICY)
    if not helper.startswith(b"#!/usr/bin/python3 -I\n"):
        raise ValueError("helper must use the isolated system Python interpreter")
    if re.search(rb"NOPASSWD\s*:", helper + policy):
        raise ValueError("helper payload must not introduce passwordless sudo")
    check_policy(policy)
    return {"helper": HELPER, "backend": BACKEND, "session": SESSION, "policy": POLICY,
            "ownership": {"user": "root", "group": "root"}, "ok": True}


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: check-helper-package.py RPM_PATH")
    print(json.dumps(check_package(Path(sys.argv[1]).resolve())))
