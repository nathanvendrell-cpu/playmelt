#!/usr/bin/env python3
"""Sequential CPU semaphore tests and embedded six-argument PE proof; no external binary input."""
import hashlib
import json
from pathlib import Path
import re
import signal
import sys
import tempfile

sys.dont_write_bytecode = True
from events_fixture import make_events_fixture
from semaphore_fixture import make_semaphore_fixture
from run_cpu_probe import OWNED_GROUPS, bounded, group_exists


def main():
    source = Path(__file__).resolve().parent
    products = source.parents[2] / "Products.noindex"
    products.mkdir(exist_ok=True)
    dependencies = ("pe_loader.c", "pe_loader.h", "x64_unwind.h", "x64_unwind_internal.h",
                    "pe_modules.c", "pe_modules.h", "winapi_subset.c", "winapi_subset.h",
                    "winapi_modules.c", "winapi_modules.h", "winapi_memory.c", "winapi_memory.h",
                    "winapi_events.c", "winapi_events.h", "winapi_combined.c", "winapi_combined.h",
                    "test_winapi_events.c", "test_winapi_semaphores.c", "test_winapi_combined.c", "test_winapi_combined_collisions.c",
                    "events_probe.c", "events_fixture.py", "run_events_probe.py",
                    "semaphore_probe.c", "semaphore_fixture.py", "run_semaphore_probe.py",
                    "run_allocation_probe.py", "run_cpu_probe.py", "module_fixture.py", "probe_fixture.py")
    hashes = {name: hashlib.sha256((source / name).read_bytes()).hexdigest() for name in dependencies}
    evidence = {"schemaVersion": 1, "sourceHashes": hashes, "commands": [], "unitTests": [],
                "sanitizers": "ASan+UBSan; only generated PE entry trampolines exclude function-type metadata checking"}
    try:
        with tempfile.TemporaryDirectory(prefix="native-semaphore-probe-", dir=products) as directory:
            scratch = Path(directory)
            flags = ["nice", "-n", "15", "xcrun", "clang", "-std=c11", "-Wall", "-Wextra", "-Werror",
                     "-Wstrict-prototypes", "-O1", "-g", "-arch", "x86_64", "-mmacosx-version-min=15.0",
                     "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                     "-I", str(source), "-I", str(scratch)]
            common = ("pe_loader.c", "pe_modules.c", "winapi_subset.c", "winapi_modules.c", "winapi_memory.c", "winapi_combined.c")

            def build(name, sources):
                binary = scratch / name
                command = [*flags, *(str(source / file) for file in sources), "-o", str(binary)]
                evidence["commands"].append(command); bounded(command, 120)
                return binary

            def run(binary, *args):
                command = ["nice", "-n", "15", str(binary), *args]
                evidence["commands"].append(command)
                return bounded(command, 20).decode().strip()

            for name, sources in (
                ("semaphore-tests", ("winapi_subset.c", "winapi_memory.c", "test_winapi_semaphores.c")),
                ("event-regression", ("winapi_subset.c", "winapi_memory.c", "test_winapi_events.c")),
                ("combined-collisions", ("winapi_combined.c", "test_winapi_combined_collisions.c")),
                ("combined-integration", (*common, "winapi_events.c", "test_winapi_combined.c")),
            ):
                output = run(build(name, sources))
                count = re.match(r"PASS:?\s+(\d+) ", output)
                if not count:
                    raise RuntimeError("Unexpected unit result: " + output[:1000])
                evidence["unitTests"].append({"name": name, "checks": int(count[1]), "output": output})
            for name, maker, sources, argument, field in (
                ("semaphore", make_semaphore_fixture, (*common, "semaphore_probe.c"), "--synthetic-semaphore-test", "semaphoreResult"),
                ("events", make_events_fixture, (*common, "events_probe.c"), "--synthetic-events-test", "eventRegressionResult"),
            ):
                fixture = maker()
                (scratch / (name+"_fixture.h")).write_text(
                    "static const unsigned char "+name+"_fixture[]={" + ",".join(map(str, fixture)) + "};\n")
                evidence[name+"FixtureSHA256"] = hashlib.sha256(fixture).hexdigest()
                binary = build(name+"-probe", sources)
                result = json.loads(run(binary, argument))
                evidence[field] = result
                if not result.get("passed") or not result.get("cleanupVerified"):
                    raise RuntimeError("Synthetic "+name+" proof failed")
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
