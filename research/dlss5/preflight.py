#!/usr/bin/env python3
"""Check declared model topology and reported run parameters, without weight/model execution."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
import types

import qualify as q

ARCHITECTURES = {"mlxdlss.neural-rendering-transformer.v1", "nrk.neural-rendering-transformer.v1"}
SUMMARY_BUDGET = 8 * 1024 * 1024


def json_evidence(path):
    with q.regular(path, q.MAX_JSON) as handle:
        data = handle.read(q.MAX_JSON + 1)
    q.require(len(data) <= q.MAX_JSON, "JSON exceeded inspection budget")
    def invalid_constant(value):
        raise q.Invalid("non-finite JSON")
    return json.loads(data, object_pairs_hook=q.no_duplicate_keys, parse_constant=invalid_constant), hashlib.sha256(data).hexdigest(), len(data)


def typed_equal(actual, expected):
    if type(actual) is not type(expected): return False
    if isinstance(expected, list):
        return len(actual) == len(expected) and all(typed_equal(a, b) for a, b in zip(actual, expected))
    if isinstance(expected, dict):
        return actual.keys() == expected.keys() and all(typed_equal(actual[k], v) for k, v in expected.items())
    return actual == expected


def pinned_topology(source):
    """Execute only the exact reviewed, stdlib-only topology module; never import mlxdlss."""
    source = q.bounded_root(source)
    proof = q.inspect_source(source)
    lock = q.read_json(q.LOCK)
    verified, topology_bytes = {}, None
    for name, expected in lock["mlx"]["preflightFiles"].items():
        path = source / name
        q.bounded_root(path.parent)
        with q.regular(path, q.MAX_JSON) as handle:
            data = handle.read(q.MAX_JSON + 1)
        q.require(len(data) <= q.MAX_JSON, "source exceeded inspection budget")
        actual = hashlib.sha256(data).hexdigest()
        q.require(actual == expected, "preflight source drift: " + name)
        verified[name] = actual
        if name == "python/mlxdlss/topology.py":
            topology_bytes = data
    q.require(topology_bytes is not None, "topology source is not locked")
    name = "_playmelt_pinned_dlss_topology"
    module = types.ModuleType(name)
    previous = sys.modules.get(name)
    sys.modules[name] = module  # dataclasses resolves its module during definition.
    try:
        exec(compile(topology_bytes, "pinned-mlxdlss-topology.py", "exec"), module.__dict__)
    finally:
        if previous is None:
            sys.modules.pop(name, None)
        else:
            sys.modules[name] = previous
    proof["preflightSourceFilesVerified"] = verified
    return module, proof


def inspect_manifest(path, expected_identity, topology):
    path = Path(path).absolute()
    q.bounded_root(path.parent)
    q.require(path.name == "manifest.json", "supply only the package's manifest.json, never a weight file")
    manifest, manifest_digest, _ = json_evidence(path)
    q.fields(manifest, ("schemaVersion", "identifier", "architecture", "inputs", "outputs", "state", "weights"))
    q.require(type(manifest["schemaVersion"]) is int and manifest["schemaVersion"] == 1, "unsupported model manifest")
    q.require(isinstance(manifest["identifier"], str) and 0 < len(manifest["identifier"]) <= 512, "invalid model identifier")
    q.require(isinstance(manifest["architecture"], str) and manifest["architecture"] in ARCHITECTURES, "not a reviewed neural-rendering transformer architecture")
    for field, channels in (("inputs", 16), ("outputs", 4)):
        # Contract produced by the pinned package tool, prior to RGB postprocessing.
        q.require(typed_equal(manifest[field], [{"name": "color", "dataType": "float32", "layout": "nhwc", "shape": [1, "height", "width", channels]}]),
                  "unexpected network " + field + " contract")
    state = manifest["state"]
    q.fields(state, ("kind",), ("cadence", "resetPolicy", "tensors"))
    q.require(state["kind"] == "stateless" and state.get("cadence", "frameIndependent") == "frameIndependent" and
              state.get("resetPolicy", "explicit") == "explicit" and state.get("tensors", []) == [],
              "the network head must be stateless; temporal history belongs to the wrapper")
    weights = manifest["weights"]
    q.fields(weights, ("file", "sha256", "tensors"))
    q.flat_file(path.parent, weights["file"])  # Validate spelling only. Never stat/open weights.
    expected_digest = q.digest(expected_identity["weightsSHA256"])
    q.require(q.digest(weights["sha256"]) == expected_digest, "declared weight digest differs from capture identity")
    tensors = weights["tensors"]
    q.require(isinstance(tensors, list) and 0 < len(tensors) <= 10_000, "invalid tensor metadata count")
    shapes = {}
    for tensor in tensors:
        q.fields(tensor, ("name", "dataType", "shape"))
        name, shape = tensor["name"], tensor["shape"]
        q.require(isinstance(name, str) and 0 < len(name) <= 512 and name not in shapes, "invalid/duplicate tensor name")
        match = re.match(r"block([0-9]+)\.", name)
        q.require(match is not None and int(match[1]) < 128, "unreviewed tensor name/block range")
        q.require(tensor["dataType"] in ("float16", "float32"), "unsupported declared tensor dtype")
        q.require(isinstance(shape, list) and 0 < len(shape) <= 8 and
                  all(type(n) is int and 0 < n <= 1_048_576 for n in shape), "invalid declared tensor shape")
        shapes[name] = shape
    count = topology.block_count(shapes)
    families = [topology.classify_logical_block(shapes, i) for i in range(count)]
    # Python upstream accepts partial fixtures through a preset fallback. Swift
    # execution requires a complete mirrored layout; do not use that permissive path.
    q.require(all(family is not None for family in families), "incomplete block-family inventory; preset fallback is not qualification")
    declared = topology.infer_from_families(families)
    network = {"ht": "ht71", "small": "small31"}.get(declared.name)
    q.require(network is not None and network == expected_identity["network"], "declared topology differs from captured network")
    q.require(network in q.read_json(q.LOCK)["knownNetworks"].get(expected_identity["runtimeVersion"], []), "unreviewed runtime/network pairing")
    # The digest and parsed declarations came from the same bounded read.
    return {"identifier": manifest["identifier"], "architecture": manifest["architecture"],
            "manifestSHA256": manifest_digest, "network": network, "blockCount": count,
            "stageDepths": list(declared.depths), "globalBlocks": declared.global_blocks,
            "declaredWeightSHA256": weights["sha256"], "declaredTensorCount": len(tensors),
            "allBlockFamiliesClassified": True, "fullTensorInventoryValidated": False,
            "weightBytesRead": False, "weightBytesVerified": False}


def prepared_contract(bundle):
    evidence = q.read_json(bundle / "qualification.json")
    capture = evidence["capture"]
    q.fields(capture, ("schemaVersion", "width", "height", "colorEncoding", "depthInverted", "motion", "controls", "identity", "provenance", "frames"))
    q.require(type(capture["schemaVersion"]) is int and capture["schemaVersion"] == 1, "unsupported capture")
    q.integer(capture["width"]); q.integer(capture["height"])
    q.require(capture["colorEncoding"] == "display-srgb-unit" and type(capture["depthInverted"]) is bool, "unsupported color/depth declaration")
    identity = capture["identity"]
    q.fields(identity, ("runtimeVersion", "runtimeSHA256", "network", "weightsSHA256"))
    q.digest(identity["runtimeSHA256"]); q.digest(identity["weightsSHA256"])
    controls = capture["controls"]
    q.fields(controls, ("intensity", "styleIndex", "localTone", "localStructure", "skinStructure", "autoMask", "modelSlot"))
    for key in ("intensity", "localTone", "localStructure", "skinStructure"):
        q.f32(q.number(controls[key]))
    q.require(type(controls["styleIndex"]) is int and 0 <= controls["styleIndex"] < 2**32, "invalid style")
    q.require(type(controls["autoMask"]) is bool and type(controls["modelSlot"]) is int and controls["modelSlot"] == 0, "unreviewed control mapping")
    frames = capture["frames"]
    q.require(isinstance(frames, list) and 0 < len(frames) <= 4096, "invalid frame count")
    local, previous_time = 0, -1
    for i, frame in enumerate(frames):
        q.require(type(frame["index"]) is int and frame["index"] == i and type(frame["reset"]) is bool and (i > 0 or frame["reset"]), "invalid reset sequence")
        if frame["reset"]: local = 0
        q.require(type(frame["noiseFrameIndex"]) is int and frame["noiseFrameIndex"] == local, "noise sequence differs from replay plan")
        q.require(type(frame["timestampNanoseconds"]) is int and previous_time < frame["timestampNanoseconds"] <= 2**63-1, "invalid frame time")
        previous_time = frame["timestampNanoseconds"]; local += 1
    return capture


def checked_plan(bundle, source, model_manifest, capture):
    plan = q.read_json(bundle / "planned-run.json")
    commands = plan["commands"]
    q.require(isinstance(commands, list) and 0 < len(commands) <= 4096, "invalid command count")
    args = commands[0]["argv"]
    q.require(isinstance(args, list) and all(isinstance(a, str) for a in args) and "--output-dir" in args, "invalid argv plan")
    index = args.index("--output-dir")
    q.require(index + 1 < len(args), "missing output directory")
    first_output = Path(args[index + 1])
    q.require(first_output.is_absolute() and first_output.name == "segment-0000", "unexpected segment directory")
    expected = q.run_plan(capture, source, bundle, model_manifest.parent, first_output.parent)
    q.require(typed_equal(plan, expected), "planned argv, model package or frame mapping differs from the captured contract")
    return plan


def check_summaries(directory, capture, plan):
    root = q.bounded_root(directory)
    files = [root / f"segment-{i:04d}.json" for i in range(len(plan["commands"]))]
    total = 0
    for path in files:
        with q.regular(path, q.MAX_JSON) as handle:
            total += q.os.fstat(handle.fileno()).st_size
        q.require(total <= SUMMARY_BUDGET, "run summaries exceed8MiB CPU budget")
    controls = capture["controls"]
    h, w = capture["height"], capture["width"]
    aligned = lambda value: max(320, ((value + 63) // 64) * 64)
    results, bytes_read = [], 0
    for i, (file, command) in enumerate(zip(files, plan["commands"])):
        summary, summary_digest, byte_count = json_evidence(file)
        bytes_read += byte_count
        q.require(bytes_read <= SUMMARY_BUDGET, "run summaries exceeded8MiB CPU budget while reading")
        args = command["argv"]
        expected = {"backend": "mlx-metal", "cadence": "consecutiveFrames", "frameCount": len(command["frameIndices"]),
                    "inputFormat": "rgb-temporal-reference", "motionFormat": "normalized-uv", "pipeline": "portable", "preprocessor": "cpu",
                    "shape": [1, h, w, 3], "networkShape": [1, aligned(h), aligned(w), 16], "computePrecision": "float32", "executionMode": "eager",
                    "networkGeometry": "vendor-aligned", "profile": "standard", "checkpointModelSelection": 0, "checkpointModel": "shipping-default",
                    "controlMask": "none", "styleIndex": controls["styleIndex"], "effectiveAutomaticMask": controls["autoMask"],
                    "outputDirectory": args[args.index("--output-dir") + 1]}
        q.fields(summary, (*expected, "intensity", "localToneStrength", "localStructureStrength", "executionNanoseconds", "endToEndNanoseconds"))
        for key, value in expected.items():
            q.require(typed_equal(summary[key], value), f"segment{i}: reported {key} differs from plan")
        for key, control in (("intensity", "intensity"), ("localToneStrength", "localTone"), ("localStructureStrength", "localStructure")):
            q.require(q.f32(q.number(summary[key])) == q.f32(q.number(controls[control])), f"segment{i}: reported {key} differs from capture")
        for key in ("executionNanoseconds", "endToEndNanoseconds"):
            q.require(type(summary[key]) is int and 0 <= summary[key] < 2**63, "invalid reported timing")
        # Timing is only validated, not presented as a measured performance result.
        results.append({"segment": i, "reportedParametersMatch": True, "summarySHA256": summary_digest,
                        "frameIndices": command["frameIndices"], "reportAuthenticated": False})
    return results


def preflight(manifest, bundle, source, summaries=None):
    source, bundle = q.bounded_root(source), q.bounded_root(bundle)
    manifest = Path(manifest).absolute()
    topology, source_proof = pinned_topology(source)
    capture = prepared_contract(bundle)
    model = inspect_manifest(manifest, capture["identity"], topology)
    plan = checked_plan(bundle, source, manifest, capture)
    reports = check_summaries(summaries, capture, plan) if summaries is not None else []
    return {"schemaVersion": 1, "declarationsConsistent": True, "model": model, "source": source_proof,
            "runSummariesChecked": summaries is not None, "runSummaries": reports,
            "unreportedParameters": ["skinStructure", "depthInverted", "noiseFrameIndex", "modelWeightDigest", "runtimeDLLIdentity"],
            "modelManifestRead": True, "weightBytesRead": False, "runtimeBytesRead": False,
            "runtimeIdentityVerified": False, "candidateIdentityVerified": False,
            "inferenceExecuted": False, "inferenceReady": False, "vendor_runtime_parity_verified": False,
            "scope": "Consistent declarations and reported settings only. No weight/runtime bytes, execution authenticity or NVIDIA parity verified."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("model_manifest", type=Path)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("source", type=Path)
    parser.add_argument("--run-summaries", type=Path)
    args = parser.parse_args()
    try:
        result = preflight(args.model_manifest, args.bundle, args.source, args.run_summaries)
        print(json.dumps(result, indent=2, allow_nan=False)); return 0
    except (q.Invalid, OSError, ValueError, KeyError, TypeError, IndexError) as error:
        print(json.dumps({"error": str(error), "declarationsConsistent": False, "inferenceExecuted": False,
                          "inferenceReady": False, "vendor_runtime_parity_verified": False})); return 1


if __name__ == "__main__":
    raise SystemExit(main())
