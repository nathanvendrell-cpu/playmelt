#!/usr/bin/env python3
"""Two sequential builds, inert host checks, then isolated embedded PE↔GS runs."""
import hashlib
import json
import os
from pathlib import Path
import signal
import struct
import sys
import tempfile

sys.dont_write_bytecode = True
from gs_pe_fixture import make_gs_pe_fixture, TEXT, IAT
from run_gs_probe import run_child
from run_cpu_probe import group_exists


def fixture_checks(data, metadata):
    checks = 0
    def check(condition):
        nonlocal checks
        checks += 1
        if not condition:
            raise RuntimeError("Embedded GS PE generation check failed at check "+str(checks))
    def u32(at):
        return struct.unpack_from("<I", data, at)[0]
    check(len(data) == 0x1400)
    check(data[:2] == b"MZ" and data[0x80:0x84] == b"PE\0\0")
    check(data[0x84:0x86] == b"\x64\x86")
    check(u32(0x98+16) == TEXT and metadata["entryRVA"] == TEXT)
    check(data[0x98+112+9*8:0x98+112+10*8] == bytes(8))
    check(0 < metadata["codeSize"] <= 0x800)
    check(len(metadata["callsiteRVAs"]) == len(metadata["failureGuardRVAs"]) == 2)
    for call, guard in zip(metadata["callsiteRVAs"], metadata["failureGuardRVAs"]):
        at = 0x400+call-TEXT
        check(data[at:at+2] == b"\xff\x15")
        check(call+6+struct.unpack_from("<i", data, at+2)[0] == IAT)
        check(guard == call+6)
        check(data[at+6:at+14] == bytes.fromhex("49837c2468000f85"))
    for i, (raw, size) in enumerate(((0x400,0x800),(0xc00,0x400),(0x1000,0x200),(0x1200,0x200))):
        check(u32(0x188+i*40+16) == size and u32(0x188+i*40+20) == raw)
    return checks


def main():
    source=Path(__file__).resolve().parent
    products=source.parents[2]/"Products.noindex"
    products.mkdir(exist_ok=True)
    names=("gs_pe_probe.h","gs_pe_probe.c","gs_pe_bridge.S","gs_pe_fixture.py","run_gs_pe_probe.py","GS_PE_PROBE.md",
           "gs_probe.h","gs_bridge.S","run_gs_probe.py","run_cpu_probe.py","probe_fixture.py",
           "pe_loader.h","pe_loader.c","x64_unwind_internal.h","x64_unwind.h")
    def hashes(): return {n:hashlib.sha256((source/n).read_bytes()).hexdigest() for n in names}
    evidence={"schemaVersion":1,"runnerPID":os.getpid(),"runnerPGID":os.getpgrp(),"sourceHashes":hashes(),"processes":[],
              "sanitizers":{"inertHostTests":"ASan+UBSan","GSChildren":"none; no sanitizer handler under guest GS"},
              "scope":{"externalPE":False,"gameExecuted":False,"wineUsed":False,"gpuUsed":False,
                       "parentGSChanged":False,"threadsTested":1,"staticTLSLoaderImplemented":False}}
    scratch=None; failed=False
    try:
        with tempfile.TemporaryDirectory(prefix="native-gs-pe-",dir=products) as directory:
            scratch=Path(directory); evidence["scratchPath"]=str(scratch)
            data,metadata=make_gs_pe_fixture()
            evidence["fixtureChecks"]=fixture_checks(data,metadata)
            evidence["fixtureSHA256"]=hashlib.sha256(data).hexdigest(); evidence["fixtureMetadata"]=metadata
            header="static const unsigned char gs_pe_fixture[]={"+",".join(map(str,data))+"};\n"
            for name,key in (("gs_pe_callsites","callsiteRVAs"),("gs_pe_guards","failureGuardRVAs")):
                header+="static const uint32_t "+name+"[]={"+",".join(map(str,metadata[key]))+"};\n"
            (scratch/"gs_pe_fixture.h").write_text(header)
            evidence["generatedHeaderSHA256"]=hashlib.sha256(header.encode()).hexdigest()
            flags=["nice","-n","15","xcrun","clang","-std=c11","-Wall","-Wextra","-Werror","-Wstrict-prototypes",
                   "-O1","-g","-arch","x86_64","-mmacosx-version-min=15.0","-fno-omit-frame-pointer",
                   "-I",str(source),"-I",str(scratch)]
            binaries={}
            for name,extra in (("host-tests",["-DPM_GS_PE_HOST_TESTS_ONLY","-fsanitize=address,undefined"]),
                               ("gs-pe-child",["-fno-stack-protector"])):
                binary=scratch/name
                command=[*flags,*extra,*(str(source/n) for n in ("pe_loader.c","gs_bridge.S","gs_pe_bridge.S","gs_pe_probe.c")),"-o",str(binary)]
                result=run_child(command,90,evidence)
                if result["classification"]!="PASS" or result["stderr"]:
                    raise RuntimeError(name+" compilation failed or emitted diagnostics")
                binaries[name]=binary
            result=run_child(["nice","-n","15",str(binaries["host-tests"]),"--host-tests"],10,evidence)
            if result["classification"]!="PASS" or result["stderr"]:
                raise RuntimeError("Inert GS PE host tests failed")
            evidence["hostTests"]=json.loads(result["stdout"])
            if evidence["hostTests"].get("passed") is not True or evidence["hostTests"].get("peExecuted") is not False:
                raise RuntimeError("Unexpected host test outcome")
            evidence["guestProofs"]=[]
            for mode,expected_calls,expected_return in (("--roundtrip",2,0),("--callback-refusal",1,1)):
                result=run_child(["nice","-n","15",str(binaries["gs-pe-child"]),mode],5,evidence)
                records=[json.loads(line) for line in result["stdout"].splitlines() if line.strip()]
                evidence["guestProofs"].append({"mode":mode,"outcome":result["classification"],"records":records})
                if result["stderr"] or result["classification"] not in ("PASS","UNSUPPORTED"):
                    raise RuntimeError("Embedded GS PE child failed: "+mode)
                if result["classification"]=="UNSUPPORTED":
                    break
                by_kind={x.get("kind"):x for x in records}
                preflight=by_kind.get("preflight",{}); guest=by_kind.get("guest-result",{}); final=records[-1] if records else {}
                if not preflight.get("mappingEntryIATRelocationVerified") or not preflight.get("machWXVerified"):
                    raise RuntimeError("Entry/IAT/protection preflight missing")
                if any(guest.get(k) is not True for k in ("passed","markersVerified","darwinGSPthreadErrnoRestored","signalMaskRestored","registersVerified")):
                    raise RuntimeError("Guest postcondition missing")
                if guest.get("hostCallbacks")!=expected_calls or guest.get("tlsWrites")!=expected_calls or guest.get("peReturn")!=expected_return or guest.get("callbackFailures")!=0:
                    raise RuntimeError("Unexpected PE counters/return")
                if final.get("status")!="PASS" or final.get("resolutions")!=1 or any(final.get(k) is not True for k in ("peLoaded","peExecuted","imageUnloaded","machMappingAbsent")):
                    raise RuntimeError("PE loading/execution/cleanup not confirmed")
        evidence["sourceHashesAfter"]=hashes()
        if evidence["sourceHashes"]!=evidence["sourceHashesAfter"]:
            raise RuntimeError("Source changed during probe")
        evidence["sourceHashesUnchanged"]=True
    except BaseException as error:
        failed=True; evidence["failure"]=type(error).__name__+": "+str(error)
    finally:
        evidence["temporaryArtifactsRemoved"]=scratch is not None and not scratch.exists()
        evidence["remainingProcessGroups"]=[p["pgid"] for p in evidence["processes"] if "pgid" in p and group_exists(p["pgid"])]
        evidence["processCleanupVerified"]=not evidence["remainingProcessGroups"] and all(p.get("reaped") for p in evidence["processes"] if "pid" in p)
        evidence["workCompleted"]=not failed and evidence["temporaryArtifactsRemoved"] and evidence["processCleanupVerified"]
        print(json.dumps(evidence,indent=2))
    return 1 if failed or not evidence["workCompleted"] else 0


if __name__=="__main__":
    if len(sys.argv)!=1: raise SystemExit("No external executable/PE path or other input accepted")
    def interrupted(_signal,_frame): raise KeyboardInterrupt
    signal.signal(signal.SIGTERM,interrupted)
    raise SystemExit(main())
