#!/usr/bin/env python3
"""Stage verified publisher files for verification/adoption by official Steam.

No appmanifest, StateFlags, install script or game process is created/executed.
Only APFS clones are allowed; unsupported storage never falls back to a large copy.
"""
import argparse
from contextlib import ExitStack
import ctypes
import errno
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import unicodedata
import uuid

DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
FILE_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC


def identity(value):
    return (value.st_dev,value.st_ino,value.st_mode,value.st_uid,value.st_size,
            value.st_mtime_ns,value.st_ctime_ns,value.st_nlink)


def directory_identity(value):
    return value.st_dev,value.st_ino,value.st_mode,value.st_uid


class Directory:
    """An open directory and its no-follow namespace binding, never a cwd."""
    def __init__(self,fd,stack,parent=None,name=None,owned=True):
        stack.callback(os.close,fd)
        value=os.fstat(fd)
        if not stat.S_ISDIR(value.st_mode) or (owned and value.st_uid!=os.geteuid()):
            raise ValueError('Dossier non possédé par cette opération')
        self.fd,self.parent,self.name,self.owned=fd,parent,name,owned
        self.binding=(value.st_dev,value.st_ino,value.st_uid)

    def validate(self):
        if self.parent:
            self.parent.validate()
            value=os.stat(self.name,dir_fd=self.parent.fd,follow_symlinks=False)
        else:value=os.fstat(self.fd)
        if not stat.S_ISDIR(value.st_mode) or (value.st_dev,value.st_ino,value.st_uid)!=self.binding:
            raise ValueError('Un dossier a changé pendant la préparation')
        if self.owned and value.st_uid!=os.geteuid():raise ValueError('Dossier étranger')

    def child(self,name,stack):
        self.validate()
        return Directory(os.open(name,DIRECTORY_FLAGS,dir_fd=self.fd),stack,self,name)


def open_root(path,stack):
    if path.resolve()!=path or len(path.parts)>64:raise ValueError('Dossier avec lien ou chemin non canonique')
    current=Directory(os.open('/',DIRECTORY_FLAGS),stack,owned=False)
    for index,part in enumerate(path.parts[1:]):
        current.validate()
        current=Directory(os.open(part,DIRECTORY_FLAGS,dir_fd=current.fd),stack,current,part,owned=index==len(path.parts)-2)
    return current


def snapshot(root,source=False):
    files,dirs={},{}
    def walk(directory,relative):
        directory.validate()
        value=os.fstat(directory.fd)
        dirs[relative]=identity(value) if source else directory_identity(value)
        for name in sorted(os.listdir(directory.fd)):
            key=relative+'/'+name if relative else name
            value=os.stat(name,dir_fd=directory.fd,follow_symlinks=False)
            if stat.S_ISDIR(value.st_mode):
                with ExitStack() as stack:walk(directory.child(name,stack),key)
            elif stat.S_ISREG(value.st_mode) and (not source or value.st_uid==os.geteuid()):files[key]=identity(value)
            else:raise ValueError('Lien ou fichier spécial dans les fichiers préparés')
            if len(files)+len(dirs)>200000:raise ValueError('Inventaire trop volumineux')
    walk(root,'')
    return files,dirs


def safe_relative(value):
    return (isinstance(value,str) and 0<len(value)<=1024 and not any(c in value for c in '\\:\x00') and
            not any(ord(c)<32 for c in value) and all(p not in ('','.','..') and p==p.rstrip(' .') for p in value.split('/')))


def unique_object(pairs):
    result={}
    for key,value in pairs:
        if key in result:raise ValueError('Clé de reçu ambiguë')
        result[key]=value
    return result


def read_receipt(folder):
    folder.validate()
    fd=os.open('playmelt-install.json',FILE_FLAGS,dir_fd=folder.fd)
    try:
        before=os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_uid!=os.geteuid() or not 0<before.st_size<=16000000:raise ValueError('Reçu invalide')
        with os.fdopen(fd,'rb',closefd=False) as stream:data=stream.read(16000001)
        if len(data)>16000000 or identity(os.fstat(fd))!=identity(before):raise ValueError('Reçu modifié')
        return json.loads(data,object_pairs_hook=unique_object),identity(before)
    finally:os.close(fd)


def clone_file(source_fd,directory_fd,name):
    lib=ctypes.CDLL('/usr/lib/libSystem.B.dylib',use_errno=True)
    fn=lib.fclonefileat;fn.argtypes=[ctypes.c_int,ctypes.c_int,ctypes.c_char_p,ctypes.c_uint];fn.restype=ctypes.c_int
    if fn(source_fd,directory_fd,os.fsencode(name),0):
        code=ctypes.get_errno();raise OSError(code,os.strerror(code))


def publish_file(source_directory,source_name,target_directory,target_name):
    lib=ctypes.CDLL('/usr/lib/libSystem.B.dylib',use_errno=True)
    fn=lib.renameatx_np;fn.argtypes=[ctypes.c_int,ctypes.c_char_p,ctypes.c_int,ctypes.c_char_p,ctypes.c_uint];fn.restype=ctypes.c_int
    if fn(source_directory,os.fsencode(source_name),target_directory,os.fsencode(target_name),0x00000004): # RENAME_EXCL
        code=ctypes.get_errno();raise OSError(code,os.strerror(code))


def check_cancelled(cancelled):
    if cancelled():raise InterruptedError(errno.ECANCELED,'Préparation des fichiers annulée')


def hash_file(fd,cancelled):
    result=hashlib.sha256()
    while True:
        check_cancelled(cancelled)
        data=os.read(fd,1024*1024)
        if not data:return result.hexdigest()
        result.update(data)


def file_parent(root,relative,stack,created=None):
    parent=root;parts=relative.split('/')
    for offset,name in enumerate(parts[:-1]):
        key='/'.join(parts[:offset+1])
        try:child=parent.child(name,stack)
        except FileNotFoundError:
            if created is None:raise
            parent.validate();os.mkdir(name,0o755,dir_fd=parent.fd)
            child=parent.child(name,stack)
            created[key]=directory_identity(os.fstat(child.fd))
        if created is not None and created.get(key)!=directory_identity(os.fstat(child.fd)):
            raise ValueError('Dossier destination créé ou remplacé simultanément')
        parent=child
    return parent,parts[-1]


def cleanup_stage(common,stage,name):
    # The private stage is flat and was created empty by this invocation. Never
    # traverse a link or remove a replacement directory at its published name.
    for entry in os.listdir(stage.fd):
        value=os.stat(entry,dir_fd=stage.fd,follow_symlinks=False)
        if value.st_uid!=os.geteuid() or stat.S_ISDIR(value.st_mode):raise ValueError('Staging modifié ; nettoyage automatique refusé')
        os.unlink(entry,dir_fd=stage.fd)
    value=os.stat(name,dir_fd=common.fd,follow_symlinks=False)
    if not stat.S_ISDIR(value.st_mode) or (value.st_dev,value.st_ino,value.st_uid)!=stage.binding:raise ValueError('Staging remplacé ; dossier tiers conservé')
    os.rmdir(name,dir_fd=common.fd)


def prepare(folder,steam_root,app_id,clone=None,publish=None,cancelled=lambda:False,progress=None):
    folder,steam_root=Path(folder).absolute(),Path(steam_root).absolute()
    if not re.fullmatch(r'[1-9][0-9]{0,9}',app_id):raise ValueError('Identité Steam invalide')
    clone,publish=clone or clone_file,publish or publish_file
    with ExitStack() as stack:
        source_folder,steam=open_root(folder,stack),open_root(steam_root,stack)
        receipt,receipt_identity=read_receipt(source_folder)
        if not isinstance(receipt,dict) or receipt.get('appID')!=app_id or receipt.get('source')!='official-steam-console-completion':raise ValueError('Reçu associé à un autre jeu')
        name=receipt.get('officialInstallDirectory','')
        if not safe_relative(name) or '/' in name or len(name)>160:raise ValueError('Dossier éditeur Steam à qualifier')
        expected,hashes=receipt.get('files'),receipt.get('fileSHA256')
        if (not isinstance(expected,dict) or not expected or len(expected)>200000 or
            any(not safe_relative(k) or type(v)!=int or v<0 for k,v in expected.items()) or
            not isinstance(hashes,dict) or set(hashes)!=set(expected) or
            any(not isinstance(v,str) or not re.fullmatch('[0-9a-f]{64}',v) for v in hashes.values()) or
            len({unicodedata.normalize('NFC',k).casefold() for k in expected})!=len(expected)):
            raise ValueError('Inventaire ou empreintes Steam invalides')
        source=source_folder.child('Windows',stack);before=snapshot(source,source=True)
        if {k:v[4] for k,v in before[0].items()}!=expected:raise ValueError('Les fichiers préparés ont changé')
        client=os.open('steam.exe',FILE_FLAGS,dir_fd=steam.fd)
        try:
            if not stat.S_ISREG(os.fstat(client).st_mode) or os.read(client,2)!=b'MZ':raise ValueError('Client officiel Steam Windows invalide')
        finally:os.close(client)
        apps=steam.child('steamapps',stack)
        try:common=apps.child('common',stack)
        except FileNotFoundError:
            apps.validate();os.mkdir('common',0o755,dir_fd=apps.fd);common=apps.child('common',stack)
        try:target=common.child(name,stack)
        except FileNotFoundError:target=None
        existed=target is not None
        target_files,target_dirs=snapshot(target) if target else ({},{})
        missing=[];existing=0
        for relative in sorted(expected):
            if relative in target_dirs:raise ValueError('Un dossier occupe un fichier attendu')
            if any('/'.join(relative.split('/')[:i]) in target_files for i in range(1,len(relative.split('/')))):raise ValueError('Un fichier occupe un dossier attendu')
            if relative in target_files:existing+=1
            else:missing.append(relative)
        metrics=dict(clonedFiles=0,existingFiles=existing,processedFiles=existing,totalFiles=len(expected),totalBytes=sum(expected.values()),
                     clonedBytes=0,existingBytes=sum(target_files[k][4] for k in expected if k in target_files),stagedFiles=0,stagedBytes=0)
        notify=lambda:progress(dict(metrics)) if progress else None
        def validate_source():
            source_folder.validate();source.validate()
            if identity(os.stat('playmelt-install.json',dir_fd=source_folder.fd,follow_symlinks=False))!=receipt_identity:
                raise ValueError('Reçu source modifié pendant la préparation')
            if snapshot(source,source=True)!=before:raise ValueError('Inventaire source modifié ; publication arrêtée')
        check_cancelled(cancelled);notify()
        stage_name='.playmelt-reuse-'+app_id+'-'+uuid.uuid4().hex
        stage=None;stage_binding=None;staged={}
        try:
            common.validate();os.mkdir(stage_name,0o700,dir_fd=common.fd)
            value=os.stat(stage_name,dir_fd=common.fd,follow_symlinks=False);stage_binding=(value.st_dev,value.st_ino,value.st_uid)
            stage=common.child(stage_name,stack)
            if stage.binding!=stage_binding:stage=None;raise ValueError('Staging remplacé pendant son ouverture')
            for index,relative in enumerate(missing):
                check_cancelled(cancelled)
                with ExitStack() as parents:
                    parent,leaf=file_parent(source,relative,parents);fd=os.open(leaf,FILE_FLAGS,dir_fd=parent.fd)
                    try:
                        if identity(os.fstat(fd))!=before[0][relative]:raise ValueError('Fichier source modifié')
                        stage.validate();temporary=str(index);clone(fd,stage.fd,temporary)
                        if identity(os.fstat(fd))!=before[0][relative]:raise ValueError('Fichier source modifié pendant le clone')
                    finally:os.close(fd)
                cloned=os.open(temporary,FILE_FLAGS,dir_fd=stage.fd)
                try:
                    value=os.fstat(cloned)
                    if not stat.S_ISREG(value.st_mode) or value.st_uid!=os.geteuid() or value.st_size!=expected[relative] or hash_file(cloned,cancelled)!=hashes[relative]:raise ValueError('Empreinte du clone non conforme au reçu Steam')
                    if identity(os.fstat(cloned))!=identity(value):raise ValueError('Clone modifié pendant la vérification')
                    staged[relative]=(temporary,value)
                finally:os.close(cloned)
                metrics['stagedFiles']+=1;metrics['stagedBytes']+=value.st_size;notify()
            validate_source()
            if target:
                if snapshot(target)!=(target_files,target_dirs):raise ValueError('Cible modifiée ; publication arrêtée')
            else:
                common.validate();os.mkdir(name,0o755,dir_fd=common.fd);target=common.child(name,stack)
                target_files,target_dirs=snapshot(target)
            for relative,(temporary,value) in staged.items():
                check_cancelled(cancelled);source.validate();target.validate();stage.validate()
                with ExitStack() as parents:
                    parent,leaf=file_parent(target,relative,parents,created=target_dirs)
                    parent.validate();publish(stage.fd,temporary,parent.fd,leaf);parent.validate()
                    published=os.stat(leaf,dir_fd=parent.fd,follow_symlinks=False)
                    if (published.st_dev,published.st_ino,published.st_mode,published.st_uid,published.st_size,published.st_mtime_ns)!=(value.st_dev,value.st_ino,value.st_mode,value.st_uid,value.st_size,value.st_mtime_ns):raise ValueError('Fichier publié modifié simultanément')
                    target_files[relative]=identity(published)
                metrics['clonedFiles']+=1;metrics['clonedBytes']+=value.st_size;metrics['processedFiles']+=1;notify()
            check_cancelled(cancelled);validate_source();target.validate()
            if snapshot(target)!=(target_files,target_dirs):raise ValueError('Inventaire cible modifié pendant la préparation')
            return dict(status='existing-directory' if existed else 'prepared',target=str(steam_root/'steamapps/common'/name),requiresSteamValidation=True,
                        filesWritten=metrics['clonedFiles'],appID=app_id,**metrics)
        finally:
            if stage_binding is not None:
                if stage is None:
                    value=os.stat(stage_name,dir_fd=common.fd,follow_symlinks=False)
                    if not stat.S_ISDIR(value.st_mode) or (value.st_dev,value.st_ino,value.st_uid)!=stage_binding:raise ValueError('Staging remplacé ; nettoyage refusé')
                    stage=Directory(os.open(stage_name,DIRECTORY_FLAGS,dir_fd=common.fd),stack,common,stage_name)
                cleanup_stage(common,stage,stage_name)


def main():
    p=argparse.ArgumentParser();p.add_argument('--game-folder',required=True);p.add_argument('--steam-root',required=True);p.add_argument('--appid',required=True);a=p.parse_args()
    try:result=prepare(a.game_folder,a.steam_root,a.appid)
    except (OSError,ValueError,KeyError) as error:
        print(json.dumps({'status':'error','error':'Réutilisation des fichiers non finalisée : '+str(error),'requiresSteamValidation':True}));return 1
    print(json.dumps(result));return 0


if __name__=='__main__':
    def cancel(*_):raise KeyboardInterrupt
    signal.signal(signal.SIGTERM,cancel);signal.signal(signal.SIGINT,cancel)
    try:raise SystemExit(main())
    except KeyboardInterrupt:raise SystemExit(130)
