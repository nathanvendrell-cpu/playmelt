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
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/steam-installer.py"
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

    def test_multiple_windows_depots_are_not_guessed(self):
        def depot(size):
            return {"config": {"oslist": "windows"}, "manifests": {"public": {"size": str(size), "gid": "123"}}}
        app = {"common": {"name": "Fixture"}, "depots": {"11": depot(10), "12": depot(20)}}
        payload = json.dumps({"data": {"10": app}}).encode()
        with patch.object(installer.urllib.request, "urlopen", return_value=contextlib.closing(io.BytesIO(payload))):
            self.assertIsNone(installer.resolve_steam_info("10"))
        app["depots"].pop("12")
        payload = json.dumps({"data": {"10": app}}).encode()
        with patch.object(installer.urllib.request, "urlopen", return_value=contextlib.closing(io.BytesIO(payload))):
            self.assertEqual(installer.resolve_steam_info("10")["manifest_id"], "123")

    def run_fixture(self, root, receipt=False, existing=False):
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
        info = {"name": "Fixture", "installdir": "Fixture", "depot_id": "11", "manifest_id": "123",
                "build_id": "456", "size": size if receipt else 100 * size, "download_size": size, "executable": "Game.exe"}
        events = []
        def trigger(*args):
            if receipt:
                log.write_text(f'Depot download complete : "{content}" (manifest 123)\n')
            return True
        ticks = iter([0] + list(range(1, 11)) + [50000])
        with patch.dict(os.environ, {"HOME": str(root)}), \
             patch.object(installer.sys, "argv", [str(SCRIPT), "--appid", "10", "--accountid", ACCOUNT, "--renderer", "dxmt"]), \
             patch.object(installer, "resolve_steam_info", return_value=info), \
             patch.object(installer, "trigger_steam_depot_download", side_effect=trigger), \
             patch.object(installer.time, "sleep"), \
             patch.object(installer.time, "time", side_effect=lambda: next(ticks, 50000)), \
             patch.object(installer, "emit", side_effect=lambda *args, **kwargs: events.append((args, kwargs))):
            code = installer.main()
        return code, events, destination, steam

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
            self.assertEqual(events[-1][0][0], "launch-ready")
            self.assertEqual((destination / "steam_api64.dll").read_bytes(), b"preserve vendor bytes")
            self.assertFalse((steam / "steamapps/appmanifest_10.acf").exists())
            receipt = json.loads((destination.parent / "playmelt-install.json").read_text())
            self.assertEqual(receipt["manifestID"], "123")
            self.assertFalse(receipt["gameExecutionVerified"])

    def test_existing_installation_is_never_replaced(self):
        with tempfile.TemporaryDirectory(prefix="playmelt-installer-test-") as temporary:
            code, events, destination, _ = self.run_fixture(Path(temporary).resolve(), receipt=True, existing=True)
            self.assertEqual(code, 1)
            self.assertEqual((destination / "save.dat").read_bytes(), b"existing user data")
            self.assertNotIn("launch-ready", [event[0][0] for event in events])

    def test_launcher_quotes_untrusted_names(self):
        with tempfile.TemporaryDirectory(prefix="playmelt-installer-test-") as temporary:
            game = Path(temporary) / "name ' $(touch injected)"
            game.mkdir()
            script = Path(installer.create_launch_script(str(game), "a ' $(touch injected).exe", "Fixture", "10"))
            text = script.read_text()
            self.assertIn(installer.shlex.quote(str(game)), text)
            self.assertIn(installer.shlex.quote("a ' $(touch injected).exe"), text)
            self.assertNotIn(">/dev/null", text)
            self.assertIn("tail -c 1048576", text)

    def test_cancellation_reaps_owned_request_helper(self):
        with tempfile.TemporaryDirectory(prefix="playmelt-installer-test-") as temporary:
            root = Path(temporary).resolve()
            child_pid = root / "helper.pid"
            helper = root / "fake-steam-request"
            helper.write_text(f"#!/bin/sh\nprintf '%s' \"$$\" > {installer.shlex.quote(str(child_pid))}\nexec /bin/sleep 20\n")
            helper.chmod(0o700)
            code = (
                "import importlib.util,signal; "
                f"s=importlib.util.spec_from_file_location('fixture',{str(SCRIPT)!r}); "
                "m=importlib.util.module_from_spec(s); s.loader.exec_module(m); "
                "signal.signal(signal.SIGTERM,lambda *a: (_ for _ in ()).throw(KeyboardInterrupt())); "
                f"m.trigger_steam_depot_download({str(helper)!r},'10','11','123')"
            )
            worker = subprocess.Popen([sys.executable, "-B", "-c", code], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 3
                while not child_pid.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(child_pid.exists(), "fixture helper started")
                owned_pid = int(child_pid.read_text())
                worker.terminate()
                worker.wait(timeout=3)
                with self.assertRaises(ProcessLookupError):
                    os.kill(owned_pid, 0)
            finally:
                if worker.poll() is None:
                    worker.kill()
                    worker.wait(timeout=3)
                if child_pid.exists():
                    try:
                        os.kill(int(child_pid.read_text()), signal.SIGKILL)
                    except ProcessLookupError:
                        pass


if __name__ == "__main__":
    unittest.main()
