"""Offline recovery checks. No Steam client or publisher process is executed."""
import errno
import hashlib
import io
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch, Mock

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from steam_install_plan import build_plan
spec = importlib.util.spec_from_file_location("steam_resume_installer", ROOT / "scripts/steam-installer.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)
ACCOUNT = "76561198000000000"


class ResumeTests(unittest.TestCase):
    def fixture(self, root, redist=False):
        steam = root / "FakeSteam"
        content = steam / "steamapps/content/app_10/depot_11"
        content.mkdir(parents=True)
        (content / "Game.exe").write_bytes(b"MZgame")
        metadata = {"10": {"common": {"name": "Recovery"}, "config": {"launch": {"0": {"executable": "Game.exe"}}},
            "depots": {"11": {"manifests": {"public": {"gid": "123", "size": "6"}}}}}}
        if redist:
            metadata["10"]["depots"]["99"] = {"depotfromapp": "228980"}
            metadata["228980"] = {"depots": {"99": {"config": {"oslist": "windows"},
                "manifests": {"public": {"gid": "456", "size": "2"}}}}}
            (steam / "steamapps/content/app_228980/depot_99").mkdir(parents=True)
        plan = build_plan("10", metadata)
        log = root / "Library/Application Support/Steam/logs/console_log.txt"
        log.parent.mkdir(parents=True)
        log.write_text("")
        destination = root / "Library/Application Support/Playmelt/Games/Recovery-10"
        args = SimpleNamespace(appid="10", accountid=ACCOUNT, renderer="dxmt")
        return SimpleNamespace(root=root, steam=steam, content=content, log=log, plan=plan, args=args,
            final=destination / "Windows", stage=destination / (".steam-staging-" + plan["planSHA256"][:16]))

    def complete(self, f):
        def trigger(binary, app, depot, manifest):
            self.assertNotEqual(app, "228980", "Mac Steam must not acquire Windows CommonRedist")
            with f.log.open("a") as handle:
                handle.write("ExecCommandLine: " + installer.shlex.join([binary, "+download_depot", app, depot, manifest]) + "\n")
                handle.write(f'Depot download complete : "{f.content}" (manifest {manifest})\n')
            return True
        return trigger

    def run_install(self, f, trigger=None):
        events = []
        ticks = iter([0, 50000])
        with patch.object(installer, "active_steam_account", side_effect=lambda _: f.args.accountid), \
             patch.object(installer, "trigger_steam_depot_download", side_effect=trigger or self.complete(f)), \
             patch.object(installer.time, "sleep"), \
             patch.object(installer.time, "monotonic", side_effect=lambda: next(ticks, 50000)), \
             patch.object(installer, "emit", side_effect=lambda *a, **k: events.append((a, k))):
            installer.install_depots(f.args, f.plan, str(f.steam / "steam_osx"), str(f.root), "unused")
        return events

    def interrupt_copy(self, f):
        with patch.object(installer.shutil, "copytree", side_effect=OSError(errno.EINTR, "fixture interruption")):
            with self.assertRaises(installer.InstallFailure) as result:
                self.run_install(f)
        self.assertEqual(result.exception.details["code"], "steam_depot_copy_failed")
        self.assertTrue(result.exception.details["retryable"])
        self.assertEqual(result.exception.details["resumePoint"], "steam-depot-copy")
        self.assertFalse(f.final.exists())
        checkpoint = next((f.stage / "validated-depots").glob("*.json"))
        return checkpoint

    def test_shared_master_os_language_architecture_and_dlc_are_inherited(self):
        for name, properties in [("OS", {"config": {"oslist": "linux"}}),
            ("language", {"config": {"language": "german"}}),
            ("architecture", {"config": {"osarch": "32"}}), ("DLC", {"dlcappid": "1234"})]:
            with self.subTest(property=name):
                metadata = {"10": {"config": {"launch": {"0": {"executable": "Game.exe"}}},
                    "depots": {"11": {"config": {"language": "french", "osarch": "64"},
                        "manifests": {"public": {"gid": "123", "size": "6"}}}, "99": {"depotfromapp": "20"}}},
                    "20": {"depots": {"99": {**properties, "manifests": {"public": {"gid": "456", "size": "2"}}}}}}
                self.assertEqual([d["depotID"] for d in build_plan("10", metadata)["depots"]], ["11"])

    def test_windows_redist_keeps_both_architectures_without_changing_game_language(self):
        metadata = {"10": {"config": {"launch": {"0": {"executable": "Game.exe"}}}, "depots": {
            "11": {"config": {"language": "english", "osarch": "64"}, "manifests": {"public": {"gid": "123", "size": "6"}}},
            "98": {"depotfromapp": "228980"}, "99": {"depotfromapp": "228980"}}}, "228980": {"depots": {
                "98": {"config": {"oslist": "windows", "osarch": "32"}, "manifests": {"public": {"gid": "456", "size": "2"}}},
                "99": {"config": {"oslist": "windows", "osarch": "64"}, "manifests": {"public": {"gid": "789", "size": "2"}}}}}}
        plan = build_plan("10", metadata)
        self.assertEqual(plan["language"], "english")
        self.assertEqual([d["depotID"] for d in plan["depots"]], ["11"])
        self.assertEqual([d["depotID"] for d in plan["prerequisites"]], ["98", "99"])

    def test_empty_windows_redist_does_not_block_game_files_or_become_verified(self):
        with tempfile.TemporaryDirectory(prefix="playmelt-resume-test-") as temporary:
            f = self.fixture(Path(temporary).resolve(), redist=True)
            events = self.run_install(f)
            receipt = json.loads((f.final.parent / "playmelt-install.json").read_text())
            self.assertEqual([r["depotID"] for r in receipt["receipts"]], ["11"])
            self.assertEqual(receipt["prerequisites"], f.plan["prerequisites"])
            self.assertTrue(receipt["requiresOfficialSteam"])
            self.assertFalse(receipt["prerequisiteExecutionVerified"])
            task = next(t for t in receipt["preparationTasks"] if t.get("depotID") == "99")
            self.assertEqual(task["requiredClient"], "steam-windows")
            self.assertFalse(task["acquisitionVerified"])
            self.assertFalse(task["executionVerified"])
            self.assertEqual(events[-1][0][0], "files-prepared")
            self.assertFalse(events[-1][1]["ready"])
            self.assertTrue(events[-1][1]["requiresOfficialSteam"])
            self.assertNotIn("launch-ready", [a[0] for a, _ in events])
            self.assertEqual(list(f.final.parent.glob("*.command")), [])

    def test_interrupted_copy_reuses_rehashed_checkpoint_without_steam_request(self):
        with tempfile.TemporaryDirectory(prefix="playmelt-resume-test-") as temporary:
            f = self.fixture(Path(temporary).resolve())
            checkpoint = self.interrupt_copy(f)
            record = json.loads(checkpoint.read_text())
            self.assertEqual(record["accountID"], ACCOUNT)
            self.assertEqual(record["planSHA256"], f.plan["planSHA256"])
            self.assertEqual(record["depot"]["manifestID"], "123")
            self.assertEqual(record["fileSHA256"]["Game.exe"], hashlib.sha256(b"MZgame").hexdigest())
            events = self.run_install(f, lambda *args: self.fail("A validated checkpoint must not request Steam again"))
            self.assertEqual((f.final / "Game.exe").read_bytes(), b"MZgame")
            self.assertIn("steam_checkpoint_verified", [k.get("code") for _, k in events])

    def test_same_size_modified_cache_requires_new_official_completion(self):
        with tempfile.TemporaryDirectory(prefix="playmelt-resume-test-") as temporary:
            f = self.fixture(Path(temporary).resolve())
            self.interrupt_copy(f)
            (f.content / "Game.exe").write_bytes(b"MZevil")
            calls = []
            def fresh(*args):
                calls.append(args)
                return self.complete(f)(*args)
            self.run_install(f, fresh)
            self.assertEqual(len(calls), 1)
            self.assertEqual((f.final / "Game.exe").read_bytes(), b"MZevil")

    def test_checkpoint_for_another_account_or_manifest_is_not_reused(self):
        for changed in ("account", "manifest", "malformed"):
            with self.subTest(changed=changed), tempfile.TemporaryDirectory(prefix="playmelt-resume-test-") as temporary:
                f = self.fixture(Path(temporary).resolve())
                checkpoint = self.interrupt_copy(f)
                record = json.loads(checkpoint.read_text())
                if changed == "account":
                    record["accountID"] = "76561198000000001"
                elif changed == "manifest":
                    record["depot"]["manifestID"] = "999"
                checkpoint.write_text("{" if changed == "malformed" else json.dumps(record))
                calls = []
                def fresh(*args):
                    calls.append(args)
                    return self.complete(f)(*args)
                self.run_install(f, fresh)
                self.assertEqual(len(calls), 1)

    def test_old_log_and_matching_size_without_checkpoint_cannot_certify_cache(self):
        with tempfile.TemporaryDirectory(prefix="playmelt-resume-test-") as temporary:
            f = self.fixture(Path(temporary).resolve())
            self.complete(f)("unused", "10", "11", "123")
            with self.assertRaises(installer.InstallFailure) as result:
                self.run_install(f, lambda *args: True)
            self.assertEqual(result.exception.details["code"], "steam_download_timeout")
            self.assertFalse(f.final.exists())

    def test_longer_rotated_log_retries_with_a_fresh_cursor_and_receipt(self):
        with tempfile.TemporaryDirectory(prefix="playmelt-resume-test-") as temporary:
            f = self.fixture(Path(temporary).resolve())
            f.log.write_text("old unrelated log\n" * 128)
            calls = []
            def trigger(*args):
                calls.append(args)
                if len(calls) == 1:
                    replacement = f.log.with_suffix(".replacement")
                    replacement.write_text(f'Depot download complete : "{f.content}" (manifest 123)\n' + "padding\n" * 1024)
                    replacement.replace(f.log)
                    return True
                return self.complete(f)(*args)
            events = self.run_install(f, trigger)
            self.assertEqual(len(calls), 2)
            self.assertTrue(f.final.exists())
            recovery = next(k for _, k in events if k.get("code") == "steam_log_renewed")
            self.assertTrue(recovery["retryable"])
            self.assertEqual(recovery["resumePoint"], "steam-log-restart")

    def test_repeated_log_rotation_stops_after_three_requests(self):
        with tempfile.TemporaryDirectory(prefix="playmelt-resume-test-") as temporary:
            f = self.fixture(Path(temporary).resolve())
            calls = []
            def rotate(*args):
                calls.append(args)
                replacement = f.log.with_suffix(".replacement")
                replacement.write_text("padding\n" * (1024 + len(calls)))
                replacement.replace(f.log)
                return True
            with self.assertRaises(installer.InstallFailure) as result:
                self.run_install(f, rotate)
            self.assertEqual(len(calls), 3)
            self.assertEqual(result.exception.details["code"], "steam_log_renewed")
            self.assertFalse(result.exception.details["retryable"])
            self.assertFalse(f.final.exists())

    def test_same_inode_truncation_regrown_past_cursor_restarts_safely(self):
        with tempfile.TemporaryDirectory(prefix="playmelt-resume-test-") as temporary:
            f = self.fixture(Path(temporary).resolve())
            f.log.write_text("old unrelated log\n" * 128)
            original_inode = f.log.stat().st_ino
            calls = []
            def rewrite(*args):
                calls.append(args)
                if len(calls) == 1:
                    f.log.write_text("replacement log\n" * 1024)
                    self.assertEqual(f.log.stat().st_ino, original_inode)
                    return True
                return self.complete(f)(*args)
            self.run_install(f, rewrite)
            self.assertEqual(len(calls), 2)
            self.assertTrue(f.final.exists())

    def test_independent_handoff_observes_completion_without_waiting_or_killing_client(self):
        with tempfile.TemporaryDirectory(prefix="playmelt-resume-test-") as temporary:
            f = self.fixture(Path(temporary).resolve())
            original = installer.trigger_steam_depot_download
            client = Mock()
            client.poll.return_value = None
            def handoff(command, **kwargs):
                self.assertTrue(kwargs["start_new_session"])
                self.complete(f)(command[0], *command[2:])
                return client
            try:
                with patch.object(installer.subprocess, "Popen", side_effect=handoff):
                    self.run_install(f, original)
                client.wait.assert_not_called()
                client.kill.assert_not_called()
                client.terminate.assert_not_called()
            finally:
                installer._steam_handoffs[:] = [p for p in installer._steam_handoffs if p is not client]
            self.assertTrue(f.final.exists())

    def test_incremental_log_keeps_completion_and_attribution_across_large_bursts(self):
        for receipt_first in (True, False):
            with self.subTest(receipt_first=receipt_first), tempfile.TemporaryDirectory(prefix="playmelt-resume-test-") as temporary:
                f = self.fixture(Path(temporary).resolve())
                def trigger(binary, app, depot, manifest):
                    anchor = "ExecCommandLine: " + installer.shlex.join([binary, "+download_depot", app, depot, manifest]) + "\n"
                    completion = f'Depot download complete : "{f.content}" (manifest {manifest})\n'
                    padding = "unrelated diagnostic\n" * 150000
                    f.log.write_text(anchor + (completion + padding if receipt_first else padding + completion))
                    return True
                self.run_install(f, trigger)
                self.assertTrue(f.final.exists())

    def test_completion_without_matching_command_anchor_cannot_publish(self):
        with tempfile.TemporaryDirectory(prefix="playmelt-resume-test-") as temporary:
            f = self.fixture(Path(temporary).resolve())
            def unbound(*args):
                f.log.write_text(f'Depot download complete : "{f.content}" (manifest 123)\n')
                return True
            with self.assertRaises(installer.InstallFailure) as result:
                self.run_install(f, unbound)
            self.assertEqual(result.exception.details["code"], "steam_download_timeout")
            self.assertFalse(f.final.exists())

    def test_same_size_copy_corruption_cannot_publish(self):
        with tempfile.TemporaryDirectory(prefix="playmelt-resume-test-") as temporary:
            f = self.fixture(Path(temporary).resolve())
            original = installer.shutil.copytree
            def corrupt(*args, **kwargs):
                result = original(*args, **kwargs)
                (Path(args[1]) / "Game.exe").write_bytes(b"MZevil")
                return result
            with patch.object(installer.shutil, "copytree", side_effect=corrupt):
                with self.assertRaises(installer.InstallFailure) as result:
                    self.run_install(f)
            self.assertEqual(result.exception.details["code"], "steam_depot_copy_mismatch")
            self.assertFalse(f.final.exists())

    def test_verified_staged_copy_does_not_require_the_full_game_space_again(self):
        with tempfile.TemporaryDirectory(prefix="playmelt-resume-test-") as temporary:
            f = self.fixture(Path(temporary).resolve())
            self.interrupt_copy(f)
            (f.stage / "Windows/Game.exe").write_bytes(b"MZgame")
            with patch.object(installer.shutil, "disk_usage", return_value=SimpleNamespace(free=0)), \
                 patch.object(installer.shutil, "copytree", side_effect=AssertionError("Verified staging must not be recopied")):
                self.run_install(f, lambda *args: self.fail("No new Steam request for this verified checkpoint"))
            self.assertTrue(f.final.exists())

    def test_main_preserves_structured_failure_fields_in_json_event(self):
        failure = installer.InstallFailure("fixture error", "steam_depot_size_mismatch", False,
            "steam-depot-validation", appID="10", depotID="11", manifestID="123", expectedBytes=6, actualBytes=0)
        events = []
        with patch.object(installer.sys, "argv", ["steam-installer.py", "--appid", "10", "--accountid", ACCOUNT, "--renderer", "dxmt"]), \
             patch.object(installer, "active_steam_account", return_value=ACCOUNT), \
             patch.object(installer.os.path, "expanduser", return_value="/fixture-only"), \
             patch.object(installer.os.path, "exists", return_value=True), \
             patch.object(installer, "resolve_steam_info", return_value={"fixture": True}), \
             patch.object(installer, "install_depots", side_effect=failure), \
             patch.object(installer, "emit", side_effect=lambda *a, **k: events.append((a, k))):
            self.assertEqual(installer.main(), 1)
        self.assertEqual(events[-1][0], ("failed", "Installation", None, "fixture error"))
        self.assertEqual(events[-1][1], failure.details)

    def test_worker_stage_metrics_are_scoped_to_actual_hash_and_copy_counts(self):
        with tempfile.TemporaryDirectory(prefix="playmelt-stage-test-") as temporary:
            f = self.fixture(Path(temporary).resolve(), redist=True)
            events = self.run_install(f)
            measurements = [row for _, data in events for row in data.get("stages", [])]
            downloads = [row for row in measurements if row["id"] == "download"]
            self.assertEqual(downloads[0]["completedUnits"], 0, "logical cache size is not proof of downloaded bytes")
            self.assertEqual(downloads[0]["unit"], "verified-bytes")
            verifies = [row for row in measurements if row["id"] == "verify" and row.get("unit") == "bytes"]
            self.assertTrue(any(row.get("completedUnits") == 0 and row.get("totalUnits") == 6 for row in verifies))
            self.assertTrue(any(row.get("completedUnits") == 6 and row.get("totalUnits") == 6 for row in verifies))
            copies = [row for row in measurements if row["id"] == "prepare" and row.get("unit") == "bytes"]
            self.assertTrue(any(row.get("completedUnits") == 6 and row.get("totalUnits") == 6 for row in copies))
            final = events[-1][1]["stages"]
            self.assertTrue(all(row["status"] == "completed" and row["progress"] == 1 for row in final[:3]))
            self.assertEqual(final[-1], {"id":"components", "status":"waiting", "progress":None})

    def test_aggregate_worker_percent_never_becomes_a_verification_stage_percent(self):
        output = io.StringIO()
        with patch.object(installer.sys, "stdout", output):
            installer.emit("validating", "Vérification", 0.82, "Measured value unavailable")
        event = json.loads(output.getvalue())
        self.assertEqual(event["percent"], 0.82, "legacy aggregate retained only for old callers")
        self.assertEqual(event["stages"], [{"id":"verify", "status":"active", "progress":None}])


if __name__ == "__main__":
    unittest.main()
