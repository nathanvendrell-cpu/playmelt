#!/usr/bin/env python3
"""CPU-only captured-buffer adapter. Never imports or executes an inference backend."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import stat
import struct
import tempfile

LOCK = Path(__file__).with_name("upstream-lock.json")
LIMIT = 256 * 1024 * 1024
MAX_JSON = 1024 * 1024
SHA = re.compile(r"[0-9a-f]{64}\Z")
FORMATS = {"r32f-le": 1, "rg32f-le": 2, "rgb32f-le": 3, "rgba32f-le": 4}
ROLES = {"color": 3, "motion": 2, "depth": 1, "output": 3}


class Invalid(ValueError):
    pass


def require(ok, message):
    if not ok:
        raise Invalid(message)


def fields(value, required, optional=()):
    require(isinstance(value, dict), "expected an object")
    require(set(required) <= value.keys(), "missing fields: " + str(set(required) - value.keys()))
    require(value.keys() <= set(required) | set(optional), "unknown fields: " + str(value.keys() - set(required) - set(optional)))


def number(value):
    require(type(value) in (int, float) and math.isfinite(value), "expected a finite number")
    return float(value)


def integer(value, maximum=8192):
    require(type(value) is int and 0 < value <= maximum, "integer outside supported bounds")
    return value


def digest(value):
    require(isinstance(value, str) and SHA.fullmatch(value), "invalid SHA-256")
    return value


def f32(value):
    try:
        result = struct.unpack("<f", struct.pack("<f", value))[0]
    except (OverflowError, struct.error):
        raise Invalid("value overflows float32") from None
    require(math.isfinite(result), "non-finite float32")
    return result


def pixel_to_uv(x, y, scale, jitter, width, height):
    # Same order and float32 rounding as pinned normalizePixelMotion, lines139–152.
    return tuple(f32(f32(v * f32(f32(s) / f32(n))) + f32(f32(j) / f32(n)))
                 for v, s, j, n in zip((x, y), scale, jitter, (width, height)))


def regular(path, max_bytes=LIMIT):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
    try:
        st = os.fstat(fd)
        require(stat.S_ISREG(st.st_mode) and st.st_size <= max_bytes, "not a bounded regular file")
        return os.fdopen(fd, "rb")
    except BaseException:
        os.close(fd)
        raise


def no_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON key: " + key)
        result[key] = value
    return result


def read_json(path):
    with regular(path, MAX_JSON) as handle:
        raw = handle.read(MAX_JSON + 1)
    require(len(raw) <= MAX_JSON, "JSON exceeded byte limit while reading")
    return json.loads(raw, object_pairs_hook=no_duplicate_keys,
                      parse_constant=lambda value: (_ for _ in ()).throw(Invalid("non-finite JSON")))


def write_json(path, value):
    with path.open("x", encoding="utf-8") as handle:
        json.dump(value, handle, indent=2, allow_nan=False)
        handle.write("\n")


def flat_file(root, name):
    require(isinstance(name, str) and name not in ("", ".", "..") and
            "/" not in name and "\\" not in name and "\0" not in name,
            "buffer paths must be flat filenames")
    return root / name


def bounded_root(path):
    path = Path(path).absolute()
    for part in (path, *path.parents):
        require(not part.is_symlink(), "symlink directory is unsupported")
    require(path.is_dir(), "directory does not exist")
    return path


def inspect_source(source_root):
    root = bounded_root(source_root)
    lock = read_json(LOCK)
    matches = {}
    for name, expected in lock["mlx"]["files"].items():
        path = root / name
        bounded_root(path.parent)
        with regular(path, MAX_JSON) as handle:
            data = handle.read(MAX_JSON + 1)
        require(len(data) <= MAX_JSON, "source file exceeded byte limit while reading")
        actual = hashlib.sha256(data).hexdigest()
        require(actual == expected, "upstream source drift: " + name)
        matches[name] = actual
    return {"contractCommit": lock["mlx"]["commit"], "sourceFilesVerified": matches,
            "wholeCheckoutVerified": False,
            "inferenceExecuted": False}


def capture_contract(root):
    m = read_json(root / "capture.json")
    fields(m, ("schemaVersion", "width", "height", "colorEncoding", "depthInverted",
               "motion", "controls", "identity", "provenance", "frames"))
    require(type(m["schemaVersion"]) is int and m["schemaVersion"] == 1, "unsupported capture schema")
    w, h = integer(m["width"]), integer(m["height"])
    require(m["colorEncoding"] == "display-srgb-unit", "only display-referred unit-range sRGB is implemented")
    require(type(m["depthInverted"]) is bool, "depthInverted must be boolean")
    motion = m["motion"]
    fields(motion, ("convention", "jitterIncluded"), ("scale",))
    require(type(motion["jitterIncluded"]) is bool, "jitterIncluded must be boolean")
    if motion["convention"] == "pixel-current-to-previous":
        require(isinstance(motion.get("scale"), list) and len(motion["scale"]) == 2, "pixel motion needs two signed scales")
        [f32(number(v)) for v in motion["scale"]]
    else:
        require(motion["convention"] == "normalized-history-uv-offset" and
                motion["jitterIncluded"] and "scale" not in motion, "unsupported motion convention")
    controls = m["controls"]
    fields(controls, ("intensity", "styleIndex", "localTone", "localStructure", "skinStructure", "autoMask", "modelSlot"))
    for k in ("intensity", "localTone", "localStructure", "skinStructure"):
        f32(number(controls[k]))
    require(type(controls["styleIndex"]) is int and 0 <= controls["styleIndex"] < 2**32, "invalid style index")
    require(type(controls["autoMask"]) is bool, "autoMask must be boolean")
    require(type(controls["modelSlot"]) is int and controls["modelSlot"] == 0,
            "nondefault modelSlot has no qualified upstream flag; appearance uses styleIndex")
    identity = m["identity"]
    fields(identity, ("runtimeVersion", "runtimeSHA256", "network", "weightsSHA256"))
    digest(identity["runtimeSHA256"]); digest(identity["weightsSHA256"])
    networks = read_json(LOCK)["knownNetworks"]
    require(identity["network"] in networks.get(identity["runtimeVersion"], []), "unreviewed runtime/network pairing")
    p = m["provenance"]
    fields(p, ("kind", "rightsReview", "referenceDescription"))
    require(p["kind"] in ("synthetic-fixture", "user-supplied-capture"), "unsupported evidence kind")
    require(p["rightsReview"] in ("not-reviewed", "user-attested-local-use"), "unsupported provenance review")
    require(isinstance(p["referenceDescription"], str) and 0 < len(p["referenceDescription"]) <= 1000, "reference description required")
    frames = m["frames"]
    require(isinstance(frames, list) and 0 < len(frames) <= 4096, "invalid frame count")
    total = 0
    last_time = -1
    expected_noise_index = 0
    for index, frame in enumerate(frames):
        fields(frame, ("index", "timestampNanoseconds", "reset", "noiseFrameIndex", "jitterDeltaPixels", *ROLES))
        require(type(frame["index"]) is int and frame["index"] == index, "frames must be contiguous and ordered")
        t = frame["timestampNanoseconds"]
        require(type(t) is int and t > last_time and t <= 2**63-1, "timestamps must increase")
        last_time = t
        require(type(frame["reset"]) is bool and (index > 0 or frame["reset"]), "first frame must reset history")
        if frame["reset"]:
            expected_noise_index = 0
        require(type(frame["noiseFrameIndex"]) is int and frame["noiseFrameIndex"] == expected_noise_index,
                "unsupported noiseFrameIndex: upstream starts at0 after each reset and increments per frame")
        expected_noise_index += 1
        jitter = frame["jitterDeltaPixels"]
        require(isinstance(jitter, list) and len(jitter) == 2, "jitter must have two components")
        [f32(number(v)) for v in jitter]
        require(not motion["jitterIncluded"] or jitter == [0, 0], "jitter would be applied twice")
        for role, channels in ROLES.items():
            r = frame[role]
            fields(r, ("file", "sha256", "format", "rowBytes"))
            digest(r["sha256"])
            c = FORMATS.get(r["format"])
            require(c == channels or (role in ("color", "output") and c == 4), "unsupported buffer format")
            row = integer(r["rowBytes"], 1024 * 1024)
            require(row >= w * c * 4 and row % 4 == 0, "invalid row stride")
            path = flat_file(root, r["file"])
            with regular(path) as handle:
                require(os.fstat(handle.fileno()).st_size == row * h, "buffer extent/stride mismatch")
            total += row * h
    require(total <= LIMIT, "capture exceeds 256MiB CPU inspection budget; split into smaller sequences")
    return m


def adapt_buffer(root, record, dest, role, m, jitter):
    width, height = m["width"], m["height"]
    channels = FORMATS[record["format"]]
    source_hash, target_hash = hashlib.sha256(), hashlib.sha256()
    with regular(flat_file(root, record["file"])) as src, dest.open("xb") as out:
        for _ in range(height):
            row = src.read(record["rowBytes"])
            require(len(row) == record["rowBytes"], "buffer changed during read")
            source_hash.update(row)
            values = struct.unpack("<" + "f" * (width * channels), row[:width * channels * 4])
            require(all(math.isfinite(v) for v in values), "non-finite captured buffer")
            converted = []
            for x in range(width):
                v = values[x * channels:(x + 1) * channels]
                if role in ("color", "output"):
                    v = v[:3]
                    require(all(0 <= n <= 1 for n in v), "SDR color outside declared unit range")
                elif role == "depth":
                    require(0 <= v[0] <= 1, "depth outside normalized range")
                elif m["motion"]["convention"] == "pixel-current-to-previous":
                    v = pixel_to_uv(*v, m["motion"]["scale"], jitter, width, height)
                converted.extend(v)
            raw = struct.pack("<" + "f" * len(converted), *converted)
            out.write(raw); target_hash.update(raw)
        require(not src.read(1), "buffer changed during read")
    require(source_hash.hexdigest() == record["sha256"], "captured buffer SHA-256 mismatch")
    return {"file": dest.name, "sha256": target_hash.hexdigest()}


def run_plan(m, source, bundle, model, candidate):
    """Produce argv only. A fresh run-sequence process starts at each history reset."""
    controls = m["controls"]
    segments = []
    for frame in m["frames"]:
        if frame["reset"]:
            segments.append([])
        segments[-1].append(frame["index"])
    commands, outputs = [], []
    for s, indices in enumerate(segments):
        segment = candidate / f"segment-{s:04d}"
        args = [str(source / ".build/release/mlxdlss"), "run-sequence", str(model),
                "--input-format", "rgb-temporal-reference", "--motion-format", "normalized-uv",
                "--height", str(m["height"]), "--width", str(m["width"]),
                "--depth-inverted", str(m["depthInverted"]).lower(), "--output-dir", str(segment),
                "--backend", "mlx", "--execution", "eager", "--precision", "float32",
                "--preprocessor", "cpu", "--pipeline", "portable", "--network-geometry", "vendor-aligned",
                "--profile", "standard", "--intensity", str(controls["intensity"]),
                "--style-index", str(controls["styleIndex"]), "--local-tone", str(controls["localTone"]),
                "--local-structure", str(controls["localStructure"]), "--skin-structure", str(controls["skinStructure"]),
                "--auto-mask", "enabled" if controls["autoMask"] else "disabled"]
        for local_index, i in enumerate(indices):
            for role in ("color", "motion", "depth"):
                args += ["--input" if role == "color" else "--" + role, str(bundle / f"{role}-{i:06d}.f32")]
            outputs.append({"index": i, "candidate": f"segment-{s:04d}/{local_index:06d}.f32"})
        commands.append({"frameIndices": indices, "noiseFrameIndices": list(range(len(indices))), "argv": args})
    return {"schemaVersion": 1, "commands": commands, "outputs": outputs,
            "inferenceExecuted": False, "inferenceAuthorizedByThisTool": False,
            "modelBytesRead": False, "candidateExecutableVerified": False,
            "vendor_runtime_parity_verified": False}


def prepare(capture, output, source, model, candidate):
    root = bounded_root(capture)
    source = bounded_root(source)
    source_evidence = inspect_source(source)
    m = capture_contract(root)
    output = Path(output).absolute()
    bounded_root(output.parent)
    require(not output.exists() and not output.is_symlink(), "destination already exists")
    staging = Path(tempfile.mkdtemp(prefix=".dlss5-prepare-", dir=output.parent))
    try:
        golden = {"schemaVersion": 1, "width": m["width"], "height": m["height"],
                  "motionConvention": "normalized-history-uv-offset", "depthInverted": m["depthInverted"], "frames": []}
        for frame in m["frames"]:
            converted = {}
            for role in ROLES:
                dest = staging / f"{role}-{frame['index']:06d}.f32"
                converted[role] = adapt_buffer(root, frame[role], dest, role, m, frame["jitterDeltaPixels"])
            golden["frames"].append(converted)
        write_json(staging / "manifest.json", golden)
        evidence = {"schemaVersion": 1, "upstream": source_evidence, "capture": m,
                    "inferenceExecuted": False, "modelBytesRead": False,
                    "vendor_runtime_parity_verified": False}
        write_json(staging / "qualification.json", evidence)
        plan = run_plan(m, source, output, Path(model).absolute(), Path(candidate).absolute())
        write_json(staging / "planned-run.json", plan)
        # Exclusive directory creation + hard links never replace a concurrent destination.
        # Staging shares the parent filesystem. Publish the manifest last.
        output.mkdir(mode=0o700)
        published = []
        try:
            files = sorted(staging.iterdir(), key=lambda p: p.name == "manifest.json")
            for item in files:
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
                pass  # Do not remove anything another writer may have placed here.
            raise
        return {"preparedFrames": len(m["frames"]), "segments": len(plan["commands"]),
                "bundle": str(output), "inferenceExecuted": False, "vendor_runtime_parity_verified": False}
    finally:
        if staging.exists():
            shutil.rmtree(staging)  # Only the unique staging directory created above.


def compare(bundle, candidate, max_mae, max_abs):
    bundle, candidate = bounded_root(bundle), bounded_root(candidate)
    max_mae, max_abs = number(max_mae), number(max_abs)
    require(max_mae >= 0 and max_abs >= 0, "error thresholds must be nonnegative")
    manifest = read_json(bundle / "manifest.json")
    evidence = read_json(bundle / "qualification.json")
    m = evidence["capture"]
    require(type(manifest["schemaVersion"]) is int and manifest["schemaVersion"] == 1 and
            manifest["motionConvention"] == "normalized-history-uv-offset" and
            manifest["width"] == m["width"] and manifest["height"] == m["height"], "bundle metadata mismatch")
    expected = integer(m["width"]) * integer(m["height"]) * 3 * 4
    require(len(manifest["frames"]) == len(m["frames"]) and 0 < len(m["frames"]) <= 4096, "frame count mismatch")
    require(expected * len(m["frames"]) * 2 <= LIMIT, "comparison exceeds 256MiB CPU budget")
    results, segment, local_index = [], -1, 0
    for i, frame in enumerate(m["frames"]):
        require(frame["index"] == i and type(frame["reset"]) is bool and (i > 0 or frame["reset"]), "invalid frame history")
        if frame["reset"]:
            segment += 1; local_index = 0
        require(type(frame["noiseFrameIndex"]) is int and frame["noiseFrameIndex"] == local_index,
                "unsupported noiseFrameIndex in prepared bundle")
        ref_record = manifest["frames"][i]["output"]
        ref = flat_file(bundle, ref_record["file"])
        cand_dir = bounded_root(candidate / f"segment-{segment:04d}")
        cand = cand_dir / f"{local_index:06d}.f32"
        local_index += 1
        ref_hash, candidate_hash = hashlib.sha256(), hashlib.sha256()
        absolute, squared, maximum, count = 0.0, 0.0, 0.0, 0
        with regular(ref) as a, regular(cand) as b:
            require(os.fstat(a.fileno()).st_size == expected == os.fstat(b.fileno()).st_size, "comparison byte count mismatch")
            while left := a.read(65536):
                right = b.read(len(left))
                require(len(left) == len(right), "candidate changed during comparison")
                ref_hash.update(left); candidate_hash.update(right)
                for (x,), (y,) in zip(struct.iter_unpack("<f", left), struct.iter_unpack("<f", right)):
                    require(math.isfinite(x) and math.isfinite(y), "non-finite comparison")
                    error = abs(x-y)
                    absolute += error; squared += error*error; maximum = max(maximum, error); count += 1
            require(not b.read(1), "candidate changed during comparison")
        require(ref_hash.hexdigest() == digest(ref_record["sha256"]), "reference digest mismatch")
        mae, mse = absolute/count, squared/count
        results.append({"index": i, "meanAbsoluteError": mae, "maximumAbsoluteError": maximum,
                        "rootMeanSquaredError": math.sqrt(mse), "candidateSHA256": candidate_hash.hexdigest(),
                        "withinThresholds": mae <= max_mae and maximum <= max_abs})
    return {"schemaVersion": 1, "evidenceKind": m["provenance"]["kind"],
            "numericThresholdsPassed": all(f["withinThresholds"] for f in results),
            "thresholds": {"maxMAE": max_mae, "maxAbsoluteError": max_abs}, "frames": results,
            "candidateIdentityVerified": False, "vendor_runtime_parity_verified": False,
            "inferenceExecuted": False,
            "scope": "Comparison of supplied buffers only. Captures, model identity and execution provenance are not authenticated."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    inspect = commands.add_parser("inspect-source")
    inspect.add_argument("source", type=Path)
    make = commands.add_parser("prepare")
    for name in ("capture", "output", "source", "model", "candidate"):
        make.add_argument(name, type=Path)
    comp = commands.add_parser("compare")
    comp.add_argument("bundle", type=Path); comp.add_argument("candidate", type=Path)
    comp.add_argument("--max-mae", type=float, required=True)
    comp.add_argument("--max-abs", type=float, required=True)
    args = parser.parse_args()
    try:
        if args.command == "inspect-source": result = inspect_source(args.source)
        elif args.command == "prepare": result = prepare(args.capture, args.output, args.source, args.model, args.candidate)
        else: result = compare(args.bundle, args.candidate, args.max_mae, args.max_abs)
        print(json.dumps(result, indent=2, allow_nan=False))
        return 0 if result.get("numericThresholdsPassed", True) else 2
    except (Invalid, OSError, ValueError, KeyError, TypeError) as error:
        print(json.dumps({"error": str(error), "inferenceExecuted": False, "vendor_runtime_parity_verified": False}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
