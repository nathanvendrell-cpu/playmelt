#!/usr/bin/env python3
"""Import an offline NGX evaluation trace; stdlib CPU only, never capture or infer."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import os
import shutil
import struct
import tempfile

import qualify as q

REMIX_COMMIT = "bbd74a1287c2fa887f4a2b0e46a1530177890b64"
PRESET = "NVSDK_NGX_DLSSNR_Hint_Render_Preset_B"
PRESET_KEY = "NVSDK_NGX_Parameter_DLSSNR_Hint_Render_Preset"
JITTER_KEYS = ("NVSDK_NGX_Parameter_Jitter_Offset_X", "NVSDK_NGX_Parameter_Jitter_Offset_Y")
BUFFERS = {"color": "pInColor", "motion": "pInMVec", "depth": "pInDepth", "output": "pInOutput"}
SUBRECTS = {"color": "Color", "motion": "MVec", "depth": "Depth", "output": "Output"}
FORMATS = {
    "VK_FORMAT_R16G16B16A16_SFLOAT": (4, 2, "e"),
    "VK_FORMAT_R32G32B32A32_SFLOAT": (4, 4, "f"),
    "VK_FORMAT_R16G16_SFLOAT": (2, 2, "e"),
    "VK_FORMAT_R32G32_SFLOAT": (2, 4, "f"),
    "VK_FORMAT_R32_SFLOAT": (1, 4, "f"),
}
PARAMS = ("InReset", "InDepthInverted", "InEnabled", "InIntensity", "InLocalToneStrength",
          "InLocalStructureStrength", "InMaskBlendMode", "InStyle", "InUseAutoMask",
          "InSkinStructureStrength", "InMVecScaleX", "InMVecScaleY", *JITTER_KEYS,
          *("In" + name + suffix for name in SUBRECTS.values() for suffix in ("SubrectBase", "SubrectSize")))


def bit(value):
    q.require(type(value) is int and value in (0, 1), "NGX flags must be integer0 or1")
    return bool(value)


def pair(value, label):
    q.require(isinstance(value, list) and len(value) == 2, label + " needs two elements")
    return [q.f32(q.number(v)) for v in value]


def contract(root):
    """NGX names are preserved; exporter declarations supply missing semantics."""
    trace = q.read_json(root / "ngx-trace.json")
    q.fields(trace, ("schemaVersion", "api", "sourceCommit", "creation", "colorEncoding",
                     "motionConvention", "motionJitterIncluded", "noiseCounterEvidence",
                     "identity", "provenance", "frames"))
    q.require(type(trace["schemaVersion"]) is int and trace["schemaVersion"] == 1, "unsupported trace schema")
    q.require(trace["api"] == "NVSDK_NGX_VK_DLSSNR_Eval_Params", "unsupported API")
    q.require(trace["sourceCommit"] == REMIX_COMMIT, "unreviewed NGX source version")
    creation = trace["creation"]
    q.fields(creation, ("Width", "Height", PRESET_KEY))
    w, h = q.integer(creation["Width"]), q.integer(creation["Height"])
    q.require(creation[PRESET_KEY] == PRESET, "only the reviewed lightweight presetB is supported")
    q.require(trace["colorEncoding"] == "display-srgb-unit", "HDR/transfer-function conversion is unsupported")
    q.require(trace["motionConvention"] == "pixel-current-to-previous", "motion direction must be declared")
    q.require(type(trace["motionJitterIncluded"]) is bool, "motion jitter inclusion must be explicit")
    q.require(isinstance(trace["noiseCounterEvidence"], str) and
              0 < len(trace["noiseCounterEvidence"]) <= 1000, "noise counter evidence must be declared; NGX does not expose it here")
    q.fields(trace["identity"], ("runtimeVersion", "runtimeSHA256", "network", "weightsSHA256"))
    q.require(trace["identity"]["runtimeVersion"] == "310.9.16.0" and trace["identity"]["network"] == "small31",
              "presetB importer is pinned to the reviewed310.9.16 small31 pairing")
    frames = trace["frames"]
    q.require(isinstance(frames, list) and 0 < len(frames) <= 4096, "invalid frame count")
    capture = {"schemaVersion": 1, "width": w, "height": h, "colorEncoding": trace["colorEncoding"],
               "identity": trace["identity"], "provenance": trace["provenance"], "frames": []}
    previous_jitter, previous_time, expected_noise, total = None, -1, 0, 0
    for index, frame in enumerate(frames):
        q.fields(frame, ("index", "timestampNanoseconds", "evaluationSucceeded", "noiseFrameIndex", "parameters", "buffers"))
        q.require(type(frame["index"]) is int and frame["index"] == index, "trace frames must be contiguous; dropped evaluations are unsupported")
        timestamp = frame["timestampNanoseconds"]
        q.require(type(timestamp) is int and previous_time < timestamp <= 2**63 - 1, "timestamps must increase")
        previous_time = timestamp
        q.require(frame["evaluationSucceeded"] is True, "failed evaluation has unknown history; recapture after a real reset")
        p = frame["parameters"]
        q.fields(p, PARAMS)
        reset = bit(p["InReset"])
        q.require(index > 0 or reset, "first evaluation must carry an actual NGX reset")
        if reset:
            expected_noise = 0
        q.require(type(frame["noiseFrameIndex"]) is int and frame["noiseFrameIndex"] == expected_noise,
                  "unsupported noiseFrameIndex: capture evidence must match MLX0-based reset segments")
        expected_noise += 1
        q.require(bit(p["InEnabled"]), "disabled/bypass evaluations are not neural references")
        depth_inverted = bit(p["InDepthInverted"])
        q.require(not bit(p["InUseAutoMask"]) and p["InMaskBlendMode"] == "NVSDK_NGX_DLSSNR_Mask_Blend_Mode_None",
                  "mask/automatic-mask equivalence is unqualified")
        q.require(type(p["InStyle"]) is int and 0 <= p["InStyle"] <= 2, "unreviewed appearance style")
        controls = {"intensity": q.f32(q.number(p["InIntensity"])), "styleIndex": p["InStyle"],
                    "localTone": q.f32(q.number(p["InLocalToneStrength"])),
                    "localStructure": q.f32(q.number(p["InLocalStructureStrength"])),
                    "skinStructure": q.f32(q.number(p["InSkinStructureStrength"])),
                    "autoMask": False, "modelSlot": 0}
        motion = {"convention": "pixel-current-to-previous", "jitterIncluded": trace["motionJitterIncluded"],
                  "scale": pair([p["InMVecScaleX"], p["InMVecScaleY"]], "motion scale")}
        if index == 0:
            capture.update(controls=controls, motion=motion, depthInverted=depth_inverted)
        q.require(controls == capture["controls"] and motion == capture["motion"] and depth_inverted == capture["depthInverted"],
                  "changing controls/scales/depth mode cannot be replayed by one MLX invocation; split at an existing reset")
        current_jitter = pair([p[key] for key in JITTER_KEYS], "current jitter")
        # At reset there is no carried history. Never subtract an old segment's jitter.
        delta = [0.0, 0.0] if reset or motion["jitterIncluded"] else [
            q.f32(old - new) for old, new in zip(previous_jitter, current_jitter)]
        previous_jitter = current_jitter
        converted = {"index": index, "timestampNanoseconds": timestamp, "reset": reset,
                     "noiseFrameIndex": frame["noiseFrameIndex"], "jitterDeltaPixels": delta}
        buffers = frame["buffers"]
        q.fields(buffers, (*BUFFERS.values(), "pInControlMask"))
        q.require(buffers["pInControlMask"] is None, "control-mask textures are unsupported, not silently discarded")
        for role, key in BUFFERS.items():
            record = buffers[key]
            q.fields(record, ("file", "sha256", "format", "rowBytes", "width", "height"))
            q.digest(record["sha256"])
            q.require(type(record["width"]) is int and type(record["height"]) is int and
                      record["width"] == w and record["height"] == h, "guide resampling is unqualified; extents must match")
            base, size = p["In" + SUBRECTS[role] + "SubrectBase"], p["In" + SUBRECTS[role] + "SubrectSize"]
            q.require(isinstance(base, list) and isinstance(size, list) and
                      all(type(v) is int for v in base + size) and base == [0, 0] and size == [w, h],
                      "subrect/crop conversion is unqualified")
            q.require(isinstance(record["format"], str) and record["format"] in FORMATS, "unsupported Vulkan texture format")
            channels, sample_bytes, _ = FORMATS[record["format"]]
            q.require(channels == (4 if role in ("color", "output") else q.ROLES[role]), "format does not match buffer role")
            stride = q.integer(record["rowBytes"], 1024 * 1024)
            q.require(stride >= w * channels * sample_bytes and stride % sample_bytes == 0, "invalid row stride")
            with q.regular(q.flat_file(root, record["file"])) as handle:
                q.require(os.fstat(handle.fileno()).st_size == stride * h, "buffer extent/stride mismatch")
            total += stride * h + w * h * q.ROLES[role] * 4
            converted[role] = {"file": f"{role}-{index:06d}.f32", "format": {1: "r32f-le", 2: "rg32f-le", 3: "rgb32f-le"}[q.ROLES[role]],
                               "rowBytes": w * q.ROLES[role] * 4}
        capture["frames"].append(converted)
    q.require(total <= q.LIMIT, "raw plus converted buffers exceed256MiB CPU import budget")
    return trace, capture


def convert(root, record, dest, role):
    channels, sample_bytes, code = FORMATS[record["format"]]
    width, height = record["width"], record["height"]
    source_hash, target_hash = hashlib.sha256(), hashlib.sha256()
    with q.regular(q.flat_file(root, record["file"])) as source, dest.open("xb") as target:
        for _ in range(height):
            row = source.read(record["rowBytes"])
            q.require(len(row) == record["rowBytes"], "buffer changed during import")
            source_hash.update(row)
            values = struct.unpack("<" + code * (width * channels), row[:width * channels * sample_bytes])
            q.require(all(math.isfinite(v) for v in values), "non-finite texture sample")
            keep = q.ROLES[role]
            output = [v for x in range(width) for v in values[x * channels:x * channels + keep]]
            if role != "motion":
                q.require(all(0 <= v <= 1 for v in output), "declared SDR color/depth outside unit range")
            raw = struct.pack("<" + "f" * len(output), *output)
            target.write(raw); target_hash.update(raw)
        q.require(not source.read(1), "buffer changed during import")
    q.require(source_hash.hexdigest() == record["sha256"], "captured texture SHA-256 mismatch")
    return target_hash.hexdigest()


def import_trace(source, output):
    root = q.bounded_root(source)
    trace, capture = contract(root)
    output = Path(output).absolute()
    q.bounded_root(output.parent)
    q.require(not output.exists() and not output.is_symlink(), "destination already exists")
    staging = Path(tempfile.mkdtemp(prefix=".dlss5-ngx-import-", dir=output.parent))
    try:
        for original, frame in zip(trace["frames"], capture["frames"]):
            for role, key in BUFFERS.items():
                frame[role]["sha256"] = convert(root, original["buffers"][key], staging / frame[role]["file"], role)
        q.write_json(staging / "capture.json", capture)
        q.capture_contract(staging)
        q.write_json(staging / "import-receipt.json", {
            "schemaVersion": 1, "sourceCommit": REMIX_COMMIT, "sourceTrace": trace,
            "jitterRule": "Float32(previous-current);zero at actual reset or when already in motion",
            "appearanceMapping": "InStyle->styleIndex;render presetB is separate from appearance",
            "inferenceExecuted": False, "modelBytesRead": False, "capturePerformed": False,
            "noiseCounterAuthenticated": False, "vendor_runtime_parity_verified": False})
        output.mkdir(mode=0o700)
        published = []
        try:
            for item in sorted(staging.iterdir(), key=lambda p: p.name == "capture.json"):
                target = output / item.name
                os.link(item, target, follow_symlinks=False)
                published.append((target, item.stat().st_ino))
        except BaseException:
            for target, inode in published:
                if target.exists() and not target.is_symlink() and target.stat().st_ino == inode:
                    target.unlink()
            try:
                output.rmdir()
            except OSError:
                pass
            raise
        return {"importedFrames": len(capture["frames"]), "capture": str(output),
                "inferenceExecuted": False, "vendor_runtime_parity_verified": False}
    finally:
        shutil.rmtree(staging)  # Only this invocation's unique staging directory.


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace_directory", type=Path)
    parser.add_argument("new_capture_directory", type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(import_trace(args.trace_directory, args.new_capture_directory), indent=2))
    except (q.Invalid, OSError, ValueError) as error:
        parser.exit(2, "NGX import refused: " + str(error) + "\n")


if __name__ == "__main__":
    main()
