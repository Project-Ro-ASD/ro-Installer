#!/usr/bin/python3 -I
"""Bounded read-only GPT worker. Format: UEFI 2.11 chapter 5.

No repair, mount or partition command is available. The helper owns admission.
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import struct
import sys
import uuid
import zlib

MAX_BYTES = 9007199254740991
MAX_PARTITIONS = 32
MAX_JSON = 7168
HEADER = struct.Struct('<8sIIIIQQQQ16sQIII')
SNAPSHOT_KEYS = {'schemaVersion','device','logicalSectorBytes','firstUsableSector','lastUsableSector',
                 'entryCount','entryBytes','primaryEntriesLba','backupEntriesLba','diskGuid','tableFingerprint','partitions'}


def integer(value, low, high):
    if type(value) is not int or not low <= value <= high:
        raise ValueError('Invalid GPT integer')
    return value


def identity(value):
    if (not isinstance(value,dict) or set(value) != {'path','majorMinor','size','diskSequence'}
            or not isinstance(value['path'],str) or not re.fullmatch(r'/dev/[A-Za-z0-9_-]{1,128}',value['path'])
            or not isinstance(value['majorMinor'],str) or not re.fullmatch(r'(0|[1-9][0-9]*):(0|[1-9][0-9]*)',value['majorMinor'])):
        raise ValueError('Invalid device identity')
    major,minor=map(int,value['majorMinor'].split(':'))
    integer(major,0,4095);integer(minor,0,1048575)
    integer(value['size'],1,MAX_BYTES);integer(value['diskSequence'],1,(1<<63)-1)
    return dict(value)


def guid(value):
    if not isinstance(value,str) or not re.fullmatch(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}',value) or uuid.UUID(value).int == 0:
        raise ValueError('Invalid GPT GUID')
    return value


def normalize_snapshot(value, expected=None):
    if not isinstance(value,dict) or set(value) != SNAPSHOT_KEYS or type(value['schemaVersion']) is not int or value['schemaVersion'] != 1:
        raise ValueError('Invalid GPT snapshot')
    device=identity(value['device'])
    if expected is not None and device != identity(expected):
        raise ValueError('Device changed')
    sector=integer(value['logicalSectorBytes'],512,4096)
    if sector not in (512,4096) or device['size'] % sector:
        raise ValueError('Unsupported sector geometry')
    count=integer(value['entryCount'],1,4096);entry=integer(value['entryBytes'],128,1024)
    if entry not in (128,256,512,1024):raise ValueError('Unsupported GPT entry size')
    reserved=(max(16384,count*entry)+sector-1)//sector;total=device['size']//sector
    first=integer(value['firstUsableSector'],2+reserved,total-reserved-2)
    last=integer(value['lastUsableSector'],first,total-reserved-2)
    primary=integer(value['primaryEntriesLba'],2,first)
    backup=integer(value['backupEntriesLba'],last+1,total-2)
    if primary+reserved>first or backup+reserved>total-1:raise ValueError('GPT metadata overlap')
    disk_guid=guid(value['diskGuid']);fingerprint=value['tableFingerprint']
    if not isinstance(fingerprint,str) or not re.fullmatch('[0-9a-f]{64}',fingerprint):raise ValueError('Invalid GPT fingerprint')
    rows=value['partitions']
    if not isinstance(rows,list) or len(rows)>min(count,MAX_PARTITIONS):raise ValueError('GPT inventory exceeds probe limit')
    numbers=set();guids={disk_guid};parts=[]
    for row in rows:
        if not isinstance(row,dict) or set(row) != {'number','startSector','endSector','typeGuid','partitionGuid','attributesHex'}:raise ValueError('Invalid GPT entry')
        number=integer(row['number'],1,count);start=integer(row['startSector'],first,last);integer(row['endSector'],start,last)
        part_guid=guid(row['partitionGuid']);guid(row['typeGuid'])
        if number in numbers or part_guid in guids:raise ValueError('Duplicate GPT identity')
        if not isinstance(row['attributesHex'],str) or not re.fullmatch('[0-9a-f]{16}',row['attributesHex']):raise ValueError('Invalid GPT attributes')
        numbers.add(number);guids.add(part_guid);parts.append(dict(row))
    parts.sort(key=lambda p:p['startSector'])
    if any(b['startSector']<=a['endSector'] for a,b in zip(parts,parts[1:])):raise ValueError('Overlapping GPT entries')
    result=dict(value,device=device,partitions=parts)
    if len(json.dumps(result,separators=(',',':')).encode())>MAX_JSON:raise ValueError('GPT snapshot exceeds output limit')
    return result


def read_snapshot(read, device, sector):
    device=identity(device)
    if sector not in (512,4096) or device['size'] % sector:raise ValueError('Unsupported sector geometry')
    total=device['size']//sector
    def exact(offset,length):
        if offset<0 or length<=0 or length>4*1024*1024 or offset+length>device['size']:raise ValueError('GPT read out of bounds')
        raw=read(offset,length)
        if len(raw)!=length:raise ValueError('Short GPT read')
        return raw
    mbr=exact(0,sector)
    records=[mbr[446+n*16:462+n*16] for n in range(4)]
    occupied=[r for r in records if any(r)]
    if (mbr[510:512]!=b'\x55\xaa' or any(mbr[512:]) or len(occupied)!=1
            or occupied[0][4]!=0xee or occupied[0][0] not in (0,0x80)
            or struct.unpack_from('<II',occupied[0],8)!=(1,min(total-1,0xffffffff))):
        raise ValueError('Protective MBR required; hybrid layouts unsupported')
    def header(lba,alternate):
        raw=exact(lba*sector,sector);h=HEADER.unpack_from(raw)
        if (h[0]!=b'EFI PART' or h[1]!=0x10000 or not 92<=h[2]<=sector or h[4]!=0
                or h[5]!=lba or h[6]!=alternate or any(raw[92:])):raise ValueError('Invalid GPT header')
        crc=bytearray(raw[:h[2]]);crc[16:20]=bytes(4)
        if zlib.crc32(crc)!=h[3]:raise ValueError('GPT header CRC mismatch')
        integer(h[11],1,4096)
        if h[12] not in (128,256,512,1024):raise ValueError('Unsupported GPT entry size')
        return h,raw
    primary,ph=header(1,total-1);backup,bh=header(total-1,1)
    if any(primary[i]!=backup[i] for i in (1,2,7,8,9,11,12,13)):raise ValueError('GPT copies disagree')
    count,entry=primary[11:13];reserved=(max(16384,count*entry)+sector-1)//sector
    first,last=primary[7:9];p_lba,b_lba=primary[10],backup[10]
    if not (2+reserved<=first<=last<=total-reserved-2 and 2<=p_lba and p_lba+reserved<=first and last<b_lba and b_lba+reserved<=total-1):
        raise ValueError('GPT metadata geometry invalid')
    p_array=exact(p_lba*sector,reserved*sector);b_array=exact(b_lba*sector,reserved*sector)
    length=count*entry
    if (zlib.crc32(p_array[:length])!=primary[13] or zlib.crc32(b_array[:length])!=backup[13]
            or p_array[:length]!=b_array[:length]):raise ValueError('GPT entry CRC or copies disagree')
    parts=[]
    for n in range(count):
        row=p_array[n*entry:(n+1)*entry]
        if not any(row[:16]):continue
        if any(row[128:]):raise ValueError('Unknown GPT entry extension')
        start,end,attrs=struct.unpack_from('<QQQ',row,32)
        parts.append({'number':n+1,'startSector':start,'endSector':end,'typeGuid':str(uuid.UUID(bytes_le=row[:16])),
                      'partitionGuid':str(uuid.UUID(bytes_le=row[16:32])),'attributesHex':f'{attrs:016x}'})
        if len(parts)>MAX_PARTITIONS:raise ValueError('Too many occupied GPT entries')
    digest=hashlib.sha256(b'ro-gpt-snapshot-v1\0'+struct.pack('<QQQQ',device['size'],sector,p_lba,b_lba))
    for raw in (mbr,ph,p_array,b_array,bh):digest.update(struct.pack('<Q',len(raw)));digest.update(raw)
    return normalize_snapshot({'schemaVersion':1,'device':device,'logicalSectorBytes':sector,'firstUsableSector':first,
        'lastUsableSector':last,'entryCount':count,'entryBytes':entry,'primaryEntriesLba':p_lba,'backupEntriesLba':b_lba,
        'diskGuid':str(uuid.UUID(bytes_le=primary[9])),'tableFingerprint':digest.hexdigest(),'partitions':parts},device)


def verified_snapshot(read, device, sector):
    first=read_snapshot(read,device,sector);second=read_snapshot(read,device,sector)
    if first!=second:raise ValueError('GPT changed during probe')
    return second


def compact_plan(snapshot, selected):
    s=normalize_snapshot(snapshot)
    if not isinstance(selected,dict) or set(selected)!={'startSector','endSector'}:raise ValueError('Invalid selected extent')
    start=integer(selected['startSector'],0,MAX_BYTES);end=integer(selected['endSector'],start,MAX_BYTES)
    gaps=[];cursor=s['firstUsableSector']
    for part in s['partitions']:
        if cursor<part['startSector']:gaps.append((cursor,part['startSector']-1))
        cursor=part['endSector']+1
    if cursor<=s['lastUsableSector']:gaps.append((cursor,s['lastUsableSector']))
    if (start,end) not in gaps:raise ValueError('Selected extent is not a current maximal gap')
    used={p['number'] for p in s['partitions']};slots=[n for n in range(1,s['entryCount']+1) if n not in used][:2]
    if len(slots)!=2:raise ValueError('Two GPT slots required')
    sector=s['logicalSectorBytes'];align=1048576//sector;esp_start=(start+align-1)//align*align
    esp_end=esp_start+512*1048576//sector-1;root_start=esp_end+1;root_end=(end+1)//align*align-1
    if root_start>root_end or (root_end-root_start+1)*sector<40*1024**3:raise ValueError('Aligned extent below safety floor')
    return {'schemaVersion':1,'mode':'free_space','device':dict(s['device']),'tableFingerprint':s['tableFingerprint'],
            'selectedExtent':dict(selected),'fileSystem':'btrfs','diskSwap':False,
            'esp':{'number':slots[0],'startSector':esp_start,'endSector':esp_end},
            'root':{'number':slots[1],'startSector':root_start,'endSector':root_end}}


def fd_geometry(fd, expected):
    info=os.fstat(fd)
    if not stat.S_ISBLK(info.st_mode) or f'{os.major(info.st_rdev)}:{os.minor(info.st_rdev)}'!=expected['majorMinor']:
        raise ValueError('Opened device identity mismatch')
    size=struct.unpack('=Q',fcntl.ioctl(fd,0x80081272,bytes(8)))[0]  # BLKGETSIZE64
    sector=struct.unpack('=I',fcntl.ioctl(fd,0x1268,bytes(4)))[0]  # BLKSSZGET
    sequence=struct.unpack('=Q',fcntl.ioctl(fd,0x80081280,bytes(8)))[0]  # BLKGETDISKSEQ
    if size!=expected['size'] or sequence!=expected['diskSequence'] or sector not in (512,4096):raise ValueError('Opened device changed')
    return sector


def verify_kernel_layout(snapshot):
    directory=Path('/sys/dev/block',snapshot['device']['majorMinor']).resolve(strict=True)
    if not str(directory).startswith('/sys/devices/') or (directory/'dev').read_text().strip()!=snapshot['device']['majorMinor']:
        raise ValueError('Kernel device changed')
    actual={}
    for child in directory.iterdir():
        try:number=int((child/'partition').read_text())
        except FileNotFoundError:continue
        start=int((child/'start').read_text());size=int((child/'size').read_text())
        if number in actual or size<=0 or start<0:raise ValueError('Ambiguous kernel partition')
        actual[number]=(start*512,size*512)
    sector=snapshot['logicalSectorBytes']
    expected={p['number']:(p['startSector']*sector,(p['endSector']-p['startSector']+1)*sector) for p in snapshot['partitions']}
    if actual!=expected:raise ValueError('Kernel and GPT partitions disagree')


def probe_device(path, expected):
    expected=identity(expected)
    if path!=expected['path']:raise ValueError('Device path mismatch')
    fd=os.open(path,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW|os.O_NONBLOCK|os.O_EXCL)
    try:
        sector=fd_geometry(fd,expected)
        snapshot=verified_snapshot(lambda offset,length:os.pread(fd,length,offset),expected,sector)
        verify_kernel_layout(snapshot)
        if fd_geometry(fd,expected)!=sector:raise ValueError('Sector geometry changed')
        return snapshot
    finally:os.close(fd)


def main():
    try:
        if os.geteuid()!=0 or len(sys.argv)!=4 or sys.argv[1]!='--probe':return 2
        snapshot=probe_device(sys.argv[2],json.loads(sys.argv[3]))
        raw=json.dumps(snapshot,separators=(',',':'))
        if len(raw.encode())>MAX_JSON:return 2
        sys.stdout.write(raw+'\n');return 0
    except Exception:
        return 2  # No raw disk metadata, filenames or exception text on stderr.


if __name__=='__main__':
    sys.dont_write_bytecode=True
    sys.exit(main())
