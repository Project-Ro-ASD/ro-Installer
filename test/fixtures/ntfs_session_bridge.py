#!/usr/bin/env python3
"""Isolated fake broker/engine/storage lifecycle; new ordinary files only."""
import ctypes,json,os,socket,stat,sys,time
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

root=Path(sys.argv[1]);directory=Path(sys.argv[2]);lease=int(sys.argv[3]);mode=sys.argv[4]
assert stat.S_ISREG(os.fstat(lease).st_mode) and os.fstat(lease).st_ino==(directory/'new-lease').stat().st_ino
assert directory.lstat().st_uid==os.geteuid() and stat.S_IMODE(directory.lstat().st_mode)==0o700
sys.path.insert(0,str(root/'test/scripts'))
import installer_helper_test as legacy
from ntfs_native_runner_test import proxy
session=legacy.load_module('storage_session_fixture',root/'linux/ro-installer-session')
gate=legacy.load_module('storage_gate_fixture',root/'linux/ro-installer-helper')
base=json.loads((root/'test/fixtures/ntfs_approvals_v1.json').read_text())['bases'][0]
parent=ctypes.CDLL(None);assert parent.prctl(36,1,0,0,0)==0
class Device:
    def public(self):return base['input']['proposal']['snapshot']['device']
identity=Device()
fixture_gate=SimpleNamespace(System=lambda:SimpleNamespace(),validate_device=lambda *args:identity,
    unique_object=gate.unique_object,BACKEND_TIMEOUT=.1)

worker=directory/'fake_worker.py'
with worker.open('x') as stream:stream.write('''import json,os,sys,time
from pathlib import Path
p=Path(sys.argv[1]);mode=sys.argv[2]
frame=json.load(sys.stdin)
assert set(frame)=={'namespace','parentNamespace','approvedPlan'}
assert frame['namespace']=='mnt:[42]' and frame['parentNamespace']=='mnt:[41]'
assert frame['approvedPlan']==json.loads((p/'approved.json').read_text())
lease=int(sys.argv[3]);os.fstat(lease)
(p/'started').write_text(str(os.getpid()))
until=time.monotonic()+8
while not (p/'release').exists() and time.monotonic()<until:time.sleep(.005)
time.sleep(10 if mode=='timeout' else .25)
(p/'complete').write_text('quiescent')
base=json.loads((p/'base.json').read_text())
outcome={'schemaVersion':1,'status':'success','snapshot':base['created'],'preservationFingerprint':base['proof']}
if mode=='leak':
 child=os.fork()
 if child==0:time.sleep(3);os._exit(0)
 (p/'grandchild').write_text(str(child))
if mode=='stderr':sys.stderr.write('PRIVATE_DEVICE_LABEL')
if mode=='overflow':sys.stdout.write('x'*9000)
elif mode=='bad-json':sys.stdout.write('{}')
else:print(json.dumps(outcome))
sys.exit(2 if mode=='bad-exit' else 0)
''')
engine=directory/'fake_engine.py'
with engine.open('x') as stream:stream.write('''import json,os,socket,sys,time
from pathlib import Path
p=Path(os.environ['FIXTURE_DIR']);mode=os.environ['FIXTURE_MODE']
def exchange():
 sock=socket.socket(socket.AF_UNIX);sock.connect(os.environ['FIXTURE_SOCKET'])
 approved=json.loads((p/'approved.json').read_text())
 if mode=='wrong-device':
  approved['proposal']['snapshot']['device']['diskSequence']=99
  approved['approval']['intent']['device']['diskSequence']=99
 if mode=='wrong-ownership':approved['approval']['rootGuid']='invalid'
 sock.sendall((json.dumps({'op':'ntfs-transaction','approvedPlan':approved})+'\\n').encode())
 return sock
sock=exchange()
if mode=='crash':
 until=time.monotonic()+3
 while not (p/'started').exists() and time.monotonic()<until:time.sleep(.01)
 os._exit(17)
if mode=='disconnect':sock.close();time.sleep(.5)
else:
 stream=sock.makefile('rb');result=json.loads(stream.readline());stream.close();sock.close()
 (p/'reply.json').write_text(json.dumps(result))
 if mode=='repeat':
  sock=exchange();stream=sock.makefile('rb');(p/'repeat.json').write_text(stream.readline().decode());stream.close();sock.close()
''')
(directory/'base.json').write_text(json.dumps(base));(directory/'approved.json').write_text(json.dumps(base['input']))
real_popen=session.subprocess.Popen
spawns=[]
def spawn(argv,**kwargs):
    if tuple(argv)==session.NTFS_WORKER:
        assert kwargs['env']==session.ROOT_ENV and kwargs['pass_fds']==(lease,)
        assert kwargs['start_new_session'] is True and kwargs['close_fds'] is True
        spawns.append(True)
        process=real_popen([sys.executable,'-I',str(worker),str(directory),mode,str(lease)],**kwargs)
        if mode=='wait-error':
            actual_wait=process.wait;first=[True]
            def wait(*args,**options):
                if first[0]:first[0]=False;raise OSError('private wait failure')
                return actual_wait(*args,**options)
            process.wait=wait
        if mode=='close-error':
            original=process.stdout
            class CloseOnce:
                @property
                def closed(self):return original.closed
                def fileno(self):return original.fileno()
                def close(self):original.close();raise OSError('private close failure')
            process.stdout=CloseOnce()
        return process
    process=real_popen(argv,**kwargs)
    actual_wait=process.wait
    first=[True]
    def wait(*args,**options):
        if first[0]:
            first[0]=False
            deadline=time.monotonic()+5
            while not supervisor.ntfs_attempted and process.poll() is None and time.monotonic()<deadline:time.sleep(.01)
            if supervisor.ntfs_attempted:raise session.subprocess.TimeoutExpired(argv,options.get('timeout'))
        return actual_wait(*args,**options)
    process.wait=wait
    return process
real_thread=session.threading.Thread
def thread(*args,**kwargs):
    result=real_thread(*args,**kwargs)
    if mode=='thread-error' and getattr(kwargs.get('target'),'__name__','')=='write':
        def fail():raise RuntimeError('private thread start failure')
        result.start=fail
    return result
with mock.patch.object(session,'threading',proxy(session.threading,Thread=thread)), \
     mock.patch.object(session,'verify_private'),mock.patch.object(session,'subprocess',proxy(session.subprocess,Popen=spawn)), \
     mock.patch.object(session,'NTFS_OPERATION_TIMEOUT',5), \
     mock.patch.object(session,'NTFS_SESSION_TIMEOUT',8):
    supervisor=session.Supervisor(fixture_gate,lease,'mnt:[41]','mnt:[42]',str(directory))
    supervisor.expected=identity
    result=supervisor.run((sys.executable,'-I',str(engine)),{**session.ROOT_ENV,'FIXTURE_DIR':str(directory),
        'FIXTURE_MODE':mode,'FIXTURE_SOCKET':supervisor.path})
    assert supervisor.storage_active is False
    (directory/'session-result.json').write_text(json.dumps({'status':result,'spawns':len(spawns),
        'storageFailed':supervisor.storage_failed}))
