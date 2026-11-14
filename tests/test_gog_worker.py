# SPDX-License-Identifier: GPL-3.0-only
"""Inert fixtures only: no account, OAuth UI, CDN, Galaxy, game or Wine."""
import contextlib
import dataclasses
import errno
import hashlib
import importlib
import io
import json
import os
import pathlib
import queue
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest
import uuid
import zlib
from unittest import mock

sys.dont_write_bytecode=True
PROJECT=pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0,str(PROJECT/'scripts'))
from gog_worker_protocol import (CHECKPOINT,LOCK,MARKER,Cancellation,Context,Events,Issue,
                                 OwnedRoot,Plan,canonical,decode,private_pipe,verify)
from gog_worker_adapter import (PinnedSource,bound_auth_manager,normalize_manifest,
                                production_download,progress_class)
from gog_worker_transfer import transfer_missing

PIN=PROJECT/'Dependencies.noindex/GOG-gogdl-1.4.0-6c6ef53'
PAYLOAD=b'inert content\x00with real bytes\n'


class GOGWorkerTests(unittest.TestCase):
    processes=[]

    @classmethod
    def setUpClass(cls):
        cls.network_guard=contextlib.ExitStack()
        cls.network_guard.enter_context(mock.patch.object(socket.socket,'connect',side_effect=AssertionError('network forbidden in fixture')))
        cls.network_guard.enter_context(mock.patch.object(socket,'getaddrinfo',side_effect=AssertionError('DNS forbidden in fixture')))
        cls.pinned=PinnedSource(PIN);cls.pinned.install()
        cls.v1=importlib.import_module('gogdl.dl.objects.v1')
        cls.v2=importlib.import_module('gogdl.dl.objects.v2')
        cls.lang=importlib.import_module('gogdl.languages').Language.parse('en-US')
        cls.auth=importlib.import_module('gogdl.auth')

    @classmethod
    def tearDownClass(cls):
        cls.network_guard.close()
        sys.meta_path.remove(cls.pinned)
        for name in list(sys.modules):
            if name=='gogdl' or name.startswith('gogdl.'):del sys.modules[name]
        for pid in cls.processes:
            try:os.kill(pid,0)
            except ProcessLookupError:continue
            raise AssertionError('owned child was not reaped')

    def setUp(self):
        self.tmp=pathlib.Path(tempfile.mkdtemp(prefix='gog-worker-fixture-',dir=PROJECT/'Products.noindex'))
        self.addCleanup(shutil.rmtree,self.tmp)
        self.context=Context('a'*64,'10','osx',str(uuid.uuid4()),3)
        self.rows=[];self.events=Events(self.context,self.rows.append)

    def plan(self,paths=None,context=None):
        context=context or self.context
        rows=[{'path':path,'size':len(data),'algorithm':'sha256','digest':hashlib.sha256(data).hexdigest()} for path,data in (paths or {'bundle/game.bin':PAYLOAD}).items()]
        return Plan.parse(context,{'productID':context.product,'platform':context.platform,'buildID':'123','files':rows})

    def root(self,context=None,files=None,name='owned'):
        context=context or self.context;root=self.tmp/name;OwnedRoot.create(root,context)
        for path,data in (files or {'bundle/game.bin':PAYLOAD}).items():
            target=root/path;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data)
        return root

    def issue(self,code,fn):
        with self.assertRaises(Issue) as caught:fn()
        self.assertEqual(caught.exception.code,code)

    def test_json_and_identity_are_strict(self):
        for data in (b'{"x":1,"x":2}',b'{"x":NaN}',b'[]',b'{}'*100):
            with self.subTest(dataLength=len(data)),self.assertRaises(Issue):decode(data)
        value={'accountOwner':'a'*64,'productID':'10','platform':'osx','jobID':self.context.job,'generation':3}
        self.assertEqual(Context.parse(value),self.context)
        for field,bad in [('accountOwner','private-account'),('productID','../10'),('platform','mac'),('generation',True),('jobID','not-uuid')]:
            with self.subTest(field=field),self.assertRaises(Issue):Context.parse(dict(value,**{field:bad}))

    def test_plan_paths_collisions_and_counters(self):
        for paths in ({'../escape':PAYLOAD},{'/absolute':PAYLOAD},{'a\\b':PAYLOAD},{'C:file':PAYLOAD},{'.playmelt-gog-owner.json':PAYLOAD},{'A':PAYLOAD,'a':PAYLOAD},{'a':PAYLOAD,'a/b':PAYLOAD}):
            with self.subTest(paths=list(paths)),self.assertRaises(Issue):self.plan(paths)
        self.assertNotEqual(self.plan().digest,self.plan(context=dataclasses.replace(self.context,owner='b'*64)).digest)

    def test_real_hash_and_checkpoint_have_no_paths_or_auth(self):
        root=self.root();extra=root/'untouched.extra';extra.write_bytes(b'preserve extra')
        with OwnedRoot(root,self.context) as owned:
            result=verify(owned,self.plan(),self.events,Cancellation())
        self.assertEqual(result,{'validFiles':1,'missingFiles':0,'invalidFiles':0,'verifiedBytes':len(PAYLOAD)})
        self.assertEqual(extra.read_bytes(),b'preserve extra')
        checkpoint=(root/CHECKPOINT).read_bytes()
        self.assertNotIn(b'bundle/',checkpoint);self.assertNotIn(str(root).encode(),checkpoint)
        self.assertLess(len(checkpoint),4096)
        self.assertEqual(self.rows[-1]['status'],'waiting')
        self.assertTrue(self.rows[-1]['requiresNativeValidation'])
        self.assertNotIn('launch-ready',canonical(self.rows[-1]).decode())

    def test_resume_rehashes_corrupted_bytes_instead_of_trusting_checkpoint(self):
        root=self.root();plan=self.plan()
        with OwnedRoot(root,self.context) as owned:verify(owned,plan,self.events,Cancellation())
        original=(root/CHECKPOINT).read_bytes();target=root/'bundle/game.bin';target.write_bytes(b'x'*len(PAYLOAD))
        with OwnedRoot(root,self.context) as owned:result=verify(owned,plan,self.events,Cancellation())
        self.assertEqual(result['invalidFiles'],1);self.assertEqual(result['validFiles'],0)
        self.assertEqual((root/CHECKPOINT).read_bytes(),original)
        self.assertEqual(target.read_bytes(),b'x'*len(PAYLOAD))
        self.assertEqual(self.rows[-1]['code'],'repair_required')

    def test_missing_truncated_and_zero_byte_files(self):
        root=self.root();(root/'bundle/game.bin').write_bytes(b'short')
        plan=self.plan({'bundle/game.bin':PAYLOAD,'missing.bin':b'missing','zero.bin':b''})
        (root/'zero.bin').write_bytes(b'')
        with OwnedRoot(root,self.context) as owned:result=verify(owned,plan,self.events,Cancellation())
        self.assertEqual((result['validFiles'],result['missingFiles'],result['invalidFiles']),(1,1,1))
        self.assertFalse((root/CHECKPOINT).exists())

    def test_wrong_owner_platform_and_copied_marker_are_refused(self):
        root=self.root()
        other=dataclasses.replace(self.context,owner='b'*64)
        self.issue('owner_mismatch',lambda:OwnedRoot(root,other).__enter__())
        self.issue('owner_mismatch',lambda:OwnedRoot(root,dataclasses.replace(self.context,platform='windows')).__enter__())
        copied=self.tmp/'copied';shutil.copytree(root,copied)
        self.issue('owner_mismatch',lambda:OwnedRoot(copied,self.context).__enter__())
        with OwnedRoot(root,self.context) as owned:
            self.issue('plan_context_mismatch',lambda:verify(owned,self.plan(context=other),self.events,Cancellation()))

    def test_foreign_permissions_and_concurrent_operation(self):
        root=self.root()
        with OwnedRoot(root,self.context):
            self.issue('operation_busy',lambda:OwnedRoot(root,self.context).__enter__())
        os.chmod(root,0o755)
        self.issue('foreign_root',lambda:OwnedRoot(root,self.context).__enter__())

    def test_symlink_root_marker_lock_parent_and_file_are_refused(self):
        root=self.root();alias=self.tmp/'alias';alias.symlink_to(root,target_is_directory=True)
        self.issue('unsafe_root',lambda:OwnedRoot(alias,self.context).__enter__())
        for name in (MARKER,LOCK):
            path=root/name
            if path.exists():path.unlink()
            path.symlink_to(root/'bundle/game.bin')
            with self.assertRaises((Issue,OSError)):OwnedRoot(root,self.context).__enter__()
            path.unlink()
            if name==MARKER:
                # Recreate only the task's fixture, never an existing installation.
                shutil.rmtree(root);root=self.root()
        file=root/'bundle/game.bin';file.unlink();file.symlink_to(root/'extra')
        (root/'extra').write_bytes(PAYLOAD)
        with OwnedRoot(root,self.context) as owned:
            self.issue('unsafe_path',lambda:verify(owned,self.plan(),self.events,Cancellation()))
        file.unlink();(root/'bundle').rmdir();(root/'bundle').symlink_to(self.tmp,target_is_directory=True)
        with OwnedRoot(root,self.context) as owned:
            self.issue('unsafe_path',lambda:verify(owned,self.plan(),self.events,Cancellation()))

    def test_hardlink_and_checkpoint_symlink_are_refused(self):
        root=self.root();os.link(root/'bundle/game.bin',root/'second-link')
        with OwnedRoot(root,self.context) as owned:
            self.issue('unsafe_file',lambda:verify(owned,self.plan(),self.events,Cancellation()))
        (root/'second-link').unlink();(root/CHECKPOINT).symlink_to(root/'bundle/game.bin')
        before=(root/'bundle/game.bin').read_bytes()
        with OwnedRoot(root,self.context) as owned:
            self.issue('unsafe_checkpoint',lambda:verify(owned,self.plan(),self.events,Cancellation()))
        self.assertEqual((root/'bundle/game.bin').read_bytes(),before)
        self.assertFalse(any(p.name.endswith('.tmp') for p in root.iterdir()))

    def test_root_and_owner_changes_fail_closed(self):
        root=self.root()
        with OwnedRoot(root,self.context) as owned:
            marker=root/MARKER;marker.write_bytes(marker.read_bytes()+b' ')
            self.issue('owner_changed',owned.revalidate)
        shutil.rmtree(root);root=self.root()
        with OwnedRoot(root,self.context) as owned:
            root.rename(self.tmp/'moved');root.mkdir(mode=0o700)
            self.issue('root_changed',owned.revalidate)

    def test_file_replacement_during_hash_is_detected(self):
        root=self.root();target=root/'bundle/game.bin';actual=os.read;changed=False
        def read(fd,size):
            nonlocal changed
            data=actual(fd,size)
            if not changed and data==PAYLOAD:
                changed=True;target.unlink();target.write_bytes(PAYLOAD)
            return data
        with OwnedRoot(root,self.context) as owned,mock.patch('gog_worker_protocol.os.read',side_effect=read):
            self.issue('file_changed',lambda:verify(owned,self.plan(),self.events,Cancellation()))
        self.assertFalse((root/CHECKPOINT).exists())

    def test_cancellation_keeps_files_and_never_commits(self):
        root=self.root();cancel=Cancellation();cancel.cancelled=True
        before=(root/'bundle/game.bin').read_bytes()
        with OwnedRoot(root,self.context) as owned:
            self.issue('cancelled',lambda:verify(owned,self.plan(),self.events,cancel))
        self.assertEqual((root/'bundle/game.bin').read_bytes(),before)
        self.assertFalse((root/CHECKPOINT).exists())
        r,w=os.pipe()
        try:
            os.close(w);w=None
            self.issue('cancelled',Cancellation(r).check)
        finally:os.close(r)

    def test_pinned_source_mismatch_and_symlink_refused(self):
        copied=self.tmp/'source';shutil.copytree(PIN,copied)
        source=copied/'gogdl/args.py';source.write_bytes(source.read_bytes()+b'\n# changed\n')
        self.issue('dependency_mismatch',lambda:PinnedSource(copied))
        alias=self.tmp/'source-alias';alias.symlink_to(PIN,target_is_directory=True)
        self.issue('dependency_unsafe',lambda:PinnedSource(alias))

    def native_manifest(self,platform='osx',chunks_only=False):
        chunk={'size':len(PAYLOAD),'compressedSize':len(zlib.compress(PAYLOAD)),'md5':hashlib.md5(PAYLOAD).hexdigest(),'compressedMd5':hashlib.md5(zlib.compress(PAYLOAD)).hexdigest()}
        item={'type':'DepotFile','path':'bundle/game.bin','chunks':[chunk]}
        if not chunks_only:item['md5']=hashlib.md5(PAYLOAD).hexdigest()
        depot={'depot':{'items':[item]}}
        class Session:
            def get(self,*_,**__):return types.SimpleNamespace(ok=True,content=zlib.compress(canonical(depot)),headers={})
        meta={'version':2,'platform':platform,'baseProductId':'10','buildId':'123','installDirectory':'Fixture',
              'depots':[{'languages':['*'],'productId':'10','manifest':'a'*32,'size':len(PAYLOAD),'compressedSize':len(zlib.compress(PAYLOAD))}]}
        manifest=self.v2.Manifest(meta,self.lang,[],types.SimpleNamespace(session=Session()),False)
        manifest.get_files();return manifest

    def test_actual_pinned_v2_osx_and_windows_manifest_parsing(self):
        for platform in ('osx','windows'):
            context=dataclasses.replace(self.context,platform=platform)
            plan=normalize_manifest(context,'123',self.native_manifest(platform))
            root=self.root(context=context,name=platform)
            with OwnedRoot(root,context) as owned:result=verify(owned,plan,Events(context,self.rows.append),Cancellation())
            self.assertEqual(result['validFiles'],1)
        self.issue('plan_context_mismatch',lambda:normalize_manifest(self.context,'123',self.native_manifest('windows')))
        self.issue('plan_context_mismatch',lambda:normalize_manifest(self.context,'999',self.native_manifest()))

    def test_pinned_v2_chunk_hashes_work_without_whole_file_digest(self):
        manifest=self.native_manifest(chunks_only=True);plan=normalize_manifest(self.context,'123',manifest)
        self.assertEqual(plan.files[0].algorithm,'chunks-md5')
        root=self.root()
        with OwnedRoot(root,self.context) as owned:self.assertEqual(verify(owned,plan,self.events,Cancellation())['validFiles'],1)
        (root/'bundle/game.bin').write_bytes(b'x'*len(PAYLOAD))
        with OwnedRoot(root,self.context) as owned:self.assertEqual(verify(owned,plan,self.events,Cancellation())['invalidFiles'],1)

    def test_actual_pinned_v1_manifest_and_unqualified_features(self):
        data={'version':1,'product':{'rootGameID':'10','timestamp':'fixture','installDirectory':'Fixture','depots':[{'gameIDs':['10'],'languages':['Neutral'],'size':len(PAYLOAD),'manifest':'a'*32}]}}
        class Session:
            def get(self,*_,**__):return types.SimpleNamespace(ok=True,json=lambda:{'depot':{'files':[{'path':'bundle/game.bin','size':len(PAYLOAD),'hash':hashlib.md5(PAYLOAD).hexdigest()}]}})
        manifest=self.v1.Manifest('osx',data,self.lang,[],types.SimpleNamespace(session=Session()),False)
        manifest.get_files();plan=normalize_manifest(self.context,'123',manifest)
        root=self.root()
        with OwnedRoot(root,self.context) as owned:self.assertEqual(verify(owned,plan,self.events,Cancellation())['validFiles'],1)
        manifest.files[0].flags=['support']
        self.issue('manifest_feature_unqualified',lambda:normalize_manifest(self.context,'123',manifest))

    def lease(self):
        return {'owner':self.context.owner,'generation':3,'accountID':'12','credentials':{self.auth.CLIENT_ID:{'user_id':'12','access_token':'FIXTURE_AUTH_SENTINEL','refresh_token':'FIXTURE_REFRESH_SENTINEL','expires_in':1,'loginTime':0}}}

    def http(self,user='12'):
        return types.SimpleNamespace(get=lambda *_,**__:types.SimpleNamespace(ok=True,json=lambda:{'user_id':user,'access_token':'FIXTURE_NEW_SENTINEL','refresh_token':'FIXTURE_ROTATED_SENTINEL','expires_in':3600}),close=lambda:None)

    def test_refresh_is_memory_only_and_uses_dedicated_cas_sink(self):
        secrets=[];out=io.StringIO()
        with mock.patch('builtins.open',side_effect=AssertionError('auth disk access forbidden')),contextlib.redirect_stdout(out):
            manager=bound_auth_manager(self.auth,self.context,self.lease(),secrets.append,self.http())
            try:
                result=manager.get_credentials()
                self.assertTrue(result['access_token']=='FIXTURE_NEW_SENTINEL')
                self.issue('auth_cli_forbidden',lambda:manager.handle_cli(None,None))
            finally:manager.close()
        self.assertEqual(out.getvalue(),'')
        self.assertEqual((secrets[0]['previousGeneration'],secrets[0]['generation']),(3,4))
        self.assertNotIn('SENTINEL',canonical(self.rows).decode())

    def test_refresh_owner_generation_account_and_commit_rejection(self):
        lease=self.lease();lease['owner']='b'*64
        self.issue('auth_owner_mismatch',lambda:bound_auth_manager(self.auth,self.context,lease,lambda _:None,self.http()))
        lease=self.lease();lease['generation']=2
        self.issue('auth_owner_mismatch',lambda:bound_auth_manager(self.auth,self.context,lease,lambda _:None,self.http()))
        sink=[];manager=bound_auth_manager(self.auth,self.context,self.lease(),sink.append,self.http('99'))
        try:self.issue('auth_account_mismatch',manager.get_credentials)
        finally:manager.close()
        self.assertEqual(sink,[])
        def reject(_):raise Issue('auth_commit_rejected')
        manager=bound_auth_manager(self.auth,self.context,self.lease(),reject,self.http())
        try:self.issue('auth_commit_rejected',manager.get_credentials);self.assertEqual(manager.lease_generation,3)
        finally:manager.close()

    def test_network_and_disk_progress_are_distinct_and_measured(self):
        upstream=importlib.import_module('gogdl.dl.progressbar').ProgressBar
        clock=iter([0,2,4,6]);cls=progress_class(upstream,self.events,lambda:next(clock))
        value=cls(100,queue.Queue(),queue.Queue())
        value.downloaded=20;value.written_total=50;value.print_progressbar()
        dl,write=self.rows[-2:]
        self.assertIsNone(next(s for s in dl['stages'] if s['id']=='download')['progress']);self.assertIsNone(dl['bytesTotal'])
        self.assertEqual(dl['speedBytesPerSecond'],10)
        self.assertEqual(next(s for s in write['stages'] if s['id']=='prepare')['progress'],0.5)
        value.written_total=150;value.print_progressbar()
        self.assertIsNone(next(s for s in self.rows[-1]['stages'] if s['id']=='prepare')['progress'])
        self.assertEqual(next(s for s in self.rows[-2]['stages'] if s['id']=='download')['status'],'waiting')
        self.assertFalse(value.is_alive())

    def transfer_plan(self):
        data=b'missing fixture file with two independently verified chunks'
        parts=[data[:17],data[17:]];compressed=[zlib.compress(p) for p in parts]
        chunks=[{'size':len(p),'compressedSize':len(z),'md5':hashlib.md5(p).hexdigest(),'compressedMd5':hashlib.md5(z).hexdigest()} for p,z in zip(parts,compressed)]
        plan=Plan.parse(self.context,{'productID':'10','platform':'osx','buildID':'123','files':[
            {'path':'bundle/game.bin','size':len(PAYLOAD),'algorithm':'sha256','digest':hashlib.sha256(PAYLOAD).hexdigest()},
            {'path':'new/missing.bin','size':len(data),'algorithm':'sha256','digest':hashlib.sha256(data).hexdigest(),'chunks':chunks}]})
        return plan,data,dict(zip([c['compressedMd5'] for c in chunks],compressed))

    def test_transfer_missing_real_bytes_atomic_publish_and_resume_without_refetch(self):
        root=self.root();plan,data,chunks=self.transfer_plan();called=[]
        def fetch(chunk,cancel):called.append(chunk['compressedMd5']);return iter([chunks[chunk['compressedMd5']]])
        with OwnedRoot(root,self.context) as owned:result=transfer_missing(owned,plan,self.events,Cancellation(),fetch)
        self.assertEqual(result['validFiles'],2);self.assertEqual((root/'new/missing.bin').read_bytes(),data)
        self.assertEqual((root/'bundle/game.bin').read_bytes(),PAYLOAD);self.assertEqual(len(called),2)
        transport=[row for row in self.rows if row['code']=='chunks_measured'][-1]
        self.assertEqual(transport['bytesDownloaded'],sum(len(z) for z in chunks.values()))
        self.assertEqual(next(s for s in transport['stages'] if s['id']=='download')['progress'],1)
        self.assertEqual(self.rows[-1]['status'],'waiting');self.assertTrue(self.rows[-1]['requiresNativeValidation'])
        self.assertEqual({s['id']:s['status'] for s in self.rows[-1]['stages']},{'download':'completed','prepare':'completed','verify':'completed'})
        with OwnedRoot(root,self.context) as owned:transfer_missing(owned,plan,self.events,Cancellation(),lambda *_:self.fail('verified resume must not refetch'))
        self.assertFalse(any(p.name.startswith('.playmelt-gog-stage-') for p in root.iterdir()))

    def test_transfer_retry_is_bounded_and_raw_traffic_is_not_logical_progress(self):
        root=self.root();plan,data,chunks=self.transfer_plan();calls={}
        def fetch(chunk,cancel):
            key=chunk['compressedMd5'];calls[key]=calls.get(key,0)+1
            return iter([b'invalid zlib' if calls[key]==1 else chunks[key]])
        with OwnedRoot(root,self.context) as owned:transfer_missing(owned,plan,self.events,Cancellation(),fetch)
        measured=[row for row in self.rows if row['code']=='chunks_measured'][-1]
        self.assertEqual(measured['bytesDownloaded'],measured['bytesTotal'])
        self.assertGreater(measured['transportBytes'],measured['bytesTotal'])
        self.assertEqual(set(calls.values()),{2})
        (root/'new/missing.bin').unlink();attempts=[]
        def broken(chunk,cancel):attempts.append(1);return iter([b'broken'])
        with OwnedRoot(root,self.context) as owned:self.issue('chunk_retries_exhausted',lambda:transfer_missing(owned,plan,self.events,Cancellation(),broken))
        self.assertEqual(len(attempts),3);self.assertFalse((root/'new/missing.bin').exists())
        self.assertFalse(any(s['status']=='active' for s in self.rows[-1]['stages']))
        self.assertFalse(any(p.name.startswith('.playmelt-gog-stage-') for p in root.iterdir()))

    def test_transfer_never_overwrites_existing_different_or_raced_file(self):
        root=self.root();plan,data,chunks=self.transfer_plan();target=root/'new/missing.bin'
        target.parent.mkdir();target.write_bytes(b'different')
        with OwnedRoot(root,self.context) as owned:self.issue('existing_file_conflict',lambda:transfer_missing(owned,plan,self.events,Cancellation(),lambda *_:self.fail('no fetch on conflict')))
        self.assertEqual(target.read_bytes(),b'different');target.unlink()
        def raced(chunk,cancel):target.write_bytes(b'concurrent writer');return iter([chunks[chunk['compressedMd5']]])
        with OwnedRoot(root,self.context) as owned:self.issue('publication_conflict',lambda:transfer_missing(owned,plan,self.events,Cancellation(),raced))
        self.assertEqual(target.read_bytes(),b'concurrent writer')

    def test_transfer_exdev_cancel_and_inflation_are_safe(self):
        root=self.root();plan,data,chunks=self.transfer_plan()
        fetch=lambda chunk,cancel:iter([chunks[chunk['compressedMd5']]])
        with OwnedRoot(root,self.context) as owned,mock.patch('gog_worker_transfer.os.link',side_effect=OSError(errno.EXDEV,'fixture')):
            self.issue('atomic_publication_failed',lambda:transfer_missing(owned,plan,self.events,Cancellation(),fetch))
        self.assertFalse((root/'new/missing.bin').exists())
        cancel=Cancellation()
        def cancelled(chunk,_):cancel.cancelled=True;return iter([chunks[chunk['compressedMd5']]])
        with OwnedRoot(root,self.context) as owned:self.issue('cancelled',lambda:transfer_missing(owned,plan,self.events,cancel,cancelled))
        def inflated(chunk,_):return iter([zlib.compress(b'x'*100000)])
        with OwnedRoot(root,self.context) as owned:self.issue('chunk_retries_exhausted',lambda:transfer_missing(owned,plan,self.events,Cancellation(),inflated))
        self.assertFalse((root/'new/missing.bin').exists())
        self.assertEqual((root/'bundle/game.bin').read_bytes(),PAYLOAD)
        self.assertFalse(any(p.name.startswith('.playmelt-gog-stage-') for p in root.iterdir()))

    def test_transfer_stream_closes_on_failed_chunk(self):
        root=self.root();plan,data,chunks=self.transfer_plan();closed=[]
        def fetch(chunk,cancel):
            try:
                yield b'not compressed'
                self.fail('corrupt stream must stop before requesting more bytes')
            finally:closed.append(True)
        with OwnedRoot(root,self.context) as owned:self.issue('chunk_retries_exhausted',lambda:transfer_missing(owned,plan,self.events,Cancellation(),fetch))
        self.assertEqual(len(closed),3)

    def run_worker(self,operation,root=None,cancel=False,alias=False):
        request_r,request_w=os.pipe();event_r,event_w=os.pipe();cancel_r,cancel_w=os.pipe()
        descriptors={request_r,request_w,event_r,event_w,cancel_r,cancel_w};child=None;thread=None;raw=[]
        request={'schema':1,'operation':operation,'accountOwner':self.context.owner,'productID':'10','platform':'osx','jobID':self.context.job,'generation':3,
                 'root':str(root) if root else None,'plan':{'productID':'10','platform':'osx','buildID':'123','files':[{'path':'bundle/game.bin','size':len(PAYLOAD),'algorithm':'sha256','digest':hashlib.sha256(PAYLOAD).hexdigest()}]}}
        def close(fd):
            if fd in descriptors:os.close(fd);descriptors.remove(fd)
        try:
            command=[sys.executable,str(PROJECT/'scripts/gog-worker.py'),'--request-fd',str(request_r),'--event-fd',str(event_w),'--cancel-fd',str(request_r if alias else cancel_r)]
            child=subprocess.Popen(command,pass_fds=(request_r,event_w,cancel_r),stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True,env=dict(os.environ,PYTHONDONTWRITEBYTECODE='1'))
            self.processes.append(child.pid);close(request_r);close(event_w);close(cancel_r)
            def drain():
                while True:
                    part=os.read(event_r,65536)
                    if not part:break
                    raw.append(part)
            thread=threading.Thread(target=drain,name='gog-fixture-event-reader');thread.start()
            os.write(request_w,canonical(request));close(request_w)
            if cancel:os.write(cancel_w,b'c')
            stdout,stderr=child.communicate(timeout=6)
            thread.join(timeout=3);self.assertFalse(thread.is_alive())
            self.assertEqual(stdout,b'');self.assertEqual(stderr,b'')
            return child.returncode,[json.loads(line) for line in b''.join(raw).splitlines()]
        finally:
            if child is not None and child.poll() is None:
                os.killpg(child.pid,signal.SIGTERM)
                try:child.communicate(timeout=2)
                except subprocess.TimeoutExpired:os.killpg(child.pid,signal.SIGKILL);child.communicate()
            for fd in list(descriptors):close(fd)
            if thread:thread.join(timeout=3)

    def test_private_fd_worker_inspect_verify_resume_and_refusal(self):
        root=self.root()
        for operation in ('inspect-plan','verify','resume'):
            code,rows=self.run_worker(operation,root)
            self.assertEqual(code,0);self.assertTrue(rows[-1]['terminal'])
            self.assertEqual(rows[-1]['status'],'waiting')
            self.assertTrue(rows[-1]['requiresNativeValidation'])
            self.assertNotIn(str(root),canonical(rows).decode())
        code,rows=self.run_worker('download',root)
        self.assertEqual(code,2);self.assertEqual(rows[-1]['code'],'direct_download_integration_required')
        self.assertFalse(any(row['status']=='launch-ready' for row in rows))

    def test_private_fd_cancel_alias_and_no_implicit_network(self):
        code,rows=self.run_worker('verify',self.root(),cancel=True)
        self.assertEqual(code,130);self.assertEqual(rows[-1]['status'],'cancelled')
        code,rows=self.run_worker('inspect-plan',alias=True)
        self.assertEqual(code,2);self.assertEqual(rows,[])
        code,rows=self.run_worker('refresh-auth')
        self.assertEqual(code,2);self.assertEqual(rows[-1]['code'],'network_not_authorized')
        fd=os.open(self.tmp/'not-pipe',os.O_CREAT|os.O_RDWR,0o600)
        try:self.issue('invalid_fd',lambda:private_pipe(fd,False))
        finally:os.close(fd)

    def test_actual_secret_pipes_refresh_cas_and_no_token_on_event_or_stdout(self):
        for acknowledged in (True,False,1):
            descriptors=set();child=None;threads=[];event_bytes=[];secret=[]
            def pipe():
                r,w=os.pipe();descriptors.update((r,w));return r,w
            req_r,req_w=pipe();ev_r,ev_w=pipe();cancel_r,cancel_w=pipe()
            sec_r,sec_w=pipe();result_r,result_w=pipe();ack_r,ack_w=pipe()
            def close(fd):
                if fd in descriptors:os.close(fd);descriptors.remove(fd)
            # Real worker entry point, injecting only a fake HTTP response. All
            # credentials arrive through sec_r; no token occurs in this argv.
            harness="""
import pathlib,runpy,socket,sys,types
sys.path.insert(0,str(pathlib.Path(sys.argv[1]).parent))
socket.socket.connect=lambda *_: (_ for _ in ()).throw(AssertionError('network forbidden'))
socket.getaddrinfo=lambda *_: (_ for _ in ()).throw(AssertionError('DNS forbidden'))
entry=runpy.run_path(sys.argv[1],run_name='inert_worker_fixture')
original=entry['bound_auth_manager']
def injected(module,context,lease,sink):
    reply=dict(lease['credentials'][module.CLIENT_ID]);reply['expires_in']=3600
    fake=types.SimpleNamespace(get=lambda *a,**k:types.SimpleNamespace(ok=True,json=lambda:reply),close=lambda:None)
    return original(module,context,lease,sink,fake)
entry['main'].__globals__['bound_auth_manager']=injected
sys.exit(entry['main'](sys.argv[2:]))
"""
            command=[sys.executable,'-B','-c',harness,str(PROJECT/'scripts/gog-worker.py'),
                     '--request-fd',str(req_r),'--event-fd',str(ev_w),'--cancel-fd',str(cancel_r),
                     '--secret-fd',str(sec_r),'--secret-result-fd',str(result_w),'--secret-ack-fd',str(ack_r),
                     '--dependency-root',str(PIN)]
            self.assertNotIn('SENTINEL',' '.join(command))
            try:
                child=subprocess.Popen(command,pass_fds=(req_r,ev_w,cancel_r,sec_r,result_w,ack_r),stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True,env=dict(os.environ,PYTHONDONTWRITEBYTECODE='1'))
                self.processes.append(child.pid)
                for fd in (req_r,ev_w,cancel_r,sec_r,result_w,ack_r):close(fd)
                def drain_events():
                    while True:
                        part=os.read(ev_r,65536)
                        if not part:break
                        event_bytes.append(part)
                def commit():
                    with os.fdopen(os.dup(result_r),'rb') as stream:
                        line=stream.readline(65537)
                    if not line:return
                    value=decode(line,65536);secret.append(value)
                    ack={'owner':self.context.owner,'generation':4,'accepted':acknowledged}
                    os.write(ack_w,canonical(ack));close(ack_w)
                for fn in (drain_events,commit):
                    thread=threading.Thread(target=fn,name='gog-private-fixture-reader');thread.start();threads.append(thread)
                request={'schema':1,'operation':'refresh-auth','networkAllowed':True,'accountOwner':self.context.owner,'productID':'10','platform':'osx','jobID':self.context.job,'generation':3}
                os.write(req_w,canonical(request));close(req_w)
                os.write(sec_w,canonical(self.lease()));close(sec_w)
                stdout,stderr=child.communicate(timeout=8)
                for thread in threads:thread.join(timeout=3);self.assertFalse(thread.is_alive())
                self.assertEqual(stdout,b'');self.assertEqual(stderr,b'')
                encoded=b''.join(event_bytes);self.assertNotIn(b'SENTINEL',encoded)
                self.assertTrue(len(secret)==1 and secret[0]['generation']==4)
                rows=[decode(line,65536) for line in encoded.splitlines()]
                self.assertEqual(child.returncode,0 if acknowledged is True else 2)
                self.assertEqual(rows[-1]['code'],'session_available' if acknowledged is True else 'auth_commit_rejected')
            finally:
                if child is not None and child.poll() is None:
                    os.killpg(child.pid,signal.SIGTERM)
                    try:child.communicate(timeout=2)
                    except subprocess.TimeoutExpired:os.killpg(child.pid,signal.SIGKILL);child.communicate()
                for fd in list(descriptors):close(fd)
                for thread in threads:thread.join(timeout=3)


if __name__=='__main__':unittest.main(verbosity=2)
