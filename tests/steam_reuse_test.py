import json
import contextlib
import errno
import hashlib
import io
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from steam_reuse import prepare,clone_file,publish_file,main,Directory


class ReuseTests(unittest.TestCase):
    def workspace(self):
        return tempfile.TemporaryDirectory(prefix='steam-reuse-fixture-',dir=Path(__file__).resolve().parents[1]/'Products.noindex')

    def hashes(self,root):
        return {str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in root.rglob('*') if p.is_file() and not p.is_symlink()}

    def no_stage(self,steam):self.assertFalse(list((steam/'steamapps/common').glob('.playmelt-reuse-*')))

    def fixture(self,root):
        game=root/'Game';files=game/'Windows';files.mkdir(parents=True)
        (files/'Game.exe').write_bytes(b'MZoriginal');(files/'data.bin').write_bytes(b'assets')
        steam=root/'Steam';(steam/'steamapps').mkdir(parents=True);(steam/'steam.exe').write_bytes(b'MZclient')
        receipt={'appID':'10','officialInstallDirectory':'Publisher Game','source':'official-steam-console-completion','files':{'Game.exe':10,'data.bin':6},
                 'fileSHA256':{'Game.exe':hashlib.sha256(b'MZoriginal').hexdigest(),'data.bin':hashlib.sha256(b'assets').hexdigest()}}
        (game/'playmelt-install.json').write_text(json.dumps(receipt));return game,steam

    def test_actual_apfs_clones_preserve_original_and_leave_steam_to_verify(self):
        with self.workspace() as d:
            game,steam=self.fixture(Path(d).resolve());before=self.hashes(game);result=prepare(game,steam,'10');target=Path(result['target'])
            self.assertEqual(result['status'],'prepared');self.assertTrue(result['requiresSteamValidation'])
            self.assertNotEqual((game/'Windows/Game.exe').stat().st_ino,(target/'Game.exe').stat().st_ino)
            (target/'Game.exe').write_bytes(b'client verified changes')
            self.assertEqual((game/'Windows/Game.exe').read_bytes(),b'MZoriginal')
            self.assertFalse((steam/'steamapps/appmanifest_10.acf').exists())
            self.assertEqual(self.hashes(game),before);self.no_stage(steam)

    def test_existing_official_directory_is_never_overwritten(self):
        with self.workspace() as d:
            game,steam=self.fixture(Path(d).resolve());target=steam/'steamapps/common/Publisher Game';target.mkdir(parents=True);(target/'save.dat').write_bytes(b'user data')
            result=prepare(game,steam,'10');self.assertEqual(result['filesWritten'],2)
            self.assertEqual((target/'save.dat').read_bytes(),b'user data')
            self.assertEqual((target/'Game.exe').read_bytes(),b'MZoriginal');self.no_stage(steam)

    def test_unsupported_clone_cleans_own_stage_without_large_copy_fallback(self):
        with self.workspace() as d:
            game,steam=self.fixture(Path(d).resolve())
            with self.assertRaises(OSError):prepare(game,steam,'10',clone=lambda *_:(_ for _ in ()).throw(OSError('unsupported')))
            self.assertEqual(list((steam/'steamapps/common').iterdir()),[])
            self.assertTrue((game/'Windows/Game.exe').exists())

    def test_concurrent_target_creation_is_preserved(self):
        with self.workspace() as d:
            game,steam=self.fixture(Path(d).resolve())
            target=steam/'steamapps/common/Publisher Game'
            def clone(srcfd,dstfd,name):
                clone_file(srcfd,dstfd,name)
                if not target.exists():target.mkdir();(target/'user.dat').write_bytes(b'keep')
            with self.assertRaises(FileExistsError):prepare(game,steam,'10',clone=clone)
            self.assertEqual((steam/'steamapps/common/Publisher Game/user.dat').read_bytes(),b'keep')
            self.assertFalse(list((steam/'steamapps/common').glob('.playmelt-reuse-*')))

    def test_tampered_files_symlinks_and_escaped_publisher_path_are_rejected(self):
        for kind in ('size','symlink','path'):
            with self.subTest(kind=kind),self.workspace() as d:
                game,steam=self.fixture(Path(d).resolve())
                if kind=='size':(game/'Windows/Game.exe').write_bytes(b'changed')
                elif kind=='symlink':(game/'Windows/link').symlink_to(game/'Windows/data.bin')
                else:
                    p=game/'playmelt-install.json';r=json.loads(p.read_text());r['officialInstallDirectory']='../outside';p.write_text(json.dumps(r))
                with self.assertRaises(ValueError):prepare(game,steam,'10')
                self.assertFalse((steam/'steamapps/common/Publisher Game').exists())

    def test_empty_existing_directory_is_seeded_with_measured_counts(self):
        with self.workspace() as d:
            game,steam=self.fixture(Path(d).resolve());target=steam/'steamapps/common/Publisher Game';target.mkdir(parents=True);before=self.hashes(game)
            events=[];result=prepare(game,steam,'10',progress=events.append)
            self.assertEqual(self.hashes(target),self.hashes(game/'Windows'));self.assertEqual(self.hashes(game),before)
            self.assertEqual(result['status'],'existing-directory')
            for key,value in {'clonedFiles':2,'existingFiles':0,'processedFiles':2,'totalFiles':2,'totalBytes':16,'clonedBytes':16}.items():self.assertEqual(result[key],value,key)
            self.assertEqual(events[-1]['stagedFiles'],2);self.assertEqual(events[-1]['processedFiles'],2);self.no_stage(steam)

    def test_existing_different_files_are_preserved_and_only_missing_files_cloned(self):
        with self.workspace() as d:
            game,steam=self.fixture(Path(d).resolve());target=steam/'steamapps/common/Publisher Game';target.mkdir(parents=True)
            existing=target/'Game.exe';existing.write_bytes(b'different Steam data');before=(existing.read_bytes(),existing.stat().st_ino,existing.stat().st_mtime_ns)
            result=prepare(game,steam,'10')
            self.assertEqual((existing.read_bytes(),existing.stat().st_ino,existing.stat().st_mtime_ns),before)
            self.assertEqual((target/'data.bin').read_bytes(),b'assets');self.assertEqual(result['clonedFiles'],1);self.assertEqual(result['existingFiles'],1)
            self.assertEqual(result['existingBytes'],len(b'different Steam data'));self.assertTrue(result['requiresSteamValidation']);self.no_stage(steam)

    def test_all_existing_files_are_left_for_steam_without_clone_or_validation_claim(self):
        with self.workspace() as d:
            game,steam=self.fixture(Path(d).resolve());target=steam/'steamapps/common/Publisher Game';target.mkdir(parents=True)
            for name in ['Game.exe','data.bin']:(target/name).write_bytes(b'existing different')
            before=self.hashes(target);result=prepare(game,steam,'10',clone=lambda *_:self.fail('existing file cloned'))
            self.assertEqual(result['clonedFiles'],0);self.assertEqual(result['existingFiles'],2);self.assertTrue(result['requiresSteamValidation'])
            self.assertEqual(self.hashes(target),before);self.no_stage(steam)

    def test_nested_missing_directories_and_files_are_seeded_without_touching_existing_extra(self):
        with self.workspace() as d:
            game,steam=self.fixture(Path(d).resolve());(game/'Windows/data').mkdir();(game/'Windows/data/sub.bin').write_bytes(b'nested')
            p=game/'playmelt-install.json';r=json.loads(p.read_text());r['files']['data/sub.bin']=6;r['fileSHA256']['data/sub.bin']=hashlib.sha256(b'nested').hexdigest();p.write_text(json.dumps(r))
            target=steam/'steamapps/common/Publisher Game';target.mkdir(parents=True);(target/'save.dat').write_bytes(b'keep')
            before=self.hashes(game);result=prepare(game,steam,'10')
            self.assertEqual(result['clonedFiles'],3);self.assertEqual((target/'data/sub.bin').read_bytes(),b'nested');self.assertEqual((target/'save.dat').read_bytes(),b'keep')
            self.assertEqual(self.hashes(game),before);self.no_stage(steam)

    def test_exdev_never_falls_back_to_a_copy_and_existing_data_remains(self):
        with self.workspace() as d:
            game,steam=self.fixture(Path(d).resolve());target=steam/'steamapps/common/Publisher Game';target.mkdir(parents=True);(target/'save.dat').write_bytes(b'keep');before=self.hashes(game)
            with self.assertRaises(OSError) as raised:prepare(game,steam,'10',clone=lambda *_:(_ for _ in ()).throw(OSError(errno.EXDEV,'cross-device')))
            self.assertEqual(raised.exception.errno,errno.EXDEV);self.assertEqual(list(target.iterdir()),[target/'save.dat']);self.assertEqual(self.hashes(game),before);self.no_stage(steam)

    def test_file_created_during_atomic_publish_is_not_overwritten(self):
        with self.workspace() as d:
            game,steam=self.fixture(Path(d).resolve());target=steam/'steamapps/common/Publisher Game';target.mkdir(parents=True)
            def collide(srcfd,srcname,dstfd,dstname):
                fd=os.open(dstname,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600,dir_fd=dstfd)
                try:os.write(fd,b'concurrent Steam data')
                finally:os.close(fd)
                publish_file(srcfd,srcname,dstfd,dstname)
            with self.assertRaises(FileExistsError):prepare(game,steam,'10',publish=collide)
            self.assertEqual((target/'Game.exe').read_bytes(),b'concurrent Steam data');self.no_stage(steam)

    def test_target_namespace_replacement_is_detected_and_replacement_untouched(self):
        with self.workspace() as d:
            game,steam=self.fixture(Path(d).resolve());target=steam/'steamapps/common/Publisher Game';target.mkdir(parents=True);old=target.with_name('Moved original')
            def replace(srcfd,srcname,dstfd,dstname):
                target.rename(old);target.mkdir();(target/'Game.exe').write_bytes(b'replacement data');publish_file(srcfd,srcname,dstfd,dstname)
            with self.assertRaises(ValueError):prepare(game,steam,'10',publish=replace)
            self.assertEqual((target/'Game.exe').read_bytes(),b'replacement data');self.no_stage(steam)

    def test_target_modified_during_staging_aborts_before_any_publication(self):
        with self.workspace() as d:
            game,steam=self.fixture(Path(d).resolve());target=steam/'steamapps/common/Publisher Game';target.mkdir(parents=True);(target/'save.dat').write_bytes(b'old')
            def change(srcfd,dstfd,name):clone_file(srcfd,dstfd,name);(target/'save.dat').write_bytes(b'new')
            with self.assertRaises(ValueError):prepare(game,steam,'10',clone=change)
            self.assertEqual(list(target.iterdir()),[target/'save.dat']);self.assertEqual((target/'save.dat').read_bytes(),b'new');self.no_stage(steam)

    def test_cancellation_during_staging_preserves_source_and_existing_files(self):
        with self.workspace() as d:
            game,steam=self.fixture(Path(d).resolve());target=steam/'steamapps/common/Publisher Game';target.mkdir(parents=True);(target/'save.dat').write_bytes(b'keep');before=self.hashes(game)
            stopped=False
            def progress(value):
                nonlocal stopped
                if value['stagedFiles']>=1:stopped=True
            with self.assertRaises(InterruptedError):prepare(game,steam,'10',cancelled=lambda:stopped,progress=progress)
            self.assertEqual(list(target.iterdir()),[target/'save.dat']);self.assertEqual(self.hashes(game),before);self.no_stage(steam)

    def test_cancellation_after_commit_keeps_valid_clone_and_retry_only_seeds_missing(self):
        with self.workspace() as d:
            game,steam=self.fixture(Path(d).resolve());target=steam/'steamapps/common/Publisher Game';target.mkdir(parents=True);before=self.hashes(game)
            stopped=False
            def progress(value):
                nonlocal stopped
                if value['clonedFiles']==1:stopped=True
            with self.assertRaises(InterruptedError):prepare(game,steam,'10',cancelled=lambda:stopped,progress=progress)
            self.assertEqual((target/'Game.exe').read_bytes(),b'MZoriginal');self.no_stage(steam)
            result=prepare(game,steam,'10');self.assertEqual(result['existingFiles'],1);self.assertEqual(result['clonedFiles'],1)
            self.assertEqual(self.hashes(target),self.hashes(game/'Windows'));self.assertEqual(self.hashes(game),before);self.no_stage(steam)

    def test_same_size_source_corruption_is_rejected_by_actual_clone_hash(self):
        with self.workspace() as d:
            game,steam=self.fixture(Path(d).resolve());(game/'Windows/Game.exe').write_bytes(b'MZtampered');before=self.hashes(game)
            with self.assertRaises(ValueError):prepare(game,steam,'10')
            self.assertFalse((steam/'steamapps/common/Publisher Game').exists());self.assertEqual(self.hashes(game),before);self.no_stage(steam)

    def test_source_modified_during_clone_aborts_without_reverting_other_writer(self):
        with self.workspace() as d:
            game,steam=self.fixture(Path(d).resolve())
            def change(srcfd,dstfd,name):clone_file(srcfd,dstfd,name);(game/'Windows/Game.exe').write_bytes(b'MZtampered')
            with self.assertRaises(ValueError):prepare(game,steam,'10',clone=change)
            self.assertEqual((game/'Windows/Game.exe').read_bytes(),b'MZtampered');self.assertFalse((steam/'steamapps/common/Publisher Game').exists());self.no_stage(steam)

    def test_source_receipt_change_aborts_before_publication(self):
        with self.workspace() as d:
            game,steam=self.fixture(Path(d).resolve())
            def change(srcfd,dstfd,name):
                clone_file(srcfd,dstfd,name);p=game/'playmelt-install.json';value=json.loads(p.read_text());value['officialInstallDirectory']='Changed by another writer';p.write_text(json.dumps(value))
            with self.assertRaises(ValueError):prepare(game,steam,'10',clone=change)
            self.assertFalse((steam/'steamapps/common/Publisher Game').exists());self.no_stage(steam)

    def test_stage_open_failure_cleans_its_new_empty_directory(self):
        with self.workspace() as d:
            game,steam=self.fixture(Path(d).resolve());original=Directory.child
            def reject(directory,name,stack):
                if name.startswith('.playmelt-reuse-'):raise ValueError('simulated namespace change before opening stage')
                return original(directory,name,stack)
            with patch.object(Directory,'child',reject),self.assertRaises(ValueError):prepare(game,steam,'10')
            self.no_stage(steam);self.assertFalse((steam/'steamapps/common/Publisher Game').exists())

    def test_target_symlinks_and_file_directory_collisions_preserve_data(self):
        for kind in ['target','extra-link','leaf-dir','parent-file','receipt']:
            with self.subTest(kind=kind),self.workspace() as d:
                game,steam=self.fixture(Path(d).resolve());target=steam/'steamapps/common/Publisher Game';outside=Path(d)/'outside';outside.mkdir();(outside/'user.dat').write_bytes(b'keep')
                if kind=='receipt':(game/'playmelt-install.json').rename(game/'receipt.json');(game/'playmelt-install.json').symlink_to(game/'receipt.json')
                else:
                    target.parent.mkdir(parents=True,exist_ok=True)
                    if kind=='target':target.symlink_to(outside)
                    else:
                        target.mkdir()
                        if kind=='extra-link':(target/'link').symlink_to(outside/'user.dat')
                        elif kind=='leaf-dir':(target/'data.bin').mkdir();(target/'data.bin/user.dat').write_bytes(b'keep')
                        else:
                            (game/'Windows/data').mkdir();(game/'Windows/data/sub.bin').write_bytes(b'nested')
                            p=game/'playmelt-install.json';r=json.loads(p.read_text());r['files']['data/sub.bin']=6;r['fileSHA256']['data/sub.bin']=hashlib.sha256(b'nested').hexdigest();p.write_text(json.dumps(r));(target/'data').write_bytes(b'keep')
                with self.assertRaises((ValueError,OSError)):prepare(game,steam,'10')
                self.assertEqual((outside/'user.dat').read_bytes(),b'keep');self.no_stage(steam)

    def test_missing_hashes_case_collisions_and_escaped_inventory_are_rejected(self):
        for kind in ['hash','case','relative','absolute']:
            with self.subTest(kind=kind),self.workspace() as d:
                game,steam=self.fixture(Path(d).resolve());p=game/'playmelt-install.json';r=json.loads(p.read_text())
                if kind=='hash':r.pop('fileSHA256')
                else:
                    name={'case':'GAME.EXE','relative':'../outside','absolute':'/outside'}[kind];r['files'][name]=10;r['fileSHA256'][name]='0'*64
                p.write_text(json.dumps(r))
                with self.assertRaises(ValueError):prepare(game,steam,'10')
                self.assertFalse((steam/'steamapps/common/Publisher Game').exists())

    def test_foreign_directory_owner_is_refused_without_seeding(self):
        with self.workspace() as d:
            game,steam=self.fixture(Path(d).resolve());before=self.hashes(game)
            with patch('steam_reuse.os.geteuid',return_value=os.geteuid()+1),self.assertRaises(ValueError):prepare(game,steam,'10')
            self.assertEqual(self.hashes(game),before);self.assertFalse((steam/'steamapps/common/Publisher Game').exists())

    def test_cli_preserves_single_json_response_with_factual_counts(self):
        with self.workspace() as d:
            game,steam=self.fixture(Path(d).resolve());target=steam/'steamapps/common/Publisher Game';target.mkdir(parents=True);output=io.StringIO()
            with patch.object(sys,'argv',['steam_reuse.py','--game-folder',str(game),'--steam-root',str(steam),'--appid','10']),contextlib.redirect_stdout(output):result=main()
            self.assertEqual(result,0);self.assertEqual(len(output.getvalue().splitlines()),1);self.assertEqual(json.loads(output.getvalue())['clonedFiles'],2);self.no_stage(steam)


if __name__=='__main__':unittest.main()
