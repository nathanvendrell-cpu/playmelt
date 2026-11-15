#!/usr/bin/env python3
"""Compile the actual production wrapper implementation against inert files."""
from pathlib import Path
import subprocess
import tempfile
import shutil

root = Path(__file__).resolve().parent.parent
products = root / "Products.noindex"
scratch = Path(tempfile.mkdtemp(prefix="game-mode-tests-", dir=products))
try:
    source = (root / "Core.swift").read_text()
    start = source.index("enum GameModeRuntime {")
    end = source.index("\nfunc localGameEnvironmentExports", start)
    extracted = scratch / "GameModeRuntime.swift"
    # Inert Dock icon: the wrapper treats a missing icon as optional (if let).
    stub = "\nenum GameDockRuntime { static func icnsData(from data: Data) -> Data? { nil } }\n"
    extracted.write_text("import Foundation\n" + source[start:end] + stub)
    binary = scratch / "test"
    subprocess.run(["swiftc", str(extracted), str(root / "tests/GameModeRuntimeTests.swift"), "-o", str(binary)], check=True, timeout=60)
    subprocess.run([str(binary), str(scratch / "fixture")], check=True, timeout=20)
finally:
    shutil.rmtree(scratch)
