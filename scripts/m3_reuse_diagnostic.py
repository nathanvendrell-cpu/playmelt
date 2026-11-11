#!/usr/bin/env python3
"""Review required: --run launches the real game. Never use either shared prefix."""
import getpass
import json
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import sys
import threading
import time
import uuid

import m3_private_supervisor as base

RUN = base.PRODUCTS/'m3-wine-diagnostic'
PREFIX = RUN/'prefix'
LSOF = '/usr/sbin/lsof'
SAMPLE = '/usr/bin/sample'
VMMAP = '/usr/bin/vmmap'
MAX_CAPTURE = 4*1024*1024


def same_identity(a,b):
    return a is not None and b is not None and base.identity_key(a)==base.identity_key(b) and a['uid']==os.geteuid()


def capture(argv,output,timeout=8):
    """No shell. Bound duration and output; always wait for our process."""
    env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','LC_ALL':'C'}
    process=subprocess.Popen(argv,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env=env,start_new_session=True)
    sel=selectors.DefaultSelector(); total=0; capped=False; timeout_hit=False
    try:
        sel.register(process.stdout,selectors.EVENT_READ)
        deadline=time.monotonic()+timeout
        with output.open('xb',buffering=0) as f:
            while True:
                left=deadline-time.monotonic()
                if left<=0: timeout_hit=True; break
                for key,_ in sel.select(min(left,0.1)):
                    data=os.read(key.fd,65536)
                    if not data: sel.unregister(key.fileobj)
                    else:
                        keep=max(0,MAX_CAPTURE-total)
                        if keep: f.write(data[:keep]); total+=min(len(data),keep)
                        if len(data)>keep: capped=True
                if process.poll() is not None:
                    until=time.monotonic()+0.3
                    while sel.get_map() and time.monotonic()<until:
                        for key,_ in sel.select(min(0.05,max(0,until-time.monotonic()))):
                            data=os.read(key.fd,65536)
                            if not data: sel.unregister(key.fileobj)
                            else:
                                keep=max(0,MAX_CAPTURE-total)
                                if keep: f.write(data[:keep]); total+=min(len(data),keep)
                                if len(data)>keep: capped=True
                    break
        return {'exit':process.poll(),'timeout':timeout_hit,'capped':capped,'bytes':total}
    finally:
        sel.close(); base.reap_child(process)


def find_game(inspector,marker,wine,game_path,query):
    """Require a unique intersection of run-marked Wine PIDs and mapped game EXE."""
    marked,unknown=inspector.snapshot(marker)
    candidates={p['pid']:p for p in marked if p['path']==wine and p['uid']==os.geteuid()}
    pids=query(game_path)
    matches=[v for k,v in candidates.items() if k in pids]
    if len(matches)!=1: return None,{'reason':'game_pid_not_unique','matches':len(matches),'inspection_unknown':len(unknown)}
    item=matches[0]
    if not same_identity(item,inspector.identity(item['pid'])): return None,{'reason':'identity_changed'}
    return item,{'inspection_unknown':len(unknown)}


def query_game_pids(path):
    r=subprocess.run([LSOF,'-t',str(path)],stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=5,check=False,env={'PATH':'/usr/bin:/bin','LC_ALL':'C'})
    if r.returncode not in (0,1) or r.stderr: raise RuntimeError('lsof game query incomplete')
    if r.returncode==1 and r.stdout: raise RuntimeError('lsof inconsistent result')
    return {int(line) for line in r.stdout.splitlines() if line.isdigit()}


def require_idle_prefix(prefix):
    r=subprocess.run([LSOF,'-t','+D',str(prefix)],stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=25,check=False,env={'PATH':'/usr/bin:/bin','LC_ALL':'C'})
    if r.returncode!=1 or r.stdout or r.stderr: raise RuntimeError('private prefix busy or lsof inventory incomplete')


def collect(inspector,marker,wine,game_path,root,started,done,records):
    for offset in (10,25,45):
        if done.wait(max(0,started+offset-time.monotonic())): return
        item=None; result={'offset_seconds':offset,'at_monotonic':time.monotonic(),'captures':{}}
        try:
            item,detail=find_game(inspector,marker,wine,game_path,query_game_pids); result.update(detail)
            if item is None: records.append(result); continue
            result['identity']=item
            for name,argv in [('sample',[SAMPLE,str(item['pid']),'2']),('vmmap',[VMMAP,str(item['pid'])]),('lsof',[LSOF,'-nP','-p',str(item['pid'])])]:
                if done.is_set(): result['captures'][name]={'error':'run_ended'}; break
                if not same_identity(item,inspector.identity(item['pid'])):
                    result['captures'][name]={'error':'identity_changed_before'}; break
                try:
                    result['captures'][name]=capture(argv,root/('%02d-%s.txt'%(offset,name)))
                    result['captures'][name]['identity_unchanged_after']=same_identity(item,inspector.identity(item['pid']))
                except Exception as e: result['captures'][name]={'error':type(e).__name__+': '+str(e)}
        except Exception as e: result['error']=type(e).__name__+': '+str(e)
        records.append(result)
        base.write_receipt(root,{'status':'running','samples':records,'inspection':'unknown'})


def main():
    if sys.argv != [sys.argv[0],'--run']: print('Review required; no action without --run.',file=sys.stderr); return 64
    if sys.platform!='darwin': raise RuntimeError('macOS only')
    if RUN.is_symlink() or RUN.resolve()!=RUN or PREFIX.is_symlink() or not PREFIX.is_dir(): raise RuntimeError('private prefix path invalid')
    receipt=json.loads((RUN/'receipt.json').read_text())
    if receipt.get('status')!='finished' or receipt.get('prefix')!=str(PREFIX) or receipt.get('remaining_marked')!=[] or receipt.get('stages',{}).get('boot',{}).get('exit')!=0 or any(receipt.get('shutdown',{}).get(k,{}).get('exit')!=0 for k in ('-k','-w')): raise RuntimeError('previous private run not properly closed')
    if not base.valid_executable(base.GAME) or base.GAME_DIR.resolve()!=base.GAME_DIR: raise RuntimeError('game path invalid')
    entries=[p.name for p in base.GAME_DIR.iterdir() if p.name.lower()=='spider-man2.exe']
    if entries!=['Spider-Man2.exe']: raise RuntimeError('ambiguous game executable')
    plan=json.loads(subprocess.run([str(base.PLAN_HELPER)],capture_output=True,check=True,timeout=90).stdout)
    if plan['rendererHash']!=receipt['rendererHash'] or plan['engineFingerprint']!=receipt['engineFingerprint'] or plan['wine']!=receipt['wine']: raise RuntimeError('engine/renderer changed')
    wine=plan['wine']; server=plan['server']; engine=str(Path(wine).parent.parent)
    if server!=str(Path(engine)/'bin/wineserver'): raise RuntimeError('server mismatch')
    require_idle_prefix(PREFIX)
    ident_root=os.lstat(RUN); ident_prefix=os.lstat(PREFIX)
    def scope_safe():
        try:
            a=os.lstat(RUN); b=os.lstat(PREFIX)
            return not RUN.is_symlink() and not PREFIX.is_symlink() and (a.st_dev,a.st_ino,a.st_uid)==(ident_root.st_dev,ident_root.st_ino,os.geteuid()) and (b.st_dev,b.st_ino,b.st_uid)==(ident_prefix.st_dev,ident_prefix.st_ino,os.geteuid())
        except OSError: return False
    marker=str(uuid.uuid4()); out=RUN/('diagnostic-'+marker); out.mkdir(mode=0o700)
    print(str(out),flush=True)
    state={'status':'allocated','previous_run':receipt['run_id'],'prefix':str(PREFIX),'marker':marker,'inspection':'unknown','samples':[],'shutdown':{},'limitations':['No rendered image is asserted.','Identification depends on the marked process retaining its executable mapping and marker.','Private prefix has no prior Steam session.']}
    base.write_receipt(out,state)
    oldlog=PREFIX/'drive_c/users'/getpass.getuser()/"Documents/Marvel's Spider-Man 2/Marvel's Spider-Man 2.log"
    if oldlog.is_file() and not oldlog.is_symlink():
        if oldlog.stat().st_size>2*1024*1024: raise RuntimeError('old game log too large to preserve automatically')
        shutil.copyfile(oldlog,out/'previous-game.log')
    env=dict(plan['environment']); env.update(WINEPREFIX=str(PREFIX),HOME=str(RUN/'home'),PLAYMELT_TEST_RUN=marker,ROSETTA_ADVERTISE_AVX='1',WINEDEBUG='fixme-all,+loaddll',WINEDLLOVERRIDES='d3d12,d3d12core,dxgi=n,b;winemenubuilder.exe=d',MVK_CONFIG_LOG_LEVEL='0')
    inspector=base.Inspector(); seen={}; done=threading.Event(); records=[]; child=None; thread=None
    def on_interrupt(signum, frame): raise KeyboardInterrupt('signal '+str(signum))
    import signal
    old_handlers={sig:signal.signal(sig,on_interrupt) for sig in (signal.SIGINT,signal.SIGTERM)}
    try:
        before,unknown=inspector.snapshot(marker)
        if before: raise RuntimeError('marker unexpectedly already active')
        if unknown: seen['_inspection_unknown']=True
        state['status']='game_running'; base.write_receipt(out,state)
        started=time.monotonic()
        thread=threading.Thread(target=collect,args=(base.Inspector(),marker,wine,base.GAME,out,started,done,records),daemon=False)
        thread.start()
        with (out/'game-loaddll.log').open('xb',buffering=0) as log:
            child,timed,capped=base.run_command(base.game_command(wine,base.GAME),env,str(base.GAME_DIR),log,120,inspector,marker,seen)
        state['game']={'timeout':timed,'exit':child.poll(),'log_capped':capped}
    except BaseException as e: state['error']=type(e).__name__+': '+str(e)
    finally:
        for sig in old_handlers: signal.signal(sig,signal.SIG_IGN)
        done.set()
        if thread: thread.join(timeout=35)
        if thread and thread.is_alive(): state['error']='diagnostic worker failed to stop; cleanup state unknown'
        if scope_safe(): base.bounded_shutdown(server,env,str(RUN),state)
        else: state['shutdown']['scope']={'error':'private prefix identity changed'}
        base.reap_child(child)
        try:
            marked,unknown=inspector.snapshot(marker)
            state['remaining_marked']=marked; state['unknown_processes']=unknown
            state['inspection']='unknown' if unknown or seen.get('_inspection_unknown') or (thread and thread.is_alive()) else ('remaining' if marked else 'no_marked_processes')
        except Exception as e: state['inspection']='unknown'; state['inspection_error']=type(e).__name__
        state['observed_processes']=[v for k,v in seen.items() if k!='_inspection_unknown']; state['samples']=records; state['status']='finished'
        base.write_receipt(out,state); print(str(out/'receipt.json'),flush=True)
        for sig,handler in old_handlers.items(): signal.signal(sig,handler)
    game=state.get('game',{})
    clean=all(state['shutdown'].get(k,{}).get('exit')==0 for k in ('-k','-w'))
    return 0 if (not state.get('error') and state['inspection']=='no_marked_processes' and clean and
                 game.get('exit')==0 and not game.get('timeout',True)) else 1

if __name__=='__main__': sys.exit(main())
