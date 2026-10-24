#!/usr/bin/env python3
"""Offline fixtures only. No Epic login, package installation or network calls."""
import configparser
import importlib.metadata
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest

WORKER = Path(__file__).resolve().parents[1] / "scripts/epic-worker.py"
spec = importlib.util.spec_from_file_location("epic_worker", WORKER)
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


def game(name="factory", title="Factory", namespace="games", platforms=("Windows",), dlc=False):
    return SimpleNamespace(app_name=name, app_title=title, is_dlc=dlc,
                           metadata={"id": name + "-catalog", "namespace": namespace},
                           asset_infos={p: {} for p in platforms})


class FakeStorage:
    def __init__(self, **kwargs):
        self.path = os.environ["LEGENDARY_CONFIG_PATH"]
        self.config = configparser.ConfigParser()
        self.config.add_section("Legendary")
    @property
    def userdata(self):
        raise AssertionError("Original disk credentials must not be read")
    @property
    def userdata_lock(self):
        raise AssertionError("Original credential lock must not be used")


class FakeNetwork:
    def __init__(self): self.closed = False
    def close(self): self.closed = True


class FakeEPCAPI:
    def __init__(self):
        self.session = FakeNetwork()
        self.unauth_session = FakeNetwork()
    def get_auth_url(self): return "https://www.epicgames.com/id/login?redirectUrl=test"
    def start_session(self, authorization_code=None, refresh_token=None):
        return {"account_id": "fixture-account", "displayName": "Fixture Player", "access_token": "fixture-access", "refresh_token": "fixture-only-secret"}
    def resume_session(self, session): return session


class FakeCore:
    instances = []
    def __init__(self, timeout):
        self.lgd = MODULE.LGDLFS()
        self.egs = FakeEPCAPI()
        self.instances.append(self)
        self.platforms = []
    def auth_code(self, code):
        raise AssertionError("The ambiguous bool auth wrapper must not be used")
    def login(self): raise AssertionError("The ambiguous bool login wrapper must not be used")
    def get_game_and_dlc_list(self, platform, skip_ue):
        self.platforms.append(platform)
        return [game(platforms=(platform,)), game("engine", namespace="ue")], {}
    def get_non_asset_library_items(self, skip_ue): return [game("external")], {}


MODULE = SimpleNamespace(LGDLFS=FakeStorage, LegendaryCore=FakeCore)


class EpicTests(unittest.TestCase):
    def handle(self, request, **kwargs):
        return worker.handle(request, MODULE, lambda _: "0.21.1", manifest_reader=lambda: [], **kwargs)

    def test_dependency_absence_is_explicit(self):
        def absent(_): raise importlib.metadata.PackageNotFoundError()
        value = worker.handle({"action": "status"}, version_lookup=absent)
        self.assertEqual(value["error"]["code"], "missingDependency")

    def test_unvalidated_version_is_rejected(self):
        value = worker.handle({"action": "status"}, version_lookup=lambda _: "999")
        self.assertEqual(value["error"]["code"], "unsupportedDependency")

    def test_no_session_requires_login(self):
        self.assertEqual(self.handle({"action": "sync"})["error"]["code"], "requiresLogin")

    def test_auth_never_uses_original_credentials_and_cleans_scratch(self):
        original = os.environ.get("LEGENDARY_CONFIG_PATH")
        value = self.handle({"action": "authenticate", "code": "a" * 32})
        self.assertTrue(value["ok"])
        self.assertEqual(value["snapshot"]["accountId"], "fixture-account")
        self.assertNotIn("fixture-only-secret", json.dumps(value["snapshot"]))
        self.assertEqual(value["session"]["refresh_token"], "fixture-only-secret")
        self.assertIs(MODULE.LGDLFS, FakeStorage)
        self.assertEqual(os.environ.get("LEGENDARY_CONFIG_PATH"), original)
        instance = FakeCore.instances[-1]
        self.assertFalse(Path(instance.lgd.path).exists())
        self.assertTrue(instance.egs.session.closed)
        self.assertTrue(instance.egs.unauth_session.closed)
        self.assertEqual(instance.platforms, ["Windows", "Mac"])

    def test_platform_union_and_noninstallable_are_honest(self):
        value = self.handle({"action": "authenticate", "code": "b" * 32})
        rows = {g["appName"]: g for g in value["snapshot"]["games"]}
        self.assertEqual(set(rows), {"factory", "external"})
        self.assertEqual(rows["factory"]["platforms"], ["Mac", "Windows"])
        self.assertEqual(rows["external"]["platforms"], [])
        self.assertTrue(rows["external"]["requiresExternalLauncher"])
        self.assertFalse(any(g["installed"] or g["canLaunch"] or g["canInstall"] for g in rows.values()))

    def test_storage_cleans_on_failure(self):
        location = None
        with self.assertRaises(RuntimeError):
            with worker.isolated_core(MODULE, {"account_id": "fixture"}) as core:
                location = core.lgd.path
                with core.lgd.userdata_lock as lock: lock.clear()
                self.assertIsNone(core.lgd.userdata)
                raise RuntimeError("fixture")
        self.assertFalse(Path(location).exists())
        self.assertIs(MODULE.LGDLFS, FakeStorage)

    def test_failed_library_keeps_rotated_session_without_partial_data(self):
        original = FakeCore.get_game_and_dlc_list
        class ReadTimeout(Exception): pass
        def fail(*args, **kwargs): raise ReadTimeout("fixture-only-secret")
        FakeCore.get_game_and_dlc_list = fail
        try:
            value = self.handle({"action": "authenticate", "code": "c" * 32})
        finally:
            FakeCore.get_game_and_dlc_list = original
        self.assertEqual(value["error"]["code"], "networkError")
        self.assertNotIn("snapshot", value)
        self.assertEqual(value["session"]["refresh_token"], "fixture-only-secret")
        self.assertNotIn("fixture-only-secret", json.dumps(value["error"]))

    def test_network_login_failure_preserves_existing_session(self):
        original = FakeEPCAPI.resume_session
        class ReadTimeout(Exception): pass
        def fail(*args, **kwargs): raise ReadTimeout("fixture-only-secret")
        FakeEPCAPI.resume_session = fail
        saved = {"account_id": "fixture-account", "access_token": "fixture-access", "refresh_token": "fixture-only-secret"}
        try:
            value = self.handle({"action": "sync", "session": saved})
        finally:
            FakeEPCAPI.resume_session = original
        self.assertEqual(value["error"]["code"], "networkError")
        self.assertEqual(value["session"], saved)
        self.assertNotIn("snapshot", value)

    def test_expired_access_token_refreshes_before_invalidating(self):
        original = FakeEPCAPI.resume_session
        class InvalidCredentialsError(Exception): pass
        def expired(*args, **kwargs): raise InvalidCredentialsError("expired access")
        FakeEPCAPI.resume_session = expired
        try:
            value = self.handle({"action": "sync", "session": {"account_id": "fixture-account", "access_token": "expired", "refresh_token": "fixture-refresh"}})
        finally:
            FakeEPCAPI.resume_session = original
        self.assertTrue(value["ok"])
        self.assertEqual(value["session"]["access_token"], "fixture-access")

    def test_explicit_invalid_refresh_is_only_authentication_failure(self):
        original = FakeEPCAPI.start_session
        class InvalidCredentialsError(Exception): pass
        def invalid(*args, **kwargs): raise InvalidCredentialsError("fixture-only-secret")
        FakeEPCAPI.start_session = invalid
        try:
            value = self.handle({"action": "sync", "session": {"account_id": "fixture-account", "refresh_token": "invalid"}})
        finally:
            FakeEPCAPI.start_session = original
        self.assertEqual(value["error"]["code"], "authenticationFailed")
        self.assertNotIn("session", value)
        self.assertNotIn("fixture-only-secret", json.dumps(value))

    def test_auth_code_network_failure_is_not_invalid_credentials(self):
        original = FakeEPCAPI.start_session
        class ConnectionError(Exception): pass
        def unavailable(*args, **kwargs): raise ConnectionError("fixture-only-secret")
        FakeEPCAPI.start_session = unavailable
        try:
            value = self.handle({"action": "authenticate", "code": "d" * 32})
        finally:
            FakeEPCAPI.start_session = original
        self.assertEqual(value["error"]["code"], "networkError")
        self.assertNotIn("fixture-only-secret", json.dumps(value))

    def test_code_rejects_shell_or_newline_and_accepts_json(self):
        for value in (None, "$(say hi)", "a" * 32 + "\nsecret", {"code": "a" * 32}):
            with self.assertRaises((ValueError, TypeError)): worker.clean_code(value)
        self.assertEqual(worker.clean_code(json.dumps({"authorizationCode": "a" * 32})), "a" * 32)

    def test_installed_manifest_filters_ue_stale_and_escape(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); manifests = root / "manifests"; manifests.mkdir()
            install = root / "game"; install.mkdir(); (install / "game.exe").write_text("fixture")
            (root / "outside.exe").write_text("fixture")
            base = {"AppName": "real", "DisplayName": "Real", "CatalogNamespace": "games", "InstallLocation": str(install), "LaunchExecutable": "game.exe"}
            entries = [base, base, dict(base, AppName="ue", CatalogNamespace="ue"),
                       dict(base, AppName="partial", bIsIncompleteInstall=True),
                       dict(base, AppName="escape", LaunchExecutable="../outside.exe"),
                       dict(base, AppName="missing", LaunchExecutable="missing.exe")]
            for i, entry in enumerate(entries): (manifests / f"{i}.item").write_text(json.dumps(entry))
            rows = worker.installed_manifests(manifests)
            self.assertEqual([r["appName"] for r in rows], ["real"])
            self.assertEqual(rows[0]["ownership"], "installed-only")

    def test_image_allowlist(self):
        self.assertEqual(worker.safe_image({"keyImages": [{"url": "https://evil.test/image.png"}]}), "")
        self.assertEqual(worker.safe_image({"keyImages": [{"url": "https://cdn1.epicgames.com/a.png"}]}), "https://cdn1.epicgames.com/a.png")

    def test_error_does_not_echo_secret(self):
        result = subprocess.run([sys.executable, "-I", str(WORKER)], input=b'{bad-fixture-secret', capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["error"]["code"], "invalidRequest")
        self.assertNotIn(b"fixture-secret", result.stdout + result.stderr)
        self.assertEqual(result.stderr, b"")


if __name__ == "__main__":
    unittest.main()
