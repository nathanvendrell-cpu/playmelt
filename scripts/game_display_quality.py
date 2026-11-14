#!/usr/bin/env python3
"""Prepare backing-pixel rendering in an idle, existing DX12 prefix. Never starts Wine or a game."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
FFVII = '33e6ac38b5a14098b079fd62d71aabc6'
MAC_SECTION = r'Software\\Wine\\Mac Driver'

def dimensions(env):
    if env.get('PLAYMELT_DISPLAY_POLICY') != 'external-windowed-v1':
        raise ValueError('Politique d’écran non vérifiée.')
    def number(key, low, high):
        value=env.get(key,'')
        if not re.fullmatch(r'-?[0-9]{1,6}',value):raise ValueError('Dimensions d’écran non vérifiées.')
        value=int(value)
        if not low<=value<=high:raise ValueError('Dimensions d’écran hors limites.')
        return value
    scale=number('PLAYMELT_DISPLAY_SCALE',1,2)
    width=number('PLAYMELT_DISPLAY_DESKTOP_WIDTH',640,7680)
    height=number('PLAYMELT_DISPLAY_DESKTOP_HEIGHT',480,4320)
    pixel_w=number('PLAYMELT_DISPLAY_PIXEL_WIDTH',640,7680)
    pixel_h=number('PLAYMELT_DISPLAY_PIXEL_HEIGHT',480,4320)
    if (pixel_w,pixel_h)!=(width*scale,height*scale):raise ValueError('Échelle Retina incohérente.')
    x=number('PLAYMELT_GAME_X',-32768,32768);y=number('PLAYMELT_GAME_Y',-32768,32768)
    return {'scale':scale,'width':pixel_w,'height':pixel_h,
            'window':[max(640,width)*scale,max(480,height)*scale,x*scale,y*scale]}

def patch_fields(text,section,values,registry=False):
    headers=list(re.finditer(r'^\[([^\r\n]+)\][^\r\n]*\r?$',text,re.M))
    matches=[(i,h) for i,h in enumerate(headers) if h[1]==section]
    if len(matches)!=1:raise ValueError('Section graphique absente ou ambiguë.')
    index,header=matches[0];end=headers[index+1].start() if index+1<len(headers) else len(text)
    body=text[header.end():end];changes=[]
    for name,value in values.items():
        key='"'+name+'"' if registry else name
        pattern=re.compile(r'^'+re.escape(key)+r'=([^\r\n]*)\r?$',re.M)
        found=list(pattern.finditer(body))
        if len(found)>1:raise ValueError('Clé graphique ambiguë.')
        before=found[0][1] if found else None
        if before==value:continue
        replacement=key+'='+value
        if found:body=pattern.sub(lambda _:replacement,body,count=1)
        else:body=body.rstrip('\r\n')+'\n'+replacement+'\n\n'
        changes.append({'section':section,'key':name,'before':before,'after':value})
    return text[:header.end()]+body+text[end:],changes

def atomic(path,data):
    fd,name=tempfile.mkstemp(prefix='.'+path.name+'.',dir=path.parent)
    try:
        os.fchmod(fd,0o600)
        with os.fdopen(fd,'wb') as stream:stream.write(data);stream.flush();os.fsync(stream.fileno())
        os.replace(name,path)
    finally:
        if os.path.exists(name):os.unlink(name)

def prepare(prefix,config,plan,journal,require_idle=lambda:None):
    previous=json.loads(journal.read_text()) if journal.exists() else {}
    if previous.get('state')=='prepared':
        raise ValueError('Préparation graphique précédente incomplète ; diagnostic nécessaire.')
    # One initial correction, then preserve changes made in the game's own settings.
    if previous.get('ffviiMigrated') is True:config=None
    edits=[]
    paths=[prefix/'user.reg']+([config] if config else [])
    for path in paths:
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(prefix) or path.stat().st_size>8*1024*1024:
            raise ValueError('Fichier de réglages non vérifié.')
        before=path.read_bytes();text=before.decode('utf-8')
        if path.name=='user.reg':
            after,changes=patch_fields(text,MAC_SECTION,{'RetinaMode':'"Y"' if plan['scale']==2 else '"N"','CaptureDisplaysForFullscreen':'"N"'},registry=True)
        else:
            fields={'ResolutionSizeX':str(plan['width']),'ResolutionSizeY':str(plan['height']),
                    'LastUserConfirmedResolutionSizeX':str(plan['width']),'LastUserConfirmedResolutionSizeY':str(plan['height']),
                    'DesiredScreenWidth':str(plan['width']),'DesiredScreenHeight':str(plan['height']),
                    'LastUserConfirmedDesiredScreenWidth':str(plan['width']),'LastUserConfirmedDesiredScreenHeight':str(plan['height']),
                    'bUseDynamicResolution':'False','FullscreenMode':'1','LastConfirmedFullscreenMode':'1','PreferredFullscreenMode':'1'}
            after,changes=patch_fields(text,'/Script/Engine.GameUserSettings',fields)
            after,quality=patch_fields(after,'ScalabilityGroups',{'sg.ResolutionQuality':'100.000000','sg.TextureQuality':'3'})
            changes+=quality
        if changes:edits.append((path,before,after.encode('utf-8'),changes))
    if not edits and config is None:return
    if edits:require_idle()
    receipt={'state':'prepared','at':time.time(),'width':plan['width'],'height':plan['height'],'scale':plan['scale'],
             'ffviiMigrated':previous.get('ffviiMigrated') is True,
             'globalModesChanged':False,'changes':[{'file':str(p.relative_to(prefix)),'beforeSHA256':hashlib.sha256(b).hexdigest(),
              'afterSHA256':hashlib.sha256(a).hexdigest(),'fields':c} for p,b,a,c in edits]}
    atomic(journal,json.dumps(receipt,ensure_ascii=False,indent=2).encode())
    written=[]
    try:
        for path,before,after,_ in edits:
            if path.read_bytes()!=before:raise ValueError('Les réglages ont changé pendant la préparation.')
            atomic(path,after);written.append((path,before,after))
        receipt['state']='committed';receipt['ffviiMigrated']=receipt['ffviiMigrated'] or config is not None
        atomic(journal,json.dumps(receipt,ensure_ascii=False,indent=2).encode())
    except BaseException:
        restored=True
        for path,before,after in reversed(written):
            if path.read_bytes()==after:atomic(path,before)
            else:restored=False
        receipt['state']='rolled-back' if restored else 'prepared'
        atomic(journal,json.dumps(receipt,ensure_ascii=False,indent=2).encode())
        raise

def main():
    if len(sys.argv)!=3 or sys.argv[1]!='--prepare' or not re.fullmatch('[A-Za-z0-9_.-]{1,80}',sys.argv[2]):return 64
    home=Path.home();root=home/'Library/Application Support/Playmelt'
    prefix=root/'Runtime/D3DMetal/prefix'
    if os.environ.get('WINEPREFIX')!=str(prefix) or prefix.resolve()!=prefix or not prefix.is_dir():raise ValueError('Préfixe DirectX 12 non vérifié.')
    plan=dimensions(os.environ)
    journal=root/'GameSettings/display-quality-journal.json';journal.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
    if journal.parent.resolve()!=journal.parent or journal.is_symlink():raise ValueError('Dossier de réglages non vérifié.')
    lock_path=journal.with_suffix('.lock')
    fd=os.open(lock_path,os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
    try:
        fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        def require_idle():
            active=subprocess.run(['/usr/sbin/lsof','-t','+D',str(prefix)],stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=25,env={'PATH':'/usr/bin:/bin','LC_ALL':'C'})
            if active.returncode!=1 or active.stdout or active.stderr:raise ValueError('Ferme les applications Windows de cet environnement avant de changer son affichage.')
        config=None
        if sys.argv[2]==FFVII:
            matches=list((prefix/'drive_c/users').glob('*/Documents/My Games/FINAL FANTASY VII REBIRTH/Saved/Config/WindowsNoEditor/GameUserSettings.ini'))
            if len(matches)>1:raise ValueError('Réglages Final Fantasy ambigus.')
            if matches:config=matches[0]
        prepare(prefix,config,plan,journal,require_idle)
        print(' '.join(map(str,plan['window'])))
    finally:os.close(fd)
    return 0

if __name__=='__main__':
    try:sys.exit(main())
    except (ValueError,OSError,subprocess.SubprocessError) as error:print(str(error),file=sys.stderr);sys.exit(1)
