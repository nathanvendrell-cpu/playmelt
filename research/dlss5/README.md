# DLSS 5 Neural Rendering: captured-buffer qualification

This module prepares real interoperability with the existing MLX-DLSS port. It is
not an inference implementation, an upscaler, an enabled Playmelt feature, or proof
of NVIDIA equivalence. It does not import MLX, Metal, Torch or CoreML, execute a
backend, download anything, inspect weights, or extract NVIDIA libraries.

The existing sibling project `../MLX-DLSS` was at
`7870371e8bf6c03967213f1a5d40db6c5a3bee38` during this work. It is reused by path;
there is no new checkout and its source is not modified. A source lock checks the
six files defining the interface, not the entire checkout or its built executable.

## Implemented interface

`prepare` accepts a `capture.json` plus raw captured buffers. It strips row padding
and RGBA alpha, validates float32 samples, and converts signed pixel motion to
history UV offsets with **the pinned upstream float32 operation order**:

`uv = float32(float32(motion * float32(scale / extent)) + float32(jitter / extent))`

The scale is signed. Jitter is in output pixels and is not multiplied by the motion
scale. Already normalized motion is passed through; applying jitter twice is refused.
No optical-flow estimation, inferred depth, resizing, invented history or synthetic
game inputs are substituted for missing captures.

Each explicit history reset starts a separate planned `run-sequence` invocation.
Within a segment, upstream owns the recurrent state. Its noise counter starts at0
and increments after each successful frame; a reset clears both history and counter.
Captures must explicitly record matching `noiseFrameIndex` values. A vendor capture
that preserves a global noise counter across history resets is refused: upstream
has no CLI override for that counter. Missing counter metadata is never inferred.
Every artistic control is
passed explicitly. The plan uses `rgb-temporal-reference`, eager float32 execution,
the portable pipeline and vendor-aligned geometry, rather than the media pipeline's
additional color/detail composition. Its preprocessor is CPU; **the planned network
would still use GPU inference if someone later ran it**. This tool never does so.

The output is an upstream-compatible `manifest.json`, converted f32 buffers,
`qualification.json` preserving original semantics/provenance, and `planned-run.json`
containing argv arrays and output mapping. Arrays are data, not shell commands.
For captures with resets, use the segmented plan; the upstream generic golden runner
does not know the extra reset metadata.

## Capture contract, version 1

Required top-level fields:

| Field | Supported contract |
|---|---|
| `schemaVersion` | Integer `1` |
| `width`, `height` | Positive integers, at most 8192; same full extent for all buffers |
| `colorEncoding` | `display-srgb-unit`; HDR and other transfer functions are refused |
| `depthInverted` | Boolean; raw depth samples are normalized to `[0,1]` |
| `motion` | `{ "convention": "pixel-current-to-previous", "scale": [-2,1], "jitterIncluded": false }`, or `{ "convention": "normalized-history-uv-offset", "jitterIncluded": true }` |
| `controls` | `intensity`, `styleIndex`, `localTone`, `localStructure`, `skinStructure`, `autoMask`, `modelSlot` |
| `identity` | `runtimeVersion`, `runtimeSHA256`, `network`, `weightsSHA256` |
| `provenance` | `kind`, `rightsReview`, `referenceDescription` |
| `frames` | Ordered non-empty sequence described below |

Controls contain finite values; `styleIndex` is UInt32, `autoMask` is boolean and
`modelSlot` must be `0`. The port's style control is not an A/B/C model selector.
Nondefault model slots, control masks, subrects and variable resolution are refused
until their exact capture and upstream contracts are qualified.

Reviewed identity pairs are `310.8.0.0` + `ht71`, or `310.9.16.0` + `ht71`/`small31`.
This is a version/shape allowlist, **not authentication of the model**. Digest strings
are recorded but no runtime DLL or weight bytes are read. The caller supplies the
model-package location for the future argv; even its existence is not treated as
verified. Unknown builds require a source review and lock update.

`provenance.kind` is `synthetic-fixture` or `user-supplied-capture`.
`rightsReview` is `not-reviewed` or `user-attested-local-use`; the latter records an
assertion, not a legal determination or permission to run. `referenceDescription`
must explain where the reference came from. No provenance flag authorizes inference.

Each frame contains:

```json
{
  "index": 0,
  "timestampNanoseconds": 0,
  "reset": true,
  "noiseFrameIndex": 0,
  "jitterDeltaPixels": [0.25, -0.125],
  "color": { "file": "color-0.raw", "sha256": "ACTUAL_SHA256", "format": "rgba32f-le", "rowBytes": 32 },
  "motion": { "file": "motion-0.raw", "sha256": "ACTUAL_SHA256", "format": "rg32f-le", "rowBytes": 16 },
  "depth": { "file": "depth-0.raw", "sha256": "ACTUAL_SHA256", "format": "r32f-le", "rowBytes": 8 },
  "output": { "file": "reference-0.raw", "sha256": "ACTUAL_SHA256", "format": "rgb32f-le", "rowBytes": 24 }
}
```

This example describes a two-pixel row; hashes must be calculated from actual files.
The first frame must reset. Indices are contiguous and timestamps strictly increase.
`noiseFrameIndex` must be `0,1,...` within every reset segment, matching the pinned
backend's state lifecycle rather than assuming NVIDIA uses the same reset policy.
Color/reference accept interleaved RGB or RGBA little-endian float32; motion accepts
RG and depth R. No planar, half-float, compressed, big-endian or integer interpretation
is guessed. `rowBytes` includes row padding; a file is exactly `rowBytes * height`.
Color/reference RGB must be finite `[0,1]`. All other used components must be finite.
File hashes include padding. Filenames are flat, and symlinks are refused.

## Commands

From the Playmelt source project, using an existing source checkout:

```sh
python3 -B research/dlss5/qualify.py inspect-source '../MLX-DLSS'
python3 -B -m unittest discover -s research/dlss5/tests -v
```

For future captures obtained with appropriate rights and explicit runtime-test
authorization, the following **prepares data and argv only**:

```sh
python3 -B research/dlss5/qualify.py prepare CAPTURE_DIR NEW_BUNDLE_DIR ../MLX-DLSS MODEL_PACKAGE FUTURE_CANDIDATE_DIR
```

It never invokes the executable named in `planned-run.json`. The default executable
location there follows upstream `.build/release/mlxdlss`; an existing alternative
build location and binary provenance must be reviewed before any later execution.

Once independently produced candidate files are available, the CPU comparator uses
the segment mapping and explicit, reviewer-chosen thresholds:

```sh
python3 -B research/dlss5/qualify.py compare BUNDLE_DIR CANDIDATE_DIR --max-mae 0 --max-abs 0
```

Zero requests exact equality. Thresholds are not silently relaxed. Every frame must
pass both criteria, so a good sequence average cannot hide a bad frame. The report
contains numerical errors and candidate hashes. It **always** leaves
`vendor_runtime_parity_verified: false`: supplied captures, executable identity,
model identity and same-parameter execution are not authenticated by this comparison.
Synthetic equality proves only the adapter/comparator. Non-finite data is an error.

All JSON is bounded to 1MiB; captures and comparisons to 256MiB each; processing is
row/chunk streamed without allocating full frames or loading models. Split longer
captures at genuine reset boundaries. Inputs are read-only. Output directories must
not exist; staging is private and cleaned on failure. Publication uses exclusive
directory creation and non-replacing hard links on the same filesystem. Canonical
paths are required (`/private/tmp`, rather than its `/tmp` symlink, for example).
Keep real captures, models and candidate runs outside the source repository.

## Sources and unresolved proof

- [Pinned upstream CLI](https://github.com/iamwavecut/MLX-DLSS/blob/7870371e8bf6c03967213f1a5d40db6c5a3bee38/Sources/mlxdlss/RunSequenceCommand.swift): flags, controls, output naming and sequence state.
- [Pinned motion preprocessor](https://github.com/iamwavecut/MLX-DLSS/blob/7870371e8bf6c03967213f1a5d40db6c5a3bee38/Sources/DLSSCore/NeuralRenderingTemporalReferencePreprocessor.swift#L117-L163): signed scale, jitter and float32 arithmetic.
- [Pinned temporal backend](https://github.com/iamwavecut/MLX-DLSS/blob/7870371e8bf6c03967213f1a5d40db6c5a3bee38/Sources/DLSSCore/NeuralRenderingTemporalReferenceBackend.swift): history and noise-counter reset/increment semantics.
- [MLX-DLSS limitations](https://github.com/iamwavecut/MLX-DLSS/blob/7870371e8bf6c03967213f1a5d40db6c5a3bee38/docs/recovery-notes.md): an experimental model port, not NVIDIA-certified game integration; the small network lacks an NVIDIA parity measurement.
- [OpenDLSS-NR](https://github.com/aloshdenny/open-dlss/tree/b9d4f7e8dc04a946a60207db73330177a586f1f1): alternative numerical reference. Its parity claim is not independently reproduced here; proprietary fixtures are absent.
- [NVIDIA research](https://research.nvidia.com/labs/adlr/DLSS5/): neural rendering conditions and temporal design.
- [Official RTX Remix 1.6.1](https://github.com/NVIDIAGameWorks/rtx-remix/releases/tag/remix-1.6.1): the official manifest lists `runtime/nvngx_dlssnr.dll`; nothing is downloaded by this module.
- [NVIDIA component terms](https://github.com/NVIDIAGameWorks/dxvk-remix/blob/main/ThirdPartyLicenses.txt): source-code licenses do not transfer rights to proprietary runtimes or extracted models.

Remaining gates: provenance/rights, source and executable qualification, external
NVIDIA reference capture, faithful temporal/control behavior, measured GPU cost,
texture sharing and game integration. These require later authorized work. This
module adds no UI switch and makes no performance or hardware-parity claim.
