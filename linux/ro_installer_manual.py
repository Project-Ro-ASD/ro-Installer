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


def main():
    try:
        if os.geteuid() != 0:
            return 2
        if len(sys.argv)==5 and sys.argv[1]=='--layout':
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
