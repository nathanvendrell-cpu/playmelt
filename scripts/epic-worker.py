#!/usr/bin/env python3
"""Optional Epic adapter; JSON over private stdin/stdout pipes, never argv secrets.

Requires official PyPI legendary-gl 0.21.1. This worker never imports an Epic
Launcher session or reads Legendary's existing user.json. Credentials exist
only in memory; the native owner decides their lifetime. Temporary non-secret
Legendary metadata is removed by TemporaryDirectory even after failures.

Prepare, do not automatically execute:
  python3 -m venv Dependencies.noindex/epic-venv
  Dependencies.noindex/epic-venv/bin/python3 -m pip install \
    'https://files.pythonhosted.org/packages/4c/d5/d9648a3ebc7af8251c2126b97a331cc29e31921298f217c09a536bf1d283/legendary_gl-0.21.1-py3-none-any.whl#sha256=e1beedfaaed45ab372b7af047c092723f62a69e65666d81ffe654c61fac09e9c'
The Legendary wheel is pinned and hashed; its transitive dependencies are not
a fully locked distribution. This is an optional local integration, not a
claim of Epic endorsement. GPLv3 notices/source apply when redistributing.
"""

import contextlib
import copy
import importlib.metadata
import io
import json
import logging
import os
from pathlib import Path
import re
import signal
import sys
import tempfile
from datetime import datetime, timezone
from urllib.parse import urlparse

PINNED_VERSION = "0.21.1"
MAX_INPUT_BYTES = 1024 * 1024
ERRORS = {
    "missingDependency": "Connecteur Epic absent. Préparer la dépendance Legendary 0.21.1 pour MetalMax.",
    "unsupportedDependency": "Version Legendary non validée. Cette intégration attend la version 0.21.1.",
    "invalidRequest": "Requête Epic invalide.",
    "requiresLogin": "Connectez votre compte Epic pour synchroniser sa bibliothèque.",
    "authenticationFailed": "Connexion Epic refusée ou expirée. Recommencez la connexion dans le navigateur Epic.",
    "networkError": "Epic est temporairement indisponible. La bibliothèque n’a pas été actualisée.",
    "adapterError": "Le connecteur Epic n’a pas pu lire la réponse. Aucune bibliothèque complète n’est annoncée.",
}


def failure(code):
    return {"ok": False, "error": {"code": code, "message": ERRORS[code]}}


def clean_code(value):
    if not isinstance(value, str) or len(value) > 8192:
        raise ValueError("invalid code")
    value = value.strip()
    if value.startswith("{"):
        value = json.loads(value).get("authorizationCode", "")
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_-]{16,4096}", value):
        raise ValueError("invalid code")
    return value


def memory_storage_class(base_class, initial_session):
    """Override the on-disk userdata property BEFORE LegendaryCore creation."""
    class MemoryStorage(base_class):
        def __init__(self, *args, **kwargs):
            self._metalmax_session = copy.deepcopy(initial_session) if initial_session else None
            super().__init__(*args, **kwargs)

        @property
        def userdata(self):
            return self._metalmax_session

        @property
        @contextlib.contextmanager
        def userdata_lock(self):
            class Lock:
                def __init__(self, data):
                    self.data = data

                def clear(self):
                    self.data = None
            lock = Lock(self._metalmax_session)
            try:
                yield lock
            finally:
                self._metalmax_session = lock.data

        def invalidate_userdata(self):
            self._metalmax_session = None
    return MemoryStorage


@contextlib.contextmanager
def isolated_core(core_module, session):
    old_storage = core_module.LGDLFS
    old_config = os.environ.get("LEGENDARY_CONFIG_PATH")
    core = None
    with tempfile.TemporaryDirectory(prefix="metalmax-epic-") as directory:
        os.environ["LEGENDARY_CONFIG_PATH"] = directory
        core_module.LGDLFS = memory_storage_class(old_storage, session)
        try:
            core = core_module.LegendaryCore(timeout=15.0)
            core.lgd.config.set("Legendary", "disable_update_check", "true")
            core.lgd.config.set("Legendary", "disable_update_notice", "true")
            yield core
        finally:
            if core is not None:
                for name in ("session", "unauth_session"):
                    network_session = getattr(core.egs, name, None)
                    if network_session is not None:
                        network_session.close()
            core_module.LGDLFS = old_storage
            if old_config is None:
                os.environ.pop("LEGENDARY_CONFIG_PATH", None)
            else:
                os.environ["LEGENDARY_CONFIG_PATH"] = old_config


def safe_image(metadata):
    allowed = {"cdn1.epicgames.com", "cdn2.unrealengine.com", "cdn1.unrealengine.com", "cdn.unrealengine.com"}
    images = metadata.get("keyImages", [])
    if not isinstance(images, list):
        return ""
    images = sorted((i for i in images if isinstance(i, dict)), key=lambda i: i.get("type") != "DieselGameBoxTall")
    for image in images:
        value = image.get("url", "")
        if isinstance(value, str) and len(value) < 4096:
            url = urlparse(value)
            if url.scheme == "https" and url.hostname in allowed and not url.username and not url.password:
                return value
    return ""


def normalize_games(platform_results, noninstallable):
    merged = {}
    for platform, games, dlc_map in platform_results:
        for game in games:
            metadata = game.metadata or {}
            if metadata.get("namespace") == "ue" or game.is_dlc:
                continue
            app_name = str(game.app_name)
            if not app_name or len(app_name) > 512:
                continue
            row = merged.setdefault(app_name, {
                "id": "epic-owned:" + app_name, "appName": app_name,
                "title": str(game.app_title)[:500], "store": "epic",
                "namespace": str(metadata.get("namespace", "")),
                "catalogItemId": str(metadata.get("id", "")),
                "platforms": [], "dlcs": [], "ownership": "authenticated-library",
                "imageURL": safe_image(metadata), "installed": False,
                "canLaunch": False, "canInstall": False,
            })
            if platform and platform not in row["platforms"]:
                row["platforms"].append(platform)
            known_dlc = {d["appName"] for d in row["dlcs"]}
            for dlc in dlc_map.get(metadata.get("id"), []):
                if dlc.app_name not in known_dlc:
                    row["dlcs"].append({"appName": str(dlc.app_name), "title": str(dlc.app_title)[:500]})
                    known_dlc.add(dlc.app_name)
    for game in noninstallable:
        if game.app_name not in merged:
            for row in normalize_games([(None, [game], {})], []):
                row["requiresExternalLauncher"] = True
                merged[row["appName"]] = row
    for row in merged.values():
        row["platforms"].sort()
        row["platform"] = "mac" if "Mac" in row["platforms"] else "windows" if "Windows" in row["platforms"] else "unknown"
    return sorted(merged.values(), key=lambda r: (r["title"].casefold(), r["appName"]))


def installed_manifests(directory=None):
    """Read non-credential official launcher manifests; never infer ownership."""
    directory = directory or Path.home() / "Library/Application Support/Epic/EpicGamesLauncher/Data/Manifests"
    rows = {}
    for path in sorted(Path(directory).glob("*.item")):
        try:
            if path.stat().st_size > 2 * 1024 * 1024:
                continue
            data = json.loads(path.read_text(encoding="utf-8"))
            if data.get("CatalogNamespace") == "ue" or data.get("bIsIncompleteInstall"):
                continue
            app_name = data.get("AppName")
            folder = data.get("InstallLocation")
            executable = data.get("LaunchExecutable")
            if not all(isinstance(v, str) and v for v in (app_name, folder, executable)):
                continue
            root = Path(folder).resolve()
            target = (root / executable).resolve()
            if not root.is_dir() or not target.is_file() or root not in target.parents:
                continue
            rows[app_name] = {"appName": app_name, "title": str(data.get("DisplayName", app_name))[:500],
                              "installPath": str(root), "source": "epic-manifest", "ownership": "installed-only"}
        except (OSError, ValueError, TypeError):
            continue
    return list(rows.values())


def load_library(core):
    results = []
    for platform in ("Windows", "Mac"):
        games, dlcs = core.get_game_and_dlc_list(platform=platform, skip_ue=True)
        results.append((platform, games, dlcs))
    noninstallable, _ = core.get_non_asset_library_items(skip_ue=True)
    return normalize_games(results, noninstallable)


def establish_session(core, action, session, code=None):
    """Use EPCAPI directly: Core's bool wrappers swallow network exceptions.

    An expired access token is not an expired refresh token. Retry refresh only
    after an explicit InvalidCredentialsError; connection/timeouts propagate
    without throwing away the caller's in-memory session.
    """
    if action == "authenticate":
        data = core.egs.start_session(authorization_code=code)
    elif isinstance(session, dict):
        data = copy.deepcopy(session)
        if data.get("access_token"):
            try:
                data = core.egs.resume_session(data)
            except Exception as error:
                if type(error).__name__ != "InvalidCredentialsError" or not session.get("refresh_token"):
                    raise
                data = core.egs.start_session(refresh_token=session["refresh_token"])
        elif data.get("refresh_token"):
            data = core.egs.start_session(refresh_token=data["refresh_token"])
        else:
            raise ValueError("session unavailable")
    else:
        raise ValueError("session unavailable")
    if not isinstance(data, dict) or not data.get("account_id"):
        raise ValueError("invalid session response")
    with core.lgd.userdata_lock as lock:
        lock.data = data
    core.logged_in = True
    return data


def handle(request, core_module=None, version_lookup=None, manifest_reader=installed_manifests):
    if not isinstance(request, dict) or request.get("action") not in ("status", "authURL", "authenticate", "sync"):
        return failure("invalidRequest")
    try:
        version = (version_lookup or importlib.metadata.version)("legendary-gl")
    except importlib.metadata.PackageNotFoundError:
        return failure("missingDependency")
    if version != PINNED_VERSION:
        return failure("unsupportedDependency")
    if request["action"] == "status":
        return {"ok": True, "version": version, "credentialStorage": "memory", "sessionLifetime": "until-app-closes"}
    if core_module is None:
        try:
            import legendary.core as core_module
        except ImportError:
            return failure("missingDependency")
    session = request.get("session")
    if session is not None and not isinstance(session, dict):
        return failure("invalidRequest")
    action = request["action"]
    if action == "sync" and not session:
        return failure("requiresLogin")
    updated_session = copy.deepcopy(session) if session else None
    try:
        with isolated_core(core_module, session) as core:
            if action == "authURL":
                url = core.egs.get_auth_url()
                parsed = urlparse(url)
                if parsed.scheme != "https" or parsed.hostname != "www.epicgames.com" or parsed.path != "/id/login":
                    return failure("adapterError")
                return {"ok": True, "url": url}
            code = None
            if action == "authenticate":
                try:
                    code = clean_code(request.get("code"))
                except (ValueError, TypeError):
                    return failure("invalidRequest")
            updated_session = establish_session(core, action, session, code)
            games = load_library(core)
            installed = manifest_reader()
            # Credentials travel only to native through its private pipe, never to WebKit.
            return {"ok": True, "session": updated_session,
                    "snapshot": {"accountId": str(updated_session["account_id"]),
                                 "displayName": str(updated_session.get("displayName", "Compte Epic")),
                                 "games": games, "installed": installed,
                                 "source": "legendary-authenticated-library",
                                 "updatedAt": datetime.now(timezone.utc).isoformat(),
                                 "credentialStorage": "memory", "sessionLifetime": "until-app-closes"}}
    except Exception as error:
        if type(error).__name__ == "InvalidCredentialsError":
            return failure("authenticationFailed")
        if type(error).__name__ in ("HTTPError", "ConnectionError", "Timeout", "ReadTimeout", "ConnectTimeout"):
            result = failure("networkError")
        else:
            result = failure("adapterError")
        # A successful refresh may rotate the credential before a library call
        # fails. Preserve it privately without presenting incomplete games.
        if isinstance(updated_session, dict):
            result["session"] = updated_session
        return result


def main():
    # Never emit imported-library logs, exception reprs, response bodies, codes or tokens.
    logging.disable(logging.CRITICAL)
    def interrupted(signum, _frame):
        # Let context managers close HTTP sessions and remove metadata scratch.
        raise SystemExit(128 + signum)
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        raw = sys.stdin.buffer.read(MAX_INPUT_BYTES + 1)
        if len(raw) > MAX_INPUT_BYTES:
            result = failure("invalidRequest")
        else:
            request = json.loads(raw)
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                result = handle(request)
    except Exception:
        result = failure("invalidRequest")
    sys.stdout.write(json.dumps(result, ensure_ascii=False, separators=(",", ":")) + "\n")


if __name__ == "__main__":
    main()
