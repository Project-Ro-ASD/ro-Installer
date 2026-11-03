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


def read_snapshot(read, device, sector, preserve_slots=None, *, ntfs_layout=None):
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
    snapshot=normalize_snapshot({'schemaVersion':1,'device':device,'logicalSectorBytes':sector,'firstUsableSector':first,
        'lastUsableSector':last,'entryCount':count,'entryBytes':entry,'primaryEntriesLba':p_lba,'backupEntriesLba':b_lba,
        'diskGuid':str(uuid.UUID(bytes_le=primary[9])),'tableFingerprint':digest.hexdigest(),'partitions':parts},device)
    if ntfs_layout is not None:
        if preserve_slots is not None:
            raise ValueError('Conflicting GPT preservation policies')
        return _ntfs_preservation(snapshot, (mbr, ph, p_array, b_array, bh), ntfs_layout)
    if preserve_slots is None:return snapshot
    if (not isinstance(preserve_slots,list) or len(preserve_slots)>2
            or any(type(n) is not int or not 1<=n<=count for n in preserve_slots) or len(set(preserve_slots))!=len(preserve_slots)):
        raise ValueError('Invalid preservation slots')
    masked=[]
    for raw in (mbr,ph,p_array,b_array,bh):masked.append(bytearray(raw))
    for raw in (masked[1],masked[4]):raw[16:20]=bytes(4);raw[88:92]=bytes(4)
    for raw in (masked[2],masked[3]):
        for n in preserve_slots:raw[(n-1)*entry:n*entry]=bytes(entry)
    proof=hashlib.sha256(b'ro-gpt-preservation-v1\0'+struct.pack('<QQQQ',device['size'],sector,p_lba,b_lba))
    for raw in masked:proof.update(struct.pack('<Q',len(raw)));proof.update(raw)
    return {'snapshot':snapshot,'preservationFingerprint':proof.hexdigest()}


def _ntfs_preservation(snapshot, metadata, layout):
    """Mask only source-end bytes and one root slot, never the whole source.

    This raw proof must be paired with exact planned geometry/GUID verification;
    it neither proves filesystem safety nor authorizes a write.
    """
    if not isinstance(layout, dict) or set(layout) != {'sourceNumber', 'rootNumber'}:
        raise ValueError('Invalid NTFS preservation slots')
    source = integer(layout['sourceNumber'], 1, snapshot['entryCount'])
    root = integer(layout['rootNumber'], 1, snapshot['entryCount'])
    rows = {p['number']: p for p in snapshot['partitions']}
    if (source == root or source not in rows
            or rows[source]['typeGuid'] != 'ebd0a0a2-b9e5-4433-87c0-68b6b72699c7'
            or rows[source]['attributesHex'] != '0000000000000000'
            or root in rows and (rows[root]['typeGuid'] != '0fc63daf-8483-4772-8e79-3d69d8477de4'
                                  or rows[root]['attributesHex'] != '0000000000000000')):
        raise ValueError('Unsupported NTFS preservation binding')
    masked = [bytearray(raw) for raw in metadata]
    for raw in (masked[1], masked[4]):
        raw[16:20] = bytes(4)  # Header CRC.
        raw[88:92] = bytes(4)  # Entry-array CRC.
    entry = snapshot['entryBytes']
    for raw in (masked[2], masked[3]):
        end_offset = (source - 1) * entry + 40
        raw[end_offset:end_offset + 8] = bytes(8)
        raw[(root - 1) * entry:root * entry] = bytes(entry)
    disk = snapshot['device']
    proof = hashlib.sha256(b'ro-gpt-ntfs-tail-preservation-v1\0' + struct.pack('<QQQQII',
        disk['size'], snapshot['logicalSectorBytes'], snapshot['primaryEntriesLba'],
        snapshot['backupEntriesLba'], source, root))
    for raw in masked:
        proof.update(struct.pack('<Q', len(raw))); proof.update(raw)
    return {'snapshot': snapshot, 'preservationFingerprint': proof.hexdigest()}


def verified_ntfs_snapshot(read, device, sector, source_number, root_number):
    layout = {'sourceNumber': source_number, 'rootNumber': root_number}
    first = read_snapshot(read, device, sector, ntfs_layout=layout)
    second = read_snapshot(read, device, sector, ntfs_layout=layout)
    if first != second:
        raise ValueError('GPT changed during NTFS preservation probe')
    return second


def verified_snapshot(read, device, sector, preserve_slots=None):
    first=read_snapshot(read,device,sector,preserve_slots);second=read_snapshot(read,device,sector,preserve_slots)
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


def ntfs_shrink_plan(proposal):
    """Pure geometry on normalized GPT input; never filesystem/write authority."""
    fields = {'schemaVersion', 'snapshot', 'sourceNumber', 'espNumber',
              'rootBytes', 'minimumFilesystemBytes'}
    if (not isinstance(proposal, dict) or set(proposal) != fields
            or type(proposal['schemaVersion']) is not int or proposal['schemaVersion'] != 1):
        raise ValueError('Invalid NTFS shrink proposal')
    s = normalize_snapshot(proposal['snapshot'])
    source_number = integer(proposal['sourceNumber'], 1, 4096)
    esp_number = integer(proposal['espNumber'], 1, 4096)
    rows = {p['number']: p for p in s['partitions']}
    if source_number not in rows or esp_number not in rows or source_number == esp_number:
        raise ValueError('Select distinct observed partitions')
    source, esp = rows[source_number], rows[esp_number]
    sector = s['logicalSectorBytes']; align = 1048576 // sector
    if (source['typeGuid'] != 'ebd0a0a2-b9e5-4433-87c0-68b6b72699c7'
            or esp['typeGuid'] != 'c12a7328-f81f-11d2-ba4b-00a0c93ec93b'
            or source['attributesHex'] != '0000000000000000'
            or esp['attributesHex'] != '0000000000000000'
            or source['startSector'] % align
            or (esp['endSector'] - esp['startSector'] + 1) * sector < 512 * 1048576):
        raise ValueError('Unsupported source or reusable ESP geometry')
    root_bytes = integer(proposal['rootBytes'], 40 * 1024**3, MAX_BYTES)
    minimum = integer(proposal['minimumFilesystemBytes'], 1,
                      (source['endSector'] - source['startSector'] + 1) * sector)
    if root_bytes % 1048576 or len(rows) >= MAX_PARTITIONS:
        raise ValueError('Root alignment or inventory limit')
    slot = next((n for n in range(1, s['entryCount'] + 1) if n not in rows), None)
    if slot is None:
        raise ValueError('No free GPT slot')
    gaps = []; cursor = s['firstUsableSector']
    for part in s['partitions']:
        if cursor < part['startSector']:
            gaps.append((cursor, part['startSector'] - 1))
        cursor = part['endSector'] + 1
    if cursor <= s['lastUsableSector']:
        gaps.append((cursor, s['lastUsableSector']))
    for start, end in gaps:
        aligned_start = (start + align - 1) // align * align
        aligned_end = (end + 1) // align * align
        if (aligned_end - aligned_start) * sector >= root_bytes:
            raise ValueError('Shrink unnecessary; use create-only free space')
    exclusive_end = source['endSector'] + 1
    for start, end in gaps:
        if start == exclusive_end:
            exclusive_end = end + 1
            break
    exclusive_end = exclusive_end // align * align
    root_start = exclusive_end - root_bytes // sector
    if root_start > source['endSector']:
        raise ValueError('Shrink unnecessary; use create-only free space')
    source_end = root_start - 1
    retained = (source_end - source['startSector'] + 1) * sector
    if (root_start <= source['startSector'] or retained < 40 * 1024**3
            or retained < minimum + 1024**3):
        raise ValueError('Insufficient retained source capacity')
    return {'schemaVersion': 1, 'layoutVersion': 1, 'mode': 'alongside_ntfs_shrink',
            'device': dict(s['device']), 'tableFingerprint': s['tableFingerprint'],
            'fileSystem': 'btrfs', 'diskSwap': False,
            'subvolumes': {'root': '/', 'home': '/home', 'var_log': '/var/log',
                          'var_cache': '/var/cache', 'var_tmp': '/var/tmp'},
            'source': dict(source, newEndSector=source_end,
                           minimumFilesystemBytes=minimum, retainedBytes=retained),
            'esp': dict(esp, formatOnInstall=False),
            'root': {'number': slot, 'startSector': root_start,
                     'endSector': exclusive_end - 1,
                     'typeGuid': '0fc63daf-8483-4772-8e79-3d69d8477de4',
                     'formatOnInstall': True}}


def normalize_ntfs_approval(value):
    """Private helper/backend ownership, never public resize admission."""
    if not isinstance(value, dict) or set(value) != {'proposal', 'approval'}:
        raise ValueError('Invalid private NTFS approval')
    proposal = value['proposal']
    intent = ntfs_shrink_plan(proposal)
    proposal = dict(proposal, snapshot=normalize_snapshot(proposal['snapshot']))
    approval = value['approval']
    fields = {'intent', 'rootGuid', 'preservationFingerprint', 'inspectionFingerprint', 'preparationFingerprint'}
    if not isinstance(approval, dict) or set(approval) != fields:
        raise ValueError('Invalid NTFS ownership')
    root = guid(approval['rootGuid'])
    snapshot = proposal['snapshot']
    if root in {snapshot['diskGuid'], *(part['partitionGuid'] for part in snapshot['partitions'])}:
        raise ValueError('Reused NTFS allocation identity')
    fingerprints = {}
    for name in ('preservationFingerprint', 'inspectionFingerprint', 'preparationFingerprint'):
        observed = approval[name]
        if not isinstance(observed, str) or not re.fullmatch('[0-9a-f]{64}', observed):
            raise ValueError('Invalid NTFS fingerprint')
        fingerprints[name] = observed
    expected = {'intent': intent, 'rootGuid': root, **fingerprints}
    if json.dumps(approval, sort_keys=True, allow_nan=False) != json.dumps(expected, sort_keys=True, allow_nan=False):
        raise ValueError('NTFS ownership differs from the bound proposal')
    return {'proposal': proposal, 'approval': expected}


def verify_ntfs_created_layout(proposal, root_guid, preservation_fingerprint, observed):
    """Pure final GPT check; filesystem resize and write admission are separate."""
    plan = ntfs_shrink_plan(proposal)
    before = normalize_snapshot(proposal['snapshot'])
    root_guid = guid(root_guid)
    if root_guid in {before['diskGuid'], *(p['partitionGuid'] for p in before['partitions'])}:
        raise ValueError('Reused NTFS root allocation identity')
    if (not isinstance(preservation_fingerprint, str)
            or not re.fullmatch('[0-9a-f]{64}', preservation_fingerprint)
            or not isinstance(observed, dict) or set(observed) != {'snapshot', 'preservationFingerprint'}
            or observed['preservationFingerprint'] != preservation_fingerprint):
        raise ValueError('Protected GPT metadata changed')
    current = normalize_snapshot(observed['snapshot'], before['device'])
    def header(snapshot):
        return {key: value for key, value in snapshot.items() if key not in {'tableFingerprint', 'partitions'}}
    if header(before) != header(current):
        raise ValueError('GPT header geometry changed')
    expected = []
    for part in before['partitions']:
        expected.append(dict(part, endSector=plan['source']['newEndSector'])
                        if part['number'] == plan['source']['number'] else dict(part))
    expected.append({key: value for key, value in plan['root'].items() if key != 'formatOnInstall'})
    expected[-1].update(partitionGuid=root_guid, attributesHex='0000000000000000')
    expected.sort(key=lambda part: part['startSector'])
    if current['partitions'] != expected:
        raise ValueError('Created NTFS layout differs from the bound plan')
    return current


def ntfs_gpt_update_plan(read, proposal, root_guid, preservation_fingerprint):
    """Pure immutable patches: backup copy first, primary copy second.

    Each patch is (offset, original, replacement). A future applier must bind
    its own device/lease, regenerate this plan, flush the entire backup group
    before touching the primary and verify the final layout. No I/O writes or
    filesystem safety/write admission are provided here.
    """
    plan = ntfs_shrink_plan(proposal)
    before = normalize_snapshot(proposal['snapshot'])
    root_guid = guid(root_guid)
    if root_guid in {before['diskGuid'], *(p['partitionGuid'] for p in before['partitions'])}:
        raise ValueError('Reused NTFS root allocation identity')
    captured = {}
    def capture(offset, length):
        raw = read(offset, length)
        if not isinstance(raw, bytes):
            raise ValueError('GPT reader must return immutable bytes')
        captured[(offset, length)] = raw
        return raw
    source, root = plan['source']['number'], plan['root']['number']
    device, sector = before['device'], before['logicalSectorBytes']
    initial = verified_ntfs_snapshot(capture, device, sector, source, root)
    if initial != {'snapshot': before, 'preservationFingerprint': preservation_fingerprint}:
        raise ValueError('Stale NTFS GPT update input')
    entry, count = before['entryBytes'], before['entryCount']
    reserved = (max(16384, count*entry)+sector-1)//sector*sector
    updates = []
    for entries_lba, header_lba in ((before['backupEntriesLba'], device['size']//sector-1),
                                    (before['primaryEntriesLba'], 1)):
        array_offset, header_offset = entries_lba*sector, header_lba*sector
        original_array = captured[(array_offset, reserved)]
        array = bytearray(original_array)
        struct.pack_into('<Q', array, (source-1)*entry+40, plan['source']['newEndSector'])
        new = bytearray(entry)
        new[:16] = uuid.UUID(plan['root']['typeGuid']).bytes_le
        new[16:32] = uuid.UUID(root_guid).bytes_le
        struct.pack_into('<QQQ', new, 32, plan['root']['startSector'], plan['root']['endSector'], 0)
        array[(root-1)*entry:root*entry] = new
        original_header = captured[(header_offset, sector)]
        header = bytearray(original_header)
        struct.pack_into('<I', header, 88, zlib.crc32(array[:count*entry]))
        header[16:20] = bytes(4)
        struct.pack_into('<I', header, 16, zlib.crc32(header[:HEADER.unpack_from(header)[2]]))
        updates.append(((array_offset, original_array, bytes(array)),
                        (header_offset, original_header, bytes(header))))
    overlay = dict(captured)
    for group in updates:
        for offset, original, replacement in group:
            overlay[(offset, len(original))] = replacement
    observed = verified_ntfs_snapshot(lambda offset, length: overlay[(offset, length)],
                                      device, sector, source, root)
    verify_ntfs_created_layout(proposal, root_guid, preservation_fingerprint, observed)
    if verified_ntfs_snapshot(read, device, sector, source, root) != initial:
        raise ValueError('GPT changed while planning update')
    return tuple(updates)


def manual_choice(value):
    if not isinstance(value, dict):
        raise ValueError('Invalid manual selection')
    if value.get('source') == 'existing' and set(value) == {'source', 'number', 'formatOnInstall'}:
        integer(value['number'], 1, 4096)
        if type(value['formatOnInstall']) is not bool:
            raise ValueError('Explicit format decision required')
    elif value.get('source') == 'create' and set(value) == {'source', 'startSector', 'endSector'}:
        start = integer(value['startSector'], 0, MAX_BYTES)
        integer(value['endSector'], start, MAX_BYTES)
    else:
        raise ValueError('Unsupported manual selection')
    return dict(value)


def manual_intent_choices(value, expected):
    if (not isinstance(value,dict) or set(value)!={'schemaVersion','layoutVersion','mode','device','tableFingerprint','fileSystem','diskSwap','subvolumes','esp','root'}
            or type(value['schemaVersion']) is not int or value['schemaVersion']!=1
            or type(value['layoutVersion']) is not int or value['layoutVersion']!=1
            or value['mode']!='manual' or value['fileSystem']!='btrfs' or value['diskSwap'] is not False
            or identity(value['device'])!=identity(expected)
            or not isinstance(value['tableFingerprint'],str) or not re.fullmatch('[0-9a-f]{64}',value['tableFingerprint'])
            or value['subvolumes']!={'root':'/','home':'/home','var_log':'/var/log','var_cache':'/var/cache','var_tmp':'/var/tmp'}):
        raise ValueError('Invalid manual intent')
    choices={}
    for role in ('esp','root'):
        row=value[role]
        fields={'source','number','startSector','endSector','typeGuid','fileSystem','mountPoint','formatOnInstall'}
        if not isinstance(row,dict):raise ValueError('Invalid manual binding')
        if row.get('source')=='existing':fields|={'partitionGuid','attributesHex'}
        if set(row)!=fields or type(row['formatOnInstall']) is not bool:raise ValueError('Invalid manual binding')
        integer(row['number'],1,4096);start=integer(row['startSector'],0,MAX_BYTES);integer(row['endSector'],start,MAX_BYTES)
        if (row['typeGuid']!=('c12a7328-f81f-11d2-ba4b-00a0c93ec93b' if role=='esp' else '0fc63daf-8483-4772-8e79-3d69d8477de4')
                or row['fileSystem']!=('fat32' if role=='esp' else 'btrfs') or row['mountPoint']!=('/boot/efi' if role=='esp' else '/')
                or (role=='root' or row['source']=='create') and row['formatOnInstall'] is not True):
            raise ValueError('Unsupported manual binding')
        if row['source']=='existing':
            guid(row['partitionGuid'])
            if row['attributesHex']!='0000000000000000':raise ValueError('Unsupported attributes')
            choices[role]=manual_choice({'source':'existing','number':row['number'],'formatOnInstall':row['formatOnInstall']})
        else:
            choices[role]=manual_choice({'source':row['source'],'startSector':row['startSector'],'endSector':row['endSector']})
    return choices


def manual_plan(snapshot, choices):
    s = normalize_snapshot(snapshot)
    if not isinstance(choices, dict) or set(choices) != {'esp', 'root'}:
        raise ValueError('Exactly two manual roles required')
    choices = {role: manual_choice(choices[role]) for role in ('esp', 'root')}
    if choices['root'].get('formatOnInstall', True) is not True:
        raise ValueError('Root must be formatted')
    additions = sum(c['source'] == 'create' for c in choices.values())
    if len(s['partitions']) + additions > MAX_PARTITIONS:
        raise ValueError('Manual inventory exceeds probe limit')
    used = {p['number'] for p in s['partitions']}
    gaps = []; cursor = s['firstUsableSector']
    for p in s['partitions']:
        if cursor < p['startSector']:
            gaps.append((cursor, p['startSector'] - 1))
        cursor = p['endSector'] + 1
    if cursor <= s['lastUsableSector']:
        gaps.append((cursor, s['lastUsableSector']))
    result = {'schemaVersion': 1, 'layoutVersion': 1, 'mode': 'manual',
              'device': dict(s['device']), 'tableFingerprint': s['tableFingerprint'],
              'fileSystem': 'btrfs', 'diskSwap': False,
              'subvolumes': {'root': '/', 'home': '/home', 'var_log': '/var/log',
                            'var_cache': '/var/cache', 'var_tmp': '/var/tmp'}}
    for role in ('esp', 'root'):
        choice = choices[role]
        type_guid = ('c12a7328-f81f-11d2-ba4b-00a0c93ec93b' if role == 'esp'
                     else '0fc63daf-8483-4772-8e79-3d69d8477de4')
        part = None
        if choice['source'] == 'existing':
            rows = [p for p in s['partitions'] if p['number'] == choice['number']]
            if len(rows) != 1:
                raise ValueError('Missing selected partition')
            part = rows[0]
            if part['typeGuid'] != type_guid or part['attributesHex'] != '0000000000000000':
                raise ValueError('Unsupported writable type or attributes')
            number, start, end = part['number'], part['startSector'], part['endSector']
        else:
            start = integer(choice['startSector'], s['firstUsableSector'], s['lastUsableSector'])
            end = integer(choice['endSector'], start, s['lastUsableSector'])
            alignment = 1048576 // s['logicalSectorBytes']
            if start % alignment or (end + 1) % alignment or not any(a <= start <= end <= b for a, b in gaps):
                raise ValueError('New role is not aligned in a current free extent')
            number = next((n for n in range(1, s['entryCount'] + 1) if n not in used), None)
            if number is None:
                raise ValueError('No unused GPT slot')
            used.add(number)
        minimum = 512 * 1048576 if role == 'esp' else 40 * 1024**3
        if (end - start + 1) * s['logicalSectorBytes'] < minimum:
            raise ValueError('Manual role below safety floor')
        binding = {'source': choice['source'], 'number': number, 'startSector': start,
                   'endSector': end, 'typeGuid': type_guid,
                   'fileSystem': 'fat32' if role == 'esp' else 'btrfs',
                   'mountPoint': '/boot/efi' if role == 'esp' else '/',
                   'formatOnInstall': choice.get('formatOnInstall', True)}
        if part is not None:
            binding.update(partitionGuid=part['partitionGuid'], attributesHex=part['attributesHex'])
        result[role] = binding
    a, b = result['esp'], result['root']
    if a['number'] == b['number'] or a['startSector'] <= b['endSector'] and b['startSector'] <= a['endSector']:
        raise ValueError('Manual roles overlap')
    return result



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


def probe_device(path, expected, preserve_slots=None):
    expected=identity(expected)
    if path!=expected['path']:raise ValueError('Device path mismatch')
    fd=os.open(path,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW|os.O_NONBLOCK|os.O_EXCL)
    try:
        sector=fd_geometry(fd,expected)
        snapshot=verified_snapshot(lambda offset,length:os.pread(fd,length,offset),expected,sector,preserve_slots)
        verify_kernel_layout(snapshot if preserve_slots is None else snapshot['snapshot'])
        if fd_geometry(fd,expected)!=sector:raise ValueError('Sector geometry changed')
        return snapshot
    finally:os.close(fd)


def main():
    try:
        if os.geteuid()!=0 or len(sys.argv) not in (4,6) or sys.argv[1]!='--probe':return 2
        slots=None
        if len(sys.argv)==6:
            if sys.argv[4]!='--preserve-slots':return 2
            slots=json.loads(sys.argv[5])
            if not isinstance(slots,list) or len(slots)!=2 or any(type(n) is not int or not 1<=n<=4096 for n in slots):return 2
        snapshot=probe_device(sys.argv[2],json.loads(sys.argv[3]),slots)
        raw=json.dumps(snapshot,separators=(',',':'))
        if len(raw.encode())>(MAX_JSON if slots is None else 8191):return 2
        sys.stdout.write(raw+'\n');return 0
    except Exception:
        return 2  # No raw disk metadata, filenames or exception text on stderr.


if __name__=='__main__':
    sys.dont_write_bytecode=True
    sys.exit(main())
