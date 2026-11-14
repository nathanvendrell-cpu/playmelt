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
import urllib.request
import subprocess
import shutil
import re
import shlex
import signal
from pathlib import Path

def emit(status, phase, percent, message, **kwargs):
    payload = {
        "status": status,
        "phase": phase,
        "percent": round(float(percent), 3) if percent is not None else None,
        "message": message
    }
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
    url = f"https://api.steamcmd.net/v1/info/{app_id}"
    req = urllib.request.Request(url, headers={"User-Agent": "Playmelt/2.0"})
    try:
        with urllib.request.urlopen(req, timeout=8) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            app_data = data.get("data", {}).get(str(app_id), {})
            if not app_data:
                return None
            
            common = app_data.get("common", {})
            name = common.get("name", f"App {app_id}")
            config = app_data.get("config", {})
            installdir = config.get("installdir", name.replace(" ", ""))
            
            # Find executable in launch options
            launch_exe = None
            launch_opts = config.get("launch", {})
            for key, opt in launch_opts.items():
                if isinstance(opt, dict):
                    oslist = opt.get("config", {}).get("oslist", "")
                    exe = opt.get("executable", "")
                    if "windows" in oslist or not oslist:
                        if exe.lower().endswith(".exe"):
                            launch_exe = exe
                            break

            # Find best Windows depot
            depots = app_data.get("depots", {})
            candidates = []
            
            for dep_id, dep_info in depots.items():
                if not isinstance(dep_info, dict) or not dep_id.isdigit():
                    continue
                # Skip shared redists
                if "depotfromapp" in dep_info:
                    continue
                
                oslist = dep_info.get("config", {}).get("oslist", "")
                manifests = dep_info.get("manifests", {}).get("public", {})
                size = int(manifests.get("size", 0) or 0)
                dl_size = int(manifests.get("download", 0) or 0)
                
                if "windows" in oslist or not oslist:
                    gid = str(manifests.get("gid", ""))
                    if size > 0 and gid.isdigit():
                        candidates.append((dep_id, size, dl_size, gid))
            # A largest-depot guess can silently omit required assets/languages.
            # Until complete multi-depot plans are supported, refuse ambiguity.
            if len(candidates) != 1:
                return None
            best_depot, max_size, download_size, manifest_id = candidates[0]

            return {
                "name": name,
                "installdir": installdir,
                "depot_id": best_depot,
                "manifest_id": manifest_id,
                "build_id": str(depots.get("branches", {}).get("public", {}).get("buildid", "")),
                "size": max_size,
                "download_size": download_size,
                "executable": launch_exe
            }
    except Exception as e:
        return None

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


def trigger_steam_depot_download(steam_osx_path, app_id, depot_id, manifest_id):
    cmd = [steam_osx_path, "+download_depot", str(app_id), str(depot_id), str(manifest_id)]
    try:
        subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30, check=True)
        return True
    except (OSError, subprocess.SubprocessError):
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

def create_launch_script(game_dir, chosen_exe, game_title, app_id=None, renderer=None):
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
    script_path = os.path.join(game_dir, f"Lancer-{safe_title}.command")
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
        emit("failed", "Compte", None, "Le compte actif Steam ne correspond plus au compte sélectionné.")
        return 1
    steam_osx = os.path.join(home, "Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steam_osx")
    if not os.path.exists(steam_osx):
        steam_osx = "/Applications/Steam.app/Contents/MacOS/steam_osx"
    
    if not os.path.exists(steam_osx):
        emit("failed", "Erreur", 0.0, "Steam n'est pas installé sur ce Mac.")
        return 1
        
    emit("downloading", "Téléchargement", 0.02, "Résolution des dépôts Steam en cours...")
    
    # 1. Resolve metadata
    info = resolve_steam_info(app_id)
    if not info:
        emit("failed", "Dépôts", None, "Plan de dépôts Windows incomplet ou ambigu. Utilisez Steam pour cette installation.")
        return 1
    title = info["name"]
    installdir = (info and info.get("installdir")) or title.replace(" ", "")
    depot_id = info["depot_id"]
    manifest_id = info["manifest_id"]
    expected_size = (info and info.get("size")) or 0
    expected_dl = (info and info.get("download_size")) or expected_size
    target_exe = info and info.get("executable")
    
    emit("downloading", "Téléchargement", 0.05, f"Dépôt identifié : {depot_id} ({format_bytes(expected_dl)}). Lancement du téléchargement...")
    
    # 2. Trigger download
    content_dir = os.path.join(home, f"Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steamapps/content/app_{app_id}/depot_{depot_id}")
    content_log = os.path.join(home, "Library/Application Support/Steam/logs/content_log.txt")
    
    console_log = os.path.join(home, "Library/Application Support/Steam/logs/console_log.txt")
    log_offset = os.path.getsize(console_log) if os.path.exists(console_log) else 0
    if not trigger_steam_depot_download(steam_osx, app_id, depot_id, manifest_id):
        emit("failed", "Téléchargement", None, "Steam n’a pas accepté la demande de téléchargement.")
        return 1
    
    # 3. Monitor download progress
    start_time = time.time()
    last_size = 0
    unchanged_count = 0
    max_wait_seconds = 12 * 60 * 60
    
    while True:
        time.sleep(1.0)
        now = time.time()
        elapsed = now - start_time
        
        cur_size = get_dir_size(content_dir)
        rate_str = get_recent_download_rate(content_log)
        
        # Calculate ratio
        if expected_size > 0:
            ratio = min(0.85, (cur_size / float(expected_size)) * 0.85)
        else:
            ratio = 0.30 if cur_size > 0 else 0.05
            
        rate_info = f" · {rate_str}" if rate_str else ""
        size_info = f" · {format_bytes(cur_size)} / {format_bytes(expected_size)}" if expected_size > 0 else f" · {format_bytes(cur_size)}"
        
        emit(
            "downloading",
            "Téléchargement",
            ratio,
            f"Téléchargement de {title}{rate_info}{size_info}",
            bytesDownloaded=cur_size,
            bytesTotal=expected_size,
            speed=rate_str or ""
        )
        
        if cur_size > 0 and cur_size == last_size:
            unchanged_count += 1
        else:
            unchanged_count = 0
            
        last_size = cur_size
        
        # Only a new official Steam receipt for this exact pinned manifest can
        # complete the download. Stalls and byte percentages are never receipts.
        recent_console = ""
        try:
            with open(console_log, "rb") as handle:
                handle.seek(max(log_offset, os.path.getsize(console_log) - 1_048_576))
                recent_console = handle.read(1_048_576).decode("utf-8", "replace")
        except OSError:
            pass
        if official_completion(recent_console, content_dir, manifest_id):
            if expected_size <= 0 or cur_size != expected_size:
                emit("failed", "Vérification", None, "Le reçu Steam et la taille du dépôt ne concordent pas. Les fichiers sont conservés.")
                return 1
            break
        if active_steam_account(login_path) != args.accountid:
            emit("failed", "Compte", None, "Compte Steam changé : préparation annulée.")
            return 1

        if elapsed > max_wait_seconds:
            emit("failed", "Erreur", ratio, "Le téléchargement a dépassé la limite de temps.")
            return 1
            
    # 4. Deploy only after official completion; never replace an existing game.
    emit("installing", "Installation", 0.88, f"Déploiement des fichiers de {title}…")
    safe_folder_name = "".join(c for c in title if c.isalnum() or c in " -_").strip() or "Game"
    dest_game_folder = os.path.join(home, "Library/Application Support/Playmelt/Games", f"{safe_folder_name}-{app_id}")
    dest_win_folder = os.path.join(dest_game_folder, "Windows")
    if os.path.realpath(dest_game_folder) != os.path.abspath(dest_game_folder):
        emit("failed", "Installation", None, "Le dossier de destination utilise un lien. Aucun fichier déplacé.")
        return 1
    if os.path.lexists(dest_win_folder):
        emit("failed", "Installation", None, "Une installation existe déjà. Aucun fichier remplacé ; vérifiez le dossier dans Playmelt.")
        return 1
    if active_steam_account(login_path) != args.accountid:
        emit("failed", "Compte", None, "Compte Steam changé : aucun fichier déplacé.")
        return 1
    os.makedirs(dest_game_folder, exist_ok=True)
    shutil.move(content_dir, dest_win_folder)
    emit("validating", "Vérification", 0.93, f"Préparation du lanceur pour {title}…")
    # Detect best executable
    exe_chosen = target_exe
    if not exe_chosen or not os.path.exists(os.path.join(dest_win_folder, exe_chosen)):
        candidates = []
        for root, dirs, files in os.walk(dest_win_folder):
            for file in files:
                if file.lower().endswith(".exe"):
                    rel = os.path.relpath(os.path.join(root, file), dest_win_folder)
                    low = rel.lower()
                    if not any(k in low for k in ["crash", "sentry", "redist", "setup", "install", "vcredist"]):
                        candidates.append(rel)
        if candidates:
            shipping = [c for c in candidates if "-shipping.exe" in c.lower()]
            exe_chosen = shipping[0] if shipping else sorted(candidates, key=len)[0]
            
    if not exe_chosen:
        emit("failed", "Erreur", 0.95, "Aucun exécutable Windows trouvé dans le dossier du jeu.")
        return 1
        
    target_path = os.path.realpath(os.path.join(dest_win_folder, exe_chosen))
    if os.path.isabs(exe_chosen) or not target_path.startswith(os.path.realpath(dest_win_folder) + os.sep):
        raise ValueError("L’exécutable sort du dossier du jeu")
    with open(target_path, "rb") as handle:
        if handle.read(2) != b"MZ":
            raise ValueError("L’exécutable Windows est invalide")

    # Create launch script
    script_path = create_launch_script(dest_win_folder, exe_chosen, title, app_id=app_id, renderer=args.renderer)
    # Also symlink or copy to dest_game_folder
    top_script = os.path.join(dest_game_folder, os.path.basename(script_path))
    if script_path != top_script:
        shutil.copy2(script_path, top_script)
        os.chmod(top_script, 0o755)
        
    # This receipt is owned by Playmelt. Never fabricate Steam StateFlags/buildid.
    receipt = {"appID": app_id, "depotID": depot_id, "manifestID": manifest_id,
               "buildID": info["build_id"], "bytes": cur_size,
               "source": "official-steam-console-completion", "gameExecutionVerified": False}
    Path(dest_game_folder, "playmelt-install.json").write_text(json.dumps(receipt, indent=2), encoding="utf-8")
    # Publish discovery identity only after successful verification and launcher
    # creation. An interrupted deployment must not appear complete in the hub.
    for directory in (dest_win_folder, dest_game_folder):
        Path(directory, "steam_appid.txt").write_text(f"{app_id}\n", encoding="utf-8")

    emit(
        "launch-ready",
        "Terminé",
        1.0,
        f"Fichiers de {title} préparés ; lancement à vérifier.",
        ready=True,
        gamePath=dest_win_folder,
        scriptPath=top_script
    )

if __name__ == "__main__":
    def interrupted(signum, frame):
        # Raising unwinds subprocess.run's owned child before Python exits.
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        sys.exit(main() or 0)
    except KeyboardInterrupt:
        emit("cancelled", "Annulé", None, "Préparation annulée. Le client Steam reste indépendant.")
        sys.exit(130)
    except Exception as exc:
        emit("failed", "Erreur", None, f"Préparation interrompue : {exc}")
        sys.exit(1)
