#!/usr/bin/env python3
"""
Playmelt Native Game Installer & Depot Downloader
Automates verified depot downloading and file deployment,
and Apple Silicon (Wine/Metal) launcher configuration for Steam games.
"""

import sys
import os
import time
import json
import subprocess
import shutil
import re
import shlex
import signal
import hashlib
import tempfile
import stat
import errno
from steam_appinfo import read_appinfo
from steam_install_plan import build_plan, PlanError
from steam_prerequisites import inspect_scripts, detect_renderer
from pathlib import Path

class InstallFailure(PlanError):
    def __init__(self, message, code, retryable=False, resume_point="steam-depot-validation", **details):
        super().__init__(message)
        self.details = dict(code=code, retryable=retryable, resumePoint=resume_point, **details)

_steam_handoffs = []


def reap_steam_handoffs():
    # Steam is an independent user application, never an owned cancellable job.
    # Poll reaps short IPC helpers without waiting for or terminating the client.
    _steam_handoffs[:] = [process for process in _steam_handoffs if process.poll() is None]

def stage_metric(stage_id, status="active", done=None, total=None, unit=None):
    row = {"id": stage_id, "status": status, "progress": None}
    if done is not None:
        row["completedUnits"] = done
    if total is not None:
        row["totalUnits"] = total
    if unit is not None:
        row["unit"] = unit
    if done is not None and total and 0 <= done <= total:
        row["progress"] = done / total
    return row


def emit(status, phase, percent, message, **kwargs):
    payload = {
        "status": status,
        "phase": phase,
        "percent": round(float(percent), 3) if percent is not None else None,
        "message": message
    }
    stage = {"downloading": "download", "installing": "prepare", "validating": "verify"}.get(status)
    if stage and "stages" not in kwargs:
        kwargs["stages"] = [stage_metric(stage)]
    payload.update(kwargs)
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()

def format_bytes(bytes_count):
    if bytes_count < 1024 * 1024:
        return f"{bytes_count / 1024:.1f} Ko"
    elif bytes_count < 1024 * 1024 * 1024:
        return f"{bytes_count / (1024 * 1024):.1f} Mo"
    else:
        return f"{bytes_count / (1024 * 1024 * 1024):.2f} Go"

def resolve_steam_info(app_id):
    try:
        cache = Path.home() / "Library/Application Support/Steam/appcache/appinfo.vdf"
        return build_plan(str(app_id), read_appinfo(cache))
    except OSError as exc:
        raise PlanError("Cache Steam indisponible. Ouvrez Steam et actualisez sa bibliothèque.") from exc

def get_dir_size(path):
    total = 0
    if not os.path.exists(path):
        return 0
    try:
        for entry in os.scandir(path):
            if entry.is_file(follow_symlinks=False):
                total += entry.stat().st_size
            elif entry.is_dir(follow_symlinks=False):
                total += get_dir_size(entry.path)
    except Exception:
        pass
    return total

def active_steam_account(login_path):
    try:
        text = Path(login_path).read_text(encoding="utf-8")
    except OSError:
        return None
    users = []
    for match in re.finditer(r'"(\d{17})"\s*\{([^{}]*)\}', text):
        fields = dict(re.findall(r'"([^"\n]+)"\s*"([^"\n]*)"', match[2]))
        users.append((match[1], fields))
    for flag in ("MostRecent", "AutoLogin"):
        for account, fields in sorted(users):
            if fields.get(flag) == "1":
                return account
    return None


def official_completion(log_text, content_dir, manifest_id):
    expected = os.path.normpath(content_dir)
    for path, gid in re.findall(r'Depot download complete\s*:\s*"([^"\n]+)"\s*\(manifest (\d+)\)', log_text):
        if os.path.normpath(path.replace("\\", "/")) == expected and gid == str(manifest_id):
            return True
    return False


def depot_attempt_problem(log_text, steam_osx_path, app_id, depot_id, manifest_id):
    """Attribute generic Valve errors only inside this exact console command.

    Steam's No subscription line has no depot ID. The fresh log offset and
    exact ExecCommandLine anchor identify our request; a subsequent command
    invalidates attribution rather than blaming an unrelated download.
    """
    expected = [steam_osx_path, "+download_depot", str(app_id), str(depot_id), str(manifest_id)]
    active = False
    for line in log_text.splitlines():
        if "ExecCommandLine:" in line:
            command = line.split("ExecCommandLine:", 1)[1].strip()
            if command.startswith('"') and command.endswith('"'):
                command = command[1:-1]
            try:
                arguments = shlex.split(command)
            except ValueError:
                arguments = []
            if active and arguments != expected:
                return "context-changed"
            active = arguments == expected
            continue
        if active and re.search(r"Depot download failed\s*:|(?:Depot|depot)\s+" + re.escape(str(depot_id)) + r"[^\n]*(?:failed|denied|No subscription)", line):
            return "denied"
    return None


def trigger_steam_depot_download(steam_osx_path, app_id, depot_id, manifest_id):
    cmd = [steam_osx_path, "+download_depot", str(app_id), str(depot_id), str(manifest_id)]
    try:
        reap_steam_handoffs()
        process = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        _steam_handoffs.append(process)
        return process
    except OSError:
        return False


class DepotLogCursor:
    """Incremental fresh-request attribution; no tail jumps or unbounded log buffer."""
    def __init__(self, path, steam_osx, depot):
        self.path, self.steam_osx, self.depot = path, steam_osx, depot
        self.boundary = b""
        current = None
        if path.exists():
            with path.open("rb") as handle:
                current = os.fstat(handle.fileno())
                handle.seek(max(0, current.st_size - 256))
                self.boundary = handle.read(256)
        self.identity = (current.st_dev, current.st_ino) if current else None
        self.offset = current.st_size if current else 0
        self.pending, self.anchor, self.complete, self.problem, self.backlog = b"", "", False, None, False
        self.expected = [steam_osx, "+download_depot", str(depot["appID"]), str(depot["depotID"]), str(depot["manifestID"])]

    def read(self, content):
        if not self.path.exists():
            self.backlog = False
            return False
        with self.path.open("rb") as handle:
            current = os.fstat(handle.fileno())
            identity = (current.st_dev, current.st_ino)
            if (self.identity is not None and identity != self.identity) or current.st_size < self.offset:
                return True
            if self.boundary:
                handle.seek(self.offset - len(self.boundary))
                if handle.read(len(self.boundary)) != self.boundary:
                    return True
            self.identity = identity
            handle.seek(self.offset)
            chunk = handle.read(1024 * 1024)
            self.offset = handle.tell()
            self.boundary = (self.boundary + chunk)[-256:]
            self.backlog = self.offset < current.st_size
        lines = (self.pending + chunk).split(b"\n")
        self.pending = lines.pop()
        if len(self.pending) > 65536 or any(len(line) > 65536 for line in lines):
            raise InstallFailure("Une ligne du journal Steam est trop longue pour être attribuée sûrement.",
                                 "steam_log_invalid", False, "steam-log-restart")
        for raw in lines:
            line = raw.decode("utf-8", "replace")
            if "ExecCommandLine:" in line:
                command = line.split("ExecCommandLine:", 1)[1].strip()
                if command.startswith('"') and command.endswith('"'):
                    command = command[1:-1]
                try:
                    arguments = shlex.split(command)
                except ValueError:
                    arguments = []
                if self.anchor and arguments != self.expected:
                    self.problem = "context-changed"
                    break
                self.anchor = line if arguments == self.expected else ""
            elif self.anchor:
                self.problem = depot_attempt_problem(self.anchor + "\n" + line, self.steam_osx,
                                                     self.depot["appID"], self.depot["depotID"], self.depot["manifestID"])
                if self.problem:
                    break
                if official_completion(line, str(content), self.depot["manifestID"]):
                    self.complete = True
                    break
        return False


def get_recent_download_rate(content_log_path):
    if not os.path.exists(content_log_path):
        return None
    try:
        with open(content_log_path, "rb") as f:
            f.seek(max(0, os.path.getsize(content_log_path) - 65_536))
            lines = f.read(65_536).decode("utf-8", "replace").splitlines()[-30:]
            for line in reversed(lines):
                m = re.search(r"Current download rate:\s*([0-9.]+)\s*Mbps", line)
                if m:
                    rate_mbps = float(m.group(1))
                    return f"{rate_mbps / 8.0:.1f} Mo/s"
    except Exception:
        pass
    return None

def create_launch_script(game_dir, chosen_exe, game_title, app_id=None, renderer=None, output_dir=None):
    runtime_dir = os.path.expanduser("~/Library/Application Support/Playmelt/Runtime")
    renderer_dir = os.path.expanduser("~/Library/Application Support/Playmelt/Renderers/D3DMetal/payload")
    
    lower_exe = chosen_exe.lower()
    quoted_dir = shlex.quote(game_dir)
    quoted_exe = shlex.quote(chosen_exe)
    is_unity = "unity" in lower_exe or any(
        os.path.isdir(os.path.join(game_dir, f)) and f.endswith("_Data")
        for f in os.listdir(game_dir)
    )
    
    # Check for DX12 requirement:
    # 1. Known DX12 app IDs
    dx12_app_ids = {"1783560", "2584270", "4711740"}
    is_dx12 = bool(app_id and str(app_id) in dx12_app_ids)
    
    proj_name = None
    if "-shipping.exe" in lower_exe:
        proj_candidates = [
            f for f in os.listdir(game_dir)
            if os.path.isdir(os.path.join(game_dir, f)) and f.lower() not in ["engine", "communityresources", "binaries", "redist"]
        ]
        if proj_candidates:
            proj_name = proj_candidates[0]
            
        # Check if directory contains UE5 markers or D3D12 binaries
        for root, dirs, files in os.walk(game_dir):
            if any(f.lower() in ["d3d12core.dll", "d3d12sdklayers.dll"] for f in files):
                is_dx12 = True
                break
            if os.path.basename(root).lower() == "nne" and "plugins" in root.lower():
                is_dx12 = True
                break

    # Unity games on macOS Wine are always run on DX11 via DXMT
    if renderer is not None:
        is_dx12 = renderer == "d3dmetal"
    elif str(app_id) == "526870":
        is_dx12 = False
    elif is_unity and str(app_id) not in dx12_app_ids:
        is_dx12 = False

    if is_dx12:
        extra_args = f"{shlex.quote(proj_name)} -d3d12" if proj_name else "-d3d12"
        content = f"""#!/bin/bash
# Lanceur direct Playmelt (Wine / D3DMetal DX12)
# Playmelt launcher v3
set -eo pipefail
GAME_DIR={quoted_dir}
RUNTIME_DIR={shlex.quote(runtime_dir)}
RENDERER_DIR={shlex.quote(renderer_dir)}

cd "$GAME_DIR"

export WINEPREFIX="$RUNTIME_DIR/D3DMetal/prefix"
export WINEDEBUG="fixme-all"
export WINEDLLOVERRIDES="d3d12,d3d12core,dxgi=n,b;winemenubuilder.exe=d"
export WINEDLLPATH_PREPEND="$RENDERER_DIR/wine"
export CX_D3DMETALPATH="$RENDERER_DIR/external"
export DYLD_FALLBACK_LIBRARY_PATH="$RENDERER_DIR/external:$RENDERER_DIR/external/D3DMetal.framework/Versions/A/Resources:$RUNTIME_DIR/playmelt-wine10-dxmt-20261017/frameworks:$RUNTIME_DIR/playmelt-wine10-dxmt-20261017/frameworks/GStreamer.framework/Versions/1.0/lib"
export DYLD_FALLBACK_FRAMEWORK_PATH="$RENDERER_DIR/external:$RUNTIME_DIR/playmelt-wine10-dxmt-20261017/frameworks"
export MVK_CONFIG_LOG_LEVEL=0

mkdir -p "$RUNTIME_DIR/logs"
exec "$RUNTIME_DIR/playmelt-wine10-dxmt-20261017/engine/bin/wine" {quoted_exe} {extra_args} "$@" 2>&1 | /usr/bin/tail -c 1048576 >"$RUNTIME_DIR/logs/game-{app_id}.log"
"""
    else:
        extra_args = "-force-d3d11" if is_unity else (f"{shlex.quote(proj_name)} -dx11" if proj_name else "-dx11")
        content = f"""#!/bin/bash
# Lanceur direct Playmelt (Wine / DXMT)
# Playmelt launcher v3
set -eo pipefail
GAME_DIR={quoted_dir}
RUNTIME_DIR={shlex.quote(runtime_dir)}

cd "$GAME_DIR"

export WINEPREFIX="$RUNTIME_DIR/prefix"
export WINEDEBUG="fixme-all"
export WINEDLLOVERRIDES="d3d11,dxgi,nvapi64=n,b;winemenubuilder.exe=d"
export WINEDLLPATH_PREPEND="$RUNTIME_DIR/playmelt-wine10-dxmt-20261017/renderers/dxmt/wine"
export DYLD_FALLBACK_LIBRARY_PATH="$RUNTIME_DIR/playmelt-wine10-dxmt-20261017/frameworks:$RUNTIME_DIR/playmelt-wine10-dxmt-20261017/frameworks/GStreamer.framework/Versions/1.0/lib"
export DYLD_FALLBACK_FRAMEWORK_PATH="$RUNTIME_DIR/playmelt-wine10-dxmt-20261017/frameworks"
export MVK_CONFIG_LOG_LEVEL=0

mkdir -p "$RUNTIME_DIR/logs"
exec "$RUNTIME_DIR/playmelt-wine10-dxmt-20261017/engine/bin/wine" {quoted_exe} {extra_args} "$@" 2>&1 | /usr/bin/tail -c 1048576 >"$RUNTIME_DIR/logs/game-{app_id}.log"
"""

    safe_title = "".join(c if c.isalnum() or c in " -_" else "-" for c in game_title).strip()
    script_path = os.path.join(output_dir or game_dir, f"Lancer-{safe_title}.command")
    if os.path.realpath(script_path) != os.path.abspath(script_path):
        raise PlanError("Le lanceur utilise un lien. Aucun fichier remplacé.")
    with open(script_path, "w", encoding="utf-8") as f:
        f.write(content)
    os.chmod(script_path, 0o755)
    return script_path

def main():
    import argparse
    parser = argparse.ArgumentParser(description="Playmelt Steam Depot Installer")
    parser.add_argument("--appid", required=True, help="Steam App ID")
    parser.add_argument("--title", default=None, help="Game Title")
    parser.add_argument("--accountid", required=True, help="Expected active Steam account")
    parser.add_argument("--renderer", choices=("dxmt", "d3dmetal"), required=True)
    parser.add_argument("--depotid", default=None, help="Steam Depot ID (optional)")
    args = parser.parse_args()
    
    app_id = str(args.appid).strip()
    if not re.fullmatch(r"[0-9]{1,10}", app_id) or not 0 < int(app_id) <= 0xFFFFFFFF:
        parser.error("Invalid Steam App ID")
    if not re.fullmatch(r"[0-9]{17}", args.accountid):
        parser.error("Invalid Steam account")
    user_title = args.title
    forced_depot = args.depotid
    if forced_depot is not None:
        parser.error("Forced depots cannot bypass the verified installation plan")
    
    home = os.path.expanduser("~")
    login_path = os.path.join(home, "Library/Application Support/Steam/config/loginusers.vdf")
    if active_steam_account(login_path) != args.accountid:
        emit("failed", "Compte", None, "Le compte actif Steam ne correspond plus au compte sélectionné.",
             code="steam_account_changed", retryable=False, resumePoint="steam-account-confirmation")
        return 1
    steam_osx = os.path.join(home, "Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steam_osx")
    if not os.path.exists(steam_osx):
        steam_osx = "/Applications/Steam.app/Contents/MacOS/steam_osx"
    
    if not os.path.exists(steam_osx):
        emit("failed", "Erreur", 0.0, "Steam n'est pas installé sur ce Mac.",
             code="steam_client_missing", retryable=False, resumePoint="steam-client-installation")
        return 1
        
    emit("downloading", "Téléchargement", 0.02, "Résolution des dépôts Steam en cours...")
    
    try:
        plan = resolve_steam_info(app_id)
        if not plan:
            raise PlanError("Plan Steam indisponible. Actualisez la bibliothèque.")
        return install_depots(args, plan, steam_osx, home, login_path)
    except PlanError as exc:
        emit("failed", "Installation", None, str(exc), **getattr(exc, "details", {
            "code": "steam_preparation_failed", "retryable": False, "resumePoint": "steam-depot-validation"}))
        return 1
    finally:
        reap_steam_handoffs()


def checked_files(folder):
    result = {}
    root = Path(folder)
    if root.resolve() != root.absolute():
        raise PlanError("Le dossier Steam utilise un lien non pris en charge")
    if not root.is_dir():
        raise PlanError("Le dossier du dépôt Steam est absent")
    for directory, dirs, files in os.walk(root, followlinks=False):
        for name in dirs + files:
            item = Path(directory, name)
            if item.is_symlink():
                raise PlanError("Un dépôt contient un lien non pris en charge. Les fichiers sont conservés.")
        for name in files:
            item = Path(directory, name)
            if not item.is_file():
                raise PlanError("Fichier Steam non régulier")
            result[str(item.relative_to(root))] = item.stat().st_size
    return result


def prepared_files_match(folder, expected, app_id):
    actual = checked_files(folder)
    marker = Path(folder, "steam_appid.txt")
    if "steam_appid.txt" not in expected and marker.is_file() and marker.read_text().strip() == app_id:
        actual.pop("steam_appid.txt", None)
    return actual == expected


def file_hashes(folder, files, report_progress=False):
    """Bind a verified receipt to bytes, rejecting a file changing mid-read."""
    result = {}
    processed, total, reported = 0, sum(files.values()), 0.0
    def report(force=False):
        nonlocal reported
        now = time.perf_counter()
        if report_progress and (force or now - reported >= 0.2):
            emit("validating", "Vérification", None, "Vérification des empreintes des fichiers…",
                 stages=[stage_metric("verify", done=processed, total=total, unit="bytes")])
            reported = now
    report(True)
    for relative, size in sorted(files.items()):
        path = Path(folder, relative)
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(descriptor, "rb") as handle:
            before = os.fstat(handle.fileno())
            if not stat.S_ISREG(before.st_mode) or before.st_size != size:
                raise InstallFailure("Le cache Steam a changé pendant sa vérification.", "steam_cache_changed", True)
            value = hashlib.sha256()
            for block in iter(lambda: handle.read(1024 * 1024), b""):
                value.update(block)
                processed += len(block)
                report()
            after = os.fstat(handle.fileno())
        current = path.stat(follow_symlinks=False)
        identity = lambda item: (item.st_dev, item.st_ino, item.st_size, item.st_mtime_ns, item.st_ctime_ns)
        if identity(before) != identity(after) or identity(after) != identity(current):
            raise InstallFailure("Le cache Steam a changé pendant sa vérification.", "steam_cache_changed", True)
        result[relative] = value.hexdigest()
    report(True)
    return result


def depot_checkpoint(staging, plan, account_id, depot, content, verified=None):
    """Only a fresh official completion can mint this account-bound checkpoint."""
    directory = staging / "validated-depots"
    if directory.is_symlink():
        raise PlanError("Les points de reprise utilisent un lien non pris en charge")
    directory.mkdir(exist_ok=True)
    path = directory / f'{depot["appID"]}-{depot["depotID"]}-{depot["manifestID"]}.json'
    if path.is_symlink():
        raise PlanError("Le point de reprise utilise un lien non pris en charge")
    identity = dict(schema=1, planSHA256=plan["planSHA256"], accountID=account_id,
                    depot=depot, contentRoot=str(content.absolute()), officialCompletionVerified=True)
    if verified is None:
        if not path.is_file():
            return None
        try:
            saved = json.loads(path.read_text(encoding="utf-8"))
            if any(saved.get(key) != value for key, value in identity.items()):
                return None
            if not content.is_dir():
                return None
            files = checked_files(content)
            if saved.get("files") != files or sum(files.values()) != depot["bytes"]:
                return None
            emit("validating", "Vérification", None, f"Vérification des empreintes du dépôt {depot['depotID']} conservé.",
                 code="steam_checkpoint_checking", resumePoint="steam-depot-validation", depotID=depot["depotID"])
            hashes = file_hashes(content, files, report_progress=True)
            if saved.get("fileSHA256") != hashes or checked_files(content) != files:
                return None
            return files, hashes
        except PlanError:
            raise
        except (OSError, ValueError, TypeError, AttributeError):
            return None
    files, hashes = verified
    record = dict(identity, files=files, fileSHA256=hashes)
    descriptor, temporary = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=directory)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(record, handle, indent=2)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return files, hashes


def install_depots(args, plan, steam_osx, home, login_path):
    app_id, title = args.appid, plan["name"]
    # Stable per-app ownership: resumable staging is never an installed game.
    safe_title = "".join(c for c in title if c.isalnum() or c in " -_").strip()[:120] or "Game"
    destination = Path(home, "Library/Application Support/Playmelt/Games", f"{safe_title}-{app_id}")
    final = destination / "Windows"
    if str(destination.resolve()) != str(destination.absolute()):
        raise PlanError("Le dossier de destination utilise un lien. Aucun fichier déplacé.")
    destination.mkdir(parents=True, exist_ok=True)
    staging = destination / (".steam-staging-" + plan["planSHA256"][:16])
    if staging.is_symlink():
        raise PlanError("Le dossier de préparation utilise un lien")
    staging.mkdir(exist_ok=True)
    owner = staging / "plan.json"
    for file in (owner,staging/"verified.json",staging/"Windows",destination/"playmelt-install.json",destination/".playmelt-steam-launch.json",destination/"steam_appid.txt"):
        if file.is_symlink():
            raise PlanError("La préparation utilise un lien. Aucun fichier remplacé.")
    if owner.exists() and json.loads(owner.read_text())["planSHA256"] != plan["planSHA256"]:
        raise PlanError("La préparation appartient à un autre plan. Les fichiers sont conservés.")
    owner.write_text(json.dumps(plan, indent=2), encoding="utf-8")
    verified = staging / "verified.json"
    published = final.exists() or final.is_symlink()
    if published:
        if final.is_symlink() or not verified.is_file():
            emit("failed", "Installation", None, "Une installation existe déjà. Aucun fichier remplacé ; vérifiez le dossier dans Playmelt.",
                 code="steam_existing_install_unverified", retryable=False, resumePoint="steam-existing-install-validation")
            return 1
        previous = json.loads(verified.read_text())
        # Recover only our exact complete publication, never an unrelated game.
        if (previous.get("planSHA256") != plan["planSHA256"] or previous.get("accountID") != args.accountid
                or not prepared_files_match(final, previous.get("files", {}), app_id)
                or not isinstance(previous.get("fileSHA256"), dict)):
            raise PlanError("L’installation existante doit être vérifiée. Aucun fichier remplacé.")
    deployment = staging / "Windows"
    deployment.mkdir(exist_ok=True)
    checked_files(deployment)
    for directory,_,files in os.walk(deployment):
        for filename in files:
            if Path(directory,filename).stat(follow_symlinks=False).st_nlink > 1:
                raise PlanError("La préparation contient un fichier partagé. Aucun fichier remplacé.")
    console_log = Path(home, "Library/Application Support/Steam/logs/console_log.txt")
    content_log = Path(home, "Library/Application Support/Steam/logs/content_log.txt")
    # Steam places console depot downloads alongside the active client binary.
    content_base = Path(steam_osx).parent / "steamapps/content"
    completed, receipts, expected_files, expected_hashes = 0, [], {}, {}
    prerequisites=plan.get("prerequisites",[])
    total_bytes=plan["bytes"]
    depots = [] if published else plan["depots"]
    for index, depot in enumerate(depots):
        if active_steam_account(login_path) != args.accountid:
            raise PlanError("Compte Steam changé : préparation annulée.")
        content = content_base / ("app_" + depot["appID"]) / ("depot_" + depot["depotID"])
        details = {key: depot[key] for key in ("appID", "depotID", "manifestID")}
        cached = depot_checkpoint(staging, plan, args.accountid, depot, content)
        if cached is not None:
            files, hashes = cached
            emit("validating", "Reprise", 0.02 + 0.8 * completed / max(1, total_bytes),
                 f"Dépôt {index + 1}/{len(depots)} déjà vérifié ; reprise de sa copie.",
                 code="steam_checkpoint_verified", resumePoint="steam-depot-copy", **details)
        else:
            for attempt in range(3):
                emit("downloading", "Vérification Steam", 0.02 + 0.8 * completed / max(1, total_bytes),
                 f"Steam vérifie ou récupère le dépôt {index + 1}/{len(depots)} · {title}", bytesDownloaded=completed, bytesTotal=total_bytes,
                 stages=[stage_metric("download", done=completed, total=total_bytes, unit="verified-bytes")])
                cursor = DepotLogCursor(console_log, steam_osx, depot)
                dispatch = trigger_steam_depot_download(steam_osx, depot["appID"], depot["depotID"], depot["manifestID"])
                if dispatch is False:
                    raise InstallFailure("Steam n’a pas confirmé la demande. Vérifiez sa connexion ; les fichiers sont conservés.",
                                         "steam_dispatch_failed", True, **details)
                started = time.monotonic()
                renewed = False
                while True:
                    if not cursor.backlog:
                        time.sleep(1)
                    reap_steam_handoffs()
                    if active_steam_account(login_path) != args.accountid:
                        raise PlanError("Compte Steam changé : préparation annulée.")
                    size = get_dir_size(content)
                    elapsed = time.monotonic() - started
                    emit("downloading", "Téléchargement", min(0.85, 0.02 + 0.8 * (completed + size) / max(1, total_bytes)),
                         f"{title} · dépôt {index + 1}/{len(depots)} · {format_bytes(completed + size)} / {format_bytes(total_bytes)}",
                         bytesDownloaded=completed + size, bytesTotal=total_bytes, speed="",
                         stages=[stage_metric("download", done=completed, total=total_bytes, unit="verified-bytes")])
                    if cursor.read(content):
                        renewed = True
                        break
                    if cursor.complete:
                        files = checked_files(content)
                        if sum(files.values()) != depot["bytes"]:
                            raise InstallFailure(f"Le dépôt Steam {depot['depotID']} ne correspond pas au reçu : {sum(files.values())} octets présents sur {depot['bytes']} attendus. Les fichiers sont conservés.",
                                                 "steam_depot_size_mismatch", False, expectedBytes=depot["bytes"], actualBytes=sum(files.values()), **details)
                        emit("downloading", "Réception Steam", None, "Reçu du dépôt confirmé par Steam.",
                             stages=[stage_metric("download", done=completed + depot["bytes"], total=total_bytes, unit="verified-bytes")], **details)
                        hashes = file_hashes(content, files, report_progress=True)
                        if checked_files(content) != files:
                            raise InstallFailure("Le cache Steam a changé pendant sa vérification.", "steam_cache_changed", True, **details)
                        if active_steam_account(login_path) != args.accountid:
                            raise PlanError("Compte Steam changé : préparation annulée.")
                        depot_checkpoint(staging, plan, args.accountid, depot, content, (files, hashes))
                        break
                    problem = cursor.problem
                    if problem == "denied":
                        raise InstallFailure("Steam a refusé ce dépôt. Vérifiez la licence et la connexion Steam.", "steam_depot_denied", False, **details)
                    if problem == "context-changed":
                        raise InstallFailure("Steam exécute une autre demande. Vérifiez ses téléchargements puis reprenez la préparation ; les fichiers sont conservés.", "steam_context_changed", False, **details)
                    if hasattr(dispatch, "poll") and dispatch.poll() not in (None, 0) and not cursor.backlog:
                        raise InstallFailure("Le client Steam n’a pas transmis la demande de dépôt. Les fichiers sont conservés.",
                                             "steam_dispatch_failed", True, **details)
                    if elapsed > 12 * 60 * 60 and not cursor.backlog:
                        raise InstallFailure("La vérification Steam a été interrompue. Les fichiers sont conservés pour la reprise.", "steam_download_timeout", True, **details)
                if renewed:
                    if attempt == 2:
                        raise InstallFailure("Le journal Steam se renouvelle à chaque demande. Les fichiers sont conservés.", "steam_log_renewed", False, "steam-log-restart", attempt=attempt + 1, **details)
                    emit("recovering", "Reprise", None, "Journal Steam renouvelé ; nouvelle demande de vérification du dépôt.",
                         code="steam_log_renewed", retryable=True, resumePoint="steam-log-restart", attempt=attempt + 1, **details)
                else:
                    break
        if active_steam_account(login_path) != args.accountid:
            raise PlanError("Compte Steam changé : préparation annulée.")
        emit("installing", "Installation", 0.85, f"Préparation du dépôt {index + 1}/{len(depots)}…")
        # Respect Valve mounting order. Recopy only this task's staging tree.
        staged = checked_files(deployment)
        copy_needed = any(staged.get(path) != size for path, size in files.items())
        if not copy_needed:
            copy_needed = file_hashes(deployment, files, report_progress=True) != hashes
        if copy_needed and shutil.disk_usage(destination).free < sum(files.values()):
            raise InstallFailure("Espace disque insuffisant pour préparer le dépôt vérifié. Son point de reprise est conservé.",
                                 "steam_disk_space", False, "storage", **details)
        try:
            if copy_needed:
                copied, reported = 0, 0.0
                def copy_file(source, target):
                    nonlocal copied, reported
                    result = shutil.copy2(source, target)
                    copied += Path(target).stat().st_size
                    now = time.perf_counter()
                    if now - reported >= 0.2:
                        emit("installing", "Copie", None, "Préparation des fichiers du jeu…",
                             stages=[stage_metric("prepare", done=completed + copied, total=total_bytes, unit="bytes")])
                        reported = now
                    return result
                shutil.copytree(content, deployment, dirs_exist_ok=True, symlinks=True, copy_function=copy_file)
        except OSError as exc:
            raise InstallFailure("La copie du dépôt est interrompue. Son point de reprise vérifié est conservé.",
                                 "steam_depot_copy_failed", exc.errno in (errno.EINTR, errno.EBUSY, errno.ETIMEDOUT), "steam-depot-copy", errno=exc.errno, **details) from exc
        emit("installing", "Copie", None, "Fichiers du dépôt préparés ; vérification de la copie restante.",
             stages=[stage_metric("prepare", done=completed + depot["bytes"], total=total_bytes, unit="bytes")])
        expected_files.update(files)
        expected_hashes.update(hashes)
        receipts.append(dict(depot, officialCompletionVerified=True))
        completed += depot["bytes"]
    if active_steam_account(login_path) != args.accountid:
        raise PlanError("Compte Steam changé : aucun jeu publié.")
    if published:
        expected_files,receipts,expected_hashes = previous["files"],previous["receipts"],previous["fileSHA256"]
    if not prepared_files_match(final if published else deployment, expected_files, app_id):
        raise PlanError("Les fichiers préparés ne correspondent pas à tous les dépôts Steam.")
    if file_hashes(final if published else deployment, expected_files, report_progress=True) != expected_hashes:
        raise InstallFailure("La copie préparée ne correspond pas aux empreintes des dépôts vérifiés.", "steam_depot_copy_mismatch", True, "steam-depot-copy")
    executable = (final if published else deployment) / plan["executable"]
    if not executable.is_file() or executable.is_symlink():
        raise PlanError("L’exécutable publié par Steam est absent. Aucun exécutable n’a été deviné.")
    with executable.open("rb") as handle:
        if handle.read(2) != b"MZ":
            raise PlanError("L’exécutable Windows est invalide")
    if plan["workingDirectory"] and not ((final if published else deployment) / plan["workingDirectory"]).is_dir():
        raise PlanError("Le dossier de lancement publié par Steam est absent")
    emit("validating", "Vérification", 0.95, "Dépôts du jeu vérifiés. Vérification des étapes restantes…")
    checks,issues=inspect_scripts(final if published else deployment)
    for component in prerequisites:
        issues.append(dict(kind="official-installscript", depotID=component["depotID"],
                           sourceAppID=component["sourceAppID"], manifestID=component["manifestID"],
                           acquisitionVerified=False, executionVerified=False, requiredClient="steam-windows",
                           message="Ce composant doit être acquis et finalisé par le client Steam Windows officiel."))
    detected_renderer,renderer_source=detect_renderer(expected_files,plan["arguments"],app_id)
    if renderer_source=='unknown':issues.append({'kind':'graphics-api-unknown','message':'Le moteur graphique de ce jeu doit être vérifié avant son premier lancement.'})
    steam_client_required=any(Path(p).name.lower() in ('steam_api.dll','steam_api64.dll') for p in expected_files)
    # Atomic publication; a cancelled/partial copy never becomes installed.
    receipt = dict(plan, renderer=detected_renderer,rendererRequested=args.renderer,rendererSource=renderer_source,source="official-steam-console-completion",
                   receipts=receipts, files=expected_files, fileSHA256=expected_hashes, accountID=args.accountid, gameExecutionVerified=False,
                   prerequisiteExecutionVerified=False,prerequisiteChecks=checks,preparationTasks=issues,
                   steamClientRequired=steam_client_required, requiresOfficialSteam=bool(prerequisites) or steam_client_required)
    if not published:
        verified.write_text(json.dumps(receipt, indent=2), encoding="utf-8")
        deployment.rename(final)
    # The native dispatcher generates the guarded launcher only after its fresh
    # engine, account, prerequisites and display preflight succeeds.
    (destination / "playmelt-install.json").write_text(json.dumps(receipt, indent=2), encoding="utf-8")
    launch = {k: plan[k] for k in ("appID", "executable", "arguments", "workingDirectory")}
    launch.update(schema=1,renderer=detected_renderer,source=receipt["source"],preparationTasks=issues,
                  prerequisiteChecks=checks,steamClientRequired=steam_client_required,requiresOfficialSteam=receipt["requiresOfficialSteam"],gameExecutionVerified=False)
    (destination / ".playmelt-steam-launch.json").write_text(json.dumps(launch, indent=2), encoding="utf-8")
    # Keep every publisher file byte-for-byte. The parent marker is Playmelt's
    # discovery metadata; a vendor-provided Windows/steam_appid.txt is untouched.
    (destination / "steam_appid.txt").write_text(app_id + "\n", encoding="utf-8")
    emit("files-prepared", "Fichiers préparés", 1.0, f"Fichiers de {title} préparés ; composants et premier lancement à vérifier.",
         ready=False,gamePath=str(final),scriptPath="",depotCount=len(plan["depots"]),
         renderer=detected_renderer,prerequisiteCount=len(prerequisites),steamClientRequired=steam_client_required,
         requiresOfficialSteam=receipt["requiresOfficialSteam"], preparationTasks=issues,
         stages=[stage_metric("download", "completed", total_bytes, total_bytes, "verified-bytes"),
                 stage_metric("prepare", "completed", total_bytes, total_bytes, "bytes"),
                 stage_metric("verify", "completed", sum(expected_files.values()), sum(expected_files.values()), "bytes")]
                + ([stage_metric("components", "waiting")] if prerequisites else []))

if __name__ == "__main__":
    def interrupted(signum, frame):
        # Raising unwinds subprocess.run's owned child before Python exits.
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        sys.exit(main() or 0)
    except KeyboardInterrupt:
        emit("cancelled", "Annulé", None, "Préparation annulée. Le client Steam reste indépendant.",
             code="steam_cancelled", retryable=False, resumePoint="steam-depot-validation")
        sys.exit(130)
    except Exception as exc:
        emit("failed", "Erreur", None, f"Préparation interrompue : {exc}",
             code="steam_unexpected_error", retryable=False, resumePoint="steam-depot-validation")
        sys.exit(1)
