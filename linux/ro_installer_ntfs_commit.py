#!/usr/bin/python3 -I
"""Private GPT commit building block. No CLI, filesystem or write admission.

Caller must establish NTFS post-state, source identity, namespace and lease.
Only the fixed transaction worker may compose this with installation admission.
"""
import fcntl
import importlib.util
import os
from pathlib import Path

spec = importlib.util.spec_from_file_location('ro_commit_gpt', Path(__file__).with_name('ro_installer_gpt.py'))
gpt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gpt)


class GptCommitError(RuntimeError):
    def __init__(self, phase, write_started, verified_copies):
        super().__init__('NTFS_GPT_COMMIT_FAILED')
        self.phase = phase
        self.write_started = write_started
        self.verified_copies = verified_copies
        self.cleanup_failed = False


class BlockGptIo:
    """Own a duplicate of the whole-disk description; caller owns source proof."""
    def __init__(self, fd, device, sector, assert_source):
        if type(fd) is not int or fd < 3 or type(sector) is not int or sector not in (512, 4096) or not callable(assert_source):
            raise ValueError('Invalid GPT commit binding')
        self._device = gpt.identity(device)
        self._sector, self._assert_source = sector, assert_source
        self._fd = fcntl.fcntl(fd, fcntl.F_DUPFD_CLOEXEC, 3)
        try:
            self._geometry()
        except BaseException:
            self.close()
            raise

    @property
    def device(self): return dict(self._device)
    @property
    def sector(self): return self._sector
    @property
    def fd(self):
        if self._fd is None: raise ValueError('Closed GPT commit binding')
        return self._fd

    def _geometry(self):
        flags = fcntl.fcntl(self.fd, fcntl.F_GETFL)
        if flags & os.O_ACCMODE != os.O_RDWR or flags & (os.O_APPEND | os.O_PATH):
            raise ValueError('Writable positional GPT descriptor required')
        if gpt.fd_geometry(self.fd, self._device) != self._sector:
            raise ValueError('GPT sector geometry changed')

    def guard(self):
        self._geometry()
        return self._assert_source() is True
    def read(self, offset, length): return os.pread(self.fd, length, offset)
    def write(self, offset, data): return os.pwrite(self.fd, data, offset)
    def flush(self): os.fsync(self.fd)
    def close(self):
        fd, self._fd = self._fd, None
        if fd is not None: os.close(fd)
    def __enter__(self): return self
    def __exit__(self, kind, error, traceback):
        try:
            self.close()
        except OSError:
            if error is None: raise
            if isinstance(error, GptCommitError): error.cleanup_failed = True


def commit_ntfs_gpt(io, proposal, root_guid, preservation_fingerprint):
    """Regenerate exact patches, flush backup before primary, never roll back.

    Internal IO must bind device/sector and return literal True from guard().
    write_started means this step attempted a write, not a claim that other
    actors or preceding filesystem resize left the disk unchanged.
    """
    phase, write_started, verified_copies = 'prepare', False, 0
    try:
        before = gpt.normalize_snapshot(proposal['snapshot'])
        sector, device = before['logicalSectorBytes'], before['device']
        if type(io.sector) is not int or io.sector != sector or gpt.identity(io.device) != device:
            raise ValueError('GPT IO differs from the approved device')
        def owned():
            if io.guard() is not True: raise ValueError('GPT source guard refused')
        owned()
        plan = gpt.ntfs_shrink_plan(proposal)
        groups = gpt.ntfs_gpt_update_plan(io.read, proposal, root_guid, preservation_fingerprint)
        view = {(0, sector): io.read(0, sector)}
        for group in groups:
            for offset, original, replacement in group: view[offset, len(original)] = original
        observed = gpt.verified_ntfs_snapshot(lambda offset, length: view[offset, length],
            device, sector, plan['source']['number'], plan['root']['number'])
        if observed != {'snapshot': before, 'preservationFingerprint': preservation_fingerprint}:
            raise ValueError('GPT commit preimage changed')
        def check_view():
            for _ in range(2):
                for (offset, length), expected in view.items():
                    actual = io.read(offset, length)
                    if type(actual) is not bytes or actual != expected:
                        raise ValueError('GPT intermediate metadata changed')
        for index, group in enumerate(groups):
            phase = 'backup' if index == 0 else 'primary'
            owned()
            check_view()
            for offset, original, replacement in group:
                write_started = True
                count = io.write(offset, replacement)
                if type(count) is not int or count != len(replacement):
                    raise ValueError('Incomplete GPT metadata write')
            io.flush()
            for offset, original, replacement in group: view[offset, len(replacement)] = replacement
            check_view()
            verified_copies += 1
        phase = 'verify'
        final = gpt.verified_ntfs_snapshot(io.read, device, sector,
            plan['source']['number'], plan['root']['number'])
        result = gpt.verify_ntfs_created_layout(proposal, root_guid, preservation_fingerprint, final)
        owned()
        return result
    except Exception:
        # No raw metadata, native diagnostics or paths cross the error boundary.
        raise GptCommitError(phase, write_started, verified_copies) from None


if __name__ == '__main__':
    raise SystemExit(2)
