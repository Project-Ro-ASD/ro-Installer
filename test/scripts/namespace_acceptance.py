#!/usr/bin/env python3
"""Disposable real Linux namespace probe. Exit 77 is explicit NO-GO, never PASS.

No host root escalation, block devices or actual /mnt paths. The outer process
only invokes a fresh user+mount namespace. Mount operations happen after the
production private_namespace primitive succeeds, in a fresh temporary tree.
"""
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def rows():
    return Path('/proc/self/mountinfo').read_text()


def worker(directory):
    loader = importlib.machinery.SourceFileLoader('namespace_probe', str(ROOT / 'linux/ro-installer-session'))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    before, after = module.private_namespace()
    base = Path(directory)
    assert base.is_dir() and str(base).startswith('/tmp/ro-p0-03-namespace-')
    source, dest = base / 'source', base / 'dest'
    source.mkdir()
    dest.mkdir()
    owned = {}

    def record(path):
        matches = [line for line in rows().splitlines() if line.split()[4] == str(path)]
        assert len(matches) == 1, matches
        owned[str(path)] = matches[0].split()[:6]

    def run(*args):
        subprocess.run(args, check=True, capture_output=True, timeout=10)
        module.verify_private(after)

    run('mount', '-t', 'tmpfs', '-o', 'size=4m', 'tmpfs', str(source))
    record(source)
    nested = source / 'nested'
    nested.mkdir()
    run('mount', '-t', 'tmpfs', '-o', 'size=1m', 'tmpfs', str(nested))
    record(nested)
    run('mount', '--rbind', str(source), str(dest))
    run('mount', '--make-rprivate', str(dest))
    record(dest)
    record(dest / 'nested')
    (nested / 'proof').write_text('isolated')
    assert (dest / 'nested/proof').read_text() == 'isolated'
    for path in sorted(owned, key=lambda value: len(Path(value).parts), reverse=True):
        current = [line.split()[:6] for line in rows().splitlines() if line.split()[4] == path]
        assert current == [owned[path]], 'mount identity changed before cleanup'
        run('umount', path)
        assert not any(line.split()[4] == path for line in rows().splitlines())
    assert directory not in rows(), 'temporary mount survived cleanup'
    print(json.dumps({'status': 'PASS', 'real_mounts': 4, 'namespace_before': before,
                      'namespace_after': after, 'private_propagation': True,
                      'rbind_nested': True, 'individual_cleanup': True}))


def main():
    before, inventory = os.readlink('/proc/self/ns/mnt'), rows()
    if not shutil.which('unshare'):
        print(json.dumps({'status': 'UNAVAILABLE', 'security_acceptance': 'NO-GO', 'reason': 'unshare unavailable'}))
        return 77
    with tempfile.TemporaryDirectory(prefix='ro-p0-03-namespace-', dir='/tmp') as directory:
        # The bootstrap emits a marker only after the kernel grants both new
        # namespaces. Any later test error is FAIL, not a capability SKIP.
        command = ['unshare', '--user', '--map-root-user', '--mount', '--',
                   sys.executable, str(Path(__file__).resolve()), '--worker', directory]
        result = subprocess.run(command, capture_output=True, text=True, timeout=40)
        assert before == os.readlink('/proc/self/ns/mnt'), 'parent namespace changed'
        assert inventory == rows(), 'parent mount inventory changed during probe'
        if result.returncode == 77:
            report = {'status': 'UNAVAILABLE', 'security_acceptance': 'NO-GO',
                      'reason': 'kernel denied disposable user/mount namespace bootstrap'}
        elif result.returncode != 0:
            # No marker means unshare itself failed, before Python/any mount.
            if 'RO_NAMESPACE_WORKER_STARTED' not in result.stderr and 'unshare:' in result.stderr:
                report = {'status': 'UNAVAILABLE', 'security_acceptance': 'NO-GO',
                          'reason': 'kernel denied disposable user/mount namespace bootstrap'}
            else:
                report = {'status': 'FAIL', 'security_acceptance': 'NO-GO',
                          'reason': 'real namespace/mount probe failed', 'stderr': result.stderr[-4000:]}
        else:
            report = json.loads(result.stdout)
            report['parent_unchanged'] = True
        print(json.dumps(report, sort_keys=True))
        return 0 if report['status'] == 'PASS' else 77 if report['status'] == 'UNAVAILABLE' else 1


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--worker':
        sys.stderr.write('RO_NAMESPACE_WORKER_STARTED\n')
        worker(sys.argv[2])
    else:
        sys.exit(main())
