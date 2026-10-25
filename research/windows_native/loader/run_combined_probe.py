#!/usr/bin/env python3
"""Sequential resolver tests and our generated PE; no external file accepted."""
import hashlib
import json
from pathlib import Path
import re
import signal
import sys
import tempfile

sys.dont_write_bytecode = True
from combined_fixture import make_combined_fixture
from run_cpu_probe import OWNED_GROUPS, bounded, group_exists


def main():
    source = Path(__file__).resolve().parent
    products = source.parents[2] / "Products.noindex"
    products.mkdir(exist_ok=True)
    dependencies = ("pe_loader.c", "pe_loader.h", "pe_modules.c", "pe_modules.h",
                    "winapi_subset.c", "winapi_subset.h", "winapi_modules.c", "winapi_modules.h",
                    "winapi_memory.c", "winapi_memory.h", "winapi_combined.c", "winapi_combined.h",
                    "test_winapi_combined.c", "test_winapi_combined_collisions.c",
                    "combined_probe.c", "combined_fixture.py", "run_combined_probe.py",
                    "run_cpu_probe.py", "module_fixture.py", "probe_fixture.py")
    hashes = {name: hashlib.sha256((source / name).read_bytes()).hexdigest() for name in dependencies}
    evidence = {"schemaVersion": 1, "sourceHashes": hashes, "commands": [], "unitTests": [],
                "sanitizerException": "Only generated-PE entry call_fixture excludes function-type metadata check; unit tests have no exclusions."}
    try:
        with tempfile.TemporaryDirectory(prefix="native-combined-probe-", dir=products) as directory:
            scratch = Path(directory)
            flags = ["nice", "-n", "15", "xcrun", "clang", "-std=c11", "-Wall", "-Wextra",
                     "-Werror", "-Wstrict-prototypes", "-O1", "-g", "-arch", "x86_64",
                     "-mmacosx-version-min=15.0", "-fsanitize=address,undefined",
                     "-fno-omit-frame-pointer", "-I", str(source), "-I", str(scratch)]
            common = ("pe_loader.c", "pe_modules.c", "winapi_subset.c", "winapi_modules.c",
                      "winapi_memory.c", "winapi_combined.c")
            for name, sources in (
                ("collisions", ("winapi_combined.c", "test_winapi_combined_collisions.c")),
                ("integrated", (*common, "test_winapi_combined.c")),
            ):
                binary = scratch / (name + "-test")
                command = flags + [str(source / file) for file in sources] + ["-o", str(binary)]
                evidence["commands"].append(command); bounded(command, 120)
                command = ["nice", "-n", "15", str(binary)]
                evidence["commands"].append(command)
                output = bounded(command, 15).decode().strip()
                match = re.fullmatch(r"PASS: (\d+) [^\n]+", output)
                if not match:
                    raise RuntimeError("Unexpected unit result: " + output[:1000])
                evidence["unitTests"].append({"name": name, "checks": int(match[1]), "output": output})
            fixture = make_combined_fixture()
            (scratch / "combined_fixture.h").write_text(
                "static const unsigned char combined_fixture[]={" + ",".join(map(str, fixture)) + "};\n")
            evidence["fixtureSHA256"] = hashlib.sha256(fixture).hexdigest()
            binary = scratch / "combined-probe"
            command = flags + [str(source / file) for file in (*common, "combined_probe.c")] + ["-o", str(binary)]
            evidence["commands"].append(command); bounded(command, 120)
            command = ["nice", "-n", "15", str(binary), "--synthetic-combined-test"]
            evidence["commands"].append(command)
            result = json.loads(bounded(command, 15))
            evidence["result"] = result
            if not result.get("passed") or not result.get("cleanupVerified"):
                raise RuntimeError("Combined synthetic proof failed")
        evidence["temporaryArtifactsRemoved"] = True
        after = {name: hashlib.sha256((source / name).read_bytes()).hexdigest() for name in dependencies}
        if hashes != after:
            raise RuntimeError("Sources changed during compilation/tests")
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
