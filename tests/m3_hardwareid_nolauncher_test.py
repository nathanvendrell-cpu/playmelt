import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

scripts=Path(__file__).resolve().parents[1]/'scripts';sys.path.insert(0,str(scripts))
spec=importlib.util.spec_from_file_location('m3_hardwareid_nolauncher',scripts/'m3_hardwareid_nolauncher.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)

class Tests(unittest.TestCase):
    def test_game_only_gets_flag_and_explicit_timeout(self):
        calls=[]
        def original(*args):calls.append(args);return 'ok'
        with tempfile.TemporaryDirectory() as directory:
            with (Path(directory)/'game.log').open('wb') as log:
                argv=['/wine',str(m.supervisor.GAME)];env={'WINEPREFIX':str(m.reuse.PREFIX)}
                self.assertEqual(m.game_run(original,argv,env,str(m.supervisor.GAME_DIR),log,120,None,'id',{},seconds=300),'ok')
            profile=json.loads((Path(directory)/'nolauncher-profile.json').read_text())
        self.assertEqual(calls[0][0],argv+['-nolauncher']);self.assertEqual(calls[0][4],300)
        self.assertEqual(profile['game_timeout_seconds'],300);self.assertTrue(profile['diagnostic_only'])
    def test_probe_command_untouched(self):
        calls=[]
        with tempfile.TemporaryDirectory() as directory:
            with (Path(directory)/'probe.log').open('wb') as log:
                m.game_run(lambda *a:calls.append(a),['/wine','/probe','--read'],{},directory,log,30,None,'id',{},seconds=300)
        self.assertEqual(calls[0][0],['/wine','/probe','--read']);self.assertEqual(calls[0][4],30)
    def test_wrong_prefix_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            with (Path(directory)/'game.log').open('wb') as log:
                with self.assertRaises(RuntimeError):m.game_run(lambda *a:None,['/wine',str(m.supervisor.GAME)],{'WINEPREFIX':'/other'},str(m.supervisor.GAME_DIR),log,120,None,'id',{},seconds=300)
    def test_cli_rejects_unreviewed_args(self):
        for args in (['x'],['x','--run'],['x','--run','--nolauncher','--timeout','301'],['x','--run','--nolauncher','--other']):
            with mock.patch.object(sys,'argv',args),mock.patch.object(m.experiment,'main') as call,mock.patch('sys.stderr',new=io.StringIO()):
                self.assertEqual(m.main(),64);call.assert_not_called()
    def test_hook_restored_and_cli_selects_300(self):
        old=m.supervisor.run_command;seen=[]
        with tempfile.TemporaryDirectory() as directory:
            with (Path(directory)/'game.log').open('wb') as f:
                def original(*args):seen.append(args);return 0
                def experiment():
                    self.assertEqual(sys.argv,['x','--run'])
                    return m.supervisor.run_command(['/wine',str(m.supervisor.GAME)],{'WINEPREFIX':str(m.reuse.PREFIX)},str(m.supervisor.GAME_DIR),f,120,None,'id',{})
                with mock.patch.object(m.supervisor,'run_command',side_effect=original),mock.patch.object(m.experiment,'main',side_effect=experiment),mock.patch.object(sys,'argv',['x','--run','--nolauncher','--timeout','300']):
                    self.assertEqual(m.main(),0)
        self.assertEqual(seen[0][0][-1],'-nolauncher');self.assertEqual(seen[0][4],300);self.assertIs(m.supervisor.run_command,old)

if __name__=='__main__':unittest.main()
