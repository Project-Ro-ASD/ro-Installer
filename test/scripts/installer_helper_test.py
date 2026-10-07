#!/usr/bin/env python3
"""Protocol, authoritative storage guards and real process/RPM boundary tests."""

import ast
import copy
import importlib.machinery
import importlib.util
import json
import multiprocessing
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]


def load_module(name, path):
    loader = importlib.machinery.SourceFileLoader(name, str(path))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    loader.exec_module(module)
    return module


helper = load_module("installer_helper", ROOT / "linux/ro-installer-helper")
package = load_module("helper_package", ROOT / "scripts/check-helper-package.py")


def request(operation="audit-live", **extra):
    return {"protocolVersion": 1, "operation": operation, **extra}


def install_request(**extra):
    return request("install-full-disk", disk="/dev/vda", partitionMethod="full",
                   fileSystem="btrfs", confirmDestructive=True,
                   expectedDevice={"majorMinor": "252:0", "size": 68719476736, "diskSequence": 11},
                   **extra)


class FakeSystem:
    def __init__(self):
        self.data = json.loads((ROOT / "test/fixtures/helper_blank_virtio.json").read_text())
        self.mountinfo = "1 0 8:1 / / rw - ext4 /dev/sda1 rw\n2 1 0:2 / /run rw - tmpfs tmpfs rw\n"
        self.swapinfo = "Filename Type Size Used Priority\n"
        self.identities = {"/dev/vda": "252:0", "/dev/sda": "8:0", "/dev/sda1": "8:1"}
        self.nonblock = set()
        self.infos = {
            "252:0": self.info("vda", 68719476736, sequence=11),
            "8:0": self.info("sda", 137438953472, sequence=12),
            "8:1": self.info("sda/sda1", 136365211648, parents={"8:0"}, partition=True),
        }
        self.supported = True

    @staticmethod
    def info(name, size, parents=None, partition=False, sequence=None, backing=None):
        return {"path": "/sys/devices/fixture/block/" + name, "size": size,
                "parents": parents or set(), "partition": partition,
                "diskSequence": sequence, "backingFile": backing}

    def lsblk(self):
        return copy.deepcopy(self.data)

    def mounts(self):
        return self.mountinfo

    def swaps(self):
        return self.swapinfo

    def path_identity(self, path, *, block=False):
        if path in self.nonblock and block:
            helper.fail("NOT_BLOCK_DEVICE", "Not a block device.")
        if path not in self.identities:
            raise FileNotFoundError(path)
        return self.identities[path]

    def sysfs(self, number):
        return copy.deepcopy(self.infos[number])

    def platform_supported(self):
        return self.supported

    def audit(self):
        return {"installationImplemented": False}

    def add_child(self, parent, name, number, kind="part", mount=None):
        node = {"name": name, "type": kind, "maj:min": number, "size": 1073741824,
                "pkname": parent["name"], "ro": False, "rm": False}
        parent.setdefault("children", []).append(node)
        self.identities[name] = number
        self.infos[number] = self.info(name[5:], node["size"], parents={parent["maj:min"]}, partition=kind == "part")
        if mount:
            self.mountinfo += f"3 1 {number} / {mount} rw - ext4 {name} rw\n"
        return node


class ErrorAssertions:
    def error(self, code, function, *args):
        with self.assertRaises(helper.HelperError) as caught:
            function(*args)
        self.assertEqual(caught.exception.code, code)


class ProtocolTests(ErrorAssertions, unittest.TestCase):
    def parse(self, data):
        return helper.parse_request(json.dumps(data).encode())

    def test_audit_and_probe_accepted(self):
        self.assertEqual(self.parse(request()).operation, "audit-live")
        self.assertEqual(self.parse(request("probe-disk", disk="/dev/vda")).disk, "/dev/vda")

    def test_install_schema_accepted_but_never_success(self):
        self.assertEqual(self.parse(install_request()).operation, "install-full-disk")

    def test_unknown_protocol_operation_and_exec_rejected(self):
        for data in ({"protocolVersion": version, "operation": "audit-live"} for version in (0, 2, True, "1", None)):
            self.error("INVALID_REQUEST", self.parse, data)
        for operation in ("exec", "sh", "", None, [], {}):
            self.error("INVALID_REQUEST", self.parse, request(operation))

    def test_unknown_security_sensitive_fields_all_operations(self):
        for base in (request(), request("probe-disk", disk="/dev/vda"), install_request()):
            for key in ("command", "shell", "argv", "source", "destination", "chroot", "environment", "UID", "vmTestMode"):
                with self.subTest(operation=base["operation"], field=key):
                    self.error("INVALID_REQUEST", self.parse, dict(base, **{key: "$(touch /tmp/injected)"}))

    def test_malformed_duplicate_trailing_and_oversized_json(self):
        for raw in (b"{", b"[]", b"null", b"\xff", b"{}{}", b'{"protocolVersion":1,"protocolVersion":1}',
                    b'{"protocolVersion":NaN}', b"[" * 2000):
            self.error("INVALID_REQUEST", helper.parse_request, raw)
        self.error("REQUEST_TOO_LARGE", helper.parse_request, b" " * (helper.MAX_REQUEST_BYTES + 1))

    def test_install_requires_full_btrfs_confirmation_and_identity(self):
        for key, value in (("partitionMethod", "manual"), ("fileSystem", "ext4"), ("confirmDestructive", 1),
                           ("expectedDevice", {}), ("expectedDevice", {"majorMinor": "252:0", "size": True, "diskSequence": 1})):
            data = install_request()
            data[key] = value
            self.error("INVALID_REQUEST", self.parse, data)
        data = install_request()
        data["expectedDevice"]["command"] = "sh"
        self.error("INVALID_REQUEST", self.parse, data)

    def test_option_path_and_shell_injections_rejected(self):
        for path in ("--help", "/tmp/disk", "/dev/../etc/passwd", "/dev/vda;id", "/dev/$(id)", "/dev/vda\x00", "/dev/vda\n"):
            self.error("INVALID_REQUEST", self.parse, request("probe-disk", disk=path))

    def test_real_cli_machine_output_and_uid_environment_is_not_authority(self):
        result = subprocess.run([str(ROOT / "linux/ro-installer-helper")], input=json.dumps(request()),
                                text=True, capture_output=True, env=dict(os.environ, UID="0", PYTHONPATH="/tmp", RO_INSTALLER_AUTO_PROFILE="/tmp/evil"))
        data = json.loads(result.stdout)
        self.assertEqual(result.stderr, "")
        if os.geteuid() == 0:
            self.assertEqual(result.returncode, 0)
            self.assertFalse(data["audit"]["installationImplemented"])
        else:
            self.assertEqual(result.returncode, 3)
            self.assertEqual(data["error"]["code"], "ROOT_REQUIRED")

    def test_stdin_deadline_and_limit(self):
        read_fd, write_fd = os.pipe()
        try:
            with mock.patch.object(helper, "REQUEST_TIMEOUT", 0.01):
                self.error("REQUEST_TIMEOUT", helper.read_request, read_fd)
        finally:
            os.close(read_fd)
            os.close(write_fd)
        with tempfile.TemporaryFile() as stream:
            stream.write(b" " * (helper.MAX_REQUEST_BYTES + 1))
            stream.seek(0)
            self.error("REQUEST_TOO_LARGE", helper.read_request, stream.fileno())


class DeviceTests(ErrorAssertions, unittest.TestCase):
    def setUp(self):
        self.system = FakeSystem()

    def validate(self, path="/dev/vda"):
        return helper.validate_device(self.system, path)

    def test_blank_virtio_identity(self):
        device = self.validate().public()
        self.assertEqual(device, {"path": "/dev/vda", "majorMinor": "252:0", "size": 68719476736, "diskSequence": 11})

    def test_partition_rejected(self):
        self.system.add_child(self.system.data["blockdevices"][0], "/dev/vda1", "252:1")
        self.error("UNSAFE_DEVICE", self.validate, "/dev/vda1")

    def test_root_disk_rejected(self):
        self.error("UNSAFE_DEVICE", self.validate, "/dev/sda")

    def test_mounted_partition_and_mapped_ancestor_rejected(self):
        for kind in ("part", "lvm"):
            self.setUp()
            self.system.add_child(self.system.data["blockdevices"][0], "/dev/dm-0", "253:0", kind, "/protected")
            self.error("UNSAFE_DEVICE", self.validate)

    def test_missing_and_nonblock_paths(self):
        self.error("DEVICE_NOT_FOUND", self.validate, "/dev/missing")
        self.system.nonblock.add("/dev/vda")
        self.error("NOT_BLOCK_DEVICE", self.validate)

    def test_ambiguous_topology_fail_closed(self):
        cases = [lambda s: s.data.update(blockdevices=None),
                 lambda s: s.data["blockdevices"][0].update(children=None),
                 lambda s: s.data["blockdevices"][0].update(size=123),
                 lambda s: s.infos["8:1"].update(parents=set()),
                 lambda s: setattr(s, "mountinfo", "garbage"),
                 lambda s: setattr(s, "mountinfo", "1 0 0:3 / / rw - mystery mystery rw\n")]
        for change in cases:
            self.setUp()
            change(self.system)
            self.error("AMBIGUOUS_TOPOLOGY", self.validate)

    def test_readonly_removable_alias_and_missing_sequence_rejected(self):
        for field in ("ro", "rm"):
            self.setUp()
            self.system.data["blockdevices"][0][field] = True
            self.error("UNSAFE_DEVICE", self.validate)
        self.setUp()
        self.system.identities["/dev/alias"] = "252:0"
        self.error("UNSAFE_DEVICE", self.validate, "/dev/alias")
        self.system.infos["252:0"]["diskSequence"] = None
        self.error("AMBIGUOUS_TOPOLOGY", self.validate)

    def test_overlay_loop_live_backing_disk_rejected(self):
        parent = self.system.data["blockdevices"][0]
        self.system.add_child(parent, "/dev/vda1", "252:1")
        self.system.data["blockdevices"].append({"name": "/dev/loop0", "type": "loop", "maj:min": "7:0",
                                                "size": 1073741824, "pkname": None, "ro": True, "rm": False})
        self.system.infos["7:0"] = self.system.info("loop0", 1073741824, backing="/run/initramfs/live/root.img")
        self.system.identities.update({"/dev/loop0": "7:0", "/run/lower": "7:0", "/run/initramfs/live/root.img": "252:1"})
        self.system.mountinfo = ("1 0 0:3 / / rw - overlay overlay rw,lowerdir=/run/lower\n"
                                 "2 1 7:0 / /run/lower ro - squashfs /dev/loop0 ro\n"
                                 "3 1 252:1 / /run/initramfs/live ro - ext4 /dev/vda1 ro\n")
        self.error("UNSAFE_DEVICE", self.validate)

    def test_btrfs_mount_membership_fails_closed(self):
        self.system.mountinfo = "1 0 0:32 / / rw - btrfs /dev/sda1 rw\n"
        # A mount source alone cannot prove all members of multi-device Btrfs.
        self.error("AMBIGUOUS_TOPOLOGY", self.validate)
        self.error("AMBIGUOUS_TOPOLOGY", self.validate, "/dev/sda")

    def test_active_swap_rejected(self):
        self.system.swapinfo += "/dev/vda partition 1024 0 -2\n"
        self.error("UNSAFE_DEVICE", self.validate)

    def test_cyclic_or_conflicting_tree_rejected(self):
        self.system.data["blockdevices"][0]["pkname"] = "/dev/vda"
        self.system.infos["252:0"]["parents"] = {"252:0"}
        self.error("UNSAFE_DEVICE", self.validate)
        self.setUp()
        duplicate = copy.deepcopy(self.system.data["blockdevices"][0])
        duplicate["size"] = 1
        self.system.data["blockdevices"].append(duplicate)
        self.error("AMBIGUOUS_TOPOLOGY", self.validate)


def lock_worker(directory, connection):
    with helper.InstallerLock(directory, os.geteuid()):
        connection.send("locked")
        connection.recv()


class LockAndGateTests(ErrorAssertions, unittest.TestCase):
    def test_concurrent_process_fails_closed(self):
        with tempfile.TemporaryDirectory() as td:
            directory = td + "/installer"
            context = multiprocessing.get_context("fork")
            parent, child = context.Pipe()
            worker = context.Process(target=lock_worker, args=(directory, child))
            worker.start()
            try:
                self.assertTrue(parent.poll(5))
                self.assertEqual(parent.recv(), "locked")
                self.error("BUSY", helper.InstallerLock(directory, os.geteuid()).__enter__)
                parent.send("release")
                worker.join(5)
                self.assertEqual(worker.exitcode, 0)
                with helper.InstallerLock(directory, os.geteuid()):
                    self.assertTrue(Path(directory, "install.lock").exists())
            finally:
                if worker.is_alive():
                    worker.terminate()
                    worker.join(5)
                parent.close()
                child.close()

    def test_symlink_and_unsafe_lock_modes_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            directory = Path(td, "installer")
            directory.mkdir(mode=0o700)
            lock = directory / "install.lock"
            lock.symlink_to(Path(td, "other"))
            with self.assertRaises(OSError):
                with helper.InstallerLock(str(directory), os.geteuid()):
                    pass
            lock.unlink()
            lock.touch(mode=0o666)
            lock.chmod(0o666)
            self.error("UNSAFE_LOCK", helper.InstallerLock(str(directory), os.geteuid()).__enter__)

    def test_install_checks_expected_and_repeated_identity_without_mutation(self):
        system = FakeSystem()
        parsed = helper.parse_request(json.dumps(install_request()).encode())
        original = helper.validate_device(system, parsed.disk)
        with tempfile.TemporaryDirectory() as td:
            real_lock = helper.InstallerLock
            with mock.patch.object(helper.os, "geteuid", return_value=0), \
                    mock.patch.object(helper, "InstallerLock", side_effect=lambda: real_lock(td + "/installer", os.getuid())):
                self.error("NOT_IMPLEMENTED", helper.handle, parsed, system)
                for changed in (helper.dataclasses.replace(original, size=original.size + 512),
                                helper.dataclasses.replace(original, disk_sequence=99)):
                    with mock.patch.object(helper, "validate_device", side_effect=[original, changed]) as validator:
                        self.error("DEVICE_CHANGED", helper.handle, parsed, system)
                        self.assertEqual(validator.call_count, 2)
                stale = helper.dataclasses.replace(parsed, expected_device=dict(parsed.expected_device, diskSequence=1))
                self.error("DEVICE_CHANGED", helper.handle, stale, system)

    def test_root_and_platform_gates(self):
        with mock.patch.object(helper.os, "geteuid", return_value=1000):
            self.error("ROOT_REQUIRED", helper.handle, helper.Request("audit-live"), FakeSystem())
        system = FakeSystem()
        system.supported = False
        with mock.patch.object(helper.os, "geteuid", return_value=0):
            self.error("UNSUPPORTED_PLATFORM", helper.handle, helper.parse_request(json.dumps(install_request()).encode()), system)


class PackagingTests(unittest.TestCase):
    def test_policy_and_explicit_spec_ownership(self):
        package.check_policy((ROOT / "linux/org.roasd.installer.helper.policy").read_bytes())
        spec = (ROOT / "ro-installer.spec").read_text()
        self.assertIn("%attr(0755,root,root) %{_libexecdir}/ro-installer-helper", spec)
        self.assertIn("%attr(0644,root,root) %{_datadir}/polkit-1/actions/org.roasd.installer.helper.policy", spec)
        self.assertIn("Requires:       python3", spec)
        self.assertNotIn("sudoers", spec)
        self.assertNotIn("NOPASSWD", spec)
        self.assertIn("%{_datadir}/polkit-1/actions/org.roasd.installer.policy", spec)

    def test_policy_rejects_broad_path_and_retained_authorization(self):
        raw = (ROOT / "linux/org.roasd.installer.helper.policy").read_bytes()
        for bad in (raw.replace(b"/usr/libexec/ro-installer-helper", b"/usr/bin/python3"),
                    raw.replace(b"auth_admin", b"auth_admin_keep")):
            with self.assertRaises(ValueError):
                package.check_policy(bad)

    def test_helper_has_only_fixed_readonly_process_api(self):
        source = (ROOT / "linux/ro-installer-helper").read_text()
        tree = ast.parse(source)
        process_calls = []
        for node in ast.walk(tree):
            if isinstance(node, ast.Call):
                if isinstance(node.func, ast.Name):
                    self.assertNotIn(node.func.id, {"eval", "exec", "compile", "__import__"})
                if isinstance(node.func, ast.Attribute):
                    self.assertNotIn(node.func.attr, {"system", "popen", "execv", "execve", "spawnv"})
                    if isinstance(node.func.value, ast.Name) and node.func.value.id == "subprocess":
                        process_calls.append(node)
        self.assertEqual(len(process_calls), 1)
        call = process_calls[0]
        self.assertEqual(call.func.attr, "Popen")
        self.assertEqual(call.args[0].id, "LSBLK_ARGV")
        self.assertFalse(any(keyword.arg == "shell" for keyword in call.keywords))
        self.assertEqual(helper.LSBLK_ARGV[0], "/usr/bin/lsblk")
        self.assertEqual(stat.S_IMODE((ROOT / "linux/ro-installer-helper").stat().st_mode), 0o755)

    @unittest.skipUnless(all(shutil.which(tool) for tool in ("rpmbuild", "rpm2cpio", "cpio")), "RPM tools unavailable")
    def test_real_rpm_payload_audit_and_wrong_mode_rejection(self):
        # Build small payload RPM fixtures, not a product release or a Flutter build.
        with tempfile.TemporaryDirectory() as td:
            top = Path(td)
            for directory in ("BUILD", "BUILDROOT", "RPMS", "SOURCES", "SPECS", "SRPMS", "tmp"):
                (top / directory).mkdir()
            shutil.copy2(ROOT / "linux/ro-installer-helper", top / "SOURCES/helper")
            shutil.copy2(ROOT / "linux/org.roasd.installer.helper.policy", top / "SOURCES/policy")
            for release, mode in (("1", "0755"), ("2", "0777")):
                spec = top / "SPECS/fixture.spec"
                spec.write_text(f'''Name: helper-payload-fixture
Version: 1
Release: {release}
Summary: Helper package boundary fixture
License: MIT
BuildArch: noarch
%description
Non-product package fixture.
%install
install -Dm755 %{{_sourcedir}}/helper %{{buildroot}}{package.HELPER}
install -Dm644 %{{_sourcedir}}/policy %{{buildroot}}{package.POLICY}
%files
%attr({mode},root,root) {package.HELPER}
%attr(0644,root,root) {package.POLICY}
''')
                built = subprocess.run(["rpmbuild", "-bb", "--define", f"_topdir {top}",
                                        "--define", f"_tmppath {top / 'tmp'}", str(spec)],
                                       text=True, capture_output=True, timeout=60)
                self.assertEqual(built.returncode, 0, built.stderr)
                rpm = next((top / "RPMS").rglob(f"*-1-{release}*.rpm"))
                if mode == "0755":
                    self.assertTrue(package.check_package(rpm)["ok"])
                else:
                    with self.assertRaises(ValueError):
                        package.check_package(rpm)


if __name__ == "__main__":
    unittest.main()
