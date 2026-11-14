#!/usr/bin/env python3
"""Execute main.swift's actual shutdown method with inert dependencies."""
import os
from pathlib import Path
import signal
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
def interrupted(_signal, _frame):
    raise InterruptedError("Shutdown lifecycle test interrupted")

for stop_signal in (signal.SIGTERM, signal.SIGINT):
    signal.signal(stop_signal, interrupted)

source = (ROOT / "main.swift").read_text()
start = source.index("    func beginShutdown() {")
brace = source.index("{", start)
depth = 1
end = brace + 1
while depth:
    if source[end] == "{":
        depth += 1
    elif source[end] == "}":
        depth -= 1
    end += 1
method = source[start:end]
template = (ROOT / "tests/SteamShutdownLifecycleTests.swift").read_text()
assert template.count("    // @PRODUCTION_BEGIN_SHUTDOWN@") == 1
with tempfile.TemporaryDirectory(prefix="steam-shutdown-test-", dir=ROOT / "Products.noindex") as name:
    folder = Path(name)
    swift = folder / "ShutdownTests.swift"
    swift.write_text(template.replace("    // @PRODUCTION_BEGIN_SHUTDOWN@", method))
    executable = folder / "SteamShutdownLifecycleTests"
    for arguments in (["/usr/bin/xcrun", "swiftc", "-module-cache-path", folder / "module-cache",
                       ROOT / "SteamInstallCoordinator.swift", swift, "-o", executable],
                      [executable, folder / "fixtures"]):
        process = subprocess.Popen([str(value) for value in arguments], cwd=ROOT, start_new_session=True)
        try:
            if process.wait(timeout=90) != 0:
                raise SystemExit("Shutdown lifecycle check failed")
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
