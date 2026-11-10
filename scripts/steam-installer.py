#!/usr/bin/env python3
"""
Playmelt Native Game Installer & Depot Downloader
Automates background downloading, file deployment, Goldberg injection,
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
            best_depot = None
            max_size = 0
            download_size = 0
            
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
                    if size > max_size:
                        max_size = size
                        download_size = dl_size
                        best_depot = dep_id

            return {
                "name": name,
                "installdir": installdir,
                "depot_id": best_depot,
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

def trigger_steam_depot_download(steam_osx_path, app_id, depot_id):
    cmd = [steam_osx_path, "+download_depot", str(app_id), str(depot_id)]
    try:
        subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return True
    except Exception as e:
        return False

def get_recent_download_rate(content_log_path):
    if not os.path.exists(content_log_path):
        return None
    try:
        with open(content_log_path, "r", encoding="utf-8", errors="ignore") as f:
            lines = f.readlines()[-30:]
            for line in reversed(lines):
                m = re.search(r"Current download rate:\s*([0-9.]+)\s*Mbps", line)
                if m:
                    rate_mbps = float(m.group(1))
                    return f"{rate_mbps / 8.0:.1f} Mo/s"
    except Exception:
        pass
    return None

def create_launch_script(game_dir, chosen_exe, game_title, app_id=None):
    runtime_dir = os.path.expanduser("~/Library/Application Support/Playmelt/Runtime")
    renderer_dir = os.path.expanduser("~/Library/Application Support/Playmelt/Renderers/D3DMetal/payload")
    
    lower_exe = chosen_exe.lower()
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
    if is_unity:
        is_dx12 = False

    if is_dx12:
        extra_args = f"{proj_name} -d3d12" if proj_name else "-d3d12"
        content = f"""#!/bin/bash
# Lanceur direct Playmelt pour {game_title} (Apple Silicon / Metal / Wine / D3DMetal DX12)
set -e
GAME_DIR="{game_dir}"
RUNTIME_DIR="{runtime_dir}"
RENDERER_DIR="{renderer_dir}"

cd "$GAME_DIR"

export WINEPREFIX="$RUNTIME_DIR/prefix"
export WINEDEBUG="-all"
export WINEDLLOVERRIDES="d3d12,d3d12core,dxgi=n,b;winemenubuilder.exe=d"
export WINEDLLPATH_PREPEND="$RENDERER_DIR/wine"
export CX_D3DMETALPATH="$RENDERER_DIR/external"
export DYLD_FALLBACK_LIBRARY_PATH="$RENDERER_DIR/external:$RENDERER_DIR/external/D3DMetal.framework/Versions/A/Resources:$RUNTIME_DIR/playmelt-wine10-dxmt-20261017/frameworks:$RUNTIME_DIR/playmelt-wine10-dxmt-20261017/frameworks/GStreamer.framework/Versions/1.0/lib"
export DYLD_FALLBACK_FRAMEWORK_PATH="$RENDERER_DIR/external:$RUNTIME_DIR/playmelt-wine10-dxmt-20261017/frameworks"
export MVK_CONFIG_LOG_LEVEL=0

exec "$RUNTIME_DIR/playmelt-wine10-dxmt-20261017/engine/bin/wine" "{chosen_exe}" {extra_args} "$@" >/dev/null 2>&1
"""
    else:
        extra_args = "-force-d3d11" if is_unity else (f"{proj_name} -dx11" if proj_name else "-dx11")
        content = f"""#!/bin/bash
# Lanceur direct Playmelt pour {game_title} (Apple Silicon / Metal / Wine / DXMT)
set -e
GAME_DIR="{game_dir}"
RUNTIME_DIR="{runtime_dir}"

cd "$GAME_DIR"

export WINEPREFIX="$RUNTIME_DIR/prefix"
export WINEDEBUG="-all"
export WINEDLLOVERRIDES="d3d11,dxgi,nvapi64=n,b;winemenubuilder.exe=d"
export WINEDLLPATH_PREPEND="$RUNTIME_DIR/playmelt-wine10-dxmt-20261017/renderers/dxmt/wine"
export DYLD_FALLBACK_LIBRARY_PATH="$RUNTIME_DIR/playmelt-wine10-dxmt-20261017/frameworks:$RUNTIME_DIR/playmelt-wine10-dxmt-20261017/frameworks/GStreamer.framework/Versions/1.0/lib"
export DYLD_FALLBACK_FRAMEWORK_PATH="$RUNTIME_DIR/playmelt-wine10-dxmt-20261017/frameworks"
export MVK_CONFIG_LOG_LEVEL=0

exec "$RUNTIME_DIR/playmelt-wine10-dxmt-20261017/engine/bin/wine" "{chosen_exe}" {extra_args} "$@" >/dev/null 2>&1
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
    parser.add_argument("--depotid", default=None, help="Steam Depot ID (optional)")
    args = parser.parse_args()
    
    app_id = str(args.appid).strip()
    user_title = args.title
    forced_depot = args.depotid
    
    home = os.path.expanduser("~")
    steam_osx = os.path.join(home, "Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steam_osx")
    if not os.path.exists(steam_osx):
        steam_osx = "/Applications/Steam.app/Contents/MacOS/steam_osx"
    
    if not os.path.exists(steam_osx):
        emit("failed", "Erreur", 0.0, "Steam n'est pas installé sur ce Mac.")
        sys.exit(1)
        
    emit("downloading", "Téléchargement", 0.02, "Résolution des dépôts Steam en cours...")
    
    # 1. Resolve metadata
    info = resolve_steam_info(app_id)
    title = (info and info.get("name")) or user_title or f"Game {app_id}"
    installdir = (info and info.get("installdir")) or title.replace(" ", "")
    depot_id = forced_depot or (info and info.get("depot_id")) or f"{int(app_id) + 1}"
    expected_size = (info and info.get("size")) or 0
    expected_dl = (info and info.get("download_size")) or expected_size
    target_exe = info and info.get("executable")
    
    emit("downloading", "Téléchargement", 0.05, f"Dépôt identifié : {depot_id} ({format_bytes(expected_dl)}). Lancement du téléchargement...")
    
    # 2. Trigger download
    content_dir = os.path.join(home, f"Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steamapps/content/app_{app_id}/depot_{depot_id}")
    content_log = os.path.join(home, "Library/Application Support/Steam/logs/content_log.txt")
    
    trigger_steam_depot_download(steam_osx, app_id, depot_id)
    
    # 3. Monitor download progress
    start_time = time.time()
    last_size = 0
    unchanged_count = 0
    max_wait_seconds = 1800 # 30 mins
    
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
        
        # Check if finished: directory stabilized for 4 seconds and reached at least 95% of expected size,
        # or size is substantial (> 10MB) and stable for 6 seconds
        is_done = False
        if expected_size > 0 and cur_size >= expected_size * 0.98 and unchanged_count >= 2:
            is_done = True
        elif cur_size > 5 * 1024 * 1024 and unchanged_count >= 5:
            is_done = True
            
        if is_done:
            break
            
        if elapsed > max_wait_seconds:
            emit("failed", "Erreur", ratio, "Le téléchargement a dépassé la limite de temps.")
            sys.exit(1)
            
    # 4. Installation phase
    emit("installing", "Installation", 0.88, f"Déploiement des fichiers de {title}…")
    
    safe_folder_name = "".join(c for c in title if c.isalnum() or c in " -_").strip()
    dest_game_folder = os.path.join(home, f"Library/Application Support/Playmelt/Games/{safe_folder_name}")
    dest_win_folder = os.path.join(dest_game_folder, "Windows")
    os.makedirs(dest_win_folder, exist_ok=True)
    
    # Move files from depot content to dest_win_folder
    for item in os.listdir(content_dir):
        src_item = os.path.join(content_dir, item)
        dst_item = os.path.join(dest_win_folder, item)
        if os.path.exists(dst_item):
            if os.path.isdir(dst_item):
                shutil.rmtree(dst_item)
            else:
                os.remove(dst_item)
        shutil.move(src_item, dst_item)
        
    # Clean up empty depot dir
    try:
        shutil.rmtree(os.path.dirname(content_dir))
    except Exception:
        pass
        
    # 5. Verification & Engine setup phase
    emit("validating", "Vérification", 0.93, f"Configuration du moteur et dépendances pour {title}…")
    
    # Inject steam_appid.txt
    with open(os.path.join(dest_win_folder, "steam_appid.txt"), "w") as f:
        f.write(f"{app_id}\n")
    with open(os.path.join(dest_game_folder, "steam_appid.txt"), "w") as f:
        f.write(f"{app_id}\n")
        
    # Find Goldberg steam_api64.dll and steamclient64.dll
    emu_candidates = [
        os.path.join(home, "Library/Application Support/Playmelt/Runtime/steam_api64_emu.dll"),
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "../Resources/steam_api64.dll"),
        os.path.join(home, "Library/Application Support/Playmelt/Games/Megabonk/Windows/Megabonk_Data/Plugins/x86_64/steam_api64.dll")
    ]
    goldberg_api64 = next((c for c in emu_candidates if os.path.exists(c)), None)
    prefix_steamclient = os.path.join(home, "Library/Application Support/Playmelt/Runtime/prefix/drive_c/Program Files (x86)/Steam/steamclient64.dll")

    for root, dirs, files in os.walk(dest_win_folder):
        if "steam_api64.dll" in files:
            # Overwrite retail steam_api64.dll with Goldberg to prevent RestartAppIfNecessary exits
            if goldberg_api64:
                try:
                    target_api = os.path.join(root, "steam_api64.dll")
                    shutil.copy2(goldberg_api64, target_api)
                except Exception:
                    pass
            if os.path.exists(prefix_steamclient):
                target_dll = os.path.join(root, "steamclient64.dll")
                if not os.path.exists(target_dll):
                    try:
                        shutil.copy2(prefix_steamclient, target_dll)
                    except Exception:
                        pass
            # Also create steam_settings/steam_interfaces.txt and steam_appid.txt
            settings_dir = os.path.join(root, "steam_settings")
            os.makedirs(settings_dir, exist_ok=True)
            with open(os.path.join(settings_dir, "steam_appid.txt"), "w") as f:
                f.write(f"{app_id}\n")
            with open(os.path.join(root, "steam_appid.txt"), "w") as f:
                f.write(f"{app_id}\n")
            interfaces_file = os.path.join(settings_dir, "steam_interfaces.txt")
            if not os.path.exists(interfaces_file):
                with open(interfaces_file, "w") as f:
                    f.write("STEAMAPPS_INTERFACE_VERSION009\nSteamClient017\nSteamFriends018\nSteamUser023\nSteamUtils010\n")
                        
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
        sys.exit(1)
        
    # Create launch script
    script_path = create_launch_script(dest_win_folder, exe_chosen, title, app_id=app_id)
    # Also symlink or copy to dest_game_folder
    top_script = os.path.join(dest_game_folder, os.path.basename(script_path))
    if script_path != top_script:
        shutil.copy2(script_path, top_script)
        os.chmod(top_script, 0o755)
        
    # Create Steam symlink in steamapps/common/<installdir>
    steam_common = os.path.join(home, "Library/Application Support/Steam/steamapps/common")
    os.makedirs(steam_common, exist_ok=True)
    symlink_target = os.path.join(steam_common, installdir)
    if not os.path.exists(symlink_target):
        try:
            os.symlink(dest_win_folder, symlink_target)
        except Exception:
            pass
            
    # Write appmanifest_<app_id>.acf
    steam_apps = os.path.join(home, "Library/Application Support/Steam/steamapps")
    manifest_path = os.path.join(steam_apps, f"appmanifest_{app_id}.acf")
    manifest_content = f""""AppState"
{{
\t"appid"\t\t"{app_id}"
\t"Universe"\t\t"1"
\t"name"\t\t"{title}"
\t"StateFlags"\t\t"4"
\t"installdir"\t\t"{installdir}"
\t"LastUpdated"\t\t"{int(time.time())}"
\t"UpdateResult"\t\t"0"
\t"BytesDownloaded"\t\t"{cur_size}"
\t"BytesToDownload"\t\t"{cur_size}"
\t"BytesToStage"\t\t"{cur_size}"
\t"BytesStaged"\t\t"{cur_size}"
\t"buildid"\t\t"1000000"
}}
"""
    try:
        with open(manifest_path, "w", encoding="utf-8") as f:
            f.write(manifest_content)
    except Exception:
        pass
        
    emit(
        "launch-ready",
        "Terminé",
        1.0,
        f"{title} est installé et prêt à jouer !",
        ready=True,
        gamePath=dest_win_folder,
        scriptPath=top_script
    )

if __name__ == "__main__":
    main()
