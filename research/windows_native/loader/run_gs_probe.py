#!/usr/bin/env python3
"""Child-only GS experiment, no external executable/PE path or arbitrary input.

The Python orchestrator never changes its own GS. Every command has its own
session/process group, fixed timeout, captured status and exact finally cleanup.
SIGILL/unsupported protocol are NOT PASS. A restoration failure is a failure.
"""
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
from run_cpu_probe import group_exists, stop_owned_group


def classification(returncode, timed_out=False):
    if timed_out:
        return "TIMEOUT"
    if returncode in (77, -signal.SIGILL):
        return "UNSUPPORTED"
    return "PASS" if returncode == 0 else "FAIL"


def classifier_tests():
    cases = ((0, False, "PASS"), (77, False, "UNSUPPORTED"),
             (-signal.SIGILL, False, "UNSUPPORTED"), (78, False, "FAIL"),
             (-signal.SIGSEGV, False, "FAIL"), (-signal.SIGBUS, False, "FAIL"),
             (1, False, "FAIL"), (0, True, "TIMEOUT"), (77, True, "TIMEOUT"))
    for code, timeout, expected in cases:
        if classification(code, timeout) != expected:
            raise RuntimeError("Outcome classifier failed")
    return len(cases)


def run_child(command, timeout, evidence):
    record = {"command": command, "timeoutSeconds": timeout, "startedMonotonic": time.monotonic()}
    evidence["processes"].append(record)
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    record.update(pid=process.pid, pgid=process.pid)
    timed_out = False
    out = err = b""
    try:
        try:
            out, err = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            stop_owned_group(process)
            out, err = process.communicate(timeout=1)
        record.update(returncode=process.returncode, timedOut=timed_out,
                      stdout=out.decode(errors="replace")[-32768:], stderr=err.decode(errors="replace")[-8192:])
        record["classification"] = classification(process.returncode, timed_out)
        return record
    finally:
        try:
            stop_owned_group(process)
        finally:
            record.update(reaped=process.returncode is not None, groupAbsent=not group_exists(process.pid),
                          elapsedSeconds=round(time.monotonic()-record["startedMonotonic"], 6))
            for stream in (process.stdout, process.stderr):
                if stream is not None:
                    stream.close()


def main():
    source = Path(__file__).resolve().parent
    products = source.parents[2] / "Products.noindex"
    products.mkdir(exist_ok=True)
    names = ("gs_probe.h", "gs_probe.c", "gs_bridge.S", "run_gs_probe.py", "run_cpu_probe.py", "probe_fixture.py", "GS_PROBE.md")
    def hashes():
        return {name: hashlib.sha256((source/name).read_bytes()).hexdigest() for name in names}
    evidence = {"schemaVersion": 1, "runnerPID": os.getpid(), "runnerPGID": os.getpgrp(),
                "sourceHashes": hashes(), "processes": [], "classifierChecks": classifier_tests(),
                "sanitizers": {"hostTests": "ASan+UBSan", "actualGSChild": "none; no sanitizer signal runtime under guest GS"},
                "scope": {"peLoaded": False, "gameExecuted": False, "wineUsed": False, "gpuUsed": False,
                          "parentGSChanged": False, "threadsTested": 1, "asyncSignalsQualified": False}}
    failed = False
    scratch_path = None
    try:
        with tempfile.TemporaryDirectory(prefix="native-gs-probe-", dir=products) as directory:
            scratch_path = Path(directory)
            evidence["scratchPath"] = str(scratch_path)
            flags = ["nice", "-n", "15", "xcrun", "clang", "-std=c11", "-Wall", "-Wextra", "-Werror",
                     "-Wstrict-prototypes", "-O1", "-g", "-arch", "x86_64", "-mmacosx-version-min=15.0",
                     "-fno-omit-frame-pointer", "-I", str(source)]
            binaries = {}
            for name, extra in (("host-tests", ["-DPM_GS_HOST_TESTS_ONLY", "-fsanitize=address,undefined"]),
                                ("gs-child", ["-fno-stack-protector"])):
                binary = scratch_path/name
                result = run_child([*flags, *extra, str(source/"gs_probe.c"), str(source/"gs_bridge.S"), "-o", str(binary)], 90, evidence)
                if result["classification"] != "PASS" or result["stderr"]:
                    raise RuntimeError(name+" compilation failed or emitted diagnostics")
                binaries[name] = binary
            result = run_child(["nice", "-n", "15", str(binaries["host-tests"]), "--host-tests"], 10, evidence)
            if result["classification"] != "PASS" or result["stderr"]:
                raise RuntimeError("Sanitized host tests failed")
            evidence["hostTests"] = json.loads(result["stdout"])
            if evidence["hostTests"].get("passed") is not True or evidence["hostTests"].get("gsChanged") is not False:
                raise RuntimeError("Unexpected host unit result")
            evidence["negativeControls"] = []
            for mode, timeout, expected in (("--force-unavailable", 5, "UNSUPPORTED"),
                                            ("--force-sigill", 5, "UNSUPPORTED"),
                                            ("--force-timeout", 0.2, "TIMEOUT")):
                result = run_child(["nice", "-n", "15", str(binaries["gs-child"]), mode], timeout, evidence)
                evidence["negativeControls"].append({"mode": mode, "outcome": result["classification"], "expected": expected,
                                                     "beforeGSChange": True, "provesGuestFaultRecovery": False})
                if result["classification"] != expected or result["stderr"] or not result["groupAbsent"]:
                    raise RuntimeError("Negative control failed: "+mode)
            result = run_child(["nice", "-n", "15", str(binaries["gs-child"]), "--roundtrip"], 5, evidence)
            evidence["realProbeOutcome"] = result["classification"]
            evidence["realProbeRecords"] = [json.loads(line) for line in result["stdout"].splitlines() if line.strip()]
            if result["stderr"]:
                raise RuntimeError("Unexpected real GS child diagnostics")
            if result["classification"] == "PASS":
                final = evidence["realProbeRecords"][-1] if evidence["realProbeRecords"] else {}
                required = ("passed", "gsActuallyRead", "darwinGSRestored", "pthreadSelfPreserved",
                            "errnoPreserved", "registersVerified", "signalMaskRestored")
                if any(final.get(key) is not True for key in required) or final.get("hostCallbacks") != 2 or final.get("tlsWrites") != 2:
                    raise RuntimeError("Success exit without required real GS evidence")
            elif result["classification"] != "UNSUPPORTED":
                raise RuntimeError("Real GS experiment failed; negative evidence retained")
        evidence["sourceHashesAfter"] = hashes()
        if evidence["sourceHashes"] != evidence["sourceHashesAfter"]:
            raise RuntimeError("Source changed during experiment")
        evidence["sourceHashesUnchanged"] = True
    except BaseException as error:
        failed = True
        evidence["failure"] = type(error).__name__+": "+str(error)
    finally:
        evidence["temporaryArtifactsRemoved"] = scratch_path is not None and not scratch_path.exists()
        evidence["remainingProcessGroups"] = [item["pgid"] for item in evidence["processes"] if "pgid" in item and group_exists(item["pgid"])]
        evidence["processCleanupVerified"] = not evidence["remainingProcessGroups"] and all(item.get("reaped") for item in evidence["processes"] if "pid" in item)
        evidence["workCompleted"] = not failed and evidence["processCleanupVerified"] and evidence["temporaryArtifactsRemoved"]
        print(json.dumps(evidence, indent=2))
    return 1 if failed or not evidence["workCompleted"] else 0


if __name__ == "__main__":
    if len(sys.argv) != 1:
        raise SystemExit("No executable path or arbitrary input accepted.")
    def interrupted(_signal, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    raise SystemExit(main())
