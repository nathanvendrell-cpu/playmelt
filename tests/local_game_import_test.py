import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('importer',ROOT/'scripts/local_game_import.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class Tests(unittest.TestCase):
 def test_zip_traversal_duplicate_and_links_rejected(self):
  for members in [[('../escape.exe',b'MZ')],[('/absolute.exe',b'MZ')],[('C:\\escape.exe',b'MZ')],[('Game.exe',b'MZ'),('game.exe',b'MZ')],[('a',b'file'),('a/game.exe',b'MZ')]]:
   with tempfile.TemporaryDirectory() as tmp:
    archive=Path(tmp)/'game.zip'
    with zipfile.ZipFile(archive,'w') as z:
     for name,data in members:z.writestr(name,data)
    with self.assertRaises(ValueError):m.inventory(archive)
 def test_folder_import_is_transactional_and_preserves_source(self):
  with tempfile.TemporaryDirectory() as tmp:
   source=Path(tmp)/'Source';source.mkdir();(source/'Game.exe').write_bytes(b'MZgame');root=Path(tmp)/'Games'
   result=m.install(source,root,'My Game','Game.exe');target=next(root.iterdir())
   self.assertEqual(result['status'],'imported');self.assertEqual((source/'Game.exe').read_bytes(),b'MZgame');self.assertEqual((target/'Windows/Game.exe').read_bytes(),b'MZgame')
   self.assertEqual(json.loads((target/'.playmelt-game.json').read_text())['executable'],'Game.exe')
 def test_failed_binary_never_appears_as_installed(self):
  with tempfile.TemporaryDirectory() as tmp:
   source=Path(tmp)/'Source';source.mkdir();(source/'Game.exe').write_bytes(b'bad');root=Path(tmp)/'Games'
   with self.assertRaises(ValueError):m.install(source,root,'Bad','Game.exe')
   self.assertEqual(list(root.iterdir()),[])
 def test_installer_not_executed_and_symlinks_rejected(self):
  with tempfile.TemporaryDirectory() as tmp:
   source=Path(tmp)/'Source';source.mkdir();(source/'setup.exe').write_bytes(b'MZ');self.assertEqual(m.inventory(source)[1]['executables'],[])
   with self.assertRaises(ValueError):m.inventory(source/'setup.exe')
   (source/'link').symlink_to(source/'setup.exe')
   with self.assertRaises(ValueError):m.inventory(source)
if __name__=='__main__':unittest.main()
