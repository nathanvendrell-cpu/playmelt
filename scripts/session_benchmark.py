#!/usr/bin/env python3
"""Private automatic session measurement; no game control.

The session marker identifies the game's processes while it runs. When the
session ends, macOS's always-on Metal performance record is collected for
exactly that window and only those processes are analysed.
"""
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
import shutil
import struct
import subprocess
import time
from m3_private_supervisor import Inspector, identity_key

TOOL = '/usr/bin/metalperftrace'
POLL_SECONDS = 3
DISCOVERY_SECONDS = 300
MAX_SESSION_SECONDS = 4 * 3600
SPIKE_MS = 50.0
MIN_GROUP_SECONDS = 10.0


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


class MarkerInspector(Inspector):
    """Every process of this launch inherits the session marker (launcher, Wine, game)."""
    def marker(self, pid, marker, buffer=None):
        buf = buffer if buffer is not None else ctypes.create_string_buffer(1024*1024)
        mib = (ctypes.c_int*3)(1, 49, pid)
        size = ctypes.c_size_t(ctypes.sizeof(buf))
        if self.lib.sysctl(mib, 3, buf, ctypes.byref(size), None, 0) != 0 or size.value > ctypes.sizeof(buf):
            return None
        return ('PLAYMELT_BENCHMARK_SESSION='+marker).encode() in ctypes.string_at(buf, size.value).split(b'\0')


def _number(value):
    return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else 0.0


def _intervals(layer):
    rows = []
    for item in layer.get('Stats Timeline') or []:
        presented = item.get('Presented Frame Stats') or {}
        glass = item.get('Frame-On-Glass Interval Stats') or {}
        frames = int(_number(presented.get('Frame Count')))
        rows.append({'start': _number(item.get('Start MCT Seconds')),
                     'active': _number(item.get('Time Active (sec)')),
                     'frames': frames,
                     'gpu': _number((presented.get('On-GPU Walltime Stats') or {}).get('Average (ms)')),
                     'worst': _number(glass.get('Max (ms)'))})
    return rows


def _stats(rows):
    frames = sum(r['frames'] for r in rows)
    active = sum(r['active'] for r in rows)
    if frames <= 0 or active <= 0:
        return None
    measured = [r for r in rows if r['frames'] > 0]
    return {'presentedFPS': round(frames/active, 2), 'frames': frames, 'durationSeconds': round(active, 1),
            'gpuMs': round(sum(r['gpu']*r['frames'] for r in measured)/frames, 2),
            'worstFrameMs': round(max(r['worst'] for r in measured), 1),
            'spikeSeconds': sum(1 for r in measured if r['worst'] > SPIKE_MS),
            'lowestSecondFPS': round(min(r['frames']/r['active'] for r in measured if r['active'] > 0), 1)}


def summarize(overview, pids):
    """Pure analysis of `metalperftrace overview --json --json-include-timeline`."""
    processes = overview if isinstance(overview, list) else [overview]
    layers = [layer for proc in processes if isinstance(proc, dict) and proc.get('PID') in pids
              for layer in proc.get('Layers') or [] if isinstance(layer, dict)]
    measured = [(layer, _intervals(layer)) for layer in layers]
    measured = [(layer, rows) for layer, rows in measured if sum(r['frames'] for r in rows) > 0]
    if not measured:
        return {'status': 'inconclusive', 'reason': 'no_frames_for_session', 'groups': []}
    # The game's own surface is the layer that presented the most frames.
    layer, rows = max(measured, key=lambda item: sum(r['frames'] for r in item[1]))
    rows.sort(key=lambda r: r['start'])
    origin = next(r['start'] for r in rows if r['frames'] > 0)
    groups = []
    for config in layer.get('Configuration Timeline') or []:
        begin, end = _number(config.get('Start MCT Seconds')), _number(config.get('End MCT Seconds'))
        stats = _stats([r for r in rows if begin <= r['start'] < end])
        if stats and stats['durationSeconds'] >= MIN_GROUP_SECONDS:
            groups.append({'width': int(_number(config.get('Width (pixels)'))),
                           'height': int(_number(config.get('Height (pixels)'))), **stats})
    minutes = []
    for index in range(int((rows[-1]['start']-origin)//60)+1):
        stats = _stats([r for r in rows if origin+index*60 <= r['start'] < origin+(index+1)*60])
        if stats:
            minutes.append({'minute': index, **stats})
    session = _stats(rows)
    if not groups and session:
        groups.append({'width': 0, 'height': 0, **session})
    return {'status': 'measured', 'method': 'metalperftrace-collect', 'session': session,
            'groups': groups, 'minutes': minutes}


def collect(start, end, directory, run=subprocess.run):
    directory.mkdir(mode=0o700)
    done = run([TOOL, 'collect', '--start', '@%d' % int(start), '--end', '@%d' % int(end+1), '--json', str(directory)],
               stdin=subprocess.DEVNULL, capture_output=True, timeout=600, check=True)
    traces = [Path(x) for x in json.loads(done.stdout).get('traces', [])]
    if len(traces) != 1 or traces[0].parent.resolve() != directory.resolve():
        raise RuntimeError('unexpected trace list')
    return traces[0]


def overview_of(trace, pids, run=subprocess.run):
    predicate = 'pid IN {%s}' % ','.join(str(int(p)) for p in sorted(pids))
    done = run([TOOL, 'overview', '--json', '--json-include-timeline', '--predicate', predicate, str(trace)],
               stdin=subprocess.DEVNULL, capture_output=True, timeout=600, check=True)
    return json.loads(done.stdout)


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
    report = {'status': 'inconclusive', 'reason': 'target_not_identified', 'groups': []}
    def interrupt(*_):
        raise KeyboardInterrupt()
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, interrupt)
    inspector = MarkerInspector()
    capture = args.output/'capture'
    try:
        began = time.monotonic()
        seen, first, last = set(), None, None
        missing = 0
        while True:
            now = time.monotonic()
            pids = {item['pid'] for item in inspector.snapshot(args.session)[0]}
            if pids:
                seen |= pids
                first = first or time.time()
                last = time.time()
                missing = 0
            elif first is not None:
                missing += 1
                if missing >= 2:
                    break
            if first is None and now-began > DISCOVERY_SECONDS:
                break
            if first is not None and now-began > MAX_SESSION_SECONDS:
                report['truncatedAtSeconds'] = MAX_SESSION_SECONDS
                break
            time.sleep(POLL_SECONDS)
        if first is not None:
            trace = collect(first-2, last+POLL_SECONDS, capture)
            report = summarize(overview_of(trace, seen), seen)
            if report.get('status') == 'measured':
                # Analysis kept; the raw system-wide record is not retained.
                shutil.rmtree(capture, ignore_errors=True)
    except KeyboardInterrupt:
        report['reason'] = 'cancelled'
    except subprocess.TimeoutExpired:
        report['reason'] = 'collect_timeout'
    except subprocess.CalledProcessError:
        report['reason'] = 'collect_failed'
    except (OSError, ValueError, RuntimeError) as error:
        report['reason'] = type(error).__name__
    finally:
        temporary = args.output/'result.tmp'
        temporary.write_text(json.dumps(report, ensure_ascii=False), encoding='utf-8')
        temporary.replace(args.output/'result.json')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
