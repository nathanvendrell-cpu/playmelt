# SPDX-License-Identifier: GPL-3.0-only
"""Missing-file V2 transfer core with an injected, authenticated chunk transport.

The real CDN/session adapter is deliberately not enabled by gog-worker.py yet.
This core never overwrites an existing path. It rehashes resumed files, bounds
retries and decompression, and publishes a verified file atomically with link(2).
Tests supply compressed bytes in memory, not a network or Galaxy simulator.
"""
from __future__ import annotations

import contextlib
import hashlib
import os
import stat
import time
import uuid
import zlib

from gog_worker_protocol import Issue,verify


def transfer_missing(root,plan,events,cancel,fetch_chunk,attempts=3,clock=time.monotonic):
    """fetch_chunk(chunk,cancel) yields bounded bytes; it never receives a token.

    Caller must hold OwnedRoot and an authenticated plan lease. A changed existing
    file is a conflict, not permission to replace a Galaxy or user installation.
    """
    if type(attempts) is not int or not 1<=attempts<=3:raise Issue('invalid_retry_policy')
    inspection=verify(root,plan,events,cancel,terminal=False,checkpoint=False)
    if inspection['invalidFiles']:raise Issue('existing_file_conflict',False,'verify')
    missing=[]
    for item in plan.files:
        try:
            with root.parent(item.path) as (parent,name):os.stat(name,dir_fd=parent,follow_symlinks=False)
        except FileNotFoundError:missing.append(item)
    if any(not item.chunks for item in missing):raise Issue('download_generation_unqualified')
    network_total=sum(chunk['compressedSize'] for item in missing for chunk in item.chunks)
    write_total=sum(item.size for item in missing)
    accepted=transport=written=0;started=clock()
    stage_name='.playmelt-gog-stage-'+uuid.uuid4().hex
    os.mkdir(stage_name,0o700,dir_fd=root.fd)
    stage=os.open(stage_name,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=root.fd)
    stage_identity=os.fstat(stage);owned={}
    def progress():
        elapsed=clock()-started
        events.send('installing','download','active' if accepted<network_total else 'completed','chunks_measured',accepted,network_total,
                    bytesDownloaded=accepted,bytesTotal=network_total,transportBytes=transport,
                    speedBytesPerSecond=transport/elapsed if elapsed>0 else None)
        events.send('installing','prepare','active','writes_measured',written,write_total)
    try:
        progress()
        for item in missing:
            cancel.check();root.revalidate()
            name=uuid.uuid4().hex
            fd=os.open(name,os.O_RDWR|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=stage)
            owned[name]=os.fstat(fd).st_ino
            try:
                for chunk in item.chunks:
                    offset=os.lseek(fd,0,os.SEEK_CUR)
                    for attempt in range(attempts):
                        cancel.check();compressed=hashlib.md5();content=hashlib.md5();count=produced=0
                        decoder=zlib.decompressobj()
                        try:
                            with contextlib.ExitStack() as sources:
                                stream=fetch_chunk(chunk,cancel)
                                if hasattr(stream,'close'):sources.callback(stream.close)
                                for part in stream:
                                    cancel.check()
                                    if not isinstance(part,bytes) or len(part)>1024*1024:raise Issue('chunk_stream_invalid')
                                    count+=len(part);transport+=len(part);compressed.update(part)
                                    if count>chunk['compressedSize']:raise Issue('chunk_checksum_failed',True,'download')
                                    while part:
                                        output=decoder.decompress(part,min(65536,chunk['size']-produced+1))
                                        produced+=len(output)
                                        if produced>chunk['size']:raise Issue('chunk_checksum_failed',True,'download')
                                        content.update(output)
                                        pending=output
                                        while pending:
                                            n=os.write(fd,pending);written+=n;pending=pending[n:]
                                        part=decoder.unconsumed_tail
                            # Do not call unbounded flush() on untrusted streams.
                            # A complete zlib stream must reach EOF through the
                            # bounded decompress loop above.
                            if count!=chunk['compressedSize'] or produced!=chunk['size'] or not decoder.eof or decoder.unused_data or compressed.hexdigest()!=chunk['compressedMd5'] or content.hexdigest()!=chunk['md5']:
                                raise Issue('chunk_checksum_failed',True,'download')
                            accepted+=chunk['compressedSize'];progress();break
                        except (Issue,zlib.error) as error:
                            os.ftruncate(fd,offset);os.lseek(fd,offset,os.SEEK_SET)
                            if isinstance(error,Issue) and (error.code=='cancelled' or not error.retryable):raise
                            if attempt+1==attempts:raise Issue('chunk_retries_exhausted',True,'download') from None
                os.fsync(fd)
                if os.fstat(fd).st_size!=item.size:raise Issue('file_checksum_failed')
                if item.algorithm!='chunks-md5':
                    os.lseek(fd,0,os.SEEK_SET);digest=hashlib.new(item.algorithm)
                    while True:
                        cancel.check();part=os.read(fd,65536)
                        if not part:break
                        digest.update(part)
                    if digest.hexdigest()!=item.digest:raise Issue('file_checksum_failed')
                root.revalidate();cancel.check()
                expected=os.fstat(fd);actual=os.stat(name,dir_fd=stage,follow_symlinks=False)
                if not stat.S_ISREG(actual.st_mode) or actual.st_nlink!=1 or actual.st_ino!=expected.st_ino:
                    raise Issue('staging_changed')
                with root.parent(item.path,create=True) as (parent,leaf):
                    try:os.link(name,leaf,src_dir_fd=stage,dst_dir_fd=parent,follow_symlinks=False)
                    except FileExistsError:raise Issue('publication_conflict',True,'verify') from None
                    except OSError:raise Issue('atomic_publication_failed',False,'verify') from None
                    actual=os.stat(leaf,dir_fd=parent,follow_symlinks=False)
                    if (actual.st_dev,actual.st_ino)!=(expected.st_dev,expected.st_ino):raise Issue('publication_changed')
                    os.fsync(parent)
                os.unlink(name,dir_fd=stage);owned.pop(name)
            finally:os.close(fd)
        events.send('installing','prepare','completed','writes_finished',written,write_total)
        return verify(root,plan,events,cancel)
    except Issue as error:
        status='cancelled' if error.code=='cancelled' else 'failed'
        events.send(status,'download',status,error.code,terminal=True,retryable=error.retryable,resumePoint=error.resume_point)
        raise
    finally:
        for name,inode in owned.items():
            try:
                value=os.stat(name,dir_fd=stage,follow_symlinks=False)
                if value.st_ino==inode:os.unlink(name,dir_fd=stage)
            except FileNotFoundError:pass
        os.close(stage)
        try:
            value=os.stat(stage_name,dir_fd=root.fd,follow_symlinks=False)
            if (value.st_dev,value.st_ino)==(stage_identity.st_dev,stage_identity.st_ino):os.rmdir(stage_name,dir_fd=root.fd)
        except FileNotFoundError:pass
