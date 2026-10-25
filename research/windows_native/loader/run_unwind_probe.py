#!/usr/bin/env python3
"""Build/run only our embedded unwind fixture; never resume a restored context."""
import hashlib
import json
from pathlib import Path
import signal
import sys
import tempfile

sys.dont_write_bytecode = True
from run_cpu_probe import OWNED_GROUPS, bounded, group_exists
from unwind_fixture import make_unwind_fixture, RBX_SENTINEL, R12_SENTINEL


def main():
    source = Path(__file__).resolve().parent
    products = source.parents[2] / "Products.noindex"
    products.mkdir(exist_ok=True)
    dependencies = ("pe_loader.c", "pe_loader.h", "x64_unwind.c", "x64_unwind.h", "x64_unwind_internal.h",
                    "unwind_probe.c", "unwind_fixture.py", "run_unwind_probe.py",
                    "run_cpu_probe.py", "module_fixture.py", "probe_fixture.py")
    hashes = {name: hashlib.sha256((source / name).read_bytes()).hexdigest()
              for name in dependencies}
    evidence = {"schemaVersion": 1, "sourceHashes": hashes, "commands": []}
    try:
        with tempfile.TemporaryDirectory(prefix="native-unwind-probe-", dir=products) as directory:
            scratch = Path(directory)
            data, functions, returns, captures = make_unwind_fixture()
            header = "static const unsigned char unwind_fixture[]={" + ",".join(map(str, data)) + "};\n"
            header += "static const pm_runtime_function function_table[]={" + ",".join(
                "{" + ",".join(map(str, function)) + "}" for function in functions) + "};\n"
            for name, values in (("expected_returns", returns), ("capture_rvas", captures)):
                header += "static const uint32_t " + name + "[]={" + ",".join(map(str, values)) + "};\n"
            for name, value in (("RBX_SENTINEL", RBX_SENTINEL), ("R12_SENTINEL", R12_SENTINEL)):
                header += "#define " + name + " UINT64_C(" + str(value) + ")\n"
            (scratch / "unwind_fixture.h").write_text(header)
            evidence["fixtureSHA256"] = hashlib.sha256(data).hexdigest()
            binary = scratch / "unwind-probe"
            command = ["nice", "-n", "15", "xcrun", "clang", "-std=c11", "-Wall", "-Wextra",
                       "-Werror", "-Wstrict-prototypes", "-O1", "-g", "-arch", "x86_64",
                       "-mmacosx-version-min=15.0", "-fsanitize=address,undefined",
                       "-fno-omit-frame-pointer",
                       "-I", str(source), "-I", str(scratch),
                       *(str(source / name) for name in ("pe_loader.c", "x64_unwind.c", "unwind_probe.c")),
                       "-o", str(binary)]
            evidence["commands"].append(command)
            bounded(command, 120)
            command = ["nice", "-n", "15", str(binary), "--synthetic-unwind-test"]
            evidence["commands"].append(command)
            result = json.loads(bounded(command, 15))
            evidence["result"] = result
            if not result.get("passed") or not result.get("cleanupVerified"):
                raise RuntimeError("Synthetic context proof failed")
        evidence["temporaryArtifactsRemoved"] = True
        after = {name: hashlib.sha256((source / name).read_bytes()).hexdigest()
                 for name in dependencies}
        if hashes != after:
            raise RuntimeError("Sources changed during compilation/probe")
        evidence["sourceHashesUnchanged"] = True
    except BaseException as error:
        evidence["failure"] = str(error)
        raise
    finally:
        evidence["ownedProcessGroups"] = list(OWNED_GROUPS)
        remaining = [group for group in OWNED_GROUPS if group_exists(group)]
        evidence["remainingProcessGroups"] = remaining
        evidence["processCleanupVerified"] = not remaining
        print(json.dumps(evidence, indent=2))


if __name__ == "__main__":
    if len(sys.argv) != 1:
        raise SystemExit("This self-test accepts no executable/DLL path or other argument.")
    def interrupted(_signum, _frame): raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    main()
