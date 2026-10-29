#!/usr/bin/env python3
"""Synthetic record cost; isolated subprocess per repeat, never an install benchmark."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import resource
import statistics
import subprocess
import sys
import tempfile
import time
import tracemalloc

ROOT=Path(__file__).resolve().parents[2]
parser=argparse.ArgumentParser();parser.add_argument('--worker',choices=['disabled','enabled','limit']);parser.add_argument('--events',type=int,default=1000);parser.add_argument('--runs',type=int,default=5);args=parser.parse_args()
spec=importlib.util.spec_from_file_location('record_benchmark',ROOT/'linux/ro_installer_records.py')
r=importlib.util.module_from_spec(spec);spec.loader.exec_module(r)


def worker(mode):
    with tempfile.TemporaryDirectory(prefix='p0-04-benchmark-') as td:
        calls={name:0 for name in ('open','close','fstat','mkdir','scandir','write','fsync','rename','unlink')}
        original={name:getattr(os,name) for name in calls}
        written_bytes=0
        def counted(name):
            def wrapped(*a,**k):
                nonlocal written_bytes
                calls[name]+=1
                value=original[name](*a,**k)
                if name=='write':written_bytes+=value
                return value
            return wrapped
        for name in calls:setattr(os,name,counted(name))
        tracemalloc.start();start=time.perf_counter_ns();rec=None
        try:
            if mode!='disabled':
                rec=r.Recorder(directory=td+'/records',owner_uid=os.geteuid(),limits={**r.LIMITS,**({'events':100} if mode=='limit' else {})},write=os.write)
            for _ in range(args.events):
                value={'eventType':'command.end','stageId':5,'operationId':'copy.main','status':'success','durationMs':1,'exitCode':0,'errorCode':None}
                if rec is not None:rec.observe(value)
            if rec is not None:
                rec.finish(8)
                rec.close()
            elapsed=time.perf_counter_ns()-start
            peak=tracemalloc.get_traced_memory()[1]
            result={'mode':mode,'attemptedEvents':args.events,'durationNs':elapsed,'nsPerAttempt':elapsed/args.events,'eventFileBytes':rec.bytes if rec else 0,'totalWrittenBytes':written_bytes,'events':rec.events if rec else 0,'fileOperations':calls.copy(),'tracemallocPeakBytes':peak,'maxRssKiB':resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,'logStatus':rec.report['logStatus'] if rec else 'disabled'}
        finally:
            if rec is not None:rec.close()
            tracemalloc.stop()
            for name,value in original.items():setattr(os,name,value)
        print(json.dumps(result))


if args.worker:worker(args.worker)
else:
    rows=[]
    for _ in range(args.runs):
        for mode in ['disabled','enabled','limit']:
            result=subprocess.run([sys.executable,str(Path(__file__).resolve()),'--worker',mode,'--events',str(args.events)],capture_output=True,text=True,check=True)
            rows.append(json.loads(result.stdout))
    summary={}
    for mode in ['disabled','enabled','limit']:
        data=[x for x in rows if x['mode']==mode];times=[x['nsPerAttempt'] for x in data]
        summary[mode]={'minNsPerAttempt':min(times),'medianNsPerAttempt':statistics.median(times),'maxNsPerAttempt':max(times),'runs':len(data),'maxTracemallocPeakBytes':max(x['tracemallocPeakBytes'] for x in data),'maxRssKiB':max(x['maxRssKiB'] for x in data)}
    delta=summary['enabled']['medianNsPerAttempt']-summary['disabled']['medianNsPerAttempt']
    print(json.dumps({'schemaVersion':1,'synthetic':True,'notPhysicalInstallation':True,'eventsPerSession':args.events,'summary':summary,'medianAddedNsPerEvent':delta,'medianAddedMsPerSyntheticSession':delta*args.events/1e6,'samples':rows},indent=2))
