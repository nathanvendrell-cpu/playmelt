import contextlib
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

scripts=Path(__file__).resolve().parents[1]/'scripts';sys.path.insert(0,str(scripts))
spec=importlib.util.spec_from_file_location('spiderman2_profile',scripts/'spiderman2_profile.py')
p=importlib.util.module_from_spec(spec);spec.loader.exec_module(p)

class Tests(unittest.TestCase):
    def settings_fixture(self):
        head='[Software\\\\Insomniac Games\\\\Marvel\'s Spider-Man 2\\\\Graphics] 1\n'
        values=''.join('"'+name+'"=dword:0000000a\n' for name in p.GRAPHICS_NAMES)
        root='[Software\\\\Insomniac Games\\\\Marvel\'s Spider-Man 2] 1\n"FirstRun"=dword:00000000\n"englishVO"=dword:00000001\n"TextLanguage"=dword:00000006\n"ShowLauncher"=dword:00000001\n'
        return root+head+values+'[Software\\\\Wine\\\\Mac Driver] 1\n"RetinaMode"="Y"\n"CaptureDisplaysForFullscreen"="N"\n'
    def test_settings_parser_preserves_dynamic_values_and_types(self):
        selected=p.parse_settings(self.settings_fixture())
        self.assertEqual(selected['FullscreenWidth'],('dword','10'))
        self.assertEqual(selected['CaptureDisplaysForFullscreen'],('mac','N'))
        self.assertEqual(selected['FirstRun'],('root','0'));self.assertEqual(selected['TextLanguage'],('root','6'))
        self.assertEqual(set(selected),set(p.GRAPHICS_NAMES+p.MAC_NAMES+p.ROOT_NAMES))
    def test_settings_parser_rejects_missing_wrong_type_and_duplicates(self):
        fixture=self.settings_fixture()
        for broken in (fixture.replace('"CaptureDisplaysForFullscreen"="N"\n',''),
                       fixture.replace('"Fullscreen"=dword:0000000a','"Fullscreen"="1"'),
                       fixture.replace('"FirstRun"=dword:00000000','"FirstRun"=dword:00000001'),
                       fixture.replace('"TextLanguage"=dword:00000006','"TextLanguage"="6"'),
                       fixture.replace('"englishVO"=dword:00000001\n',''),
                       fixture.replace('"RetinaMode"="Y"','"RetinaMode"="Y"\n"RetinaMode"="N"')):
            with self.assertRaises(RuntimeError):p.parse_settings(broken)
    def test_explicit_modes_only(self):
        self.assertEqual(p.requested_mode(['runner','--prepare-only']),'--prepare-only')
        self.assertEqual(p.requested_mode(['runner','--run']),'--run')
        self.assertEqual(p.requested_mode(['runner','--run-msync-test']),'--run-msync-test')
        self.assertEqual(p.requested_mode(['runner','--run-server-test']),'--run-server-test')
        for args in (['runner'],['runner','--run','extra'],['runner','--other']):self.assertIsNone(p.requested_mode(args))
    def test_select_sync_qualification_and_explicit_overrides(self):
        plan={'engineFingerprint':p.QUALIFIED_SYNC_ENGINE,'rendererHash':p.QUALIFIED_SYNC_RENDERER,'environment':{'WINEMSYNC':'0','WINEESYNC':'0'}}
        for mode in ('--run','--prepare-only'):self.assertEqual(p.select_sync_mode(plan,mode),'msync')
        self.assertEqual(p.select_sync_mode(plan,'--run-server-test'),'server')
        unknown=dict(plan,rendererHash='different');self.assertIsNone(p.select_sync_mode(unknown,'--run'));self.assertEqual(p.select_sync_mode(unknown,'--run-msync-test'),'msync')
        self.assertEqual(plan['environment'],{'WINEMSYNC':'0','WINEESYNC':'0'})
        with self.assertRaises(ValueError):p.select_sync_mode(plan,'--injected')
    def test_game_hud_is_opt_in_and_preserves_sync(self):
        original={'WINEMSYNC':'1','WINEESYNC':'0','other':'x','MTL_HUD_ENABLED':'leaked'}
        for hud in (None,'0'):
            env=p.game_environment(original,'/wine',hud);self.assertNotIn('MTL_HUD_ENABLED',env);self.assertNotIn('MTL_HUD_LOG_ENABLED',env);self.assertEqual(env['WINEMSYNC'],'1')
        env=p.game_environment(original,'/wine','1');self.assertEqual((env['MTL_HUD_ENABLED'],env['MTL_HUD_LOG_ENABLED']),('1','1'));self.assertEqual((env['WINEMSYNC'],env['WINEESYNC']),('1','0'));self.assertEqual(env['PLAYMELT_WINE_EXECUTABLE'],'/wine')
        self.assertEqual(original,{'WINEMSYNC':'1','WINEESYNC':'0','other':'x','MTL_HUD_ENABLED':'leaked'})
        for invalid in ('','yes','2',True):
            with self.assertRaises(RuntimeError):p.game_environment(original,'/wine',invalid)
    def test_invalid_hud_is_rejected_before_any_wine_preparation(self):
        with mock.patch.object(sys,'argv',['runner','--run']),mock.patch.dict(os.environ,{'PLAYMELT_METAL_HUD':'invalid'}),mock.patch.object(p,'create_profile') as create:
            with self.assertRaises(RuntimeError):p.main()
            create.assert_not_called()
    def test_prepare_only_never_enters_game_experiment(self):
        with tempfile.TemporaryDirectory() as tmp,contextlib.ExitStack() as stack:
            root=Path(tmp).resolve();profile=root/'profile';profile.mkdir();resources=root/'resources';resources.mkdir();game=root/'game';game.mkdir();exe=game/'Spider-Man2.exe';exe.write_bytes(b'MZ')
            for name in ('m3-private-plan','spiderman-retina-default.exe'):(resources/name).write_bytes(b'fixture')
            checksum=p.digest(resources/'m3-private-plan');(resources/'spiderman-runtime-hashes.json').write_text(json.dumps(dict.fromkeys(('cas','probe','retina','settings','plan'),checksum)))
            for name,value in [('PROFILE',profile),('PREFIX',profile/'prefix'),('RESOURCES',resources),('RETINA',resources/'spiderman-retina-default.exe'),('GAME_DIR',game),('GAME',exe)]:stack.enter_context(mock.patch.object(p,name,value))
            stack.enter_context(mock.patch.object(sys,'argv',['runner','--prepare-only']))
            stack.enter_context(mock.patch.object(sys,'platform','darwin'))
            stack.enter_context(mock.patch.object(p.subprocess,'run',return_value=mock.Mock(stdout=b'{"wine":"/wine","server":"/server","environment":{}}')))
            fd=os.open(profile/'lock',os.O_CREAT|os.O_RDWR,0o600);stack.enter_context(mock.patch.object(p,'create_profile',return_value=fd))
            stack.enter_context(mock.patch.object(p,'seed_saves'));stack.enter_context(mock.patch.object(p,'seed_settings'));stack.enter_context(mock.patch.object(p,'read_preferences',return_value=None));stack.enter_context(mock.patch.object(p,'apply_preferences'))
            stack.enter_context(mock.patch.object(p.reuse,'require_idle_prefix'));stack.enter_context(mock.patch.object(p.tx,'private_environment',return_value={}))
            stack.enter_context(mock.patch.object(p.base,'Inspector'));stack.enter_context(mock.patch.object(p.base,'reap_child'))
            stack.enter_context(mock.patch.object(p.base,'run_command',return_value=(mock.Mock(poll=lambda:0),False,False)))
            def stop(server,env,directory,state):state['shutdown'].update({'-k':{'exit':0},'-w':{'exit':0}})
            stack.enter_context(mock.patch.object(p.base,'bounded_shutdown',side_effect=stop));experiment=stack.enter_context(mock.patch.object(p.experiment,'main'))
            self.assertEqual(p.main(),0);experiment.assert_not_called()
    def test_run_imports_settings_before_game(self):
        with tempfile.TemporaryDirectory() as tmp,contextlib.ExitStack() as stack:
            root=Path(tmp).resolve();profile=root/'profile';profile.mkdir();resources=root/'resources';resources.mkdir();game=root/'game';game.mkdir();exe=game/'Spider-Man2.exe';exe.write_bytes(b'MZ')
            for name in ('m3-private-plan','spiderman-retina-default.exe'):(resources/name).write_bytes(b'fixture')
            checksum=p.digest(resources/'m3-private-plan');(resources/'spiderman-runtime-hashes.json').write_text(json.dumps(dict.fromkeys(('cas','probe','retina','settings','plan'),checksum)))
            for name,value in [('PROFILE',profile),('PREFIX',profile/'prefix'),('RESOURCES',resources),('RETINA',resources/'spiderman-retina-default.exe'),('GAME_DIR',game),('GAME',exe)]:stack.enter_context(mock.patch.object(p,name,value))
            stack.enter_context(mock.patch.object(sys,'argv',['runner','--run']));stack.enter_context(mock.patch.object(sys,'platform','darwin'))
            stack.enter_context(mock.patch.object(p.subprocess,'run',return_value=mock.Mock(stdout=b'{"wine":"/wine","server":"/server","environment":{}}')))
            fd=os.open(profile/'lock',os.O_CREAT|os.O_RDWR,0o600);stack.enter_context(mock.patch.object(p,'create_profile',return_value=fd));calls=[]
            stack.enter_context(mock.patch.object(p,'read_preferences',return_value=None));stack.enter_context(mock.patch.object(p,'apply_preferences'))
            stack.enter_context(mock.patch.object(p,'seed_saves',side_effect=lambda:calls.append('saves')))
            stack.enter_context(mock.patch.object(p,'seed_settings',side_effect=lambda *a:calls.append('settings')))
            stack.enter_context(mock.patch.object(p.reuse,'require_idle_prefix'));stack.enter_context(mock.patch.object(p.tx,'private_environment',return_value={}))
            stack.enter_context(mock.patch.object(p.base,'Inspector'));stack.enter_context(mock.patch.object(p.base,'reap_child'))
            stack.enter_context(mock.patch.object(p.base,'run_command',return_value=(mock.Mock(poll=lambda:0),False,False)))
            def stop(server,env,directory,state):state['shutdown'].update({'-k':{'exit':0},'-w':{'exit':0}})
            stack.enter_context(mock.patch.object(p.base,'bounded_shutdown',side_effect=stop));stack.enter_context(mock.patch.object(p,'crash_snapshot',return_value={}));stack.enter_context(mock.patch.object(p,'new_crash',return_value='none'))
            stack.enter_context(mock.patch.object(p.experiment,'main',side_effect=lambda:(calls.append('game'),0)[1]))
            self.assertEqual(p.main(),0);self.assertEqual(calls,['saves','settings','game'])
    def test_msync_mode_passes_explicit_request(self):
        with tempfile.TemporaryDirectory() as tmp,contextlib.ExitStack() as stack:
            root=Path(tmp).resolve();profile=root/'profile';profile.mkdir();resources=root/'resources';resources.mkdir();game=root/'game';game.mkdir();exe=game/'Spider-Man2.exe';exe.write_bytes(b'MZ')
            for name in ('m3-private-plan','spiderman-retina-default.exe'):(resources/name).write_bytes(b'fixture')
            checksum=p.digest(resources/'m3-private-plan');(resources/'spiderman-runtime-hashes.json').write_text(json.dumps(dict.fromkeys(('cas','probe','retina','settings','plan'),checksum)))
            for name,value in [('PROFILE',profile),('PREFIX',profile/'prefix'),('RESOURCES',resources),('RETINA',resources/'spiderman-retina-default.exe'),('GAME_DIR',game),('GAME',exe)]:stack.enter_context(mock.patch.object(p,name,value))
            stack.enter_context(mock.patch.object(sys,'argv',['runner','--run-msync-test']));stack.enter_context(mock.patch.object(sys,'platform','darwin'))
            stack.enter_context(mock.patch.object(p.subprocess,'run',return_value=mock.Mock(stdout=b'{"wine":"/wine","server":"/server","environment":{"WINEMSYNC":"0","WINEESYNC":"0"}}')))
            fd=os.open(profile/'lock',os.O_CREAT|os.O_RDWR,0o600);stack.enter_context(mock.patch.object(p,'create_profile',return_value=fd));calls=[]
            stack.enter_context(mock.patch.object(p,'read_preferences',return_value=None));stack.enter_context(mock.patch.object(p,'apply_preferences'))
            stack.enter_context(mock.patch.object(p,'seed_saves',side_effect=lambda:calls.append('saves')))
            stack.enter_context(mock.patch.object(p,'seed_settings',side_effect=lambda *a:calls.append('settings')))
            stack.enter_context(mock.patch.object(p.reuse,'require_idle_prefix'));stack.enter_context(mock.patch.object(p.tx,'private_environment',return_value={}))
            stack.enter_context(mock.patch.object(p.base,'Inspector'));stack.enter_context(mock.patch.object(p.base,'reap_child'))
            stack.enter_context(mock.patch.object(p.base,'run_command',return_value=(mock.Mock(poll=lambda:0),False,False)))
            def stop(server,env,directory,state):state['shutdown'].update({'-k':{'exit':0},'-w':{'exit':0}})
            stack.enter_context(mock.patch.object(p.base,'bounded_shutdown',side_effect=stop));stack.enter_context(mock.patch.object(p,'crash_snapshot',return_value={}));stack.enter_context(mock.patch.object(p,'new_crash',return_value='none'))
            stack.enter_context(mock.patch.object(p.experiment,'main',side_effect=lambda **kw:(calls.append(('game',kw)),0)[1]))
            self.assertEqual(p.main(),0);self.assertEqual(calls,['saves','settings',('game',{'sync_mode':'msync','expected_identity':(None,None)})])
    def test_bootstrap_only_new_owned_prefix_and_reuse_idempotently(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp).resolve();d3d=root/'D3DMetal';d3d.mkdir(mode=0o700)
            profile=d3d/'Games/2651280';prefix=profile/'prefix'
            plan={'wine':'/wine','server':'/server','rendererHash':'renderer','engineFingerprint':'engine','environment':{}}
            class Child:
                def poll(self):return 0
            def fake_boot(*args):
                (prefix/'system.reg').write_text('fixture');(prefix/'user.reg').write_text('fixture')
                return Child(),False,False
            def fake_stop(server,env,directory,state):state['shutdown'].update({'-k':{'exit':0},'-w':{'exit':0}})
            with contextlib.ExitStack() as stack:
                stack.enter_context(mock.patch.object(p,'PROFILE',profile));stack.enter_context(mock.patch.object(p,'PREFIX',prefix))
                stack.enter_context(mock.patch.object(p.reuse,'require_idle_prefix'))
                boot=stack.enter_context(mock.patch.object(p.base,'run_command',side_effect=fake_boot))
                stack.enter_context(mock.patch.object(p.base,'bounded_shutdown',side_effect=fake_stop))
                stack.enter_context(mock.patch.object(p.base,'reap_child'))
                stack.enter_context(mock.patch.object(p.base,'Inspector',return_value=None))
                fd=p.create_profile(plan);fcntl.flock(fd,fcntl.LOCK_UN);os.close(fd)
                self.assertEqual(json.loads((profile/'profile-owner.json').read_text())['status'],'ready')
                fd=p.create_profile(plan);fcntl.flock(fd,fcntl.LOCK_UN);os.close(fd)
                self.assertEqual(boot.call_count,1)
    def test_existing_unknown_profile_is_preserved_and_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp).resolve();parent=root/'Games';parent.mkdir(mode=0o700);profile=parent/'2651280';profile.mkdir(mode=0o700)
            sentinel=profile/'data';sentinel.write_text('preserve')
            with mock.patch.object(p,'PROFILE',profile),mock.patch.object(p,'PREFIX',profile/'prefix'):
                with self.assertRaises(RuntimeError):p.create_profile({'environment':{}})
            self.assertEqual(sentinel.read_text(),'preserve')

    def test_source_config_optional_private_and_non_overlapping(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp).resolve();profile=root/'profile';profile.mkdir();source=root/'source';source.mkdir()
            with mock.patch.object(p,'PROFILE',profile),mock.patch.object(p,'PREFIX',profile/'prefix'):
                self.assertIsNone(p.migration_source())
                config=profile/'source-import.json';config.write_text(json.dumps({'schema':1,'source_prefix':str(source)}));config.chmod(0o600)
                self.assertEqual(p.migration_source(),source)
                config.chmod(0o644)
                with self.assertRaises(RuntimeError):p.migration_source()
                config.chmod(0o600);config.write_text(json.dumps({'schema':1,'source_prefix':str(profile)}))
                with self.assertRaises(RuntimeError):p.migration_source()

    def test_staged_profile_bootstraps_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp).resolve();parent=root/'Games';parent.mkdir(mode=0o700);profile=parent/'2651280';profile.mkdir(mode=0o700)
            (profile/'resources').mkdir(mode=0o700)
            (profile/'profile-owner.json').write_text(json.dumps({'owner':'playmelt-spiderman2','schema':1,'status':'staged'}))
            prefix=profile/'prefix';plan={'wine':'/wine','server':'/server','rendererHash':'r','engineFingerprint':'e','environment':{}}
            class Child:
                def poll(self):return 0
            def boot(*args):
                (prefix/'system.reg').write_text('ok');(prefix/'user.reg').write_text('ok');return Child(),False,False
            def stop(server,env,directory,state):state['shutdown'].update({'-k':{'exit':0},'-w':{'exit':0}})
            with mock.patch.object(p,'PROFILE',profile),mock.patch.object(p,'PREFIX',prefix),mock.patch.object(p.reuse,'require_idle_prefix'),mock.patch.object(p.base,'run_command',side_effect=boot),mock.patch.object(p.base,'bounded_shutdown',side_effect=stop),mock.patch.object(p.base,'reap_child'),mock.patch.object(p.base,'Inspector'):
                fd=p.create_profile(plan);fcntl.flock(fd,fcntl.LOCK_UN);os.close(fd)
            self.assertEqual(json.loads((profile/'profile-owner.json').read_text())['status'],'ready')

    def test_import_only_three_saves_and_never_overwrite_progress(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp).resolve(); test=root/'test'; profile=root/'profile'; prefix=profile/'prefix';profile.mkdir();prefix.mkdir();test.mkdir()
            sid='76561198000000000'; source=test/"drive_c/users/testuser/Documents/Marvel's Spider-Man 2"/sid;source.mkdir(parents=True)
            names=('prefs-autosave.save','slot1-manual-0.save','slot1-autosave.save')
            for i,n in enumerate(names):(source/n).write_bytes(('save'+str(i)).encode())
            (source/'slot2-manual-0.save').write_bytes(b'new-progress')
            (source/'extra').mkdir();(source/'extra/backup.save').write_bytes(b'backup')
            (source/'steam_autocloud.vdf').write_text('do not copy')
            (prefix/'drive_c/users/testuser').mkdir(parents=True)
            with mock.patch.object(p,'PROFILE',profile),mock.patch.object(p,'PREFIX',prefix),mock.patch.object(p,'migration_source',return_value=test),mock.patch.object(p.reuse,'require_idle_prefix') as idle:
                p.seed_saves();self.assertEqual(idle.call_count,2)
                target=prefix/"drive_c/users/testuser/Documents/Marvel's Spider-Man 2"/sid
                self.assertEqual(sorted(x.name for x in target.iterdir()),sorted(names+('slot2-manual-0.save','extra')))
                self.assertEqual((target/'extra/backup.save').read_bytes(),b'backup')
                (target/names[1]).write_bytes(b'user progress')
                p.seed_saves();self.assertEqual((target/names[1]).read_bytes(),b'user progress')
                self.assertTrue(json.loads((profile/'save-import.json').read_text())['complete'])
    def test_import_refuses_existing_changed_save(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp).resolve();test=root/'test';profile=root/'profile';prefix=profile/'prefix';profile.mkdir();prefix.mkdir();test.mkdir()
            source=test/"drive_c/users/testuser/Documents/Marvel's Spider-Man 2/1234567890";source.mkdir(parents=True)
            names=('prefs-autosave.save','slot1-manual-0.save','slot1-autosave.save')
            for n in names:(source/n).write_bytes(b'from-test')
            target=prefix/"drive_c/users/testuser/Documents/Marvel's Spider-Man 2/1234567890";target.mkdir(parents=True)
            (target/names[0]).write_bytes(b'keep-me')
            with mock.patch.object(p,'PROFILE',profile),mock.patch.object(p,'PREFIX',prefix),mock.patch.object(p,'migration_source',return_value=test),mock.patch.object(p.reuse,'require_idle_prefix'):
                with self.assertRaises(RuntimeError):p.seed_saves()
            self.assertEqual((target/names[0]).read_bytes(),b'keep-me');self.assertFalse((profile/'save-import.json').exists())
    def test_destination_symlink_rejected_before_creating_outside(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp).resolve();test=root/'test';profile=root/'profile';prefix=profile/'prefix';outside=root/'outside'
            profile.mkdir();prefix.mkdir();test.mkdir();outside.mkdir()
            source=test/"drive_c/users/testuser/Documents/Marvel's Spider-Man 2/1234567890";source.mkdir(parents=True)
            (source/'prefs-autosave.save').write_bytes(b'save')
            user=prefix/'drive_c/users/testuser';user.mkdir(parents=True);(user/'Documents').symlink_to(outside,target_is_directory=True)
            with mock.patch.object(p,'PROFILE',profile),mock.patch.object(p,'PREFIX',prefix),mock.patch.object(p,'migration_source',return_value=test),mock.patch.object(p.reuse,'require_idle_prefix'):
                with self.assertRaises(RuntimeError):p.seed_saves()
            self.assertEqual(list(outside.iterdir()),[])
    def test_crash_detection_ignores_old_and_detects_new_reports(self):
        with tempfile.TemporaryDirectory() as tmp:
            prefix=Path(tmp).resolve();docs=prefix/"drive_c/users/u/Documents/Marvel's Spider-Man 2";docs.mkdir(parents=True)
            log=docs/"Marvel's Spider-Man 2.log";log.write_text('old [Crash] prior\n')
            old=docs/'old.mdmp';old.write_bytes(b'prior')
            with mock.patch.object(p,'PREFIX',prefix):
                before=p.crash_snapshot();self.assertEqual(p.new_crash(before,p.crash_snapshot()),'none')
                with log.open('a') as f:f.write('normal new session\n')
                self.assertEqual(p.new_crash(before,p.crash_snapshot()),'none')
                reports=prefix/"drive_c/users/u/AppData/Roaming/Insomniac Games/Marvel's Spider-Man 2/crs/reports";reports.mkdir(parents=True)
                (reports/'new.dmp').write_bytes(b'new');self.assertEqual(p.new_crash(before,p.crash_snapshot()),'crash')
    def test_crash_marker_after_truncation_and_large_log_unknown(self):
        with tempfile.TemporaryDirectory() as tmp:
            prefix=Path(tmp).resolve();docs=prefix/"drive_c/users/u/Documents/Marvel's Spider-Man 2";docs.mkdir(parents=True)
            log=docs/"Marvel's Spider-Man 2.log";log.write_bytes(b'a'*100)
            with mock.patch.object(p,'PREFIX',prefix):
                before=p.crash_snapshot();log.write_bytes(b'[Crash] '+b'b'*110)
                self.assertEqual(p.new_crash(before,p.crash_snapshot()),'crash')
                before=p.crash_snapshot();log.write_bytes(b'x'*(4*1024*1024+10))
                self.assertEqual(p.new_crash(before,p.crash_snapshot()),'unknown')
    def test_wait_drains_after_cap_without_empty_writes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);game=root/'fixture.py';game.write_text('import os;os.write(1,b"x"*100000)')
            class Inspector:
                def identity(self,pid):return {'pid':pid,'uid':os.geteuid(),'start_sec':1,'start_usec':0,'path':'/fake','status':1,'ppid':os.getpid()}
                def snapshot(self,marker):return [],[]
            class Log:
                def __init__(self):self.data=b''
                def write(self,data):
                    if not data:raise AssertionError('empty write')
                    self.data+=data
                def flush(self):pass
            log=Log()
            with mock.patch.object(p,'GAME',game),mock.patch.object(p.base,'MAX_LOG',2):
                child,timed,capped=p.wait_game(lambda *a:None,[sys.executable,str(game)],{'PLAYMELT_WINE_EXECUTABLE':sys.executable},str(root),log,120,Inspector(),'marker',{})
                p.base.reap_child(child)
            self.assertFalse(timed);self.assertTrue(capped);self.assertEqual(log.data,b'xx');self.assertEqual(child.returncode,0)
    def test_game_wait_is_unbounded_and_adds_only_nolauncher(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp).resolve();game=root/'fixture.py';game.write_text('import sys; print("args="+repr(sys.argv[1:]),flush=True)')
            class Inspector:
                def identity(self,pid):return {'pid':pid,'uid':os.geteuid(),'start_sec':1,'start_usec':0,'path':'/fake','status':1,'ppid':os.getpid()}
            with mock.patch.object(p,'GAME',game):
                with (root/'game.log').open('wb',buffering=0) as log:
                    child,timed,capped=p.wait_game(lambda *a:None,[sys.executable,str(game)],{'PLAYMELT_WINE_EXECUTABLE':sys.executable},str(root),log,120,Inspector(),'marker',{})
                    p.base.reap_child(child)
            self.assertFalse(timed);self.assertFalse(capped);self.assertIn("'-nolauncher'",(root/'game.log').read_text())

class PreferenceTests(unittest.TestCase):
    def fixture(self):
        return {'schemaVersion':2,'applyFields':['launchArgs','display.screenID','graphics.upscaler','graphics.frameGeneration'],'gameKey':'steam-2651280-windows','revision':'8a4e05b8-fbf2-4a0c-86d7-519c4fa68d92','settings':{'backend':'auto','launchArgs':'--example "two words"','display':{'mode':'fullscreen','width':2560,'height':1440,'refreshRate':60,'retina':'auto','screenID':'primary','vsync':True,'hdr':False},'graphics':{'upscaler':'fsr','quality':'quality','dynamicFPS':60,'frameGeneration':True,'grain':0.2,'sharpness':0.7}}}
    def test_strict_preferences_and_argv(self):
        with tempfile.TemporaryDirectory() as td:
            f=Path(td)/'settings.json'; data=self.fixture();f.write_text(json.dumps(data))
            prefs=p.read_preferences(f);self.assertEqual(prefs[1],['--example','two words'])
            data['settings']['graphics']['frameGeneration']=1;f.write_text(json.dumps(data))
            with self.assertRaises(RuntimeError):p.read_preferences(f)
            f.write_text('{"schemaVersion":1,"schemaVersion":1}')
            with self.assertRaises(RuntimeError):p.read_preferences(f)
    def test_windows_path_lexing(self):
        self.assertEqual(p.split_launch_args(r'--path C:\Games\SM2 "two words" one\ two'),['--path',r'C:\Games\SM2','two words','one two'])
        with self.assertRaises(RuntimeError):p.split_launch_args('"unfinished')
    def test_argument_controls_and_masks(self):
        with tempfile.TemporaryDirectory() as td:
            f=Path(td)/'settings.json';data=self.fixture()
            for arg,expected in [('--a\t--b',['--a','--b']), (r'--p C:\Games\SM2 one\ two "hello" $(x)', ['--p',r'C:\Games\SM2','one two','hello','$(x)'])]:
                data['settings']['launchArgs']=arg;f.write_text(json.dumps(data));self.assertEqual(p.read_preferences(f)[1],expected)
            for arg in ['"a\tb"','a\x7fb','a\u200bb']:
                data['settings']['launchArgs']=arg;f.write_text(json.dumps(data))
                with self.assertRaises(RuntimeError):p.read_preferences(f)
            data['settings']['launchArgs']='--a';data['applyFields']=[];f.write_text(json.dumps(data));self.assertEqual(p.read_preferences(f)[1],[])
            data['applyFields']=['launchArgs','graphics.frameGeneration','display.hdr'];f.write_text(json.dumps(data));self.assertEqual(p.read_preferences(f)[0]['applyFields'],data['applyFields'])
            data['applyFields']=['bad.field'];f.write_text(json.dumps(data))
            with self.assertRaises(RuntimeError):p.read_preferences(f)
    def test_mask_only_changes_requested_values_and_uses_current_monitor(self):
        with tempfile.TemporaryDirectory() as td,contextlib.ExitStack() as stack:
            root=Path(td);prefix=root/'prefix';prefix.mkdir();reg=prefix/'user.reg'
            reg.write_text('[Software\\\\Wine\\\\Mac Driver] 1\n"RetinaMode"="Y"\n\n[Software\\\\Insomniac Games\\\\Marvel\'s Spider-Man 2\\\\Graphics] 1\n"Monitor"=dword:00000001\n"UpscaleMethod"=dword:00000000\n"FrameGen"=dword:00000001\n"HDR"=dword:00000001\n')
            stack.enter_context(mock.patch.object(p,'PROFILE',root));stack.enter_context(mock.patch.object(p,'PREFIX',prefix));stack.enter_context(mock.patch.object(p.reuse,'require_idle_prefix'))
            data=self.fixture();data['applyFields']=['launchArgs'];primary={'id':'primary','scale':2,'wineIndex':0};current={'id':'external','scale':1,'wineIndex':1}
            plan={'displayHints':{'primary':primary,'displays':[primary,current]}};p.apply_preferences(plan,(data,[]));out=reg.read_text()
            for item in ['"RetinaMode"="N"','"Monitor"=dword:00000001','"UpscaleMethod"=dword:00000000','"HDR"=dword:00000001']:self.assertIn(item,out)
            data['revision']='a745773e-5717-49ea-9c78-f26dfcb466c4';data['applyFields']=['graphics.frameGeneration','display.hdr'];data['settings']['graphics']['frameGeneration']=False;data['settings']['display']['hdr']=False
            p.apply_preferences(plan,(data,[]));out=reg.read_text();self.assertIn('"FrameGen"=dword:00000000',out);self.assertIn('"HDR"=dword:00000000',out);self.assertIn('"UpscaleMethod"=dword:00000000',out)
    def test_revision_delta_preserves_game_changes_and_allows_retouch(self):
        with tempfile.TemporaryDirectory() as td,contextlib.ExitStack() as stack:
            root=Path(td);prefix=root/'prefix';prefix.mkdir();reg=prefix/'user.reg'
            reg.write_text('[Software\\\\Wine\\\\Mac Driver] 1\n"RetinaMode"="Y"\n\n[Software\\\\Insomniac Games\\\\Marvel\'s Spider-Man 2\\\\Graphics] 1\n"FullscreenWidth"=dword:00000d80\n"UpscaleMethod"=dword:00000000\n')
            stack.enter_context(mock.patch.object(p,'PROFILE',root));stack.enter_context(mock.patch.object(p,'PREFIX',prefix));stack.enter_context(mock.patch.object(p.reuse,'require_idle_prefix'))
            plan={'displayHints':{'primary':{'scale':2,'wineIndex':0},'displays':[]}}
            data=self.fixture();data['schemaVersion']=3;data['applyFields']=['launchArgs','display.width','graphics.upscaler'];data['fieldRevisions']={k:data['revision'] for k in data['applyFields']}
            p.apply_preferences(plan,(data,['--example']));self.assertIn('"FullscreenWidth"=dword:00000a00',reg.read_text())
            text=reg.read_text().replace('"FullscreenWidth"=dword:00000a00','"FullscreenWidth"=dword:00000d80').replace('"UpscaleMethod"=dword:00000003','"UpscaleMethod"=dword:00000000');reg.write_text(text)
            p.apply_preferences(plan,(data,['--example']));self.assertEqual(reg.read_text(),text)
            data['revision']='a745773e-5717-49ea-9c78-f26dfcb466c4';data['fieldRevisions']['launchArgs']=data['revision'];p.apply_preferences(plan,(data,['--example']));self.assertEqual(reg.read_text(),text)
            self.assertEqual(json.loads((root/'preferences-journal.json').read_text())['revision'],data['revision'])
            data['revision']='f2c859d0-3687-40fc-bb48-e9e4143de5c5';data['fieldRevisions']['display.width']=data['revision'];p.apply_preferences(plan,(data,[]));self.assertIn('"FullscreenWidth"=dword:00000a00',reg.read_text());self.assertIn('"UpscaleMethod"=dword:00000000',reg.read_text())
    def test_two_saved_field_revisions_are_both_applied_once(self):
        with tempfile.TemporaryDirectory() as td,contextlib.ExitStack() as stack:
            root=Path(td);prefix=root/'prefix';prefix.mkdir();reg=prefix/'user.reg'
            reg.write_text('[Software\\\\Insomniac Games\\\\Marvel\'s Spider-Man 2\\\\Graphics] 1\n"FullscreenWidth"=dword:00000d80\n"FullscreenHeight"=dword:000008ba\n')
            stack.enter_context(mock.patch.object(p,'PROFILE',root));stack.enter_context(mock.patch.object(p,'PREFIX',prefix));stack.enter_context(mock.patch.object(p.reuse,'require_idle_prefix'))
            data=self.fixture();r1='a745773e-5717-49ea-9c78-f26dfcb466c4';r2='f2c859d0-3687-40fc-bb48-e9e4143de5c5'
            data.update(schemaVersion=3,revision=r2,applyFields=['display.width','display.height'],fieldRevisions={'display.width':r1,'display.height':r2})
            (root/'preferences-journal.json').write_text(json.dumps({'state':'committed','revision':self.fixture()['revision']}))
            p.apply_preferences({},(data,[]));out=reg.read_text();self.assertIn('"FullscreenWidth"=dword:00000a00',out);self.assertIn('"FullscreenHeight"=dword:000005a0',out)
            self.assertEqual(json.loads((root/'preferences-journal.json').read_text())['appliedFieldRevisions'],data['fieldRevisions'])
            out=out.replace('"FullscreenWidth"=dword:00000a00','"FullscreenWidth"=dword:00000d80');reg.write_text(out);p.apply_preferences({},(data,[]));self.assertEqual(reg.read_text(),out)
    def test_v2_committed_revision_and_noop_revision_do_not_rewrite_registry(self):
        with tempfile.TemporaryDirectory() as td,contextlib.ExitStack() as stack:
            root=Path(td);prefix=root/'prefix';prefix.mkdir();reg=prefix/'user.reg'
            text='[Software\\\\Insomniac Games\\\\Marvel\'s Spider-Man 2\\\\Graphics] 1\n"FullscreenWidth"=dword:00000d80\n';reg.write_text(text)
            data=self.fixture();data['applyFields']=['display.width','launchArgs'];(root/'preferences-journal.json').write_text(json.dumps({'state':'committed','revision':data['revision']}))
            stack.enter_context(mock.patch.object(p,'PROFILE',root));stack.enter_context(mock.patch.object(p,'PREFIX',prefix));stack.enter_context(mock.patch.object(p.reuse,'require_idle_prefix'))
            inode=reg.stat().st_ino;p.apply_preferences({},(data,[]));self.assertEqual(reg.read_text(),text);self.assertEqual(reg.stat().st_ino,inode)
            data['schemaVersion']=3;data['revision']='a745773e-5717-49ea-9c78-f26dfcb466c4';data['fieldRevisions']={'display.width':self.fixture()['revision'],'launchArgs':data['revision']};p.apply_preferences({},(data,[]))
            self.assertEqual(reg.stat().st_ino,inode);self.assertEqual(json.loads((root/'preferences-journal.json').read_text())['revision'],data['revision'])
    def test_consumed_v2_and_v3_args_preserve_max_graphics(self):
        with tempfile.TemporaryDirectory() as td,contextlib.ExitStack() as stack:
            root=Path(td);prefix=root/'prefix';prefix.mkdir();reg=prefix/'user.reg'
            text='[Software\\\\Insomniac Games\\\\Marvel\'s Spider-Man 2\\\\Graphics] 1\n"FullscreenWidth"=dword:00000d80\n"FullscreenHeight"=dword:000008ba\n"HDR"=dword:00000001\n"FrameGen"=dword:00000001\n"RTReflections"=dword:00000003\n"UpscaleMethod"=dword:00000000\n';reg.write_text(text)
            data=self.fixture();data['applyFields']=['display.width','display.height','display.hdr','graphics.frameGeneration','graphics.upscaler','launchArgs'];(root/'preferences-journal.json').write_text(json.dumps({'state':'committed','revision':data['revision']}))
            stack.enter_context(mock.patch.object(p,'PROFILE',root));stack.enter_context(mock.patch.object(p,'PREFIX',prefix));stack.enter_context(mock.patch.object(p.reuse,'require_idle_prefix'))
            p.apply_preferences({},(data,[]));self.assertEqual(reg.read_text(),text)
            oldrev=data['revision'];data['schemaVersion']=3;data['revision']='a745773e-5717-49ea-9c78-f26dfcb466c4';data['fieldRevisions']={k:oldrev for k in data['applyFields']};data['fieldRevisions']['launchArgs']=data['revision']
            p.apply_preferences({},(data,[]));self.assertEqual(reg.read_text(),text)
    def test_upscale_sharpness_preserves_general_sharpness(self):
        with tempfile.TemporaryDirectory() as td,contextlib.ExitStack() as stack:
            root=Path(td);prefix=root/'prefix';prefix.mkdir();reg=prefix/'user.reg'
            reg.write_text('[Software\\\\Insomniac Games\\\\Marvel\'s Spider-Man 2\\\\Graphics] 1\n"Sharpness"=dword:000001f4\n"UpscaleSharpness"=dword:00000000\n')
            stack.enter_context(mock.patch.object(p,'PROFILE',root));stack.enter_context(mock.patch.object(p,'PREFIX',prefix));stack.enter_context(mock.patch.object(p.reuse,'require_idle_prefix'))
            data=self.fixture();data['applyFields']=['graphics.sharpness'];p.apply_preferences({},(data,[]));out=reg.read_text()
            self.assertIn('"Sharpness"=dword:000001f4',out);self.assertIn('"UpscaleSharpness"=dword:000002bc',out)
    def test_v3_validation_and_persistent_args(self):
        with tempfile.TemporaryDirectory() as td:
            f=Path(td)/'settings.json';data=self.fixture();data['schemaVersion']=3;data['fieldRevisions']={k:data['revision'] for k in data['applyFields']};f.write_text(json.dumps(data))
            self.assertEqual(p.read_preferences(f)[1],['--example','two words'])
            data['fieldRevisions']['unknown']=data['revision'];f.write_text(json.dumps(data))
            with self.assertRaises(RuntimeError):p.read_preferences(f)
            data['fieldRevisions']={k:data['revision'].upper() for k in data['applyFields']};f.write_text(json.dumps(data))
            with self.assertRaises(RuntimeError):p.read_preferences(f)
    def test_v1_rejected_and_utf8_byte_limit(self):
        with tempfile.TemporaryDirectory() as td:
            f=Path(td)/'settings.json';data=self.fixture();data['schemaVersion']=1;f.write_text(json.dumps(data))
            with self.assertRaises(RuntimeError):p.read_preferences(f)
            data['schemaVersion']=2;data['settings']['launchArgs']='é'*1025;f.write_text(json.dumps(data))
            with self.assertRaises(RuntimeError):p.read_preferences(f)
    def test_auto_retina_and_graphics_transaction(self):
        with tempfile.TemporaryDirectory() as td,contextlib.ExitStack() as stack:
            root=Path(td);prefix=root/'prefix';prefix.mkdir();reg=prefix/'user.reg'
            reg.write_text('[Software\\\\Wine\\\\Mac Driver] 1\n"RetinaMode"="Y"\n\n[Software\\\\Insomniac Games\\\\Marvel\'s Spider-Man 2\\\\Graphics] 1\n"HDR"=dword:00000001\n')
            stack.enter_context(mock.patch.object(p,'PROFILE',root));stack.enter_context(mock.patch.object(p,'PREFIX',prefix));stack.enter_context(mock.patch.object(p.reuse,'require_idle_prefix'))
            screen={'id':'foo','scale':1,'wineIndex':0};p.apply_preferences({'displayHints':{'primary':screen,'displays':[screen]}},(self.fixture(),[]))
            out=reg.read_text();self.assertIn('"RetinaMode"="N"',out);self.assertIn('"UpscaleMethod"=dword:00000003',out);self.assertIn('"FrameGen"=dword:00000001',out);self.assertIn('"Monitor"=dword:00000000',out)
            receipt=json.loads((root/'preferences-journal.json').read_text());self.assertEqual(receipt['state'],'committed');self.assertTrue(any(c['name']=='RetinaMode' and c['before']=='"Y"' for c in receipt['changes']))
    def test_unfinished_journal_never_overwrites_registry(self):
        with tempfile.TemporaryDirectory() as td,contextlib.ExitStack() as stack:
            root=Path(td);prefix=root/'prefix';prefix.mkdir();reg=prefix/'user.reg';reg.write_text('user-change')
            (root/'preferences-journal.json').write_text('{"state":"prepared"}')
            stack.enter_context(mock.patch.object(p,'PROFILE',root));stack.enter_context(mock.patch.object(p,'PREFIX',prefix));stack.enter_context(mock.patch.object(p.reuse,'require_idle_prefix'))
            with self.assertRaisesRegex(RuntimeError,'unresolved'):p.apply_preferences({},None)
            self.assertEqual(reg.read_text(),'user-change')
    def test_missing_screen_falls_back_to_primary(self):
        with tempfile.TemporaryDirectory() as td,contextlib.ExitStack() as stack:
            root=Path(td);prefix=root/'prefix';prefix.mkdir();reg=prefix/'user.reg'
            reg.write_text('[Software\\\\Wine\\\\Mac Driver] 1\n"RetinaMode"="Y"\n\n[Software\\\\Insomniac Games\\\\Marvel\'s Spider-Man 2\\\\Graphics] 1\n')
            stack.enter_context(mock.patch.object(p,'PROFILE',root));stack.enter_context(mock.patch.object(p,'PREFIX',prefix));stack.enter_context(mock.patch.object(p.reuse,'require_idle_prefix'))
            data=self.fixture();data['settings']['display']['screenID']='8a4e05b8-fbf2-4a0c-86d7-519c4fa68d92'
            primary={'id':'other','scale':1,'wineIndex':1};p.apply_preferences({'displayHints':{'primary':primary,'displays':[primary]}},(data,[]))
            receipt=json.loads((root/'preferences-journal.json').read_text());self.assertTrue(receipt['screenFallback']);self.assertIn('"Monitor"=dword:00000001',reg.read_text())
    def test_unknown_scale_does_not_change_retina_without_preferences(self):
        with tempfile.TemporaryDirectory() as td,contextlib.ExitStack() as stack:
            root=Path(td);prefix=root/'prefix';prefix.mkdir();reg=prefix/'user.reg';text='[Software\\\\Wine\\\\Mac Driver] 1\n"RetinaMode"="N"\n';reg.write_text(text)
            stack.enter_context(mock.patch.object(p,'PROFILE',root));stack.enter_context(mock.patch.object(p,'PREFIX',prefix));stack.enter_context(mock.patch.object(p.reuse,'require_idle_prefix'))
            p.apply_preferences({'displayHints':{'primary':{'scale':1.5}}},None);self.assertEqual(reg.read_text(),text)
    def test_nvidia_bridge_backend_dlss_upscaling_and_environment(self):
        with tempfile.TemporaryDirectory() as td,contextlib.ExitStack() as stack:
            root=Path(td);prefix=root/'prefix';prefix.mkdir();reg=prefix/'user.reg'
            reg.write_text('[Software\\\\Wine\\\\Mac Driver] 1\n"RetinaMode"="Y"\n\n[Software\\\\Insomniac Games\\\\Marvel\'s Spider-Man 2\\\\Graphics] 1\n"UpscaleMethod"=dword:00000000\n')
            stack.enter_context(mock.patch.object(p,'PROFILE',root));stack.enter_context(mock.patch.object(p,'PREFIX',prefix));stack.enter_context(mock.patch.object(p.reuse,'require_idle_prefix'))
            data=self.fixture();data['settings']['backend']='d3dmetal-nv';data['settings']['graphics']['upscaler']='dlss'
            data['applyFields']=['graphics.upscaler']
            p.apply_preferences({},(data,[]))
            out=reg.read_text()
            self.assertIn('"UpscaleMethod"=dword:00000002',out)
        env=p.game_environment({'WINEDLLOVERRIDES':'d3d12=n,b;'},'/wine',None,backend='d3dmetal-nv')
        self.assertEqual(env['D3DM_ENABLE_METALFX'],'1')
        self.assertEqual(env['WINEDLLOVERRIDES'],'nvapi64,nvngx=b,n;d3d12=n,b;')

if __name__=='__main__':unittest.main()
