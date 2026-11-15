import os
from pathlib import Path
import struct
import sys
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
import json
import subprocess
import tempfile
from session_benchmark import arguments, target_argument, target_match, choose, summarize, collect, overview_of

class LauncherHandOverTests(unittest.TestCase):
    stub=Path('/games/FF7/ff7rebirth.exe')
    def test_unreal_shipping_child_inside_game_tree_matches(self):
        self.assertEqual(target_match(['wine','Z:\\games\\FF7\\End\\Binaries\\Win64\\ff7rebirth_-Win64-Shipping.exe'],self.stub),'child')
        self.assertEqual(target_match(['wine','/games/FF7/ff7rebirth.exe'],self.stub),'exact')
    def test_outside_traversal_relative_and_non_exe_are_refused(self):
        for args in [['wine','/games/Other/game.exe'],['wine','/games/FF7/../Other/x.exe'],
                     ['wine','End/Binaries/Win64/x.exe'],['wine','/games/FF7/End/data.pak'],
                     ['wine','--path=/games/FF7/End/x.exe'],['wine','/games/FF7x/a.exe']]:
            self.assertIsNone(target_match(args,self.stub),args)
    def test_stub_and_single_child_selects_child_but_two_children_stay_ambiguous(self):
        row={'path':'/runtime/wine','uid':os.geteuid(),'status':1}
        stub,child,other={**row,'pid':10},{**row,'pid':11},{**row,'pid':12}
        self.assertEqual(choose([stub,child],{10:'exact',11:'child'}),child)
        self.assertIsNone(choose([stub,child,other],{10:'exact',11:'child',12:'child'}))
        self.assertIsNone(choose([stub,other],{10:'exact',12:'exact'}))

class Tests(unittest.TestCase):
    def test_kernel_argv_does_not_read_environment_as_arguments(self):
        data=struct.pack('i',2)+b'/bin/wine\0\0wine\0/game/a.exe\0SECRET=/private/a.exe\0'
        self.assertEqual(arguments(data),['wine','/game/a.exe'])
        self.assertFalse(target_argument(arguments(data),Path('/private/a.exe')))
    def test_target_requires_full_path(self):
        target=Path('/games/My Game/game.exe')
        self.assertTrue(target_argument(['wine','Z:\\games\\My Game\\game.exe'],target))
        self.assertTrue(target_argument(['wine','/games/My Game/game.exe'],target))
        for args in [['game.exe'],['/other/game.exe'],['--path=/games/My Game/game.exe']]:
            self.assertFalse(target_argument(args,target))
    def test_ambiguous_or_foreign_process_is_rejected(self):
        row={'pid':20,'path':'/runtime/wine64','uid':os.geteuid(),'status':1}
        self.assertEqual(choose([row]),row)
        self.assertIsNone(choose([row,{**row,'pid':21}]))
        self.assertIsNone(choose([{**row,'uid':os.geteuid()+1}]))
        self.assertIsNone(choose([{**row,'status':5}]))
        self.assertIsNone(choose([{**row,'path':'/usr/bin/python3'}]))
def interval(start, frames, gpu=20.0, worst=25.0, active=1.0):
    return {'Start MCT Seconds': start, 'Time Active (sec)': active,
            'Presented Frame Stats': {'Frame Count': frames, 'On-GPU Walltime Stats': {'Average (ms)': gpu}},
            'Frame-On-Glass Interval Stats': {'Max (ms)': worst}}

def layer(rows, configs):
    return {'Stats Timeline': rows, 'Configuration Timeline': [
        {'Start MCT Seconds': a, 'End MCT Seconds': b, 'Width (pixels)': w, 'Height (pixels)': h} for a, b, w, h in configs]}

class CollectSummaryTests(unittest.TestCase):
    def test_session_groups_minutes_and_spikes(self):
        rows = [interval(100+i, 120, gpu=5, worst=9) for i in range(20)] + \
               [interval(120+i, 35, gpu=28, worst=(175 if i == 3 else 30)) for i in range(70)]
        game = {'PID': 7, 'Process': 'wine', 'Layers': [layer(rows, [(100, 120, 1728, 1084), (120, 190, 2560, 1600)])]}
        other = {'PID': 99, 'Process': 'Safari', 'Layers': [layer([interval(100, 500)], [(100, 101, 800, 600)])]}
        r = summarize([game, other], {7})
        self.assertEqual(r['status'], 'measured')
        self.assertEqual([(g['width'], g['presentedFPS']) for g in r['groups']], [(1728, 120.0), (2560, 35.0)])
        self.assertEqual(r['groups'][1]['gpuMs'], 28.0)
        self.assertEqual(r['groups'][1]['spikeSeconds'], 1)
        self.assertEqual(r['groups'][1]['worstFrameMs'], 175.0)
        self.assertEqual(r['session']['frames'], 20*120+70*35)
        self.assertEqual([m['minute'] for m in r['minutes']], [0, 1])
    def test_foreign_processes_and_empty_layers_are_never_measured(self):
        other = {'PID': 99, 'Layers': [layer([interval(1, 60)], [(0, 9, 800, 600)])]}
        idle = {'PID': 7, 'Layers': [layer([interval(1, 0)], [(0, 9, 800, 600)])]}
        self.assertEqual(summarize([other, idle], {7})['reason'], 'no_frames_for_session')
    def test_largest_layer_of_the_session_is_the_game(self):
        small = layer([interval(1, 5)], [(0, 99, 640, 480)])
        big = layer([interval(1+i, 60) for i in range(30)], [(0, 99, 1920, 1080)])
        r = summarize({'PID': 7, 'Layers': [small, big]}, {7})
        self.assertEqual(r['groups'][0]['width'], 1920)
    def test_collect_and_overview_commands_are_bounded_and_scoped(self):
        calls = []
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)/'capture'
            def run(argv, **kw):
                calls.append(argv)
                self.assertTrue(kw['check']); self.assertLessEqual(kw['timeout'], 600)
                if argv[1] == 'collect':
                    return subprocess.CompletedProcess(argv, 0, json.dumps({'traces': [str(out/'t.atrc')]}).encode())
                return subprocess.CompletedProcess(argv, 0, b'[]')
            trace = collect(1000.4, 1600.2, out, run=run)
            self.assertEqual(calls[0][:6], ['/usr/bin/metalperftrace', 'collect', '--start', '@1000', '--end', '@1601'])
            self.assertEqual(overview_of(trace, {12, 3}, run=run), [])
            self.assertEqual(calls[1][calls[1].index('--predicate')+1], 'pid IN {3,12}')
            def foreign(argv, **kw):
                return subprocess.CompletedProcess(argv, 0, json.dumps({'traces': ['/tmp/elsewhere.atrc']}).encode())
            with self.assertRaises(RuntimeError):
                collect(1, 2, Path(tmp)/'second', run=foreign)

if __name__=='__main__':unittest.main()
