"""Manual metadata/FS eligibility using fake devices and sparse regular files."""
import ast
import copy
import io
import json
import os
from pathlib import Path
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout, redirect_stderr
from types import SimpleNamespace
from unittest import mock
import installer_helper_test as legacy
from gpt_probe_test import FakeGptSystem, SysPath

helper = legacy.helper
gpt = helper.gpt_module()
worker = legacy.load_module('manual_worker', legacy.ROOT / 'linux/ro_installer_manual.py')


def fixture():
    return json.loads((legacy.ROOT / 'test/fixtures/manual_installation_plan_v1.json').read_text())


def choices():
    f = fixture()
    return {role: f[role] for role in ('esp', 'root')}


def request():
    s = fixture()['snapshot']
    return {'protocolVersion': 2, 'operation': 'validate-manual-plan', 'disk': s['device']['path'],
            'expectedDevice': {k: v for k, v in s['device'].items() if k != 'path'},
            'tableFingerprint': s['tableFingerprint'], **choices()}


class System(FakeGptSystem):
    def __init__(self):
        super().__init__(); self.snapshot = fixture()['snapshot']; self.manual_calls = 0; self.drift = False

    def gpt_snapshot(self, device, manual_roles=None):
        if manual_roles is None:
            return copy.deepcopy(self.snapshot)
        self.manual_calls += 1
        value = copy.deepcopy(self.snapshot)
        if self.drift:
            value['tableFingerprint'] = 'b' * 64
        return {'snapshot': value, 'plan': gpt.manual_plan(value, manual_roles)}


class AdmissionTests(unittest.TestCase):
    def error(self, code, action, *args, **kwargs):
        with self.assertRaises(helper.HelperError) as caught:
            action(*args, **kwargs)
        self.assertEqual(caught.exception.code, code)

    def parse(self, value=None, version=2):
        return helper.parse_request(json.dumps(value or request()).encode(), version)

    def test_strict_v2_choices_no_inventory_commands_or_write_authority(self):
        self.assertEqual(self.parse().manual_choices, choices())
        for patch in [{'sourceSnapshot': fixture()['snapshot']}, {'confirmDestructive': True},
                      {'confirmedPlan': {}}, {'tableFingerprint': True},
                      {'root': {'source': 'existing', 'number': 2, 'formatOnInstall': 1}},
                      {'root': {'source': 'existing', 'number': 2, 'formatOnInstall': False}},
                      {'esp': {**choices()['esp'], 'path': '/dev/vdb1'}}]:
            self.error('INVALID_REQUEST', self.parse, {**request(), **patch})
        self.error('INVALID_REQUEST', self.parse, {**request(), 'protocolVersion': 1}, 1)
        for op in ('install-manual', 'install-manual-plan'):
            self.error('INVALID_REQUEST', self.parse, {**request(), 'operation': op})

    def test_under_lease_recomputes_roles_and_never_starts_backend(self):
        system = System()
        with mock.patch.object(helper.os, 'geteuid', return_value=0), \
             mock.patch.object(helper, 'InstallerLock') as lock, mock.patch.object(helper, 'run_backend') as backend:
            lock.return_value.__enter__.return_value.fd = 123
            self.assertEqual(helper.handle(self.parse(), system), {'plan': gpt.manual_plan(system.snapshot, choices())})
            self.assertEqual(system.manual_calls, 1)
            backend.assert_not_called()
            self.assertFalse(hasattr(system, 'lease_fd'))

    def test_stale_table_device_or_probe_drift_is_rejected(self):
        with mock.patch.object(helper.os, 'geteuid', return_value=0), mock.patch.object(helper, 'InstallerLock'):
            self.error('DEVICE_CHANGED', helper.handle, self.parse({**request(), 'tableFingerprint': 'b' * 64}), System())
            self.error('DEVICE_CHANGED', helper.handle, self.parse({**request(), 'expectedDevice': {**request()['expectedDevice'], 'diskSequence': 12}}), System())
            system = System(); system.drift = True
            self.error('DEVICE_CHANGED', helper.handle, self.parse(), system)
            self.assertFalse(hasattr(system, 'lease_fd'))

    def test_root_platform_busy_and_occupied_ranges_reject_before_fs_reader(self):
        system = System()
        with mock.patch.object(helper.os, 'geteuid', return_value=1000):
            self.error('ROOT_REQUIRED', helper.handle, self.parse(), system)
        with mock.patch.object(helper.os, 'geteuid', return_value=0):
            system.supported = False
            self.error('UNSUPPORTED_PLATFORM', helper.handle, self.parse(), system)
            system.supported = True
            with mock.patch.object(helper, 'InstallerLock', side_effect=helper.HelperError('BUSY', 'busy')):
                self.error('BUSY', helper.handle, self.parse(), system)
            with mock.patch.object(helper, 'InstallerLock'):
                bad = {**request(), 'root': {'source': 'create', 'startSector': 2048, 'endSector': 100000000}}
                self.error('INVALID_REQUEST', helper.handle, self.parse(bad), system)
        self.assertEqual(system.manual_calls, 0)

    def test_manual_worker_transport_checks_result_and_inherits_exact_lease(self):
        system = helper.System()
        device = helper.Device('/dev/vda', '252:0', fixture()['snapshot']['device']['size'], 11, '/sys/mock/vda')
        with tempfile.TemporaryDirectory() as td:
            lease = os.open(Path(td) / 'lease', os.O_CREAT | os.O_RDWR, 0o600)
            try:
                system.lease_fd = lease
                stub = Path(td) / 'worker.py'
                value = {'snapshot': fixture()['snapshot'], 'plan': gpt.manual_plan(fixture()['snapshot'], choices())}
                stub.write_text(f"import os\nos.fstat(int(os.environ['RO_INSTALLER_LEASE_FD']))\nprint({json.dumps(value)!r})\n")
                with mock.patch.object(helper, 'MANUAL_ARGV', (sys.executable, '-I', str(stub))):
                    self.assertEqual(system.gpt_snapshot(device, manual_roles=choices()), value)
                    value['plan']['esp']['formatOnInstall'] = True
                    stub.write_text(f'print({json.dumps(value)!r})\n')
                    self.error('AMBIGUOUS_TOPOLOGY', system.gpt_snapshot, device, manual_roles=choices())
                    stub.write_text("print('X'*9000)\n")
                    self.error('AMBIGUOUS_TOPOLOGY', system.gpt_snapshot, device, manual_roles=choices())
            finally:
                os.close(lease)


class FilesystemTests(unittest.TestCase):
    def test_export_allowlist_rejects_crypto_raid_missing_ambiguous_and_duplicate_fields(self):
        self.assertEqual(worker.parse_blkid(b'TYPE=vfat\nVERSION=FAT32\nUSAGE=filesystem\nLABEL=PRIVATE\n'), 'vfat')
        for fs in ('btrfs', 'ext4', 'xfs'):
            self.assertEqual(worker.parse_blkid(f'TYPE={fs}\nUSAGE=filesystem\n'.encode()), fs)
        for raw in [b'TYPE=vfat\nVERSION=FAT16\nUSAGE=filesystem\n', b'TYPE=crypto_LUKS\nUSAGE=crypto\n',
                    b'TYPE=LVM2_member\nUSAGE=raid\n', b'TYPE=ext4\n', b'TYPE=xfs\nTYPE=ext4\nUSAGE=filesystem\n',
                    b'TYPE=xfs\nUSAGE=filesystem\nBAD LINE', b'X'*4097, b'\xff']:
            with self.assertRaises(ValueError): worker.parse_blkid(raw)

    def test_roles_require_fs_eligibility_and_reprobe_entire_gpt_afterwards(self):
        source = fixture()['snapshot']; device = source['device']
        with mock.patch.object(worker, 'probe_device', return_value=source) as probe, \
             mock.patch.object(worker, 'probe_filesystem', side_effect=['vfat', 'ext4']) as fs:
            result = worker.probe_manual('/dev/vda', device, choices())
            self.assertEqual(result['plan'], gpt.manual_plan(source, choices()))
            self.assertEqual(probe.call_count, 2); self.assertEqual(fs.call_count, 2)
        for types in (['ext4', 'btrfs'], ['vfat', 'vfat']):
            with mock.patch.object(worker, 'probe_device', return_value=source), \
                 mock.patch.object(worker, 'probe_filesystem', side_effect=types):
                with self.assertRaises(ValueError): worker.probe_manual('/dev/vda', device, choices())
        changed = copy.deepcopy(source); changed['tableFingerprint'] = 'b'*64
        with mock.patch.object(worker, 'probe_device', side_effect=[source, changed]), \
             mock.patch.object(worker, 'probe_filesystem', side_effect=['vfat', 'xfs']):
            with self.assertRaises(ValueError): worker.probe_manual('/dev/vda', device, choices())

    def test_partition_descriptor_uses_fd_identity_size_sequence_and_kernel_geometry(self):
        s = fixture()['snapshot']; part = gpt.manual_plan(s, choices())['esp']; parent = '/sys/dev/block/252:0'
        files = {parent+'/diskseq': '11', parent+'/size': str(s['device']['size']//512),
                 parent+'/vda1/dev': '252:1', parent+'/vda1/partition': '1',
                 parent+'/vda1/start': str(part['startSector']), parent+'/vda1/size': str(part['endSector']-part['startSector']+1)}
        original_path = Path
        def path(value):
            return SysPath(value, files, []) if str(value).startswith('/sys/') else original_path(value)
        local_os = SimpleNamespace(**vars(os))
        info = SimpleNamespace(st_mode=stat.S_IFBLK, st_rdev=os.makedev(252,1))
        def ioctl(fd, code, raw):
            return struct.pack('=Q', 512*1024*1024 if code == 0x80081272 else 11)
        with mock.patch.object(worker, 'Path', side_effect=path), mock.patch.object(worker, 'os', local_os), \
             mock.patch.object(local_os, 'fstat', return_value=info), mock.patch.object(worker.fcntl, 'ioctl', side_effect=ioctl):
            self.assertEqual(worker.partition_descriptor(s, part, 17), ('/dev/vda1','252:1'))
            info.st_rdev = os.makedev(252,2)
            with self.assertRaises(ValueError): worker.partition_descriptor(s, part, 17)
            info.st_rdev = os.makedev(252,1); info.st_mode = stat.S_IFREG
            with self.assertRaises(ValueError): worker.partition_descriptor(s, part, 17)
            info.st_mode = stat.S_IFBLK
            files[parent+'/vda1/start'] = '4096'
            with self.assertRaises(ValueError): worker.partition_descriptor(s, part, 17)

    def test_4kn_partition_geometry_uses_kernel_512_byte_units(self):
        source = fixture()['snapshot']
        for part in source['partitions']:
            part['startSector'] //= 8; part['endSector'] = (part['endSector']+1)//8-1
        source['logicalSectorBytes']=4096
        source['firstUsableSector']=256
        source['lastUsableSector']=source['device']['size']//4096-6
        source['backupEntriesLba']=source['device']['size']//4096-5
        binding = gpt.manual_plan(source,choices())['esp']
        parent='/sys/dev/block/252:0'
        files={parent+'/diskseq':'11',parent+'/size':str(source['device']['size']//512),
               parent+'/vda1/dev':'252:1',parent+'/vda1/partition':'1',
               parent+'/vda1/start':'2048',parent+'/vda1/size':'1048576'}
        original_path=Path
        def path(value):
            return SysPath(value,files,[]) if str(value).startswith('/sys/') else original_path(value)
        with mock.patch.object(worker,'Path',side_effect=path):
            self.assertEqual(worker.partition_descriptor(source,binding),('/dev/vda1','252:1'))
            files[parent+'/vda1/start']='256'
            with self.assertRaises(ValueError):worker.partition_descriptor(source,binding)

    def test_new_roles_skip_all_existing_filesystem_probes(self):
        source=fixture()['snapshot']
        selected={'esp':{'source':'create','startSector':80*1024**3//512,'endSector':81*1024**3//512-1},
                  'root':{'source':'create','startSector':100*1024**3//512,'endSector':150*1024**3//512-1}}
        with mock.patch.object(worker,'probe_device',return_value=source),mock.patch.object(worker,'probe_filesystem') as fs:
            self.assertEqual(worker.probe_manual('/dev/vda',source['device'],selected)['plan'],gpt.manual_plan(source,selected))
            fs.assert_not_called()

    def test_real_blkid_uses_only_inherited_readonly_fd_and_never_exports_label(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td)/'fat32.img'
            with path.open('wb') as stream: stream.truncate(512*1024*1024)
            subprocess.run(['mkfs.fat','-F32','-n','PRIVATE',str(path)],capture_output=True,check=True,timeout=10)
            seen = []
            def descriptor(snapshot, part, fd=None):
                if fd is not None: seen.append(fd)
                return str(path), '252:1'
            lease = os.open(Path(td)/'lease',os.O_CREAT|os.O_RDWR,0o600)
            local_os = SimpleNamespace(**vars(os))
            real_open = os.open
            opens = []
            def opened(name, flags):
                opens.append((name,flags)); return real_open(name,flags)
            real_popen = subprocess.Popen
            def popen(argv, **kwargs):
                self.assertEqual(argv[:5], ('/usr/sbin/blkid','-p','-o','export','--'))
                self.assertRegex(argv[-1],r'^/proc/self/fd/[0-9]+$')
                self.assertIn(lease, kwargs['pass_fds'])
                return real_popen(argv, **kwargs)
            try:
                with mock.patch.object(worker,'os',local_os), mock.patch.object(local_os,'open',side_effect=opened), \
                     mock.patch.object(worker,'partition_descriptor',side_effect=descriptor), \
                     mock.patch.dict(os.environ,{'RO_INSTALLER_LEASE_FD':str(lease)}), \
                     mock.patch.object(worker.subprocess,'Popen',side_effect=popen):
                    self.assertEqual(worker.probe_filesystem(fixture()['snapshot'],{}),'vfat')
                self.assertEqual(opens,[(str(path),os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW|os.O_NONBLOCK|os.O_EXCL)])
                self.assertEqual(len(seen),2)
                with self.assertRaises(OSError): os.fstat(seen[0])
            finally: os.close(lease)

    def test_stream_limits_deadline_nonzero_and_fd_cleanup(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td)/'regular.img'; path.write_bytes(b'')
            stub = Path(td)/'stub.py'
            real_popen = subprocess.Popen
            for body in ["print('X'*5000)", "import sys;sys.stderr.write('X'*5000)",
                         "import time;time.sleep(60)", "import sys;print('TYPE=ext4\\nUSAGE=filesystem');sys.exit(8)"]:
                stub.write_text(body)
                children, descriptors = [], []
                def descriptor(snapshot, binding, fd=None):
                    if fd is not None: descriptors.append(fd)
                    return str(path), '252:1'
                def popen(argv, **kwargs):
                    child = real_popen((sys.executable,'-I',str(stub)), **kwargs)
                    children.append(child)
                    return child
                with mock.patch.object(worker,'partition_descriptor',side_effect=descriptor), \
                     mock.patch.object(worker,'FILESYSTEM_TIMEOUT',0.15), \
                     mock.patch.object(worker.subprocess,'Popen',side_effect=popen):
                    with self.assertRaises((ValueError,subprocess.TimeoutExpired)):
                        worker.probe_filesystem(fixture()['snapshot'],{})
                self.assertTrue(all(child.poll() is not None for child in children))
                with self.assertRaises(OSError): os.fstat(descriptors[0])

    def test_worker_has_only_fixed_readonly_subprocess_and_no_disk_write_api(self):
        tree = ast.parse((legacy.ROOT/'linux/ro_installer_manual.py').read_text())
        calls = [n for n in ast.walk(tree) if isinstance(n,ast.Call) and isinstance(n.func,ast.Attribute)
                 and isinstance(n.func.value,ast.Name) and n.func.value.id == 'subprocess']
        self.assertEqual(len(calls),1); self.assertEqual(calls[0].func.attr,'Popen')
        self.assertEqual(calls[0].args[0].id,'argv')
        programs={n.elts[0].value for n in ast.walk(tree) if isinstance(n,ast.Tuple) and n.elts and isinstance(n.elts[0],ast.Constant) and isinstance(n.elts[0].value,str) and n.elts[0].value.startswith('/usr/')}
        self.assertEqual(programs,{'/usr/sbin/blkid','/usr/sbin/fsck.fat','/usr/bin/btrfs'})
        self.assertFalse(any(k.arg=='shell' for k in calls[0].keywords))
        for n in ast.walk(tree):
            if isinstance(n,ast.Call) and isinstance(n.func,ast.Attribute) and isinstance(n.func.value,ast.Name) and n.func.value.id=='os':
                self.assertNotIn(n.func.attr,{'write','pwrite','truncate','ftruncate','system','unlink','remove'})
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(worker.os,'geteuid',return_value=0), \
             mock.patch.object(sys,'argv',['worker','/dev/vda','{}','{}']), \
             mock.patch.object(worker,'probe_manual',side_effect=ValueError('PRIVATE')),redirect_stdout(out),redirect_stderr(err):
            self.assertEqual(worker.main(),2)
        self.assertEqual(out.getvalue()+err.getvalue(),'')


if __name__ == '__main__':
    unittest.main(verbosity=2)
