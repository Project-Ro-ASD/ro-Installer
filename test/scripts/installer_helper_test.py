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
import struct
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

    def loop_backing(self, number, path):
        return self.identities[self.infos[number]["backingFile"]]

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


class KiwiLiveSystem(FakeSystem):
    def __init__(self):
        super().__init__()
        fixture = json.loads((ROOT / "test/fixtures/helper_fedora44_kiwi_live.json").read_text())
        self.data = {"blockdevices": fixture["blockdevices"]}
        self.mountinfo = "\n".join(fixture["mountinfo"]) + "\n"
        self.swapinfo = fixture["swaps"]
        self.identities = fixture["identities"]
        self.infos = {number: self.info(**info) for number, info in fixture["sysfs"].items()}
        self.loop_devices = fixture["loopBacking"]

    def loop_backing(self, number, path):
        return self.loop_devices[number]


class KiwiLiveTopologyTests(ErrorAssertions, unittest.TestCase):
    def setUp(self):
        self.system = KiwiLiveSystem()

    def validate(self, path="/dev/vda"):
        return helper.validate_device(self.system, path)

    def test_pre_pivot_missing_filename_probe_accepts_blank_disk_without_mutation(self):
        with self.assertRaises(FileNotFoundError):
            self.system.path_identity("/LiveOS/squashfs.img")
        with mock.patch.object(helper.os, "geteuid", return_value=0), \
                mock.patch.object(helper.subprocess, "Popen") as spawn, \
                mock.patch.object(helper, "run_backend") as backend:
            data = helper.handle(helper.Request("probe-disk", "/dev/vda"), self.system)
            self.assertEqual(data, {"device":{"path":"/dev/vda","majorMinor":"253:0","size":68719476736,"diskSequence":1}})
            spawn.assert_not_called()
            backend.assert_not_called()
        self.assertEqual(helper.Topology(self.system).protected_devices(), {"7:0", "11:0", "252:0"})

    def test_live_root_iso_and_active_zram_targets_rejected(self):
        for path in ("/dev/loop0", "/dev/sr0", "/dev/zram0"):
            self.error("UNSAFE_DEVICE", self.validate, path)
        # Also protect a non-removable whole disk that contains the ISO image.
        self.system.loop_devices["7:0"] = "253:0"
        self.system.mountinfo += "36 31 253:0 / /media/source ro - ext4 /dev/vda ro\n"
        self.error("UNSAFE_DEVICE", self.validate)

    def test_mounted_or_root_target_rejected(self):
        self.system.mountinfo += "36 31 253:0 / /mnt rw - ext4 /dev/vda rw\n"
        self.error("UNSAFE_DEVICE", self.validate)
        self.system.mountinfo = "1 0 253:0 / / rw - ext4 /dev/vda rw\n"
        self.error("UNSAFE_DEVICE", self.validate)

    def test_missing_backing_overlay_or_sysfs_is_ambiguous_not_selected_absence(self):
        changes = [lambda s: s.loop_devices.update({"7:0":"11:99"}),
                   lambda s: s.identities.pop("/run/rootfsbase"),
                   lambda s: s.infos.pop("11:0"),
                   lambda s: s.infos["7:0"].update(backingFile=None),
                   lambda s: s.infos["7:0"].update(backingFile="/LiveOS/squashfs.img (deleted)"),
                   lambda s: setattr(s, "loop_backing", mock.Mock(side_effect=FileNotFoundError))]
        for change in changes:
            self.setUp()
            change(self.system)
            self.error("AMBIGUOUS_TOPOLOGY", self.validate)
        self.setUp()
        self.system.identities.pop("/dev/vda")
        self.error("DEVICE_NOT_FOUND", self.validate)

    def test_missing_or_spoofed_filename_cannot_override_kernel_backing_identity(self):
        self.system.identities["/LiveOS/squashfs.img"] = "253:0"
        self.assertEqual(self.validate().major_minor, "253:0")
        self.system.infos["7:0"]["backingFile"] = "/run/initramfs/live/nonexistent.img"
        self.assertEqual(self.validate().major_minor, "253:0")
        self.system.loop_devices["7:0"] = "0:99"
        self.error("AMBIGUOUS_TOPOLOGY", self.validate)

    def test_portal_exception_is_narrow_and_cannot_authorize_backing_storage(self):
        for old, new in (("fuse.portal", "fuse.sshfs"), ("fuse.portal portal", "fuse.portal unknown"),
                         ("/run/user/1000/doc", "/media/doc"), ("0:43", "8:43")):
            self.setUp()
            self.system.mountinfo = self.system.mountinfo.replace(old, new)
            self.error("AMBIGUOUS_TOPOLOGY", self.validate)
        self.setUp()
        self.system.loop_devices["7:0"] = "0:43"
        self.error("AMBIGUOUS_TOPOLOGY", self.validate)
        self.setUp()
        self.system.mountinfo = self.system.mountinfo.replace("lowerdir=/run/rootfsbase", "lowerdir=/run/user/1000/doc")
        self.system.identities["/run/user/1000/doc"] = "0:43"
        self.error("AMBIGUOUS_TOPOLOGY", self.validate)

    def test_cycles_btrfs_and_changed_disk_identity_remain_rejected(self):
        lock_type = helper.InstallerLock
        self.system.loop_devices["7:0"] = "7:0"
        self.error("AMBIGUOUS_TOPOLOGY", self.validate)
        self.setUp()
        self.system.mountinfo = self.system.mountinfo.replace("iso9660", "btrfs")
        self.error("AMBIGUOUS_TOPOLOGY", self.validate)
        for expected in ({"majorMinor":"253:0","size":68719476736,"diskSequence":2},
                         {"majorMinor":"253:0","size":68719476735,"diskSequence":1},
                         {"majorMinor":"253:1","size":68719476736,"diskSequence":1}):
            self.setUp()
            with tempfile.TemporaryDirectory() as td, mock.patch.object(helper.os, "geteuid", return_value=0), \
                    mock.patch.object(helper, "InstallerLock", side_effect=lambda: lock_type(td + "/lock", os.getuid())), \
                    mock.patch.object(helper, "run_backend") as backend:
                self.error("DEVICE_CHANGED", helper.handle,
                           helper.Request("install-full-disk", "/dev/vda", expected), self.system)
                backend.assert_not_called()


class LoopKernelIdentityTests(ErrorAssertions, unittest.TestCase):
    def status(self, major=11, minor=0, inode=77, rdevice=0, loop_number=0):
        raw = bytearray(232)
        device = (minor & 0xff) | (major << 8) | ((minor & ~0xff) << 12)
        struct.pack_into("=QQQ", raw, 0, device, inode, rdevice)
        struct.pack_into("=I", raw, 40, loop_number)
        return bytes(raw)

    def read(self, raw, *, mode=stat.S_IFBLK, rdev=None):
        with mock.patch.object(helper.os, "open", return_value=41) as opened, \
                mock.patch.object(helper.os, "close") as closed, \
                mock.patch.object(helper.os, "fstat", return_value=mock.Mock(st_mode=mode, st_rdev=rdev or os.makedev(7, 0))), \
                mock.patch.object(helper.fcntl, "ioctl", return_value=raw) as ioctl:
            try:
                return helper.System().loop_backing("7:0", "/dev/loop0")
            finally:
                opened.assert_called_once_with("/dev/loop0", os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK)
                closed.assert_called_once_with(41)
                if ioctl.called:
                    ioctl.assert_called_once_with(41, 0x4C05, bytes(232))

    def test_kernel_device_encoding_including_large_minor_and_readonly_ioctl(self):
        for major, minor in ((11, 0), (253, 0), (259, 65537), (0, 2000)):
            self.assertEqual(self.read(self.status(major, minor)), f"{major}:{minor}")

    def test_nonblock_mismatched_or_unsupported_loop_metadata_fails_closed(self):
        for raw in (self.status(inode=0), self.status(rdevice=1), self.status(loop_number=1)):
            self.error("AMBIGUOUS_TOPOLOGY", self.read, raw)
        self.error("AMBIGUOUS_TOPOLOGY", lambda: self.read(self.status(), mode=stat.S_IFREG))
        self.error("AMBIGUOUS_TOPOLOGY", lambda: self.read(self.status(), rdev=os.makedev(7, 1)))
        with mock.patch.object(helper.os, "open") as opened:
            self.error("AMBIGUOUS_TOPOLOGY", helper.System().loop_backing, "7:0", "/dev/alias")
            opened.assert_not_called()



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
            self.assertTrue(data["audit"]["installationImplemented"])
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
                with mock.patch.object(helper, "run_backend", return_value={"installed": True}) as backend:
                    self.assertEqual(helper.handle(parsed, system), {"installed": True})
                    backend.assert_called_once()
                    self.assertEqual(backend.call_args.args[1], original)
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


class BackendBridgeTests(ErrorAssertions, unittest.TestCase):
    prefix = "import json,sys\nrequest=json.loads(sys.stdin.readline())\n"
    ready = 'print(json.dumps({"protocolVersion":1,"type":"ready"}),flush=True)\ngate=json.loads(sys.stdin.readline())\n'
    success = 'print(json.dumps({"protocolVersion":1,"type":"result","ok":True,"code":"OK"}),flush=True)\n'

    def run_stub(self, body, system=None, emit=lambda _: None):
        system = system or FakeSystem()
        request = helper.parse_request(json.dumps(install_request()).encode())
        confirmed = helper.validate_device(FakeSystem(), request.disk)
        with tempfile.TemporaryDirectory() as td:
            script = Path(td, "backend.py")
            script.write_text(self.prefix + body)
            with mock.patch.object(helper, "BACKEND_ARGV", (sys.executable, "-I", str(script))):
                return helper.run_backend(request, confirmed, system, emit)

    def test_normalized_request_gate_and_explicit_success(self):
        body = self.ready + '''assert set(request)=={"protocolVersion","operation","disk","expectedDevice"}
assert request["disk"]==gate["device"]["path"]=="/dev/vda"
assert request["expectedDevice"]["diskSequence"]==gate["device"]["diskSequence"]==11
print(json.dumps({"protocolVersion":1,"type":"progress","stage":2,"progress":0.2,"messageKey":"install_stage_partitioning"}),flush=True)
''' + self.success
        events = []
        self.assertEqual(self.run_stub(body, emit=events.append), {"installed": True})
        self.assertEqual(events[0]["stage"], 2)

    def test_crash_eof_malformed_unknown_oversized_and_false_success_rejected(self):
        cases = ["sys.exit(1)", self.success,
                 "print('not-json',flush=True)",
                 'print(json.dumps({"protocolVersion":1,"type":"exec"}),flush=True)',
                 "print('x'*9000,flush=True)",
                 self.ready + self.success + "sys.exit(1)",
                 self.ready + self.success + self.success,
                 self.ready + self.success + "print('trailing',end='',flush=True)"]
        for body in cases:
            with self.subTest(body=body):
                self.error("BACKEND_ERROR", self.run_stub, body)

    def test_stage_failure_is_not_success(self):
        self.error("INSTALL_FAILED", self.run_stub, self.ready +
                   'print(json.dumps({"protocolVersion":1,"type":"result","ok":False,"code":"INSTALL_FAILED"}),flush=True)')

    def test_device_change_at_ready_never_authorizes_backend(self):
        system = FakeSystem()
        system.infos["252:0"]["diskSequence"] = 99
        self.error("DEVICE_CHANGED", self.run_stub, self.ready + self.success, system)

    def test_backend_watchdog_fails_closed(self):
        with mock.patch.object(helper, "BACKEND_TIMEOUT", 0.05):
            self.error("BACKEND_ERROR", self.run_stub, "import time; time.sleep(30)")

    def test_backend_crash_stops_remaining_stage_children(self):
        with tempfile.TemporaryDirectory() as td:
            pidfile = Path(td, "child.pid")
            body = self.ready + "import subprocess,os\n" + \
                "child=subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)\n" + \
                "open(" + repr(str(pidfile)) + ", 'w').write(str(child.pid))\nsys.exit(1)\n"
            self.error("BACKEND_ERROR", self.run_stub, body)
            pid = int(pidfile.read_text())
            # A reparented zombie is stopped and cannot continue disk writes.
            proc = Path("/proc", str(pid), "stat")
            for _ in range(100):
                if not proc.exists() or proc.read_text().split()[2] == "Z": break
                import time
                time.sleep(0.01)
            self.assertTrue(not proc.exists() or proc.read_text().split()[2] == "Z")

    def test_missing_backend_fails_closed(self):
        with mock.patch.object(helper, "BACKEND_ARGV", ("/nonexistent/ro-backend",)):
            request = helper.parse_request(json.dumps(install_request()).encode())
            self.error("BACKEND_ERROR", helper.run_backend, request,
                       helper.validate_device(FakeSystem(), request.disk), FakeSystem(), lambda _: None)

    def test_install_lock_held_through_backend_result(self):
        with tempfile.TemporaryDirectory() as td:
            directory = td + "/installer"
            real_lock = helper.InstallerLock
            script = Path(td, "backend.py")
            inherited = 'import os\nassert any(os.path.realpath("/proc/self/fd/"+n)=='+repr(directory + '/install.lock')+' for n in os.listdir("/proc/self/fd"))\n'
            script.write_text(self.prefix + inherited + self.ready +
                'print(json.dumps({"protocolVersion":1,"type":"progress","stage":2,"progress":0.1,"messageKey":"install_stage_partitioning"}),flush=True)\n' + self.success)
            events = []
            def emit(event):
                self.error("BUSY", real_lock(directory, os.getuid()).__enter__)
                events.append(event)
            with mock.patch.object(helper.os, "geteuid", return_value=0), \
                    mock.patch.object(helper, "InstallerLock", side_effect=lambda: real_lock(directory, os.getuid())), \
                    mock.patch.object(helper, "BACKEND_ARGV", (sys.executable, "-I", str(script))):
                self.assertEqual(helper.handle(helper.parse_request(json.dumps(install_request()).encode()), FakeSystem(), emit), {"installed": True})
            self.assertEqual(len(events), 1)
            with real_lock(directory, os.getuid()): pass


    @unittest.skipUnless(shutil.which("dart"), "Dart SDK unavailable for native-runtime lease test")
    def test_native_dart_backend_retains_lock_after_parent_releases_it(self):
        with tempfile.TemporaryDirectory() as td:
            binary = Path(td, "dart-lease")
            compiled = subprocess.run(["dart", "compile", "exe", str(ROOT / "test/fixtures/backend_lock_lease.dart"),
                                       "-o", str(binary)], capture_output=True, text=True, timeout=60)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            directory = td + "/installer"
            lock = helper.InstallerLock(directory, os.geteuid())
            with lock:
                process = subprocess.Popen([str(binary)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                           stderr=subprocess.PIPE, pass_fds=(lock.fd,))
                self.assertEqual(process.stdout.readline(), b"ready\n")
            try:
                # The helper's own descriptor is gone, but the native backend's
                # inherited descriptor still prevents a second installation.
                self.error("BUSY", helper.InstallerLock(directory, os.geteuid()).__enter__)
            finally:
                process.stdin.close()
                self.assertEqual(process.wait(timeout=5), 0)
                process.stdout.close()
                process.stderr.close()
            with helper.InstallerLock(directory, os.geteuid()): pass


class LauncherSessionTests(unittest.TestCase):
    def test_desktop_launches_user_gui_with_literal_args_and_session(self):
        source = (ROOT / "linux/ro-installer-launcher.sh").read_text()
        self.assertNotIn("pkexec", source)
        self.assertNotIn("sudo", source)
        self.assertIn("Exec=/usr/libexec/ro-installer-launcher.sh", (ROOT / "linux/ro-installer.desktop").read_text())
        with tempfile.TemporaryDirectory() as td:
            binary = Path(td, "gui")
            binary.write_text('#!/usr/bin/python3 -I\nimport os,sys,json\nprint(json.dumps({"uid":os.getuid(),"args":sys.argv[1:],"wayland":os.getenv("WAYLAND_DISPLAY"),"runtime":os.getenv("XDG_RUNTIME_DIR"),"theme":os.getenv("QT_QPA_PLATFORMTHEME")}))\n')
            binary.chmod(0o755)
            launcher = Path(td, "launcher")
            launcher.write_text(source.replace("BINARY=/usr/bin/ro-installer", "BINARY=" + str(binary)))
            args = ["--literal", "a b", "$(touch /tmp/never-run)", ";id"]
            result = subprocess.run(["bash", str(launcher), *args], text=True, capture_output=True,
                env=dict(os.environ, WAYLAND_DISPLAY="wayland-test", XDG_RUNTIME_DIR=td, QT_QPA_PLATFORMTHEME="kde"))
            self.assertEqual(result.returncode, 0)
            actual = json.loads(result.stdout)
            self.assertEqual(actual, {"uid":os.getuid(),"args":args,"wayland":"wayland-test","runtime":td,"theme":"kde"})
            binary.unlink()
            missing = subprocess.run(["bash", str(launcher)], text=True, capture_output=True)
            self.assertEqual(missing.returncode, 1)
            self.assertLess(len(missing.stderr), 256)

    def test_no_root_gui_or_generic_sudo_routing(self):
        main = (ROOT / "lib/main.dart").read_text()
        runner = (ROOT / "lib/services/command_runner.dart").read_text()
        installing = (ROOT / "lib/screens/installing_screen.dart").read_text()
        self.assertNotIn("RO_INSTALLER_COMMAND_SUDO", main + runner)
        self.assertNotIn("pkexec", main)
        self.assertNotIn("InstallService.instance.runInstall", installing)
        self.assertIn("HelperClient.instance.install", installing)


class PackagingTests(unittest.TestCase):
    @unittest.skipUnless(all(shutil.which(tool) for tool in ("dart", "rpmbuild", "rpm2cpio", "cpio")), "Dart/RPM tools unavailable")
    def test_native_backend_snapshot_survives_real_rpm_postprocessing(self):
        with tempfile.TemporaryDirectory() as td:
            top = Path(td)
            for directory in ("BUILD", "BUILDROOT", "RPMS", "SOURCES", "SPECS", "SRPMS", "tmp"):
                (top / directory).mkdir()
            backend = top / "SOURCES/backend"
            compiled = subprocess.run(["dart", "compile", "exe", "bin/privileged_backend.dart", "-o", str(backend)],
                                      cwd=ROOT, text=True, capture_output=True, timeout=120)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            shutil.copy2(ROOT / "scripts/strip-preserve-dart.sh", top / "SOURCES/strip-preserve-dart.sh")
            # Use the product's exact lazy strip macro and the real RPM hooks.
            strip_macro = next(line for line in (ROOT / "ro-installer.spec").read_text().splitlines()
                               if line.startswith("%define __strip "))
            spec = top / "SPECS/fixture.spec"
            spec.write_text(f'''Name: backend-snapshot-fixture
Version: 1
Release: 1
Summary: Dart backend RPM snapshot fixture
License: MIT
%global debug_package %{{nil}}
{strip_macro}
%description
Non-product native backend package fixture.
%prep
%setup -c -T -n backend-snapshot-fixture-1
mkdir scripts
cp %{{_sourcedir}}/strip-preserve-dart.sh scripts/
%install
install -Dm755 %{{_sourcedir}}/backend %{{buildroot}}{package.BACKEND}
%files
%attr(0755,root,root) {package.BACKEND}
''')
            built = subprocess.run(["rpmbuild", "-bb", "--define", f"_topdir {top}",
                                    "--define", f"_tmppath {top / 'tmp'}", str(spec)],
                                   text=True, capture_output=True, timeout=60)
            self.assertEqual(built.returncode, 0, built.stderr)
            rpm = next((top / "RPMS").rglob("*.rpm"))
            payload = package.extract_member(rpm, package.BACKEND)
            self.assertEqual(payload, backend.read_bytes(), "RPM changed the appended Dart snapshot")
            installed = top / "installed-backend"
            installed.write_bytes(payload)
            installed.chmod(0o755)
            result = subprocess.run([str(installed), "--privileged-backend-v1"],
                                    input='{"protocolVersion":999}\n', text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 9)
            self.assertEqual(result.stderr, "")
            self.assertEqual(json.loads(result.stdout), {
                "protocolVersion": 1, "type": "result", "ok": False, "code": "BACKEND_ERROR"})
            # Protection is restricted to the one buildroot path. Other files
            # still reach the system strip tool (which rejects this bad option).
            other = subprocess.run([str(ROOT / "scripts/strip-preserve-dart.sh"), "--invalid-strip-option", str(installed)],
                                   env=dict(os.environ, RPM_BUILD_ROOT=str(top)), capture_output=True)
            self.assertNotEqual(other.returncode, 0)

    def test_policy_and_explicit_spec_ownership(self):
        package.check_policy((ROOT / "linux/org.roasd.installer.helper.policy").read_bytes())
        spec = (ROOT / "ro-installer.spec").read_text()
        self.assertIn("%attr(0755,root,root) %{_libexecdir}/ro-installer-helper", spec)
        self.assertIn("%attr(0644,root,root) %{_datadir}/polkit-1/actions/org.roasd.installer.helper.policy", spec)
        self.assertIn("Requires:       python3", spec)
        self.assertNotIn("sudoers", spec)
        self.assertNotIn("NOPASSWD", spec)
        self.assertNotIn("%{_datadir}/polkit-1/actions/org.roasd.installer.policy", spec)
        self.assertFalse((ROOT / "linux/org.roasd.installer.policy").exists())
        self.assertIn("%attr(0755,root,root) %{_libexecdir}/ro-installer-backend", spec)

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
        self.assertEqual(len(process_calls), 2)
        self.assertEqual({call.args[0].id for call in process_calls}, {"LSBLK_ARGV", "BACKEND_ARGV"})
        for call in process_calls:
            self.assertEqual(call.func.attr, "Popen")
            self.assertFalse(any(keyword.arg == "shell" for keyword in call.keywords))
        self.assertEqual(helper.LSBLK_ARGV[0], "/usr/bin/lsblk")
        self.assertEqual(helper.BACKEND_ARGV, ("/usr/libexec/ro-installer-backend", "--privileged-backend-v1"))
        self.assertEqual(stat.S_IMODE((ROOT / "linux/ro-installer-helper").stat().st_mode), 0o755)

    @unittest.skipUnless(all(shutil.which(tool) for tool in ("rpmbuild", "rpm2cpio", "cpio")), "RPM tools unavailable")
    def test_real_rpm_payload_audit_and_wrong_mode_rejection(self):
        # Build small payload RPM fixtures, not a product release or a Flutter build.
        with tempfile.TemporaryDirectory() as td:
            top = Path(td)
            for directory in ("BUILD", "BUILDROOT", "RPMS", "SOURCES", "SPECS", "SRPMS", "tmp"):
                (top / directory).mkdir()
            (top / "SOURCES/backend").write_bytes(b"\x7fELFpayload-fixture")
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
install -Dm755 %{{_sourcedir}}/backend %{{buildroot}}{package.BACKEND}
install -Dm644 %{{_sourcedir}}/policy %{{buildroot}}{package.POLICY}
%files
%attr({mode},root,root) {package.HELPER}
%attr(0755,root,root) {package.BACKEND}
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
