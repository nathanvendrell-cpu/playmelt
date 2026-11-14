# SPDX-License-Identifier: GPL-3.0-only
"""Private GOG worker protocol and content verification. No network or client API.

The native caller supplies an account-bound plan over a private pipe. A saved
checkpoint is informational: every resume rehashes the real bytes. This module
does not certify an executable, prerequisites, entitlement, or launch readiness.
"""
from __future__ import annotations

import contextlib
import dataclasses
import fcntl
import hashlib
import json
import math
import os
import pathlib
import re
import select
import stat
import time
import uuid

MAX_JSON = 8 * 1024 * 1024
MAX_FILES = 100_000
MAX_COUNTER = 2**53 - 1
MARKER = '.playmelt-gog-owner.json'
LOCK = '.playmelt-gog-operation.lock'
CHECKPOINT = '.playmelt-gog-checkpoint.json'
RESERVED = ('.playmelt-gog-', '.gogdl-resume')


class Issue(Exception):
    def __init__(self, code: str, retryable: bool = False, resume_point: str = 'plan'):
        super().__init__(code)
        self.code, self.retryable, self.resume_point = code, retryable, resume_point


def integer(value, maximum=MAX_COUNTER):
    if type(value) is not int or not 0 <= value <= maximum:
        raise Issue('invalid_counter')
    return value


def identifier(value):
    if not isinstance(value, str) or not re.fullmatch(r'[1-9][0-9]{0,19}', value):
        raise Issue('invalid_product')
    return value


def relative(value):
    if not isinstance(value, str) or not value or len(value.encode()) > 2048:
        raise Issue('invalid_path')
    parts = value.split('/')
    if any(not p or p in ('.', '..') or p.startswith(RESERVED) for p in parts):
        raise Issue('invalid_path')
    if '\\' in value or ':' in value or any(ord(c) < 32 for c in value):
        raise Issue('invalid_path')
    return value


def canonical(data):
    return json.dumps(data, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()


def decode(data, maximum=MAX_JSON):
    if not data or len(data) > maximum:
        raise Issue('invalid_request')
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise Issue('duplicate_field')
            result[key] = value
        return result
    try:
        value = json.loads(data, object_pairs_hook=unique,
                           parse_constant=lambda _: (_ for _ in ()).throw(Issue('invalid_number')))
    except (ValueError, UnicodeError):
        raise Issue('invalid_request') from None
    if not isinstance(value, dict):
        raise Issue('invalid_request')
    return value


@dataclasses.dataclass(frozen=True)
class Context:
    owner: str
    product: str
    platform: str
    job: str
    generation: int

    @classmethod
    def parse(cls, data):
        try:
            owner, platform, job = data['accountOwner'], data['platform'], data['jobID']
            if not isinstance(owner, str) or not re.fullmatch('[a-f0-9]{64}', owner):
                raise Issue('invalid_owner')
            if platform not in ('osx', 'windows') or str(uuid.UUID(job)) != job:
                raise Issue('invalid_context')
            return cls(owner, identifier(data['productID']), platform, job, integer(data['generation']))
        except (KeyError, ValueError, TypeError, AttributeError):
            raise Issue('invalid_context') from None


@dataclasses.dataclass(frozen=True)
class File:
    path: str
    size: int
    algorithm: str
    digest: str
    chunks: tuple = ()


@dataclasses.dataclass(frozen=True)
class Plan:
    context: Context
    build: str
    files: tuple[File, ...]
    digest: str

    @classmethod
    def parse(cls, context, data):
        try:
            if data['productID'] != context.product or data['platform'] != context.platform:
                raise Issue('plan_context_mismatch')
            build = identifier(data['buildID'])
            rows = data['files']
            if not isinstance(rows, list) or not 0 < len(rows) <= MAX_FILES:
                raise Issue('invalid_manifest')
            files, names = [], set()
            for row in rows:
                path, size = relative(row['path']), integer(row['size'])
                name = path.casefold()
                if name in names:
                    raise Issue('manifest_collision')
                names.add(name)
                algorithm = row['algorithm']
                digest = row['digest']
                length = {'md5': 32, 'sha256': 64, 'chunks-md5':64}.get(algorithm)
                if length is None or not isinstance(digest, str) or not re.fullmatch('[a-f0-9]{'+str(length)+'}', digest):
                    raise Issue('unsupported_digest')
                chunks = tuple(row.get('chunks', []))
                if chunks:
                    if len(chunks) > MAX_FILES:
                        raise Issue('invalid_manifest')
                    total = 0
                    for chunk in chunks:
                        total += integer(chunk['size'],64*1024*1024)
                        integer(chunk['compressedSize'],64*1024*1024)
                        for field in ('md5', 'compressedMd5'):
                            if not isinstance(chunk[field], str) or not re.fullmatch('[a-f0-9]{32}', chunk[field]):
                                raise Issue('unsupported_digest')
                    if total != size:
                        raise Issue('invalid_manifest')
                if algorithm=='chunks-md5':
                    if not chunks or digest!=hashlib.sha256(canonical([{'size':c['size'],'md5':c['md5']} for c in chunks])).hexdigest():
                        raise Issue('invalid_manifest')
                files.append(File(path, size, algorithm, digest, chunks))
            if sum(f.size for f in files) > MAX_COUNTER:
                raise Issue('invalid_counter')
            for name in names:
                pieces = name.split('/')
                if any('/'.join(pieces[:i]) in names for i in range(1, len(pieces))):
                    raise Issue('manifest_collision')
            identity = {'owner':context.owner, 'product':context.product, 'platform':context.platform,
                        'build':build, 'files':[dataclasses.asdict(f) for f in files]}
            return cls(context, build, tuple(files), hashlib.sha256(canonical(identity)).hexdigest())
        except (KeyError, TypeError, AttributeError):
            raise Issue('invalid_manifest') from None


def private_pipe(fd, writing):
    if type(fd) is not int or fd <= 2:
        raise Issue('invalid_fd')
    try:
        value = os.fstat(fd)
        access = fcntl.fcntl(fd, fcntl.F_GETFL) & os.O_ACCMODE
    except OSError:
        raise Issue('invalid_fd') from None
    if not stat.S_ISFIFO(value.st_mode) or value.st_uid != os.geteuid() or access != (os.O_WRONLY if writing else os.O_RDONLY):
        raise Issue('invalid_fd')
    return value.st_dev, value.st_ino


def read_pipe(fd, maximum, timeout=10):
    deadline, result = time.monotonic()+timeout, bytearray()
    while True:
        remaining = deadline-time.monotonic()
        if remaining <= 0 or not select.select([fd], [], [], remaining)[0]:
            raise Issue('ipc_timeout', True, 'session')
        chunk = os.read(fd, min(65536, maximum+1-len(result)))
        if not chunk:
            return decode(bytes(result), maximum)
        result.extend(chunk)
        if len(result) > maximum:
            raise Issue('invalid_request')


def write_pipe(fd, data, maximum=MAX_JSON, timeout=2):
    payload = canonical(data)+b'\n'
    if len(payload) > maximum:
        raise Issue('ipc_limit')
    os.set_blocking(fd, False)
    deadline = time.monotonic()+timeout
    while payload:
        remaining = deadline-time.monotonic()
        if remaining <= 0 or not select.select([], [fd], [], remaining)[1]:
            raise Issue('ipc_timeout', True, 'session')
        try:
            count = os.write(fd, payload)
        except BlockingIOError:
            continue
        except (BrokenPipeError, OSError):
            raise Issue('parent_disconnected', True, 'session') from None
        payload = payload[count:]


class Cancellation:
    def __init__(self, fd=None):
        self.fd, self.cancelled = fd, False

    def check(self):
        if self.fd is not None and select.select([self.fd], [], [], 0)[0]:
            os.read(self.fd, 1)  # a byte or EOF both stop this owned operation
            self.cancelled = True
        if self.cancelled:
            raise Issue('cancelled', False, 'verify')


class Events:
    def __init__(self, context, sink):
        self.context, self.sink, self.stages = context, sink, {}

    def send(self, status, stage, stage_status, code, completed=None, total=None, **extra):
        if status not in ('installing','validating','waiting','failed','cancelled') or stage not in ('engine','client','download','prepare','verify','components'):
            raise Issue('invalid_event')
        if stage_status not in ('pending','active','completed','failed','cancelled','waiting'):
            raise Issue('invalid_event')
        progress = None
        if completed is not None: integer(completed)
        if total is not None: integer(total)
        if completed is not None and total and completed <= total:
            progress = completed/total
        labels={'engine':'Moteur GOG','client':'Connexion GOG','download':'Téléchargement','prepare':'Préparation','verify':'Vérification','components':'Composants'}
        row = {'id':stage,'label':labels[stage],'status':stage_status,'progress':progress}
        if completed is not None:row.update(completedUnits=completed,unit='bytes')
        if total is not None:row['totalUnits']=total
        if stage == 'verify' and completed is not None:row['unit']='verified-bytes'
        self.stages[stage]=row
        if status in ('failed','cancelled'):
            self.stages={key:dict(value,status=status) if value['status']=='active' else value for key,value in self.stages.items()}
        value = {'schema':1,'id':'gog:'+self.context.product+':'+self.context.job,
                 'gameId':'gog:'+self.context.product,'appId':self.context.product,'store':'gog',
                 'platform':'mac' if self.context.platform=='osx' else 'windows',
                 'runtimeId':'gog-mac' if self.context.platform=='osx' else 'gog-windows',
                 'source':'gog-direct','status':status,'code':code,'activeStage':stage,
                 'progress':None,'stages':[self.stages[key] for key in labels if key in self.stages],
                 'autoLaunch':False,'observed':False,'cancellable':True}
        if set(extra)-{'bytesDownloaded','bytesTotal','speedBytesPerSecond','transportBytes','terminal','requiresNativeValidation','retryable','resumePoint','validFiles','missingFiles','invalidFiles','planDigest'}:
            raise Issue('invalid_event')
        value.update(extra)
        self.sink(value)


class OwnedRoot:
    """Directory-FD authority for one managed product, account and platform."""
    def __init__(self, path, context):
        self.path, self.context, self.fd, self.lockfd = pathlib.Path(path), context, None, None

    @staticmethod
    def open_directory(path):
        path = pathlib.Path(path)
        if not path.is_absolute() or str(path) != os.path.normpath(str(path)):
            raise Issue('invalid_root')
        fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
        try:
            for part in path.parts[1:]:
                next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                os.close(fd); fd = next_fd
            return fd
        except OSError:
            os.close(fd);raise Issue('unsafe_root') from None

    @classmethod
    def create(cls, path, context):
        path = pathlib.Path(path)
        parent = cls.open_directory(path.parent)
        try:
            os.mkdir(path.name, mode=0o700, dir_fd=parent)
            fd = os.open(path.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
            try:
                value=os.fstat(fd)
                marker={'schema':1,'owner':context.owner,'product':context.product,'platform':context.platform,
                        'device':value.st_dev,'inode':value.st_ino}
                out=os.open(MARKER,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=fd)
                try:os.write(out,canonical(marker));os.fsync(out)
                finally:os.close(out)
            finally:os.close(fd)
        except OSError:
            raise Issue('root_create_failed') from None
        finally:os.close(parent)

    def __enter__(self):
        try:
            self.fd=self.open_directory(self.path);value=os.fstat(self.fd)
            if value.st_uid != os.geteuid() or value.st_mode & 0o077:
                raise Issue('foreign_root')
            self.root_identity=(value.st_dev,value.st_ino)
            fd=os.open(MARKER,os.O_RDONLY|os.O_NOFOLLOW,dir_fd=self.fd)
            try:
                m=os.fstat(fd)
                if not stat.S_ISREG(m.st_mode) or m.st_uid!=os.geteuid() or m.st_nlink!=1 or m.st_mode&0o077:
                    raise Issue('foreign_root')
                marker=decode(os.read(fd,4097),4096)
                self.marker_signature=(m.st_dev,m.st_ino,m.st_size,m.st_mtime_ns,m.st_ctime_ns)
            finally:os.close(fd)
            expected={'schema':1,'owner':self.context.owner,'product':self.context.product,'platform':self.context.platform,
                      'device':value.st_dev,'inode':value.st_ino}
            if marker!=expected:raise Issue('owner_mismatch')
            self.lockfd=os.open(LOCK,os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600,dir_fd=self.fd)
            lock=os.fstat(self.lockfd)
            if not stat.S_ISREG(lock.st_mode) or lock.st_uid!=os.geteuid() or lock.st_nlink!=1 or lock.st_mode&0o077:
                raise Issue('unsafe_lock')
            try:fcntl.flock(self.lockfd,fcntl.LOCK_EX|fcntl.LOCK_NB)
            except BlockingIOError:raise Issue('operation_busy',True,'verify') from None
            self.revalidate()
            return self
        except BaseException:
            self.close();raise

    def revalidate(self):
        fd=self.open_directory(self.path)
        try:
            value=os.fstat(fd)
            if (value.st_dev,value.st_ino)!=self.root_identity:raise Issue('root_changed')
            marker=os.stat(MARKER,dir_fd=fd,follow_symlinks=False)
            if (marker.st_dev,marker.st_ino,marker.st_size,marker.st_mtime_ns,marker.st_ctime_ns)!=self.marker_signature:
                raise Issue('owner_changed')
        finally:os.close(fd)

    @contextlib.contextmanager
    def parent(self,path,create=False):
        pieces=relative(path).split('/');fd=os.dup(self.fd)
        try:
            for part in pieces[:-1]:
                if create:
                    try:os.mkdir(part,0o700,dir_fd=fd)
                    except FileExistsError:pass
                child=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=fd)
                os.close(fd);fd=child
            yield fd,pieces[-1]
        except OSError as error:
            if isinstance(error,FileNotFoundError):raise
            raise Issue('unsafe_path') from None
        finally:os.close(fd)

    def checkpoint(self,plan,files,bytes_verified):
        self.revalidate();name='.playmelt-gog-checkpoint.'+uuid.uuid4().hex+'.tmp'
        value={'schema':1,'owner':plan.context.owner,'product':plan.context.product,'platform':plan.context.platform,
               'build':plan.build,'planDigest':plan.digest,'verifiedFiles':files,'verifiedBytes':bytes_verified}
        try:
            try:
                old=os.stat(CHECKPOINT,dir_fd=self.fd,follow_symlinks=False)
                if not stat.S_ISREG(old.st_mode) or old.st_uid!=os.geteuid() or old.st_nlink!=1 or old.st_mode&0o077:
                    raise Issue('unsafe_checkpoint')
            except FileNotFoundError:pass
            fd=os.open(name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=self.fd)
            try:os.write(fd,canonical(value));os.fsync(fd)
            finally:os.close(fd)
            self.revalidate();os.replace(name,CHECKPOINT,src_dir_fd=self.fd,dst_dir_fd=self.fd);os.fsync(self.fd)
        finally:
            try:os.unlink(name,dir_fd=self.fd)
            except FileNotFoundError:pass

    def close(self):
        if self.lockfd is not None:os.close(self.lockfd);self.lockfd=None
        if self.fd is not None:os.close(self.fd);self.fd=None

    def __exit__(self,*_):self.close()


def verify(root,plan,events,cancel,terminal=True,checkpoint=True):
    if root.context!=plan.context:raise Issue('plan_context_mismatch')
    total=sum(f.size for f in plan.files);processed=valid=missing=invalid=0;inventory=[];last_emit=time.monotonic()
    events.send('validating','verify','active','verifying',0,total)
    for item in plan.files:
        cancel.check();root.revalidate()
        try:
            with root.parent(item.path) as (parent,name):
                fd=os.open(name,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=parent)
                try:
                    before=os.fstat(fd)
                    if not stat.S_ISREG(before.st_mode) or before.st_nlink!=1:raise Issue('unsafe_file')
                    if before.st_size!=item.size:
                        invalid+=1;continue
                    content_valid=True
                    boundaries=item.chunks if item.algorithm=='chunks-md5' else ({'size':item.size,'md5':None},)
                    for boundary in boundaries:
                        digest=hashlib.new('md5' if item.algorithm=='chunks-md5' else item.algorithm)
                        remaining=boundary['size']
                        while remaining:
                            cancel.check();chunk=os.read(fd,min(65536,remaining))
                            if not chunk:raise Issue('file_changed',True,'verify')
                            digest.update(chunk);processed+=len(chunk);remaining-=len(chunk)
                            if time.monotonic()-last_emit>=0.1:
                                events.send('validating','verify','active','verifying',processed,total);last_emit=time.monotonic()
                        expected=boundary['md5'] if item.algorithm=='chunks-md5' else item.digest
                        if digest.hexdigest()!=expected:content_valid=False
                    after=os.fstat(fd)
                    if (before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns,before.st_ctime_ns)!=(after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns,after.st_ctime_ns):
                        raise Issue('file_changed',True,'verify')
                    actual=os.stat(name,dir_fd=parent,follow_symlinks=False)
                    if (actual.st_dev,actual.st_ino)!=(before.st_dev,before.st_ino):raise Issue('file_changed',True,'verify')
                    inventory.append((item.path,(after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns,after.st_ctime_ns)))
                    if content_valid:valid+=1
                    else:invalid+=1
                finally:os.close(fd)
        except FileNotFoundError:missing+=1
        except OSError:raise Issue('unsafe_file') from None
    cancel.check();root.revalidate()
    for path,signature in inventory:
        try:
            with root.parent(path) as (parent,name):
                value=os.stat(name,dir_fd=parent,follow_symlinks=False)
                if (value.st_dev,value.st_ino,value.st_size,value.st_mtime_ns,value.st_ctime_ns)!=signature:
                    raise Issue('file_changed',True,'verify')
        except OSError:raise Issue('file_changed',True,'verify') from None
    if checkpoint and not missing and not invalid:root.checkpoint(plan,valid,processed)
    events.send('waiting','verify','completed' if not missing and not invalid else 'waiting',
                'files_verified' if not missing and not invalid else 'repair_required',processed,total,
                validFiles=valid,missingFiles=missing,invalidFiles=invalid,planDigest=plan.digest,
                terminal=terminal,requiresNativeValidation=True,resumePoint='native-validation' if not missing and not invalid else 'verify')
    return {'validFiles':valid,'missingFiles':missing,'invalidFiles':invalid,'verifiedBytes':processed}
