import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
import sys
sys.path.insert(0, str(ROOT / 'scripts'))
spec = importlib.util.spec_from_file_location('capture', ROOT / 'scripts/metal_performance_capture.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class Clock:
    def __init__(self): self.t = 0
    def __call__(self): self.t += .1; return self.t


class Inspector:
    def __init__(self, items=None):
        self.items = list(items or [])
    def identity(self, pid):
        return self.items.pop(0) if self.items else item(pid)


def item(pid, start=10, path='/fake/wine'):
    return {'pid': pid, 'uid': os.geteuid(), 'start_sec': start, 'start_usec': 1,
            'path': path, 'status': 1}


class Child:
    def __init__(self):
        self.stdout = type('Stream', (), {'close': lambda s: None})()
        self.calls = []
        self.done = False
    def poll(self): return 0 if self.done else None
    def send_signal(self, sig): self.calls.append(('signal', sig)); self.done = True
    def wait(self, timeout): self.calls.append(('wait', timeout)); return 0
    def terminate(self): self.calls.append(('terminate',)); self.done = True
    def kill(self): self.calls.append(('kill',)); self.done = True


class Selector:
    def __init__(self): self.values = [b'{"PID":123}\n']; self.closed = False
    def register(self, stream, mask): pass
    def select(self, timeout): return [(type('Key', (), {'fd': 3})(), None)] if self.values else []
    def close(self): self.closed = True


class Tests(unittest.TestCase):
    def run_case(self, inspector, payload=b'{"PID":123}\n'):
        with tempfile.TemporaryDirectory() as td:
            child, sel, clock = Child(), Selector(), Clock()
            sel.values = [payload]
            args = []
            def popen(argv, **kwargs):
                args.append(argv)
                return child
            def read(fd, size): return sel.values.pop(0)
            result = m.run_capture(123, '/fake/wine', 2, Path(td), inspector=inspector,
                                   popen=popen, selector_factory=lambda: sel, monotonic=clock, read=read)
            receipt = json.loads((Path(td)/'receipt.json').read_text())
            self.assertEqual(result, receipt)
            return result, child, sel, args

    def test_lifecycle_reports_transport_only(self):
        result, child, sel, args = self.run_case(Inspector())
        self.assertEqual(args[0], [m.TOOL, 'listen', '--json', '--interval', '1', '--pid', '123'])
        self.assertEqual(result['status'], 'captured')
        self.assertEqual(result['metricAnalysis'], 'not_run')
        self.assertIsNone(result['reason'])
        self.assertEqual(result['jsonObjects'], 1)
        self.assertIn(('signal', m.signal.SIGINT), child.calls)
        self.assertTrue(sel.closed)

    def test_identity_change_stops_and_reaps(self):
        result, child, _, _ = self.run_case(Inspector([item(123), item(123, start=11)]))
        self.assertIn('changed', result['reason'])
        self.assertTrue(child.done)
        self.assertTrue(any(c[0] == 'wait' for c in child.calls))

    def test_invalid_output_stops_and_reaps(self):
        result, child, _, _ = self.run_case(Inspector(), b'not-json\n')
        self.assertEqual(result['reason'], 'incomplete or invalid JSON output')
        self.assertTrue(child.done)

    def test_output_limit_stops_and_reaps(self):
        with mock.patch.object(m, 'MAX_BYTES', 4):
            result, child, _, _ = self.run_case(Inspector(), b'{"PID":123}\n')
        self.assertEqual(result['reason'], 'raw output limit exceeded')
        self.assertTrue(child.done)

    def test_pretty_chunks_and_concatenated_objects(self):
        f = m.JSONFramer(123)
        for data in (b'{\n "PID":', b'123, "Process":"w', b'ine"\n}\n {"PID":', b'123}', b'\n'):
            f.feed(data)
        f.feed(b'', final=True)
        self.assertEqual(f.count, 2)

    def test_partial_final_and_wrong_pid(self):
        f = m.JSONFramer(123); f.feed(b'{"PID":')
        with self.assertRaisesRegex(ValueError, 'incomplete'): f.feed(b'', final=True)
        with self.assertRaisesRegex(ValueError, 'PID'): m.JSONFramer(123).feed(b'{"PID":124}')
        with self.assertRaisesRegex(ValueError, 'PID'): m.JSONFramer(123).feed(b'{"PID":true}')

    def test_duplicate_keys_nan_and_nonobject_rejected(self):
        for payload, message in [(b'{"PID":123,"PID":123}', 'duplicate'),
                                 (b'{"PID":123,"x":NaN}', 'non-finite'),
                                 (b'{"PID":123,"x":1e999}', 'non-finite'),
                                 (b'[]', 'structure')]:
            with self.subTest(payload=payload):
                with self.assertRaisesRegex(ValueError, message):
                    m.JSONFramer(123).feed(payload)

    def test_post_collection_identity_change_is_inconclusive(self):
        inspector = Inspector()
        calls = 0
        def read_identity(pid):
            nonlocal calls
            calls += 1
            return item(pid, start=11 if calls >= 4 else 10)
        inspector.identity = read_identity
        result, child, _, _ = self.run_case(inspector)
        self.assertEqual(result['status'], 'inconclusive')
        self.assertIn('target', result['reason'])
        self.assertTrue(child.done)

    def test_bad_identity_never_starts_listener(self):
        result, child, _, args = self.run_case(Inspector([item(123, path='/wrong')]))
        self.assertIn('does not match', result['reason'])
        self.assertEqual(args, [])
        self.assertEqual(child.calls, [])

    def test_timeout_escalates_only_listener(self):
        child = Child()
        def wait(timeout):
            child.calls.append(('wait', timeout))
            if len([x for x in child.calls if x[0] == 'wait']) < 3:
                raise m.subprocess.TimeoutExpired('listener', timeout)
            return -9
        child.wait = wait
        self.assertEqual(m.stop_listener(child), -9)
        self.assertTrue(any(c[0] == 'terminate' for c in child.calls))
        self.assertTrue(any(c[0] == 'kill' for c in child.calls))

    def test_cli_exit_reports_capture_not_metric_validation(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            executable = root/'wine'
            executable.write_text('fixture')
            args = ['capture', '--pid', '123', '--expected-executable', str(executable),
                    '--duration', '2', '--output', str(root/'out')]
            with mock.patch.object(sys, 'argv', args), mock.patch.object(
                    m, 'run_capture', return_value={'status': 'captured', 'metricAnalysis':'not_run'}), mock.patch('builtins.print'):
                self.assertEqual(m.main(), 0)


if __name__ == '__main__':
    unittest.main()
