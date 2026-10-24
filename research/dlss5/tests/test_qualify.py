"""Tiny synthetic buffers exercise interop and rejection; no model is imported."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

MODULE = Path(__file__).resolve().parents[1] / "qualify.py"
spec = importlib.util.spec_from_file_location("qualify", MODULE)
q = importlib.util.module_from_spec(spec)
spec.loader.exec_module(q)


class QualificationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="playmelt-dlss5-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.capture = self.root / "capture"
        self.capture.mkdir()
        self.source = self.root / "source"
        self.source.mkdir()
        self.bundle = self.root / "prepared"
        self.candidate = self.root / "candidate"

    def fixture(self, resets=(True, False, True)):
        m = {
            "schemaVersion": 1, "width": 2, "height": 1,
            "colorEncoding": "display-srgb-unit", "depthInverted": False,
            "motion": {"convention": "pixel-current-to-previous", "jitterIncluded": False, "scale": [-2, 1]},
            "controls": {"intensity": 1.0, "styleIndex": 0, "localTone": 1.0,
                         "localStructure": 1.0, "skinStructure": -1.0,
                         "autoMask": False, "modelSlot": 0},
            "identity": {"runtimeVersion": "310.9.16.0", "runtimeSHA256": "0"*64,
                         "network": "small31", "weightsSHA256": "1"*64},
            "provenance": {"kind": "synthetic-fixture", "rightsReview": "not-reviewed",
                           "referenceDescription": "Generated tiny buffers, no NVIDIA output."},
            "frames": []}
        values = {"color": [0.25, 0.5, 0.75, 1.0, 0.75, 0.5, 0.25, 0.5],
                  "motion": [-0.5, 0.25, 0.5, -0.25], "depth": [0.5, 1.0],
                  "output": [0.25, 0.5, 0.75, 0.75, 0.5, 0.25]}
        formats = {"color": "rgba32f-le", "motion": "rg32f-le", "depth": "r32f-le", "output": "rgb32f-le"}
        noise_index = 0
        for index, reset in enumerate(resets):
            if reset: noise_index = 0
            f = {"index": index, "timestampNanoseconds": index*16666667,
                 "reset": reset, "noiseFrameIndex": noise_index, "jitterDeltaPixels": [0.25, -0.125]}
            noise_index += 1
            for role in q.ROLES:
                raw = struct.pack("<" + "f"*len(values[role]), *values[role]) + b"PAD!"
                name = f"{role}-{index}.raw"
                (self.capture/name).write_bytes(raw)
                f[role] = {"file": name, "format": formats[role], "rowBytes": len(raw),
                           "sha256": hashlib.sha256(raw).hexdigest()}
            m["frames"].append(f)
        self.save(m)
        return m

    def save(self, m):
        (self.capture / "capture.json").write_text(json.dumps(m))

    def prepare(self):
        # Unit fixture doesn't pretend to be the source checkout; source pin gets a separate test.
        with patch.object(q, "inspect_source", return_value={"syntheticSourceFixture": True}):
            return q.prepare(self.capture, self.bundle, self.source, self.root/"model-not-read", self.candidate)

    def candidate_outputs(self):
        plan = q.read_json(self.bundle / "planned-run.json")
        for record in plan["outputs"]:
            dst = self.candidate / record["candidate"]
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_bytes((self.bundle/f"output-{record['index']:06d}.f32").read_bytes())

    def test_rgba_stride_motion_sign_jitter_and_reset_segments(self):
        self.fixture()
        result = self.prepare()
        self.assertEqual(result["segments"], 2)
        self.assertEqual(struct.unpack("<6f", (self.bundle/"color-000000.f32").read_bytes()),
                         (0.25, 0.5, 0.75, 0.75, 0.5, 0.25))
        # width2: (-.5 * -2 + .25)/2 = .625; y: (.25 - .125)/1 = .125.
        self.assertEqual(struct.unpack("<4f", (self.bundle/"motion-000000.f32").read_bytes()),
                         (0.625, 0.125, -0.375, -0.375))
        plan = q.read_json(self.bundle/"planned-run.json")
        self.assertEqual([c["frameIndices"] for c in plan["commands"]], [[0, 1], [2]])
        self.assertEqual([c["noiseFrameIndices"] for c in plan["commands"]], [[0, 1], [0]])
        self.assertEqual(plan["outputs"][2]["candidate"], "segment-0001/000000.f32")
        args = plan["commands"][0]["argv"]
        self.assertEqual(args[args.index("--motion-format")+1], "normalized-uv")
        self.assertEqual(args[args.index("--local-structure")+1], "1.0")
        self.assertFalse(plan["inferenceExecuted"])
        self.assertFalse((self.root/"model-not-read").exists())

    def test_jitter_not_multiplied_by_signed_motion_scale(self):
        self.assertEqual(q.pixel_to_uv(0, 0, [-2, 7], [1, -1], 2, 2), (0.5, -0.5))
        self.assertEqual(q.pixel_to_uv(-0.5, 0, [-2, 1], [0, 0], 2, 2), (0.5, 0.0))

    def test_normalized_motion_is_not_scaled_again(self):
        m = self.fixture(resets=(True, False))
        m["motion"] = {"convention": "normalized-history-uv-offset", "jitterIncluded": True}
        for f in m["frames"]: f["jitterDeltaPixels"] = [0, 0]
        self.save(m); self.prepare()
        self.assertEqual(struct.unpack("<4f", (self.bundle/"motion-000000.f32").read_bytes()),
                         (-0.5, 0.25, 0.5, -0.25))

    def test_vendor_global_noise_counter_cannot_be_silently_reset(self):
        for frame_index, noise_index in [(0, 42), (1, 0), (2, 2)]:
            m = self.fixture()
            m["frames"][frame_index]["noiseFrameIndex"] = noise_index
            self.save(m)
            with self.assertRaisesRegex(q.Invalid, "noiseFrameIndex"):
                self.prepare()
        m = self.fixture(); del m["frames"][0]["noiseFrameIndex"]; self.save(m)
        with self.assertRaisesRegex(q.Invalid, "missing fields"): self.prepare()

    def test_hash_failure_does_not_publish_partial_buffers(self):
        m = self.fixture()
        m["frames"][1]["motion"]["sha256"] = "f"*64; self.save(m)
        with self.assertRaisesRegex(q.Invalid, "SHA-256 mismatch"): self.prepare()
        self.assertFalse(self.bundle.exists())
        self.assertFalse(list(self.root.glob(".dlss5-prepare-*")))

    def test_synthetic_equality_never_proves_vendor_parity(self):
        self.fixture(); self.prepare(); self.candidate_outputs()
        report = q.compare(self.bundle, self.candidate, 0, 0)
        self.assertTrue(report["numericThresholdsPassed"])
        self.assertFalse(report["vendor_runtime_parity_verified"])
        self.assertEqual(report["evidenceKind"], "synthetic-fixture")

    def test_one_bad_frame_cannot_hide_behind_average(self):
        self.fixture(); self.prepare(); self.candidate_outputs()
        p = self.candidate/"segment-0000/000001.f32"
        b = bytearray(p.read_bytes()); struct.pack_into("<f", b, 0, 0.5); p.write_bytes(b)
        r = q.compare(self.bundle, self.candidate, 0.1, 0.1)
        self.assertFalse(r["numericThresholdsPassed"])
        self.assertFalse(r["frames"][1]["withinThresholds"])

    def test_source_hash_drift_is_rejected_without_running_source(self):
        lock = q.read_json(q.LOCK)
        for file in lock["mlx"]["files"]:
            p = self.source/file; p.parent.mkdir(parents=True, exist_ok=True); p.write_text("raise SystemExit('never execute')")
        with self.assertRaisesRegex(q.Invalid, "source drift"):
            q.inspect_source(self.source)

    def test_nan_and_hash_mismatch_roll_back_only_staging(self):
        m = self.fixture()
        p = self.capture/m["frames"][0]["color"]["file"]
        b = bytearray(p.read_bytes()); struct.pack_into("<f", b, 0, float("nan")); p.write_bytes(b)
        m["frames"][0]["color"]["sha256"] = hashlib.sha256(b).hexdigest(); self.save(m)
        with self.assertRaisesRegex(q.Invalid, "non-finite"):
            self.prepare()
        self.assertFalse(self.bundle.exists())
        self.assertFalse(list(self.root.glob(".dlss5-prepare-*")))
        self.assertTrue(p.exists())

    def test_path_traversal_symlink_and_existing_destination_are_rejected(self):
        m = self.fixture()
        m["frames"][0]["color"]["file"] = "../private.raw"; self.save(m)
        with self.assertRaisesRegex(q.Invalid, "flat filenames"):
            self.prepare()
        m = self.fixture()
        p = self.capture/m["frames"][0]["color"]["file"]
        original = p.read_bytes(); p.unlink(); target = self.root/"private.raw"; target.write_bytes(original); p.symlink_to(target)
        with self.assertRaises(OSError): self.prepare()
        p.unlink(); p.write_bytes(original)
        self.bundle.mkdir(); sentinel = self.bundle/"user.txt"; sentinel.write_text("keep")
        with self.assertRaisesRegex(q.Invalid, "destination already exists"): self.prepare()
        self.assertEqual(sentinel.read_text(), "keep")

    def test_rejects_unreviewed_semantics(self):
        for mutate in [lambda m: m["identity"].update(runtimeVersion="future"),
                       lambda m: m["controls"].update(modelSlot=2),
                       lambda m: m["motion"].update(jitterIncluded=True),
                       lambda m: m.update(colorEncoding="linear-hdr"),
                       lambda m: m["frames"][0].update(reset=False),
                       lambda m: m["frames"][0].update(controlMask="not-implemented")]:
            m = self.fixture(); mutate(m); self.save(m)
            with self.assertRaises(q.Invalid): self.prepare()

    def test_fifo_is_rejected_without_waiting_for_a_writer(self):
        p = self.capture / "pipe.raw"
        os.mkfifo(p)
        with self.assertRaisesRegex(q.Invalid, "regular file"):
            q.regular(p)

    def test_budget_and_candidate_nan_fail_closed(self):
        self.fixture()
        with patch.object(q, "LIMIT", 10):
            with self.assertRaisesRegex(q.Invalid, "budget"): self.prepare()
        self.prepare(); self.candidate_outputs()
        p = self.candidate/"segment-0000/000000.f32"
        b = bytearray(p.read_bytes()); struct.pack_into("<f", b, 0, float("nan")); p.write_bytes(b)
        with self.assertRaisesRegex(q.Invalid, "non-finite comparison"):
            q.compare(self.bundle, self.candidate, 1, 1)

    def test_prepared_buffers_are_accepted_by_actual_pinned_upstream_cpu_validator(self):
        source = MODULE.parents[3] / "MLX-DLSS"
        if not source.is_dir():
            self.skipTest("existing sibling MLX-DLSS checkout is unavailable")
        q.inspect_source(source)
        self.fixture(); self.prepare()
        def load(name, file):
            spec = importlib.util.spec_from_file_location(name, source/"Tools"/file)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            return module
        # These pinned CPU-only tools import stdlib, never an inference backend.
        f32 = load("compare_f32", "compare_f32.py")
        with patch.dict(sys.modules, {"compare_f32": f32}):
            golden = load("upstream_golden", "compare_neural_rendering_golden_bundle.py")
            height, width, convention, frames, jitter = golden._validated_frames(self.bundle)
            self.assertEqual((height, width, convention, len(frames)),
                             (1, 2, "normalized-history-uv-offset", 3))
            self.assertEqual(jitter, [[0.0, 0.0]] * 3)


if __name__ == "__main__":
    unittest.main()
