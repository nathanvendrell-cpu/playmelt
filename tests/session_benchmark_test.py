import os
from pathlib import Path
import struct
import sys
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from session_benchmark import arguments, target_argument, choose

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
