#!/usr/bin/env python3
"""Inspect/copy a user's extracted game or ZIP. Never executes an installer."""
import argparse
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import uuid
import zipfile

MAX_FILES=200000
MAX_BYTES=500*1024**3

def safe_name(raw):
    if '\\' in raw or '\x00' in raw or ':' in raw:
        raise ValueError('Chemin d’archive non pris en charge')
    path=PurePosixPath(raw)
    if path.is_absolute() or '..' in path.parts or any(part.startswith('.') and part in ('.','..') for part in path.parts):
        raise ValueError('Chemin hors du dossier du jeu')
    return path.as_posix().rstrip('/')

def inventory(source):
    items=[]
    if source.is_symlink():raise ValueError('Sélectionnez le dossier original, pas un lien')
    if source.is_dir():
        for base, dirs, files in os.walk(source,followlinks=False):
            for name in dirs+files:
                path=Path(base)/name
                if path.is_symlink():raise ValueError('Le dossier contient un lien symbolique')
                if not path.is_dir() and not path.is_file():raise ValueError('Type de fichier non pris en charge')
                if path.is_file():items.append((path.relative_to(source).as_posix(),path.stat().st_size))
                if len(items)>MAX_FILES:raise ValueError('Trop de fichiers')
    elif source.suffix.lower()=='.zip':
        with zipfile.ZipFile(source) as archive:
            for item in archive.infolist():
                name=safe_name(item.filename)
                mode=item.external_attr>>16
                if stat.S_ISLNK(mode) or (stat.S_IFMT(mode) not in (0,stat.S_IFREG,stat.S_IFDIR)):
                    raise ValueError('L’archive contient un lien ou un fichier spécial')
                if item.flag_bits&1:raise ValueError('Archive chiffrée : extrayez-la d’abord')
                if not item.is_dir():items.append((name,item.file_size))
                if len(items)>MAX_FILES:raise ValueError('Trop de fichiers')
    else:raise ValueError('Cet installateur nécessite le parcours VM ; il ne sera pas exécuté sur le Mac')
    names=[safe_name(name) for name,size in items]
    folded={name.casefold() for name in names}
    if len(folded)!=len(names):raise ValueError('Noms de fichiers en conflit')
    if any(parent.as_posix().casefold() in folded for name in names for parent in PurePosixPath(name).parents if str(parent)!='.'):
        raise ValueError('Un fichier remplace un dossier')
    total=sum(size for name,size in items)
    if total>MAX_BYTES:raise ValueError('Installation trop volumineuse')
    candidates=[name for name in names if name.lower().endswith('.exe') and not re.search(r'(^|/)(setup|install|unins|redist|vcredist|dxsetup|crash|launcher|unitycrash)',PurePosixPath(name).name,re.I)]
    return items,{'files':len(items),'bytes':total,'executables':candidates[:100], 'kind':'folder' if source.is_dir() else 'zip'}

def install(source,root,title,executable):
    items,info=inventory(source)
    if executable not in info['executables']:raise ValueError('Exécutable non confirmé')
    if not title.strip() or len(title)>160:raise ValueError('Nom de jeu invalide')
    root.mkdir(parents=True,exist_ok=True)
    if root.is_symlink():raise ValueError('Destination invalide')
    if shutil.disk_usage(root).free<info['bytes']+2*1024**3:raise ValueError('Espace disque insuffisant')
    identity=str(uuid.uuid4());target=root.parent/'Imports.noindex'/identity;target.mkdir(parents=True,mode=0o700)
    # Preserve a failed staging folder for recovery. It has no manifest and is not playable.
    stage=target/'Windows';stage.mkdir(mode=0o700)
    if source.is_dir():
        for name,size in items:
            original=source/name
            if original.is_symlink() or not original.is_file():raise ValueError('Source modifiée pendant l’import')
            dest=stage/name;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(original,dest)
    else:
        with zipfile.ZipFile(source) as archive:
            for name,size in items:
                dest=stage/name;dest.parent.mkdir(parents=True,exist_ok=True)
                with archive.open(name) as src,dest.open('xb') as dst:
                    written=0
                    while chunk:=src.read(1024*1024):
                        written+=len(chunk)
                        if written>size:raise ValueError('Taille d’archive incohérente')
                        dst.write(chunk)
    with (stage/executable).open('rb') as binary:
        if binary.read(2)!=b'MZ':raise ValueError('Exécutable Windows invalide')
    manifest={'schema':1,'id':identity,'title':title.strip(),'executable':executable}
    temporary=target/'manifest.tmp';temporary.write_text(json.dumps(manifest,ensure_ascii=False),encoding='utf-8');temporary.replace(target/'.playmelt-game.json');target.rename(root/('Imported-'+identity))
    return {'status':'imported','title':title.strip(),'id':identity}

def main():
    parser=argparse.ArgumentParser();parser.add_argument('action',choices=['inspect','install']);parser.add_argument('--source',type=Path,required=True);parser.add_argument('--root',type=Path);parser.add_argument('--title');parser.add_argument('--executable');args=parser.parse_args()
    try:
        if not args.source.is_absolute():raise ValueError('Chemin absolu requis')
        result=inventory(args.source)[1] if args.action=='inspect' else install(args.source,args.root,args.title,args.executable)
        print(json.dumps(result,ensure_ascii=False));return 0
    except (ValueError,OSError,zipfile.BadZipFile,RuntimeError) as e:
        print(json.dumps({'error':str(e)},ensure_ascii=False));return 1
if __name__=='__main__':raise SystemExit(main())
