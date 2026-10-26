#!/usr/bin/env python3
"""Bounded TLS opt-in proof plus affected loader/ownership/GS regressions."""
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import struct
import sys
import tempfile

sys.dont_write_bytecode=True
from gs_tls_fixture import make_tls_fixture
from gs_pe_fixture import make_gs_pe_fixture
from dll_lifecycle_fixture import make_dll_lifecycle_fixture
from run_gs_pe_probe import fixture_checks
from run_gs_probe import run_child
from run_cpu_probe import group_exists


def main():
    source=Path(__file__).resolve().parent; products=source.parents[2]/"Products.noindex"; products.mkdir(exist_ok=True)
    names=("pe_loader.c","pe_loader.h","x64_unwind.h","x64_unwind_internal.h","test_pe_loader.c","test_pe_holds.c",
           "test_pe_unwind_loader.c","test_pe_tls.c","gs_probe.h","gs_bridge.S","gs_pe_probe.h","gs_pe_bridge.S",
           "gs_pe_probe.c","gs_pe_fixture.py","gs_tls_fixture.py","gs_tls_probe.c","run_tls_probe.py","TLS_PROBE.md",
           "run_gs_pe_probe.py","run_gs_probe.py","run_cpu_probe.py","probe_fixture.py","module_fixture.py",
           "dll_lifecycle_fixture.py","dll_lifecycle_probe.c")
    def hashes(): return {n:hashlib.sha256((source/n).read_bytes()).hexdigest() for n in names}
    evidence={"schemaVersion":1,"runnerPID":os.getpid(),"runnerPGID":os.getpgrp(),"sourceHashes":hashes(),"processes":[],"unitTests":[],
              "sanitizers":{"unitsAndDLLProbe":"ASan+UBSan; existing DllMain entry-only function-check exclusion","GSChildren":"none; no sanitizer signal handler under guest GS"},
              "scope":{"externalPE":False,"gameExecuted":False,"gpuUsed":False,"wineUsed":False,"threadsWithGuestTLS":1,
                       "TLSCallbacksExecuted":False,"generalWindowsTLSImplemented":False}}
    scratch=None; failed=False
    try:
        with tempfile.TemporaryDirectory(prefix="native-tls-probe-",dir=products) as directory:
            scratch=Path(directory); evidence["scratchPath"]=str(scratch)
            flags=["nice","-n","15","xcrun","clang","-std=c11","-Wall","-Wextra","-Werror","-Wstrict-prototypes","-O1","-g",
                   "-arch","x86_64","-mmacosx-version-min=15.0","-fno-omit-frame-pointer","-I",str(source),"-I",str(scratch)]
            def build(name,sources,sanitized=True):
                binary=scratch/name
                result=run_child([*flags,*( ["-fsanitize=address,undefined"] if sanitized else ["-fno-stack-protector"] ),
                                  *(str(source/n) for n in sources),"-o",str(binary)],90,evidence)
                if result["classification"]!="PASS" or result["stderr"]: raise RuntimeError(name+" build failed")
                return binary
            def run(binary,*args):
                result=run_child(["nice","-n","15",str(binary),*args],10,evidence)
                if result["classification"]!="PASS" or result["stderr"]: raise RuntimeError(binary.name+" failed: "+result["classification"])
                return result["stdout"]
            for name,src in (("tls-tests","test_pe_tls.c"),("loader-regression","test_pe_loader.c"),
                             ("holds-regression","test_pe_holds.c"),("unwind-loader-regression","test_pe_unwind_loader.c")):
                output=run(build(name,(src,)))
                count=re.search(r"(?:PASS: |PE loader: )(\d+) ",output)
                if not count: raise RuntimeError("Unknown unit result "+output[:500])
                evidence["unitTests"].append({"name":name,"checks":int(count[1]),"output":output.strip()})
            fixtures=(("dll_success_fixture",make_dll_lifecycle_fixture(True)),("dll_failure_fixture",make_dll_lifecycle_fixture(False)))
            (scratch/"dll_lifecycle_fixture.h").write_text("\n".join("static const unsigned char "+n+"[]={"+",".join(map(str,d))+"};" for n,d in fixtures)+"\n")
            evidence["dllFixtureHashes"]={n:hashlib.sha256(d).hexdigest() for n,d in fixtures}
            result=json.loads(run(build("dll-lifecycle-regression",("pe_loader.c","dll_lifecycle_probe.c")),"--synthetic-dll-lifecycle-self-test"))
            evidence["dllLifecycleRegression"]=result
            if not result.get("passed") or not result.get("allImagesUnmapped"): raise RuntimeError("DLL lifecycle regression failed")
            evidence["guestProofs"]=[]
            for tls in (False,True):
                data,meta=make_tls_fixture() if tls else make_gs_pe_fixture()
                digest=hashlib.sha256(data).hexdigest()
                if not tls:
                    evidence["baselineFixtureChecks"]=fixture_checks(data,meta)
                    if digest!="e1a44fe44d3653832fc92f0e3a325daea84ba0a55975feb0ba6cb21c5d2d0e9e":
                        raise RuntimeError("Baseline PE fixture bytes changed")
                else:
                    if struct.unpack_from("<II",data,0x150)!=(0x8300,40) or data[0x1080:0x1084]!=b"\xff"*4 or not meta["tlsDirectoryPresent"]:
                        raise RuntimeError("Missing actual TLS directory or uninitialized index")
                key="tlsFixture" if tls else "baselineFixture"
                evidence[key]={"sha256":digest,"metadata":meta}
                header="static const unsigned char gs_pe_fixture[]={"+",".join(map(str,data))+"};\n"
                for name,field in (("gs_pe_callsites","callsiteRVAs"),("gs_pe_guards","failureGuardRVAs")):
                    header+="static const uint32_t "+name+"[]={"+",".join(map(str,meta[field]))+"};\n"
                (scratch/"gs_pe_fixture.h").write_text(header)
                evidence[key]["headerSHA256"]=hashlib.sha256(header.encode()).hexdigest()
                binary=build("tls-pe-child" if tls else "gs-pe-regression",("pe_loader.c","gs_bridge.S","gs_pe_bridge.S","gs_tls_probe.c" if tls else "gs_pe_probe.c"),False)
                for mode,expected_calls,expected_return in (("--roundtrip",2,0),("--callback-refusal",1,1)):
                    raw=run_child(["nice","-n","15",str(binary),mode],5,evidence)
                    records=[json.loads(line) for line in raw["stdout"].splitlines() if line.strip()]
                    evidence["guestProofs"].append({"tlsOptIn":tls,"mode":mode,"outcome":raw["classification"],"records":records})
                    if raw["stderr"] or raw["classification"]!="PASS":
                        raise RuntimeError("GS child not qualified: "+raw["classification"]+" (UNSUPPORTED is not PASS)")
                    kinds={r.get("kind"):r for r in records}; guest=kinds.get("guest-result",{}); final=records[-1] if records else {}
                    if guest.get("passed") is not True or guest.get("callbackFailures")!=0 or guest.get("hostCallbacks")!=expected_calls or guest.get("tlsWrites")!=expected_calls or guest.get("peReturn")!=expected_return:
                        raise RuntimeError("Incorrect PE gateway proof")
                    if any(guest.get(k) is not True for k in ("markersVerified","darwinGSPthreadErrnoRestored","signalMaskRestored","registersVerified")):
                        raise RuntimeError("Missing restoration evidence")
                    if any(final.get(k) is not True for k in ("peLoaded","peExecuted","imageUnloaded","machMappingAbsent")) or final.get("resolutions")!=1:
                        raise RuntimeError("Missing actual PE lifecycle proof")
                    if tls:
                        result=kinds.get("tls-result",{})
                        if result.get("initializedFromPE") is not True or result.get("templateAndZeroFillVerified") is not True or result.get("storageMachRWNonXVerified") is not True or result.get("assignedIndex")!=1 or result.get("guestReadIndex")!=1 or result.get("blockBytes")!=32:
                            raise RuntimeError("Real PE TLS initialization/index evidence missing")
        evidence["sourceHashesAfter"]=hashes()
        if evidence["sourceHashes"]!=evidence["sourceHashesAfter"]: raise RuntimeError("Source changed during proof")
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
    if len(sys.argv)!=1: raise SystemExit("No external PE/executable input accepted")
    def interrupted(_signal,_frame): raise KeyboardInterrupt
    signal.signal(signal.SIGTERM,interrupted)
    raise SystemExit(main())
