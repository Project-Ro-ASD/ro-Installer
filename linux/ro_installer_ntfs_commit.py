#!/usr/bin/python3 -I
"""Private NTFS/GPT composition. No CLI or installation admission.

Caller owns namespace, trusted lease and exclusive source claim. Metadata
commit alone never authorizes kernel transition or root formatting.
"""
import fcntl
import importlib.util
import os
import re
import stat
import struct
from pathlib import Path

spec = importlib.util.spec_from_file_location('ro_commit_gpt', Path(__file__).with_name('ro_installer_gpt.py'))
gpt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gpt)


def _companion(name):
    spec = importlib.util.spec_from_file_location('ro_commit_' + name,
        Path(__file__).with_name('ro_installer_' + name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ntfs, manual = _companion('ntfs'), _companion('manual')


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


class NtfsTransactionError(RuntimeError):
    def __init__(self, phase, source_may_have_changed, gpt_write_started=False,
                 verified_gpt_copies=0, cleanup_failed=False):
        super().__init__('NTFS_TRANSACTION_FAILED')
        self.phase = phase
        self.source_may_have_changed = source_may_have_changed
        self.gpt_write_started = gpt_write_started
        self.verified_gpt_copies = verified_gpt_copies
        self.cleanup_failed = cleanup_failed


def _source_binding(reader, writer, proposal):
    before = proposal['snapshot']
    source = next(part for part in before['partitions'] if part['number'] == proposal['sourceNumber'])
    observed = []
    for fd, mode in ((reader, os.O_RDONLY), (writer, os.O_RDWR)):
        flags = fcntl.fcntl(fd, fcntl.F_GETFL)
        if flags & os.O_ACCMODE != mode or flags & (os.O_PATH | os.O_APPEND):
            raise ValueError('Invalid source access')
        observed.append(manual.partition_descriptor(before, source, fd))
        sector = struct.unpack('=I', fcntl.ioctl(fd, 0x1268, bytes(4)))[0]
        if sector != before['logicalSectorBytes']: raise ValueError('Source sector changed')
    if observed[0] != observed[1]: raise ValueError('Source descriptions disagree')


def resize_and_commit_ntfs(io, proposal, root_guid, preservation_fingerprint,
                           inspection_fingerprint, preparation_fingerprint,
                           source_read_fd, source_write_fd, lease_fd):
    """Private composition through metadata commit, never kernel-ready admission.

    Caller owns the trusted session/namespace/lease, exclusive source claim and
    whole-disk IO. All original partition descriptions must close before any
    kernel reread. This function owns only duplicates, never repairs or retries,
    and returns a verified GPT snapshot rather than installation targets.
    """
    phase, changed, table_started, copies, cleanup_failed = 'prepare', False, False, 0, False
    descriptors, result, error = [], None, None
    try:
        if (any(type(fd) is not int or fd < 3 for fd in (source_read_fd, source_write_fd, lease_fd))
                or len({source_read_fd, source_write_fd, lease_fd}) != 3
                or os.environ.get('RO_INSTALLER_LEASE_FD') != str(lease_fd)
                or not stat.S_ISREG(os.fstat(lease_fd).st_mode)
                or any(not isinstance(value, str) or not re.fullmatch('[0-9a-f]{64}', value)
                       for value in (inspection_fingerprint, preparation_fingerprint))):
            raise ValueError('Invalid transaction binding')
        proposal = dict(proposal, snapshot=gpt.normalize_snapshot(proposal['snapshot']))
        plan = gpt.ntfs_shrink_plan(proposal)
        before = proposal['snapshot']; sector = before['logicalSectorBytes']
        size = (plan['source']['endSector'] - plan['source']['startSector'] + 1) * sector
        target = plan['source']['retainedBytes']
        if type(io.sector) is not int or io.sector != sector or gpt.identity(io.device) != before['device']:
            raise ValueError('Transaction IO differs from approved device')
        def guarded():
            if io.guard() is not True: raise ValueError('Transaction context refused')
        guarded()
        for fd in (source_read_fd, source_write_fd):
            descriptors.append(fcntl.fcntl(fd, fcntl.F_DUPFD_CLOEXEC, 3))
        reader, writer = descriptors
        def bound():
            guarded(); _source_binding(reader, writer, proposal)
        bound()
        patches = gpt.ntfs_gpt_update_plan(io.read, proposal, root_guid, preservation_fingerprint)
        original_boot = ntfs.boot_sector(reader, size, sector)[0]
        preparation = ntfs.prepare_resize_target(reader, size, sector, target, inspection_fingerprint)
        if preparation['preparationFingerprint'] != preparation_fingerprint:
            raise ValueError('Target preparation changed')
        bound()
        if (ntfs.boot_sector(reader, size, sector)[0] != original_boot
                or gpt.ntfs_gpt_update_plan(io.read, proposal, root_guid, preservation_fingerprint) != patches):
            raise ValueError('Transaction preimage changed')
        phase, changed = 'native', True
        try:
            if ntfs.run_native_resize(writer, size, sector, target, lease_fd) is not True:
                raise ValueError('Native writer did not complete')
        except ntfs.NativeResizeError as failure:
            changed, cleanup_failed = failure.started, failure.cleanup_failed
            raise
        phase = 'filesystem'
        bound()
        ntfs.inspect_resized_fd(reader, size, target, sector, original_boot)
        bound()
        phase = 'gpt'
        class BoundIo:
            device, sector = io.device, io.sector
            read, write, flush = staticmethod(io.read), staticmethod(io.write), staticmethod(io.flush)
            def guard(self):
                bound()
                return True
        try:
            result = commit_ntfs_gpt(BoundIo(), proposal, root_guid, preservation_fingerprint)
            table_started, copies = True, 2
        except GptCommitError as failure:
            table_started, copies = failure.write_started, failure.verified_copies
            cleanup_failed = cleanup_failed or failure.cleanup_failed
            phase = 'gpt.' + failure.phase
            raise
        phase = 'metadata-committed'
    except Exception:
        error = NtfsTransactionError(phase, changed, table_started, copies, cleanup_failed)
    finally:
        for fd in descriptors:
            try: os.close(fd)
            except OSError:
                if error is None: error = NtfsTransactionError('cleanup', changed, table_started, copies, True)
                else: error.cleanup_failed = True
    if error is not None: raise error from None
    return result


if __name__ == '__main__':
    raise SystemExit(2)
