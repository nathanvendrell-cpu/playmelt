#!/usr/bin/env python3
"""REVIEW BEFORE --run: real one-value private-prefix A/B experiment.

Only existing virtual HardwareID is temporarily mirrored to the observed DXGI
compatibility identity. Never edits the game, PCI instance key or capabilities.
Abrupt termination can leave a prepared/applied journal: use reviewed --undo.
"""
import getpass
import hashlib
import errno
import json
import os
from pathlib import Path
import shutil
import signal
import sys
import uuid

import gpu_hardwareid_transaction as tx
import m3_private_supervisor as base
import m3_reuse_diagnostic as reuse

PROBE=base.PRODUCTS/'setupapi-identity-probe.exe'
PROBE_SHA='2335d6dac2d29b55ae6fab78efd6506412323909e209bd04e513b732daa1a62e'
INSTANCE=r'PCI\VEN_106B&DEV_03F1&SUBSYS_00000000&REV_00\00000000'


def verify_stopped(seen,inspector):
    """Never signal a PID here; distinguish gone, reused, alive and unknown."""
    result=[]
    for key,old in seen.items():
        if key=='_inspection_unknown': continue
        pid=old['pid']; current=inspector.identity(pid)
        if current is not None:
            status='alive' if base.identity_key(current)==base.identity_key(old) else 'reused'
        else:
            try: os.kill(pid,0); status='unknown'
            except ProcessLookupError: status='gone'
            except PermissionError: status='unknown'
            except OSError as e: status='gone' if e.errno==errno.ESRCH else 'unknown'
        result.append({'pid':pid,'status':status,'identity':old})
    if any(x['status'] in ('alive','unknown') for x in result):
        raise RuntimeError('at least one observed process is still active or unidentifiable')
    return result


def require_observed(probe,expected,nonce):
    if probe.get('schema')!=1 or probe.get('kind')!='playmelt-setupapi-display-probe' or probe.get('nonce')!=nonce:
        raise RuntimeError('probe schema/nonce mismatch')
    if probe.get('setupComplete') is not True or probe.get('interfacesComplete') is not True:
        raise RuntimeError('SetupAPI enumeration incomplete')
    candidates=[x for x in probe.get('setupDevices',[]) if x.get('instanceId','').upper()==INSTANCE.upper()]
    if len(candidates)!=1 or candidates[0].get('hardwareId','').upper()!=expected.upper():
        raise RuntimeError('live SetupAPI HardwareID differs from expected')


def probe(plan,folder,marker,stage,seen):
    if PROBE.is_symlink() or not PROBE.is_file() or hashlib.sha256(PROBE.read_bytes()).hexdigest()!=PROBE_SHA:
        raise RuntimeError('SetupAPI probe binary changed')
    nonce=str(uuid.uuid4()); env=tx.private_environment(plan,marker)
    output=folder/(stage+'-setupapi.json')
    with output.open('xb',buffering=0) as f:
        child,timed,capped=base.run_command([plan['wine'],str(PROBE),'--nonce',nonce],env,str(reuse.RUN),f,30,base.Inspector(),marker,seen)
    code=child.poll();base.reap_child(child)
    if timed or capped or code!=0: raise RuntimeError(stage+' probe failed or output incomplete')
    return tx.extract_record(output.read_text(),kind='setupapi',nonce=nonce),nonce


def record_for(plan,identity,txn):
    return {'schema':1,'transaction':txn,'state':'prepared','prefix':str(reuse.PREFIX),'identity':identity,'helper_sha256':tx.HELPER_SHA,
            'target':'HKLM/SYSTEM/CurrentControlSet/Enum/PCI/VEN_106B&DEV_03F1&SUBSYS_00000000&REV_00/00000000/HardwareID',
            'type':7,'before_hex':tx.ORIGINAL,'after_hex':tx.REPLACEMENT,'rendererHash':plan['rendererHash'],'engineFingerprint':plan['engineFingerprint'],
            'limitations':['Experimental identity only; no hardware capability is changed.','Instance ID remains Apple; Wine can rebuild display keys.','Abrupt termination requires reviewed durable undo.']}


def recover(plan,folder,txn,identity,seen,record):
    """Only call after game is stopped and prefix is verified idle."""
    if tx.prefix_identity()!=identity: raise RuntimeError('prefix identity changed before rollback')
    current=tx.invoke(plan,'--read',folder,txn,seen)
    if current.get('type')!=7: raise RuntimeError('rollback type changed; no overwrite')
    if current.get('hex')==tx.REPLACEMENT:
        result=tx.invoke(plan,'--undo',folder,txn,seen)
        if result.get('type')!=7 or result.get('hex')!=tx.ORIGINAL: raise RuntimeError('undo verification failed')
        record['rollback_method']='cas_undo'
    elif current.get('hex')==tx.ORIGINAL:
        record['rollback_method']='already_original_after_refresh'
    else: raise RuntimeError('value changed by another writer; no overwrite')


COPY_PREVIOUS_DIAGNOSTIC_LOG=True

def main():
    if sys.argv != [sys.argv[0],'--run']:
        print('Review required; this experiment acts only with --run.',file=sys.stderr);return 64
    if sys.platform!='darwin': raise RuntimeError('macOS only')
    plan=tx.load_plan();identity=tx.prefix_identity();reuse.require_idle_prefix(reuse.PREFIX)
    if not base.valid_executable(base.GAME) or base.GAME_DIR.resolve()!=base.GAME_DIR: raise RuntimeError('game path/MZ invalid')
    entries=[p.name for p in base.GAME_DIR.iterdir() if p.name.lower()=='spider-man2.exe']
    if entries!=['Spider-Man2.exe'] or (base.GAME_DIR/'Windows').exists(): raise RuntimeError('game layout ambiguous')
    for existing in reuse.RUN.glob('gpu-hardwareid-*/journal.json'):
        if json.loads(existing.read_text()).get('state')!='rolled_back': raise RuntimeError('unresolved prior transaction: '+str(existing))
    txn=str(uuid.uuid4());folder=reuse.RUN/('gpu-hardwareid-'+txn);folder.mkdir(mode=0o700)
    print(str(folder),flush=True)
    record=record_for(plan,identity,txn); state={'status':'allocated','transaction':txn,'prefix':str(reuse.PREFIX),'inspection':'unknown','shutdown':{},'probe':{}}
    base.write_receipt(folder,state)
    oldlog=reuse.PREFIX/'drive_c/users'/getpass.getuser()/"Documents/Marvel's Spider-Man 2/Marvel's Spider-Man 2.log"
    if COPY_PREVIOUS_DIAGNOSTIC_LOG and oldlog.is_file() and not oldlog.is_symlink():
        if oldlog.stat().st_size>2*1024*1024: raise RuntimeError('previous game log too large')
        shutil.copyfile(oldlog,folder/'previous-game.log')
    env=tx.private_environment(plan,txn,debug='fixme-all,+msgbox,+dialog')
    seen={}; game=None; journal_prepared=False; write_attempted=False
    def interrupt(signum,frame): raise KeyboardInterrupt('signal '+str(signum))
    handlers={sig:signal.signal(sig,interrupt) for sig in (signal.SIGINT,signal.SIGTERM)}
    try:
        before,nonce=probe(plan,folder,txn,'before',seen);require_observed(before,tx.APPLE,nonce);state['probe']['before']='apple_observed'
        original=tx.invoke(plan,'--read',folder,txn,seen)
        if original.get('type')!=7 or original.get('hex')!=tx.ORIGINAL: raise RuntimeError('original raw type/value changed')
        if tx.prefix_identity()!=identity: raise RuntimeError('prefix identity changed')
        tx.durable_write(folder,record);journal_prepared=True
        state['status']='journal_prepared';base.write_receipt(folder,state)
        write_attempted=True
        applied=tx.invoke(plan,'--apply',folder,txn,seen)
        if applied.get('type')!=7 or applied.get('hex')!=tx.REPLACEMENT: raise RuntimeError('apply readback mismatch')
        record['state']='applied';tx.durable_write(folder,record)
        state['status']='refresh_probe';base.write_receipt(folder,state)
        after,nonce=probe(plan,folder,txn,'after',seen)
        try: require_observed(after,tx.AMD,nonce)
        except RuntimeError:
            state['probe']['after']='not_expected_after_refresh';raise
        refreshed=tx.invoke(plan,'--read',folder,txn,seen)
        if refreshed.get('type')!=7 or refreshed.get('hex')!=tx.REPLACEMENT: raise RuntimeError('HardwareID overwritten by display refresh')
        state['probe']['after']='compatibility_id_observed';state['status']='game_running';base.write_receipt(folder,state)
        with (folder/'game.log').open('xb',buffering=0) as log:
            game,timed,capped=base.run_command([plan['wine'],str(base.GAME)],env,str(base.GAME_DIR),log,120,base.Inspector(),txn,seen)
        state['game']={'exit':game.poll(),'timeout':timed,'log_capped':capped}
    except BaseException as e: state['error']=type(e).__name__+': '+str(e)
    finally:
        for sig in handlers:signal.signal(sig,signal.SIG_IGN)
        try:
            if tx.prefix_identity()!=identity: raise RuntimeError('prefix identity changed')
            base.bounded_shutdown(plan['server'],env,str(reuse.RUN),state)
        except BaseException as e: state['shutdown']['scope']={'error':type(e).__name__+': '+str(e)}
        try: base.reap_child(game)
        except BaseException as e: state['reap_error']=type(e).__name__+': '+str(e)
        if journal_prepared and write_attempted:
            state['status']='rollback';base.write_receipt(folder,state)
            try:
                if any(state['shutdown'].get(k,{}).get('exit')!=0 for k in ('-k','-w')): raise RuntimeError('game server shutdown unverified')
                state['processes_after_game']=verify_stopped(seen,base.Inspector())
                reuse.require_idle_prefix(reuse.PREFIX)
                rollback_shutdown={'shutdown':{}}
                try:
                    recover(plan,folder,txn,identity,seen,record)
                finally:
                    if tx.prefix_identity()==identity: base.bounded_shutdown(plan['server'],env,str(reuse.RUN),rollback_shutdown)
                    else: rollback_shutdown['shutdown']['scope']={'error':'prefix identity changed'}
                    state['rollback_shutdown']=rollback_shutdown['shutdown']
                state['rollback_shutdown']=rollback_shutdown['shutdown']
                if any(rollback_shutdown['shutdown'].get(k,{}).get('exit')!=0 for k in ('-k','-w')): raise RuntimeError('rollback server shutdown unverified')
                reuse.require_idle_prefix(reuse.PREFIX)
                state['processes_after_rollback']=verify_stopped(seen,base.Inspector())
                record['state']='rolled_back';tx.durable_write(folder,record);state['rollback']='verified_readback_and_shutdown'
            except BaseException as e: state['rollback']='unknown_or_deferred';state['rollback_error']=type(e).__name__+': '+str(e)
        else: state['rollback']='not_needed_no_write'
        state['status']='finished';state['observed_processes']=[v for k,v in seen.items() if k!='_inspection_unknown']
        state['inspection']='unknown' if seen.get('_inspection_unknown') else 'not_independently_verified'
        base.write_receipt(folder,state);print(str(folder/'receipt.json'),flush=True)
        for sig,handler in handlers.items():signal.signal(sig,handler)
    game_result=state.get('game',{})
    return 0 if (not state.get('error') and not state.get('reap_error') and state.get('rollback')=='verified_readback_and_shutdown' and
                 game_result.get('exit')==0 and not game_result.get('timeout',True)) else 1

if __name__=='__main__': sys.exit(main())
