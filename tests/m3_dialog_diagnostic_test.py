import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

scripts=Path(__file__).resolve().parents[1]/'scripts'; sys.path.insert(0,str(scripts))
spec=importlib.util.spec_from_file_location('m3_dialog_diagnostic',scripts/'m3_dialog_diagnostic.py')
d=importlib.util.module_from_spec(spec); spec.loader.exec_module(d)

class DialogTests(unittest.TestCase):
    def test_fixed_profile_does_not_mutate_plan(self):
        env={'WINEPREFIX':str(d.reuse.PREFIX),'WINEDEBUG':'old','OTHER':'retained'}
        captured={}
        def fake(argv,run_env,directory,log,timeout,inspector,marker,seen):
            captured.update(run_env); captured['argv']=argv; return 'fixture'
        with tempfile.TemporaryDirectory() as directory:
            with (Path(directory)/'log').open('wb') as f:
                argv=d.supervisor.game_command('/wine',d.supervisor.GAME)
                self.assertEqual(d.dialog_run(fake,argv,env,directory,f,120,None,'fixture',{}),'fixture')
            profile=json.loads((Path(directory)/'diagnostic-profile.json').read_text())
        self.assertEqual(captured['WINEDEBUG'],'fixme-all,+dialog,+msgbox,+seh')
        self.assertEqual(captured['argv'],argv)
        self.assertEqual(captured['OTHER'],'retained'); self.assertEqual(env['WINEDEBUG'],'old')
        self.assertFalse(profile['samples_enabled']); self.assertEqual(profile['timeout_seconds'],120)
        self.assertFalse(profile['nolauncher_requested'])
        self.assertEqual(profile['launch_mode'],'virtual_desktop')

    def test_direct_mode_has_only_executable_without_game_flags(self):
        captured=[]
        def fake(argv,*args): captured.extend(argv); return 0
        with tempfile.TemporaryDirectory() as directory:
            with (Path(directory)/'log').open('wb') as f:
                argv=d.supervisor.game_command('/wine',d.supervisor.GAME)
                d.dialog_run(fake,argv,{'WINEPREFIX':str(d.reuse.PREFIX)},directory,f,120,None,'fixture',{},direct=True)
            profile=json.loads((Path(directory)/'diagnostic-profile.json').read_text())
        self.assertEqual(captured,['/wine',str(d.supervisor.GAME)])
        self.assertEqual(profile['launch_mode'],'direct')
        self.assertFalse(profile['nolauncher_requested'])

    def test_direct_and_nolauncher_keep_argument_order(self):
        captured=[]
        with tempfile.TemporaryDirectory() as directory:
            with (Path(directory)/'log').open('wb') as f:
                argv=d.supervisor.game_command('/wine',d.supervisor.GAME)
                d.dialog_run(lambda actual,*a:captured.extend(actual),argv,{'WINEPREFIX':str(d.reuse.PREFIX)},directory,f,120,None,'fixture',{},direct=True,nolauncher=True)
        self.assertEqual(captured,['/wine',str(d.supervisor.GAME),'-nolauncher'])

    def test_nolauncher_is_single_explicit_game_argument(self):
        captured=[]
        def fake(argv,*args): captured.extend(argv); return 0
        with tempfile.TemporaryDirectory() as directory:
            with (Path(directory)/'log').open('wb') as f:
                argv=d.supervisor.game_command('/wine',d.supervisor.GAME)
                d.dialog_run(fake,argv,{'WINEPREFIX':str(d.reuse.PREFIX)},directory,f,120,None,'fixture',{},nolauncher=True)
            profile=json.loads((Path(directory)/'diagnostic-profile.json').read_text())
        self.assertEqual(captured,argv+['-nolauncher'])
        self.assertTrue(profile['nolauncher_requested'])

    def test_cli_enables_only_nolauncher_and_restores_hooks(self):
        captured=[]; original=d.supervisor.run_command
        with tempfile.TemporaryDirectory() as directory:
            with (Path(directory)/'log').open('wb') as f:
                def original_fake(argv,*args): captured.extend(argv); return 0
                def reuse_fake():
                    self.assertEqual(sys.argv,['script','--run'])
                    argv=d.supervisor.game_command('/wine',d.supervisor.GAME)
                    return d.supervisor.run_command(argv,{'WINEPREFIX':str(d.reuse.PREFIX)},directory,f,120,None,'fixture',{})
                with mock.patch.object(d.supervisor,'run_command',side_effect=original_fake), mock.patch.object(d.reuse,'main',side_effect=reuse_fake), mock.patch.object(sys,'argv',['script','--run','--nolauncher']):
                    self.assertEqual(d.main(),0)
                    self.assertEqual(sys.argv,['script','--run','--nolauncher'])
        self.assertEqual(captured,d.supervisor.game_command('/wine',d.supervisor.GAME)+['-nolauncher'])
        self.assertIs(d.supervisor.run_command,original)

    def test_reject_wrong_prefix_and_arguments(self):
        with tempfile.TemporaryDirectory() as directory:
            with (Path(directory)/'log').open('wb') as f:
                for argv,env,t in [(['/wine'],{'WINEPREFIX':str(d.reuse.PREFIX)},120),
                                   (d.supervisor.game_command('/wine',d.supervisor.GAME),{'WINEPREFIX':'/other'},120),
                                   (d.supervisor.game_command('/wine',d.supervisor.GAME),{'WINEPREFIX':str(d.reuse.PREFIX)},121)]:
                    with self.assertRaises(RuntimeError): d.dialog_run(lambda *a:None,argv,env,directory,f,t,None,'fixture',{})

    def test_hooks_restored_on_error_and_no_samples(self):
        old_run,old_collect=d.supervisor.run_command,d.reuse.collect
        with mock.patch.object(sys,'argv',['script','--run']),mock.patch.object(d.reuse,'main',side_effect=RuntimeError('fixture')):
            with self.assertRaises(RuntimeError): d.main()
        self.assertIs(d.supervisor.run_command,old_run); self.assertIs(d.reuse.collect,old_collect)
        self.assertIsNone(d.no_samples())

    def test_without_run_is_passive(self):
        with mock.patch.object(sys,'argv',['script']),mock.patch.object(d.reuse,'main') as called,mock.patch('sys.stderr',new=io.StringIO()):
            self.assertEqual(d.main(),64); called.assert_not_called()

    def test_arbitrary_arguments_rejected_without_invocation(self):
        with mock.patch.object(sys,'argv',['script','--run','--other']),mock.patch.object(d.reuse,'main') as called,mock.patch('sys.stderr',new=io.StringIO()):
            self.assertEqual(d.main(),64); called.assert_not_called()

if __name__=='__main__': unittest.main()
