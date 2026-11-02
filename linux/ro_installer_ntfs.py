#!/usr/bin/python3 -I
"""Private read-only NTFS inspection primitive; not installation admission."""
import ctypes as c
import datetime
import fcntl
import hashlib
import json
import os
import re
import resource
import select
import signal
import stat
import struct
import subprocess
import sys
import time

LIBRARY = '/usr/lib64/libntfs-3g.so.89'
MAX_BYTES = 8 * 1024**4
RO_FORENSIC = 0x04000001
sys.dont_write_bytecode = True
FILLDIR = c.CFUNCTYPE(c.c_int, c.c_void_p, c.c_void_p, c.c_int, c.c_int, c.c_int64, c.c_uint64, c.c_uint)


def boot_sector(fd, size, sector):
    if type(size) is not int or not 1024**2 <= size <= MAX_BYTES or sector not in (512, 4096) or size % sector:
        raise ValueError('Unsupported NTFS geometry')
    raw = os.pread(fd, sector, 0)
    if (len(raw) != sector or raw[3:11] != b'NTFS    ' or raw[510:512] != b'\x55\xaa'
            or struct.unpack_from('<H', raw, 11)[0] != sector):
        raise ValueError('NTFS boot sector required')
    clusters = raw[13]
    total, mft, mirror = struct.unpack_from('<QQQ', raw, 40)
    if (not clusters or clusters & (clusters - 1) or not 512 <= clusters * sector <= 65536
            or (total + 1) * sector != size or not 0 < mft < total // clusters
            or not 0 < mirror < total // clusters or mft == mirror
            or os.pread(fd, sector, size - sector) != raw):
        raise ValueError('Unsupported NTFS extent or backup boot sector')
    return raw, clusters * sector


def resized_boot_sector(fd, original_size, target_bytes, sector, original_boot):
    """Read only: validate the exact decimal-size ntfsresize boot geometry.

    The kernel partition still has its old size until a later GPT transaction.
    This is not initial eligibility, filesystem mutation or write admission.
    """
    if (type(original_size) is not int or type(target_bytes) is not int
            or not 1048576 <= target_bytes < original_size <= MAX_BYTES
            or sector not in (512, 4096) or original_size % sector or target_bytes % 1048576
            or not isinstance(original_boot, bytes) or len(original_boot) != sector
            or original_boot[3:11] != b'NTFS    ' or original_boot[510:512] != b'\x55\xaa'
            or struct.unpack_from('<H', original_boot, 11)[0] != sector):
        raise ValueError('Invalid original NTFS geometry')
    units = original_boot[13]; cluster = units * sector
    old_total, old_mft, old_mirror = struct.unpack_from('<QQQ', original_boot, 40)
    if (not units or units & (units - 1) or not 512 <= cluster <= 65536
            or (old_total + 1) * sector != original_size
            or not 0 < old_mft < old_total // units or not 0 < old_mirror < old_total // units
            or old_mft == old_mirror):
        raise ValueError('Invalid original NTFS extent')
    current = os.pread(fd, sector, 0)
    if len(current) != sector:
        raise ValueError('Short resized NTFS boot sector')
    masked = []
    for raw in (original_boot, current):
        protected = bytearray(raw); protected[40:64] = bytes(24); masked.append(protected)
    if masked[0] != masked[1]:
        raise ValueError('Protected NTFS boot fields changed')
    total, mft, mirror = struct.unpack_from('<QQQ', current, 40)
    clusters = (target_bytes - sector) // cluster
    if (total != clusters * units or not 0 < mft < clusters or not 0 < mirror < clusters
            or mft == mirror or os.pread(fd, sector, target_bytes - sector) != current):
        raise ValueError('Resized NTFS extent or backup mismatch')
    return current, cluster


def resized_volume_information(raw):
    # ntfsresize schedules Windows chkdsk. No other volume flags are admitted.
    if len(raw) != 12 or raw[:8] != bytes(8) or raw[8:10] != b'\x03\x01' or raw[10:12] != b'\x01\x00':
        raise ValueError('Unexpected post-resize NTFS volume state')


def volume_information(raw):
    if len(raw) != 12 or raw[:8] != bytes(8) or raw[8:10] != b'\x03\x01' or raw[10:12] != bytes(2):
        raise ValueError('Only clean NTFS 3.1 volume metadata is supported')


def hibernation_header(raw):
    if len(raw) != 4096 or raw != bytes(4096):
        raise ValueError('Unknown or active hibernation header')


def restart_header(raw):
    """Version filter after libntfs-3g has validated the restart page."""
    if len(raw) != 32 or raw[:4] != b'RSTR' or struct.unpack_from('<hh', raw, 26) != (1, 1):
        raise ValueError('Unsupported or cached NTFS journal')


class NativeNtfs:
    """Only stable exported ABI functions; no native volume-struct dereferences."""
    def __init__(self):
        if sys.byteorder != 'little' or c.sizeof(c.c_void_p) != 8:
            raise ValueError('Unsupported NTFS library ABI')
        self.lib = c.CDLL(LIBRARY, use_errno=True)
        def bind(name, args, result):
            fn = getattr(self.lib, name); fn.argtypes = args; fn.restype = result
            return fn
        self.mount = bind('ntfs_mount', [c.c_char_p, c.c_ulong], c.c_void_p)
        self.unmount = bind('ntfs_umount', [c.c_void_p, c.c_int], c.c_int)
        self.shown = bind('ntfs_set_shown_files', [c.c_void_p, c.c_int, c.c_int, c.c_int], c.c_int)
        self.inode = bind('ntfs_inode_open', [c.c_void_p, c.c_uint64], c.c_void_p)
        self.close_inode = bind('ntfs_inode_close', [c.c_void_p], c.c_int)
        self.readdir = bind('ntfs_readdir', [c.c_void_p, c.POINTER(c.c_int64), c.c_void_p, FILLDIR], c.c_int)
        self.attribute = bind('ntfs_attr_open', [c.c_void_p, c.c_uint32, c.c_void_p, c.c_uint32], c.c_void_p)
        self.close_attribute = bind('ntfs_attr_close', [c.c_void_p], None)
        self.read_attribute = bind('ntfs_attr_pread', [c.c_void_p, c.c_int64, c.c_int64, c.c_void_p], c.c_int64)
        self.check_log = bind('ntfs_check_logfile', [c.c_void_p, c.POINTER(c.c_void_p)], c.c_int)
        self.clean_log = bind('ntfs_is_logfile_clean', [c.c_void_p, c.c_void_p], c.c_int)
        bind('ntfs_log_set_levels', [c.c_uint32], c.c_uint32)(0)
        bind('ntfs_log_set_handler', [c.c_void_p], None)(c.cast(self.lib.ntfs_log_handler_null, c.c_void_p))
        self.unnamed = c.addressof(c.c_uint16.in_dll(self.lib, 'AT_UNNAMED'))
        libc = c.CDLL(None)
        self.free = libc.free; self.free.argtypes = [c.c_void_p]; self.free.restype = None

    def read(self, inode, kind, count):
        attr = self.attribute(inode, kind, self.unnamed, 0)
        if not attr:
            raise ValueError('NTFS attribute unavailable')
        try:
            buffer = c.create_string_buffer(count)
            if self.read_attribute(attr, 0, count, buffer) != count:
                raise ValueError('NTFS attribute truncated')
            return buffer.raw
        finally:
            self.close_attribute(attr)

    def hibernation(self, volume):
        inode = self.inode(volume, 10)  # $UpCase, not Python/host Unicode rules.
        if not inode:
            raise ValueError('NTFS case mapping unavailable')
        try:
            raw_upcase = self.read(inode, 0x80, 131072)
        finally:
            if self.close_inode(inode) != 0:
                raise ValueError('NTFS case mapping close failed')
        upcase = struct.unpack('<65536H', raw_upcase)
        if any(upcase[upcase[n]] != upcase[n] for n in range(65536)) or any(upcase[n] != n - 32 for n in range(97, 123)) or any(upcase[n] != n for n in range(65, 91)) or upcase[46] != 46:
            raise ValueError('Unsupported NTFS case mapping')
        target = tuple(upcase[n] for n in b'hiberfil.sys')
        root = self.inode(volume, 5)
        if not root:
            raise ValueError('NTFS root directory unavailable')
        matches = set(); count = 0; invalid = False
        @FILLDIR
        def visit(_context, name, length, _name_type, _position, reference, kind):
            nonlocal count, invalid
            try:
                count += 1
                if count > 4096 or not name or not 1 <= length <= 255:
                    invalid = True; return -1
                if length == len(target):
                    units = struct.unpack('<12H', c.string_at(name, 24))
                    if tuple(upcase[n] for n in units) == target:
                        if kind != 8 or reference == 2**64-1 or (reference & (2**48-1)) < 16:
                            invalid = True; return -1
                        matches.add(reference)
                        if len(matches) > 1:
                            invalid = True; return -1
                return 0
            except BaseException:
                invalid = True; return -1  # Never let an exception cross C.
        try:
            position = c.c_int64(0)
            if self.readdir(root, c.byref(position), None, visit) != 0 or invalid:
                raise ValueError('Ambiguous or oversized NTFS root inventory')
        finally:
            if self.close_inode(root) != 0:
                raise ValueError('NTFS root directory close failed')
        mapping = hashlib.sha256(raw_upcase).digest()
        if not matches:
            return mapping + b'absent'
        reference = next(iter(matches))
        inode = self.inode(volume, reference & (2**48-1))
        if not inode:
            raise ValueError('NTFS hibernation metadata unavailable')
        try:
            hibernation_header(self.read(inode, 0x80, 4096))
            return mapping + b'zero-header' + struct.pack('<Q', reference)
        finally:
            if self.close_inode(inode) != 0:
                raise ValueError('NTFS hibernation metadata close failed')

    def metadata(self, fd):
        return self._metadata(fd, volume_information)

    def resized_metadata(self, fd):
        return self._metadata(fd, resized_volume_information)

    def _metadata(self, fd, check_volume):
        volume = self.mount(f'/proc/self/fd/{fd}'.encode(), RO_FORENSIC)
        if not volume:
            raise ValueError('Read-only NTFS metadata open failed')
        try:
            # Default directory filters can hide Windows hibernation metadata.
            if self.shown(volume, 1, 1, 0) != 0:
                raise ValueError('Complete NTFS directory visibility unavailable')
            inode = self.inode(volume, 3)  # $Volume / VOLUME_INFORMATION
            if not inode:
                raise ValueError('NTFS volume metadata missing')
            try:
                info = self.read(inode, 0x70, 12)
                check_volume(info)
            finally:
                if self.close_inode(inode) != 0:
                    raise ValueError('NTFS volume metadata close failed')
            hiber = self.hibernation(volume)
            inode = self.inode(volume, 2)  # $LogFile / DATA
            if not inode:
                raise ValueError('NTFS journal missing')
            try:
                attr = self.attribute(inode, 0x80, self.unnamed, 0)
                if not attr:
                    raise ValueError('NTFS journal data missing')
                restart = c.c_void_p()
                try:
                    if self.check_log(attr, c.byref(restart)) != 1 or self.clean_log(attr, restart) != 1:
                        raise ValueError('NTFS journal is not clean')
                    if restart.value:
                        journal = c.string_at(restart, 32)
                        restart_header(journal)
                    else:
                        journal = b'empty-validated-journal'
                finally:
                    if restart.value:
                        self.free(restart)
                    self.close_attribute(attr)
            finally:
                if self.close_inode(inode) != 0:
                    raise ValueError('NTFS journal close failed')
            return info + hiber + journal
        finally:
            if self.unmount(volume, 0) != 0:
                raise ValueError('Read-only NTFS metadata close failed')


def run_tool(kind, fd, *, target_bytes=None):
    if kind == 'resize-target' and (type(target_bytes) is not int
            or not 1048576 <= target_bytes <= MAX_BYTES or target_bytes % 1048576):
        raise ValueError('Invalid read-only NTFS target')
    node = f'/proc/self/fd/{fd}'
    argv = {'signature': ('/usr/sbin/blkid', '-p', '-o', 'export', '--', node),
            'minimum': ('/usr/bin/ntfsresize', '--info', '--no-action', '-P', node),
            # Post-check only: allow the independently verified dirty bit for a
            # read-only allocation scan. Initial eligibility never uses force.
            'resized-minimum': ('/usr/bin/ntfsresize', '--info', '--no-action', '--force', '-P', node),
            'resize-version': ('/usr/bin/ntfsresize', '--version'),
            'resize-packages': ('/usr/bin/rpm', '-qf', '--qf', '%{NAME}|%{EPOCHNUM}|%{VERSION}|%{RELEASE}|%{ARCH}\n',
                                '/usr/bin/ntfsresize', LIBRARY),
            'resize-target': ('/usr/bin/ntfsresize', '--no-action', '-P', '--size', str(target_bytes), node)}[kind]
    inherited = [] if kind in {'resize-version', 'resize-packages'} else [fd]
    lease = os.environ.get('RO_INSTALLER_LEASE_FD')
    if lease is not None:
        if not re.fullmatch('[0-9]{1,6}', lease):
            raise ValueError('Invalid inspection lease')
        lease_fd = int(lease)
        if lease_fd < 3 or lease_fd == fd or not stat.S_ISREG(os.fstat(lease_fd).st_mode):
            raise ValueError('Invalid inspection lease descriptor')
        inherited.append(lease_fd)
    process = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        close_fds=True, pass_fds=tuple(sorted(set(inherited))), env={'PATH':'/usr/sbin:/usr/bin','LC_ALL':'C'})
    streams = [process.stdout, process.stderr]; output = bytearray(); total = 0
    limit = 4096 if kind in {'signature', 'resize-version', 'resize-packages'} else 65536
    deadline = time.monotonic() + (5 if kind == 'resize-packages' else 2 if kind in {'signature', 'resize-version'} else 90)
    try:
        while streams:
            remaining = deadline - time.monotonic()
            ready = select.select(streams, [], [], max(0, remaining))[0]
            if remaining <= 0 or not ready:
                raise ValueError('NTFS inspection deadline')
            for stream in ready:
                chunk = os.read(stream.fileno(), 4096); total += len(chunk)
                if total > limit:
                    raise ValueError('NTFS inspection output limit')
                if not chunk: streams.remove(stream)
                elif stream is process.stdout: output.extend(chunk)
        if process.wait(timeout=max(0.01, deadline-time.monotonic())) != 0:
            raise ValueError('NTFS tool refused inspection')
        return bytes(output)
    finally:
        if process.poll() is None: process.kill()
        process.wait(); process.stdout.close(); process.stderr.close()


def qualify_resize_toolchain(version_output, package_output):
    """Compatibility gate for future writes, not package integrity attestation."""
    if len(version_output) > 4096 or len(package_output) > 4096 or b'\0' in version_output + package_output:
        raise ValueError('Invalid NTFS toolchain output')
    def release(value):
        if not re.fullmatch(r'[0-9]{4}\.[0-9]{1,2}\.[0-9]{1,2}', value):
            raise ValueError('Unrecognized NTFS release')
        try:
            return datetime.date(*(int(part) for part in value.split('.')))
        except ValueError:
            raise ValueError('Invalid NTFS release date') from None
    lines = version_output.decode('utf-8', errors='strict').splitlines()
    match = re.fullmatch(r'ntfsresize v([0-9.]+) \(libntfs-3g\)', lines[0] if lines else '')
    if match is None or sum(line.startswith('ntfsresize v') for line in lines) != 1:
        raise ValueError('Unrecognized NTFS resize version')
    version = release(match[1])
    if version < datetime.date(2026, 9, 28):
        raise ValueError('Unsupported NTFS resize release')
    packages = {}
    for line in package_output.decode('ascii', errors='strict').splitlines():
        fields = line.split('|')
        if (len(fields) != 5 or fields[0] not in {'ntfsprogs', 'ntfs-3g-libs'} or fields[0] in packages
                or not re.fullmatch(r'0|[1-9][0-9]{0,7}', fields[1])
                or not re.fullmatch(r'[0-9][A-Za-z0-9._+~^\-]{0,63}', fields[3]) or fields[4] != 'x86_64'
                or release(fields[2]) != version):
            raise ValueError('Mismatched NTFS dependency package')
        packages[fields[0]] = fields[1:]
    if set(packages) != {'ntfsprogs', 'ntfs-3g-libs'} or packages['ntfsprogs'] != packages['ntfs-3g-libs']:
        raise ValueError('NTFS dependencies must have matching EVR and architecture')
    epoch, name, revision, arch = packages['ntfsprogs']
    return {'version': name, 'epoch': int(epoch), 'release': revision, 'arch': arch}


def validate_resize_target_test(raw, inspection, target_bytes, sector):
    if len(raw) > 65536 or b'\0' in raw:
        raise ValueError('Invalid NTFS target test output')
    text = raw.decode('utf-8', errors='strict')
    def field(pattern):
        values = re.findall(pattern, text, re.M)
        if len(values) != 1: raise ValueError('Ambiguous NTFS target test')
        return int(values[0])
    device = field(r'^Current device size\s*: ([0-9]+) bytes \([0-9]+ MB\)$')
    volume = field(r'^Current volume size\s*: ([0-9]+) bytes \([0-9]+ MB\)$')
    cluster = field(r'^Cluster size\s*: ([0-9]+) bytes$')
    target = field(r'^New volume size\s*: ([0-9]+) bytes \([0-9]+ MB\)$')
    if (device != inspection['deviceBytes'] or volume != inspection['volumeBytes']
            or cluster != inspection['clusterBytes'] or target != ((target_bytes-sector)//cluster)*cluster+sector
            or len(re.findall(r'^The read-only test run ended successfully\.$', text, re.M)) != 1):
        raise ValueError('NTFS target test does not match preparation')


def prepare_resize_target(fd, size, sector, target_bytes, expected_fingerprint):
    """Private read-only preparation; the caller owns identity, exclusion and lease.

    A future writer must regenerate this evidence at its mutation boundary.
    No CLI mode exposes this primitive or accepts caller-provided minimums.
    """
    if (fcntl.fcntl(fd, fcntl.F_GETFL) & os.O_ACCMODE != os.O_RDONLY
            or type(size) is not int or not 1048576 <= size <= MAX_BYTES or sector not in (512, 4096)
            or type(target_bytes) is not int or not 40*1024**3 <= target_bytes < size or target_bytes % 1048576
            or not isinstance(expected_fingerprint, str) or not re.fullmatch('[0-9a-f]{64}', expected_fingerprint)):
        raise ValueError('Invalid NTFS target preparation')
    toolchain = qualify_resize_toolchain(run_tool('resize-version', None), run_tool('resize-packages', None))
    inspection = inspect_fd(fd, size, sector)
    if (inspection['inspectionFingerprint'] != expected_fingerprint
            or target_bytes < inspection['minimumBytes'] + 1024**3):
        raise ValueError('Stale or insufficient NTFS target capacity')
    before = boot_sector(fd, size, sector); native = NativeNtfs(); metadata = native.metadata(fd)
    validate_resize_target_test(run_tool('resize-target', fd, target_bytes=target_bytes), inspection, target_bytes, sector)
    if (boot_sector(fd, size, sector) != before or native.metadata(fd) != metadata or inspect_fd(fd, size, sector) != inspection
            or qualify_resize_toolchain(run_tool('resize-version', None), run_tool('resize-packages', None)) != toolchain):
        raise ValueError('NTFS source or toolchain changed during preparation')
    result = {'schemaVersion': 1, 'deviceBytes': size, 'targetBytes': target_bytes,
              'inspectionFingerprint': expected_fingerprint, 'toolchain': toolchain}
    digest = hashlib.sha256(b'ro-ntfs-target-preparation-v1\0' + before[0] + metadata
                            + json.dumps(result, sort_keys=True).encode())
    return {**result, 'preparationFingerprint': digest.hexdigest()}


def _info_fields(raw):
    text = raw.decode('utf-8', errors='strict')
    def field(pattern):
        values = re.findall(pattern, text, re.M)
        if len(values) != 1:
            raise ValueError('Ambiguous NTFS inspection output')
        return int(values[0])
    volume = field(r'^Current volume size\s*: ([0-9]+) bytes \([0-9]+ MB\)$')
    device = field(r'^Current device size\s*: ([0-9]+) bytes \([0-9]+ MB\)$')
    unit = field(r'^Cluster size\s*: ([0-9]+) bytes$')
    minimum = field(r'^You might resize at ([0-9]+) bytes or [0-9]+ MB \(freeing [0-9]+ MB\)\.$')
    return {'deviceBytes':device, 'volumeBytes':volume, 'clusterBytes':unit, 'minimumBytes':minimum}


def parse_minimum(raw, size, sector, cluster):
    result = _info_fields(raw)
    device, volume, unit, minimum = (result[key] for key in ('deviceBytes', 'volumeBytes', 'clusterBytes', 'minimumBytes'))
    if (device != size or unit != cluster or not 0 < minimum <= volume <= size
            or minimum % sector or (volume-sector) % cluster or size-volume >= cluster):
        raise ValueError('NTFS inspection geometry mismatch')
    return {'deviceBytes':device, 'volumeBytes':volume, 'clusterBytes':unit, 'minimumBytes':minimum}


def parse_resized_minimum(raw, original_size, target_bytes, sector, cluster):
    result = _info_fields(raw)
    volume = ((target_bytes - sector) // cluster) * cluster + sector
    if (result['deviceBytes'] != original_size or result['clusterBytes'] != cluster
            or result['volumeBytes'] != volume or not 0 < result['minimumBytes'] <= volume
            or result['minimumBytes'] % sector):
        raise ValueError('Post-resize allocation geometry mismatch')
    return result


def inspect_resized_fd(fd, original_size, target_bytes, sector, original_boot):
    if fcntl.fcntl(fd, fcntl.F_GETFL) & os.O_ACCMODE != os.O_RDONLY:
        raise ValueError('Read-only post-resize descriptor required')
    before, cluster = resized_boot_sector(fd, original_size, target_bytes, sector, original_boot)
    native = NativeNtfs(); metadata = native.resized_metadata(fd)
    result = parse_resized_minimum(run_tool('resized-minimum', fd), original_size, target_bytes, sector, cluster)
    if (resized_boot_sector(fd, original_size, target_bytes, sector, original_boot) != (before, cluster)
            or native.resized_metadata(fd) != metadata):
        raise ValueError('NTFS changed during post-resize inspection')
    result = {**result, 'targetBytes': target_bytes}
    digest = hashlib.sha256(b'ro-ntfs-resized-inspection-v1\0' + original_boot + before + metadata
                            + json.dumps(result, sort_keys=True).encode())
    return {'schemaVersion': 1, **result, 'inspectionFingerprint': digest.hexdigest()}


def inspect_fd(fd, size, sector):
    if fcntl.fcntl(fd, fcntl.F_GETFL) & os.O_ACCMODE != os.O_RDONLY:
        raise ValueError('Read-only source descriptor required')
    before, cluster = boot_sector(fd, size, sector)
    signature = run_tool('signature', fd).decode('utf-8', errors='strict')
    fields = {}
    for row in signature.splitlines():
        key, sep, value = row.partition('=')
        if not sep or not re.fullmatch('[A-Z_0-9]+', key) or key in fields:
            raise ValueError('Ambiguous filesystem signature')
        fields[key] = value
    if fields.get('TYPE') != 'ntfs' or fields.get('USAGE') != 'filesystem':
        raise ValueError('Unambiguous NTFS signature required')
    native = NativeNtfs()
    metadata = native.metadata(fd)
    result = parse_minimum(run_tool('minimum', fd), size, sector, cluster)
    if boot_sector(fd, size, sector) != (before, cluster) or native.metadata(fd) != metadata:
        raise ValueError('NTFS metadata changed during inspection')
    digest = hashlib.sha256(b'ro-ntfs-inspection-v1\0' + before + metadata + json.dumps(result, sort_keys=True).encode())
    return {'schemaVersion':1, **result, 'inspectionFingerprint':digest.hexdigest()}


def restrict_limit(kind, maximum):
    soft, hard = resource.getrlimit(kind)
    hard = maximum if hard == resource.RLIM_INFINITY else min(hard, maximum)
    soft = hard if soft == resource.RLIM_INFINITY else min(soft, hard)
    resource.setrlimit(kind, (soft, hard))


def main():
    armed = False
    try:
        if os.geteuid() != 0 or len(sys.argv) != 5 or sys.argv[1] != '--check-fd': return 2
        fd, size, sector = (int(v) for v in sys.argv[2:])
        if fd < 3 or not stat.S_ISBLK(os.fstat(fd).st_mode): return 2
        restrict_limit(resource.RLIMIT_CORE, 0)
        restrict_limit(resource.RLIMIT_AS, 1024**3)
        restrict_limit(resource.RLIMIT_CPU, 120)
        signal.alarm(120)
        armed = True
        result = inspect_fd(fd, size, sector)
        raw = json.dumps(result, separators=(',', ':'))
        if len(raw.encode()) > 1023: return 2
        sys.stdout.write(raw + '\n')
        return 0
    except Exception:
        return 2
    finally:
        if armed: signal.alarm(0)


if __name__ == '__main__':
    sys.exit(main())
