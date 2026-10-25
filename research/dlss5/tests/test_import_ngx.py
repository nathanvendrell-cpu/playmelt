"""Offline NGX trace interoperability; synthetic references never establish parity."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

MODULE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(MODULE))
import import_ngx as ngx
q = ngx.q


class NGXImportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="playmelt-ngx-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.trace = self.root / "trace"
        self.trace.mkdir()
        self.capture = self.root / "capture"
        self.bundle = self.root / "bundle"

    def fixture(self):
        trace = {
            "schemaVersion": 1, "api": "NVSDK_NGX_VK_DLSSNR_Eval_Params", "sourceCommit": ngx.REMIX_COMMIT,
            "creation": {"Width": 2, "Height": 1, ngx.PRESET_KEY: ngx.PRESET},
            "colorEncoding": "display-srgb-unit", "motionConvention": "pixel-current-to-previous",
            "motionJitterIncluded": False, "noiseCounterEvidence": "Synthetic explicit0,1,0; no vendor capture.",
            "identity": {"runtimeVersion": "310.9.16.0", "runtimeSHA256": "0"*64,
                         "network": "small31", "weightsSHA256": "1"*64},
            "provenance": {"kind": "synthetic-fixture", "rightsReview": "not-reviewed",
                           "referenceDescription": "Tiny CPU fixture, no NVIDIA output or model."}, "frames": []}
        # Literal IEEE754 binary16 values: .25,.5,.75,1 and .75,.5,.25,.5.
        rgba = bytes.fromhex("00340038003a003c003a003800340038") + b"PAD!"
        contents = {"color": ("VK_FORMAT_R16G16B16A16_SFLOAT", rgba),
                    "motion": ("VK_FORMAT_R16G16_SFLOAT", struct.pack("<4e", -.5, .25, .5, -.25) + b"PAD!"),
                    "depth": ("VK_FORMAT_R32_SFLOAT", struct.pack("<2f", .5, 1) + b"PAD!"),
                    "output": ("VK_FORMAT_R16G16B16A16_SFLOAT", rgba)}
        for i, (reset, jitter) in enumerate([(1, [.25, -.125]), (0, [-.25, .375]), (1, [.125, .125])]):
            p = {"InReset": reset, "InDepthInverted": 0, "InEnabled": 1, "InIntensity": 1,
                 "InLocalToneStrength": .3, "InLocalStructureStrength": .7,
                 "InMaskBlendMode": "NVSDK_NGX_DLSSNR_Mask_Blend_Mode_None", "InStyle": 2,
                 "InUseAutoMask": 0, "InSkinStructureStrength": 0, "InMVecScaleX": -2, "InMVecScaleY": 1,
                 ngx.JITTER_KEYS[0]: jitter[0], ngx.JITTER_KEYS[1]: jitter[1]}
            buffers = {"pInControlMask": None}
            for role, key in ngx.BUFFERS.items():
                p["In" + ngx.SUBRECTS[role] + "SubrectBase"] = [0, 0]
                p["In" + ngx.SUBRECTS[role] + "SubrectSize"] = [2, 1]
                fmt, raw = contents[role]
                name = f"{role}-{i}.raw"
                (self.trace/name).write_bytes(raw)
                buffers[key] = {"file": name, "sha256": hashlib.sha256(raw).hexdigest(), "format": fmt,
                                "rowBytes": len(raw), "width": 2, "height": 1}
            trace["frames"].append({"index": i, "timestampNanoseconds": i*16666667,
                                    "evaluationSucceeded": True, "noiseFrameIndex": 1 if i == 1 else 0,
                                    "parameters": p, "buffers": buffers})
        self.save(trace)
        return trace

    def save(self, trace):
        (self.trace/"ngx-trace.json").write_text(json.dumps(trace))

    def prepare(self, source=None):
        if source is not None:
            return q.prepare(self.capture, self.bundle, source, self.root/"absent-model", self.root/"not-run")
        with patch.object(q, "inspect_source", return_value={"syntheticSourceFixture": True}):
            return q.prepare(self.capture, self.bundle, self.root, self.root/"absent-model", self.root/"not-run")

    def test_half_float_stride_jitter_reset_and_style_are_real_buffer_conversions(self):
        self.fixture()
        result = ngx.import_trace(self.trace, self.capture)
        capture = q.capture_contract(self.capture)
        self.assertEqual(result["importedFrames"], 3)
        self.assertEqual([f["jitterDeltaPixels"] for f in capture["frames"]], [[0, 0], [.5, -.5], [0, 0]])
        self.assertEqual(capture["controls"]["styleIndex"], 2)  # StyleC is not presetB/index1.
        self.assertEqual(capture["controls"]["modelSlot"], 0)
        self.assertEqual(struct.unpack("<6f", (self.capture/"color-000000.f32").read_bytes()),
                         (.25, .5, .75, .75, .5, .25))
        self.prepare()
        self.assertEqual(struct.unpack("<4f", (self.bundle/"motion-000001.f32").read_bytes()),
                         (.75, -.25, -.25, -.75))
        self.assertEqual(struct.unpack("<4f", (self.bundle/"motion-000002.f32").read_bytes()),
                         (.5, .25, -.5, -.25))
        plan = q.read_json(self.bundle/"planned-run.json")
        self.assertEqual([c["frameIndices"] for c in plan["commands"]], [[0, 1], [2]])
        self.assertFalse(plan["inferenceExecuted"])
        self.assertFalse(q.read_json(self.capture/"import-receipt.json")["vendor_runtime_parity_verified"])
        self.assertFalse((self.root/"absent-model").exists())

    def test_current_jitter_rounds_to_float32_before_subtraction(self):
        trace = self.fixture()
        trace["frames"][0]["parameters"][ngx.JITTER_KEYS[0]] = 16777217
        trace["frames"][1]["parameters"][ngx.JITTER_KEYS[0]] = 16777216
        self.save(trace)
        _, capture = ngx.contract(self.trace)
        self.assertEqual(capture["frames"][1]["jitterDeltaPixels"][0], 0)

    def test_adapter_commit_matches_locked_source_and_has_no_inference_import(self):
        import ast
        lock = q.read_json(MODULE/"upstream-lock.json")
        self.assertEqual(ngx.REMIX_COMMIT, lock["ngxAdapterSource"]["commit"])
        tree = ast.parse((MODULE/"import_ngx.py").read_text())
        imports = {alias.name.split(".")[0] for node in ast.walk(tree) if isinstance(node, ast.Import) for alias in node.names}
        imports |= {node.module.split(".")[0] for node in ast.walk(tree) if isinstance(node, ast.ImportFrom) and node.module}
        self.assertFalse(imports & {"mlx", "torch", "tensorflow", "subprocess", "socket", "urllib", "requests"})

    def test_already_jittered_vectors_are_not_corrected_twice(self):
        trace = self.fixture(); trace["motionJitterIncluded"] = True; self.save(trace)
        ngx.import_trace(self.trace, self.capture)
        capture = q.capture_contract(self.capture)
        self.assertEqual([f["jitterDeltaPixels"] for f in capture["frames"]], [[0, 0]]*3)

    def test_resets_are_never_invented_to_hide_changed_controls(self):
        trace = self.fixture()
        for i in [1, 2]:
            changed = copy.deepcopy(trace)
            changed["frames"][i]["parameters"]["InIntensity"] = .5
            self.save(changed)
            with self.assertRaisesRegex(q.Invalid, "changing controls"):
                ngx.import_trace(self.trace, self.capture)
            self.assertFalse(self.capture.exists())

    def test_history_failures_unknown_noise_and_dropped_frames_are_rejected(self):
        trace = self.fixture()
        changes = [(0, "parameters", "InReset", 0), (1, None, "noiseFrameIndex", 42),
                   (1, None, "evaluationSucceeded", False), (1, None, "index", 2),
                   (1, None, "timestampNanoseconds", 0)]
        for i, group, key, value in changes:
            changed = copy.deepcopy(trace)
            target = changed["frames"][i]
            if group: target = target[group]
            target[key] = value; self.save(changed)
            with self.assertRaises(q.Invalid): ngx.import_trace(self.trace, self.capture)
        self.assertFalse(self.capture.exists())

    def test_hdr_unknown_fields_subrects_masks_and_different_guides_are_rejected(self):
        trace = self.fixture()
        variants = []
        hdr = copy.deepcopy(trace); hdr["colorEncoding"] = "linear-hdr"; variants.append(hdr)
        extra = copy.deepcopy(trace); extra["frames"][0]["parameters"]["InUnknown"] = 1; variants.append(extra)
        rect = copy.deepcopy(trace); rect["frames"][0]["parameters"]["InColorSubrectBase"] = [1, 0]; variants.append(rect)
        mask = copy.deepcopy(trace); mask["frames"][0]["buffers"]["pInControlMask"] = {}; variants.append(mask)
        guide = copy.deepcopy(trace); guide["frames"][0]["buffers"]["pInMVec"]["width"] = 1; variants.append(guide)
        preset = copy.deepcopy(trace); preset["creation"][ngx.PRESET_KEY] = "A"; variants.append(preset)
        for value in variants:
            self.save(value)
            with self.assertRaises(q.Invalid): ngx.import_trace(self.trace, self.capture)
        self.assertFalse(self.capture.exists())

    def test_nan_hdr_sample_and_hash_failure_clean_own_staging(self):
        trace = self.fixture()
        record = trace["frames"][0]["buffers"]["pInColor"]
        path = self.trace/record["file"]
        original = path.read_bytes()
        for half in (b"\x00\x7e", b"\x00\x40"):  # NaN and2.0: both invalid for declared SDR.
            data = half + original[2:]; path.write_bytes(data)
            record["sha256"] = hashlib.sha256(data).hexdigest(); self.save(trace)
            with self.assertRaises(q.Invalid): ngx.import_trace(self.trace, self.capture)
            self.assertFalse(self.capture.exists())
            self.assertEqual(list(self.root.glob(".dlss5-ngx-import-*")), [])
        path.write_bytes(original); self.save(trace)  # Keep last hash, now wrong.
        with self.assertRaisesRegex(q.Invalid, "SHA-256"): ngx.import_trace(self.trace, self.capture)

    def test_paths_existing_output_and_budget_are_preserved(self):
        trace = self.fixture()
        with patch.object(q, "LIMIT", 100):
            with self.assertRaisesRegex(q.Invalid, "budget"): ngx.import_trace(self.trace, self.capture)
        self.capture.mkdir(); (self.capture/"keep").write_text("existing")
        with self.assertRaisesRegex(q.Invalid, "destination already exists"): ngx.import_trace(self.trace, self.capture)
        self.assertEqual((self.capture/"keep").read_text(), "existing")
        trace["frames"][0]["buffers"]["pInColor"]["file"] = "../other"
        self.save(trace)
        with self.assertRaisesRegex(q.Invalid, "flat filenames"): ngx.contract(self.trace)

    def test_imported_and_prepared_buffers_pass_actual_upstream_cpu_validator(self):
        source = MODULE.parents[2] / "MLX-DLSS"
        if not source.is_dir():
            self.skipTest("existing sibling MLX-DLSS checkout is unavailable")
        self.fixture(); ngx.import_trace(self.trace, self.capture); self.prepare(source)
        def load(name, file):
            spec = importlib.util.spec_from_file_location(name, source/"Tools"/file)
            module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
            return module
        with patch.dict(sys.modules, {"compare_f32": load("compare_f32", "compare_f32.py")}):
            golden = load("ngx_upstream_golden", "compare_neural_rendering_golden_bundle.py")
            height, width, convention, frames, jitter = golden._validated_frames(self.bundle)
        self.assertEqual((height, width, convention, len(frames)), (1, 2, "normalized-history-uv-offset", 3))
        self.assertEqual(jitter, [[0, 0]]*3)


if __name__ == "__main__":
    unittest.main()
