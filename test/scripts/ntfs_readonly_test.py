"""NTFS read-only checks against freshly created regular files, never devices."""
import hashlib
import ctypes as c
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout, redirect_stderr
from unittest import mock
from types import SimpleNamespace

ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('ntfs_worker',ROOT/'linux/ro_installer_ntfs.py')
worker=importlib.util.module_from_spec(spec);spec.loader.exec_module(worker)
SIZE=256*1024*1024


def digest(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()


def image(directory,sector=512):
    path=Path(directory)/f'ntfs-{sector}.img'
    with path.open('wb') as stream:stream.truncate(SIZE)
    subprocess.run(['/usr/bin/mkntfs','-F','-Q','-s',str(sector),'-c','4096',str(path)],capture_output=True,check=True,timeout=20)
    return path


def inspect(path,sector=512):
    fd=os.open(path,os.O_RDONLY|os.O_CLOEXEC)
    try:return worker.inspect_fd(fd,SIZE,sector)
    finally:os.close(fd)


class ReadonlyTests(unittest.TestCase):
    def test_real_clean_ntfs_images_are_byte_identical_after_inspection(self):
        for sector in [512,4096]:
            with tempfile.TemporaryDirectory() as td:
                path=image(td,sector);before=digest(path)
                value=inspect(path,sector)
                self.assertEqual(value['deviceBytes'],SIZE)
                self.assertEqual(value['clusterBytes'],4096)
                self.assertGreater(value['minimumBytes'],0)
                self.assertLess(value['minimumBytes'],value['volumeBytes'])
                self.assertRegex(value['inspectionFingerprint'],'^[0-9a-f]{64}$')
                self.assertEqual(value,inspect(path,sector))
                self.assertEqual(digest(path),before)
                self.assertEqual(set(value),{'schemaVersion','deviceBytes','volumeBytes','clusterBytes','minimumBytes','inspectionFingerprint'})

    def test_dirty_volume_is_refused_without_repair(self):
        with tempfile.TemporaryDirectory() as td:
            path=image(td)
            subprocess.run(['/usr/bin/ntfsfix',str(path)],capture_output=True,check=True,timeout=10)
            before=digest(path)
            with self.assertRaises(ValueError):inspect(path)
            self.assertEqual(digest(path),before)

    def test_existing_hibernation_file_is_checked_without_modifying_it(self):
        for header, target in [(b'hibr'+bytes(4092),'/hiberfil.sys'),(b'HIBR'+bytes(4092),'/HIBERFIL.SYS'),(b'unknown'+bytes(4089),'/HiBeRfIl.SyS'),(b'x'*128,'/hiberfil.sys')]:
            with tempfile.TemporaryDirectory() as td:
                path=image(td);source=Path(td)/'header';source.write_bytes(header)
                subprocess.run(['/usr/bin/ntfscp','-f',str(path),str(source),target],capture_output=True,check=True,timeout=10)
                before=digest(path)
                with self.assertRaises(ValueError):inspect(path)
                self.assertEqual(digest(path),before)

    def test_zero_hibernation_header_is_accepted_only_with_clean_metadata(self):
        with tempfile.TemporaryDirectory() as td:
            path=image(td);source=Path(td)/'header';source.write_bytes(bytes(4096))
            subprocess.run(['/usr/bin/ntfscp','-f',str(path),str(source),'/hiberfil.sys'],capture_output=True,check=True,timeout=10)
            before=digest(path)
            self.assertGreater(inspect(path)['minimumBytes'],0)
            self.assertEqual(digest(path),before)

    def test_repeated_native_metadata_checks_close_all_descriptors(self):
        with tempfile.TemporaryDirectory() as td:
            path=image(td);fd=os.open(path,os.O_RDONLY)
            try:
                native=worker.NativeNtfs();before=len(list(Path('/proc/self/fd').iterdir()))
                for _ in range(10):native.metadata(fd)
                self.assertEqual(len(list(Path('/proc/self/fd').iterdir())),before)
            finally:os.close(fd)

    def test_non_readonly_fd_or_changed_backup_is_refused_before_tools(self):
        with tempfile.TemporaryDirectory() as td:
            path=image(td);fd=os.open(path,os.O_RDWR)
            try:
                with mock.patch.object(worker,'run_tool') as run:
                    with self.assertRaises(ValueError):worker.inspect_fd(fd,SIZE,512)
                    run.assert_not_called()
            finally:os.close(fd)
            with path.open('r+b') as stream:stream.seek(SIZE-512+3);stream.write(b'INVALID!')
            with mock.patch.object(worker,'run_tool') as run:
                with self.assertRaises(ValueError):inspect(path)
                run.assert_not_called()

    def test_strict_volume_hibernation_and_journal_headers(self):
        worker.volume_information(bytes(8)+b'\x03\x01\0\0')
        worker.hibernation_header(bytes(4096))
        good=bytearray(32);good[:4]=b'RSTR';good[26:30]=b'\x01\0\x01\0'
        worker.restart_header(bytes(good))
        for raw in [bytes(12),bytes(8)+b'\x03\x01\x01\0',bytes(8)+b'\x03\0\0\0']:
            with self.assertRaises(ValueError):worker.volume_information(raw)
        for raw in [b'',bytes(4095),b'wake'+bytes(4092),bytes(4095)+b'x']:
            with self.assertRaises(ValueError):worker.hibernation_header(raw)
        good[28:30]=b'\x02\0'
        with self.assertRaises(ValueError):worker.restart_header(bytes(good))

    def test_ambiguous_tool_fields_and_geometry_do_not_become_minimum_evidence(self):
        raw=(b'Current volume size: 268431872 bytes (269 MB)\nCurrent device size: 268435456 bytes (269 MB)\n'
             b'Cluster size: 4096 bytes\nYou might resize at 1810432 bytes or 2 MB (freeing 267 MB).\n')
        self.assertEqual(worker.parse_minimum(raw,SIZE,512,4096)['minimumBytes'],1810432)
        for bad in [raw+raw,raw.replace(b'1810432',b'0'),raw.replace(b'1810432',b'9999999999999'),
                    raw.replace(b'268435456',b'268435455'),raw.replace(b'4096',b'65536'),raw.replace(b'1810432',b'1810433')]:
            with self.assertRaises(ValueError):worker.parse_minimum(bad,SIZE,512,4096)

    def test_root_only_cli_rejects_regular_files_and_arbitrary_operations_silently(self):
        with tempfile.TemporaryDirectory() as td:
            path=image(td);fd=os.open(path,os.O_RDONLY)
            try:
                for uid,args in [(1000,['--check-fd',str(fd),str(SIZE),'512']),
                                 (0,['--write',str(fd),str(SIZE),'512']),
                                 (0,['--check-fd',str(fd),str(SIZE),'512'])]:
                    out,err=io.StringIO(),io.StringIO()
                    with mock.patch.object(worker.os,'geteuid',return_value=uid),mock.patch.object(worker.sys,'argv',['worker',*args]),redirect_stdout(out),redirect_stderr(err):
                        self.assertEqual(worker.main(),2)
                    self.assertEqual(out.getvalue()+err.getvalue(),'')
            finally:os.close(fd)

    def test_fixed_tool_argv_preserves_the_source_and_lease_descriptors(self):
        with tempfile.TemporaryFile() as source,tempfile.TemporaryFile() as lease:
            calls=[];real_popen=subprocess.Popen
            def spawn(argv,**kwargs):
                calls.append((argv,kwargs))
                child="import os;os.fstat(%d);os.fstat(%d);print('TYPE=ntfs\\nUSAGE=filesystem')"%(source.fileno(),lease.fileno())
                return real_popen([sys.executable,'-I','-c',child],**kwargs)
            proxy=SimpleNamespace(Popen=spawn,DEVNULL=subprocess.DEVNULL,PIPE=subprocess.PIPE)
            with mock.patch.object(worker,'subprocess',proxy),mock.patch.dict(os.environ,{'RO_INSTALLER_LEASE_FD':str(lease.fileno())}):
                value=worker.run_tool('signature',source.fileno())
            self.assertIn(b'TYPE=ntfs',value)
            argv,options=calls[0]
            self.assertEqual(argv,('/usr/sbin/blkid','-p','-o','export','--',f'/proc/self/fd/{source.fileno()}'))
            self.assertEqual(set(options['pass_fds']),{source.fileno(),lease.fileno()})
            self.assertTrue(options['close_fds']);self.assertEqual(options['env'],{'PATH':'/usr/sbin:/usr/bin','LC_ALL':'C'})

    def test_output_overflow_or_deadline_kills_reaps_and_closes_the_tool(self):
        real_popen=subprocess.Popen
        for deadline in [False,True]:
            processes=[]
            def spawn(argv,**kwargs):
                self.assertEqual(argv[:4],('/usr/bin/ntfsresize','--info','--no-action','-P'))
                code="import time;time.sleep(60)" if deadline else "import sys;sys.stderr.write('x'*70000)"
                process=real_popen([sys.executable,'-I','-c',code],**kwargs);processes.append(process);return process
            proxy=SimpleNamespace(Popen=spawn,DEVNULL=subprocess.DEVNULL,PIPE=subprocess.PIPE)
            clock=iter([0,91])
            timing=SimpleNamespace(monotonic=lambda:next(clock)) if deadline else worker.time
            with tempfile.TemporaryFile() as source,mock.patch.object(worker,'subprocess',proxy),mock.patch.object(worker,'time',timing):
                with self.assertRaises(ValueError):worker.run_tool('minimum',source.fileno())
            self.assertEqual(len(processes),1)
            self.assertIsNotNone(processes[0].poll())
            self.assertTrue(processes[0].stdout.closed);self.assertTrue(processes[0].stderr.closed)

    def test_metadata_drift_during_minimum_probe_never_becomes_a_result(self):
        with tempfile.TemporaryDirectory() as td:
            path=image(td);native=worker.NativeNtfs();read=native.metadata;count=0
            def observed(fd):
                nonlocal count
                count+=1;value=read(fd)
                return value+(b'drift' if count==2 else b'')
            native.metadata=observed
            before=digest(path)
            with mock.patch.object(worker,'NativeNtfs',return_value=native):
                with self.assertRaises(ValueError):inspect(path)
            self.assertEqual(digest(path),before)

    def test_package_installs_a_nonexecutable_root_owned_worker_and_pins_the_abi(self):
        spec=(ROOT/'ro-installer.spec').read_text()
        self.assertIn('install -Dm644 linux/ro_installer_ntfs.py',spec)
        self.assertIn('%attr(0644,root,root) %{_libexecdir}/ro_installer_ntfs.py',spec)
        self.assertIn('Requires:       %{_libdir}/libntfs-3g.so.89',spec)

    def test_cli_framing_and_native_error_silence_in_an_isolated_regular_file_fixture(self):
        # Only the CLI UID/type guard is simulated. Native metadata/limits/tools
        # execute in a child against an ordinary image, not a Linux block device.
        script="""
import importlib.util,os,stat,sys,resource,signal
from types import SimpleNamespace
module,fd,size=sys.argv[1],int(sys.argv[2]),int(sys.argv[3])
spec=importlib.util.spec_from_file_location('worker',module)
w=importlib.util.module_from_spec(spec);spec.loader.exec_module(w)
proxy=SimpleNamespace(**vars(os));proxy.geteuid=lambda:0
proxy.fstat=lambda n:SimpleNamespace(st_mode=stat.S_IFBLK) if n==fd else os.fstat(n)
w.os=proxy;sys.argv=['worker','--check-fd',str(fd),str(size),'512']
result=w.main()
assert resource.getrlimit(resource.RLIMIT_CORE)==(0,0)
assert resource.getrlimit(resource.RLIMIT_AS)[1]<=1024**3
assert resource.getrlimit(resource.RLIMIT_CPU)[1]<=120
assert signal.alarm(0)==0
raise SystemExit(result)
"""
        with tempfile.TemporaryDirectory() as td:
            path=image(td)
            for corrupt in [False,True]:
                if corrupt:
                    with path.open('r+b') as stream:
                        boot=stream.read(512);offset=int.from_bytes(boot[48:56],'little')*boot[13]*512
                        stream.seek(offset);stream.write(bytes(512))
                before=digest(path);fd=os.open(path,os.O_RDONLY)
                try:
                    result=subprocess.run([sys.executable,'-I','-c',script,str(ROOT/'linux/ro_installer_ntfs.py'),str(fd),str(SIZE)],
                      pass_fds=(fd,),capture_output=True,timeout=20)
                finally:os.close(fd)
                self.assertEqual(result.stderr,b'')
                if corrupt:
                    self.assertEqual(result.returncode,2);self.assertEqual(result.stdout,b'')
                else:
                    self.assertEqual(result.returncode,0)
                    self.assertEqual(json.loads(result.stdout)['deviceBytes'],SIZE)
                    self.assertLessEqual(len(result.stdout),1024)
                self.assertEqual(digest(path),before)

    def test_resource_caps_never_relax_inherited_stricter_limits(self):
        calls=[]
        proxy=SimpleNamespace(RLIM_INFINITY=-1,getrlimit=lambda _: (128,256),
          setrlimit=lambda kind,value:calls.append((kind,value)))
        with mock.patch.object(worker,'resource',proxy):worker.restrict_limit(7,1024)
        self.assertEqual(calls,[(7,(128,256))])
        calls.clear()
        proxy.getrlimit=lambda _: (-1,-1)
        with mock.patch.object(worker,'resource',proxy):worker.restrict_limit(7,1024)
        self.assertEqual(calls,[(7,(1024,1024))])

    def test_case_colliding_hibernation_names_are_not_treated_as_an_inactive_file(self):
        with tempfile.TemporaryDirectory() as td:
            path=image(td);source=Path(td)/'header';source.write_bytes(bytes(4096))
            for target in ['/hiberfil.sys','/HiBeRfIl.SyS']:
                subprocess.run(['/usr/bin/ntfscp','-f',str(path),str(source),target],capture_output=True,check=True,timeout=10)
            names=subprocess.run(['/usr/bin/ntfsls',str(path)],capture_output=True,check=True,timeout=10).stdout.splitlines()
            self.assertIn(b'hiberfil.sys',names);self.assertIn(b'HiBeRfIl.SyS',names)
            before=digest(path)
            with self.assertRaises(ValueError):inspect(path)
            self.assertEqual(digest(path),before)

    def test_root_inventory_limit_and_callback_failures_never_imply_absence(self):
        for bad_length in [False,True]:
            with tempfile.TemporaryDirectory() as td:
                path=image(td);native=worker.NativeNtfs()
                name=c.create_string_buffer('ordinary'.encode('utf-16-le'))
                def directory(_root,_position,_context,visit):
                    for _ in range(4097):
                        if visit(None,c.addressof(name),256 if bad_length else 8,0,0,64,8):return -1
                    return 0
                native.readdir=directory
                with mock.patch.object(worker,'NativeNtfs',return_value=native):
                    with self.assertRaises(ValueError):inspect(path)

    def test_hidden_system_hibernation_file_cannot_disappear_from_the_inventory(self):
        # Fixture setup may write only this new regular-file image. The worker
        # never binds a setter or opens metadata with writable flags.
        with tempfile.TemporaryDirectory() as td:
            path=image(td);source=Path(td)/'header';source.write_bytes(bytes(4096))
            self.assertTrue(path.is_file())
            subprocess.run(['/usr/bin/ntfscp','-f',str(path),str(source),'/hiberfil.sys'],capture_output=True,check=True,timeout=10)
            native=worker.NativeNtfs()
            lookup=native.lib.ntfs_pathname_to_inode;lookup.argtypes=[c.c_void_p,c.c_void_p,c.c_char_p];lookup.restype=c.c_void_p
            setter=native.lib.ntfs_set_ntfs_attrib;setter.argtypes=[c.c_void_p,c.c_char_p,c.c_size_t,c.c_int];setter.restype=c.c_int
            getter=native.lib.ntfs_get_ntfs_attrib;getter.argtypes=[c.c_void_p,c.c_void_p,c.c_size_t];getter.restype=c.c_int
            volume=native.mount(str(path).encode(),0)
            self.assertTrue(volume)
            try:
                inode=lookup(volume,None,b'/hiberfil.sys');self.assertTrue(inode)
                try:self.assertEqual(setter(inode,(0x26).to_bytes(4,'little'),4,0),0)
                finally:self.assertEqual(native.close_inode(inode),0)
            finally:self.assertEqual(native.unmount(volume,0),0)
            source.write_bytes(b'hibr'+bytes(4092))
            subprocess.run(['/usr/bin/ntfscp','-f',str(path),str(source),'/hiberfil.sys'],capture_output=True,check=True,timeout=10)
            volume=native.mount(str(path).encode(),worker.RO_FORENSIC);self.assertTrue(volume)
            try:
                inode=lookup(volume,None,b'/hiberfil.sys');self.assertTrue(inode)
                try:
                    flags=c.create_string_buffer(4);self.assertEqual(getter(inode,flags,4),4)
                    self.assertEqual(int.from_bytes(flags.raw,'little')&6,6)
                finally:self.assertEqual(native.close_inode(inode),0)
                root=native.inode(volume,5);self.assertTrue(root)
                try:
                    for visible in [False,True]:
                        found=[]
                        @worker.FILLDIR
                        def visit(_ctx,name,length,_kind,_pos,_ref,_type):
                            if length==12 and c.string_at(name,24)=='hiberfil.sys'.encode('utf-16-le'):found.append(True)
                            return 0
                        self.assertEqual(native.shown(volume,int(visible),int(visible),0),0)
                        position=c.c_int64(0)
                        self.assertEqual(native.readdir(root,c.byref(position),None,visit),0)
                        self.assertEqual(bool(found),visible)
                finally:self.assertEqual(native.close_inode(root),0)
            finally:self.assertEqual(native.unmount(volume,0),0)
            before=digest(path)
            with self.assertRaisesRegex(ValueError,'hibernation'):inspect(path)
            self.assertEqual(digest(path),before)

    def test_invalid_lease_descriptors_cannot_reach_a_tool(self):
        with tempfile.TemporaryFile() as source:
            for lease in ['0','1','2',str(source.fileno()),'invalid']:
                proxy=SimpleNamespace(Popen=mock.Mock(),DEVNULL=subprocess.DEVNULL,PIPE=subprocess.PIPE)
                with mock.patch.object(worker,'subprocess',proxy),mock.patch.dict(os.environ,{'RO_INSTALLER_LEASE_FD':lease}):
                    with self.assertRaises(ValueError):worker.run_tool('signature',source.fileno())
                    proxy.Popen.assert_not_called()


if __name__=='__main__':unittest.main(verbosity=2)
