#!/usr/bin/env python3
"""Bounded, PID-scoped Metal statistics collection; no metric interpretation."""
import argparse
import codecs
import json
import math
import os
from pathlib import Path
import selectors
import signal
import stat
import subprocess
import time

from m3_private_supervisor import Inspector

TOOL = '/usr/bin/metalperftrace'
MAX_BYTES = 4 * 1024 * 1024
MAX_OBJECT = 256 * 1024
CHECK_SECONDS = 1.0


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate JSON key')
        result[key] = value
    return result


def reject_constant(_value):
    raise ValueError('non-finite JSON value')


def finite_float(value):
    parsed = float(value)
    if not math.isfinite(parsed):
        raise ValueError('non-finite JSON value')
    return parsed


class JSONFramer:
    """Accept complete pretty-printed or concatenated objects without guessing metrics."""
    def __init__(self, pid):
        self.pid = pid
        self.text = ''
        self.utf8 = codecs.getincrementaldecoder('utf-8')('strict')
        self.decoder = json.JSONDecoder(object_pairs_hook=unique_object, parse_constant=reject_constant,
                                        parse_float=finite_float)
        self.count = 0

    def feed(self, data, *, final=False):
        try:
            self.text += self.utf8.decode(data, final=final)
        except UnicodeDecodeError:
            raise ValueError('invalid UTF-8 output') from None
        while True:
            self.text = self.text.lstrip()
            if not self.text:
                return
            try:
                value, end = self.decoder.raw_decode(self.text)
            except json.JSONDecodeError:
                if final:
                    raise ValueError('incomplete or invalid JSON output') from None
                if len(self.text.encode('utf-8')) > MAX_OBJECT:
                    raise ValueError('JSON object limit exceeded')
                return
            if len(self.text[:end].encode('utf-8')) > MAX_OBJECT:
                raise ValueError('JSON object limit exceeded')
            if not isinstance(value, dict):
                raise ValueError('unknown JSON structure')
            if type(value.get('PID')) is not int or value['PID'] != self.pid:
                raise ValueError('unexpected or missing PID')
            self.count += 1
            self.text = self.text[end:]


def identity(inspector, pid, expected):
    item = inspector.identity(pid)
    if not item or item.get('pid') != pid or item.get('uid') != os.geteuid():
        raise RuntimeError('process identity unavailable or wrong user')
    if item.get('status') == 5:
        raise RuntimeError('process is a zombie')
    path = item.get('path')
    if not path or os.path.realpath(path) != expected:
        raise RuntimeError('process executable does not match')
    sec, usec = item.get('start_sec'), item.get('start_usec')
    if type(sec) is not int or sec <= 0 or type(usec) is not int or not 0 <= usec < 1_000_000:
        raise RuntimeError('process start time unavailable')
    return (pid, item['uid'], sec, usec, os.path.realpath(path))


def stop_listener(child):
    """Stop and reap only our own Popen child, even on an error."""
    if child.poll() is None:
        try:
            child.send_signal(signal.SIGINT)
        except ProcessLookupError:
            pass
    try:
        return child.wait(timeout=3)
    except subprocess.TimeoutExpired:
        try:
            child.terminate()
        except ProcessLookupError:
            pass
        try:
            return child.wait(timeout=3)
        except subprocess.TimeoutExpired:
            try:
                child.kill()
            except ProcessLookupError:
                pass
            return child.wait(timeout=3)


def run_capture(pid, expected, duration, output, *, inspector=None, popen=subprocess.Popen,
                selector_factory=selectors.DefaultSelector, monotonic=time.monotonic, read=os.read):
    """Output directory already created exclusively; never controls the target."""
    receipt = {'status': 'inconclusive', 'reason': 'collection incomplete', 'metricAnalysis': 'not_run',
               'pid': pid, 'expectedExecutable': expected, 'durationRequestedSeconds': duration,
               'rawBytes': 0, 'jsonObjects': 0, 'listenerExit': None, 'transport': 'incomplete'}
    child = None
    selector = None
    baseline = None
    listener_stopped = False
    started = monotonic()
    interrupted = False
    def interrupt(signum, _frame):
        raise KeyboardInterrupt(f'signal {signum}')
    previous = {s: signal.signal(s, interrupt) for s in (signal.SIGINT, signal.SIGTERM)}
    try:
        if inspector is None:
            inspector = Inspector()
        baseline = identity(inspector, pid, expected)
        receipt['targetStart'] = {'seconds': baseline[2], 'microseconds': baseline[3]}
        child = popen([TOOL, 'listen', '--json', '--interval', '1', '--pid', str(pid)],
                      stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                      start_new_session=True)
        selector = selector_factory()
        selector.register(child.stdout, selectors.EVENT_READ)
        framer = JSONFramer(pid)
        next_check = started
        with (output / 'raw.ndjson').open('xb') as raw:
            def consume(data):
                if receipt['rawBytes'] + len(data) > MAX_BYTES:
                    raise RuntimeError('raw output limit exceeded')
                raw.write(data)
                receipt['rawBytes'] += len(data)
                framer.feed(data)
                receipt['jsonObjects'] = framer.count
            while monotonic() - started < duration:
                now = monotonic()
                if now >= next_check:
                    if identity(inspector, pid, expected) != baseline:
                        raise RuntimeError('target process changed')
                    next_check = now + CHECK_SECONDS
                if child.poll() is not None:
                    raise RuntimeError('listener exited before requested duration')
                wait = max(0, min(0.25, duration - (monotonic() - started)))
                for key, _ in selector.select(wait):
                    data = read(key.fd, 65536)
                    if not data:
                        raise RuntimeError('listener output closed early')
                    consume(data)
            if identity(inspector, pid, expected) != baseline:
                raise RuntimeError('target process changed')
            receipt['listenerExit'] = stop_listener(child)
            listener_stopped = True
            if receipt['listenerExit'] not in (0, -signal.SIGINT, -signal.SIGTERM):
                raise RuntimeError('listener did not exit cleanly')
            # Drain bytes already buffered by the stopped child, without waiting indefinitely.
            while selector.select(0):
                tail = read(child.stdout.fileno(), 65536)
                if not tail:
                    break
                consume(tail)
            framer.feed(b'', final=True)
            if receipt['jsonObjects'] == 0:
                raise RuntimeError('no JSON observations')
            receipt['transport'] = 'complete'
    except (Exception, KeyboardInterrupt) as exc:
        interrupted = isinstance(exc, KeyboardInterrupt)
        receipt['reason'] = str(exc) or type(exc).__name__
    finally:
        if selector is not None:
            selector.close()
        if child is not None and not listener_stopped:
            try:
                receipt['listenerExit'] = stop_listener(child)
            except Exception as exc:
                receipt['reason'] = 'listener cleanup failed: ' + type(exc).__name__
                receipt['transport'] = 'incomplete'
        if child is not None and child.stdout is not None:
            child.stdout.close()
        if baseline is not None:
            try:
                if identity(inspector, pid, expected) != baseline:
                    receipt['reason'] = 'target process changed after collection'
                    receipt['transport'] = 'incomplete'
            except Exception as exc:
                receipt['reason'] = 'target identity unavailable after collection: ' + str(exc)
                receipt['transport'] = 'incomplete'
        if receipt['transport'] == 'complete':
            receipt['status'] = 'captured'
            receipt['reason'] = None
        for sig, handler in previous.items():
            signal.signal(sig, handler)
        receipt['elapsedSeconds'] = round(monotonic() - started, 3)
        receipt['interrupted'] = interrupted
        with (output / 'receipt.json').open('x', encoding='utf-8') as f:
            json.dump(receipt, f, indent=2, sort_keys=True)
            f.write('\n')
    return receipt


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--expected-executable', type=Path, required=True)
    parser.add_argument('--duration', type=int, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.pid <= 0 or not 1 <= args.duration <= 60:
        parser.error('pid must be positive and duration must be 1–60 seconds')
    expected = args.expected_executable
    if not expected.is_absolute() or expected.is_symlink() or not expected.is_file():
        parser.error('expected executable must be an existing absolute regular file')
    expected = os.path.realpath(expected)
    output = args.output
    if not output.is_absolute() or output.name in ('', '.', '..'):
        parser.error('output must be an absolute new directory')
    output.mkdir(mode=0o700, parents=False, exist_ok=False)
    os.chmod(output, stat.S_IRWXU)
    result = run_capture(args.pid, expected, args.duration, output)
    print(json.dumps(result, sort_keys=True), flush=True)
    return 0 if result['status'] == 'captured' else 1


if __name__ == '__main__':
    raise SystemExit(main())
