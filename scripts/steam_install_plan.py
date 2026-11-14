"""Deterministic public-branch, Windows depot plans from Valve app metadata."""
import hashlib
import json
import re


class PlanError(ValueError):
    pass


def safe_relative(value, allow_empty=False):
    value = str(value or "").replace("\\", "/").removeprefix("./").rstrip("/")
    if allow_empty and value in ("", "."):
        return ""
    if not value or value.startswith("/") or ":" in value or any(ord(c) < 32 for c in value) or any(c in ("", "..") for c in value.split("/")):
        raise PlanError("Chemin de lancement Steam non pris en charge")
    return value


def windows_arguments(text):
    # CommandLineToArgvW quote/backslash rules, then shell-quote each resulting
    # argument at script generation. Publisher arguments are never shell code.
    if not isinstance(text, str) or len(text) > 8192 or any(ord(c) < 32 for c in text) or "%" in text:
        raise PlanError("Arguments Steam non pris en charge")
    result, current, quoted, started, i = [], [], False, False, 0
    while i < len(text):
        if text[i].isspace() and not quoted:
            if started:
                result.append("".join(current)); current, started = [], False
            i += 1; continue
        slashes = 0
        while i < len(text) and text[i] == "\\":
            slashes += 1; i += 1
        if i < len(text) and text[i] == '"':
            current.extend("\\" * (slashes // 2))
            if slashes % 2:
                current.append('"')
            else:
                quoted = not quoted
            started = True; i += 1
        else:
            current.extend("\\" * slashes)
            if i < len(text):
                current.append(text[i]); started = True; i += 1
    if quoted:
        raise PlanError("Guillemets incomplets dans les arguments Steam")
    if started:
        result.append("".join(current))
    return result


def build_plan(app_id, apps, language="french"):
    app_id = str(app_id)
    app = apps.get(app_id)
    if not isinstance(app, dict):
        raise PlanError("Métadonnées Steam absentes. Actualisez la bibliothèque dans Steam.")
    launch = []
    for key, option in app.get("config", {}).get("launch", {}).items():
        if not isinstance(option, dict):
            continue
        config = {k.lower(): v for k, v in option.get("config", {}).items()}
        oslist = str(config.get("oslist", "")).split(",")
        if config.get("betakey", "default") != "default" or config.get("ownsdlc") or config.get("realm", "steamglobal") != "steamglobal" or (oslist != [""] and "windows" not in oslist):
            continue
        executable = str(option.get("executable", ""))
        if not executable.lower().endswith(".exe") or option.get("type", "default") in ("server", "editor"):
            continue
        launch.append((option.get("type", "default") != "default", int(key) if key.isdigit() else 99999, option))
    if not launch:
        raise PlanError("Aucun lancement Windows publié pour ce jeu. Vérifiez sa fiche Steam.")
    option = sorted(launch, key=lambda x: x[:2])[0][2]
    executable = safe_relative(option["executable"])
    working = str(option.get("workingdir", ""))
    if working.startswith("%INSTALLDIR%"):
        working = working[len("%INSTALLDIR%"):].lstrip("/\\")
    # Some Steam publishers write '\\bin' for an entry point in bin/. Accept
    # only that exact parent directory, anchored under this game's root.
    if working.startswith("\\") and not working.startswith("\\\\") and working[1:].replace("\\", "/").rstrip("/") == executable.rpartition("/")[0]:
        working = working[1:]
    working = safe_relative(working, allow_empty=True)
    if "%" in working:
        raise PlanError("Dossier de lancement Steam non pris en charge")
    arguments = windows_arguments(option.get("arguments", ""))
    candidates = []
    for depot_id, row in app.get("depots", {}).items():
        if not depot_id.isdigit() or not isinstance(row, dict):
            continue
        source_app = str(row.get("depotfromapp", app_id))
        master = row if source_app == app_id else apps.get(source_app, {}).get("depots", {}).get(depot_id)
        if not isinstance(master, dict):
            raise PlanError("Métadonnées d’un dépôt partagé manquantes. Actualisez Steam.")
        # Valve shared depots inherit the master's language, OS, architecture
        # and DLC properties; the dependent app may omit those fields entirely.
        config = {**row.get("config", {}), **master.get("config", {})}
        if config.get("oslist") and "windows" not in str(config["oslist"]).split(","):
            continue
        # Base edition only. DLC ownership, optional installs and activation are
        # left to Steam; never infer a licence from a public manifest.
        if row.get("dlcappid") or master.get("dlcappid") or config.get("dlcappid") or row.get("optional") == "1" or master.get("optional") == "1":
            continue
        if config.get("lowviolence") == "1" or config.get("realm", "steamglobal") != "steamglobal":
            continue
        if not row.get("depotfromapp") and "public" not in row.get("manifests", {}):
            # Unused/retired or private-branch depots are not mounted by Steam.
            continue
        candidates.append((depot_id, row, config))
    game_candidates = [(depot_id, row, config) for depot_id, row, config in candidates
                       if str(row.get("depotfromapp", app_id)) != "228980"]
    arches = {str(c.get("osarch")) for _, _, c in game_candidates if c.get("osarch")}
    chosen_arch = "64" if "64" in arches else "32"
    languages = {str(c.get("language")) for _, _, c in game_candidates
                 if c.get("language") and (not c.get("osarch") or str(c["osarch"]) == chosen_arch)}
    chosen_language = language if language in languages else "english" if "english" in languages else language
    depots, prerequisites = [], []
    for depot_id, row, config in candidates:
        source_app = str(row.get("depotfromapp", app_id))
        # CommonRedist can require both x86 and x64 on a 64-bit system.
        # Preserve every referenced Windows component for the official client.
        if source_app != "228980" and config.get("language") and config["language"] != chosen_language:
            continue
        if source_app != "228980" and config.get("osarch") and str(config["osarch"]) != chosen_arch:
            continue
        source = row
        if source_app != app_id and "public" not in row.get("manifests", {}):
            source = apps.get(source_app, {}).get("depots", {}).get(depot_id)
            if not isinstance(source, dict):
                raise PlanError("Métadonnées d’un dépôt partagé manquantes. Actualisez Steam.")
        manifest = source.get("manifests", {}).get("public", {})
        if not isinstance(manifest, dict):
            raise PlanError("Manifeste public Steam incomplet. Actualisez Steam.")
        gid, size = str(manifest.get("gid", "")), str(manifest.get("size", ""))
        if not re.fullmatch(r"[1-9][0-9]{0,19}", gid) or not size.isdigit():
            raise PlanError("Manifeste public Steam incomplet. Actualisez Steam.")
        depot = {"appID": source_app if source_app == "228980" else app_id, "sourceAppID": source_app, "depotID": depot_id, "manifestID": gid,
                 "bytes": int(size), "downloadBytes": int(manifest.get("download", size))}
        (prerequisites if source_app == "228980" else depots).append(depot)
    if not depots:
        raise PlanError("Aucun dépôt Windows pour cette édition du jeu.")
    plan = {"schema": 2, "appID": app_id, "name": app.get("common", {}).get("name", "Steam " + app_id),
            "officialInstallDirectory":app.get("config",{}).get("installdir",""),
            "executable": executable, "arguments": arguments, "workingDirectory": working,
            "language": chosen_language, "depots": depots, "prerequisites": prerequisites,
            "buildID": str(app.get("depots", {}).get("branches", {}).get("public", {}).get("buildid", "")),
            "bytes": sum(d["bytes"] for d in depots),
            "downloadBytes": sum(d["downloadBytes"] for d in depots)}
    plan["planSHA256"] = hashlib.sha256(json.dumps(plan, sort_keys=True).encode()).hexdigest()
    return plan
