#!/usr/bin/env python3
"""Post-only reader contracts on synthetic bytes and disposable regular images."""
import hashlib
import io
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

worker=legacy.load_module('ntfs_postresize_worker',legacy.ROOT/'linux/ro_installer_ntfs.py')
OLD=512*1024**2
TARGET=256*1024**2


def boot_pair(sector=512):
    raw=bytearray(sector);raw[3:11]=b'NTFS    ';raw[510:512]=b'\x55\xaa'
    struct.pack_into('<H',raw,11,sector);raw[13]=4096//sector
    struct.pack_into('<QQQ',raw,40,OLD//sector-1,4,20)
    struct.pack_into('<Q',raw,72,123456)
    old=bytes(raw);struct.pack_into('<Q',raw,40,((TARGET-sector)//4096)*(4096//sector))
    return old,bytes(raw)


def info(sector=512):
    volume=((TARGET-sector)//4096)*4096+sector
    return (f'Current device size: {OLD} bytes (537 MB)\n'
            f'Current volume size: {volume} bytes (269 MB)\nCluster size: 4096 bytes\n'
            f'You might resize at {128*1024**2} bytes or 135 MB (freeing 134 MB).\n').encode()


class PostResizeTests(unittest.TestCase):
    def boot(self,sector=512,old=None,new=None,target=TARGET,original=OLD):
        before,after=boot_pair(sector);before=before if old is None else old;after=after if new is None else new
        def read(fd,length,offset):return after if offset in (0,target-sector) else b''
        proxy=SimpleNamespace(**{name:getattr(os,name) for name in dir(os)});proxy.pread=read
        with mock.patch.object(worker,'os',proxy):
            return worker.resized_boot_sector(17,original,target,sector,before)
    def test_both_sector_sizes_require_exact_new_span_and_allow_only_expected_tail_slack(self):
        for sector in (512,4096):
            raw,cluster=self.boot(sector);self.assertEqual(cluster,4096)
            total=struct.unpack_from('<Q',raw,40)[0]
            self.assertEqual(TARGET-(total+1)*sector,3584 if sector==512 else 0)
            parsed=worker.parse_resized_minimum(info(sector),OLD,TARGET,sector,cluster)
            self.assertEqual(parsed['volumeBytes'],(total+1)*sector)
    def test_identity_geometry_boot_code_and_record_size_cannot_change(self):
        for sector in (512,4096):
            old,new=boot_pair(sector)
            for offset in [0,3,11,13,64,68,72,80,100,510]+([1024] if sector==4096 else []):
                changed=bytearray(new);changed[offset]^=1
                with self.assertRaises(ValueError):self.boot(sector,old=old,new=bytes(changed))
    def test_wrong_extent_mft_mirror_backup_and_original_input_are_rejected(self):
        for sector in (512,4096):
            old,new=boot_pair(sector)
            for offset,value in [(40,1),(48,0),(48,TARGET//4096),(56,4),(56,TARGET//4096)]:
                changed=bytearray(new);struct.pack_into('<Q',changed,offset,value)
                with self.assertRaises(ValueError):self.boot(sector,new=bytes(changed))
            for target,original in [(True,OLD),(TARGET,True),(OLD,OLD),(OLD+1048576,OLD),(TARGET+1,OLD),(0,OLD)]:
                with self.assertRaises(ValueError):self.boot(sector,target=target,original=original)
            with self.assertRaises(ValueError):self.boot(sector,old=old[:-1])
            proxy=SimpleNamespace(**{name:getattr(os,name) for name in dir(os)})
            proxy.pread=lambda fd,length,offset:new if offset==0 else b'wrong backup'
            with mock.patch.object(worker,'os',proxy):
                with self.assertRaises(ValueError):worker.resized_boot_sector(17,OLD,TARGET,sector,old)
    def test_expected_dirty_bit_is_post_only_and_other_flags_or_versions_fail(self):
        clean=bytes(8)+b'\x03\x01\x00\x00';dirty=bytes(8)+b'\x03\x01\x01\x00'
        worker.volume_information(clean);worker.resized_volume_information(dirty)
        with self.assertRaises(ValueError):worker.volume_information(dirty)
        with self.assertRaises(ValueError):worker.resized_volume_information(clean)
        for raw in [dirty[:-1],dirty+b'x',bytes(8)+b'\x03\x00\x01\x00',bytes(8)+b'\x03\x01\x03\x00']:
            with self.assertRaises(ValueError):worker.resized_volume_information(raw)
    def test_allocation_probe_requires_original_device_and_exact_new_volume_geometry(self):
        good=info()
        for bad in [good+good,good.replace(str(OLD).encode(),str(TARGET).encode()),
                    good.replace(b'Cluster size: 4096',b'Cluster size: 8192'),
                    good.replace(b'268431872 bytes',b'268435456 bytes'),
                    good.replace(b'134217728 bytes',b'134217729 bytes')]:
            with self.assertRaises(ValueError):worker.parse_resized_minimum(bad,OLD,TARGET,512,4096)
    def test_descriptor_must_be_readonly_and_metadata_drift_fails_closed(self):
        with tempfile.TemporaryFile() as stream:
            with mock.patch.object(worker,'NativeNtfs') as native,mock.patch.object(worker,'run_tool') as tool:
                with self.assertRaises(ValueError):worker.inspect_resized_fd(stream.fileno(),OLD,TARGET,512,boot_pair()[0])
                native.assert_not_called();tool.assert_not_called()
        with tempfile.TemporaryDirectory() as td:
            p=Path(td)/'regular';p.write_bytes(b'fixture');fd=os.open(p,os.O_RDONLY)
            try:
                native=SimpleNamespace(resized_metadata=mock.Mock(side_effect=[b'first',b'changed']))
                with mock.patch.object(worker,'resized_boot_sector',return_value=(boot_pair()[1],4096)), \
                     mock.patch.object(worker,'NativeNtfs',return_value=native),mock.patch.object(worker,'run_tool',return_value=info()):
                    with self.assertRaises(ValueError):worker.inspect_resized_fd(fd,OLD,TARGET,512,boot_pair()[0])
            finally:os.close(fd)
    def test_no_new_cli_mode_or_resize_authority_is_exposed(self):
        proxy=SimpleNamespace(**{name:getattr(os,name) for name in dir(os)});proxy.geteuid=lambda:0
        output=io.StringIO()
        with mock.patch.object(worker,'os',proxy),mock.patch.object(sys,'argv',['worker','--check-resized-fd','3',str(OLD),'512']), \
             mock.patch.object(worker,'inspect_resized_fd') as inspect,redirect_stdout(output),redirect_stderr(output):
            self.assertEqual(worker.main(),2);inspect.assert_not_called()
        self.assertEqual(output.getvalue(),'')
    def test_unexpected_physical_extents_refuse_before_native_or_boot_reads(self):
        with tempfile.TemporaryDirectory() as td:
            path=Path(td)/'normal';path.write_bytes(b'fixture');fd=os.open(path,os.O_RDONLY)
            try:
                for extent in (True,False,0,float(TARGET),str(TARGET),TARGET+512,OLD-512,OLD+1048576):
                    with mock.patch.object(worker,'resized_boot_sector') as boot, \
                         mock.patch.object(worker,'NativeNtfs') as native,mock.patch.object(worker,'run_tool') as tool:
                        with self.assertRaises(ValueError):
                            worker.inspect_resized_fd(fd,OLD,TARGET,512,boot_pair()[0],partition_bytes=extent)
                        boot.assert_not_called();native.assert_not_called();tool.assert_not_called()
            finally:os.close(fd)

    def test_native_refreshed_partition_requires_explicit_exact_physical_target(self):
        for sector in (512,4096):
            with tempfile.TemporaryDirectory() as td:
                path=Path(td)/'new-regular.img'
                with path.open('xb') as stream:stream.truncate(OLD)
                self.assertTrue(stat.S_ISREG(path.lstat().st_mode));self.assertFalse(path.is_symlink())
                subprocess.run(['/usr/bin/mkntfs','-F','-Q','-s',str(sector),'-c','4096',str(path)],
                               capture_output=True,check=True,timeout=20)
                fd=os.open(path,os.O_RDONLY|os.O_CLOEXEC)
                try:
                    original,cluster=worker.boot_sector(fd,OLD,sector)
                    # Fresh normal-file fixture, not MFT relocation or write
                    # qualification of the old installed native release.
                    self.assertLess(max(struct.unpack_from('<QQ',original,48))*cluster,TARGET)
                    argv=['/usr/bin/ntfsresize','-P','--size',str(TARGET),str(path)]
                    subprocess.run([argv[0],'--no-action',*argv[1:]],capture_output=True,check=True,timeout=20)
                    subprocess.run(argv,input=b'y\n',capture_output=True,check=True,timeout=20)
                    before=worker.inspect_resized_fd(fd,OLD,TARGET,sector,original)
                    self.assertEqual(before,worker.inspect_resized_fd(fd,OLD,TARGET,sector,original,partition_bytes=OLD))
                    with self.assertRaises(ValueError):
                        worker.inspect_resized_fd(fd,OLD,TARGET,sector,original,partition_bytes=TARGET)
                finally:os.close(fd)
                # Model the kernel exposing the shorter partition; reopen the
                # ordinary file just as a fresh source descriptor would be used.
                with path.open('r+b') as stream:stream.truncate(TARGET)
                fd=os.open(path,os.O_RDONLY|os.O_CLOEXEC)
                try:
                    with path.open('rb') as stream:checksum=hashlib.file_digest(stream,'sha256').hexdigest()
                    after=worker.inspect_resized_fd(fd,OLD,TARGET,sector,original,partition_bytes=TARGET)
                    self.assertEqual(after['deviceBytes'],TARGET)
                    self.assertNotEqual(after['inspectionFingerprint'],before['inspectionFingerprint'])
                    for key in ('volumeBytes','clusterBytes','minimumBytes','targetBytes','schemaVersion'):
                        self.assertEqual(after[key],before[key])
                    with self.assertRaises(ValueError):worker.inspect_resized_fd(fd,OLD,TARGET,sector,original)
                    with self.assertRaises(ValueError):
                        worker.inspect_resized_fd(fd,OLD,TARGET,sector,original,partition_bytes=OLD)
                    with path.open('rb') as stream:self.assertEqual(hashlib.file_digest(stream,'sha256').hexdigest(),checksum)
                finally:os.close(fd)

    def test_native_fresh_regular_images_are_validated_without_reader_writes(self):
        for sector in (512,4096):
            with tempfile.TemporaryDirectory() as td:
                p=Path(td)/'new-regular-file.img'
                with p.open('xb') as stream:stream.truncate(OLD)
                self.assertTrue(stat.S_ISREG(p.lstat().st_mode));self.assertFalse(p.is_symlink())
                subprocess.run(['/usr/bin/mkntfs','-F','-Q','-s',str(sector),'-c','4096',str(p)],capture_output=True,check=True,timeout=20)
                fd=os.open(p,os.O_RDONLY|os.O_CLOEXEC)
                try:
                    before,cluster=worker.boot_sector(fd,OLD,sector);worker.NativeNtfs().metadata(fd)
                    # This fixture does not exercise MFT relocation and does not
                    # qualify an old toolchain for production resize admission.
                    self.assertLess(max(struct.unpack_from('<QQ',before,48))*cluster,TARGET)
                    argv=['/usr/bin/ntfsresize','-P','--size',str(TARGET),str(p)]
                    subprocess.run([argv[0],'--no-action',*argv[1:]],capture_output=True,check=True,timeout=20)
                    subprocess.run(argv,input=b'y\n',capture_output=True,check=True,timeout=20)
                    self.assertEqual(p.stat().st_size,OLD)
                    with p.open('rb') as stream:before_hash=hashlib.file_digest(stream,'sha256').hexdigest()
                    result=worker.inspect_resized_fd(fd,OLD,TARGET,sector,before)
                    self.assertEqual(result['targetBytes'],TARGET);self.assertEqual(result['deviceBytes'],OLD)
                    self.assertEqual(result['volumeBytes'],((TARGET-sector)//cluster)*cluster+sector)
                    self.assertRegex(result['inspectionFingerprint'],r'^[0-9a-f]{64}$')
                    # The initial clean/full-extent eligibility path still refuses.
                    with self.assertRaises(ValueError):worker.inspect_fd(fd,OLD,sector)
                    with p.open('rb') as stream:self.assertEqual(hashlib.file_digest(stream,'sha256').hexdigest(),before_hash)
                finally:os.close(fd)


if __name__=='__main__':unittest.main()
