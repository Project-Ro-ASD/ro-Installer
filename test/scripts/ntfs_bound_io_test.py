#!/usr/bin/env python3
"""Fixed-alias native FD binding; every writable fixture is a new normal file."""
import ctypes
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
from types import SimpleNamespace
from unittest import mock
import installer_helper_test as legacy

ROOT = legacy.ROOT
worker = legacy.load_module('ntfs_bound_worker', ROOT/'linux/ro_installer_ntfs.py')
ALIAS = worker.BOUND_ALIAS.encode()


def build_adapter(directory):
    path = Path(directory)/'bound-io.so'
    subprocess.run(['bash',str(ROOT/'scripts/build-ntfs-bound-io.sh'),str(path)],
                   capture_output=True,check=True,timeout=30)
    return path


def environment(adapter, fd):
    return {'PATH':'/usr/sbin:/usr/bin','LC_ALL':'C','LD_PRELOAD':str(adapter),
            'RO_INSTALLER_NTFS_BOUND_FD':str(fd)}


class BoundIoTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.adapter = build_adapter(cls.temporary.name)
        cls.library = ctypes.CDLL(str(cls.adapter),use_errno=True)

    def test_all_open_variants_duplicate_same_description_and_keep_exact_access(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td)/'new'; path.write_bytes(b'original-data')
            for mode in (os.O_RDONLY,os.O_RDWR):
                fd = os.open(path,mode)
                try:
                    with mock.patch.dict(os.environ,{'RO_INSTALLER_NTFS_BOUND_FD':str(fd)}):
                        for name in ('open','open64','openat','openat64','__open_2','__open64_2','__openat_2','__openat64_2'):
                            args = [ALIAS,mode]
                            if 'openat' in name: args.insert(0,-100)
                            duplicate = getattr(self.library,name)(*args)
                            self.assertGreaterEqual(duplicate,3,name)
                            try:
                                self.assertFalse(os.get_inheritable(duplicate))
                                os.lseek(duplicate,3,os.SEEK_SET)
                                self.assertEqual(os.lseek(fd,0,os.SEEK_CUR),3,name)
                                os.lseek(fd,0,os.SEEK_SET)
                                self.assertEqual(os.read(duplicate,8),b'original')
                            finally: os.close(duplicate)
                finally: os.close(fd)

    def test_writable_binding_targets_original_inode_after_path_replacement(self):
        # Descriptor behavior only, using an ordinary text file; no filesystem
        # resize or device node is involved in this write test.
        with tempfile.TemporaryDirectory() as td:
            path=Path(td)/'new';path.write_bytes(b'original-data');fd=os.open(path,os.O_RDWR)
            original=path.with_name('original');path.rename(original);path.write_bytes(b'replacement')
            try:
                with mock.patch.dict(os.environ,{'RO_INSTALLER_NTFS_BOUND_FD':str(fd)}):
                    duplicate=self.library.open(ALIAS,os.O_RDWR)
                    self.assertGreaterEqual(duplicate,3)
                    try:
                        self.assertEqual(os.fstat(duplicate).st_ino,os.fstat(fd).st_ino)
                        self.assertEqual(os.pwrite(duplicate,b'changed!',0),8)
                    finally:os.close(duplicate)
                self.assertEqual(original.read_bytes(),b'changed!-data')
                self.assertEqual(path.read_bytes(),b'replacement')
            finally:os.close(fd)

    def test_destructive_flags_wrong_access_and_unknown_flags_cannot_change_file(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td)/'new'; path.write_bytes(b'original-data')
            for mode in (os.O_RDONLY,os.O_RDWR):
                fd = os.open(path,mode)
                try:
                    with mock.patch.dict(os.environ,{'RO_INSTALLER_NTFS_BOUND_FD':str(fd)}):
                        for flag in (os.O_WRONLY,os.O_CREAT|mode,os.O_TRUNC|mode,os.O_APPEND|mode,
                                     os.O_PATH,os.O_DIRECTORY|mode,os.O_TMPFILE|mode,1<<29,
                                     os.O_RDWR if mode==os.O_RDONLY else os.O_RDONLY):
                            self.assertEqual(self.library.open(ALIAS,flag,0o600),-1,flag)
                finally: os.close(fd)
            self.assertEqual(path.read_bytes(),b'original-data')

    def test_missing_malformed_closed_nonregular_and_path_descriptors_refuse(self):
        with mock.patch.dict(os.environ,{},clear=True):
            self.assertEqual(self.library.open(ALIAS,os.O_RDONLY),-1)
            for value in ('','0','2','-1','4x','9999999999999999999999'):
                os.environ['RO_INSTALLER_NTFS_BOUND_FD'] = value
                self.assertEqual(self.library.open(ALIAS,os.O_RDONLY),-1)
        with tempfile.TemporaryDirectory() as td:
            path=Path(td)/'new';path.write_bytes(b'data')
            pipe=os.pipe()
            directory=os.open(td,os.O_RDONLY|os.O_DIRECTORY)
            path_fd=os.open(path,os.O_PATH)
            append=os.open(path,os.O_RDWR|os.O_APPEND)
            closed=os.dup(path_fd);os.close(closed)
            try:
                for fd in (*pipe,directory,path_fd,append,closed):
                    with mock.patch.dict(os.environ,{'RO_INSTALLER_NTFS_BOUND_FD':str(fd)}):
                        self.assertEqual(self.library.open(ALIAS,os.O_RDONLY),-1)
            finally:
                for fd in (*pipe,directory,path_fd,append):os.close(fd)

    def test_stat_and_realpath_bind_original_and_other_paths_keep_normal_behavior(self):
        libc=ctypes.CDLL(None)
        libc.free.argtypes=[ctypes.c_void_p]
        self.library.realpath.restype=ctypes.c_void_p
        with tempfile.TemporaryDirectory() as td:
            path=Path(td)/'new';path.write_bytes(b'original-data');fd=os.open(path,os.O_RDONLY)
            original=path.with_name('original');path.rename(original);path.write_bytes(b'replacement')
            try:
                with mock.patch.dict(os.environ,{'RO_INSTALLER_NTFS_BOUND_FD':str(fd)}):
                    for name in ('stat','stat64','lstat','lstat64'):
                        # Compare complete libc-written records without recreating
                        # an ABI struct or parsing hardcoded field offsets.
                        expected=ctypes.create_string_buffer(512);actual=ctypes.create_string_buffer(512)
                        self.assertEqual(libc.fstat(fd,expected),0)
                        self.assertEqual(getattr(self.library,name)(ALIAS,actual),0)
                        self.assertEqual(actual.raw,expected.raw)
                    resolved=self.library.realpath(ALIAS,None)
                    self.assertTrue(resolved)
                    try:self.assertEqual(ctypes.string_at(resolved),ALIAS)
                    finally:libc.free(resolved)
                    buffer=ctypes.create_string_buffer(4096)
                    self.assertTrue(self.library.realpath(ALIAS,buffer))
                    self.assertEqual(buffer.value,ALIAS)
                    duplicate=self.library.open(ALIAS,os.O_RDONLY)
                    try:self.assertEqual(os.read(duplicate,13),b'original-data')
                    finally:os.close(duplicate)
                    ordinary=self.library.open(os.fsencode(path),os.O_RDONLY)
                    try:self.assertEqual(os.read(ordinary,11),b'replacement')
                    finally:os.close(ordinary)
                    resolved=self.library.realpath(os.fsencode(path),None)
                    try:self.assertEqual(ctypes.string_at(resolved),os.fsencode(path.resolve()))
                    finally:libc.free(resolved)
            finally:os.close(fd)

    def test_runtime_requires_fixed_regular_root_owned_mode_and_elf_adapter(self):
        with tempfile.TemporaryDirectory() as td:
            path=Path(td)/'adapter.so';path.write_bytes(self.adapter.read_bytes());path.chmod(0o644)
            original_fstat=os.fstat
            def checked(**changes):
                def info(fd):
                    observed=original_fstat(fd)
                    fields={name:getattr(observed,name) for name in ('st_mode','st_uid','st_gid','st_nlink')}
                    return SimpleNamespace(**{**fields,'st_uid':0,'st_gid':0,**changes})
                proxy=SimpleNamespace(**{name:getattr(os,name) for name in dir(os)});proxy.fstat=info
                return proxy
            with mock.patch.object(worker,'BOUND_IO',str(path)),mock.patch.object(worker,'os',checked()):
                self.assertEqual(worker.bound_io_environment(17),environment(path,17))
            for changes in ({'st_uid':1000},{'st_gid':1000},{'st_nlink':2},
                            {'st_mode':stat.S_IFREG|0o666},{'st_mode':stat.S_IFDIR|0o644}):
                with mock.patch.object(worker,'BOUND_IO',str(path)),mock.patch.object(worker,'os',checked(**changes)):
                    with self.assertRaises(ValueError):worker.bound_io_environment(17)
            valid=path.read_bytes()
            for header in (b'bad', b'\x7fELF'+bytes(16), valid[:18]+b'\x28\x00'+valid[20:]):
                path.write_bytes(header)
                with mock.patch.object(worker,'BOUND_IO',str(path)),mock.patch.object(worker,'os',checked()):
                    with self.assertRaises(ValueError):worker.bound_io_environment(17)
            path.unlink();path.symlink_to(self.adapter)
            with mock.patch.object(worker,'BOUND_IO',str(path)):
                with self.assertRaises(OSError):worker.bound_io_environment(17)
            path.unlink()
            with mock.patch.object(worker,'BOUND_IO',str(path)):
                with self.assertRaises(OSError):worker.bound_io_environment(17)

    def test_built_adapter_has_relro_immediate_binding_and_nonexecuting_stack(self):
        result=subprocess.run(['/usr/bin/readelf','-W','-l','-d',str(self.adapter)],
                              capture_output=True,text=True,check=True,timeout=5).stdout
        self.assertIn('GNU_RELRO',result)
        self.assertIn('BIND_NOW',result)
        stacks=[line for line in result.splitlines() if 'GNU_STACK' in line]
        self.assertEqual(len(stacks),1)
        self.assertNotIn('E',stacks[0].split()[-2])

    def test_missing_adapter_or_binding_never_falls_back_to_a_volume_path(self):
        # The virtual alias has no numeric procfd name and cannot open a device
        # when the loader ignores or cannot load an adapter.
        command=['/usr/bin/ntfsresize','--info','--no-action','-P',worker.BOUND_ALIAS]
        for env in ({'PATH':'/usr/bin','LC_ALL':'C'}, environment('/nonexistent-ro-adapter.so',999999),
                    environment(self.adapter,999999)):
            result=subprocess.run(command,env=env,capture_output=True,timeout=5)
            self.assertNotEqual(result.returncode,0)


if __name__=='__main__':unittest.main()
