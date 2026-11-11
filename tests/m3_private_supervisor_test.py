import importlib.util
import ctypes
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

scripts = Path(__file__).resolve().parents[1] / 'scripts'
sys.path.insert(0,str(scripts))
spec = importlib.util.spec_from_file_location('m3_private_supervisor',scripts/'m3_private_supervisor.py')
supervisor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(supervisor)

class FakeInspector:
    def snapshot(self, marker): return [],[]
    def identity(self, pid): return {'pid':pid,'uid':os.geteuid(),'start_sec':1,'start_usec':0,'path':'/fixture','status':1,'ppid':os.getpid()}

class SupervisorTests(unittest.TestCase):
    def test_reap_permission_error_still_waits_for_child(self):
        class Child:
            pid=123
            stdout=None
            def __init__(self):self.waits=0
            def poll(self):return None
            def wait(self,timeout):self.waits+=1;return 0
        child=Child()
        with mock.patch.object(supervisor.os,'killpg',side_effect=PermissionError):supervisor.reap_child(child)
        self.assertGreaterEqual(child.waits,1)
    @unittest.skipUnless(sys.platform == 'darwin', 'macOS libproc')
    def test_real_libproc_identifies_test_process(self):
        item=supervisor.Inspector().identity(os.getpid())
        self.assertIsNotNone(item)
        self.assertEqual(item['uid'],os.geteuid())
        self.assertGreater(item['start_sec'],0)

    def test_marker_bounded_copy_exact_fields_and_error(self):
        class Library:
            payload=b'';error=0
            def sysctl(self,mib,count,buf,size,*args):
                if self.error:return 1
                ctypes.memmove(buf,self.payload,len(self.payload));ctypes.cast(size,ctypes.POINTER(ctypes.c_size_t))[0]=len(self.payload);return 0
        inspector=supervisor.Inspector.__new__(supervisor.Inspector);inspector.lib=Library();buffer=ctypes.create_string_buffer(1024*1024)
        prefix=b'\x01\0\0\0exe\0'
        for payload,expected in [(b'',None),(b'\0',None),(prefix+b'PLAYMELT_TEST_RUN=test',None),(prefix+b'PLAYMELT_TEST_RUN=test\0z',None),(prefix+b'PLAYMELT_TEST_RUN=test\0z\0',True),(prefix+b'PLAYMELT_TEST_RUN=test2\0',False),(prefix+b'xPLAYMELT_TEST_RUN=test\0',False),(prefix+b'PLAYMELT_TEST_RUN=te',None),(prefix,False)]:
            inspector.lib.payload=payload;self.assertEqual(inspector.marker(12,'test',buffer),expected)
        inspector.lib.error=1;self.assertIsNone(inspector.marker(12,'test',buffer))
    def test_snapshot_reuses_local_buffer_and_marks_unknown(self):
        class Library:
            def proc_listpids(self,kind,uid,buf,cap):
                if buf is None:return 8
                ctypes.memmove(buf,(ctypes.c_int*2)(100,101),8);return 8
        inspector=supervisor.Inspector.__new__(supervisor.Inspector);inspector.lib=Library();buffers=[]
        inspector.identity=lambda pid:{'pid':pid,'path':str(supervisor.PROJECT)+'/x'}
        def marker(pid,value,buf):buffers.append(buf);return True if pid==100 else None
        inspector.marker=marker;found,unknown=inspector.snapshot('test')
        self.assertEqual([x['pid'] for x in found],[100]);self.assertEqual([x['pid'] for x in unknown],[101]);self.assertIs(buffers[0],buffers[1])
        inspector.snapshot('test');self.assertIsNot(buffers[0],buffers[2])
    def test_virtual_desktop_command_has_no_game_flags(self):
        self.assertEqual(supervisor.game_command('/wine','/game.exe'), ['/wine','explorer','/desktop=PlaymeltSpiderManTest,1280x720','/game.exe'])

    def test_announce_flushes_and_receipt_updates(self):
        class Output(io.StringIO):
            flushed=False
            def flush(self): self.flushed=True; super().flush()
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); output=Output()
            with mock.patch('sys.stdout',output): supervisor.announce_run(root,{'status':'allocated'})
            self.assertTrue(output.flushed)
            self.assertEqual(output.getvalue(),str(root)+'\n')
            self.assertEqual(json.loads((root/'receipt.json').read_text())['status'],'allocated')
            supervisor.write_receipt(root,{'status':'game_running'})
            self.assertEqual(json.loads((root/'receipt.json').read_text())['status'],'game_running')
            self.assertFalse((root/'receipt.json.tmp').exists())

    def test_short_lived_process_drains_full_buffer(self):
        with tempfile.TemporaryDirectory() as directory:
            with open(Path(directory)/'log','wb',buffering=0) as log:
                p,timed,capped=supervisor.run_command([sys.executable,'-c','import os;os.write(1,b"x"*262144)'],dict(os.environ),directory,log,3,FakeInspector(),'fixture',{})
                supervisor.reap_child(p)
            self.assertFalse(timed); self.assertFalse(capped)
            self.assertEqual((Path(directory)/'log').read_bytes(),b'x'*262144)

    def test_exit_drain_is_bounded_when_writer_stays_open(self):
        read_fd,write_fd=os.pipe()
        class Exited:
            pid=os.getpid()
            stdout=os.fdopen(read_fd,'rb',buffering=0)
            def poll(self): return 0
        p=Exited()
        try:
            with tempfile.TemporaryDirectory() as directory, open(Path(directory)/'log','wb',buffering=0) as log:
                os.write(write_fd,b'buffered error\n')
                start=time.monotonic()
                with mock.patch.object(supervisor.subprocess,'Popen',return_value=p):
                    _,timed,_=supervisor.run_command(['/fixture'],{},directory,log,3,FakeInspector(),'fixture',{})
                self.assertFalse(timed)
                self.assertLess(time.monotonic()-start,1.5)
                self.assertEqual((Path(directory)/'log').read_bytes(),b'buffered error\n')
        finally:
            p.stdout.close(); os.close(write_fd)

    def test_stream_timeout_and_owned_child_reaped(self):
        with tempfile.TemporaryDirectory() as directory:
            unrelated=subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)'],start_new_session=True)
            try:
                with open(Path(directory)/'log','wb',buffering=0) as log:
                    p,timed,capped=supervisor.run_command([sys.executable,'-u','-c','import time;print("live",flush=True);time.sleep(30)'],dict(os.environ),directory,log,0.35,FakeInspector(),'fixture',{})
                    self.assertTrue(timed); self.assertFalse(capped)
                    self.assertEqual((Path(directory)/'log').read_text(),'live\n')
                    supervisor.reap_child(p)
                    self.assertIsNotNone(p.poll())
                    self.assertIsNone(unrelated.poll())
            finally:
                unrelated.terminate(); unrelated.wait(timeout=3)

    def test_shutdown_commands_pass_only_private_prefix(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); server=root/'server'
            server.write_text('#!'+sys.executable+'\nimport os,sys\nwith open(os.environ["OUTPUT"],"a") as f: f.write(sys.argv[1]+" "+os.environ["WINEPREFIX"]+"\\n")\n')
            server.chmod(0o700)
            receipt={'shutdown':{}}; env={'OUTPUT':str(root/'out'),'WINEPREFIX':str(root/'private-prefix')}
            supervisor.bounded_shutdown(str(server),env,directory,receipt)
            self.assertEqual((root/'out').read_text(),'-k '+env['WINEPREFIX']+'\n-w '+env['WINEPREFIX']+'\n')
            self.assertEqual(receipt['shutdown']['-k']['exit'],0)
            self.assertEqual(receipt['shutdown']['-w']['exit'],0)

if __name__=='__main__': unittest.main()
