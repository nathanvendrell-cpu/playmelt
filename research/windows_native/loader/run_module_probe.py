#!/usr/bin/env python3
"""Build/run only the embedded synthetic PE client/DLL; no file input accepted."""
import json
from pathlib import Path
import signal
import sys
import tempfile

sys.dont_write_bytecode = True
from module_fixture import make_module_client_fixture, make_module_fixture
from run_cpu_probe import OWNED_GROUPS, bounded


def main():
    source = Path(__file__).resolve().parent
    products = source.parents[2] / "Products.noindex"
    products.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="native-module-probe-", dir=products) as directory:
        scratch = Path(directory)
        fixtures = (("module_fixture", make_module_fixture()), ("client_fixture", make_module_client_fixture()))
        assert all(len(data) == 3584 for _, data in fixtures)
        (scratch / "module_fixture.h").write_text("\n".join(
            "static const unsigned char " + name + "[] = {" + ",".join(map(str, data)) + "};"
            for name, data in fixtures) + "\n")
        binary = scratch / "module-probe"
        bounded(["nice", "-n", "15", "xcrun", "clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O1",
                 "-arch", "x86_64", "-mmacosx-version-min=15.0", "-I", str(source), "-I", str(scratch),
                 *(str(source / filename) for filename in
                   ("pe_loader.c", "pe_modules.c", "winapi_subset.c", "module_probe.c")), "-o", str(binary)], 120)
        result = json.loads(bounded(["nice", "-n", "15", str(binary), "--synthetic-module-self-test"], 15))
        assert result["passed"] and result["allImagesUnmapped"]
    result["temporaryArtifactsRemoved"] = True
    result["ownedProcessGroups"] = OWNED_GROUPS
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    if len(sys.argv) != 1:
        raise SystemExit("This self-test accepts no executable or DLL path, or other argument.")
    def interrupted(_signum, _frame): raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    main()
