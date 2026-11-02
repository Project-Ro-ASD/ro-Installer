#!/usr/bin/env python3
"""Power capability lifetime with fake logind and a private D-Bus only."""
import contextlib
import ctypes as c
import fcntl
import os
import select
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
from installer_session_test import session


class Function:
    def __init__(self,callback):self.callback=callback
    def __call__(self,*args):return self.callback(*args)


def assign_pointer(output,value):c.cast(output,c.POINTER(c.c_void_p))[0]=value


class FakeLogind:
    def __init__(self,write_fd,fail=None):
        self.write_fd=write_fd;self.fail=fail;self.reply_fd=None;self.calls=[]
        self.sd_bus_new=Function(self.open)
        self.sd_bus_set_address=Function(self.address)
        self.sd_bus_set_bus_client=Function(self.client)
        self.sd_bus_start=Function(lambda bus:self.calls.append('start') or (-1 if self.fail=='start' else 0))
        self.sd_bus_set_method_call_timeout=Function(self.timeout)
        self.sd_bus_call_method=Function(self.call)
        self.sd_bus_message_read=Function(self.read)
        self.sd_bus_message_unref=Function(self.unref_message)
        self.sd_bus_unref=Function(lambda bus:self.calls.append('bus.close'))
    def open(self,out):
        self.calls.append('open');assign_pointer(out,111)
        return -1 if self.fail=='open' else 0
    def address(self,bus,value):
        self.calls.append('address');assert value==b'unix:path=/run/dbus/system_bus_socket'
        return -1 if self.fail=='address' else 0
    def client(self,bus,value):
        self.calls.append('client');assert value==1
        return -1 if self.fail=='client' else 0
    def timeout(self,bus,timeout):
        self.calls.append('timeout');assert timeout==5_000_000
        return -1 if self.fail=='timeout' else 0
    def call(self,*args):
        self.calls.append('call')
        assert args[1:6]==(b'org.freedesktop.login1',b'/org/freedesktop/login1',
                           b'org.freedesktop.login1.Manager',b'Inhibit',None)
        assert args[7]==b'ssss'
        assert [value.value for value in args[8:]]==[b'sleep:shutdown',b'Ro Installer',b'Installation in progress',b'block']
        assign_pointer(args[6],222);self.reply_fd=os.dup(self.write_fd)
        return -1 if self.fail=='call' else 1
    def read(self,message,types,out):
        self.calls.append('read');assert types==b'h'
        c.cast(out,c.POINTER(c.c_int))[0]=2 if self.fail=='descriptor' else self.reply_fd
        return 0 if self.fail=='empty' else -1 if self.fail=='read' else 1
    def unref_message(self,message):
        self.calls.append('message.close');os.close(self.reply_fd)
        if self.fail=='cleanup':raise RuntimeError('cleanup fixture')


class PowerGuardTests(unittest.TestCase):
    def setUp(self):
        previous=os.umask(0o077);os.umask(previous)
        self.addCleanup(os.umask,previous)
        self.addCleanup(setattr,sys,'dont_write_bytecode',sys.dont_write_bytecode)

    def test_borrowed_reply_fd_is_duplicated_cloexec_before_reply_and_bus_close(self):
        read,write=os.pipe();owned=None
        try:
            lib=FakeLogind(write);owned=session._power_fd(lib)
            self.assertEqual(lib.calls,['open','address','client','timeout','start','call','read','message.close','bus.close'])
            self.assertFalse(os.get_inheritable(owned))
            with self.assertRaises(OSError):os.fstat(lib.reply_fd)
            os.close(write);write=None;os.set_blocking(read,False)
            with self.assertRaises(BlockingIOError):os.read(read,1)
            os.close(owned);owned=None
            self.assertEqual(os.read(read,1),b'')
        finally:
            for fd in (read,write,owned):
                if fd is not None:os.close(fd)

    def test_every_acquisition_and_cleanup_failure_releases_owned_resources(self):
        read,write=os.pipe()
        try:
            before=len(os.listdir('/proc/self/fd'))
            for failure in ('open','address','client','timeout','start','call','empty','read','descriptor','cleanup'):
                with self.subTest(failure=failure):
                    lib=FakeLogind(write,failure)
                    with self.assertRaises(RuntimeError):session._power_fd(lib)
                    self.assertEqual(lib.calls[-1],'bus.close')
                    self.assertEqual(len(os.listdir('/proc/self/fd')),before)
        finally:os.close(read);os.close(write)

    def test_dup_failure_closes_reply_and_bus_without_global_close_mock(self):
        read,write=os.pipe();lib=FakeLogind(write)
        proxy=SimpleNamespace(F_DUPFD_CLOEXEC=fcntl.F_DUPFD_CLOEXEC,fcntl=mock.Mock(side_effect=OSError('dup fixture')))
        try:
            before=len(os.listdir('/proc/self/fd'))
            with mock.patch.object(session,'fcntl',proxy):
                with self.assertRaises(OSError):session._power_fd(lib)
            self.assertEqual(lib.calls[-2:],['message.close','bus.close'])
            self.assertEqual(len(os.listdir('/proc/self/fd')),before)
        finally:os.close(read);os.close(write)

    def test_missing_provider_is_a_redacted_fail_closed_error(self):
        proxy=SimpleNamespace(**vars(c));proxy.CDLL=mock.Mock(side_effect=OSError('PRIVATE_BUS_SENTINEL'))
        with mock.patch.object(session,'ctypes',proxy):
            with self.assertRaisesRegex(session.PowerInhibitError,'^POWER_INHIBIT_FAILED$'):
                with session.power_inhibitor():self.fail('must not yield')
        proxy.CDLL.assert_called_once_with('/usr/lib64/libsystemd.so.0')

    def main_fixture(self,guard,engine_status=0,reboot=False,engine_error=None,mode="--auto"):
        gate=mock.MagicMock();gate.InstallerLock.return_value.__enter__.return_value.fd=41
        order=[];module=mock.Mock();module.valid_report.return_value=False
        module.Recorder.return_value.finish.side_effect=lambda *a,**k:order.append('report') or {}
        with tempfile.TemporaryDirectory() as td:
            gate.LOCK_DIRECTORY=td
            env={'RO_INSTALLER_AUTO_PROFILE':'fixture','RO_INSTALLER_AUTO_REBOOT':'1' if reboot else '0'}
            def engine(*args):
                order.append('engine')
                if engine_error:raise engine_error
                return engine_status
            real_remove=session.shutil.rmtree
            def remove(path):order.append('cleanup');real_remove(path)
            with mock.patch.object(session.os,'geteuid',return_value=0),mock.patch.object(session.os,'setsid'), \
                 mock.patch.object(session.sys,'argv',['session',mode]),mock.patch.dict(os.environ,env,clear=True), \
                 mock.patch.object(session,'helper_module',return_value=gate), \
                 mock.patch.object(session,'private_namespace',return_value=('before','after')), \
                 mock.patch.object(session,'records_module',return_value=module), \
                 mock.patch.object(session,'power_inhibitor',side_effect=lambda:guard(order)), \
                 mock.patch.object(session,'Supervisor') as supervisor, \
                 mock.patch.object(session.shutil,'rmtree',side_effect=remove), \
                 mock.patch.object(session.subprocess,'run',side_effect=lambda *a,**k:order.append('reboot')):
                supervisor.return_value.run.side_effect=engine
                result=session.main()
            return result,order,supervisor,module

    def test_main_keeps_guard_through_engine_cleanup_and_releases_before_reboot(self):
        @contextlib.contextmanager
        def guard(order):
            order.append('inhibit')
            try:yield
            finally:order.append('release')
        result,order,_,_=self.main_fixture(guard,reboot=True)
        self.assertEqual(result,0)
        self.assertEqual(order,['inhibit','engine','cleanup','release','report','reboot'])

    def test_gui_backend_uses_same_guard_and_never_takes_auto_reboot_option(self):
        @contextlib.contextmanager
        def guard(order):
            order.append('inhibit')
            try:yield
            finally:order.append('release')
        with mock.patch.object(session,'session_lock',return_value=contextlib.nullcontext(41)):
            result,order,supervisor,_=self.main_fixture(guard,mode='--backend',reboot=True)
        self.assertEqual(result,0)
        self.assertEqual(order,['inhibit','engine','cleanup','release','report'])
        self.assertEqual(supervisor.return_value.run.call_args.args[0],session.BACKEND)

    def test_main_guard_failure_prevents_engine_and_records_specific_failure(self):
        @contextlib.contextmanager
        def guard(order):
            raise session.PowerInhibitError('POWER_INHIBIT_FAILED')
            yield
        result,order,supervisor,module=self.main_fixture(guard,reboot=True)
        self.assertEqual(result,9);supervisor.assert_not_called()
        self.assertEqual(order,['report'])
        self.assertEqual(module.Recorder.return_value.finish.call_args.kwargs['error'],'POWER_INHIBIT_FAILED')
        records=session.records_module()
        with tempfile.TemporaryDirectory() as td:
            recorder=records.Recorder(directory=td,owner_uid=os.geteuid())
            try:
                report=recorder.finish(9,error='POWER_INHIBIT_FAILED',remaining=0)
                self.assertTrue(records.valid_report(report))
                self.assertEqual(report['primaryError'],'POWER_INHIBIT_FAILED')
            finally:recorder.close()

    def test_engine_error_cleans_session_then_releases_guard_without_reboot(self):
        @contextlib.contextmanager
        def guard(order):
            order.append('inhibit')
            try:yield
            finally:order.append('release')
        for error in (RuntimeError('engine fixture'),None):
            result,order,_,_=self.main_fixture(guard,engine_status=9,reboot=True,engine_error=error)
            self.assertEqual(result,9)
            self.assertEqual(order,['inhibit','engine','cleanup','release','report'])

    def test_native_private_bus_reply_fd_survives_real_message_unref(self):
        # Real libsystemd body/FD ownership, with a private daemon and local
        # synthetic reply. Never open the host system bus or call logind.
        lib=c.CDLL('/usr/lib64/libsystemd.so.0');pointer=c.c_void_p
        def bind(name,args,result=c.c_int):
            function=getattr(lib,name);function.argtypes=args;function.restype=result;return function
        new=bind('sd_bus_new',[c.POINTER(pointer)])
        address=bind('sd_bus_set_address',[pointer,c.c_char_p])
        client=bind('sd_bus_set_bus_client',[pointer,c.c_int]);start=bind('sd_bus_start',[pointer])
        call=bind('sd_bus_call_method',[pointer,c.c_char_p,c.c_char_p,c.c_char_p,c.c_char_p,pointer,c.POINTER(pointer),c.c_char_p])
        signal=bind('sd_bus_message_new_signal',[pointer,c.POINTER(pointer),c.c_char_p,c.c_char_p,c.c_char_p])
        append=bind('sd_bus_message_append',[pointer,c.c_char_p])
        seal=bind('sd_bus_message_seal',[pointer,c.c_uint64,c.c_uint64])
        rewind=bind('sd_bus_message_rewind',[pointer,c.c_int])
        read_message=bind('sd_bus_message_read',[pointer,c.c_char_p])
        unref=bind('sd_bus_unref',[pointer],pointer);message_unref=bind('sd_bus_message_unref',[pointer],pointer)
        with tempfile.TemporaryDirectory() as td:
            process=subprocess.Popen(['/usr/bin/dbus-daemon','--session','--nofork','--print-address=1','--address=unix:tmpdir='+td],
                                     stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            bus=pointer();reply=pointer();message=pointer();read,write=os.pipe();handed={'bus':False,'message':False}
            try:
                self.assertTrue(select.select([process.stdout],[],[],5)[0])
                private_address=process.stdout.readline().strip().encode()
                self.assertTrue(private_address.startswith(('unix:path='+td+'/').encode()))
                self.assertEqual(new(c.byref(bus)),0)
                self.assertGreaterEqual(address(bus,private_address),0)
                self.assertGreaterEqual(client(bus,1),0);self.assertGreaterEqual(start(bus),0)
                self.assertGreaterEqual(call(bus,b'org.freedesktop.DBus',b'/org/freedesktop/DBus',
                    b'org.freedesktop.DBus',b'GetId',None,c.byref(reply),b''),0)
                message_unref(reply);reply=pointer()
                self.assertEqual(signal(bus,c.byref(message),b'/test',b'org.ro.Test',b'Capability'),0)
                self.assertGreaterEqual(append(message,b'h',c.c_int(write)),0)
                self.assertEqual(seal(message,1234,0),0);self.assertGreaterEqual(rewind(message,1),0)
                borrowed=c.c_int(-1);self.assertEqual(read_message(message,b'h',c.byref(borrowed)),1)
                self.assertGreaterEqual(rewind(message,1),0)
                def open_private(out):assign_pointer(out,bus.value);handed['bus']=True;return 0
                def synthetic_reply(*args):
                    self.assertEqual(args[4],b'Inhibit');assign_pointer(args[6],message.value)
                    handed['message']=True;return 1
                hybrid=SimpleNamespace(sd_bus_new=Function(open_private),
                    sd_bus_set_address=Function(lambda bus,value:0 if value==b'unix:path=/run/dbus/system_bus_socket' else -1),
                    sd_bus_set_bus_client=Function(lambda bus,value:0 if value==1 else -1),sd_bus_start=Function(lambda bus:0),
                    sd_bus_call_method=Function(synthetic_reply),sd_bus_set_method_call_timeout=lib.sd_bus_set_method_call_timeout,
                    sd_bus_message_read=lib.sd_bus_message_read,sd_bus_message_unref=message_unref,sd_bus_unref=unref)
                proxy=SimpleNamespace(**vars(c));proxy.CDLL=lambda path:hybrid
                with mock.patch.object(session,'ctypes',proxy):
                    with session.power_inhibitor():
                        with self.assertRaises(OSError):os.fstat(borrowed.value)
                        os.close(write);write=None;os.set_blocking(read,False)
                        with self.assertRaises(BlockingIOError):os.read(read,1)
                    self.assertEqual(os.read(read,1),b'')
            finally:
                try:
                    if message and not handed['message']:message_unref(message)
                    if reply:message_unref(reply)
                    if bus and not handed['bus']:unref(bus)
                    os.close(read)
                    if write is not None:os.close(write)
                finally:
                    if process.poll() is None:
                        process.terminate()
                        try:process.wait(timeout=5)
                        except subprocess.TimeoutExpired:process.kill();process.wait(timeout=5)
                    process.stdout.close();process.stderr.close()


if __name__=='__main__':unittest.main()
