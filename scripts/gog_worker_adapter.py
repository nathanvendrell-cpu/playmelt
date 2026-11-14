# SPDX-License-Identifier: GPL-3.0-only
"""Pinned upstream adapters. This is not a Galaxy-session importer.

Only Python source verified against the pinned Git blobs is imported. Tokens
stay in memory and leave on the dedicated secret channel, never progress/stdout.
The production CDN/download and native Keychain/OAuth UI are not connected here.
"""
from __future__ import annotations

import hashlib
import importlib
import importlib.abc
import importlib.util
import json
import math
import os
import pathlib
import re
import stat
import sys
import time
import types
import urllib.parse

from gog_worker_protocol import Context, Issue, Plan, canonical, decode, identifier, integer, relative

REVISION='6c6ef53fd4965d8d9b943c73d9400fe55eadc6ba'
PIN_SHA256='33dcc4c760a51d712cf792812f61f6e53122320c1bffe80e8937961700b7b91e'


class PinnedSource(importlib.abc.MetaPathFinder,importlib.abc.Loader):
    def __init__(self,root):
        self.sources={}
        root=pathlib.Path(root)
        if not root.is_absolute() or root.resolve()!=root:raise Issue('dependency_unsafe')
        def read(name,limit):
            path=root/name
            if path.resolve()!=path:raise Issue('dependency_unsafe')
            fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
            try:
                s=os.fstat(fd)
                if not stat.S_ISREG(s.st_mode) or s.st_uid!=os.geteuid() or s.st_size>limit:
                    raise Issue('dependency_unsafe')
                data=os.read(fd,limit+1)
                if len(data)>limit:raise Issue('dependency_unsafe')
                return data
            finally:os.close(fd)
        try:
            data=read('PLAYMELT_SOURCE_PIN.json',65536)
            if hashlib.sha256(data).hexdigest()!=PIN_SHA256:raise Issue('dependency_mismatch')
            pin=decode(data,65536)
            if pin['revision']!=REVISION:raise Issue('dependency_mismatch')
            for name,expected in pin['files'].items():
                relative(name);data=read(name,1024*1024)
                if hashlib.sha256(data).hexdigest()!=expected:raise Issue('dependency_mismatch')
                if name.startswith('gogdl/') and name.endswith('.py'):
                    package=name.endswith('/__init__.py')
                    module=(name[:-12] if package else name[:-3]).replace('/','.')
                    self.sources[module]=(data,package)
        except (OSError,KeyError,TypeError):raise Issue('dependency_unavailable') from None

    def find_spec(self,fullname,path=None,target=None):
        if fullname in self.sources:
            return importlib.util.spec_from_loader(fullname,self,is_package=self.sources[fullname][1])
        if any(name.startswith(fullname+'.') for name in self.sources):
            return importlib.util.spec_from_loader(fullname,self,is_package=True)
        return None

    def create_module(self,spec):return None

    def exec_module(self,module):
        if module.__name__ not in self.sources:
            module.__path__=[];return
        data,package=self.sources[module.__name__]
        module.__file__='<verified-gogdl>/'+module.__name__.replace('.','/')+('/__init__.py' if package else '.py')
        if package:module.__path__=[]
        exec(compile(data,module.__file__,'exec'),module.__dict__)

    def install(self):
        if any(n=='gogdl' or n.startswith('gogdl.') for n in sys.modules):
            raise Issue('dependency_already_loaded')
        sys.meta_path.insert(0,self)


def normalize_manifest(context,build,manifest):
    """Map genuine gogdl v1/v2 file objects to a small content-only plan.

    Manifests are obtained by an authenticated planner, not accepted as proof of
    ownership. No URL, client credential or arbitrary metadata reaches events.
    Unsupported links/support files stop qualification rather than being skipped.
    """
    if str(manifest.product_id)!=context.product:raise Issue('plan_context_mismatch')
    platform=getattr(manifest,'platform',None) or manifest.data.get('platform')
    if platform!=context.platform:raise Issue('plan_context_mismatch')
    manifest_build=manifest.data.get('buildId')
    if manifest_build is not None and str(manifest_build)!=build:raise Issue('plan_context_mismatch')
    rows=[]
    for item in manifest.files:
        if hasattr(item,'target') or 'support' in getattr(item,'flags',[]):
            raise Issue('manifest_feature_unqualified')
        chunks=getattr(item,'chunks',None)
        size=sum(integer(c['size']) for c in chunks) if chunks is not None else integer(item.size)
        digest=getattr(item,'sha256',None) or getattr(item,'md5',None) or getattr(item,'hash',None)
        if digest and re.fullmatch('[a-f0-9]{64}',digest):algorithm='sha256'
        elif digest and re.fullmatch('[a-f0-9]{32}',digest):algorithm='md5'
        elif chunks:
            algorithm='chunks-md5';digest=hashlib.sha256(canonical([{'size':c['size'],'md5':c['md5']} for c in chunks])).hexdigest()
        else:raise Issue('unsupported_digest')
        row={'path':relative(item.path),'size':size,'algorithm':algorithm,'digest':digest}
        if chunks is not None:row['chunks']=chunks
        rows.append(row)
    return Plan.parse(context,{'productID':context.product,'platform':context.platform,'buildID':build,'files':rows})


class AuthHTTP:
    """No .netrc/proxy inheritance, redirects, request logging, or raw errors."""
    def __init__(self):
        import requests
        self.session=requests.Session();self.session.trust_env=False;self.session.auth=lambda r:r

    def get(self,url,timeout=10):
        parsed=urllib.parse.urlsplit(url)
        if parsed.scheme!='https' or parsed.hostname!='auth.gog.com' or parsed.path!='/token' or parsed.username or parsed.password:
            raise Issue('auth_endpoint_rejected')
        try:
            response=self.session.get(url,timeout=(5,min(timeout,15)),allow_redirects=False,stream=True)
            try:
                data=bytearray()
                for part in response.iter_content(16384):
                    data.extend(part)
                    if len(data)>65536:raise Issue('auth_response_rejected')
                body=decode(bytes(data),65536) if response.status_code==200 else {}
                return types.SimpleNamespace(ok=response.status_code==200,status_code=response.status_code,json=lambda:body)
            finally:response.close()
        except Issue:raise
        except Exception:raise Issue('auth_transport_failed',True,'session') from None

    def close(self):self.session.close()


def bound_auth_manager(module,context,lease,secret_sink,http=None):
    """Patch the upstream storage boundary, not its OAuth client credentials.

    Native lease contract: owner + generation + expected accountID + credentials.
    The sink must CAS Keychain and acknowledge the new generation before return.
    """
    if lease.get('owner')!=context.owner or type(lease.get('generation')) is not int or lease.get('generation')!=context.generation:
        raise Issue('auth_owner_mismatch')
    account=identifier(lease.get('accountID'))
    credentials=lease.get('credentials')
    def validate(data):
        if not isinstance(data,dict) or len(data)>32:raise Issue('auth_response_rejected')
        profile=data.get(module.CLIENT_ID)
        if not isinstance(profile,dict) or str(profile.get('user_id'))!=account:
            raise Issue('auth_account_mismatch')
        for entry in data.values():
            if not isinstance(entry,dict) or str(entry.get('user_id'))!=account:raise Issue('auth_account_mismatch')
            for field in ('access_token','refresh_token'):
                value=entry.get(field)
                if not isinstance(value,str) or not 0<len(value)<=16384:raise Issue('auth_response_rejected')
            expiry=entry.get('expires_in');logged=entry.get('loginTime')
            if type(expiry) not in (int,float) or type(logged) not in (int,float) or not math.isfinite(expiry) or not math.isfinite(logged) or expiry<=0 or logged<0:
                raise Issue('auth_response_rejected')
        if len(canonical(data))>65536:raise Issue('auth_response_rejected')
    validate(credentials)
    class MemoryAuth(module.AuthorizationManager):
        def __init__(self):
            # Do not call upstream __init__: it opens the on-disk config.
            import logging
            self.config_path=None;self.credentials_data=json.loads(canonical(credentials))
            self.logger=logging.getLogger('GOG_PRIVATE_AUTH');self.session=http or AuthHTTP()
            self.lease_generation=context.generation

        def _AuthorizationManager__read_config(self):pass

        def _AuthorizationManager__write_config(self):
            validate(self.credentials_data)
            payload={'schema':1,'owner':context.owner,'accountID':account,'previousGeneration':self.lease_generation,
                     'generation':self.lease_generation+1,'credentials':self.credentials_data}
            secret_sink(payload)  # must fail if native selection/generation changed
            self.lease_generation+=1

        def handle_cli(self,*_):raise Issue('auth_cli_forbidden')

        def close(self):
            if hasattr(self.session,'close'):self.session.close()
            self.credentials_data.clear()
    return MemoryAuth()


def progress_class(upstream,events,clock=time.monotonic):
    """Real transport bytes and disk writes remain distinct; no parsed log %."""
    class PrivateProgress(upstream):
        def __init__(self,*args,**kwargs):
            super().__init__(*args,**kwargs)
            self.private_last=clock();self.private_downloaded=0

        def print_progressbar(self):
            now=clock();elapsed=now-self.private_last
            downloaded=integer(self.downloaded);written=integer(self.written_total);total=integer(self.total)
            speed=(downloaded-self.private_downloaded)/elapsed if elapsed>0 and downloaded>=self.private_downloaded else None
            events.send('installing','download','active' if downloaded>self.private_downloaded else 'waiting',
                        'transport_measured',downloaded,None,bytesDownloaded=downloaded,bytesTotal=None,
                        transportBytes=downloaded,speedBytesPerSecond=speed)
            events.send('installing','prepare','active','writes_measured',written,total)
            self.private_last,self.private_downloaded=now,downloaded
    return PrivateProgress


def production_download(*_):
    # CDN selection, symlink/support tasks, publication and native prerequisites
    # need independent qualification before this becomes a user-facing engine.
    raise Issue('direct_download_integration_required',False,'plan')
