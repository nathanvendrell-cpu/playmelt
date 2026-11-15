#!/usr/bin/env python3
"""Private automatic sample. Exact session marker + executable argument; no game control."""
import sys
# Bundled helpers are signed resources. Imported modules must not modify the app.
sys.dont_write_bytecode = True
import argparse
import ctypes
import json
import os
import posixpath
from pathlib import Path
import signal
import struct
import time
from m3_private_supervisor import Inspector, identity_key
from metal_performance_capture import run_capture
from analyze_metal_performance import analyze


def arguments(data):
    if len(data) < 5:
        return []
    count = struct.unpack('i', data[:4])[0]
    if not 1 <= count <= 4096:
        return []
    tail = data[4:]
    end = tail.find(b'\0')
    if end < 0:
        return []
    tail = tail[end:].lstrip(b'\0')
    return [os.fsdecode(x) for x in tail.split(b'\0')[:count]]


def _normal_argument(value):
    normal = value.replace('\\', '/').casefold()
    if normal.startswith('z:/'):
        normal = normal[2:]
    return normal


def target_match(argv, executable):
    """'exact' for the launched executable, 'child' for an absolute .exe inside
    its directory tree (Unreal stubs start <Project>/Binaries/Win64/*-Shipping.exe),
    otherwise None. Basename matching stays refused: it is ambiguous."""
    expected = str(executable).replace('\\', '/').casefold()
    root = posixpath.dirname(expected).rstrip('/') + '/'
    child = False
    for value in argv:
        normal = _normal_argument(value)
        if normal == expected:
            return 'exact'
        if normal.startswith('/') and normal.endswith('.exe') and root != '/':
            resolved = posixpath.normpath(normal)
            if resolved == normal and resolved.startswith(root):
                child = True
    return 'child' if child else None


def target_argument(argv, executable):
    return target_match(argv, executable) == 'exact'


class SessionInspector(Inspector):
    def __init__(self, executable):
        super().__init__()
        self.executable = executable
        self.kinds = {}

    def marker(self, pid, marker, buffer=None):
        buf = buffer if buffer is not None else ctypes.create_string_buffer(1024*1024)
        mib = (ctypes.c_int*3)(1, 49, pid)
        size = ctypes.c_size_t(ctypes.sizeof(buf))
        if self.lib.sysctl(mib, 3, buf, ctypes.byref(size), None, 0) != 0:
            return None
        data = ctypes.string_at(buf, size.value)
        if ('PLAYMELT_BENCHMARK_SESSION='+marker).encode() not in data.split(b'\0'):
            return False
        kind = target_match(arguments(data), self.executable)
        if kind is None:
            return False
        self.kinds[pid] = kind
        return True


def candidates_of(items):
    return [x for x in items if x.get('uid') == os.geteuid() and x.get('status') != 5
            and 'wine' in Path(x.get('path', '')).name.lower()]


def choose(items, kinds=None):
    candidates = candidates_of(items)
    if len(candidates) == 1:
        return candidates[0]
    # A launcher stub and the game it started both carry the session marker:
    # the single process running a child executable of the game is the renderer.
    children = [x for x in candidates if (kinds or {}).get(x.get('pid')) == 'child']
    return children[0] if len(children) == 1 else None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--session', required=True)
    parser.add_argument('--executable', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if not args.executable.is_absolute() or not args.output.is_absolute():
        parser.error('Absolute paths required')
    if not args.executable.is_file() or args.executable.is_symlink():
        parser.error('Regular executable required')
    inspector = SessionInspector(args.executable)
    report = {'status': 'inconclusive', 'reason': 'target_not_identified', 'groups': []}
    def interrupt(*_):
        raise KeyboardInterrupt()
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, interrupt)
    def select():
        inspector.kinds = {}
        found = inspector.snapshot(args.session)[0]
        chosen = choose(found, inspector.kinds)
        if not chosen and len(candidates_of(found)) > 1:
            report['reason'] = 'target_ambiguous'
        return chosen
    try:
        # Total stays below the 180 s owner timeout in Benchmarks.swift:
        # 110 discovery + 15 settle + 10 hand-over + 30 capture.
        deadline = time.monotonic()+110
        candidate = None
        while time.monotonic() < deadline:
            candidate = select()
            if candidate:
                break
            time.sleep(1)
        if candidate:
            # Let the loading screen settle; this remains a session sample, not a certified scene.
            time.sleep(15)
            current = select()
            if current and identity_key(candidate) != identity_key(current):
                # A launcher stub handed over to the game process: confirm the new one is stable.
                candidate = current
                time.sleep(10)
                current = select()
            if not current or identity_key(candidate) != identity_key(current):
                report['reason'] = 'target_changed'
            else:
                capture = args.output/'capture'
                capture.mkdir(mode=0o700)
                receipt = run_capture(candidate['pid'], candidate['path'], 30, capture,
                                      inspector=inspector, listener_new_session=False)
                if receipt['status'] == 'captured':
                    report = analyze((capture/'raw.ndjson').read_bytes(), candidate['pid'])
                    report['status'] = 'measured'
                else:
                    report['reason'] = receipt['reason']
    except KeyboardInterrupt:
        report['reason'] = 'cancelled'
    except (OSError, ValueError, RuntimeError) as error:
        report['reason'] = type(error).__name__
    finally:
        # No PID, executable path or environment is exposed in the UI/export summary.
        report.pop('pid', None)
        temporary = args.output/'result.tmp'
        temporary.write_text(json.dumps(report, ensure_ascii=False), encoding='utf-8')
        temporary.replace(args.output/'result.json')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
