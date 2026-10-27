"""Disposable rsync metadata fixture; never mounts or opens a device node."""
import hashlib
import json
import os
from pathlib import Path
import socket
import stat
import subprocess
import sys
import tempfile

root = Path(sys.argv[2]).resolve()
assert root.parent == Path(tempfile.gettempdir()).resolve()
assert root.name.startswith('p0-02-rsync-') and root.is_dir()
source, target = root / 'source', root / 'target'
required = ['usr/lib/os-release', 'usr/lib/systemd/systemd',
            'boot/efi/EFI/fedora/shimx64.efi', 'boot/efi/EFI/fedora/grubx64.efi']
foreign = ['srv/foreign-ext', 'data/foreign-fat', 'data/foreign-ntfs', 'backup [a]*? space']


def write(name, content=b'prepared fixture\n'):
    path = source / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)
    return path


def acl(path):
    return subprocess.check_output(['getfacl', '-c', '-n', str(path)], text=True)


def attributes(path):
    return {name: os.getxattr(path, name).hex()
            for name in os.listxattr(path) if name.startswith('user.')}


def metadata(path):
    info = path.lstat()
    result = {'mode': stat.S_IMODE(info.st_mode), 'type': stat.S_IFMT(info.st_mode),
              'uid': info.st_uid, 'gid': info.st_gid, 'rdev': info.st_rdev}
    if path.is_symlink():
        result['link'] = os.readlink(path)
    elif path.is_file():
        result.update(sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                      size=info.st_size, acl=acl(path), xattrs=attributes(path))
    elif path.is_dir():
        result.update(acl=acl(path), xattrs=attributes(path))
    return result


if sys.argv[1] == 'prepare':
    source.mkdir()
    target.mkdir()
    for name in required:
        write(name)
    payload = write('opt/prepared/payload', bytes(range(256)) * 4096)
    payload.chmod(0o640)
    os.setxattr(payload, 'user.p0-02', b'content and metadata')
    os.setxattr(source / required[-1], 'user.efi-not-copied', b'efi')
    owned = write('opt/prepared/numeric-owner')
    if os.geteuid() == 0:
        os.chown(owned, 12345, 12346)
    elif 65534 in os.getgroups():
        os.chown(owned, -1, 65534)
    directory = source / 'opt/prepared'
    directory.chmod(0o750)
    subprocess.run(['setfacl', '-m', 'u:12347:r--', str(payload)], check=True)
    subprocess.run(['setfacl', '-m', 'd:u:12347:r-x', str(directory)], check=True)
    os.symlink('payload', directory / 'relative-link')
    os.mkfifo(directory / 'fifo', 0o620)
    sock = socket.socket(socket.AF_UNIX)
    try:
        sock.bind(str(directory / 'socket'))
    finally:
        sock.close()
    os.link(payload, directory / 'hardlink')
    sparse = write('opt/prepared/sparse', b'head')
    with sparse.open('r+b') as stream:
        stream.seek(8 * 1024 * 1024 - 1)
        stream.write(b'Q')
    device_limits = []
    for name, mode, number in [('char-node', stat.S_IFCHR, os.makedev(1, 3)),
                               ('block-node', stat.S_IFBLK, os.makedev(0, 0))]:
        try:
            # Metadata-only nodes: no test ever opens/reads/writes them.
            os.mknod(directory / name, mode | 0o600, number)
        except PermissionError:
            device_limits.append(name + ': CAP_MKNOD unavailable')
    for name in foreign:
        write(name + '/foreign-secret', b'not installation input')
    for name in ['run/live-session', 'tmp/live-temp', 'mnt/recursive-target',
                 'media/removable', 'home/liveuser/private', 'home/prepared/.cache/cache']:
        write(name, b'not installation input')
    write('home/prepared/keep', b'prepared home fixture')
    names = [p.relative_to(source).as_posix() for p in directory.iterdir()]
    names += ['opt/prepared', *required, 'home/prepared/keep']
    # getfacl output must not include source/destination path names.
    manifest = {'metadata': {n: metadata(source / n) for n in names},
                'device_limits': device_limits,
                'ownership_scope': 'arbitrary numeric UID/GID' if os.geteuid() == 0 else 'current UID and permitted numeric GID'}
    (root / 'manifest.json').write_text(json.dumps(manifest, indent=2))
    print(json.dumps({'prepared': True, **{k:v for k,v in manifest.items() if k != 'metadata'}}))
elif sys.argv[1] == 'verify':
    manifest = json.loads((root / 'manifest.json').read_text())
    for name, expected in manifest['metadata'].items():
        actual = metadata(target / name)
        if name.startswith('boot/efi/'):
            # Existing EFI contract deliberately excludes xattrs.
            expected['xattrs'] = {}
        assert actual == expected, (name, expected, actual)
    for name in foreign:
        assert not (target / name / 'foreign-secret').exists(), name
    for name in ['run/live-session', 'tmp/live-temp', 'mnt/recursive-target',
                 'media/removable', 'home/liveuser/private', 'home/prepared/.cache/cache']:
        assert not (target / name).exists(), name
    assert (source / 'opt/prepared/hardlink').stat().st_ino == (source / 'opt/prepared/payload').stat().st_ino
    hardlinks_preserved = (target / 'opt/prepared/hardlink').stat().st_ino == (target / 'opt/prepared/payload').stat().st_ino
    assert not hardlinks_preserved  # Current options have no -H; record, do not broaden.
    print(json.dumps({'verified': ['content', 'permissions', 'symlinks', 'numeric UID/GID', 'ACL',
                                 'user xattrs', 'FIFO', 'Unix socket', 'foreign and Live exclusions'],
                      'device_limits': manifest['device_limits'], 'ownership_scope': manifest['ownership_scope'],
                      'device_nodes_verified': [n for n in manifest['metadata'] if n.endswith('-node')],
                      'hardlinks_preserved': hardlinks_preserved,
                      'sparse_contract': 'content preserved; no -S allocation guarantee',
                      'sparse_source_blocks': (source / 'opt/prepared/sparse').stat().st_blocks,
                      'sparse_target_blocks': (target / 'opt/prepared/sparse').stat().st_blocks,
                      'filesystem_scope': 'temporary directory filesystem; not FAT32/Btrfs image acceptance'}))
elif sys.argv[1] == 'deny-read':
    # Root CI drops privilege only in this child; local unprivileged runs need no drop.
    root.chmod(0o755)
    source.chmod(0o755)
    target.chmod(0o777)
    denied = write('denied-payload', b'permission regression')
    denied.chmod(0)
    args = json.loads(sys.argv[3])
    assert args[-2:] == [str(source) + '/', str(target) + '/']
    def drop():
        os.setgroups([])
        os.setgid(65534)
        os.setuid(65534)
    process = subprocess.run(['rsync', *args], preexec_fn=drop if os.geteuid() == 0 else None)
    sys.exit(process.returncode)
else:
    raise SystemExit('unknown fixture operation')
