#!/usr/bin/env python3
"""Sequential metadata/copy regressions and our PE fixture; no external image path."""
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import sys
import tempfile

sys.dont_write_bytecode = True
from module_fixture import make_module_fixture
from module_filename_fixture import make_module_filename_fixture
from run_cpu_probe import OWNED_GROUPS, bounded, group_exists


def main():
    source = Path(__file__).resolve().parent
    products = source.parents[2] / "Products.noindex"
    products.mkdir(exist_ok=True)
    dependencies = ("pe_loader.c", "pe_loader.h", "x64_unwind.h", "x64_unwind_internal.h",
                    "pe_modules.c", "pe_modules.h", "winapi_subset.c", "winapi_subset.h",
                    "winapi_modules.c", "winapi_modules.h", "winapi_memory.c", "winapi_memory.h",
                    "winapi_events.c", "winapi_events.h", "winapi_combined.c", "winapi_combined.h",
                    "test_module_filename.c", "test_winapi_modules.c", "test_winapi_memory.c",
                    "test_winapi_combined.c", "test_winapi_combined_collisions.c",
                    "module_filename_fixture.py", "module_filename_probe.c", "run_module_filename_probe.py",
                    "module_fixture.py", "probe_fixture.py", "run_cpu_probe.py", "run_winapi_call_probe.py")
    hashes = {name: hashlib.sha256((source/name).read_bytes()).hexdigest() for name in dependencies}
    evidence = {"schemaVersion":1, "runnerPID":os.getpid(), "runnerPGID":os.getpgrp(), "sourceHashes":hashes, "commands":[], "unitTests":[],
                "sanitizers":"ASan+UBSan; only generated PE entry trampoline excludes function-type metadata checking",
                "priorSourceReviewCorrection":"C7 RIP-relative disp32 is based after its imm32; corrected before any compile/test"}
    try:
        with tempfile.TemporaryDirectory(prefix="native-module-filename-",dir=products) as directory:
            scratch = Path(directory)
            flags = ["nice","-n","15","xcrun","clang","-std=c11","-Wall","-Wextra","-Werror",
                     "-Wstrict-prototypes","-O1","-g","-arch","x86_64","-mmacosx-version-min=15.0",
                     "-fsanitize=address,undefined","-fno-omit-frame-pointer","-I",str(source),"-I",str(scratch)]
            common = ("pe_loader.c","pe_modules.c","winapi_subset.c","winapi_modules.c","winapi_memory.c",
                      "winapi_events.c","winapi_combined.c")

            def build(name,sources):
                binary=scratch/name
                command=[*flags,*(str(source/file) for file in sources),"-o",str(binary)]
                evidence["commands"].append(command); bounded(command,120)
                return binary

            def run(binary,*args):
                command=["nice","-n","15",str(binary),*args]
                evidence["commands"].append(command)
                return bounded(command,20).decode().strip()

            for name,sources in (
                ("module-filename-tests",("pe_modules.c","winapi_subset.c","winapi_modules.c","test_module_filename.c")),
                ("module-regression",("pe_modules.c","winapi_subset.c","winapi_modules.c","winapi_memory.c","test_winapi_modules.c")),
                ("memory-regression",("winapi_subset.c","test_winapi_memory.c")),
                ("combined-collisions",("winapi_combined.c","test_winapi_combined_collisions.c")),
                ("combined-integration",(*common,"test_winapi_combined.c")),
            ):
                output=run(build(name,sources))
                count=re.match(r"PASS:?\s+(\d+) ",output)
                if not count: raise RuntimeError("Unexpected unit result: "+output[:1000])
                evidence["unitTests"].append({"name":name,"checks":int(count[1]),"output":output})
            fixture=make_module_filename_fixture(); dll=make_module_fixture()
            (scratch/"module_filename_fixture.h").write_text("\n".join(
                "static const unsigned char "+name+"[]={"+",".join(map(str,data))+"};"
                for name,data in (("module_filename_fixture",fixture),("module_fixture",dll)))+"\n")
            evidence["fixtureSHA256"]={"client":hashlib.sha256(fixture).hexdigest(),"module":hashlib.sha256(dll).hexdigest()}
            result=json.loads(run(build("module-filename-probe",(*common,"module_filename_probe.c")),
                                  "--synthetic-module-filename-test"))
            evidence["moduleFilenameResult"]=result
            if not result.get("passed") or not result.get("cleanupVerified"):
                raise RuntimeError("Synthetic module filename proof failed")
        evidence["temporaryArtifactsRemoved"]=True
        after={name:hashlib.sha256((source/name).read_bytes()).hexdigest() for name in dependencies}
        if hashes!=after: raise RuntimeError("Sources changed during compilation/tests")
        evidence["sourceHashesUnchanged"]=True
    except BaseException as error:
        evidence["failure"]=str(error)
        raise
    finally:
        evidence["ownedProcessGroups"]=list(OWNED_GROUPS)
        remaining=[group for group in OWNED_GROUPS if group_exists(group)]
        evidence["remainingProcessGroups"]=remaining
        evidence["processCleanupVerified"]=not remaining
        print(json.dumps(evidence,indent=2))


if __name__ == "__main__":
    if len(sys.argv)!=1: raise SystemExit("Self-test accepts no executable/DLL path or other argument.")
    def interrupted(_signum,_frame): raise KeyboardInterrupt
    signal.signal(signal.SIGTERM,interrupted)
    main()
