"""Bounded, descriptor-relative session records. No raw command/output storage.

One writer per supervisor; an independent store lock reserves the worst-case
session size, so parallel starts cannot exceed the store quota. Logging failure
is state, never an installation exception. No caller-selected production path.
"""
import datetime
import errno
import fcntl
import json
import itertools
import os
from pathlib import Path
import re
import secrets
import stat
import threading
import time

SCHEMA = json.loads(Path(__file__).with_name('ro-installer-observability.json').read_text())
LIMITS = SCHEMA['limits']
STORE = '/run/ro-installer/records'
SPAN_IDS = tuple(SCHEMA['objects']['span']['operationId'][1])


def validate(value, rule):
    kind, *args = rule
    if kind == 'nullable':
        return value is None or validate(value, args[0])
    if kind == 'literal':
        return type(value) is type(args[0]) and value == args[0]
    if kind == 'int':
        return type(value) is int and args[0] <= value <= args[1]
    if kind == 'enum':
        return type(value) is str and value in args[0]
    if kind == 'hex':
        return type(value) is str and re.fullmatch('[0-9a-f]{%d}' % args[0], value) is not None
    if kind == 'utc':
        if type(value) is not str or not re.fullmatch(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z', value):
            return False
        try:
            datetime.datetime.fromisoformat(value)
            return True
        except ValueError:
            return False
    if kind == 'array':
        return type(value) is list and len(value) <= args[0] and all(validate(v, args[1]) for v in value)
    if kind == 'object':
        fields = SCHEMA['objects'][args[0]]
        return (type(value) is dict and set(value) == set(fields)
                and all(validate(value[k], r) for k, r in fields.items()))
    return False


def valid_report(value):
    if not validate(value, ['object', 'report']):
        return False
    if len(encoded(value)) > LIMITS['reportBytes']:
        return False
    if [s['stageId'] for s in value['stages']] != list(range(1, 10)):
        return False
    if [s['operationId'] for s in value['spans']] != list(SPAN_IDS):
        return False
    if any((s['status'] == 'notStarted') != (s['durationMs'] is None)
           for s in value['stages'] + value['spans']):
        return False
    if value['terminalStatus']=='success' and (
            value['failedStage'] is not None or value['primaryError'] is not None
            or value['cleanupStatus']!='success' or value['remainingResources']!=0
            or value['lastSuccessfulStage']!=9 or value['engineDurationMs'] is None
            or any(s['status']!='success' for s in value['stages'])):
        return False
    return True


def encoded(value):
    return json.dumps(value, separators=(',', ':'), ensure_ascii=True, allow_nan=False).encode() + b'\n'


def trusted(fd, uid, directory=False):
    info = os.fstat(fd)
    expected = 0o700 if directory else 0o600
    if ((not stat.S_ISDIR(info.st_mode) if directory else not stat.S_ISREG(info.st_mode))
            or info.st_uid != uid or info.st_gid != (0 if uid == 0 else os.getegid())
            or stat.S_IMODE(info.st_mode) != expected
            or not directory and info.st_nlink != 1):
        raise PermissionError('Unsafe record object')
    return info


def open_store(path, uid, *, test_store=False):
    # Production always passes STORE. The injectable path/uid are test-only.
    current = os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        for index, part in enumerate(Path(path).parts[1:]):
            if part in ('.', '..'):
                raise PermissionError('Invalid store path')
            final = index == len(Path(path).parts[1:]) - 1
            try:
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=current)
            except FileNotFoundError:
                # Do not create caller-selected ancestors. InstallerLock creates
                # the trusted /run/ro-installer anchor before this call.
                if not final:
                    raise
                os.mkdir(part, 0o700, dir_fd=current)
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=current)
            info = os.fstat(child)
            if final:
                try:
                    trusted(child, uid, directory=True)
                except BaseException:
                    os.close(child)
                    raise
            elif info.st_uid not in (0, uid) or stat.S_IMODE(info.st_mode) & 0o022:
                # /tmp is allowed only as an ancestor of a private test tree;
                # production has no writable ancestors.
                if not (test_store and stat.S_ISVTX & info.st_mode and info.st_uid == 0):
                    os.close(child)
                    raise PermissionError('Unsafe ancestor')
            os.close(current)
            current = child
        return current
    except BaseException:
        os.close(current)
        raise


class Recorder:
    def __init__(self, *, directory=STORE, owner_uid=0, limits=None,
                 monotonic=time.monotonic_ns, write=os.write, started_ns=None):
        self.sid = secrets.token_hex(16)
        self.limits = dict(LIMITS if limits is None else limits)
        self.monotonic, self.write = monotonic, write
        self.started = monotonic() if started_ns is None else started_ns
        self.lock = threading.RLock()
        self.fd = self.directory_fd = None
        self.events = self.bytes = 0
        self.io_calls = 0
        self.terminal = False
        self.observed_starts = {}
        self.operation_stack = []
        self.current_stage = None
        self.current_operation = 'unclassified'
        self.report = {
            'schemaVersion': 1, 'sessionId': self.sid, 'terminalStatus': 'running',
            'startedAtUtc': datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='milliseconds').replace('+00:00','Z'),
            'finishedAtUtc': None,
            'failedStage': None, 'lastSuccessfulStage': 0, 'primaryError': None,
            'cleanupStatus': 'notRun', 'remainingResources': None,
            'sessionError': None, 'remainingSessionResources': None,
            'lastFailedOperation': None, 'lastExitCode': None,
            'engineDurationMs': None, 'supervisorDurationMs': None,
            'logStatus': 'recording', 'logError': None,
            'stages': [{'stageId': i, 'status': 'notStarted', 'durationMs': None} for i in range(1, 10)],
            'spans': [{'operationId': i, 'status': 'notStarted', 'durationMs': None} for i in SPAN_IDS],
            'bytesTransferred': None, 'throughput': None,
        }
        store = reserve = None
        try:
            store = open_store(directory, owner_uid, test_store=directory != STORE)
            try:
                reserve = os.open('.store.lock', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=store)
            except FileExistsError:
                reserve = os.open('.store.lock', os.O_WRONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=store)
            trusted(reserve, owner_uid)
            fcntl.flock(reserve, fcntl.LOCK_EX | fcntl.LOCK_NB)
            # Reservation uses full per-session caps (including a temporary
            # atomic summary). No disk walk or scan per event.
            with os.scandir(store) as entries:
                count = used = 0
                for entry in entries:
                    if entry.name == '.store.lock':
                        continue
                    if not re.fullmatch('[0-9a-f]{32}', entry.name) or not entry.is_dir(follow_symlinks=False):
                        raise PermissionError('Unexpected store object')
                    child = os.open(entry.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=store)
                    try:
                        trusted(child, owner_uid, True)
                        size = 0
                        active = False
                        with os.scandir(child) as contents:
                            members = list(itertools.islice(contents,4))
                        if len(members) > 3:
                            raise PermissionError('Unexpected session contents')
                        for member in members:
                            if member.name not in ('events.jsonl','summary.json') and not re.fullmatch(r'\.summary-[0-9a-f]{32}', member.name):
                                raise PermissionError('Unexpected record member')
                            item_fd = os.open(member.name,os.O_RDONLY|os.O_NONBLOCK|os.O_NOFOLLOW|os.O_CLOEXEC,dir_fd=child)
                            try:
                                info = trusted(item_fd,owner_uid)
                                bound = self.limits['sessionBytes'] if member.name == 'events.jsonl' else self.limits['summaryBytes']
                                if info.st_size > bound:
                                    raise PermissionError('Oversize record')
                                size += info.st_size
                                if member.name == 'events.jsonl':
                                    try:fcntl.flock(item_fd,fcntl.LOCK_SH|fcntl.LOCK_NB)
                                    except BlockingIOError:active=True
                            finally:os.close(item_fd)
                        used += self.limits['sessionBytes'] + 2*self.limits['summaryBytes'] if active else size
                    finally:
                        os.close(child)
                    count += 1
                    if count >= self.limits['sessions']:
                        raise OSError(errno.ENOSPC, 'Store full')
                reservation = self.limits['sessionBytes'] + 2 * self.limits['summaryBytes']
                if used + reservation > self.limits['storeBytes']:
                    raise OSError(errno.ENOSPC, 'Store full')
            os.mkdir(self.sid, 0o700, dir_fd=store)
            self.directory_fd = os.open(self.sid, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=store)
            trusted(self.directory_fd, owner_uid, True)
            self.fd = os.open('events.jsonl', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=self.directory_fd)
            trusted(self.fd, owner_uid)
            fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.owner_uid = owner_uid
            self.checkpoint()
        except Exception as error:
            self.report['logStatus'] = 'unavailable'
            self.report['logError'] = 'LOG_STORE_FULL' if getattr(error, 'errno', None) in (errno.ENOSPC, errno.EWOULDBLOCK) else 'LOG_STORE_UNSAFE'
        finally:
            if reserve is not None:
                os.close(reserve)
            if store is not None:
                os.close(store)

    def elapsed(self):
        return max(0, min(86400000, (self.monotonic() - self.started) // 1000000))

    def _write_all(self, fd, data):
        while data:
            self.io_calls += 1
            written = self.write(fd, data)
            if written <= 0:
                raise OSError(errno.EIO, 'Short record write')
            data = data[written:]

    def _failure(self, code):
        if self.report['logStatus'] not in ('unavailable', 'failed'):
            self.report['logStatus'] = 'failed'
            self.report['logError'] = code

    def observe(self, value, role='engine'):
        with self.lock:
            if not validate(value, ['object', 'payload']):
                self._failure('LOG_SCHEMA_INVALID')
                return False
            if self.terminal:
                return False
            kind = value['eventType']
            if kind.startswith('span.'):
                if kind=='span.start':
                    if len(self.operation_stack)>=16:
                        self._failure('LOG_SCHEMA_INVALID')
                        return False
                    self.operation_stack.append(value['operationId'])
                elif self.operation_stack and self.operation_stack[-1]==value['operationId']:
                    self.operation_stack.pop()
                self.current_operation=self.operation_stack[-1] if self.operation_stack else 'stage.command'
            if kind=='command.end' and value['exitCode'] is not None and value['exitCode']!=0:
                self.report.update(lastFailedOperation=value['operationId'],lastExitCode=value['exitCode'])
            identity = ('stage',value['stageId']) if kind.startswith('stage.') else ('span',value['operationId'])
            if kind.endswith('.start') and kind.startswith(('stage.','span.')):
                self.observed_starts[identity]=self.monotonic()
            elif kind.endswith('.end'):
                self.observed_starts.pop(identity,None)
            stage = value['stageId']
            if kind.startswith('stage.') and stage is not None:
                self.report['stages'][stage - 1].update(status=value['status'], durationMs=value['durationMs'])
                if kind == 'stage.end':
                    if value['status'] == 'success':
                        self.report['lastSuccessfulStage'] = stage
                    elif value['status'] in ('failed', 'interrupted') and self.report['failedStage'] is None:
                        self.report['failedStage'] = stage
                self.current_stage = stage if kind == 'stage.start' else None
            if kind.startswith('span.') and value['operationId'] in SPAN_IDS:
                item = self.report['spans'][SPAN_IDS.index(value['operationId'])]
                item.update(status=value['status'], durationMs=value['durationMs'])

            event = {'schemaVersion': 1, 'sessionId': self.sid, 'seq': self.events + 1,
                     'timestampUtc': datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z'),
                     'processRole': role, **value}
            raw = encoded(event)
            if (len(raw) > self.limits['eventBytes'] or self.events >= self.limits['events']
                    or self.bytes + len(raw) > self.limits['sessionBytes']):
                if self.report['logStatus'] == 'recording':
                    self.report.update(logStatus='truncated', logError='LOG_LIMIT')
                return False
            if self.report['logStatus'] != 'recording' or self.fd is None:
                return False
            try:
                self._write_all(self.fd, raw)
                self.events += 1
                self.bytes += len(raw)
                if kind in ('stage.end', 'engine.end', 'session.end'):
                    self.checkpoint()
                return True
            except Exception:
                self._failure('LOG_WRITE_FAILED')
                return False

    def checkpoint(self):
        if self.directory_fd is None or self.report['logStatus'] in ('unavailable', 'failed'):
            return False
        name = '.summary-' + secrets.token_hex(16)
        fd = None
        try:
            raw = encoded(self.report)
            if len(raw) > self.limits['summaryBytes']:
                raise OSError(errno.EFBIG, 'Summary limit')
            # Existing summary must be our regular, singly-linked file.
            try:
                previous = os.open('summary.json', os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=self.directory_fd)
            except FileNotFoundError:
                previous = None
            if previous is not None:
                try:
                    trusted(previous, self.owner_uid)
                finally:
                    os.close(previous)
            fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=self.directory_fd)
            trusted(fd, self.owner_uid)
            self._write_all(fd, raw)
            os.fsync(fd)
            self.io_calls += 1
            os.rename(name, 'summary.json', src_dir_fd=self.directory_fd, dst_dir_fd=self.directory_fd)
            self.io_calls += 1
            return True
        except Exception:
            self._failure('LOG_WRITE_FAILED')
            return False
        finally:
            if fd is not None:
                os.close(fd)
            try:
                os.unlink(name, dir_fd=self.directory_fd)
            except FileNotFoundError:
                pass
            except OSError:
                self._failure('LOG_WRITE_FAILED')

    def outcome(self, value):
        with self.lock:
            if not validate(value, ['object', 'outcome']) or self.terminal:
                self._failure('LOG_SCHEMA_INVALID')
                return False
            self.report.update(value)
            return self.checkpoint()

    def finish(self, status, error=None, remaining=None):
        with self.lock:
            if self.terminal:
                return self.report.copy()
            self.report.update(sessionError=error, remainingSessionResources=remaining,finishedAtUtc=datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='milliseconds').replace('+00:00','Z'))
            if self.report['terminalStatus'] == 'running':
                if status==0:
                    self.report.update(terminalStatus='unknown',primaryError=None,cleanupStatus='unknown',
                                       sessionError='OBSERVATION_INCOMPLETE')
                    if self.report['logStatus']=='recording':
                        self.report.update(logStatus='incomplete',logError='LOG_OBSERVATION_LOST')
                else:
                    self.report.update(terminalStatus='failed' if error=='NAMESPACE_FAILED' else 'incomplete', primaryError=error or 'ENGINE_CRASH', cleanupStatus='notRun' if error=='NAMESPACE_FAILED' else 'unknown',remainingResources=0 if error=='NAMESPACE_FAILED' else None)
            elif status != 0 and self.report['terminalStatus'] == 'success':
                self.report.update(terminalStatus='failed', primaryError=error or 'SESSION_FINALIZATION_FAILED',sessionError=error or 'SESSION_FINALIZATION_FAILED')
            for item in self.report['stages'] + self.report['spans']:
                if item['status'] == 'running':
                    stage=item.get('stageId')
                    operation=item.get('operationId','stage.command')
                    key=('stage',stage) if stage is not None else ('span',operation)
                    start=self.observed_starts.get(key,self.monotonic())
                    duration=max(0,min(86400000,(self.monotonic()-start)//1000000))
                    self.observe({'eventType':'stage.end' if stage is not None else 'span.end','stageId':stage,
                                  'operationId':operation,'status':'interrupted','durationMs':duration,
                                  'exitCode':None,'errorCode':error or 'ENGINE_CRASH'},role='supervisor')
            self.report['supervisorDurationMs'] = self.elapsed()
            self.observe({'eventType': 'session.end', 'stageId': None, 'operationId': 'session',
                          'status': 'success' if status == 0 else 'failed', 'durationMs': self.elapsed(),
                          'exitCode': status, 'errorCode': error}, role='supervisor')
            if self.report['logStatus'] == 'recording':
                self.report['logStatus'] = 'complete'
            self.checkpoint()
            self.terminal = True
            return json.loads(json.dumps(self.report))

    def close(self):
        with self.lock:
            for name in ('fd', 'directory_fd'):
                fd = getattr(self, name)
                if fd is not None:
                    os.close(fd)
                    setattr(self, name, None)
