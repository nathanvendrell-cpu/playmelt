#!/usr/bin/env python3
"""Review before use. --run boots private Wine and starts Spider-Man 2.

Uses a new prefix, never the existing DX11 or D3DMetal prefixes. No operation
occurs on import or without --run. The receipt can report unknown: Wine may
launch descendants that do not retain the marker or cannot be inspected.
"""
import ctypes
import errno
import hashlib
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import tempfile
import time
import uuid

from m3_private_supervisor_policy import PrivateScope

PROJECT = Path(__file__).resolve().parent.parent
PRODUCTS = PROJECT / 'Products.noindex'
PLAN_HELPER = PRODUCTS / 'm3-private-plan'
HOME = Path.home()
GAME_DIR = HOME / 'Library/Application Support/Playmelt/Games/MarvelsSpiderMan2'
GAME = GAME_DIR / 'Spider-Man2.exe'
MAX_LOG = 8 * 1024 * 1024
EXIT_DRAIN_SECONDS = 0.3

class BSDInfo(ctypes.Structure):
    _fields_ = [(n, ctypes.c_uint32) for n in ('flags','status','xstatus','pid','ppid','uid','gid','ruid','rgid','svuid','svgid','reserved')] + [
        ('comm',ctypes.c_char*16),('name',ctypes.c_char*32)] + [(n,ctypes.c_uint32) for n in ('nfiles','pgid','pjobc','tdev','tpgid')] + [('nice',ctypes.c_int32),('start_sec',ctypes.c_uint64),('start_usec',ctypes.c_uint64)]

class Inspector:
    """macOS libproc + KERN_PROCARGS2. Never logs unrelated environments."""
    def __init__(self):
        self.lib = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
        self.lib.proc_listpids.argtypes = [ctypes.c_uint32,ctypes.c_uint32,ctypes.c_void_p,ctypes.c_int]
        self.lib.proc_pidinfo.argtypes = [ctypes.c_int,ctypes.c_int,ctypes.c_uint64,ctypes.c_void_p,ctypes.c_int]
        self.lib.proc_pidpath.argtypes = [ctypes.c_int,ctypes.c_void_p,ctypes.c_uint32]
        self.lib.sysctl.argtypes = [ctypes.POINTER(ctypes.c_int),ctypes.c_uint,ctypes.c_void_p,ctypes.POINTER(ctypes.c_size_t),ctypes.c_void_p,ctypes.c_size_t]

    def identity(self,pid):
        info=BSDInfo(); n=self.lib.proc_pidinfo(pid,3,0,ctypes.byref(info),ctypes.sizeof(info))
        if n != ctypes.sizeof(info): return None
        buf=ctypes.create_string_buffer(4096); n=self.lib.proc_pidpath(pid,buf,len(buf))
        if n <= 0: return None
        return {'pid':pid,'uid':info.uid,'start_sec':info.start_sec,'start_usec':info.start_usec,'path':os.fsdecode(buf.value),'status':info.status,'ppid':info.ppid}

    def marker(self,pid,marker,buffer=None):
        # Kernel saves argv+initial environment at exec; only exact NUL-delimited
        # marker is inspected, and bytes never enter logs or the receipt.
        buf=buffer if buffer is not None else ctypes.create_string_buffer(1024*1024)
        mib=(ctypes.c_int*3)(1,49,pid); size=ctypes.c_size_t(ctypes.sizeof(buf))
        if self.lib.sysctl(mib,3,buf,ctypes.byref(size),None,0) != 0 or size.value > ctypes.sizeof(buf): return None
        data=ctypes.string_at(buf,size.value)
        # KERN_PROCARGS2 begins with an argc integer and NUL-terminated data.
        if len(data)<=ctypes.sizeof(ctypes.c_int) or not data.endswith(b'\0'): return None
        return ('PLAYMELT_TEST_RUN='+marker).encode() in data.split(b'\0')

    def snapshot(self,marker):
        count=self.lib.proc_listpids(4,os.geteuid(),None,0)
        if count <= 0: raise RuntimeError('proc_listpids failed')
        cap=count+65536; buf=ctypes.create_string_buffer(cap)
        size=self.lib.proc_listpids(4,os.geteuid(),buf,cap)
        if size <= 0 or size>=cap or size%ctypes.sizeof(ctypes.c_int): raise RuntimeError('incomplete PID inventory')
        pids=(ctypes.c_int*(size//4)).from_buffer_copy(ctypes.string_at(buf,size)); found=[]; unknown=[]
        marker_buffer=ctypes.create_string_buffer(1024*1024)
        for pid in pids:
            if pid<=0 or pid==os.getpid(): continue
            identity=self.identity(pid)
            if identity is None:
                unknown.append({'pid':pid,'reason':'identity_unavailable_or_process_exited'})
                continue
            match=self.marker(pid,marker,marker_buffer)
            if match is True: found.append(identity)
            elif match is None and (identity['path'].startswith(str(PROJECT)) or '/playmelt-wine10-dxmt-20261017/' in identity['path'] or identity['path'].startswith(str(GAME_DIR))): unknown.append(identity)
        return found,unknown

def identity_key(item):
    return (item['pid'],item['uid'],item['start_sec'],item['start_usec'],item['path'])

def valid_executable(path):
    if path.is_symlink() or not path.is_file(): return False
    with path.open('rb') as f: return f.read(2)==b'MZ'

def game_command(wine, game):
    return [wine, 'explorer', '/desktop=PlaymeltSpiderManTest,1280x720', str(game)]

def write_receipt(root, receipt):
    temporary=root/'receipt.json.tmp'
    temporary.write_text(json.dumps(receipt,indent=2,sort_keys=True)+'\n')
    os.replace(temporary,root/'receipt.json')

def announce_run(root, receipt):
    print(str(root), flush=True)
    write_receipt(root,receipt)

def run_command(argv,env,directory,log,timeout,inspector,marker,seen):
    """Launch in its own session, stream a capped log, drain all excess output."""
    p=subprocess.Popen(argv,cwd=directory,env=env,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,start_new_session=True)
    try: first=inspector.identity(p.pid)
    except Exception: first=None
    if first: seen[identity_key(first)]=first
    else: seen['_inspection_unknown']=True
    selector=selectors.DefaultSelector(); selector.register(p.stdout,selectors.EVENT_READ)
    deadline=time.monotonic()+timeout; next_scan=0; limited=False; written=0; timed_out=False
    def drain(wait):
        nonlocal written,limited
        for key,_ in selector.select(timeout=wait):
            chunk=os.read(key.fd,65536)
            if not chunk: selector.unregister(key.fileobj)
            else:
                available=max(0,MAX_LOG-written)
                if available: log.write(chunk[:available]); log.flush(); written+=min(len(chunk),available)
                if len(chunk)>available: limited=True
    try:
        while True:
            now=time.monotonic()
            if now>=next_scan:
                try:
                    marked,unknown=inspector.snapshot(marker)
                    for item in marked: seen[identity_key(item)]=item
                    if unknown: seen['_inspection_unknown']=True
                except Exception: seen['_inspection_unknown']=True
                next_scan=now+2
            drain(0.1)
            if p.poll() is not None:
                drain_deadline=time.monotonic()+EXIT_DRAIN_SECONDS
                while selector.get_map():
                    remaining=drain_deadline-time.monotonic()
                    if remaining<=0: break
                    drain(min(0.05,remaining))
                break
            if now>=deadline: timed_out=True; break
        return p, timed_out, limited
    except BaseException:
        reap_child(p)
        raise
    finally:
        selector.close()

def bounded_shutdown(server,env,directory,receipt):
    """Only the unique new prefix is passed; never infer ownership from age."""
    for arg in ('-k','-w'):
        try:
            r=subprocess.run([server,arg],env=env,cwd=directory,stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=10,check=False,start_new_session=True)
            receipt['shutdown'][arg]={'exit':r.returncode}
        except Exception as e: receipt['shutdown'][arg]={'error':type(e).__name__}

def reap_child(p):
    if p is None: return
    if p.poll() is None:
        # The Popen child has not been waited/reaped, preventing PID reuse.
        try: os.killpg(p.pid,signal.SIGTERM)
        except (ProcessLookupError, PermissionError): pass
        try: p.wait(timeout=3)
        except subprocess.TimeoutExpired:
            try: os.killpg(p.pid,signal.SIGKILL)
            except (ProcessLookupError, PermissionError): pass
    try: p.wait(timeout=3)
    except subprocess.TimeoutExpired: pass
    if p.stdout: p.stdout.close()

def main():
    if sys.argv != [sys.argv[0],'--run']:
        print('Review required: this tool only acts with --run.',file=sys.stderr); return 64
    if sys.platform!='darwin': raise RuntimeError('macOS only')
    if GAME_DIR.is_symlink() or GAME_DIR.resolve()!=GAME_DIR or not valid_executable(GAME): raise RuntimeError('expected game path/MZ invalid')
    entries=[p.name for p in GAME_DIR.iterdir() if p.name.lower()=='spider-man2.exe']
    if entries != ['Spider-Man2.exe'] or (GAME_DIR/'Windows').exists(): raise RuntimeError('ambiguous game layout')
    if PRODUCTS.is_symlink() or not PRODUCTS.is_dir() or PRODUCTS.resolve()!=PRODUCTS: raise RuntimeError('invalid Products.noindex')
    plan=json.loads(subprocess.run([str(PLAN_HELPER)],capture_output=True,check=True,timeout=90).stdout)
    wine=plan['wine']; server=plan['server']; engine=str(Path(wine).parent.parent)
    if server!=str(Path(engine)/'bin/wineserver') or not os.access(wine,os.X_OK) or not os.access(server,os.X_OK): raise RuntimeError('engine mismatch')
    run_id=str(uuid.uuid4()); root=Path(tempfile.mkdtemp(prefix='m3-wine-'+run_id+'-',dir=PRODUCTS))
    receipt={'run_id':run_id,'prefix':str(root/'prefix'),'status':'allocated','shutdown':{},'stages':{},'inspection':'unknown'}
    announce_run(root,receipt)
    scope=PrivateScope(run_id,os.geteuid(),str(root),str(root/'prefix'),engine); scope.validate(str(PRODUCTS))
    (root/'home').mkdir(mode=0o700); (root/'prefix').mkdir(mode=0o700)
    root_stat=os.lstat(root); prefix_stat=os.lstat(root/'prefix')
    def scope_safe():
        try:
            a=os.lstat(root); b=os.lstat(root/'prefix')
            return (not root.is_symlink() and not (root/'prefix').is_symlink() and
                    (a.st_dev,a.st_ino,a.st_uid)==(root_stat.st_dev,root_stat.st_ino,os.geteuid()) and
                    (b.st_dev,b.st_ino,b.st_uid)==(prefix_stat.st_dev,prefix_stat.st_ino,os.geteuid()))
        except OSError: return False
    env=scope.environment(plan['environment']); env['WINEDLLOVERRIDES']='d3d12,d3d12core,dxgi=n,b;winemenubuilder.exe=d'; env['MVK_CONFIG_LOG_LEVEL']='0'
    receipt.update(wine=wine,rendererHash=plan['rendererHash'],engineFingerprint=plan['engineFingerprint'],limitations=['Private prefix does not include Steam or existing game configuration.','A marker-based inventory can miss processes which remove their marker or cannot be inspected.','No assertion of Playmelt UI launch or game success.'])
    write_receipt(root,receipt)
    inspector=Inspector(); seen={}; child=None
    def interrupt(signum, frame):
        raise KeyboardInterrupt('signal '+str(signum))
    old_handlers={sig:signal.signal(sig,interrupt) for sig in (signal.SIGINT,signal.SIGTERM)}
    try:
        before,before_unknown=inspector.snapshot(run_id)
        receipt['baseline']={'marked':before,'unknown':before_unknown}
        if before: raise RuntimeError('unexpected marked process before launch')
        if before_unknown: seen['_inspection_unknown']=True
        receipt['status']='boot_running'; write_receipt(root,receipt)
        with (root/'boot.log').open('xb',buffering=0) as log:
            bootenv=dict(env); bootenv['WINEBOOT_HIDE_DIALOG']='1'
            bootenv['WINEDLLOVERRIDES']='winemenubuilder.exe=d'
            child,timed,limited=run_command([wine,'wineboot','-u'],bootenv,str(root),log,180,inspector,run_id,seen)
            receipt['stages']['boot']={'timeout':timed,'log_capped':limited,'exit':child.poll()}
        receipt['status']='boot_stopping'; write_receipt(root,receipt)
        if not scope_safe(): raise RuntimeError('private scope identity changed')
        bounded_shutdown(server,env,str(root),receipt); reap_child(child); child=None
        if timed or receipt['stages']['boot']['exit'] != 0 or any(v.get('exit')!=0 for v in receipt['shutdown'].values()): raise RuntimeError('private boot did not complete cleanly')
        receipt['shutdown']={}
        receipt['status']='game_running'; write_receipt(root,receipt)
        with (root/'game.log').open('xb',buffering=0) as log:
            child,timed,limited=run_command(game_command(wine, GAME),env,str(GAME_DIR),log,120,inspector,run_id,seen)
            receipt['stages']['game']={'timeout':timed,'log_capped':limited,'exit':child.poll()}
        receipt['status']='game_stopping'; write_receipt(root,receipt)
    except BaseException as exc:
        receipt['error']=type(exc).__name__+': '+str(exc)
    finally:
        for sig in old_handlers: signal.signal(sig,signal.SIG_IGN)
        # Only our new prefix. Always attempt both actions, even on errors.
        if scope_safe(): bounded_shutdown(server,env,str(root),receipt)
        else: receipt['shutdown']['scope']={'error':'private scope identity changed'}
        reap_child(child)
        try:
            marked,unknown=inspector.snapshot(run_id)
            for item in marked: seen[identity_key(item)]=item
            receipt['remaining_marked']=marked; receipt['unknown_processes']=unknown
            receipt['inspection']='unknown' if unknown or seen.get('_inspection_unknown') else ('remaining' if marked else 'no_marked_processes')
        except Exception as exc: receipt['inspection']='unknown'; receipt['inspection_error']=type(exc).__name__
        receipt['observed_processes']=[v for k,v in seen.items() if k!='_inspection_unknown']
        receipt['status']='finished'
        write_receipt(root,receipt)
        print(str(root/'receipt.json'),flush=True)
        for sig,handler in old_handlers.items(): signal.signal(sig,handler)
    game=receipt['stages'].get('game',{})
    return 0 if ('error' not in receipt and game.get('exit')==0 and not game.get('timeout',True) and
                 receipt['inspection']=='no_marked_processes' and all(v.get('exit')==0 for v in receipt['shutdown'].values())) else 1

if __name__=='__main__': sys.exit(main())
