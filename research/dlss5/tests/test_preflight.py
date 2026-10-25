"""Synthetic metadata only; no weight bytes, inference or runtime reference output."""
import copy
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

MODULE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(MODULE))
import preflight as p
q = p.q


def declared_tensors(depths=(2, 2, 2, 2, 2)):
    # Minimal classification markers, deliberately not a complete weight inventory.
    families = [("pre", 32)]
    for depth, channels in zip(depths[:4], [32, 64, 128, 256]):
        families += [("window", channels)] * (depth-1) + [("downsample", channels)]
    families += [("split", 512)] * (depths[4]-1) + [("split_transition", 512)]
    families += [("global", 1024)]*8 + [("bridge", 1024)] + [("split", 512)]*depths[4]
    for depth, channels in zip(reversed(depths[:4]), [256, 128, 64, 32]):
        families += [("upsample", channels)] + [("window", channels)]*(depth-1)
    families += [("post", 32)]
    result = []
    for index, (family, channels) in enumerate(families):
        shapes = {}
        if family in ("split", "split_transition"):
            shapes["layer0.first_projection_weight"] = [512, 1536]
            if family == "split_transition": shapes["layer4.weight"] = [512, 1024]
        elif family == "global": shapes["layer0.weight"] = [1024, 4096]
        elif family == "bridge": shapes["layer0.conv_weight"] = [1, 1, 1024, 512]
        else:
            shapes["layer0.qkv_weight"] = [channels, 3*channels]
            marker = {"pre": ("input_adapter_weight", [16, 32]), "post": ("inp_merge_sin", [1]),
                      "upsample": ("sin", [1]), "downsample": ("weight0", [channels, 2*channels])}.get(family)
            if marker: shapes["layer0."+marker[0]] = marker[1]
        for name, shape in shapes.items():
            result.append({"name": f"block{index}."+name, "dataType": "float16", "shape": shape})
    return result


class PreflightTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = MODULE.parents[2]/"MLX-DLSS"
        if not cls.source.is_dir(): raise unittest.SkipTest("existing pinned sibling MLX-DLSS source unavailable")
        cls.topology, cls.source_proof = p.pinned_topology(cls.source)

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="playmelt-dlss-preflight-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.package = self.root/"model.dlssmodel"; self.package.mkdir()
        self.manifest = self.package/"manifest.json"
        self.bundle = self.root/"bundle"; self.bundle.mkdir()
        self.summaries = self.root/"summaries"; self.summaries.mkdir()
        self.model = {"schemaVersion": 1, "identifier": "synthetic-fixture", "architecture": "mlxdlss.neural-rendering-transformer.v1",
                      "inputs": [{"name":"color", "dataType":"float32", "layout":"nhwc", "shape":[1,"height","width",16]}],
                      "outputs": [{"name":"color", "dataType":"float32", "layout":"nhwc", "shape":[1,"height","width",4]}],
                      "state":{"kind":"stateless"}, "weights":{"file":"weights.safetensors", "sha256":"1"*64, "tensors":declared_tensors()}}
        self.capture = {"schemaVersion":1, "width":2, "height":1, "colorEncoding":"display-srgb-unit", "depthInverted":False,
                        "motion":{"convention":"pixel-current-to-previous", "scale":[-2,1], "jitterIncluded":False},
                        "controls":{"intensity":.75, "styleIndex":2, "localTone":.3, "localStructure":.7, "skinStructure":0, "autoMask":False,"modelSlot":0},
                        "identity":{"runtimeVersion":"310.9.16.0", "runtimeSHA256":"0"*64, "network":"small31", "weightsSHA256":"1"*64},
                        "provenance":{"kind":"synthetic-fixture","rightsReview":"not-reviewed","referenceDescription":"Synthetic metadata only"},
                        "frames":[{"index":0,"reset":True,"timestampNanoseconds":0,"noiseFrameIndex":0},
                                  {"index":1,"reset":False,"timestampNanoseconds":1,"noiseFrameIndex":1},
                                  {"index":2,"reset":True,"timestampNanoseconds":2,"noiseFrameIndex":0}]}
        self.save()
        self.plan = q.run_plan(self.capture, self.source, self.bundle, self.package, self.root/"future-results")
        (self.bundle/"planned-run.json").write_text(json.dumps(self.plan))
        for index, command in enumerate(self.plan["commands"]):
            summary = {"backend":"mlx-metal", "cadence":"consecutiveFrames", "frameCount":len(command["frameIndices"]),
                       "inputFormat":"rgb-temporal-reference", "motionFormat":"normalized-uv", "pipeline":"portable", "preprocessor":"cpu",
                       "shape":[1,1,2,3], "networkShape":[1,320,320,16], "computePrecision":"float32", "executionMode":"eager",
                       "networkGeometry":"vendor-aligned", "profile":"standard", "checkpointModelSelection":0,"checkpointModel":"shipping-default",
                       "controlMask":"none", "styleIndex":2,"effectiveAutomaticMask":False,
                       "outputDirectory":str(self.root/"future-results"/f"segment-{index:04d}"),
                       "intensity":.75,"localToneStrength":q.f32(.3),"localStructureStrength":q.f32(.7),
                       "executionNanoseconds":1,"endToEndNanoseconds":2}
            (self.summaries/f"segment-{index:04d}.json").write_text(json.dumps(summary))

    def save(self):
        self.manifest.write_text(json.dumps(self.model))
        (self.bundle/"qualification.json").write_text(json.dumps({"capture":self.capture}))

    def run_preflight(self, summaries=True):
        return p.preflight(self.manifest, self.bundle, self.source, self.summaries if summaries else None)

    def test_small_topology_and_reports_match_but_never_establish_weight_or_runtime_identity(self):
        os.mkfifo(self.package/"weights.safetensors")  # Opening payload would block; it is not touched.
        result = self.run_preflight()
        self.assertEqual(result["model"]["blockCount"],31)
        self.assertEqual(result["model"]["stageDepths"],[2,2,2,2,2])
        self.assertEqual([r["frameIndices"] for r in result["runSummaries"]],[[0,1],[2]])
        for flag in ["weightBytesRead","runtimeBytesRead","runtimeIdentityVerified","candidateIdentityVerified","inferenceExecuted","inferenceReady","vendor_runtime_parity_verified"]:
            self.assertIs(result[flag],False)
        self.assertFalse(result["model"]["fullTensorInventoryValidated"])
        self.assertEqual(result["model"]["manifestSHA256"],hashlib.sha256(self.manifest.read_bytes()).hexdigest())
        self.assertIn("skinStructure",result["unreportedParameters"])

    def test_ht_and_small_cannot_share_declared_network_just_because_architecture_matches(self):
        self.model["weights"]["tensors"] = declared_tensors((4,4,6,8,8)); self.save()
        with self.assertRaisesRegex(q.Invalid,"topology differs"): self.run_preflight()
        self.capture["identity"]["network"] = "ht71"; self.save()
        result = self.run_preflight(False)
        self.assertEqual(result["model"]["blockCount"],71)
        self.assertFalse(result["runSummariesChecked"])

    def test_permissive_upstream_partial_fixture_fallback_is_rejected(self):
        tensors = [r for r in self.model["weights"]["tensors"] if r["name"].startswith(("block0.","block30."))]
        shapes = {r["name"]:r["shape"] for r in tensors}
        self.assertEqual(self.topology.infer_logical(shapes).name,"small")  # Upstream fixture fallback.
        self.model["weights"]["tensors"] = tensors; self.save()
        with self.assertRaisesRegex(q.Invalid,"incomplete block-family"): self.run_preflight()

    def test_broken_decoder_mirror_and_duplicate_tensor_fail(self):
        original = copy.deepcopy(self.model)
        target = next(r for r in self.model["weights"]["tensors"] if r["name"] == "block22.layer0.qkv_weight")
        target["shape"] = [128,384]; self.save()
        with self.assertRaises(ValueError): self.run_preflight()
        self.model = original; self.model["weights"]["tensors"].append(copy.deepcopy(self.model["weights"]["tensors"][0])); self.save()
        with self.assertRaisesRegex(q.Invalid,"duplicate"): self.run_preflight()

    def test_wrong_digest_architecture_state_and_boolean_shape_fail(self):
        original = copy.deepcopy(self.model)
        for mutate in [lambda m:m["weights"].update(sha256="2"*64),lambda m:m.update(architecture="mlxdlss.pixel-affine.v1"),
                       lambda m:m["state"].update(kind="recurrent"),lambda m:m["inputs"][0].update(shape=[True,"height","width",16])]:
            self.model = copy.deepcopy(original); mutate(self.model); self.save()
            with self.assertRaises(q.Invalid): self.run_preflight()

    def test_mismatched_reported_parameters_and_noisy_unknown_fields_fail(self):
        file = self.summaries/"segment-0000.json"; original = json.loads(file.read_text())
        for key,value in [("styleIndex",1),("frameCount",3),("cadence","frameIndependent"),("computePrecision","float16"),
                          ("effectiveAutomaticMask",True),("localToneStrength",.9),("networkShape",[1,1,2,16]),
                          ("shape",[True,1,2,3]),("madeUpProof",True)]:
            changed = dict(original); changed[key]=value; file.write_text(json.dumps(changed))
            with self.assertRaises(q.Invalid): self.run_preflight()
        file.write_text(json.dumps({k:v for k,v in original.items() if k!="styleIndex"}))
        with self.assertRaisesRegex(q.Invalid,"missing fields"): self.run_preflight()

    def test_wrong_package_path_or_changed_argv_is_not_a_matching_plan(self):
        original = copy.deepcopy(self.plan)
        for mutate in [lambda p:p["commands"][0]["argv"].__setitem__(2,"/different/model"),
                       lambda p:p["commands"][0]["argv"].append("--unknown-option"),
                       lambda p:p["outputs"][0].update(index=True)]:
            plan=copy.deepcopy(original); mutate(plan); (self.bundle/"planned-run.json").write_text(json.dumps(plan))
            with self.assertRaises(q.Invalid): self.run_preflight()

    def test_source_drift_is_rejected_before_cpu_module_execution(self):
        source=self.root/"source"; source.mkdir()
        for name in q.read_json(q.LOCK)["mlx"]["preflightFiles"]:
            file=source/name; file.parent.mkdir(parents=True,exist_ok=True)
            file.write_bytes((self.source/name).read_bytes())
        topology=source/"python/mlxdlss/topology.py"
        topology.write_text("raise RuntimeError('unreviewed module executed')")
        with patch.object(q,"inspect_source",return_value={}):
            with self.assertRaisesRegex(q.Invalid,"source drift"): p.pinned_topology(source)

    def test_symlink_unsafe_weight_name_and_summary_budget_fail(self):
        self.model["weights"]["file"]="../weights.safetensors"; self.save()
        with self.assertRaisesRegex(q.Invalid,"flat filenames"): self.run_preflight()
        self.model["weights"]["file"]="weights.safetensors"; self.save()
        with patch.object(p,"SUMMARY_BUDGET",1):
            with self.assertRaisesRegex(q.Invalid,"budget"): self.run_preflight()
        target=self.root/"manifest-copy.json"; target.write_bytes(self.manifest.read_bytes()); self.manifest.unlink(); self.manifest.symlink_to(target)
        with self.assertRaises(OSError): self.run_preflight()


if __name__ == "__main__":
    unittest.main()
