#!/usr/bin/env python3
"""Test VirtualProtect only from our generated PE, on tiny owned CPU regions."""
import json
from pathlib import Path
import signal
import sys
import tempfile

sys.dont_write_bytecode = True
from memory_fixture import make_memory_fixture
from run_cpu_probe import OWNED_GROUPS, bounded


def main():
    source = Path(__file__).resolve().parent
    products = source.parents[2] / "Products.noindex"
    products.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="native-memory-probe-", dir=products) as directory:
        scratch = Path(directory)
        data = make_memory_fixture()
        (scratch / "memory_fixture.h").write_text(
            "static const unsigned char memory_fixture[] = {" + ",".join(map(str, data)) + "};\n")
        binary = scratch / "memory-probe"
        bounded(["nice", "-n", "15", "xcrun", "clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O1",
                 "-arch", "x86_64", "-mmacosx-version-min=15.0", "-I", str(source), "-I", str(scratch),
                 *(str(source / filename) for filename in
                   ("pe_loader.c", "winapi_subset.c", "winapi_memory.c", "memory_probe.c")),
                 "-o", str(binary)], 120)
        result = json.loads(bounded(["nice", "-n", "15", str(binary), "--synthetic-virtualprotect-test"], 15))
        if not result.get("passed") or not result.get("cleanupVerified"):
            raise RuntimeError("Synthetic VirtualProtect proof failed")
    result["temporaryArtifactsRemoved"] = True
    result["ownedProcessGroups"] = OWNED_GROUPS
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    if len(sys.argv) != 1:
        raise SystemExit("This self-test accepts no executable or DLL path, or other argument.")
    def interrupted(_signum, _frame): raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    main()
