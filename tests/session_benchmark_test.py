import os
from pathlib import Path
import struct
import sys
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from session_benchmark import arguments, target_argument, target_match, choose

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
if __name__=='__main__':unittest.main()
