# Graphics descriptor contract

`GraphicsFeatureContract.swift` is a CPU-only planning module. It imports Foundation, validates values and returns a serializable report. It does not query a device, allocate textures, load an SDK/model, translate an API or submit work. The existing `research/dlss5` capture/qualification tools remain separate and unchanged.

## Integration API

```swift
let inventory: [String: Any] = GraphicsFeatureContract.diagnosticsSnapshot()
let report = GraphicsFeatureContract.preflight(request, backend: nil)
let data = try JSONEncoder().encode(report)
```

`diagnosticsSnapshot()` lists the nine distinct feature identifiers. Every entry has `backendImplemented: false`, `backendQualified: false` and `executionAllowed: false`; `deviceQueried` is false. This describes **this module**, not the capabilities of an installed GPU or OS framework.

`Request` holds input/output `Texture` descriptors, `ColorEncoding`, and optional `Temporal`/`HDRPresentation` metadata. `BackendDeclaration` identifies one exact feature, provider, API and version, with declared formats/extent limits and an optional qualification-record reference. It is caller-supplied evidence to review, not proof. There is no implicit fallback between features or API conversion.

`Report.descriptorsValid` is independent of backend readiness. Dispositions are `invalidDescriptors`, `backendUnavailable`, `backendMismatch`, `qualificationRequired`, or `runtimeValidationRequired`. Even the last disposition leaves `executionAllowed` false. Diagnostic codes identify the failed field and distinguish descriptor, backend and qualification issues. A later implementation must supply its own execution authority and verify resource contents, synchronization, hardware support and the cited qualification record.

## Feature boundaries

| Identifier | Contract scope |
|---|---|
| `nvidiaDLSSSuperResolution` | Temporal reconstruction baseline; distinct from neural rendering and frame generation. |
| `nvidiaDLSS5NeuralRendering` | Final neural-rendering stage: color, engine motion and temporal metadata. Complete vendor/model schema remains unimplemented. |
| `amdFSR1Spatial` | Current-image spatial baseline; canonical perceptual SDR input. |
| `amdFSR2Or3Temporal` | Color, depth, motion, jitter, exposure and history-reset metadata; reactive mask absence is a warning. |
| `amdFSR4ML` | Temporal baseline plus unresolved versioned ML/backend schema; never silently relabels FSR 3 as FSR 4. |
| `appleMetalFXSpatial` | Color-only spatial baseline. |
| `appleMetalFXTemporal` | Temporal baseline with backend-owned history. |
| `hdrEDRPresentation` | Explicit linear extended-range surface and current display headroom. |
| `experimentalNeuralRendering` | Separate identity for an experimental port; never qualifies it as NVIDIA DLSS 5. |

FSR1 is spatial and normally runs after antialiasing/tone mapping using perceptual normalized input. FSR3's temporal path uses engine depth/motion and supports linear HDR input. Optional masks improve handling of content without matching depth/motion. These are separate integration paths. [AMD FSR1 manual](https://gpuopen.com/manuals/fidelityfx_sdk/techniques/super-resolution-spatial/), [AMD FSR3 upscaler manual](https://gpuopen.com/manuals/fidelityfx_sdk/techniques/super-resolution-upscaler/).

FSR4 ML is a separately selected technology with its own distribution and hardware requirements. The AMD loader can select a different upscaler on other hardware; that is not evidence that FSR4 ran. No AMD library is loaded here. [AMD FSR4 integration](https://gpuopen.com/fidelityfx-super-resolution-4/).

DLSS5 Neural Rendering conditions a generative rendering stage on the current frame, engine motion, temporal state and artistic controls. It is not a synonym for DLSS Super Resolution, Ray Reconstruction or frame generation. An experimental model port is not an NVIDIA backend or an automatic NVIDIA-to-Metal API conversion. The published description is not a complete versioned resource/SDK ABI, so the NR contract remains blocked on schema qualification. [NVIDIA DLSS5 research](https://research.nvidia.com/labs/adlr/DLSS5/), [NVIDIA Streamline integration checklist](https://developer.nvidia.com/blog/how-to-integrate-nvidia-dlss-4-into-your-game-with-nvidia-streamline/).

Apple separates spatial and temporal MetalFX. Temporal scaling consumes jittered color, depth and motion; history is managed by the scaler. First frames and scene cuts require reset. [MetalFX documentation](https://developer.apple.com/documentation/metalfx), [Apple WWDC22 integration](https://developer.apple.com/videos/play/wwdc2022/10103/).

## Deliberately bounded canonical subset

This is a conservative adapter contract, not the exhaustive set of formats accepted by every vendor. It accepts full-frame, resolved, single-sample textures of at most 16384 pixels per dimension. Upscaling preserves aspect ratio within one input-pixel rounding error. NR and presentation retain resolution. Crops, array slices, shared-storage subresources, display-resolution motion and dynamic-resolution history reuse need a later explicit adapter.

Encoding denotes values **at the shader boundary**, not file labels. Input/output primaries, transfer, range and reference white must match; conversion is never implicit. Temporal upscalers use linear input here. FSR1 uses perceptual SDR values in ordinary UNORM/float storage. Typed sRGB views, PQ/HLG conversion and FSR1 HDR are refused by this subset; this is not a claim that a vendor SDK can never support them.

Motion is declared current-to-previous in render pixels with finite signed scale. Jitter must be in render pixels, and temporal upscale motion excludes jitter. Depth explicitly records forward/reversed zero-to-one mapping and finite/infinite far-plane convention. No optical flow, depth or history is invented. Caller-provided `contextID` must change after backend/settings/camera-projection discontinuities. Missing frames, new sequences, scene cuts, resolution or color-domain changes require `resetHistory`; a reset discards prior metadata rather than proving actual GPU history was cleared.

`resourceID` identifies a texture and `storageID` identifies its underlying texture/view storage, **not the enclosing heap**. Output sharing any input identity/storage is refused. Metadata cannot detect hidden aliases or prove resource lifetime/fences; the future adapter must authenticate these identifiers and synchronize access. No memory-saving or zero-copy claim follows from this check.

The EDR subset uses an `rgba16Float` surface, extended linear HDR encoding, explicit reference white, presentation usage and EDR opt-in. Current headroom must be supplied afresh by the integration; potential display capability is insufficient. Headroom of 1 is explicitly SDR-limited. Content above current headroom needs a declared tone-mapping stage, which this module does not implement. Ten-bit storage alone does not prove HDR presentation. [Apple EDR tone mapping](https://developer.apple.com/documentation/metal/performing-your-own-tone-mapping), [Apple current headroom behavior](https://developer.apple.com/documentation/quartzcore/cametallayer/wantsextendeddynamicrangecontent).

## CPU fixture test

```sh
nice -n 15 swiftc GraphicsFeatureContract.swift tests/GraphicsFeatureContractTests.swift -o Products.noindex/GraphicsFeatureContractTests
nice -n 15 Products.noindex/GraphicsFeatureContractTests
```

The fixtures check metadata only, including malformed dimensions, missing temporal inputs, aliasing, history discontinuities, HDR/EDR limits and wrong backend identity/API. Passing them does not establish image quality, timing, memory residency, vendor parity, HDR output or game compatibility. No frame-generation implementation or claim is included.
