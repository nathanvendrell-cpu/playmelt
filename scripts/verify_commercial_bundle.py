#!/usr/bin/env python3
"""Read-only distribution gate. Never launches the app or reads account credentials."""
import argparse
import base64
import hashlib
import json
import plistlib
import os
import re
import stat
import subprocess
import tempfile
import zipfile
from pathlib import Path, PurePosixPath


def run(command):
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=45)
        return result.returncode, result.stdout + result.stderr
    except (OSError, subprocess.TimeoutExpired):
        return -1, ""


def newer_build(candidate, previous):
    if not all(isinstance(value,str) and re.fullmatch(r'[1-9][0-9]{0,17}',value) for value in [candidate,previous]):return False
    return int(candidate)>int(previous)


def archive_matches_bundle(archive,bundle):
    """Read the signed ZIP without extraction; bind it to the inspected app."""
    try:
        expected={str(path.relative_to(bundle.parent)).replace(os.sep,'/'):path for path in bundle.rglob('*') if path.is_file() or path.is_symlink()}
        with zipfile.ZipFile(archive)as package:
            entries=package.infolist();names=[entry.filename for entry in entries]
            if len(names)!=len(set(names)) or len(names)>50000 or sum(entry.file_size for entry in entries)>2*1024**3:return False
            found=set()
            for entry in entries:
                path=PurePosixPath(entry.filename)
                if path.is_absolute() or '..'in path.parts or '\\'in entry.filename:return False
                if path.parts and path.parts[0]=='__MACOSX':continue
                if entry.is_dir():
                    if not path.parts or path.parts[0]!=bundle.name:return False
                    continue
                actual=expected.get(entry.filename)
                if actual is None:return False
                if actual.is_symlink():
                    if stat.S_IFMT(entry.external_attr>>16)!=stat.S_IFLNK or package.read(entry)!=os.readlink(actual).encode():return False
                    if bundle.resolve()not in actual.resolve().parents:return False
                elif entry.file_size!=actual.stat().st_size or hashlib.sha256(package.read(entry)).digest()!=hashlib.sha256(actual.read_bytes()).digest():return False
                found.add(entry.filename)
            return found==set(expected)
    except (OSError,ValueError,zipfile.BadZipFile,RuntimeError):return False


def verify_update_signature(archive,key,signature):
    """Actual Ed25519 verification with macOS CryptoKit; no private signing key."""
    try:
        if len(base64.b64decode(key,validate=True))!=32 or len(base64.b64decode(signature,validate=True))!=64:return False
    except (ValueError,TypeError):return False
    code='''import Foundation;import CryptoKit
do {let key=try Curve25519.Signing.PublicKey(rawRepresentation:Data(base64Encoded:CommandLine.arguments[2])!);let signature=Data(base64Encoded:CommandLine.arguments[3])!;let archive=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]),options:.mappedIfSafe);exit(key.isValidSignature(signature,for:archive) ? 0:1)}catch{exit(1)}'''
    try:
        with tempfile.TemporaryDirectory(prefix='playmelt-signature-check-')as temporary:
            result=subprocess.run(['/usr/bin/swift','-module-cache-path',temporary+'/cache','-e',code,str(archive),key,signature],stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=90)
            return result.returncode==0
    except (OSError,subprocess.TimeoutExpired):return False


def portable_python_resources_present(bundle):
    """Static presence/permissions/confinement only; never executes Python or verifies its provenance."""
    return portable_python_layout_present(bundle/'Contents/Resources/Python',bundle)


def portable_python_layout_present(root,boundary):
    """The same read-only checks also qualify the packaging staging tree before its bundle copy."""
    try:
        boundary=boundary.resolve(strict=True)
        resolved_root=root.resolve(strict=True)
        if not root.is_dir() or(resolved_root!=boundary and boundary not in resolved_root.parents):return False
        # CPython's internal relative symlinks are valid. Reject even an unused
        # link escaping this app before looking for library/package resources.
        for path in root.rglob('*'):
            resolved=path.resolve(strict=True)
            if resolved!=boundary and boundary not in resolved.parents:return False
        library=root/'lib/python3.13'
        site=library/'site-packages'
        required=[root/'bin/python3',root/'bin/legendary',library/'encodings/__init__.py',
                  library/'json/__init__.py',library/'ssl.py',library/'hashlib.py',
                  library/'urllib/__init__.py',library/'importlib/__init__.py',
                  site/'certifi/__init__.py',site/'certifi/cacert.pem',site/'legendary/__init__.py']
        ssl=list((library/'lib-dynload').glob('_ssl*.so'))
        metadata=list(site.glob('legendary_gl-*.dist-info/METADATA'))
        if not metadata:return False
        if not all(path.is_file() for path in required+ssl+metadata):return False
        if not all(os.access(path,os.X_OK) for path in required[:2]):return False
        for path in required+ssl+metadata:
            resolved=path.resolve(strict=True)
            if resolved!=boundary and boundary not in resolved.parents:return False
        if not ssl:
            # The qualified standalone CPython has a built-in native _ssl, not
            # a separate .so. Inspect its exported symbol without running it.
            code,symbols=run(['/usr/bin/nm','-gU',str((root/'bin/python3').resolve(strict=True))])
            if code!=0 or not re.search(r'^\s*[0-9a-fA-F]+\s+[Tt]\s+_PyInit__ssl\s*$',symbols,re.MULTILINE):return False
        return True
    except (OSError,ValueError,RuntimeError):return False


def inspect(bundle, version, build, public_config, update_archive=None, update_signature=None, previous_build=None, expected_update_public_key=None):
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    configured = json.loads(public_config.read_text())
    key = info.get("PlaymeltLicensePublicKey", "")
    try:
        key_valid = len(base64.b64decode(key, validate=True)) == 32
    except (ValueError, TypeError):
        key_valid = False
    resources = bundle / "Contents/Resources"
    binary = bundle / "Contents/MacOS/MetalMax"
    prohibited_names = {"wine", "wine64", "wineserver", "d3dmetal", "libd3dmetal.dylib", "winemetal.so", "steam_api64.dll", "nvngx.dll", "nvngx.so", "nvapi64.dll"}
    prohibited = [str(p.relative_to(bundle)) for p in bundle.rglob("*") if p.is_file() and p.name.lower() in prohibited_names]
    signature_ok, _ = run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(bundle)])
    _, identity = run(["/usr/bin/codesign", "-d", "--verbose=4", str(bundle)])
    gatekeeper_ok, _ = run(["/usr/sbin/spctl", "--assess", "--type", "execute", str(bundle)])
    stapled_ok, _ = run(["/usr/bin/xcrun", "stapler", "validate", str(bundle)])
    channel_explicit='PlaymeltClientCredentialChannel'in info
    channel=info.get('PlaymeltClientCredentialChannel')
    channel_valid=not channel_explicit or(channel=='adhoc-login-v1' and info.get('PlaymeltCommercialAccessEnabled')is True and info.get('PlaymeltDevelopmentBuild')is False and info.get('PlaymeltInternalBuild')is False)
    gates = {
        "bundleIdentity": info.get("CFBundleIdentifier") == "com.robtech.metalmaxgaminghub",
        "exactVersion": info.get("CFBundleShortVersionString") == version,
        "exactBuild": str(info.get("CFBundleVersion")) == build,
        "commercialEnforcement": info.get("PlaymeltCommercialAccessEnabled") is True,
        "developmentBypassAbsent": info.get("PlaymeltDevelopmentBuild") is False,
        "internalBuildAbsent": info.get("PlaymeltInternalBuild") is False,
        "clientCredentialChannelAllowed": channel_valid,
        "accountServiceReady": info.get("PlaymeltAccountServiceAvailable") is True,
        "passwordLoginReady": info.get("PlaymeltPasswordLoginAvailable") is True,
        "productionAccountURL": info.get("PlaymeltAccountURL") == "https://7agency.fr/Playmelt/compte",
        "expectedGrantPublicKey": key_valid and key == configured.get("licensePublicKey"),
        "sourceDirectoryAbsent": "MetalMaxSourceDirectory" not in info,
        "portablePythonResourcesPresent": portable_python_resources_present(bundle),
        "runtimeLicenseTextsPresent": all((resources / "ThirdPartyLicenses" / name).is_file() for name in ["GCC-COPYING3.txt", "GCC-Runtime-Exception.txt", "MinGW-w64-COPYING.txt"]),
        "thirdPartyNoticesPresent": (resources / "ThirdPartyNotices.txt").is_file(),
        "noVendorRuntimeBundled": not prohibited,
        "bundleSealValid": signature_ok == 0,
    }
    trust={"developerIDSignature":"Authority=Developer ID Application:"in identity and "TeamIdentifier=not set"not in identity,"gatekeeperAccepted":gatekeeper_ok==0,"notarizationStapled":stapled_ok==0}
    enabled=info.get('PlaymeltAutomaticUpdatesAvailable')is True
    feed=info.get('SUFeedURL');update_key=info.get('SUPublicEDKey','')
    try:update_key_valid=len(base64.b64decode(update_key,validate=True))==32 and base64.b64decode(update_key)!=bytes(32)
    except (ValueError,TypeError):update_key_valid=False
    expected_feed='https://7agency.fr/Playmelt/compte/v1/updates/appcast.xml'
    flags=['SUEnableAutomaticChecks','SUAllowsAutomaticUpdates','SUAutomaticallyUpdate']
    policy=(feed==expected_feed and update_key_valid and info.get('PlaymeltUpdatesRequireAuthentication')is True and all(info.get(k)is True for k in flags))if enabled else(feed is None and all(info.get(k)is False for k in flags))
    gates['updatePolicyConsistent']=policy
    approved_update_key=expected_update_public_key or configured.get('updatePublicKey')
    gates['expectedUpdatePublicKey']=not enabled or bool(approved_update_key and update_key==approved_update_key)
    archive=Path(update_archive)if update_archive is not None else None
    present=archive is not None and archive.is_file() and not archive.is_symlink() and archive.stat().st_size<=1024**3
    updates={'enabled':enabled,'authenticatedFeedConfigured':enabled and policy,'archivePresent':present,
             'archiveMatchesInspectedBundle':bool(present and archive_matches_bundle(archive,bundle)),
             'ed25519SignatureValid':bool(present and update_key_valid and verify_update_signature(archive,update_key,update_signature)),
             'buildStrictlyNewer':newer_build(str(info.get('CFBundleVersion','')),previous_build),'previousBuild':previous_build,
             'archiveSHA256':hashlib.sha256(archive.read_bytes()).hexdigest()if present else None,'archiveBytes':archive.stat().st_size if present else None}
    integrity=all(gates.values());signed_update=integrity and enabled and all(updates[k]for k in ['authenticatedFeedConfigured','archivePresent','archiveMatchesInspectedBundle','ed25519SignatureValid','buildStrictlyNewer'])
    return {"schemaVersion":2,"scope":"Separate client integrity, signed-update artifact, and platform-trust assessments; no live transport/payment/runtime qualification",
            "bundle":str(bundle),"version":info.get('CFBundleShortVersionString'),"build":info.get('CFBundleVersion'),"binarySHA256":hashlib.sha256(binary.read_bytes()).hexdigest(),
            "clientPackageIntegrityPassed":integrity,"gates":gates,"failedGates":[k for k,v in gates.items()if not v],
            "signedUpdateArtifactReady":signed_update,"updates":updates,"authenticatedTransportRuntimeVerified":False,"runtimeFreshMacVerified":False,
            "clientCredentialChannel":{"selection":channel if channel_explicit else 'data-protection-keychain',"explicit":channel_explicit,"configurationValid":channel_valid,"runtimePersistenceVerified":False},
            "platformTrust":{"passed":all(trust.values()),"gates":trust},"prohibitedBundledPaths":prohibited,
            "appLaunched":False,"credentialsRead":False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--public-config", type=Path, default=Path(__file__).resolve().parents[1] / "config/native-account.json")
    parser.add_argument('--update-archive',type=Path,help='Immutable signed Sparkle ZIP containing this exact app; initial account DMG is separate')
    parser.add_argument('--update-signature',help='Public base64 Ed25519 signature of the update ZIP')
    parser.add_argument('--update-public-key',help='Independently approved PUBLIC Ed25519 key; otherwise public-config.updatePublicKey is required')
    parser.add_argument('--previous-build',help='Highest previously approved CFBundleVersion; must strictly increase')
    parser.add_argument('--require-platform-trust',action='store_true',help='Also require Developer ID/Gatekeeper/stapled-notarization checks; never inferred from integrity')
    args = parser.parse_args()
    try:
        report = inspect(args.bundle.resolve(strict=True), args.version, args.build, args.public_config,args.update_archive,args.update_signature,args.previous_build,args.update_public_key)
    except (OSError, ValueError, plistlib.InvalidFileException):
        print(json.dumps({"clientPackageIntegrityPassed":False,"signedUpdateArtifactReady":False,"runtimeFreshMacVerified":False,"error":"Invalid or unreadable bundle/configuration"}))
        return 2
    print(json.dumps(report, ensure_ascii=False, indent=2))
    acceptable=report['clientPackageIntegrityPassed']and(not report['updates']['enabled']or report['signedUpdateArtifactReady'])
    if args.require_platform_trust:acceptable=acceptable and report['platformTrust']['passed']
    return 0 if acceptable else 1


if __name__ == "__main__":
    raise SystemExit(main())
