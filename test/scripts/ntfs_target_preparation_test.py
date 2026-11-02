#!/usr/bin/env python3
"""Private target preparation: policy mocks and read-only temporary-file probes."""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from contextlib import ExitStack
from types import SimpleNamespace
from unittest import mock
import installer_helper_test as legacy

worker = legacy.load_module('ntfs_target_worker', legacy.ROOT/'linux/ro_installer_ntfs.py')
GIB = 1024**3
SIZE = 128*GIB
TARGET = 64*GIB
FINGERPRINT = 'a'*64
VERSION = b'ntfsresize v2026.9.28 (libntfs-3g)\nCopyright fixture\n'
PACKAGES = b'ntfsprogs|2|2026.9.28|1.fc44|x86_64\nntfs-3g-libs|2|2026.9.28|1.fc44|x86_64\n'


def inspection(size=SIZE, sector=512, minimum=32*GIB):
    return {'schemaVersion': 1, 'deviceBytes': size,
            'volumeBytes': ((size-sector)//4096)*4096+sector,
            'clusterBytes': 4096, 'minimumBytes': minimum,
            'inspectionFingerprint': FINGERPRINT}


def output(observed=None, target=TARGET, sector=512):
    observed = inspection() if observed is None else observed
    new = ((target-sector)//observed['clusterBytes'])*observed['clusterBytes']+sector
    return (f"Current device size: {observed['deviceBytes']} bytes (1 MB)\n"
            f"Current volume size: {observed['volumeBytes']} bytes (1 MB)\n"
            f"Cluster size: {observed['clusterBytes']} bytes\n"
            f'New volume size: {new} bytes (1 MB)\n'
            'The read-only test run ended successfully.\n').encode()


class PreparationTests(unittest.TestCase):
    def test_release_and_both_package_owners_must_match(self):
        self.assertEqual(worker.qualify_resize_toolchain(VERSION, PACKAGES),
                         {'version': '2026.9.28', 'epoch': 2, 'release': '1.fc44', 'arch': 'x86_64'})
        for version, packages in [
            (VERSION.replace(b'2026.9.28', old), PACKAGES.replace(b'2026.9.28', old))
            for old in (b'2026.2.25', b'2026.9.18', b'2026.2.30', b'2026.9.28-rc1')
        ] + [(VERSION+VERSION, PACKAGES), (b'', PACKAGES), (VERSION+b'\0', PACKAGES),
             (b'x'*4097, PACKAGES), (VERSION, b'x'*4097), (VERSION, PACKAGES+b'\0'),
             (VERSION, PACKAGES+PACKAGES), (VERSION, PACKAGES.splitlines()[0]+b'\n'),
             (VERSION, PACKAGES.replace(b'ntfsprogs|', b'unknown|')),
             (VERSION, PACKAGES.replace(b'x86_64', b'aarch64')),
             (VERSION, PACKAGES.replace(b'|2|', b'|02|')),
             (VERSION, PACKAGES.replace(b'|1.fc44|', b'|2.fc44|', 1)),
             (VERSION, PACKAGES.replace(b'2026.9.28', b'2026.10.1', 1)),
             (VERSION, PACKAGES.replace(b'|1.fc44|', b'|bad release|'))]:
            with self.subTest(version=version, packages=packages), self.assertRaises(ValueError):
                worker.qualify_resize_toolchain(version, packages)

    def test_target_output_requires_unique_exact_geometry_and_completion(self):
        for sector in (512, 4096):
            observed = inspection(sector=sector); raw = output(observed, sector=sector)
            worker.validate_resize_target_test(raw, observed, TARGET, sector)
            for bad in (raw+raw, raw+b'\0', b'x'*65537,
                        raw.replace(b'Current device size:', b'Other device size:'),
                        raw.replace(str(observed['volumeBytes']).encode(), b'1'),
                        raw.replace(b'Cluster size: 4096', b'Cluster size: 8192'),
                        raw.replace(b'New volume size:', b'Wrong volume size:'),
                        raw.replace(b'ended successfully.', b'failed.'),
                        output(observed, target=TARGET+1048576, sector=sector)):
                with self.assertRaises(ValueError):
                    worker.validate_resize_target_test(bad, observed, TARGET, sector)

    def prepare(self, fd, *, observed=None, target=TARGET, fingerprint=FINGERPRINT,
                boot=None, metadata=None, inspections=None, packages=None):
        observed = inspection() if observed is None else observed
        calls = []
        package_values = iter(packages or [PACKAGES, PACKAGES])
        def tool(kind, descriptor, **kwargs):
            calls.append((kind, descriptor, kwargs))
            if kind == 'resize-version': return VERSION
            if kind == 'resize-packages': return next(package_values)
            self.assertEqual((kind, descriptor, kwargs), ('resize-target', fd, {'target_bytes': target}))
            return output(observed, target=target)
        native = SimpleNamespace(metadata=mock.Mock(side_effect=metadata or [b'clean', b'clean']))
        with ExitStack() as stack:
            stack.enter_context(mock.patch.object(worker, 'run_tool', side_effect=tool))
            stack.enter_context(mock.patch.object(worker, 'inspect_fd', side_effect=inspections or [observed, observed]))
            stack.enter_context(mock.patch.object(worker, 'boot_sector', side_effect=boot or [(b'boot', 4096)]*2))
            stack.enter_context(mock.patch.object(worker, 'NativeNtfs', return_value=native))
            value = worker.prepare_resize_target(fd, SIZE, 512, target, fingerprint)
        return value, calls

    def test_qualified_preparation_has_distinct_stable_fingerprint_and_fixed_target(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td)/'source'; path.write_bytes(b'ordinary fixture'); fd = os.open(path, os.O_RDONLY)
            try:
                value, calls = self.prepare(fd)
                self.assertEqual(value, self.prepare(fd)[0])
                self.assertEqual(value['targetBytes'], TARGET)
                self.assertEqual(value['inspectionFingerprint'], FINGERPRINT)
                self.assertRegex(value['preparationFingerprint'], '^[0-9a-f]{64}$')
                self.assertNotEqual(value['preparationFingerprint'], FINGERPRINT)
                self.assertEqual([call[0] for call in calls],
                                 ['resize-version', 'resize-packages', 'resize-target', 'resize-version', 'resize-packages'])
                self.assertNotEqual(value, self.prepare(fd, target=TARGET+1048576)[0])
            finally: os.close(fd)

    def test_capacity_floor_headroom_stale_input_and_source_or_toolchain_drift_refuse(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td)/'source'; path.write_bytes(b'ordinary fixture'); fd = os.open(path, os.O_RDONLY)
            try:
                self.prepare(fd, observed=inspection(minimum=39*GIB), target=40*GIB)
                cases = [dict(target=40*GIB-1048576), dict(target=SIZE), dict(target=True),
                         dict(target=TARGET+1), dict(fingerprint='B'*64), dict(fingerprint='b'*64),
                         dict(observed=inspection(minimum=TARGET-GIB+1)),
                         dict(boot=[(b'before',4096),(b'after',4096)]),
                         dict(metadata=[b'clean',b'changed']),
                         dict(inspections=[inspection(), {**inspection(), 'inspectionFingerprint':'b'*64}]),
                         dict(packages=[PACKAGES, PACKAGES.replace(b'1.fc44',b'2.fc44')])]
                for kwargs in cases:
                    with self.subTest(kwargs=kwargs), self.assertRaises(ValueError): self.prepare(fd, **kwargs)
            finally: os.close(fd)
        with tempfile.TemporaryFile() as writable:
            with mock.patch.object(worker, 'run_tool') as tool:
                with self.assertRaises(ValueError):
                    worker.prepare_resize_target(writable.fileno(), SIZE, 512, TARGET, FINGERPRINT)
                tool.assert_not_called()

    def test_unqualified_toolchain_and_invalid_target_stop_before_source_probe(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td)/'source'; path.write_bytes(b'ordinary fixture'); fd = os.open(path, os.O_RDONLY)
            try:
                with mock.patch.object(worker, 'run_tool', side_effect=[
                        VERSION.replace(b'2026.9.28', b'2026.2.25'),
                        PACKAGES.replace(b'2026.9.28', b'2026.2.25')]), \
                     mock.patch.object(worker, 'inspect_fd') as inspect:
                    with self.assertRaises(ValueError):
                        worker.prepare_resize_target(fd, SIZE, 512, TARGET, FINGERPRINT)
                    inspect.assert_not_called()
                with mock.patch.object(worker, 'subprocess') as processes:
                    for target in (None, True, 0, 1048575, TARGET+1, worker.MAX_BYTES+1048576):
                        with self.assertRaises(ValueError):
                            worker.run_tool('resize-target', fd, target_bytes=target)
                    processes.Popen.assert_not_called()
            finally: os.close(fd)

    def test_version_and_package_children_receive_lease_but_no_source_descriptor(self):
        real_popen = subprocess.Popen
        calls = []
        with tempfile.TemporaryFile() as source, tempfile.TemporaryFile() as lease:
            def spawn(argv, **kwargs):
                calls.append((argv, kwargs))
                # Run harmless output through real pipes/select/wait; inspect the
                # fixed production argv before replacing only this child.
                return real_popen(['/usr/bin/printf', 'fixture'], **kwargs)
            proxy = SimpleNamespace(Popen=spawn, PIPE=subprocess.PIPE, DEVNULL=subprocess.DEVNULL)
            with mock.patch.object(worker, 'subprocess', proxy), \
                 mock.patch.dict(os.environ, {'RO_INSTALLER_LEASE_FD':str(lease.fileno())}):
                worker.run_tool('resize-version', source.fileno())
                worker.run_tool('resize-packages', source.fileno())
                worker.run_tool('resize-target', source.fileno(), target_bytes=TARGET)
            self.assertEqual(calls[0][0], ('/usr/bin/ntfsresize','--version'))
            self.assertEqual(calls[1][0], ('/usr/bin/rpm','-qf','--qf',
                '%{NAME}|%{EPOCHNUM}|%{VERSION}|%{RELEASE}|%{ARCH}\n', '/usr/bin/ntfsresize',worker.LIBRARY))
            self.assertEqual(calls[2][0], ('/usr/bin/ntfsresize','--no-action','-P','--size',str(TARGET),
                                         f'/proc/self/fd/{source.fileno()}'))
            self.assertEqual([call[1]['pass_fds'] for call in calls],
                [(lease.fileno(),), (lease.fileno(),), tuple(sorted((source.fileno(),lease.fileno())))])
            for _, kwargs in calls:
                self.assertEqual(kwargs['env'], {'PATH':'/usr/sbin:/usr/bin','LC_ALL':'C'})

    def test_native_target_probe_on_new_regular_images_preserves_every_byte(self):
        # This tests --no-action semantics only. The installed old release is
        # deliberately not qualified for future writes by the policy above.
        for sector in (512, 4096):
            with tempfile.TemporaryDirectory() as td:
                path = Path(td)/'new-regular.img'; size = 512*1024**2; target = 256*1024**2
                with path.open('xb') as stream: stream.truncate(size)
                subprocess.run(['/usr/bin/mkntfs','-F','-Q','-s',str(sector),'-c','4096',str(path)],
                               capture_output=True, check=True, timeout=20)
                with path.open('rb') as stream: before = hashlib.file_digest(stream,'sha256').hexdigest()
                fd = os.open(path, os.O_RDONLY|os.O_CLOEXEC)
                try:
                    observed = worker.inspect_fd(fd,size,sector)
                    raw = worker.run_tool('resize-target',fd,target_bytes=target)
                    worker.validate_resize_target_test(raw,observed,target,sector)
                    self.assertEqual(worker.inspect_fd(fd,size,sector), observed)
                    with path.open('rb') as stream:
                        self.assertEqual(hashlib.file_digest(stream,'sha256').hexdigest(), before)
                finally: os.close(fd)


if __name__ == '__main__': unittest.main()
