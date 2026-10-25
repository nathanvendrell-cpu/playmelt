#!/usr/bin/env python3
"""Build/run ONLY our embedded synthetic PE CPU test; no game/file input accepted."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from probe_fixture import make_fixture

OWNED_GROUPS = []

def bounded(command, timeout):
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    OWNED_GROUPS.append(process.pid)
    def stop_group(signum):
        try: os.killpg(process.pid, signum)
        except ProcessLookupError: pass
    try:
        out, err = process.communicate(timeout=timeout)
        if process.returncode:
            raise RuntimeError(f"CPU probe command exited {process.returncode}: " + (out + err).decode(errors="replace")[-3000:])
        if err:
            raise RuntimeError("Unexpected CPU probe diagnostics: " + err.decode(errors="replace")[-3000:])
        return out
    finally:
        # This group was created for this command alone. Also stop an orphaned
        # compiler child if its parent exited before communicate timed out.
        stop_group(signal.SIGTERM)
        try: process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            stop_group(signal.SIGKILL); process.wait()
        for stream in (process.stdout, process.stderr):
            if stream is not None: stream.close()


def main():
    root = Path(__file__).resolve().parents[3]
    source = Path(__file__).resolve().parent
    products = root / "Products.noindex"
    products.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="native-cpu-probe-", dir=products) as directory:
        scratch = Path(directory)
        data = make_fixture()
        (scratch / "probe_fixture.h").write_text("static const unsigned char probe_fixture[] = {" + ",".join(map(str, data)) + "};\n")
        binary = scratch / "cpu-probe"
        bounded(["nice", "-n", "15", "xcrun", "clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O1",
                 "-arch", "x86_64", "-mmacosx-version-min=15.0", "-I", str(source), "-I", str(scratch),
                 str(source / "pe_loader.c"), str(source / "winapi_subset.c"), str(source / "cpu_probe.c"), "-o", str(binary)], 120)
        result = json.loads(bounded(["nice", "-n", "15", str(binary), "--synthetic-cpu-self-test"], 15))
        assert result["passed"] and result["imageUnmapped"]
    result["temporaryArtifactsRemoved"] = True
    result["ownedProcessGroups"] = OWNED_GROUPS
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    if len(sys.argv) != 1:
        raise SystemExit("This self-test accepts no executable path or other argument.")
    def interrupted(_signum, _frame): raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    main()
