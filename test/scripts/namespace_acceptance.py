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
import re
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
WORKER_MARKER = 'RO_NAMESPACE_WORKER_STARTED'


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


def _unique_fields(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError('Duplicate namespace report field')
        value[key] = item
    return value


def verified_report(result, parent_namespace):
    if result.stderr != WORKER_MARKER + '\n' or len(result.stdout.encode()) > 4096:
        raise ValueError('Missing worker marker or oversized report')
    report = json.loads(result.stdout, object_pairs_hook=_unique_fields)
    if (not isinstance(report, dict) or set(report) != {
            'status', 'real_mounts', 'namespace_before', 'namespace_after',
            'private_propagation', 'rbind_nested', 'individual_cleanup'}
            or report['status'] != 'PASS' or type(report['real_mounts']) is not int
            or report['real_mounts'] != 4
            or any(report[name] is not True for name in
                   ('private_propagation', 'rbind_nested', 'individual_cleanup'))):
        raise ValueError('Incomplete namespace acceptance')
    names = [report['namespace_before'], report['namespace_after']]
    if (any(not isinstance(name, str) or not re.fullmatch(r'mnt:\[[0-9]+\]', name) for name in names)
            or len(set(names + [parent_namespace])) != 3):
        raise ValueError('Namespace isolation was not demonstrated')
    return {**report, 'parent_unchanged': True}


def main():
    before, inventory = os.readlink('/proc/self/ns/mnt'), rows()
    if not shutil.which('unshare'):
        print(json.dumps({'status': 'UNAVAILABLE', 'security_acceptance': 'NO-GO', 'reason': 'unshare unavailable'}))
        return 77
    with tempfile.TemporaryDirectory(prefix='ro-p0-03-namespace-', dir='/tmp') as directory:
        command = ['unshare', '--user', '--map-root-user', '--mount', '--',
                   sys.executable, str(Path(__file__).resolve()), '--worker', directory]
        report = None
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=40)
        except subprocess.TimeoutExpired:
            report = {'status': 'FAIL', 'security_acceptance': 'NO-GO',
                      'reason': 'disposable namespace probe timed out'}
        except OSError:
            report = {'status': 'FAIL', 'security_acceptance': 'NO-GO',
                      'reason': 'disposable namespace probe could not start'}
        if before != os.readlink('/proc/self/ns/mnt') or inventory != rows():
            report = {'status': 'FAIL', 'security_acceptance': 'NO-GO',
                      'reason': 'parent namespace or mount inventory changed'}
        if report is None:
            started = WORKER_MARKER in result.stderr
            if result.returncode != 0:
                unavailable = not started and (result.returncode == 77 or 'unshare:' in result.stderr)
                report = {'status': 'UNAVAILABLE' if unavailable else 'FAIL',
                          'security_acceptance': 'NO-GO',
                          'reason': 'kernel denied disposable user/mount namespace bootstrap' if unavailable
                                    else 'real namespace/mount probe failed'}
                if not unavailable:
                    report['stderr'] = result.stderr[-4000:]
            else:
                try:
                    report = verified_report(result, before)
                except (ValueError, TypeError, RecursionError):
                    report = {'status': 'FAIL', 'security_acceptance': 'NO-GO',
                              'reason': 'invalid or incomplete namespace worker report'}
        print(json.dumps(report, sort_keys=True))
        return 0 if report['status'] == 'PASS' else 77 if report['status'] == 'UNAVAILABLE' else 1


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--worker':
        sys.stderr.write(WORKER_MARKER + '\n')
        worker(sys.argv[2])
    else:
        sys.exit(main())
