"""Small CPU subprocess tests of exact task-owned group cleanup, including orphans."""
import subprocess
import sys
import unittest

sys.dont_write_bytecode = True
from run_cpu_probe import OWNED_GROUPS, bounded, group_exists


class ProbeLifecycleTests(unittest.TestCase):
    def tearDown(self):
        for group in OWNED_GROUPS:
            self.assertFalse(group_exists(group), f"owned group remains: {group}")

    def test_completed_parent(self):
        self.assertEqual(bounded([sys.executable, "-B", "-c", "print('ok')"], 3), b"ok\n")

    def test_failed_parent(self):
        with self.assertRaisesRegex(RuntimeError, "exited 7"):
            bounded([sys.executable, "-B", "-c", "raise SystemExit(7)"], 3)

    def test_timeout(self):
        with self.assertRaises(subprocess.TimeoutExpired):
            bounded([sys.executable, "-B", "-c", "import time; time.sleep(30)"], 0.15)

    def test_exited_parent_with_child_ignoring_term(self):
        # Readiness pipe ensures SIGTERM is ignored before the parent exits.
        # Child inherits only this newly-created group, never a user process.
        child = "import os,signal,sys,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); os.write(int(sys.argv[1]),b'1'); time.sleep(30)"
        parent = (
            "import os,subprocess,sys; r,w=os.pipe(); "
            f"subprocess.Popen([sys.executable,'-B','-c',{child!r},str(w)], "
            "pass_fds=(w,),stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); "
            "os.close(w); assert os.read(r,1)==b'1'; os.close(r)"
        )
        self.assertEqual(bounded([sys.executable, "-B", "-c", parent], 3), b"")


if __name__ == "__main__":
    unittest.main()
