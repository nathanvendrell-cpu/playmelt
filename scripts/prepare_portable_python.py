#!/usr/bin/env python3
"""Build-time, locked/offline-installed Python for the macOS arm64 client.

Normal mode prepares an absent dependency. --check only reads and runs isolated
diagnostics; it never downloads, installs, repairs or writes bytecode.
"""
from __future__ import annotations

import sys
sys.dont_write_bytecode = True

import argparse
import base64
import csv
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shlex
import shutil
import signal
import stat
import subprocess
import tarfile
import tempfile
import time
import urllib.parse
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parent.parent
LOCK = ROOT / "config/python-runtime-lock.json"
OUTPUT = ROOT / "Dependencies.noindex/client-python"
PRODUCTS = ROOT / "Products.noindex"
RECEIPT = "PLAYMELT_RUNTIME.json"
CHILDREN: list[subprocess.Popen] = []
ALLOWED_DOWNLOAD_HOSTS = {"github.com", "api.github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com", "files.pythonhosted.org", "www.python.org", "python.org"}


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def run(arguments, *, env=None, data=None, timeout=60, limit=1024 * 1024):
    process = subprocess.Popen([str(x) for x in arguments], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               env=env, start_new_session=True)
    CHILDREN.append(process)
    try:
        stdout, stderr = process.communicate(data, timeout=timeout)
        if len(stdout) > limit or len(stderr) > limit:
            raise RuntimeError("Bounded command output exceeded")
        if process.returncode:
            raise RuntimeError(f"{Path(arguments[0]).name} failed ({process.returncode}): " + stderr.decode(errors="replace")[-1200:])
        return stdout
    finally:
        stop(process)


def stop(process):
    if process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.communicate(timeout=3)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate(timeout=3)
    else:
        process.wait()


def validate_lock(lock):
    if lock.get("schemaVersion") != 1 or lock.get("target") != {
        "os": "macos", "architecture": "arm64", "python": "3.13.18",
        "pythonMajorMinor": "3.13", "release": "20261110",
    }:
        raise RuntimeError("Unsupported runtime lock target")
    names = set()
    for package in lock["packages"]:
        if package["name"] in names or not re.fullmatch(r"[a-z0-9-]+", package["name"]):
            raise RuntimeError("Invalid or duplicate package lock")
        names.add(package["name"])
    for artifact in artifacts(lock):
        parsed = urllib.parse.urlsplit(artifact["url"])
        if parsed.scheme != "https" or parsed.hostname not in ALLOWED_DOWNLOAD_HOSTS or parsed.username or parsed.password:
            raise RuntimeError("Non-official artifact URL")
        if Path(artifact["filename"]).name != artifact["filename"] or not re.fullmatch(r"[a-f0-9]{64}", artifact["sha256"]):
            raise RuntimeError("Invalid artifact identity")
        if type(artifact["size"]) is not int or artifact["size"] <= 0:
            raise RuntimeError("Invalid artifact size")


def artifacts(lock):
    return [lock["python"], lock["pythonBuildMetadata"]] + lock["componentSources"] + [item for package in lock["packages"] for item in (package["wheel"], package["source"])]


def stockage(lock):
    found = run(["ssh", "-o", "BatchMode=yes", "mbp2014",
                 "findmnt -T /srv/partage/03_PROJECT/1_APP/Playmelt -n -o UUID"], timeout=10).decode().strip()
    if found != lock["stockageUUID"]:
        raise RuntimeError("Canonical STOCKAGE mount not verified")


class OfficialRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        parsed = urllib.parse.urlsplit(newurl)
        if parsed.scheme != "https" or parsed.hostname not in ALLOWED_DOWNLOAD_HOSTS or parsed.username or parsed.password:
            raise RuntimeError("Non-official artifact redirect refused")
        return super().redirect_request(request, fp, code, message, headers, newurl)


def cached(artifact, cache, lock):
    target = cache / artifact["filename"]
    if target.exists() or target.is_symlink():
        if target.is_symlink() or not target.is_file() or target.stat().st_size != artifact["size"] or digest(target) != artifact["sha256"]:
            raise RuntimeError("Existing cache artifact failed verification: " + target.name)
        return target
    stockage(lock)
    partial = cache / ("." + target.name + ".partial-" + uuid.uuid4().hex)
    checksum, size, deadline = hashlib.sha256(), 0, time.monotonic() + 180
    try:
        opener = urllib.request.build_opener(OfficialRedirect())
        with opener.open(urllib.request.Request(artifact["url"], headers={"User-Agent": "Playmelt-runtime-build"}), timeout=30) as response, partial.open("xb") as output:
            while block := response.read(1024 * 1024):
                size += len(block)
                if size > artifact["size"] or time.monotonic() > deadline:
                    raise RuntimeError("Artifact size/time limit exceeded")
                checksum.update(block)
                output.write(block)
        if size != artifact["size"] or checksum.hexdigest() != artifact["sha256"]:
            raise RuntimeError("Official artifact digest mismatch: " + target.name)
        os.replace(partial, target)
    finally:
        partial.unlink(missing_ok=True)
    return target


def safe_extract(archive, directory):
    """Create only in-root ordinary files/directories and internal links.

    Files are extracted before links, so no member can redirect a later write.
    Hardlinks, devices, FIFOs, absolute/traversing and duplicate paths fail closed.
    """
    directory = directory.resolve()
    with tarfile.open(archive, "r:gz") as tar:
        members, seen = tar.getmembers(), set()
        link_targets = {PurePosixPath(item.name): PurePosixPath(item.linkname) for item in members if item.issym()}
        links = set(link_targets)
        for member in members:
            path = PurePosixPath(member.name)
            if path.is_absolute() or ".." in path.parts or not path.parts or path.parts[0] != "python" or "\\" in member.name:
                raise RuntimeError("Unsafe archive path")
            if path in seen:
                raise RuntimeError("Duplicate archive path")
            if any(parent in links for parent in path.parents):
                raise RuntimeError("Archive path descends through a symlink")
            seen.add(path)
            if not (member.isdir() or member.isfile() or member.issym()):
                raise RuntimeError("Archive member type refused")
            if member.issym():
                link = PurePosixPath(member.linkname)
                resolved = (directory / member.name).parent.joinpath(member.linkname).resolve()
                if link.is_absolute() or "\\" in member.linkname or not resolved.is_relative_to(directory / "python"):
                    raise RuntimeError("Outgoing archive link refused")
        def resolve_link(parts, active=frozenset()):
            result = []
            for part in parts:
                if part in ("", "."):
                    continue
                if part == "..":
                    if len(result) <= 1:
                        raise RuntimeError("Archive link graph escapes root")
                    result.pop()
                    continue
                result.append(part)
                candidate = PurePosixPath(*result)
                if candidate in link_targets:
                    if candidate in active:
                        raise RuntimeError("Archive link cycle refused")
                    result = resolve_link(result[:-1] + list(link_targets[candidate].parts), active | {candidate})
            if not result or result[0] != "python":
                raise RuntimeError("Archive link graph escapes root")
            return result
        for link in links:
            resolve_link(link.parts)
        for member in members:
            if member.issym():
                continue
            target = directory / member.name
            target.parent.mkdir(parents=True, exist_ok=True)
            if member.isdir():
                target.mkdir(exist_ok=True)
            else:
                with tar.extractfile(member) as source, target.open("xb") as output:
                    shutil.copyfileobj(source, output)
                target.chmod(member.mode & 0o777 & ~0o6000)
        for member in members:
            if member.issym():
                target = directory / member.name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.symlink_to(member.linkname)
        for member in members:
            if member.issym() and not (directory / member.name).resolve().is_relative_to(directory / "python"):
                raise RuntimeError("Archive link chain escapes root")


def environment(runtime):
    return {"PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "HOME": "/dev/null",
            "LEGENDARY_CONFIG_PATH": "/dev/null/playmelt-no-credentials",
            "XDG_CONFIG_HOME": "/dev/null/playmelt-no-credentials",
            "SSL_CERT_FILE": str(runtime / "lib/python3.13/site-packages/certifi/cacert.pem")}


def python(runtime, code, *, timeout=30):
    return run([runtime / "bin/python3", "-I", "-B", "-c", code], env=environment(runtime), timeout=timeout)


def inventory(runtime):
    result = {}
    for path in sorted(runtime.rglob("*")):
        name = path.relative_to(runtime).as_posix()
        if name == RECEIPT or path.is_dir() and not path.is_symlink():
            continue
        if path.is_symlink():
            if not path.resolve().is_relative_to(runtime.resolve()):
                raise RuntimeError("Runtime symlink escapes root")
            result[name] = {"link": os.readlink(path)}
        elif path.is_file():
            result[name] = {"sha256": digest(path), "mode": stat.S_IMODE(path.stat().st_mode)}
        else:
            raise RuntimeError("Unsupported runtime object")
    return result


def console_wrappers(runtime):
    entries = json.loads(python(runtime, "import importlib.metadata,json;print(json.dumps([(e.name,e.module,e.attr) for d in importlib.metadata.distributions() for e in d.entry_points if e.group=='console_scripts']))"))
    for name, module, attribute in entries:
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", name) or name.startswith("python"):
            raise RuntimeError("Unsafe console entrypoint name")
        if not re.fullmatch(r"[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*", module) or not re.fullmatch(r"[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*", attribute or ""):
            raise RuntimeError("Unsafe console entrypoint module")
        if name == "legendary":
            command = '-m legendary.cli "$@"'
        else:
            code = f"import importlib,sys;sys.argv[0]={name!r};f=importlib.import_module({module!r});" + ";".join(f"f=getattr(f,{part!r})" for part in attribute.split(".")) + ";sys.exit(f())"
            command = "-c " + shlex.quote(code) + ' "$@"'
        path = runtime / "bin" / name
        path.write_text('#!/bin/sh\nset -eu\nSCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)\nexport SSL_CERT_FILE="$SCRIPT_DIR/../lib/python3.13/site-packages/certifi/cacert.pem"\nexec "$SCRIPT_DIR/python3" -I -B ' + command + "\n")
        path.chmod(0o755)
    # Update wheel RECORD checksums after replacing absolute staging shebangs.
    for record in (runtime / "lib/python3.13/site-packages").glob("*.dist-info/RECORD"):
        rows = list(csv.reader(io.StringIO(record.read_text())))
        for row in rows:
            target = record.parent.parent / row[0]
            if row[0].startswith("../../../bin/") and target.is_file():
                data = target.read_bytes(); row[1] = "sha256=" + base64.urlsafe_b64encode(hashlib.sha256(data).digest()).decode().rstrip("="); row[2] = str(len(data))
        stream = io.StringIO(); csv.writer(stream, lineterminator="\n").writerows(rows); record.write_text(stream.getvalue())


def legal_material(runtime, cache, lock):
    legal = runtime / "share/playmelt-runtime"
    (legal / "sources").mkdir(parents=True)
    (legal / "licenses/python-build-standalone").mkdir(parents=True)
    archive = cache / lock["pythonBuildMetadata"]["filename"]
    selected = run(["/usr/bin/tar", "-cf", "-", "--include", "python/licenses/*", "--include", "python/PYTHON.json", "@" + str(archive)], timeout=30)
    with tarfile.open(fileobj=io.BytesIO(selected)) as tar:
        for member in tar.getmembers():
            if not member.isfile():
                raise RuntimeError("Unexpected metadata member")
            if member.name == "python/PYTHON.json":
                path = legal / "python-build-standalone.json"
            elif re.fullmatch(r"python/licenses/[A-Za-z0-9._-]+", member.name):
                path = legal / "licenses/python-build-standalone" / Path(member.name).name
            else:
                raise RuntimeError("Unexpected metadata path")
            path.write_bytes(tar.extractfile(member).read())
    for package in lock["packages"]:
        shutil.copy2(cache / package["source"]["filename"], legal / "sources" / package["source"]["filename"])
    openssl = next(item for item in lock["componentSources"] if item["name"] == "openssl")
    with tarfile.open(cache / openssl["filename"], "r:gz") as tar:
        prefix = "openssl-" + openssl["version"] + "/"
        license_text = tar.extractfile(prefix + "LICENSE.txt").read()
        (legal / "licenses/python-build-standalone/LICENSE.openssl-source.txt").write_bytes(license_text)
        # Preserve an upstream NOTICE only when the exact source provides one.
        if prefix + "NOTICE" in tar.getnames():
            (legal / "licenses/python-build-standalone/NOTICE.openssl.txt").write_bytes(tar.extractfile(prefix + "NOTICE").read())
    shutil.copy2(LOCK, legal / "python-runtime-lock.json")
    shutil.copy2(ROOT / "Resources/ThirdPartyLicenses/PortablePython/NOTICE.txt", legal / "NOTICE.txt")


def check(runtime, lock, *, verify_receipt=True):
    if runtime.is_symlink() or not (runtime / "bin/python3").is_file() or not (runtime / "bin/legendary").is_file():
        raise RuntimeError("Portable runtime layout missing")
    if verify_receipt:
        receipt = json.loads((runtime / RECEIPT).read_text())
        if receipt["lockSHA256"] != digest(LOCK) or receipt["inventory"] != inventory(runtime):
            raise RuntimeError("Runtime inventory/lock changed")
    for path in (runtime / "bin").iterdir():
        if path.is_file() and not path.is_symlink():
            first = path.open("rb").read(256)
            if first.startswith(b"#!") and (b"/opt/homebrew" in first or b"/Users/" in first or b".noindex" in first or b"/private/tmp" in first):
                raise RuntimeError("Non-relocatable console shebang")
    code = """import sys,platform,json,importlib.metadata,ssl,certifi,requests,urllib3,charset_normalizer,filelock,idna,legendary,legendary.core
from Cryptodome.Cipher import AES
assert AES.new(b'0'*16,AES.MODE_ECB).encrypt(b'0'*16)
print(json.dumps({'python':platform.python_version(),'machine':platform.machine(),'prefix':sys.prefix,'executable':sys.executable,'versions':{n:importlib.metadata.version(n) for n in ['legendary-gl','certifi','charset-normalizer','filelock','idna','pycryptodomex','requests','urllib3']},'openssl':ssl.OPENSSL_VERSION,'certifi':certifi.where()}))"""
    result = json.loads(python(runtime, code))
    if result["python"] != lock["target"]["python"] or result["machine"] != "arm64" or Path(result["prefix"]).resolve() != runtime.resolve():
        raise RuntimeError("Wrong interpreter or non-relocated prefix")
    if result["versions"] != {p["name"]: p["version"] for p in lock["packages"]} or not Path(result["certifi"]).resolve().is_relative_to(runtime.resolve()):
        raise RuntimeError("Locked package versions/CA bundle mismatch")
    openssl = next(item for item in lock["componentSources"] if item["name"] == "openssl")
    if not result["openssl"].startswith("OpenSSL " + openssl["version"] + " "):
        raise RuntimeError("OpenSSL binary/source version mismatch")
    for option in ("--version", "--help"):
        text = run([runtime / "bin/legendary", option], env=environment(runtime), timeout=20).decode()
        if "0.21.1" not in text:
            raise RuntimeError("Legendary CLI entrypoint failed")
    status = json.loads(run([runtime / "bin/python3", "-I", "-B", ROOT / "scripts/epic-worker.py"], env=environment(runtime), data=b'{"action":"status"}', timeout=20))
    if status.get("ok") is not True or status.get("version") != "0.21.1":
        raise RuntimeError("No-secret Epic worker status failed")
    return {"python": result["python"], "machine": result["machine"], "versions": result["versions"], "openssl": result["openssl"], "workerStatus": status, "legendaryCLI": "version/help passed"}


def qualify_copy(runtime, lock):
    with tempfile.TemporaryDirectory(prefix="Python Relocation With Spaces-", dir=PRODUCTS) as temporary:
        copied = Path(temporary) / "Runtime Python Copy"
        shutil.copytree(runtime, copied, symlinks=True)
        result = check(copied, lock)
        tls = """import ssl,certifi,urllib.request,json,requests
context=ssl.create_default_context(cafile=certifi.where())
opener=urllib.request.build_opener(urllib.request.ProxyHandler({}),urllib.request.HTTPSHandler(context=context))
url='https://pypi.org/pypi/legendary-gl/0.21.1/json'
with opener.open(url,timeout=20) as response:
 assert response.status==200
 assert json.loads(response.read(300000))['info']['version']=='0.21.1'
s=requests.Session();s.trust_env=False
with s.get(url,verify=certifi.where(),timeout=20) as response:
 assert response.status_code==200
print(json.dumps({'urllibTLS':True,'requestsTLS':True,'caSource':'bundled certifi'}))"""
        result["tls"] = json.loads(python(copied, tls, timeout=50))
        result["relocatedPathContainedSpaces"] = True
        return result


def prepare(lock):
    if OUTPUT.exists() or OUTPUT.is_symlink():
        return {"existing": True, "validation": check(OUTPUT, lock)}
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise RuntimeError("Build-time qualification requires macOS arm64")
    cache = Path(lock["defaultCache"])
    stockage(lock); cache.mkdir(parents=True, exist_ok=True)
    for artifact in artifacts(lock):
        cached(artifact, cache, lock)
    PRODUCTS.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="client-python-build-", dir=PRODUCTS) as temporary:
        stage = Path(temporary)
        safe_extract(cache / lock["python"]["filename"], stage)
        runtime = stage / "python"
        identity = json.loads(python(runtime, "import sys,json;print(json.dumps({'prefix':sys.prefix,'version':sys.version_info[:3]}))"))
        if Path(identity["prefix"]).resolve() != runtime.resolve() or identity["version"] != [3, 13, 18]:
            raise RuntimeError("Extracted interpreter not isolated")
        requirements = stage / "requirements.txt"
        requirements.write_text("\n".join(p["name"] + "==" + p["version"] + " --hash=sha256:" + p["wheel"]["sha256"] for p in lock["packages"]) + "\n")
        run([runtime / "bin/python3", "-I", "-B", "-m", "pip", "install", "--no-index", "--no-deps", "--no-compile", "--only-binary=:all:", "--disable-pip-version-check", "--no-cache-dir", "--no-warn-script-location", "--require-hashes", "--find-links", cache, "-r", requirements], env=environment(runtime), timeout=120)
        console_wrappers(runtime)
        legal_material(runtime, cache, lock)
        (runtime / RECEIPT).write_text(json.dumps({"schemaVersion": 1, "lockSHA256": digest(LOCK), "inventory": inventory(runtime)}, sort_keys=True, separators=(",", ":")) + "\n")
        result = qualify_copy(runtime, lock)
        OUTPUT.parent.mkdir(exist_ok=True)
        if OUTPUT.exists() or OUTPUT.is_symlink():
            raise RuntimeError("Runtime appeared concurrently; existing copy preserved")
        runtime.rename(OUTPUT)
        return {"prepared": True, "output": str(OUTPUT), "lockSHA256": digest(LOCK), "qualification": result}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Read-only local validation, no downloads or writes")
    arguments = parser.parse_args()
    lock = json.loads(LOCK.read_text()); validate_lock(lock)
    result = {"checked": True, "validation": check(OUTPUT, lock)} if arguments.check else prepare(lock)
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)
    for item in (signal.SIGINT, signal.SIGTERM):
        signal.signal(item, interrupted)
    try:
        main()
    finally:
        for child in CHILDREN:
            stop(child)
