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
import hashlib
import io
import json
import logging
import os
from pathlib import Path
import re
import signal
import stat
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
    "accountChanged": "Le compte Epic a changé. Reconnectez le compte voulu avant de continuer.",
    "networkError": "Epic est temporairement indisponible. La bibliothèque n’a pas été actualisée.",
    "adapterError": "Le connecteur Epic n’a pas pu lire la réponse. Aucune bibliothèque complète n’est annoncée.",
    "notOwned": "Ce jeu n’est pas disponible pour ce compte Epic sur cette plateforme.",
    "installationFailed": "L’installation Epic n’est pas vérifiée. Aucun état prêt à jouer n’est annoncé.",
    "invalidInstallation": "Cette installation Epic doit être vérifiée ou réinstallée avant le lancement.",
}


class AccountChangedError(Exception):
    """Identity changed during refresh; never retain or expose that new session."""


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
    if not isinstance(data, dict) or not isinstance(data.get("account_id"), str) or not data["account_id"]:
        raise ValueError("invalid session response")
    if action != "authenticate" and data["account_id"] != session.get("account_id"):
        raise AccountChangedError()
    with core.lgd.userdata_lock as lock:
        lock.data = data
    core.logged_in = True
    return data


class OperationError(Exception):
    def __init__(self, code): self.code = code


def managed_root():
    return Path.home() / "Library/Application Support/Playmelt/Games"


def operation_input(request, session):
    app = request.get("appName")
    account = request.get("expectedAccountId")
    platform = request.get("platform")
    if (not isinstance(app, str) or not re.fullmatch(r"[A-Za-z0-9_.-]{1,512}", app)
            or app in (".", "..") or platform not in ("Mac", "Windows")
            or not isinstance(account, str) or not account or len(account) > 128):
        raise OperationError("invalidRequest")
    if not session: raise OperationError("requiresLogin")
    if session.get("account_id") != account: raise AccountChangedError()
    return app, platform, account


def owned_game(core, app, platform):
    games, _ = core.get_game_and_dlc_list(platform=platform, skip_ue=True)
    for game in games:
        if game.app_name == app and not game.is_dlc and game.metadata.get("namespace") != "ue":
            return game
    raise OperationError("notOwned")


def safe_target(root, relative, allow_symlink=False):
    if (not isinstance(relative, str) or not relative or "\x00" in relative
            or relative.startswith(("/", "\\")) or ".." in relative.replace("\\", "/").split("/")):
        raise OperationError("invalidInstallation")
    target = root / relative.replace("\\", "/")
    if root.resolve() not in target.resolve().parents or (target.is_symlink() and not allow_symlink):
        raise OperationError("invalidInstallation")
    return target


def checked_directory(root):
    # Only this app's managed game root; no imported Legendary configuration.
    if root != Path.home() and Path.home() not in root.parents:
        raise OperationError("invalidInstallation")
    current = root
    while current != Path.home().parent:
        if current.exists() and (current.is_symlink() or current.stat().st_uid != os.getuid()):
            raise OperationError("invalidInstallation")
        if current == Path.home(): break
        current = current.parent
    root.mkdir(parents=True, exist_ok=True)
    return root.resolve()


def verify_manifest(root, manifest):
    entries = manifest.file_manifest_list.elements
    if not entries: raise OperationError("installationFailed")
    for entry in entries:
        path = safe_target(root, entry.filename, allow_symlink=bool(getattr(entry, "symlink_target", "")))
        if getattr(entry, "symlink_target", ""):
            if not path.is_symlink() or os.readlink(path) != entry.symlink_target:
                raise OperationError("installationFailed")
            continue
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            mode = os.fstat(fd)
            if not stat.S_ISREG(mode.st_mode) or mode.st_size != entry.file_size:
                raise OperationError("installationFailed")
            digest = hashlib.sha1()
            while True:
                chunk = os.read(fd, 1024 * 1024)
                if not chunk: break
                digest.update(chunk)
            if digest.digest() != entry.hash: raise OperationError("installationFailed")
        finally: os.close(fd)


def save_installation(root, account, install, session=None, verification="manifest-sha1"):
    # Explicit non-credential allowlist; never persist base URLs, session or exchange code.
    keys = ("app_name", "title", "version", "install_path", "executable", "launch_parameters",
            "can_run_offline", "requires_ot", "platform", "prereq_info")
    record = {"schema": 1, "accountId": account, "verification": verification,
              "installed": {key: getattr(install, key, None) for key in keys}}
    data = json.dumps(record, ensure_ascii=False).encode("utf8")
    if len(data) > 65536: raise OperationError("invalidInstallation")
    for name in ("access_token", "refresh_token"):
        token = (session or {}).get(name)
        if token and token.encode("utf8") in data: raise OperationError("invalidInstallation")
    target = root / ".playmelt-epic-install.json"
    if target.exists():
        old = read_installation(root, account, install.app_name)
        if old["installed"]["platform"] != install.platform: raise OperationError("invalidInstallation")
    fd, name = tempfile.mkstemp(prefix=".epic-install-", dir=root)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as stream: stream.write(data); stream.flush(); os.fsync(stream.fileno())
        os.replace(name, target)
    finally:
        if os.path.exists(name): os.unlink(name)
    return record


def read_installation(root, account, app):
    path = root / ".playmelt-epic-install.json"
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        s = os.fstat(fd)
        if not stat.S_ISREG(s.st_mode) or s.st_uid != os.getuid() or s.st_nlink != 1 or s.st_mode & 0o077 or s.st_size > 65536:
            raise OperationError("invalidInstallation")
        record = json.loads(os.read(fd, 65537))
    finally: os.close(fd)
    install = record.get("installed", {})
    if record.get("schema") != 1 or record.get("accountId") != account or install.get("app_name") != app or Path(install.get("install_path", "")).resolve() != root:
        raise OperationError("invalidInstallation")
    return record


def install_owned(core, request, game, account, root=None):
    app, platform, _ = operation_input(request, core.lgd.userdata)
    workers = request.get("maxWorkers", max(8, min((os.cpu_count() or 1) * 3, 32)))
    memory = request.get("sharedMemoryMiB", 1024)
    if type(workers) is not int or not 8 <= workers <= 32 or type(memory) is not int or memory not in (1024, 2048, 4096):
        raise OperationError("invalidRequest")
    base = checked_directory(root or managed_root())
    destination = base / (app + "-" + platform.lower())
    partial = destination / ".playmelt-epic-partial.json"
    partial_bytes = json.dumps({"schema": 1, "accountId": account, "appName": app, "platform": platform}, sort_keys=True).encode()
    if destination.exists():
        if destination.is_symlink() or destination.stat().st_uid != os.getuid(): raise OperationError("invalidInstallation")
        # Refuse another account's receipt before any download or overwrite.
        if (destination / ".playmelt-epic-install.json").exists():
            read_installation(destination.resolve(), account, app)
        elif partial.is_symlink() or not partial.is_file() or partial.read_bytes() != partial_bytes:
            raise OperationError("invalidInstallation")
    else:
        destination.mkdir(mode=0o700)
        fd = os.open(partial, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "wb") as stream: stream.write(partial_bytes)
    resume = destination / ".playmelt-epic-download-state"
    if resume.is_symlink(): raise OperationError("invalidInstallation")
    resume.mkdir(mode=0o700, exist_ok=True)
    core.lgd.get_tmp_path = lambda: str(resume)  # Only non-credential resumable file hashes.
    dlm = None
    try:
        dlm, analysis, install = core.prepare_download(game, base_path=str(base), game_folder=destination.name,
            platform=platform, max_workers=workers, max_shm=memory, dl_timeout=20,
            preferred_cdn="egdownload.fastly-edge.com", disable_https=False)
        if Path(install.install_path).resolve() != destination: raise OperationError("invalidInstallation")
        conditions = core.check_installation_conditions(analysis, install, game, updating=False, ignore_space_req=False)
        if conditions.failures: raise OperationError("installationFailed")
        if analysis.dl_size:
            dlm.start(); dlm.join()
            if dlm.exitcode != 0: raise OperationError("installationFailed")
        manifest = core.load_manifest(core.lgd.load_manifest(app, install.version, platform))
        verify_manifest(destination, manifest)
        executable = safe_target(destination, install.executable)
        if not executable.is_file(): raise OperationError("installationFailed")
        save_installation(destination, account, install, session=core.lgd.userdata)
        return {"accountId": account, "appName": app, "platform": platform,
                "installPath": str(destination), "executable": install.executable,
                "filesVerified": True, "prerequisitesRequired": bool(install.prereq_info),
                "title": install.title, "version": install.version}
    finally:
        if dlm is not None and dlm.pid is not None:
            if dlm.is_alive(): dlm.terminate()
            dlm.join(timeout=5)
            if dlm.is_alive(): dlm.kill(); dlm.join(timeout=5)


def launch_owned(core, request, game, account, root=None, installed_factory=None):
    app, platform, _ = operation_input(request, core.lgd.userdata)
    base = checked_directory(root or managed_root())
    raw_path = request.get("installPath")
    if not isinstance(raw_path, str): raise OperationError("invalidRequest")
    destination = Path(raw_path)
    if destination.is_symlink() or destination.resolve().parent != base: raise OperationError("invalidInstallation")
    destination = destination.resolve()
    if installed_factory is None:
        from legendary.models.game import InstalledGame
        installed_factory = InstalledGame.from_json
    receipt = destination / ".playmelt-epic-install.json"
    if not receipt.exists():
        # Explicit launch of an older Playmelt installation: verify against the
        # current owned manifest without reading Legendary's global profile.
        data, _, _, secrets = core.get_cdn_manifest(game, platform, disable_https=False)
        manifest = core.load_manifest(data)
        if not manifest.decrypt(secrets): raise OperationError("invalidInstallation")
        target = safe_target(destination, manifest.meta.launch_exe)
        fd = os.open(target, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode): raise OperationError("invalidInstallation")
            magic = os.read(fd, 4)
            if platform == "Windows" and not magic.startswith(b"MZ"): raise OperationError("invalidInstallation")
            if platform == "Mac" and magic not in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf", b"\xbe\xba\xfe\xca", b"\xbf\xba\xfe\xca"):
                raise OperationError("invalidInstallation")
        finally: os.close(fd)
        attributes = game.metadata.get("customAttributes", {})
        install = installed_factory({"app_name": app, "title": game.app_title,
            "version": manifest.meta.build_version, "install_path": str(destination),
            "executable": manifest.meta.launch_exe, "launch_parameters": manifest.meta.launch_command,
            "platform": platform, "requires_ot": attributes.get("OwnershipToken", {}).get("value", "false").lower() == "true",
            "can_run_offline": attributes.get("CanRunOffline", {}).get("value", "true").lower() == "true"})
        save_installation(destination, account, install, session=core.lgd.userdata, verification="declared-executable")
    record = read_installation(destination.resolve(), account, app)
    if record["installed"].get("platform") != platform: raise OperationError("invalidInstallation")
    core.lgd.set_installed_game(app, installed_factory(record["installed"]))
    params = core.get_launch_parameters(app, offline=False, disable_wine=True)
    executable = safe_target(destination, params.game_executable)
    working = Path(params.working_directory).resolve()
    if not executable.is_file() or (working != destination and destination not in working.parents): raise OperationError("invalidInstallation")
    args = params.game_parameters + params.egl_parameters + params.user_parameters
    if not all(isinstance(arg, str) and len(arg) <= 16384 and "\x00" not in arg for arg in args): raise OperationError("invalidInstallation")
    # Access/refresh credentials may never become game parameters, even on a malformed SDK response.
    for name in ("access_token", "refresh_token"):
        token = core.lgd.userdata.get(name)
        if token and any(token in arg for arg in args): raise OperationError("invalidInstallation")
    ownership = None
    for index, arg in enumerate(args):
        if arg.startswith("-epicovt="):
            token_path = Path(arg.split("=", 1)[1]).resolve()
            if Path(core.lgd.path).resolve() not in token_path.parents or token_path.stat().st_size > 65536:
                raise OperationError("invalidInstallation")
            import base64
            ownership = base64.b64encode(token_path.read_bytes()).decode("ascii")
            args[index] = "-epicovt=__PLAYMELT_PRIVATE_OWNERSHIP_TOKEN__"
    return {"accountId": account, "appName": app, "platform": platform, "executablePath": str(executable),
            "workingDirectory": str(working), "arguments": args, "ownershipToken": ownership}


def handle(request, core_module=None, version_lookup=None, manifest_reader=installed_manifests,
           operation_root=None, installed_factory=None):
    if not isinstance(request, dict) or request.get("action") not in ("status", "authURL", "authenticate", "sync", "install", "launchAuthorization"):
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
    if action in ("install", "launchAuthorization"):
        try: operation_input(request, session)
        except AccountChangedError: return failure("accountChanged")
        except OperationError as error: return failure(error.code)
    if action == "sync" and not session:
        return failure("requiresLogin")
    if action == "sync" and (not isinstance(session.get("account_id"), str) or not session["account_id"]):
        return failure("invalidRequest")
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
            if action in ("install", "launchAuthorization"):
                app, platform, account = operation_input(request, updated_session)
                game = owned_game(core, app, platform)  # Before prepare_download or any exchange code.
                if action == "install":
                    value = install_owned(core, request, game, account, root=operation_root)
                    return {"ok": True, "session": updated_session, "installation": value}
                value = launch_owned(core, request, game, account, root=operation_root, installed_factory=installed_factory)
                return {"ok": True, "session": updated_session, "launch": value}
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
        if isinstance(error, OperationError): return failure(error.code)
        if isinstance(error, AccountChangedError):
            return failure("accountChanged")
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


@contextlib.contextmanager
def quiet_process_output():
    # FD-level redirection is inherited by download children; even C/library logs
    # cannot contaminate the private JSON response or emit signed CDN URLs.
    saved = [os.dup(1), os.dup(2)]
    try:
        with open(os.devnull, "w") as sink:
            os.dup2(sink.fileno(), 1); os.dup2(sink.fileno(), 2)
            with contextlib.redirect_stdout(sink), contextlib.redirect_stderr(sink): yield
    finally:
        os.dup2(saved[0], 1); os.dup2(saved[1], 2)
        for fd in saved: os.close(fd)


def main():
    # Never emit imported-library logs, exception reprs, response bodies, codes or tokens.
    logging.disable(logging.CRITICAL)
    os.umask(0o077)
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
            with quiet_process_output():
                result = handle(request)
    except Exception:
        result = failure("invalidRequest")
    sys.stdout.write(json.dumps(result, ensure_ascii=False, separators=(",", ":")) + "\n")


if __name__ == "__main__":
    main()
