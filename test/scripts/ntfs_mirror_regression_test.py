#!/usr/bin/env python3
"""Native MFT mirror disagreement, only on newly created regular images."""
import hashlib
import os
from pathlib import Path
import stat
import struct
import subprocess
import tempfile
import unittest
from unittest import mock
import installer_helper_test as legacy

worker=legacy.load_module('ntfs_mirror_worker',legacy.ROOT/'linux/ro_installer_ntfs.py')
SIZE=512*1024**2
TARGET=256*1024**2


def digest(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()


def image(directory,sector):
    path=Path(directory)/'new-regular-ntfs.img'
    with path.open('xb') as stream:stream.truncate(SIZE)
    info=path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink!=1:raise AssertionError('normal fixture required')
    subprocess.run(['/usr/bin/mkntfs','-F','-Q','-s',str(sector),'-c','4096',str(path)],
                   capture_output=True,check=True,timeout=20)
    return path


def disagree(path,fd,sector):
    boot=os.pread(fd,sector,0);cluster=boot[13]*sector
    mft,mirror=struct.unpack_from('<QQ',boot,48)
    if not 0<mft!=mirror or (mirror+1)*cluster>TARGET:raise AssertionError('fresh fixture geometry changed')
    # Change only the mirror record's LSN. Keep FILE magic, USA offset/count,
    # update-sequence fixups, primary MFT, attributes and boot sectors intact.
    offset=mirror*cluster+8;old=os.pread(fd,8,offset)
    changed=struct.pack('<Q',(struct.unpack('<Q',old)[0]+1)%(1<<64))
    with path.open('r+b') as stream:stream.seek(offset);stream.write(changed)
    if os.pread(fd,8,mft*cluster+8)==changed:raise AssertionError('fixture must disagree')
    return offset,old


class MirrorRegressionTests(unittest.TestCase):
    def test_clean_initial_volume_mirror_mismatch_refuses_without_repair(self):
        for sector in (512,4096):
            with tempfile.TemporaryDirectory() as td:
                path=image(td,sector);fd=os.open(path,os.O_RDONLY|os.O_CLOEXEC)
                try:
                    expected=worker.inspect_fd(fd,SIZE,sector)
                    offset,old=disagree(path,fd,sector);before=digest(path)
                    with mock.patch.object(worker,'run_tool',wraps=worker.run_tool) as tool:
                        with self.assertRaises(ValueError):worker.inspect_fd(fd,SIZE,sector)
                        self.assertEqual([call.args[0] for call in tool.call_args_list],['signature'])
                    self.assertEqual(digest(path),before)
                    with path.open('r+b') as stream:stream.seek(offset);stream.write(old)
                    self.assertEqual(worker.inspect_fd(fd,SIZE,sector),expected)
                finally:os.close(fd)

    def test_post_resize_mirror_mismatch_refuses_before_allocation_probe(self):
        for sector in (512,4096):
            with tempfile.TemporaryDirectory() as td:
                path=image(td,sector);fd=os.open(path,os.O_RDONLY|os.O_CLOEXEC)
                try:
                    original,cluster=worker.boot_sector(fd,SIZE,sector)
                    # Fresh-image behavior only: this does not exercise MFT
                    # relocation or qualify the old installed tool for writes.
                    self.assertLess(max(struct.unpack_from('<QQ',original,48))*cluster,TARGET)
                    command=['/usr/bin/ntfsresize','-P','--size',str(TARGET),str(path)]
                    subprocess.run([command[0],'--no-action',*command[1:]],
                                   capture_output=True,check=True,timeout=20)
                    subprocess.run(command,input=b'y\n',capture_output=True,check=True,timeout=20)
                    expected=worker.inspect_resized_fd(fd,SIZE,TARGET,sector,original)
                    offset,old=disagree(path,fd,sector);before=digest(path)
                    # Boot geometry remains valid: only the mirror differs.
                    worker.resized_boot_sector(fd,SIZE,TARGET,sector,original)
                    with mock.patch.object(worker,'run_tool') as tool:
                        with self.assertRaises(ValueError):worker.inspect_resized_fd(fd,SIZE,TARGET,sector,original)
                        tool.assert_not_called()
                    self.assertEqual(digest(path),before)
                    with path.open('r+b') as stream:stream.seek(offset);stream.write(old)
                    self.assertEqual(worker.inspect_resized_fd(fd,SIZE,TARGET,sector,original),expected)
                finally:os.close(fd)


if __name__=='__main__':unittest.main()
