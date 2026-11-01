"""EFI capacity checks on temporary normal directories, never mounted devices."""
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from contextlib import redirect_stdout, redirect_stderr
from types import SimpleNamespace
from unittest import mock
from manual_probe_test import worker


def source(path):
    path.mkdir()
    (path/'shimx64.efi').write_bytes(b's'*4097)
    (path/'grubx64.efi').write_bytes(b'g'*1024)
    return path


class BudgetTests(unittest.TestCase):
    def test_source_budget_rounds_each_file_and_reserves_metadata_and_headroom(self):
        with tempfile.TemporaryDirectory() as td:
            path=source(Path(td)/'source')
            (path/'fonts').mkdir();(path/'fonts/font.pf2').write_bytes(b'f')
            for cluster in [512,4096,65536]:
                value=worker.source_budget(str(path),cluster)
                data=sum((n+cluster-1)//cluster*cluster for n in [4097,1024,1])
                self.assertEqual(value,{'requiredBytes':data+(2*4+4)*cluster+16*1048576,
                                        'sourceBytes':5122,'fileCount':3,'clusterBytes':cluster})
                self.assertNotIn('shimx64',json.dumps(value))

    def test_source_symlink_special_case_collision_or_missing_binary_reject(self):
        for fault in ['symlink','fifo','case','filename','missing','empty']:
            with tempfile.TemporaryDirectory() as td:
                path=source(Path(td)/'source')
                if fault=='symlink':(path/'link.efi').symlink_to('/etc/passwd')
                if fault=='fifo':os.mkfifo(path/'pipe')
                if fault=='case':(path/'SHIMX64.EFI').write_bytes(b'other')
                if fault=='filename':(path/'bad?.efi').write_bytes(b'other')
                if fault=='missing':(path/'grubx64.efi').unlink()
                if fault=='empty':(path/'grubx64.efi').write_bytes(b'')
                with self.assertRaises(ValueError):worker.source_budget(str(path),4096)

    def test_depth_byte_and_allocation_bounds_fail_closed(self):
        for cluster in [True,0,511,513,2097152]:
            with self.assertRaises(ValueError):worker.source_budget('/unused',cluster)
        with tempfile.TemporaryDirectory() as td:
            path=source(Path(td)/'source');child=path
            for _ in range(9):child=child/'nested';child.mkdir()
            with self.assertRaises(ValueError):worker.source_budget(str(path),4096)
        with tempfile.TemporaryDirectory() as td:
            path=source(Path(td)/'source')
            with (path/'grubx64.efi').open('wb') as stream:stream.truncate(1024**3+1)
            with self.assertRaises(ValueError):worker.source_budget(str(path),4096)

    def test_inventory_count_has_a_real_upper_bound(self):
        with tempfile.TemporaryDirectory() as td:
            path=source(Path(td)/'source')
            for n in range(4095):(path/f'file{n}.efi').touch()
            with self.assertRaises(ValueError):worker.source_budget(str(path),4096)

    def test_mounted_fd_must_match_role_device_before_reading_source(self):
        with tempfile.TemporaryDirectory() as td:
            path=Path(td)
            real=os.stat(path).st_dev
            wrong=f'{os.major(real)}:{os.minor(real)+1}'
            with mock.patch.object(worker,'ESP_MOUNT_TARGETS',{str(path)}),mock.patch.object(worker,'source_budget') as budget:
                with self.assertRaises(ValueError):worker.mounted_esp_budget(str(path),wrong)
                budget.assert_not_called()
        with self.assertRaises(ValueError):worker.mounted_esp_budget('/arbitrary','8:1')

    def test_allocation_counters_and_changed_geometry_are_checked_without_any_mount(self):
        with tempfile.TemporaryDirectory() as td:
            path=Path(td);src=source(path/'source');dev=os.stat(path).st_dev
            number=f'{os.major(dev)}:{os.minor(dev)}'
            fs=SimpleNamespace(f_bsize=4096,f_frsize=4096,f_blocks=100000,f_bavail=99999)
            local_os=SimpleNamespace(**vars(os))
            with mock.patch.object(worker,'os',local_os),mock.patch.object(worker,'ESP_MOUNT_TARGETS',{str(path)}),mock.patch.object(worker,'EFI_SOURCE',str(src)):
                with mock.patch.object(local_os,'fstatvfs',return_value=fs):
                    value=worker.mounted_esp_budget(str(path),number)
                    self.assertEqual(value['availableBytes'],4096*99999);self.assertTrue(value['sufficient'])
                    fs.f_bavail=0
                    self.assertFalse(worker.mounted_esp_budget(str(path),number)['sufficient'])
                    fs.f_frsize=512
                    with self.assertRaises(ValueError):worker.mounted_esp_budget(str(path),number)
                fs.f_frsize=4096;fs.f_bavail=99999
                changed=SimpleNamespace(f_bsize=8192,f_frsize=8192,f_blocks=100000,f_bavail=99999)
                with mock.patch.object(local_os,'fstatvfs',side_effect=[fs,changed]):
                    with self.assertRaises(ValueError):worker.mounted_esp_budget(str(path),number)

    def test_private_cli_emits_only_fixed_numeric_budget_or_silent_failure(self):
        value={'requiredBytes':20000000,'availableBytes':30000000,'sourceBytes':1000,'fileCount':2,'clusterBytes':4096,'sufficient':True}
        out=io.StringIO()
        with mock.patch.object(worker.os,'geteuid',return_value=0),mock.patch.object(worker,'mounted_esp_budget',return_value=value), \
             mock.patch.object(worker.sys,'argv',['worker','--efi-budget','/mnt/.ro-installer-esp-probe','8:1']),redirect_stdout(out):
            self.assertEqual(worker.main(),0)
        self.assertEqual(json.loads(out.getvalue()),value)
        out,err=io.StringIO(),io.StringIO()
        with mock.patch.object(worker.os,'geteuid',return_value=0),mock.patch.object(worker,'mounted_esp_budget',side_effect=ValueError('PRIVATE_SOURCE')), \
             mock.patch.object(worker.sys,'argv',['worker','--efi-budget','/mnt/.ro-installer-esp-probe','8:1']),redirect_stdout(out),redirect_stderr(err):
            self.assertEqual(worker.main(),2)
        self.assertEqual(out.getvalue()+err.getvalue(),'')


if __name__=='__main__':unittest.main(verbosity=2)
