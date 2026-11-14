#!/usr/bin/env python3
"""Review-only, one-value CAS experiment for the existing private Wine prefix.

--apply writes ONLY after a durable undo journal. --undo requires that journal.
No game, Steam, UI, canonical prefix, PCI instance key or driver is modified.
An apply/undo invocation starts Wine. Do not run without review.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import uuid

import m3_private_supervisor as base
import m3_reuse_diagnostic as reuse

HELPER=base.PRODUCTS/'setupapi-hardwareid-cas.exe'
HELPER_SHA='f6358956ab6973fe63e8b25fa7c56b7288168abf35e83ac4dd71459fc44b1f87'
APPLE='PCI\\VEN_106B&DEV_03F1&SUBSYS_00000000&REV_00'
AMD='PCI\\VEN_1002&DEV_66AF&SUBSYS_00000000&REV_00'
def encoded(value): return (value+'\0\0').encode('utf-16le').hex()
ORIGINAL=encoded(APPLE); REPLACEMENT=encoded(AMD)

def private_environment(plan,marker,debug='-all'):
    env=dict(plan['environment'])
    env.update(WINEPREFIX=str(reuse.PREFIX),HOME=str(reuse.RUN/'home'),PLAYMELT_TEST_RUN=marker,
               WINEDEBUG=debug,WINEDLLOVERRIDES='d3d12,d3d12core,dxgi=n,b;winemenubuilder.exe=d',
               ROSETTA_ADVERTISE_AVX='1',MVK_CONFIG_LOG_LEVEL='0')
    return env

def extract_record(raw, *, kind, nonce=None):
    """Extract exactly one strict single-line JSON object, preserving raw log."""
    def unique_pairs(pairs):
        out={}
        for key,value in pairs:
            if key in out: raise ValueError('duplicate JSON key')
            out[key]=value
        return out
    def invalid_constant(value): raise ValueError('non-finite JSON value: '+value)
    objects=[]
    for line in raw.splitlines():
        candidate=line.strip()
        if not candidate.startswith('{'): continue
        try: value=json.loads(candidate,object_pairs_hook=unique_pairs,parse_constant=invalid_constant)
        except (ValueError,TypeError) as e: raise RuntimeError('malformed JSON candidate') from e
        if not isinstance(value,dict): raise RuntimeError('JSON candidate is not an object')
        objects.append(value)
    if len(objects)!=1: raise RuntimeError('missing or ambiguous JSON response')
    value=objects[0]
    if kind=='setupapi':
        if type(value.get('schema')) is not int or value['schema']!=1 or value.get('kind')!='playmelt-setupapi-display-probe' or value.get('nonce')!=nonce:
            raise RuntimeError('SetupAPI schema, kind or nonce mismatch')
    elif kind=='cas':
        payload=value.get('hex')
        if value.get('ok') is not True or type(value.get('type')) is not int or value['type']!=7 or not isinstance(payload,str) or not payload or len(payload)>16384 or len(payload)%2 or not re.fullmatch('[0-9a-f]+',payload):
            raise RuntimeError('CAS response ok/type/hex invalid')
    else: raise ValueError('unknown record type')
    return value


def durable_write(folder,record):
    """Persist the complete typed undo before touching the registry."""
    data=(json.dumps(record,sort_keys=True,indent=2)+'\n').encode()
    temp=folder/('journal-'+str(uuid.uuid4())+'.tmp')
    fd=os.open(temp,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    try:
        with os.fdopen(fd,'wb') as f:
            f.write(data); f.flush(); os.fsync(f.fileno())
        os.replace(temp,folder/'journal.json')
        dfd=os.open(folder,os.O_RDONLY)
        try: os.fsync(dfd)
        finally: os.close(dfd)
    except BaseException:
        # Preserve an incomplete temporary record for review; never silently delete.
        raise


def prefix_identity():
    root,prefix=reuse.RUN,reuse.PREFIX
    if root.is_symlink() or prefix.is_symlink() or root.resolve()!=root or prefix.resolve()!=prefix:
        raise RuntimeError('private prefix path changed or is a link')
    a,b=os.lstat(root),os.lstat(prefix)
    if not stat.S_ISDIR(a.st_mode) or not stat.S_ISDIR(b.st_mode) or a.st_uid!=os.geteuid() or b.st_uid!=os.geteuid():
        raise RuntimeError('private prefix ownership invalid')
    return {'root_dev':a.st_dev,'root_ino':a.st_ino,'prefix_dev':b.st_dev,'prefix_ino':b.st_ino,'uid':a.st_uid}


def load_plan():
    import subprocess
    plan=json.loads(subprocess.run([str(base.PLAN_HELPER)],capture_output=True,check=True,timeout=90).stdout)
    previous=json.loads((reuse.RUN/'receipt.json').read_text())
    if (previous.get('prefix')!=str(reuse.PREFIX) or plan['rendererHash']!=previous.get('rendererHash') or
        plan['engineFingerprint']!=previous.get('engineFingerprint') or plan['wine']!=previous.get('wine')):
        raise RuntimeError('renderer, Wine or prefix identity changed')
    if HELPER.is_symlink() or not HELPER.is_file() or hashlib.sha256(HELPER.read_bytes()).hexdigest()!=HELPER_SHA:
        raise RuntimeError('CAS helper identity changed')
    wine=plan['wine']; server=plan['server']
    if server!=str(Path(wine).parent/'wineserver'): raise RuntimeError('unexpected wineserver')
    return plan


def invoke(plan,mode,folder,marker,seen):
    env=private_environment(plan,marker)
    filename=folder/(mode[2:]+'-'+str(uuid.uuid4())+'.log')
    with filename.open('xb',buffering=0) as f:
        child,timed,capped=base.run_command([plan['wine'],str(HELPER),mode],env,str(reuse.RUN),f,30,base.Inspector(),marker,seen)
    code=child.poll();base.reap_child(child)
    if timed or capped or code!=0: raise RuntimeError('CAS helper failed or timed out; inspect '+str(filename))
    return extract_record(filename.read_text(),kind='cas')


def main():
    if len(sys.argv) not in (2,3) or sys.argv[1] not in ('--apply','--undo') or (sys.argv[1]=='--apply' and len(sys.argv)!=2) or (sys.argv[1]=='--undo' and len(sys.argv)!=3):
        print('Review required. Use --apply or --undo UUID.',file=sys.stderr);return 64
    action=sys.argv[1]; plan=load_plan(); identity=prefix_identity(); reuse.require_idle_prefix(reuse.PREFIX)
    if action=='--apply':
        for existing in reuse.RUN.glob('gpu-hardwareid-*/journal.json'):
            state=json.loads(existing.read_text())
            if state.get('state')!='rolled_back': raise RuntimeError('unresolved previous transaction: '+str(existing))
        txn=str(uuid.uuid4()); folder=reuse.RUN/('gpu-hardwareid-'+txn);folder.mkdir(mode=0o700)
    else:
        txn=str(uuid.UUID(sys.argv[2]));folder=reuse.RUN/('gpu-hardwareid-'+txn)
        if folder.is_symlink() or folder.resolve()!=folder or not folder.is_dir(): raise RuntimeError('invalid transaction directory')
    env=private_environment(plan,txn)
    seen={}; shutdown={'shutdown':{}}; record=None
    try:
        current=invoke(plan,'--read',folder,txn,seen)
        if current.get('type')!=7: raise RuntimeError('value is not REG_MULTI_SZ')
        if action=='--apply':
            if current.get('hex')!=ORIGINAL: raise RuntimeError('original value differs; no mutation')
            record={'schema':1,'transaction':txn,'state':'prepared','prefix':str(reuse.PREFIX),'identity':identity,'helper_sha256':HELPER_SHA,
                    'target':'HKLM/SYSTEM/CurrentControlSet/Enum/PCI/VEN_106B&DEV_03F1&SUBSYS_00000000&REV_00/00000000/HardwareID',
                    'type':7,'before_hex':ORIGINAL,'after_hex':REPLACEMENT,'rendererHash':plan['rendererHash'],'engineFingerprint':plan['engineFingerprint'],
                    'limitations':['Experimental adapter identity coherence; no GPU capability is changed.','Wine may rebuild the display registry; causality is unproven.']}
            durable_write(folder,record)
            if prefix_identity()!=identity: raise RuntimeError('prefix changed; no mutation')
            result=invoke(plan,'--apply',folder,txn,seen)
            if result.get('hex')!=REPLACEMENT or result.get('type')!=7: raise RuntimeError('apply readback mismatch')
            record['state']='applied';durable_write(folder,record)
        else:
            file=folder/'journal.json'
            if file.is_symlink() or not file.is_file(): raise RuntimeError('missing durable journal')
            record=json.loads(file.read_text())
            if (record.get('transaction')!=txn or record.get('prefix')!=str(reuse.PREFIX) or record.get('identity')!=identity or
                record.get('before_hex')!=ORIGINAL or record.get('after_hex')!=REPLACEMENT or record.get('type')!=7 or
                record.get('rendererHash')!=plan['rendererHash'] or record.get('engineFingerprint')!=plan['engineFingerprint']):
                raise RuntimeError('journal or bound identities mismatch')
            if current.get('hex')==REPLACEMENT:
                result=invoke(plan,'--undo',folder,txn,seen)
                if result.get('hex')!=ORIGINAL or result.get('type')!=7: raise RuntimeError('undo readback mismatch')
            elif current.get('hex')!=ORIGINAL: raise RuntimeError('value changed by another writer; no overwrite')
            record['state']='rolled_back';durable_write(folder,record)
    finally:
        if prefix_identity()==identity:
            base.bounded_shutdown(plan['server'],env,str(reuse.RUN),shutdown)
        else: shutdown['shutdown']['scope']={'error':'prefix identity changed'}
        print(json.dumps({'transaction':txn,'journal':str(folder/'journal.json'),'shutdown':shutdown['shutdown']},sort_keys=True),flush=True)
    return 0 if all(shutdown['shutdown'].get(k,{}).get('exit')==0 for k in ('-k','-w')) else 1

if __name__=='__main__': sys.exit(main())
