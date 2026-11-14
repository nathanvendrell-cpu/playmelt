#!/usr/bin/env python3
"""Offline operation fixtures; no account, credential store, game or network."""
import hashlib, importlib.util, json, os
from pathlib import Path
import subprocess, sys, tempfile, unittest
from types import SimpleNamespace
from unittest.mock import patch
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("epic_base_fixtures", Path(__file__).with_name("epic-worker-test.py"))
base = importlib.util.module_from_spec(spec); spec.loader.exec_module(base)
worker = base.worker
DATA = b"MZ offline installed executable fixture"

class Downloader:
    def __init__(self, mode): self.mode=mode; self.pid=None; self.exitcode=0; self.alive=False; self.stopped=False; self.joined=0
    def start(self): self.pid=123456; self.alive=True
    def join(self, timeout=None):
        self.joined+=1
        if self.mode=="cancel" and self.joined==1: raise SystemExit(143)
        self.alive=False
        if self.mode=="failure": self.exitcode=1
    def is_alive(self): return self.alive
    def terminate(self): self.stopped=True; self.alive=False
    def kill(self): self.stopped=True; self.alive=False

class Core(base.FakeCore):
    prepared=0; mode="success"; owns=True; requires_ot=False
    def __init__(self, timeout):
        self.lgd=MODULE.LGDLFS();self.egs=base.FakeEPCAPI();self.instances.append(self);self.platforms=[]
        self.lgd.set_installed_game=lambda app, install:setattr(self,"install",install)
        self.lgd.load_manifest=lambda *args:b"fixture manifest"
    def get_game_and_dlc_list(self, platform, skip_ue):return ([base.game()]if self.owns else []),{}
    def prepare_download(self, game, **kwargs):
        type(self).prepared+=1;self.download_options=kwargs;root=Path(kwargs["base_path"])/kwargs["game_folder"]
        root.mkdir(exist_ok=True);(root/"game.exe").write_bytes(DATA if self.mode!="corrupt"else b"corrupt")
        self.install=SimpleNamespace(app_name=game.app_name,title=game.app_title,version="fixture-v1",install_path=str(root),executable="game.exe",launch_parameters="",can_run_offline=False,requires_ot=self.requires_ot,platform=kwargs["platform"],prereq_info=None)
        self.downloader=Downloader(self.mode)
        return self.downloader,SimpleNamespace(dl_size=100),self.install
    def check_installation_conditions(self,*args,**kwargs):return SimpleNamespace(failures=set())
    def load_manifest(self,data):
        return SimpleNamespace(file_manifest_list=SimpleNamespace(elements=[SimpleNamespace(filename="game.exe",file_size=len(DATA),hash=hashlib.sha1(DATA).digest(),symlink_target="")]),meta=SimpleNamespace(build_version="fixture-v1",launch_exe="game.exe",launch_command=""),decrypt=lambda secrets:True)
    def get_cdn_manifest(self,*args,**kwargs):return b"fixture manifest",[],None,{}
    def get_launch_parameters(self,app,**kwargs):
        args=["-AUTH_PASSWORD=one-use-fixture-exchange"]
        if self.mode=="leak":args.append("-bad="+self.lgd.userdata["refresh_token"])
        if self.requires_ot:
            token=Path(self.lgd.path)/"ownership.ovt";token.write_bytes(b"one-use-fixture-ownership")
            args.append("-epicovt="+str(token))
        return SimpleNamespace(game_executable="game.exe",working_directory=self.install.install_path,game_parameters=[],egl_parameters=args,user_parameters=[])

MODULE=SimpleNamespace(LGDLFS=base.FakeStorage,LegendaryCore=Core)
SESSION={"account_id":"fixture-account","access_token":"fixture-access","refresh_token":"fixture-refresh","displayName":"Fixture"}

class Operations(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix="playmelt-epic-operations-");self.addCleanup(self.tmp.cleanup)
        self.home=Path(self.tmp.name);self.root=self.home/"Library/Application Support/Playmelt/Games"
        self.home_patch=patch.object(worker.Path,"home",return_value=self.home);self.home_patch.start();self.addCleanup(self.home_patch.stop)
        self.global_profile=self.home/".config/legendary/user.json";self.global_profile.parent.mkdir(parents=True);self.global_profile.write_bytes(b"foreign profile must stay unchanged")
        self.global_inode=self.global_profile.stat().st_ino
        Core.mode="success";Core.owns=True;Core.requires_ot=False;Core.prepared=0
    def request(self,action="install",**values):return dict(action=action,session=dict(SESSION),expectedAccountId="fixture-account",appName="factory",platform="Windows",**values)
    def handle(self,request):return worker.handle(request,MODULE,lambda _:"0.21.1",manifest_reader=lambda:[],operation_root=self.root,installed_factory=lambda value:SimpleNamespace(**value))
    def unchanged(self):
        self.assertEqual(self.global_profile.read_bytes(),b"foreign profile must stay unchanged");self.assertEqual(self.global_profile.stat().st_ino,self.global_inode)
        self.assertIs(MODULE.LGDLFS,base.FakeStorage)
        self.assertFalse(Path(Core.instances[-1].lgd.path).exists())
    def test_fresh_auth_install_and_launch_never_use_global_profile(self):
        auth=self.handle({"action":"authenticate","code":"a"*32});self.assertTrue(auth["ok"])
        request=self.request();request["session"]=auth["session"]
        result=self.handle(request);self.assertTrue(result["ok"]);self.assertTrue(result["installation"]["filesVerified"])
        receipt=json.loads((Path(result["installation"]["installPath"])/".playmelt-epic-install.json").read_bytes())
        self.assertNotIn("fixture-access",json.dumps(receipt));self.assertNotIn("fixture-only-secret",json.dumps(receipt));self.assertNotIn("base_urls",receipt["installed"])
        launch=self.handle(self.request("launchAuthorization",installPath=result["installation"]["installPath"]));self.assertTrue(launch["ok"]);self.assertIn("one-use-fixture-exchange",json.dumps(launch["launch"]))
        self.assertNotIn("fixture-access",json.dumps(launch["launch"]));self.unchanged()
    def test_different_account_and_missing_ownership_are_refused_before_download(self):
        request=self.request();request["expectedAccountId"]="another-account";before=len(Core.instances)
        self.assertEqual(self.handle(request)["error"]["code"],"accountChanged");self.assertEqual(len(Core.instances),before);self.assertEqual(Core.prepared,0)
        Core.owns=False;self.assertEqual(self.handle(self.request())["error"]["code"],"notOwned");self.assertEqual(Core.prepared,0);self.assertFalse(self.root.exists());self.unchanged()
    def test_refresh_cannot_replace_current_account(self):
        def changed(_,session):return dict(session,account_id="different-account")
        with patch.object(base.FakeEPCAPI,"resume_session",changed):result=self.handle(self.request())
        self.assertEqual(result["error"]["code"],"accountChanged");self.assertEqual(Core.prepared,0);self.assertNotIn("session",result);self.unchanged()
    def test_existing_tuning_is_preserved_without_allowing_arbitrary_cdn(self):
        result=self.handle(self.request(maxWorkers=32,sharedMemoryMiB=4096));self.assertTrue(result["ok"])
        options=Core.instances[-1].download_options
        self.assertEqual(options["max_workers"],32);self.assertEqual(options["max_shm"],4096);self.assertEqual(options["preferred_cdn"],"egdownload.fastly-edge.com");self.unchanged()
    def test_failed_or_corrupt_download_never_produces_ready_receipt(self):
        for mode in ["failure","corrupt"]:
            Core.mode=mode;result=self.handle(self.request());self.assertFalse(result["ok"])
            self.assertFalse((self.root/"factory-windows/.playmelt-epic-install.json").exists());self.unchanged()
    def test_cancel_reaps_downloader_and_removes_isolated_config(self):
        Core.mode="cancel"
        with self.assertRaises(SystemExit):self.handle(self.request())
        downloader=Core.instances[-1].downloader;self.assertTrue(downloader.stopped);self.assertFalse(downloader.is_alive());self.assertGreaterEqual(downloader.joined,2);self.unchanged()
    def test_ownership_token_is_private_pipe_data_and_temp_path_never_escapes(self):
        Core.requires_ot=True;installed=self.handle(self.request())["installation"]
        result=self.handle(self.request("launchAuthorization",installPath=installed["installPath"]))
        self.assertTrue(result["ok"]);self.assertTrue(result["launch"]["ownershipToken"]);self.assertIn("-epicovt=__PLAYMELT_PRIVATE_OWNERSHIP_TOKEN__",result["launch"]["arguments"]);self.unchanged()
    def test_access_or_refresh_token_in_game_arguments_is_rejected(self):
        installed=self.handle(self.request())["installation"];Core.mode="leak"
        result=self.handle(self.request("launchAuthorization",installPath=installed["installPath"]))
        self.assertFalse(result["ok"]);self.assertNotIn("fixture-refresh",json.dumps(result));self.unchanged()
    def test_legacy_managed_installation_can_be_adopted_without_global_metadata(self):
        folder=self.root/"OlderGameFolder";folder.mkdir(parents=True);(folder/"game.exe").write_bytes(DATA)
        (folder/"mac-user-patch.dll").write_bytes(b"preserve user patch")
        # Deliberately different from the full manifest hash: no full-game
        # verification or overwrite is permitted during explicit legacy launch.
        (folder/"game.exe").write_bytes(b"MZ existing patched executable")
        result=self.handle(self.request("launchAuthorization",installPath=str(folder)))
        self.assertTrue(result["ok"]);self.assertEqual(json.loads((folder/".playmelt-epic-install.json").read_bytes())["verification"],"declared-executable");self.assertEqual((folder/"mac-user-patch.dll").read_bytes(),b"preserve user patch");self.assertEqual(Core.prepared,0);self.unchanged()
    def test_process_output_redacts_library_and_child_diagnostics(self):
        code='''import importlib.util,sys,os,subprocess,json
s=importlib.util.spec_from_file_location("w",sys.argv[1]);w=importlib.util.module_from_spec(s);s.loader.exec_module(w)
with w.quiet_process_output():
 os.write(1,b"fixture-library-secret");os.write(2,b"fixture-library-secret")
 subprocess.run([sys.executable,"-c","print('fixture-child-secret')"],check=True)
print(json.dumps({"ok":True}))
'''
        result=subprocess.run([sys.executable,"-I","-c",code,str(base.WORKER)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=10)
        self.assertEqual(result.returncode,0);self.assertEqual(json.loads(result.stdout),{"ok":True});self.assertEqual(result.stderr,b"")

if __name__=="__main__":unittest.main()
