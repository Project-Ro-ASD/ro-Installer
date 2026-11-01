#!/usr/bin/python3 -I
"""Bounded, read-only manual role eligibility worker. No installation API."""
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import re
import select
import stat
import struct
import subprocess
import sys
import time

FILESYSTEM_TIMEOUT = 2
EFI_SOURCE = '/boot/efi/EFI/fedora'
ESP_MOUNT_TARGETS = {'/mnt/.ro-installer-esp-probe', '/mnt/.ro-installer-esp-stage'}
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('ro_manual_gpt', Path(__file__).with_name('ro_installer_gpt.py'))
gpt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gpt)
probe_device = gpt.probe_device
manual_plan = gpt.manual_plan


def parse_blkid(raw):
    # Export labels and UUIDs never leave the worker. Keep only filesystem class.
    if len(raw) > 4096:
        raise ValueError('Filesystem probe output limit')
    fields = {}
    for line in raw.decode('utf-8', errors='strict').splitlines():
        key, separator, value = line.partition('=')
        if not separator or not re.fullmatch('[A-Z_0-9]+', key) or key in fields:
            raise ValueError('Invalid filesystem probe')
        fields[key] = value
    if fields.get('USAGE') != 'filesystem' or fields.get('TYPE') not in {'vfat', 'btrfs', 'ext4', 'xfs'}:
        raise ValueError('Unsupported or ambiguous filesystem')
    if fields['TYPE'] == 'vfat' and fields.get('VERSION') != 'FAT32':
        raise ValueError('FAT32 required')
    return fields['TYPE']


def partition_descriptor(snapshot, binding, fd=None):
    disk = snapshot['device']
    suffix = ('p' if disk['path'][-1].isdigit() else '') + str(binding['number'])
    path = disk['path'] + suffix
    parent = Path('/sys/dev/block/' + disk['majorMinor']).resolve(strict=True)
    child = parent / Path(path).name
    expected_size = (binding['endSector'] - binding['startSector'] + 1) * snapshot['logicalSectorBytes']
    number = (child / 'dev').read_text().strip()
    if (not re.fullmatch(r'(0|[1-9][0-9]*):(0|[1-9][0-9]*)', number)
            or int((parent / 'diskseq').read_text()) != disk['diskSequence']
            or int((parent / 'size').read_text()) * 512 != disk['size']
            or int((child / 'partition').read_text()) != binding['number']
            or int((child / 'start').read_text()) * 512 != binding['startSector'] * snapshot['logicalSectorBytes']
            or int((child / 'size').read_text()) * 512 != expected_size):
        raise ValueError('Partition geometry or sequence changed')
    if fd is not None:
        info = os.fstat(fd)
        if (not stat.S_ISBLK(info.st_mode) or f'{os.major(info.st_rdev)}:{os.minor(info.st_rdev)}' != number
                or struct.unpack('=Q', fcntl.ioctl(fd, 0x80081272, bytes(8)))[0] != expected_size
                or struct.unpack('=Q', fcntl.ioctl(fd, 0x80081280, bytes(8)))[0] != disk['diskSequence']):
            raise ValueError('Opened partition identity changed')
    return path, number


def probe_filesystem(snapshot, binding):
    path, number = partition_descriptor(snapshot, binding)
    fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_EXCL)
    try:
        if partition_descriptor(snapshot, binding, fd) != (path, number):
            raise ValueError('Partition changed before probe')
        inherited = (fd,)
        lease = os.environ.get('RO_INSTALLER_LEASE_FD')
        if lease is not None:
            lease_fd = int(lease); os.fstat(lease_fd)
            inherited += (lease_fd,)
        process = subprocess.Popen(('/usr/sbin/blkid', '-p', '-o', 'export', '--', '/proc/self/fd/' + str(fd)),
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            close_fds=True, pass_fds=inherited, env={'PATH': '/usr/sbin:/usr/bin', 'LC_ALL': 'C'})
        output = bytearray(); total = 0; streams = [process.stdout, process.stderr]
        deadline = time.monotonic() + FILESYSTEM_TIMEOUT
        try:
            while streams:
                remaining = deadline - time.monotonic()
                ready = select.select(streams, [], [], max(0, remaining))[0]
                if remaining <= 0 or not ready:
                    raise ValueError('Filesystem probe deadline')
                for stream in ready:
                    chunk = os.read(stream.fileno(), 4096); total += len(chunk)
                    if total > 4096:
                        raise ValueError('Filesystem probe output limit')
                    if not chunk: streams.remove(stream)
                    elif stream is process.stdout: output.extend(chunk)
            if process.wait(timeout=max(0.01, deadline - time.monotonic())) != 0:
                raise ValueError('Ambiguous or missing filesystem signature')
        finally:
            if process.poll() is None: process.kill()
            process.wait(); process.stdout.close(); process.stderr.close()
        result = parse_blkid(output)
        if partition_descriptor(snapshot, binding, fd) != (path, number):
            raise ValueError('Partition changed during probe')
        return result
    finally:
        os.close(fd)


def probe_manual(path, expected, choices):
    snapshot = probe_device(path, expected)
    plan = manual_plan(snapshot, choices)
    for role in ('esp', 'root'):
        binding = plan[role]
        if binding['source'] == 'existing':
            fs = probe_filesystem(snapshot, binding)
            allowed = {'vfat'} if role == 'esp' else {'btrfs', 'ext4', 'xfs'}
            if fs not in allowed:
                raise ValueError('Filesystem does not match selected role')
    if probe_device(path, expected) != snapshot:
        raise ValueError('GPT changed during filesystem eligibility probe')
    return {'snapshot': snapshot, 'plan': plan}


def probe_layout(path, expected, slots):
    if (not isinstance(slots,list) or len(slots)>2
            or any(type(n) is not int or not 1<=n<=4096 for n in slots)
            or len(set(slots))!=len(slots)):
        raise ValueError('Invalid owned GPT slots')
    return gpt.probe_device(path,expected,preserve_slots=slots)


def source_budget(path, cluster):
    if type(cluster) is not int or not 512 <= cluster <= 1048576 or cluster & (cluster - 1):
        raise ValueError('Unsupported filesystem allocation size')
    count = files = source_bytes = allocated = 0
    required_files = set()
    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_DIRECTORY | os.O_NOFOLLOW
    def walk(fd, depth):
        nonlocal count, files, source_bytes, allocated
        if depth > 8:
            raise ValueError('EFI source exceeds depth limit')
        names = set()
        with os.scandir(fd) as entries:
            for entry in entries:
                count += 1
                if count > 4096 or not re.fullmatch(r'[A-Za-z0-9_-][A-Za-z0-9_.-]{0,254}', entry.name) or entry.name.endswith('.'):
                    raise ValueError('Unsupported EFI source inventory')
                lower = entry.name.lower()
                if lower in names:
                    raise ValueError('Case-colliding EFI source names')
                names.add(lower)
                info = entry.stat(follow_symlinks=False)
                if info.st_dev != root_device:
                    raise ValueError('EFI source crosses a mount boundary')
                if stat.S_ISDIR(info.st_mode):
                    child = os.open(entry.name, flags, dir_fd=fd)
                    try:
                        opened = os.fstat(child)
                        if (opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino):
                            raise ValueError('EFI source changed during traversal')
                        walk(child, depth + 1)
                    finally:
                        os.close(child)
                elif stat.S_ISREG(info.st_mode):
                    files += 1
                    source_bytes += info.st_size
                    if info.st_size < 0 or source_bytes > 1024**3:
                        raise ValueError('EFI source exceeds byte limit')
                    allocated += (info.st_size + cluster - 1) // cluster * cluster
                    if depth == 0 and lower in {'shimx64.efi', 'grubx64.efi'} and info.st_size > 0:
                        required_files.add(lower)
                else:
                    raise ValueError('EFI source symlink or special file')
    fd = os.open(path, flags)
    try:
        root_device = os.fstat(fd).st_dev
        walk(fd, 0)
    finally:
        os.close(fd)
    if len(required_files) != 2:
        raise ValueError('Required EFI source binaries missing')
    # Per-entry directory slack and parent growth plus fixed operational headroom.
    return {'requiredBytes': allocated + (2 * count + 4) * cluster + 16 * 1048576,
            'sourceBytes': source_bytes, 'fileCount': files, 'clusterBytes': cluster}


def mounted_esp_budget(path, device):
    if path not in ESP_MOUNT_TARGETS or not isinstance(device, str) or not re.fullmatch(r'(0|[1-9][0-9]*):(0|[1-9][0-9]*)', device):
        raise ValueError('Invalid inspected ESP target')
    fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        if f'{os.major(info.st_dev)}:{os.minor(info.st_dev)}' != device:
            raise ValueError('Inspected ESP mount changed')
        fs = os.fstatvfs(fd)
        # Linux fat_statfs reports the cluster allocation unit in f_bsize.
        if fs.f_frsize != fs.f_bsize or not 0 <= fs.f_bavail <= fs.f_blocks:
            raise ValueError('Invalid ESP allocation counters')
        result = source_budget(EFI_SOURCE, fs.f_bsize)
        current = os.fstatvfs(fd)
        if current.f_bsize != fs.f_bsize or current.f_frsize != fs.f_frsize or not 0 <= current.f_bavail <= current.f_blocks:
            raise ValueError('ESP allocation geometry changed')
        available = current.f_bavail * current.f_frsize
        if not 0 <= available <= gpt.MAX_BYTES:
            raise ValueError('ESP capacity exceeds safety limit')
        return {**result, 'availableBytes': available, 'sufficient': available >= result['requiredBytes']}
    finally:
        os.close(fd)


def main():
    try:
        if os.geteuid() != 0:
            return 2
        if len(sys.argv)==4 and sys.argv[1]=='--efi-budget':
            result=mounted_esp_budget(sys.argv[2],sys.argv[3])
        elif len(sys.argv)==5 and sys.argv[1]=='--layout':
            result=probe_layout(sys.argv[2],json.loads(sys.argv[3]),json.loads(sys.argv[4]))
        elif len(sys.argv)==4:
            result=probe_manual(sys.argv[1],json.loads(sys.argv[2]),json.loads(sys.argv[3]))
        else:
            return 2
        raw = json.dumps(result, separators=(',', ':'))
        if len(raw.encode()) > 8191:
            return 2
        sys.stdout.write(raw + '\n')
        return 0
    except Exception:
        return 2  # Never return labels, UUIDs, paths or exception excerpts.


if __name__ == '__main__':
    sys.dont_write_bytecode = True
    sys.exit(main())
