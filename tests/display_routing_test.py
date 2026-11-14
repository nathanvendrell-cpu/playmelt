import contextlib
import json
import os
from pathlib import Path
import re
import subprocess
import shutil
import sys
import tempfile
import unittest
from unittest import mock
import spiderman2_profile_test as fixture

p=fixture.p

class DisplayRoutingTests(unittest.TestCase):
    def test_benchmark_entrypoint_never_writes_signed_resource_cache(self):
        scripts=Path(__file__).resolve().parents[1]/'scripts'
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            for name in ['session_benchmark.py','m3_private_supervisor.py','m3_private_supervisor_policy.py','metal_performance_capture.py','analyze_metal_performance.py']:shutil.copyfile(scripts/name,root/name)
            env=dict(os.environ);env.pop('PYTHONDONTWRITEBYTECODE',None)
            result=subprocess.run([sys.executable,str(root/'session_benchmark.py'),'--help'],env=env,capture_output=True,timeout=10)
            self.assertEqual(result.returncode,0,result.stderr);self.assertFalse((root/'__pycache__').exists())
    def target(self):
        return dict(id='external',isPrimary=True,isBuiltIn=False,desktopWidth=1920,desktopHeight=1080,refreshRate=120.0,originX=0.0,originY=0.0,windowsMonitorIndex=2,wineIndex=99)
    def test_safety_reapplied_each_launch_without_touching_graphics(self):
        with tempfile.TemporaryDirectory() as tmp,contextlib.ExitStack() as stack:
            root=Path(tmp);prefix=root/'prefix';prefix.mkdir();reg=prefix/'user.reg'
            reg.write_text('[Software\\\\Insomniac Games\\\\Marvel\'s Spider-Man 2\\\\Graphics]\n"RefreshRate"=dword:0000003c\n"Fullscreen"=dword:00000001\n"HDR"=dword:00000001\n')
            stack.enter_context(mock.patch.object(p,'PROFILE',root));stack.enter_context(mock.patch.object(p,'PREFIX',prefix));stack.enter_context(mock.patch.object(p.reuse,'require_idle_prefix'))
            data=fixture.PreferenceTests().fixture();data['applyFields']=['launchArgs'];data['settings']['display'].update(mode='windowed',width=2560,height=1600)
            plan={'displayHints':{'safeLaunchTarget':self.target()}}
            for _ in range(2):
                p.apply_preferences(plan,(data,[]));out=reg.read_text()
                for value in ['"Fullscreen"=dword:00000000','"ExclusiveFullscreen"=dword:00000000','"RefreshRate"=dword:00000078','"Monitor"=dword:00000002','"WindowWidth"=dword:00000760','"WindowHeight"=dword:000003e8','"HDR"=dword:00000001','"CaptureDisplaysForFullscreen"="N"']:
                    self.assertIn(value,out)
                reg.write_text(out.replace('"RefreshRate"=dword:00000078','"RefreshRate"=dword:0000003c').replace('"Fullscreen"=dword:00000000','"Fullscreen"=dword:00000001'))
    def test_missing_windows_identity_preserves_registry(self):
        with tempfile.TemporaryDirectory() as tmp,contextlib.ExitStack() as stack:
            root=Path(tmp);prefix=root/'prefix';prefix.mkdir();reg=prefix/'user.reg';reg.write_text('WINE REGISTRY Version 2\n')
            stack.enter_context(mock.patch.object(p,'PROFILE',root));stack.enter_context(mock.patch.object(p,'PREFIX',prefix));stack.enter_context(mock.patch.object(p.reuse,'require_idle_prefix'))
            target=self.target();target.pop('windowsMonitorIndex')
            with self.assertRaises(RuntimeError):p.apply_preferences({'displayHints':{'safeLaunchTarget':target}},None)
            self.assertEqual(reg.read_text(),'WINE REGISTRY Version 2\n')
    def test_windows_output_must_match_real_target(self):
        with tempfile.TemporaryDirectory() as tmp,contextlib.ExitStack() as stack:
            root=Path(tmp);helper=root/'settings.exe';helper.write_bytes(b'fixture')
            stack.enter_context(mock.patch.object(p,'PROFILE',root));stack.enter_context(mock.patch.object(p,'PREFIX',root/'prefix'));stack.enter_context(mock.patch.object(p,'SETTINGS',helper));stack.enter_context(mock.patch.object(p.reuse,'require_idle_prefix'))
            stack.enter_context(mock.patch.object(p.tx,'private_environment',return_value={}))
            stack.enter_context(mock.patch.object(p.base,'reap_child'))
            def shutdown(server,env,directory,receipt):receipt['shutdown']={'-k':{'exit':0},'-w':{'exit':0}}
            stack.enter_context(mock.patch.object(p.base,'bounded_shutdown',side_effect=shutdown))
            answer={'ok':True,'monitorIndex':3,'x':0,'y':0,'width':1920,'height':1080,'refreshRate':120}
            def run(argv,env,directory,log,*args):
                self.assertEqual(argv[-1],'--display');log.write((json.dumps(answer)+'\n').encode());return mock.Mock(poll=lambda:0),False,False
            stack.enter_context(mock.patch.object(p.base,'run_command',side_effect=run))
            plan={'wine':'fixture','server':'fixture','displayHints':{'safeLaunchTarget':self.target()}}
            p.resolve_safe_display(plan,{'settings':p.digest(helper)})
            self.assertEqual(plan['displayHints']['safeLaunchTarget']['windowsMonitorIndex'],3)
            answer['refreshRate']=60
            with self.assertRaises(RuntimeError):p.resolve_safe_display(plan,{'settings':p.digest(helper)})
    def test_actual_launcher_shell_reexports_guard_after_system_shell(self):
        project=Path(__file__).resolve().parents[1];library=project/'Products.noindex/libPlaymeltDisplayGuard.dylib';probe=project/'Products.noindex/display-guard-load'
        if not library.exists() or not probe.exists():self.skipTest('Compile harmless guard fixture first')
        text=(project/'Core.swift').read_text();block=text.split('func localGameDisplayGuardBlock() -> String {',1)[1].split('"""',2)[1]
        env=dict(os.environ,PLAYMELT_DISPLAY_POLICY='external-windowed-v1',PLAYMELT_DISPLAY_GUARD_LIBRARY=str(library),PLAYMELT_DISPLAY_INSERT_LIBRARIES=str(library))
        env.pop('DYLD_INSERT_LIBRARIES',None)
        result=subprocess.run(['/bin/bash','-c',block+'\nexec "$1"','fixture',str(probe)],env=env,capture_output=True,text=True,timeout=10)
        self.assertEqual(result.returncode,0,result.stderr);self.assertIn('actual capture binding denied',result.stdout)

if __name__=='__main__':unittest.main()
