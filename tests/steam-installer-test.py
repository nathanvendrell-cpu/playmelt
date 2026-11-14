"""Offline installer fixtures. No Steam, Wine, credentials or network is used."""
import contextlib
import importlib.util
import io
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch, Mock

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/steam-installer.py"
sys.path.insert(0, str(SCRIPT.parent))
from steam_install_plan import build_plan, PlanError, windows_arguments
spec = importlib.util.spec_from_file_location("steam_installer", SCRIPT)
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)
ACCOUNT = "76561198000000001"


class InstallerTests(unittest.TestCase):
    def test_receipt_is_bound_to_manifest_and_directory(self):
        receipt = 'Depot download complete : "/tmp/steam\\steamapps\\content\\app_10\\depot_11" (manifest 123)'
        self.assertTrue(installer.official_completion(receipt, "/tmp/steam/steamapps/content/app_10/depot_11", "123"))
        self.assertFalse(installer.official_completion(receipt, "/tmp/steam/steamapps/content/app_20/depot_11", "123"))
        self.assertFalse(installer.official_completion(receipt, "/tmp/steam/steamapps/content/app_10/depot_11", "999"))
        self.assertFalse(installer.official_completion("6 MiB stable for 5 seconds", "/tmp/game", "123"))

    def test_generic_refusal_requires_exact_fresh_console_attempt(self):
        steam = "/tmp/Steam/steam_osx"
        def command(app="10", depot="11", manifest="123"):
            return f"ExecCommandLine: \"'{steam}' '+download_depot' '{app}' '{depot}' '{manifest}'\"\n"
        refusal = "Depot download failed : missing license for depot (No subscription)\n"
        check = lambda log: installer.depot_attempt_problem(log, steam, "10", "11", "123")
        self.assertEqual(check(command() + refusal), "denied")
        self.assertIsNone(check(refusal))
        self.assertIsNone(check(command(app="20") + refusal))
        self.assertIsNone(check(command(manifest="999") + refusal))
        self.assertEqual(check(command() + command(app="20") + refusal), "context-changed")
        self.assertIsNone(check(command() + "Downloading depot 11 ...\n"))

    def test_multiple_windows_depots_are_all_planned(self):
        def depot(size):
            return {"config": {"oslist": "windows"}, "manifests": {"public": {"size": str(size), "gid": "123"}}}
        app = {"common": {"name": "Fixture"}, "config":{"launch":{"0":{"executable":"Game.exe"}}},"depots": {"11": depot(10), "12": depot(20)}}
        plan=build_plan("10",{"10":app})
        self.assertEqual([x["depotID"] for x in plan["depots"]],["11","12"])
        self.assertEqual(plan["bytes"],30)

    def test_language_os_arch_dlc_and_private_branches(self):
        def depot(**config):
            return {"config":config,"manifests":{"public":{"gid":"123","size":"10"}}}
        rows={"11":depot(),"12":depot(language="french"),"13":depot(language="english"),"14":depot(oslist="linux"),"15":depot(osarch="32"),"16":depot(osarch="64"),"17":dict(depot(),dlcappid="99"),"18":{}}
        app={"config":{"launch":{"0":{"executable":"Private.exe","config":{"BetaKey":"secret"}},"1":{"executable":"Game.exe","arguments":'-name "deux mots"'}}},"depots":rows}
        p=build_plan("10",{"10":app})
        self.assertEqual([x["depotID"] for x in p["depots"]],["11","12","16"])
        self.assertEqual(p["executable"],"Game.exe")
        self.assertEqual(p["arguments"],["-name","deux mots"])

    def test_shared_depot_is_bound_to_its_source_app(self):
        a={"config":{"launch":{"0":{"executable":"Game.exe"}}},"depots":{"11":{"depotfromapp":"20"}}}
        b={"depots":{"11":{"manifests":{"public":{"gid":"321","size":"10"}}}}}
        p=build_plan("10",{"10":a,"20":b})
        self.assertEqual(p["depots"][0]["appID"],"10")
        self.assertEqual(p["depots"][0]["sourceAppID"],"20")
        with self.assertRaises(PlanError):build_plan("10",{"10":a})

    def test_publisher_paths_never_escape_the_game(self):
        for executable in ("../outside.exe","C:\\outside.exe","/outside.exe"):
            with self.assertRaises(PlanError):build_plan("10",{"10":{"config":{"launch":{"0":{"executable":executable}}}}})
        with self.assertRaises(PlanError):windows_arguments('"unfinished')

    def test_default_branch_and_anchored_publisher_workdir(self):
        a={"config":{"launch":{"0":{"executable":"bin\\Game.exe","workingdir":"\\bin","config":{"BetaKey":"default"}}}},"depots":{"11":{"manifests":{"public":{"gid":"123","size":"10"}}}}}
        p=build_plan("10",{"10":a})
        self.assertEqual(p["executable"],"bin/Game.exe")
        self.assertEqual(p["workingDirectory"],"bin")
        for path in ("\\elsewhere","\\\\host\\bin","C:\\bin","../bin"):
            a["config"]["launch"]["0"]["workingdir"]=path
            with self.assertRaises(PlanError):build_plan("10",{"10":a})

    def run_fixture(self, root, receipt=False, existing=False, prerequisite=False, refusal=False):
        steam = root / "Library/Application Support/Steam"
        executable = steam / "Steam.AppBundle/Steam/Contents/MacOS/steam_osx"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"not executed")
        login = steam / "config/loginusers.vdf"
        login.parent.mkdir()
        login.write_text(f'"users" {{ "{ACCOUNT}" {{ "MostRecent" "1" }} }}')
        content = executable.parent / "steamapps/content/app_10/depot_11"
        content.mkdir(parents=True)
        (content / "Game.exe").write_bytes(b"MZ")
        (content / "steam_api64.dll").write_bytes(b"preserve vendor bytes")
        with (content / "assets.bin").open("wb") as handle:
            handle.truncate(6 * 1024 * 1024)
        size = installer.get_dir_size(content)
        log = steam / "logs/console_log.txt"
        log.parent.mkdir()
        log.write_text("")
        destination = root / "Library/Application Support/Playmelt/Games/Fixture-10/Windows"
        if existing:
            destination.mkdir(parents=True)
            (destination / "save.dat").write_bytes(b"existing user data")
        info=build_plan("10",{"10":{"common":{"name":"Fixture"},"config":{"launch":{"0":{"executable":"Game.exe"}}},"depots":{"11":{"manifests":{"public":{"gid":"123","size":str(size if receipt else 100*size),"download":str(size)}}}}}})
        redist=executable.parent/"steamapps/content/app_228980/depot_99"
        if prerequisite:
            redist.mkdir(parents=True)
            (redist/"installscript.vdf").write_text('"InstallScript" { "Run Process" { "vc2022x64" { "HasRunKey" "HKEY_LOCAL_MACHINE\\\\SOFTWARE\\\\Wow6432Node\\\\Valve\\\\Steam\\\\Apps\\\\CommonRedist\\\\vcredist\\\\2022" "Process 1" "never-run.exe" } } }')
            info["prerequisites"]=[{"appID":"228980","sourceAppID":"228980","depotID":"99","manifestID":"456","bytes":installer.get_dir_size(redist)}]
        events = []
        def trigger(*args):
            if refusal:
                with log.open("a") as handle:
                    handle.write(f"ExecCommandLine: \"'{executable}' '+download_depot' '{args[1]}' '{args[2]}' '{args[3]}'\"\n")
                    handle.write("Depot download failed : missing license for depot (No subscription)\n")
            if receipt:
                folder,gid=(redist,"456") if args[1]=="228980" else (content,"123")
                with log.open("a") as handle:
                    handle.write('ExecCommandLine: '+installer.shlex.join([args[0],'+download_depot',*args[1:]])+'\n')
                    handle.write(f'Depot download complete : "{folder}" (manifest {gid})\n')
            return True
        ticks = iter([0] + list(range(1, 11)) + [50000])
        with patch.dict(os.environ, {"HOME": str(root)}), \
             patch.object(installer.sys, "argv", [str(SCRIPT), "--appid", "10", "--accountid", ACCOUNT, "--renderer", "dxmt"]), \
             patch.object(installer, "resolve_steam_info", return_value=info), \
             patch.object(installer, "trigger_steam_depot_download", side_effect=trigger), \
             patch.object(installer.time, "sleep"), \
             patch.object(installer.time, "monotonic", side_effect=lambda: next(ticks, 50000)), \
             patch.object(installer, "emit", side_effect=lambda *args, **kwargs: events.append((args, kwargs))):
            code = installer.main()
        return code, events, destination, steam

    def test_actual_generic_no_subscription_terminates_without_publication(self):
        with tempfile.TemporaryDirectory(prefix="playmelt-refusal-test-") as temporary:
            code, events, destination, _ = self.run_fixture(Path(temporary).resolve(), refusal=True)
            self.assertEqual(code, 1)
            self.assertFalse(destination.exists())
            self.assertEqual(events[-1][0][0], "failed")
            self.assertIn("refusé", events[-1][0][3])
            self.assertNotIn("files-prepared", [event[0][0] for event in events])

    def test_stalled_partial_depot_never_deploys(self):
        with tempfile.TemporaryDirectory(prefix="playmelt-installer-test-") as temporary:
            code, events, destination, _ = self.run_fixture(Path(temporary).resolve())
            self.assertEqual(code, 1)
            self.assertFalse(destination.exists())
            self.assertNotIn("launch-ready", [event[0][0] for event in events])

    def test_official_completion_keeps_vendor_dll_and_steam_manifest(self):
        with tempfile.TemporaryDirectory(prefix="playmelt-installer-test-") as temporary:
            root = Path(temporary).resolve()
            code, events, destination, steam = self.run_fixture(root, receipt=True)
            self.assertIsNone(code)
            self.assertEqual(events[-1][0][0], "files-prepared")
            self.assertFalse(events[-1][1]["ready"])
            self.assertEqual(list(destination.parent.glob("*.command")),[])
            self.assertEqual((destination / "steam_api64.dll").read_bytes(), b"preserve vendor bytes")
            self.assertFalse((steam / "steamapps/appmanifest_10.acf").exists())
            receipt = json.loads((destination.parent / "playmelt-install.json").read_text())
            self.assertEqual(receipt["receipts"][0]["manifestID"], "123")
            self.assertFalse(receipt["gameExecutionVerified"])
            launch=json.loads((destination.parent / ".playmelt-steam-launch.json").read_text())
            self.assertEqual(launch["executable"],"Game.exe")
            self.assertFalse(receipt["prerequisiteExecutionVerified"])
            self.assertTrue(launch["steamClientRequired"])

    def test_common_redist_acquisition_and_execution_are_left_to_official_windows_steam(self):
        with tempfile.TemporaryDirectory(prefix="playmelt-installer-test-") as temporary:
            root=Path(temporary).resolve()
            code,events,destination,_=self.run_fixture(root,receipt=True,prerequisite=True)
            self.assertIsNone(code)
            receipt=json.loads((destination.parent/"playmelt-install.json").read_text())
            self.assertEqual([r["appID"] for r in receipt["receipts"]],["10"])
            self.assertEqual(receipt["prerequisiteChecks"],[])
            self.assertTrue(receipt["requiresOfficialSteam"])
            task=next(t for t in receipt["preparationTasks"] if t.get("depotID")=="99")
            self.assertEqual(task["requiredClient"],"steam-windows")
            self.assertFalse(task["acquisitionVerified"])
            self.assertFalse(task["executionVerified"])
            self.assertFalse(receipt["prerequisiteExecutionVerified"])
            self.assertFalse((destination/"installscript.vdf").exists())
            self.assertEqual(events[-1][0][0],"files-prepared")

    def test_existing_installation_is_never_replaced(self):
        with tempfile.TemporaryDirectory(prefix="playmelt-installer-test-") as temporary:
            code, events, destination, _ = self.run_fixture(Path(temporary).resolve(), receipt=True, existing=True)
            self.assertEqual(code, 1)
            self.assertEqual((destination / "save.dat").read_bytes(), b"existing user data")
            self.assertNotIn("launch-ready", [event[0][0] for event in events])

    def test_multi_depot_copy_and_interrupted_resume(self):
        for interrupt in (False,True):
            with self.subTest(interrupt=interrupt),tempfile.TemporaryDirectory(prefix="playmelt-installer-test-") as temporary:
                root=Path(temporary).resolve();steam=root/"Steam";steam.mkdir()
                log=root/"Library/Application Support/Steam/logs/console_log.txt";log.parent.mkdir(parents=True);log.write_text("")
                depot1=steam/"steamapps/content/app_10/depot_11";depot2=depot1.parent/"depot_12"
                depot1.mkdir(parents=True);depot2.mkdir()
                (depot1/"Game.exe").write_bytes(b"MZgame")
                (depot1/"shared.bin").write_bytes(b"old")
                (depot2/"shared.bin").write_bytes(b"new content")
                app={"common":{"name":"Fixture"},"config":{"launch":{"0":{"executable":"Game.exe","arguments":"-publisher \"safe words\""}}},"depots":{
                    "11":{"manifests":{"public":{"gid":"123","size":"9"}}},"12":{"manifests":{"public":{"gid":"456","size":"11"}}}}}
                plan=build_plan("10",{"10":app});args=SimpleNamespace(appid="10",accountid=ACCOUNT,renderer="dxmt")
                interrupted=[interrupt];events=[]
                def trigger(binary,appid,depot,gid):
                    if depot == "12" and interrupted[0]:return False
                    folder=depot1 if depot == "11" else depot2
                    with log.open("a") as f:
                        f.write('ExecCommandLine: '+installer.shlex.join([binary,'+download_depot',appid,depot,gid])+'\n')
                        f.write(f'Depot download complete : "{folder}" (manifest {gid})\n')
                    return True
                with patch.object(installer,"trigger_steam_depot_download",side_effect=trigger),patch.object(installer,"active_steam_account",return_value=ACCOUNT),patch.object(installer.time,"sleep"),patch.object(installer,"emit",side_effect=lambda *a,**k:events.append(a)):
                    if interrupt:
                        with self.assertRaises(PlanError):installer.install_depots(args,plan,str(steam/"steam_osx"),str(root),"unused")
                        self.assertFalse((root/"Library/Application Support/Playmelt/Games/Fixture-10/Windows").exists())
                        self.assertNotIn("launch-ready",[e[0] for e in events])
                        interrupted[0]=False
                    installer.install_depots(args,plan,str(steam/"steam_osx"),str(root),"unused")
                final=root/"Library/Application Support/Playmelt/Games/Fixture-10/Windows"
                self.assertEqual((final/"shared.bin").read_bytes(),b"new content")
                self.assertEqual((depot1/"Game.exe").read_bytes(),b"MZgame","Valve cache preserved")
                receipt=json.loads((final.parent/"playmelt-install.json").read_text())
                self.assertEqual(len(receipt["receipts"]),2)
                self.assertEqual(receipt["arguments"],["-publisher","safe words"])
                self.assertEqual(events[-1][0],"files-prepared")

    def test_launcher_quotes_untrusted_names(self):
        with tempfile.TemporaryDirectory(prefix="playmelt-installer-test-") as temporary:
            game = Path(temporary).resolve() / "name ' $(touch injected)"
            game.mkdir()
            script = Path(installer.create_launch_script(str(game), "a ' $(touch injected).exe", "Fixture", "10"))
            text = script.read_text()
            self.assertIn(installer.shlex.quote(str(game)), text)
            self.assertIn(installer.shlex.quote("a ' $(touch injected).exe"), text)
            self.assertNotIn(">/dev/null", text)
            self.assertIn("tail -c 1048576", text)

    def test_client_handoff_never_waits_or_terminates_the_independent_client(self):
        client = Mock()
        client.poll.return_value = None
        try:
            with patch.object(installer.subprocess, "Popen", return_value=client) as launch:
                self.assertIs(installer.trigger_steam_depot_download("/fixture/steam_osx", "10", "11", "123"), client)
            self.assertTrue(launch.call_args.kwargs["start_new_session"])
            self.assertNotIn("timeout", launch.call_args.kwargs)
            installer.reap_steam_handoffs()
            client.wait.assert_not_called()
            client.kill.assert_not_called()
            client.terminate.assert_not_called()
            client.poll.return_value = 0
            installer.reap_steam_handoffs()
            self.assertNotIn(client, installer._steam_handoffs)
        finally:
            installer._steam_handoffs[:] = [p for p in installer._steam_handoffs if p is not client]


if __name__ == "__main__":
    unittest.main()
