#!/usr/bin/env python3
"""Sequential opt-in tests + embedded .pdata proof + existing DLL regression."""
import hashlib
import json
from pathlib import Path
import re
import signal
import sys
import tempfile

sys.dont_write_bytecode = True
from embedded_unwind_fixture import make_embedded_unwind_fixture, RBX_SENTINEL, R12_SENTINEL
from dll_lifecycle_fixture import make_dll_lifecycle_fixture
from run_cpu_probe import OWNED_GROUPS, bounded, group_exists


def main():
    source = Path(__file__).resolve().parent
    products = source.parents[2] / "Products.noindex"
    products.mkdir(exist_ok=True)
    dependencies = ("pe_loader.c", "pe_loader.h", "x64_unwind_internal.h", "x64_unwind.c",
                    "x64_unwind.h", "test_pe_loader.c", "test_x64_unwind.c", "test_pe_unwind_loader.c",
                    "embedded_unwind_probe.c", "embedded_unwind_fixture.py", "unwind_fixture.py",
                    "dll_lifecycle_fixture.py", "dll_lifecycle_probe.c", "run_cpu_probe.py",
                    "module_fixture.py", "probe_fixture.py", "run_embedded_unwind_probe.py")
    hashes = {name: hashlib.sha256((source / name).read_bytes()).hexdigest() for name in dependencies}
    evidence = {"schemaVersion": 1, "sourceHashes": hashes, "commands": [], "unitTests": [],
                "sanitizers": "ASan+UBSan on three CPU suites and new PE probe; function-check exemption only its generated-entry trampoline",
                "existingDLLRegression": "Original unsanitized configuration; not presented as a sanitized execution"}
    try:
        with tempfile.TemporaryDirectory(prefix="native-embedded-unwind-", dir=products) as directory:
            scratch = Path(directory)
            flags = ["nice", "-n", "15", "xcrun", "clang", "-std=c11", "-Wall", "-Wextra", "-Werror",
                     "-Wstrict-prototypes", "-O1", "-g", "-arch", "x86_64", "-mmacosx-version-min=15.0",
                     "-I", str(source), "-I", str(scratch)]
            sanitized = [*flags, "-fsanitize=address,undefined", "-fno-omit-frame-pointer"]

            def build(name, sources, sanitize=True):
                binary = scratch / name
                command = [*(sanitized if sanitize else flags),
                           *(str(source / filename) for filename in sources), "-o", str(binary)]
                evidence["commands"].append(command); bounded(command, 120)
                return binary

            def run(binary, *args):
                command = ["nice", "-n", "15", str(binary), *args]
                evidence["commands"].append(command)
                return bounded(command, 20).decode().strip()

            for name, sources in (
                ("loader-regression", ("test_pe_loader.c",)),
                ("unwind-regression", ("x64_unwind.c", "test_x64_unwind.c")),
                ("embedded-metadata-tests", ("test_pe_unwind_loader.c",)),
            ):
                output = run(build(name, sources))
                count = re.search(r"(?:PASS: |PE loader: )(\d+) ", output)
                if not count:
                    raise RuntimeError("Unexpected unit result: " + output[:1000])
                evidence["unitTests"].append({"name": name, "checks": int(count[1]), "output": output})
            data, returns, captures = make_embedded_unwind_fixture()
            header = "static const unsigned char embedded_unwind_fixture[]={" + ",".join(map(str, data)) + "};\n"
            for name, values in (("expected_returns", returns), ("capture_rvas", captures)):
                header += "static const uint32_t " + name + "[]={" + ",".join(map(str, values)) + "};\n"
            for name, value in (("RBX_SENTINEL", RBX_SENTINEL), ("R12_SENTINEL", R12_SENTINEL)):
                header += "#define " + name + " UINT64_C(" + str(value) + ")\n"
            (scratch / "embedded_unwind_fixture.h").write_text(header)
            evidence["embeddedFixtureSHA256"] = hashlib.sha256(data).hexdigest()
            probe = build("embedded-unwind-probe", ("pe_loader.c", "x64_unwind.c", "embedded_unwind_probe.c"))
            result = json.loads(run(probe, "--synthetic-embedded-unwind-test"))
            evidence["embeddedProbe"] = result
            if not result.get("passed") or not result.get("cleanupVerified"):
                raise RuntimeError("Embedded metadata proof failed")
            fixtures = (("dll_success_fixture", make_dll_lifecycle_fixture(True)),
                        ("dll_failure_fixture", make_dll_lifecycle_fixture(False)))
            (scratch / "dll_lifecycle_fixture.h").write_text("\n".join(
                "static const unsigned char " + name + "[]={" + ",".join(map(str, data)) + "};"
                for name, data in fixtures) + "\n")
            probe = build("dll-lifecycle-regression", ("pe_loader.c", "dll_lifecycle_probe.c"), sanitize=False)
            result = json.loads(run(probe, "--synthetic-dll-lifecycle-self-test"))
            evidence["dllLifecycleRegression"] = result
            if not result.get("passed") or not result.get("allImagesUnmapped"):
                raise RuntimeError("Existing DLL lifecycle regression failed")
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
