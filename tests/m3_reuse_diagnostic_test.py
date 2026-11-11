import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

scripts=Path(__file__).resolve().parents[1]/'scripts'; sys.path.insert(0,str(scripts))
spec=importlib.util.spec_from_file_location('m3_reuse_diagnostic',scripts/'m3_reuse_diagnostic.py')
d=importlib.util.module_from_spec(spec); spec.loader.exec_module(d)

class FakeInspector:
    def __init__(self): self.item={'pid':123,'uid':os.geteuid(),'start_sec':5,'start_usec':7,'path':'/wine','status':2,'ppid':1}
    def snapshot(self,marker): return [self.item],[]
    def identity(self,pid): return dict(self.item) if pid==123 else None

class DiagnosticTests(unittest.TestCase):
    def test_requires_marker_identity_and_mapped_exe(self):
        i=FakeInspector(); got,_=d.find_game(i,'marker','/wine','/game',lambda path:{123})
        self.assertEqual(got['pid'],123)
        got,why=d.find_game(i,'marker','/wine','/game',lambda path:{999})
        self.assertIsNone(got); self.assertEqual(why['reason'],'game_pid_not_unique')
        got,_=d.find_game(i,'marker','/other','/game',lambda path:{123}); self.assertIsNone(got)

    def test_identity_reuse_is_refused(self):
        i=FakeInspector(); old=dict(i.item); new=dict(old,start_usec=8)
        self.assertFalse(d.same_identity(old,new))
        new=dict(old,uid=old['uid']+1); self.assertFalse(d.same_identity(old,new))
        new=dict(old,path='/other'); self.assertFalse(d.same_identity(old,new))

    def test_admission_busy_or_incomplete_is_refused(self):
        with mock.patch.object(d.subprocess,'run',return_value=subprocess.CompletedProcess([],1,b'',b'')):
            d.require_idle_prefix('/fixture')
        for result in (subprocess.CompletedProcess([],0,b'123\n',b''),subprocess.CompletedProcess([],1,b'',b'warning')):
            with mock.patch.object(d.subprocess,'run',return_value=result), self.assertRaises(RuntimeError): d.require_idle_prefix('/fixture')

    def test_bounded_capture_and_reap(self):
        with tempfile.TemporaryDirectory() as directory:
            out=Path(directory)/'capture'
            r=d.capture([sys.executable,'-u','-c','import time;print("fixture",flush=True);time.sleep(20)'],out,timeout=0.3)
            self.assertTrue(r['timeout']); self.assertEqual(out.read_text(),'fixture\n')

    def test_sampling_identity_rechecked_for_each_capture(self):
        inspector=FakeInspector(); records=[]
        class Event:
            def wait(self,seconds): return False
            def is_set(self): return False
        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.object(d,'query_game_pids',return_value={123}),mock.patch.object(d,'capture',return_value={'exit':0}) as captures:
                d.collect(inspector,'marker','/wine','/game',Path(directory),0,Event(),records)
            self.assertEqual(len(records),3); self.assertEqual(captures.call_count,9)
            self.assertTrue(all(r['captures']['sample']['identity_unchanged_after'] for r in records))

if __name__=='__main__': unittest.main()
