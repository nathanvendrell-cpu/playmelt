#!/usr/bin/env python3
"""Persistent, isolated Spider-Man 2 compatibility profile; user launch only.

Uses the reviewed HardwareID CAS experiment inside an exclusive per-game
prefix. Saves are never packaged or overwritten. No global Wine settings.
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import signal
import stat
import subprocess
import sys
import time
import unicodedata
import uuid

import m3_private_supervisor as base
import m3_reuse_diagnostic as reuse
import gpu_hardwareid_transaction as tx
import m3_hardwareid_experiment as experiment

RESOURCES=Path(__file__).resolve().parent
HOME=Path.home()
PROFILE=HOME/'Library/Application Support/Playmelt/Runtime/D3DMetal/Games/2651280'
PREFIX=PROFILE/'prefix'
GAME_DIR=HOME/'Library/Application Support/Playmelt/Games/MarvelsSpiderMan2'
GAME=GAME_DIR/'Spider-Man2.exe'
RETINA=RESOURCES/'spiderman-retina-default.exe'
SETTINGS=RESOURCES/'spiderman-profile-settings.exe'
GRAPHICS_NAMES=('Fullscreen','ExclusiveFullscreen','FullscreenWidth','FullscreenHeight','WindowLeft','WindowTop','WindowWidth','WindowHeight','UserWindowWidth','UserWindowHeight','DynamicResolutionTargetFPS','UpscaleMethod','UpscaleQuality','RefreshRate')
ROOT_NAMES=('FirstRun','englishVO','TextLanguage','ShowLauncher')
MAC_NAMES=('RetinaMode','CaptureDisplaysForFullscreen')
GAME_SETTINGS=HOME/'Library/Application Support/Playmelt/GameSettings/steam-2651280-windows.json'


def atomic_json(path,value):
    data=(json.dumps(value,indent=2,sort_keys=True)+'\n').encode()
    tmp=path.parent/(path.name+'.'+str(uuid.uuid4())+'.tmp')
    fd=os.open(tmp,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'wb') as f:f.write(data);f.flush();os.fsync(f.fileno())
    os.replace(tmp,path)
    fd=os.open(path.parent,os.O_RDONLY)
    try:os.fsync(fd)
    finally:os.close(fd)


def _object(pairs):
    result={}
    for key,value in pairs:
        if key in result:raise RuntimeError('duplicate JSON key: '+key)
        result[key]=value
    return result

def split_launch_args(text):
    # Backslashes in Windows paths remain literal except before a quote or space.
    result=[];word=[];quote=None;started=False;i=0
    while i<len(text):
        c=text[i]
        if c=='\\' and i+1<len(text) and (text[i+1] in ('"',"'",' ')):
            word.append(text[i+1]);started=True;i+=2;continue
        if c in ('"',"'"):
            if quote is None:quote=c;started=True;i+=1;continue
            if quote==c:quote=None;i+=1;continue
        if c=='\t' and quote is not None:raise RuntimeError('tab inside quoted argument')
        if c in (' ','\t') and quote is None:
            if started:result.append(''.join(word));word=[];started=False
        else:word.append(c);started=True
        i+=1
    if quote is not None:raise RuntimeError('invalid launch argument quoting')
    if started:result.append(''.join(word))
    return result

def read_preferences(path=GAME_SETTINGS):
    if path.is_symlink():raise RuntimeError('invalid game settings file')
    if not path.exists():return None
    if path.is_symlink() or not path.is_file() or path.stat().st_size>65536:raise RuntimeError('invalid game settings file')
    data=json.loads(path.read_text(),object_pairs_hook=_object,parse_constant=lambda x: (_ for _ in ()).throw(ValueError(x)))
    def fields(v,keys):
        if type(v)!=dict or set(v)!=set(keys):raise RuntimeError('invalid game settings fields')
    def integer(v,lo,hi):
        if type(v)!=int or not lo<=v<=hi:raise RuntimeError('invalid game settings integer')
    def boolean(v):
        if type(v)!=bool:raise RuntimeError('invalid game settings boolean')
    fields(data,('schemaVersion','gameKey','revision','settings','applyFields'))
    if type(data['schemaVersion'])!=int or data['schemaVersion']!=2 or data['gameKey']!='steam-2651280-windows':raise RuntimeError('invalid game settings identity')
    try:
        if type(data['revision'])!=str or str(uuid.UUID(data['revision']))!=data['revision']:raise ValueError()
    except (ValueError,AttributeError):raise RuntimeError('invalid settings revision')
    allowed={'launchArgs','backend','display.mode','display.screenID','display.width','display.height','display.refreshRate','display.retina','display.vsync','display.hdr','graphics.upscaler','graphics.quality','graphics.dynamicFPS','graphics.frameGeneration','graphics.grain','graphics.sharpness'}
    mask=data['applyFields']
    if type(mask)!=list or any(type(x)!=str or x not in allowed for x in mask) or len(mask)!=len(set(mask)):raise RuntimeError('invalid applyFields')
    s=data['settings'];fields(s,('launchArgs','backend','display','graphics'))
    if s['backend'] not in ('auto','d3dmetal'):raise RuntimeError('unsupported backend')
    args=s['launchArgs']
    if type(args)!=str or any(unicodedata.category(c) in ('Cc','Cf','Cs') and c!='\t' for c in args) or len(args.encode('utf-8'))>2048:raise RuntimeError('invalid launch arguments')
    argv=split_launch_args(args)
    if len(argv)>64 or any(len(a)>512 for a in argv):raise RuntimeError('launch argument limit exceeded')
    d=s['display']
    if type(d)!=dict:raise RuntimeError('invalid display settings')
    fields(d,('mode','width','height','refreshRate','retina','vsync','hdr','screenID'))
    screen_id=d.get('screenID','primary')
    if type(screen_id)!=str:raise RuntimeError('invalid screen ID')
    if screen_id!='primary':
        try:uuid.UUID(screen_id)
        except ValueError:raise RuntimeError('invalid screen ID')
    if d['mode'] not in ('exclusive','fullscreen','windowed') or d['retina'] not in ('auto','on','off'):raise RuntimeError('invalid display choice')
    integer(d['width'],640,7680);integer(d['height'],480,4320)
    integer(d['refreshRate'],1,1000)
    for k in ('vsync','hdr'):boolean(d[k])
    g=s['graphics'];fields(g,('upscaler','quality','dynamicFPS','frameGeneration','grain','sharpness'))
    if g['upscaler']!='fsr' or g['quality']!='quality' or type(g['dynamicFPS'])!=int or g['dynamicFPS'] not in (0,30,60):raise RuntimeError('unsupported graphics choice')
    boolean(g['frameGeneration'])
    for k in ('grain','sharpness'):
        if type(g[k]) not in (int,float) or not 0<=g[k]<=1:raise RuntimeError('invalid graphics strength')
    return data,argv if 'launchArgs' in mask else []

def apply_preferences(plan,preferences):
    # Caller holds profile lock; Wine must be stopped throughout this transaction.
    reuse.require_idle_prefix(PREFIX)
    reg=PREFIX/'user.reg';journal=PROFILE/'preferences-journal.json'
    if reg.is_symlink() or not reg.is_file():raise RuntimeError('invalid profile registry')
    if journal.is_symlink():raise RuntimeError('invalid preferences journal')
    if journal.exists():
        old=json.loads(journal.read_text())
        if old.get('state')!='committed':raise RuntimeError('unresolved preferences journal; registry preserved')
    previous=reg.read_text(encoding='utf-8'); updated=previous
    revision=preferences[0]['revision'] if preferences else None
    mask=set(preferences[0]['applyFields']) if preferences else set()
    d=preferences[0]['settings']['display'] if preferences else {}
    g=preferences[0]['settings']['graphics'] if preferences else {}
    choice=d.get('retina','auto') if 'display.retina' in mask else 'auto'
    hints=plan.get('displayHints',{});primary=hints.get('primary') if isinstance(hints,dict) else None
    displays=hints.get('displays',[]) if isinstance(hints,dict) else []
    displays=displays if isinstance(displays,list) else []
    requested=d.get('screenID','primary') if 'display.screenID' in mask else None
    fallback=False
    if requested is not None:
        matches=[x for x in displays if isinstance(x,dict) and str(x.get('id','')).lower()==requested.lower()] if requested!='primary' else []
        selected=primary if requested=='primary' else (matches[0] if len(matches)==1 else primary)
        fallback=requested!='primary' and len(matches)!=1
    else:
        graphics=r"Software\\Insomniac Games\\Marvel's Spider-Man 2\\Graphics"
        head=re.compile(r'^\['+re.escape(graphics)+r'\](?: [^\n]*)?$',re.M)
        sections=list(head.finditer(previous))
        if len(sections)>1:raise RuntimeError('duplicate graphics section')
        body=''
        if sections:
            start=sections[0].end();nxt=re.search(r'^\[',previous[start:],re.M)
            body=previous[start:start+nxt.start() if nxt else len(previous)]
        values=re.findall(r'^"Monitor"=dword:([0-9a-fA-F]{8})$',body,re.M)
        if len(values)>1:raise RuntimeError('duplicate Monitor registry value')
        current=int(values[0],16) if values else None
        matches=[x for x in displays if isinstance(x,dict) and type(x.get('wineIndex'))==int and x['wineIndex']==current] if current is not None else []
        selected=matches[0] if len(matches)==1 else primary
        fallback=len(matches)!=1
    scale=selected.get('scale') if isinstance(selected,dict) else None
    retina={'on':'Y','off':'N'}.get(choice)
    if choice=='auto' and type(scale) in (int,float) and scale in (1,2):retina='Y' if scale==2 else 'N'
    groups={}
    if retina is not None:groups[r'Software\\Wine\\Mac Driver']={'RetinaMode':'"'+retina+'"'}
    vals={}
    if 'display.mode' in mask:vals.update(Fullscreen=int(d['mode']!='windowed'),ExclusiveFullscreen=int(d['mode']=='exclusive'))
    if 'display.width' in mask:vals.update(FullscreenWidth=d['width'],WindowWidth=d['width'],UserWindowWidth=d['width'])
    if 'display.height' in mask:vals.update(FullscreenHeight=d['height'],WindowHeight=d['height'],UserWindowHeight=d['height'])
    for field,key in (('refreshRate','RefreshRate'),('vsync','VSync'),('hdr','HDR')):
        if 'display.'+field in mask:vals[key]=int(d[field])
    if 'display.screenID' in mask and isinstance(selected,dict) and type(selected.get('wineIndex'))==int and 0<=selected['wineIndex']<64:vals['Monitor']=selected['wineIndex']
    if 'graphics.upscaler' in mask:vals['UpscaleMethod']=3
    if 'graphics.quality' in mask:vals['UpscaleQuality']=3
    if 'graphics.dynamicFPS' in mask:vals['DynamicResolutionTargetFPS']=g['dynamicFPS']
    if 'graphics.frameGeneration' in mask:vals['FrameGen']=int(g['frameGeneration'])
    if 'graphics.grain' in mask:vals['FilmGrainStrength']=round(g['grain']*1000)
    if 'graphics.sharpness' in mask:vals.update(UpscaleSharpness=round(g['sharpness']*1000),Sharpness=0)
    if vals:groups[r"Software\\Insomniac Games\\Marvel's Spider-Man 2\\Graphics"]={k:'dword:%08x'%v for k,v in vals.items()}
    changes=[]
    for section,values in groups.items():
        header=re.compile(r'^\['+re.escape(section)+r'\](?: [^\n]*)?$',re.M)
        matches=list(header.finditer(updated))
        if len(matches)>1:raise RuntimeError('duplicate registry settings section: '+section)
        if not matches:
            updated=updated.rstrip('\n')+'\n\n['+section+']\n\n'
            matches=list(header.finditer(updated))
        start=matches[0].end(); nxt=re.search(r'^\[',updated[start:],re.M);end=start+nxt.start() if nxt else len(updated)
        body=updated[start:end]
        for key,newvalue in values.items():
            pattern=re.compile(r'^"'+re.escape(key)+r'"=(.*)$',re.M); found=list(pattern.finditer(body))
            if len(found)>1:raise RuntimeError('duplicate registry value: '+key)
            old=found[0].group(1) if found else None
            changes.append({'section':section,'name':key,'before':old,'after':newvalue})
            line='"'+key+'"='+newvalue
            if found:body=body[:found[0].start()]+line+body[found[0].end():]
            else:body=body.rstrip('\n')+'\n'+line+'\n\n'
        updated=updated[:start]+body+updated[end:]
    if not changes:return
    before=hashlib.sha256(previous.encode()).hexdigest();after=hashlib.sha256(updated.encode()).hexdigest()
    receipt={'schema':1,'state':'prepared','revision':revision,'beforeSHA256':before,'afterSHA256':after,'changes':changes,'screenRequested':requested,'screenSelected':selected.get('id') if isinstance(selected,dict) else None,'screenFallback':fallback}
    atomic_json(journal,receipt)
    reuse.require_idle_prefix(PREFIX)
    if reg.read_text(encoding='utf-8')!=previous:raise RuntimeError('registry changed during preferences transaction')
    temp=PREFIX/('user.reg.'+str(uuid.uuid4())+'.tmp')
    try:
        fd=os.open(temp,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
        with os.fdopen(fd,'wb') as f:f.write(updated.encode());f.flush();os.fsync(f.fileno())
        os.replace(temp,reg)
        fd=os.open(PREFIX,os.O_RDONLY)
        try:os.fsync(fd)
        finally:os.close(fd)
    finally:
        if temp.exists():temp.unlink()
    receipt['state']='committed';atomic_json(journal,receipt)

def ensure_private_dir(path):
    if path.is_symlink() or not path.is_dir() or path.resolve()!=path:
        raise RuntimeError('profile directory is missing or resolves through a link')
    s=os.lstat(path)
    if s.st_uid!=os.geteuid() or s.st_mode&0o077:
        raise RuntimeError('profile directory must be private and owned by the user')


def create_profile(plan):
    """Create only a new owned prefix; preserve partial/unknown directories."""
    parent=PROFILE.parent
    if not parent.exists():
        if parent.parent.is_symlink() or parent.parent.resolve()!=parent.parent: raise RuntimeError('invalid D3DMetal parent')
        parent.mkdir(mode=0o700)
    ensure_private_dir(parent)
    new=False
    try:PROFILE.mkdir(mode=0o700);new=True
    except FileExistsError:pass
    ensure_private_dir(PROFILE)
    lockfd=os.open(PROFILE/'profile.lock',os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW|os.O_CLOEXEC,0o600)
    info=os.fstat(lockfd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.geteuid() or info.st_nlink!=1 or info.st_mode&0o077:
        os.close(lockfd);raise RuntimeError('invalid profile lock')
    try:fcntl.flock(lockfd,fcntl.LOCK_EX|fcntl.LOCK_NB)
    except BaseException:os.close(lockfd);raise
    try:
        owner=PROFILE/'profile-owner.json'
        if not new:
            if owner.is_symlink() or not owner.is_file():raise RuntimeError('existing profile has unknown ownership')
            data=json.loads(owner.read_text())
            if data=={'owner':'playmelt-spiderman2','schema':1,'status':'staged'}:
                if set(p.name for p in PROFILE.iterdir())-{'profile.lock','profile-owner.json','resources','source-import.json'}:raise RuntimeError('staged profile contains unexpected data')
                ensure_private_dir(PROFILE/'resources');new=True
        if new:
            atomic_json(owner,{'owner':'playmelt-spiderman2','schema':1,'status':'initializing'})
            (PROFILE/'home').mkdir(mode=0o700);PREFIX.mkdir(mode=0o700)
            reuse.require_idle_prefix(PREFIX)
            env=dict(plan['environment']);env.update(WINEPREFIX=str(PREFIX),HOME=str(PROFILE/'home'),PLAYMELT_TEST_RUN=str(uuid.uuid4()),WINEBOOT_HIDE_DIALOG='1',WINEDEBUG='-all',WINEDLLOVERRIDES='winemenubuilder.exe=d')
            child=None;cleanup={'shutdown':{}}
            try:
                with (PROFILE/'boot.log').open('xb',buffering=0) as log:
                    child,timed,capped=base.run_command([plan['wine'],'wineboot','-u'],env,str(PROFILE),log,180,base.Inspector(),env['PLAYMELT_TEST_RUN'],{})
                code=child.poll()
            finally:
                base.bounded_shutdown(plan['server'],env,str(PROFILE),cleanup);base.reap_child(child)
            if timed or capped or code!=0 or any(cleanup['shutdown'].get(k,{}).get('exit')!=0 for k in ('-k','-w')):raise RuntimeError('profile boot failed; partial data preserved')
            reuse.require_idle_prefix(PREFIX)
            for name in ('system.reg','user.reg'):
                if (PREFIX/name).is_symlink() or not (PREFIX/name).is_file():raise RuntimeError('profile boot incomplete')
            atomic_json(PROFILE/'receipt.json',{'prefix':str(PREFIX),'wine':plan['wine'],'rendererHash':plan['rendererHash'],'engineFingerprint':plan['engineFingerprint']})
            atomic_json(owner,{'owner':'playmelt-spiderman2','schema':1,'status':'ready'})
        else:
            if owner.is_symlink() or not owner.is_file():raise RuntimeError('existing profile has unknown ownership')
            data=json.loads(owner.read_text())
            if data!={'owner':'playmelt-spiderman2','schema':1,'status':'ready'}:raise RuntimeError('existing profile is incomplete or unknown; data preserved')
            ensure_private_dir(PREFIX);ensure_private_dir(PROFILE/'home')
        return lockfd
    except BaseException:
        fcntl.flock(lockfd,fcntl.LOCK_UN);os.close(lockfd);raise


def digest(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda:f.read(1024*1024),b''):h.update(block)
    return h.hexdigest()

def migration_source():
    config=PROFILE/'source-import.json'
    if not os.path.lexists(config):return None
    if config.is_symlink() or not config.is_file():raise RuntimeError('invalid migration configuration')
    info=os.lstat(config)
    if info.st_uid!=os.geteuid() or info.st_mode&0o077:raise RuntimeError('migration configuration must be private')
    value=json.loads(config.read_text())
    if set(value)!={'schema','source_prefix'} or value['schema']!=1 or not isinstance(value['source_prefix'],str):raise RuntimeError('invalid migration configuration schema')
    source=Path(value['source_prefix'])
    if not source.is_absolute() or '..' in source.parts or source.is_symlink() or source.resolve()!=source or not source.is_dir():raise RuntimeError('invalid source prefix')
    if source==PREFIX or source in PREFIX.parents or PREFIX in source.parents:raise RuntimeError('source and destination prefix overlap')
    return source

def parse_settings(text):
    sections={r"Software\\Insomniac Games\\Marvel's Spider-Man 2\\Graphics":'dword',r"Software\\Insomniac Games\\Marvel's Spider-Man 2":'root',r'Software\\Wine\\Mac Driver':'mac'}
    selected={};section=None;found_sections=set()
    for raw in text.splitlines():
        if raw.startswith('[') and ']' in raw:
            name=raw[1:raw.index(']')]
            section=sections.get(name)
            if section:
                if section in found_sections:raise RuntimeError('duplicate settings section')
                found_sections.add(section)
            continue
        if not section:continue
        match=re.match(r'^"([A-Za-z0-9]+)"=(.*)$',raw)
        if not match:continue
        name,value=match.groups();allowed=GRAPHICS_NAMES if section=='dword' else ROOT_NAMES if section=='root' else MAC_NAMES
        if name not in allowed:continue
        if name in selected:raise RuntimeError('duplicate setting')
        if section in ('dword','root'):
            if not re.fullmatch(r'dword:[0-9a-fA-F]{8}',value):raise RuntimeError('invalid Graphics value/type')
            selected[name]=(section,str(int(value[6:],16)))
        else:
            if value not in ('"Y"','"N"'):raise RuntimeError('invalid macdrv value/type')
            selected[name]=(section,value[1])
    if not set(MAC_NAMES+ROOT_NAMES).issubset(selected) or not set(GRAPHICS_NAMES).intersection(selected):raise RuntimeError('validated settings missing or incomplete')
    if selected['FirstRun']!=('root','0'):raise RuntimeError('source first-run state not validated')
    return selected

def seed_settings(plan,manifest):
    marker=PROFILE/'settings-import.json'
    if marker.exists():
        if marker.is_symlink() or not marker.is_file():raise RuntimeError('settings receipt invalid')
        value=json.loads(marker.read_text())
        if value.get('schema')!=1 or value.get('complete') is not True:raise RuntimeError('settings import incomplete')
        return
    source_prefix=migration_source()
    if source_prefix is None:return
    reuse.require_idle_prefix(source_prefix)
    source=source_prefix/'user.reg'
    if source.is_symlink() or not source.is_file() or source.stat().st_size>32*1024*1024:raise RuntimeError('test registry file invalid')
    before=source.stat();text=source.read_text(encoding='utf-8');after=source.stat()
    if (before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns)!=(after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns):raise RuntimeError('test settings changed during read')
    selected=parse_settings(text)
    if SETTINGS.is_symlink() or not SETTINGS.is_file() or digest(SETTINGS)!=manifest['settings']:raise RuntimeError('settings helper identity mismatch')
    reuse.require_idle_prefix(source_prefix);reuse.require_idle_prefix(PREFIX)
    args=[]
    for name in (n for n in ROOT_NAMES+GRAPHICS_NAMES+MAC_NAMES if n in selected):
        kind,value=selected[name];args.extend((kind,name,value))
    marker_id=str(uuid.uuid4());env=tx.private_environment(plan,marker_id)
    output=PROFILE/('settings-'+marker_id+'.log');child=None;shutdown={'shutdown':{}}
    try:
        with output.open('xb',buffering=0) as log:
            child,timed,capped=base.run_command([plan['wine'],str(SETTINGS),'--import']+args,env,str(PROFILE),log,30,base.Inspector(),marker_id,{})
        code=child.poll()
    finally:
        base.bounded_shutdown(plan['server'],env,str(PROFILE),shutdown);base.reap_child(child)
    if timed or capped or code!=0 or any(shutdown['shutdown'].get(k,{}).get('exit')!=0 for k in ('-k','-w')):raise RuntimeError('settings import failed; existing data preserved')
    reuse.require_idle_prefix(PREFIX)
    records=[json.loads(line) for line in output.read_text().splitlines() if line.strip().startswith('{')]
    if len(records)!=1 or records[0].get('ok') is not True or records[0].get('created',-1)+records[0].get('preserved',-1)!=len(selected):raise RuntimeError('settings import result invalid')
    atomic_json(marker,{'schema':1,'complete':True,'selected':selected,'result':records[0]})


def seed_saves():
    """Import current save files once; never overwrite a save or partial copy."""
    marker=PROFILE/'save-import.json'
    if marker.exists():
        if marker.is_symlink() or not marker.is_file():raise RuntimeError('save import receipt invalid')
        obj=json.loads(marker.read_text())
        if obj.get('schema')!=1 or obj.get('complete') is not True:raise RuntimeError('save import incomplete')
        return
    source_prefix=migration_source()
    if source_prefix is None:return
    reuse.require_idle_prefix(source_prefix)
    source_users=source_prefix/'drive_c/users'
    if source_users.is_symlink() or not source_users.is_dir() or source_users.resolve()!=source_users:raise RuntimeError('invalid source users directory')
    source_candidates=[]
    for user in source_users.iterdir():
        if user.is_symlink() or not user.is_dir():continue
        candidate=user/"Documents/Marvel's Spider-Man 2"
        if candidate.is_dir() and not candidate.is_symlink() and candidate.resolve()==candidate:source_candidates.append(candidate)
    if len(source_candidates)!=1:raise RuntimeError('source save user ambiguous or missing')
    source=source_candidates[0]
    candidates=[p for p in source.iterdir() if p.is_dir() and not p.is_symlink() and p.name.isdecimal() and (p/'prefs-autosave.save').is_file() and not (p/'prefs-autosave.save').is_symlink()]
    if len(candidates)!=1:raise RuntimeError('validated save account ambiguous or missing')
    account=candidates[0]
    saves=[]
    for item in account.rglob('*'):
        if item.is_symlink():raise RuntimeError('symbolic link in source save account')
        if item.is_file() and item.suffix.lower()=='.save':
            if item.resolve()!=item or not item.is_relative_to(account):raise RuntimeError('source save escapes its account')
            saves.append(item)
    if not saves or len(saves)>1024:raise RuntimeError('unexpected save count')
    users=PREFIX/'drive_c/users'; accounts=[p for p in users.iterdir() if p.is_dir() and not p.is_symlink() and p.name.lower() not in ('public','default','default user','all users')]
    if len(accounts)!=1:raise RuntimeError('profile user ambiguous')
    target=accounts[0]/"Documents/Marvel's Spider-Man 2"/account.name
    def safe_directory(path):
        if not path.is_relative_to(PREFIX):raise RuntimeError('destination outside profile')
        current=PREFIX
        for part in path.relative_to(PREFIX).parts:
            current=current/part
            if os.path.lexists(current):
                if current.is_symlink() or not current.is_dir():raise RuntimeError('unsafe destination ancestor')
            else:current.mkdir(mode=0o700)
            if current.resolve()!=current:raise RuntimeError('destination path resolves through a link')
    safe_directory(target)
    hashes={}
    for src in sorted(saves):
        rel=src.relative_to(account);dst=target/rel;safe_directory(dst.parent)
        if src.stat().st_size>64*1024*1024:raise RuntimeError('unexpected save size')
        expected=digest(src)
        if dst.exists():
            if dst.is_symlink() or not dst.is_file() or digest(dst)!=expected:raise RuntimeError('existing save differs; preserved')
        else:
            with src.open('rb') as s, dst.open('xb') as t:
                shutil.copyfileobj(s,t,1024*1024);t.flush();os.fsync(t.fileno())
            if digest(dst)!=expected or digest(src)!=expected:raise RuntimeError('save copy or source stability verification failed')
        hashes[str(rel)]=expected
    reuse.require_idle_prefix(source_prefix)
    if any(digest(account/rel)!=value for rel,value in hashes.items()):raise RuntimeError('source saves changed during import')
    atomic_json(marker,{'schema':1,'complete':True,'account':account.name,'sha256':hashes})


def crash_snapshot():
    root=PREFIX/'drive_c/users'; result={}
    if not root.exists():return result
    for pattern in ("*/Documents/Marvel's Spider-Man 2/**/*", "*/AppData/Roaming/Insomniac Games/Marvel's Spider-Man 2/crs/reports/*"):
        for p in root.glob(pattern):
            if p.is_file() and not p.is_symlink() and (p.suffix.lower() in ('.mdmp','.dmp') or p.name=="Marvel's Spider-Man 2.log"):
                s=p.stat()
                with p.open('rb') as f: head=hashlib.sha256(f.read(min(s.st_size,4096))).hexdigest()
                result[str(p)]=(s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,head)
    return result


def new_crash(before,after):
    for path,meta in after.items():
        prior=before.get(path)
        if prior==meta:continue
        p=Path(path)
        if p.suffix.lower() in ('.mdmp','.dmp'):return 'crash'
        with p.open('rb') as f:
            prefix=hashlib.sha256(f.read(min(prior[2],4096))).hexdigest() if prior else None
        offset=prior[2] if prior and prior[:2]==meta[:2] and meta[2]>=prior[2] and prefix==prior[4] else 0
        with p.open('rb') as f:
            f.seek(offset);data=f.read(4*1024*1024)
        if b'[Crash]' in data or b'Unhandled exception' in data:return 'crash'
        if meta[2]-offset>len(data):return 'unknown'
    return 'none'


def wait_game(original,argv,env,directory,log,timeout,inspector,marker,seen,extra_args=()):
    if argv!=[env.get('PLAYMELT_WINE_EXECUTABLE',''),str(GAME)]:
        return original(argv,env,directory,log,timeout,inspector,marker,seen)
    # User session has no artificial 120-second diagnostic timeout.
    p=subprocess.Popen(argv+['-nolauncher']+list(extra_args),cwd=directory,env=env,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,start_new_session=True)
    try:
        item=inspector.identity(p.pid)
        if item:seen[base.identity_key(item)]=item
        else:seen['_inspection_unknown']=True
    except Exception:seen['_inspection_unknown']=True
    sel=selectors.DefaultSelector();sel.register(p.stdout,selectors.EVENT_READ);written=0;capped=False
    try:
        next_scan=0
        while p.poll() is None:
            if time.monotonic()>=next_scan:
                try:
                    marked,unknown=inspector.snapshot(marker)
                    for item in marked:seen[base.identity_key(item)]=item
                    if unknown:seen['_inspection_unknown']=True
                except Exception:seen['_inspection_unknown']=True
                next_scan=time.monotonic()+2
            for key,_ in sel.select(0.2):
                chunk=os.read(key.fd,65536)
                if not chunk:sel.unregister(key.fileobj);continue
                n=min(len(chunk),max(0,base.MAX_LOG-written));log.write(chunk[:n]);log.flush();written+=n
                if n<len(chunk):capped=True
        end=time.monotonic()+0.3
        while sel.get_map() and time.monotonic()<end:
            for key,_ in sel.select(min(0.05,max(0,end-time.monotonic()))):
                chunk=os.read(key.fd,65536)
                if not chunk:sel.unregister(key.fileobj);continue
                n=min(len(chunk),max(0,base.MAX_LOG-written));log.write(chunk[:n]);log.flush();written+=n
                if n<len(chunk):capped=True
        return p,False,capped
    except BaseException:
        base.reap_child(p);raise
    finally:sel.close()


def requested_mode(argv):
    return argv[1] if len(argv)==2 and argv[1] in ('--run','--prepare-only') else None

def main():
    mode=requested_mode(sys.argv)
    if mode is None:return 64
    if sys.platform!='darwin':raise RuntimeError('macOS required')
    if GAME_DIR.resolve()!=GAME_DIR or not base.valid_executable(GAME):raise RuntimeError('game executable missing or invalid')
    manifest=json.loads((RESOURCES/'spiderman-runtime-hashes.json').read_text())
    if set(manifest)!={'cas','probe','retina','settings','plan'} or any(not isinstance(v,str) or len(v)!=64 or any(c not in '0123456789abcdef' for c in v) for v in manifest.values()):raise RuntimeError('invalid runtime hash manifest')
    base.PLAN_HELPER=RESOURCES/'m3-private-plan';tx.HELPER=RESOURCES/'setupapi-hardwareid-cas.exe';experiment.PROBE=RESOURCES/'setupapi-identity-probe.exe'
    if base.PLAN_HELPER.is_symlink() or not base.PLAN_HELPER.is_file() or digest(base.PLAN_HELPER)!=manifest['plan']:raise RuntimeError('plan helper identity mismatch')
    tx.HELPER_SHA=manifest['cas'];experiment.PROBE_SHA=manifest['probe']
    plan=json.loads(subprocess.run([str(base.PLAN_HELPER)],capture_output=True,check=True,timeout=90).stdout)
    reuse.RUN=PROFILE;reuse.PREFIX=PREFIX;base.GAME_DIR=GAME_DIR;base.GAME=GAME
    preferences=read_preferences()
    lockfd=create_profile(plan)
    try:
        # A previous applied journal must be safely undone before a new launch.
        for journal in PROFILE.glob('gpu-hardwareid-*/journal.json'):
            value=json.loads(journal.read_text())
            if value.get('state')!='rolled_back':
                old=sys.argv
                try:sys.argv=[old[0],'--undo',value['transaction']];rc=tx.main()
                finally:sys.argv=old
                if rc!=0:raise RuntimeError('prior transaction recovery failed')
        seed_saves()
        seed_settings(plan,manifest)
        # Registry writes happen only while the private prefix is idle. The old
        # Wine helper is unnecessary here and cannot add an unsolicited default.
        reuse.require_idle_prefix(PREFIX)
        apply_preferences(plan,preferences)
        if mode=='--prepare-only':
            print('Profil Spider-Man 2 préparé ; aucun lancement du jeu.',flush=True)
            return 0
        before=crash_snapshot();old_run=base.run_command;old_shutdown=base.bounded_shutdown;old_argv=sys.argv;old_copy_log=experiment.COPY_PREVIOUS_DIAGNOSTIC_LOG
        def run_adapter(argv,env,directory,log,timeout,inspector,marker,seen):
            if argv==[plan['wine'],str(GAME)]:
                env=dict(env);env['PLAYMELT_WINE_EXECUTABLE']=plan['wine']
                return wait_game(old_run,argv,env,directory,log,timeout,inspector,marker,seen,preferences[1] if preferences else ())
            return old_run(argv,env,directory,log,timeout,inspector,marker,seen)
        def shutdown_adapter(server,env,directory,state):
            try:
                if reuse.query_game_pids(GAME):raise RuntimeError('a process still maps the game executable')
                old_shutdown(server,env,directory,state)
            except Exception as e:state['shutdown']['scope']={'error':str(e)}
        try:
            base.run_command=run_adapter;base.bounded_shutdown=shutdown_adapter;experiment.COPY_PREVIOUS_DIAGNOSTIC_LOG=False;sys.argv=[old_argv[0],'--run']
            result=experiment.main()
        finally:
            base.run_command=old_run;base.bounded_shutdown=old_shutdown;experiment.COPY_PREVIOUS_DIAGNOSTIC_LOG=old_copy_log;sys.argv=old_argv
        crash=new_crash(before,crash_snapshot())
        if crash!='none':
            print('Spider-Man 2: '+('nouveau rapport de crash détecté.' if crash=='crash' else 'vérification de crash incomplète.'),file=sys.stderr);return 1
        return result
    finally:fcntl.flock(lockfd,fcntl.LOCK_UN);os.close(lockfd)

if __name__=='__main__':
    def interrupted(signum,frame):raise KeyboardInterrupt('signal '+str(signum))
    previous={sig:signal.signal(sig,interrupted) for sig in (signal.SIGINT,signal.SIGTERM)}
    try:sys.exit(main())
    finally:
        for sig,handler in previous.items():signal.signal(sig,handler)
