#!/usr/bin/python3 -I
"""Fixed private root worker; never a GUI helper operation."""
import contextlib
import fcntl
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import re
import resource
import stat
import sys

sys.dont_write_bytecode = True
MAX_INPUT = 16384


def companion(name):
    path = Path(__file__).with_name(name)
    loader = importlib.machinery.SourceFileLoader('ro_ntfs_worker_' + name, str(path))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    sys.modules[loader.name] = module
    loader.exec_module(module)
    return module


core = companion('ro_installer_ntfs_commit.py')
gate = companion('ro-installer-helper')
session = companion('ro-installer-session')


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result: raise ValueError('Duplicate field')
        result[key] = value
    return result


def invalid_number(_): raise ValueError('Invalid number')


def parse_frame(raw):
    if not isinstance(raw, bytes) or len(raw) > MAX_INPUT: raise ValueError('Private frame limit')
    value = json.loads(raw.decode('utf-8'), object_pairs_hook=unique_object, parse_constant=invalid_number)
    if (not isinstance(value, dict) or set(value) != {'namespace', 'parentNamespace', 'approvedPlan'}
            or any(not isinstance(value[name], str) or not re.fullmatch(r'mnt:\[[1-9][0-9]{0,19}\]', value[name])
                   for name in ('namespace', 'parentNamespace'))
            or value['namespace'] == value['parentNamespace']):
        raise ValueError('Invalid private context')
    return {**value, 'approvedPlan': core.gpt.normalize_ntfs_approval(value['approvedPlan'])}


class TrustedContext:
    """Own an inherited lease duplicate; never create/reopen a replacement lock."""
    def __init__(self, frame):
        self.namespace, self.parent_namespace = frame['namespace'], frame['parentNamespace']
        self.device = core.gpt.identity(frame['approvedPlan']['proposal']['snapshot']['device'])
        self.lease = self.directory = self.parent = None
        self.parent_pid = os.getppid()
        try:
            self.parent_path, name = os.path.split(gate.LOCK_DIRECTORY)
            self.parent = os.open(self.parent_path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
            info = os.fstat(self.parent)
            if info.st_uid != 0 or stat.S_IMODE(info.st_mode) & 0o022: raise ValueError('Unsafe runtime parent')
            self.directory = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=self.parent)
            gate.InstallerLock().trusted(self.directory, directory=True)
            anchor = os.stat('install.lock', dir_fd=self.directory, follow_symlinks=False)
            for name in os.listdir('/proc/self/fd'):
                fd = int(name)
                if fd < 3: continue
                try: observed = os.fstat(fd)
                except OSError: continue
                if (observed.st_dev, observed.st_ino) != (anchor.st_dev, anchor.st_ino): continue
                gate.InstallerLock().trusted(fd)
                try: fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError: continue
                self.lease = fcntl.fcntl(fd, fcntl.F_DUPFD_CLOEXEC, 3)
                break
            if self.lease is None: raise ValueError('No inherited lease')
            self.system = gate.System()
            self.system.lease_fd = self.lease
            if not self.guard(): raise ValueError('Untrusted transaction context')
        except BaseException:
            try: self.close()
            except OSError: pass
            raise

    def guard(self):
        if os.geteuid() != 0 or os.getppid() != self.parent_pid: return False
        parent = os.fstat(self.parent)
        current_parent = os.stat(self.parent_path, follow_symlinks=False)
        if (parent.st_uid != 0 or stat.S_IMODE(parent.st_mode) & 0o022
                or (parent.st_dev, parent.st_ino) != (current_parent.st_dev, current_parent.st_ino)): return False
        session.verify_private(self.namespace)
        if (self.parent_namespace == self.namespace
                or os.readlink(f'/proc/{self.parent_pid}/ns/mnt') != self.namespace): return False
        gate.InstallerLock().trusted(self.directory, directory=True)
        gate.InstallerLock().trusted(self.lease)
        directory = os.fstat(self.directory)
        current = os.stat(gate.LOCK_DIRECTORY, follow_symlinks=False)
        anchor = os.stat('install.lock', dir_fd=self.directory, follow_symlinks=False)
        lease = os.fstat(self.lease)
        if ((directory.st_dev, directory.st_ino) != (current.st_dev, current.st_ino)
                or not stat.S_ISREG(anchor.st_mode)
                or (anchor.st_dev, anchor.st_ino) != (lease.st_dev, lease.st_ino)):
            return False
        fcntl.flock(self.lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return (self.system.platform_supported()
                and gate.validate_device(self.system, self.device['path']).public() == self.device)

    def close(self):
        error = None
        for name in ('lease', 'directory', 'parent'):
            fd = getattr(self, name)
            setattr(self, name, None)
            if fd is not None:
                try: os.close(fd)
                except OSError as failure:
                    if error is None: error = failure
        if error is not None: raise error
    def __enter__(self): return self
    def __exit__(self, kind, error, traceback):
        try: self.close()
        except OSError:
            if error is None: raise
            error.cleanup_failed = True


@contextlib.contextmanager
def native_lease(fd):
    # This module runs in an isolated worker, never a supervisor thread.
    name = 'RO_INSTALLER_LEASE_FD'
    previous = os.environ.get(name)
    os.environ[name] = str(fd)
    try: yield
    finally:
        if previous is None: os.environ.pop(name, None)
        else: os.environ[name] = previous


PHASES = core.TRANSACTION_PHASES


def failure_result(error, *, phase='admission', entered=False):
    if isinstance(error, core.NtfsTransactionError):
        return {'status':'failed', 'phase':error.phase if error.phase in PHASES else 'unknown',
                'progressKnown':True, 'sourceMayHaveChanged':error.source_may_have_changed,
                'gptWriteStarted':error.gpt_write_started, 'verifiedGptCopies':error.verified_gpt_copies,
                'cleanupFailed':error.cleanup_failed}
    return {'status':'failed', 'phase':phase if phase in PHASES else 'unknown',
            'progressKnown':not entered, 'sourceMayHaveChanged':entered,
            'gptWriteStarted':entered, 'verifiedGptCopies':0,
            'cleanupFailed':getattr(error, 'cleanup_failed', False) is True or phase == 'cleanup'}


def execute(frame):
    phase, entered, completed = 'context', False, False
    try:
        # Construct context before touching media; the session also holds its
        # own inhibitor through descendant cleanup, including worker failure.
        with TrustedContext(frame) as context, native_lease(context.lease):
            phase = 'power'
            with session.power_inhibitor():
                approved = frame['approvedPlan']; proposal = approved['proposal']; ownership = approved['approval']
                phase = 'admission'
                whole = os.open(proposal['snapshot']['device']['path'],
                    os.O_RDWR | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK)
                try:
                    with core.BlockNtfsTransaction(whole, proposal, context.guard) as io:
                        fd, whole = whole, None
                        phase = 'cleanup'
                        os.close(fd)  # The adapter now owns the only worker description.
                        phase, entered = 'execute', True
                        snapshot = io.run(ownership['rootGuid'], ownership['preservationFingerprint'],
                            ownership['inspectionFingerprint'], ownership['preparationFingerprint'], context.lease)
                        completed = True
                finally:
                    if whole is not None:
                        fd, whole = whole, None
                        original = sys.exc_info()[1]
                        try: os.close(fd)
                        except OSError:
                            if original is None: raise
                            original.cleanup_failed = True
        return {'status':'success', 'snapshot':snapshot, 'preservationFingerprint':ownership['preservationFingerprint']}
    except Exception as error:
        # Post-success context/inhibitor close failure must not erase progress.
        if completed and not isinstance(error, core.NtfsTransactionError):
            error = core.NtfsTransactionError('cleanup', True, True, 2, True)
        return failure_result(error, phase=phase, entered=entered)


def main():
    if os.geteuid() != 0 or sys.argv[1:] != ['--execute']: return 2
    entered = False
    try:
        core.ntfs.restrict_limit(resource.RLIMIT_CORE, 0)
        core.ntfs.restrict_limit(resource.RLIMIT_AS, 1024**3)
        core.ntfs.restrict_limit(resource.RLIMIT_CPU, 2*60*60)
        frame = parse_frame(sys.stdin.buffer.read(MAX_INPUT + 1))
        entered = True
        result = execute(frame)
    except Exception as error:
        result = failure_result(error, phase='unknown' if entered else 'admission', entered=entered)
    raw = json.dumps({'schemaVersion':1, **result}, separators=(',', ':'), allow_nan=False)
    if len(raw.encode()) > 8191: return 2
    try: sys.stdout.write(raw + '\n')
    except OSError: return 2
    return 0 if result['status'] == 'success' else 2


if __name__ == '__main__': sys.exit(main())
