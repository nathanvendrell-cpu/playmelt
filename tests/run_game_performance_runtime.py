#!/usr/bin/env python3
"""Bounded pure policy fixtures; no app, Steam, Wine or GPU execution."""
from pathlib import Path
import os
import shutil
import signal
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
scratch = Path(tempfile.mkdtemp(prefix="performance-runtime-tests-", dir=root / "Products.noindex"))

def run(command, timeout):
    process = subprocess.Popen(command, start_new_session=True)
    try:
        code = process.wait(timeout=timeout)
        if code:
            raise subprocess.CalledProcessError(code, command)
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
        # wait() reaps exactly the task-owned compiler/test process.
        assert process.poll() is not None

try:
    binary = scratch / "tests"
    run(["swiftc", "-j", "1", str(root / "GameSettings.swift"), str(root / "GamePerformanceRuntime.swift"),
         str(root / "tests/GamePerformanceRuntimeTests.swift"), "-o", str(binary)], 45)
    run([str(binary)], 10)
finally:
    shutil.rmtree(scratch)
