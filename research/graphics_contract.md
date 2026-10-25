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

## Bounded CPU frame adapter — implementation 1

`GraphicsFrameAdapter.swift` adds real scalar/Float-array conversions, independent of any upscaler or inference. It reuses the contract's motion/depth/primaries enums. It does not change `research/dlss5`, allocate textures, perform resizing, inspect a display, or invoke a vendor backend.

```swift
let motion = try GraphicsFrameAdapter.convertMotion(samples, layout: layout, plan: motionPlan)
let depth = try GraphicsFrameAdapter.convertDepth(samples, layout: layout, plan: depthPlan)
let color = try GraphicsFrameAdapter.convertColor(samples, layout: layout, plan: colorPlan)
let scalar = try GraphicsFrameAdapter.convertScalar(value, operation: .pqToNits)
```

`BufferLayout` specifies width, height, channel count, row stride and offset in Float elements. The output is a new packed `OwnedFrame`; no in-place or borrowed-pointer API exists. Padding is not interpreted as samples, but the entire input array counts towards the memory bound. Checked integer arithmetic verifies addressed ranges before indexing/allocation. The fixed ceilings are 4096 per dimension and **64 MiB combined input plus output sample storage**, with only smaller caller limits accepted. This excludes Swift/container overhead and pre-existing caller allocations; it is not a total-process RAM guarantee. The reset flag is forwarded, never implemented by invented motion or history.

Motion conversion outputs current-to-previous displacement in render pixels. Given source vector `v`, signed per-axis scale `s`, unit scale `u = (width,height)` for normalized UV or `(1,1)` for pixels, and direction sign `d`, the operation is:

`canonical = d * (v * s * u) - (previousProjectedJitter - currentProjectedJitter)`

The jitter term is applied only when `includesJitter` is true. Both offsets are then mandatory, even with `resetHistory=true`. `ProjectedJitterPair` means actual projected-position offsets in render pixels, each within ±0.5, not a vendor's sample-location jitter convention. Direction is normalized before subtracting the jitter delta. Signed axis scales allow an explicit axis flip; no origin/sign convention is guessed. The output is not proof that supplied vectors represent all moving objects. [Apple WWDC26, session 359, 8:46 code](https://developer.apple.com/videos/play/wwdc2026/359/?time=526), [AMD FSR3 motion conventions](https://gpuopen.com/manuals/fidelityfx_sdk/techniques/super-resolution-upscaler/).

Depth conversion accepts normalized zero-to-one values and an explicit assertion of the same projection. It preserves `z` for the same convention and computes `1-z` for forward/reversed convention changes. Linear view distance, a changed/unknown projection, or samples outside the clip interval are rejected. No depth inference or projection-based linearization is implemented.

SDR transfer operations use the sRGB piecewise curve: decoding splits at 0.04045; encoding at 0.0031308. This implementation deliberately accepts only the SDR unit interval for those two operations; negative/extended scene-linear values receive an explicit range error rather than clipping. The separate linear nits↔EDR scaling preserves signed finite RGB components, which can occur outside a color gamut. [W3C CSS Color 4, sRGB transfer function and conversion code, consulted 25 October 2026](https://www.w3.org/TR/css-color-4/#color-conversion-code).

PQ uses the **display-linear EOTF and its inverse**, with constants from ITU-R BT.2100-3 (February 2025), Table 4: `m1=2610/16384`, `m2=2523/32`, `c1=3424/4096`, `c2=2413/128`, `c3=2392/128`. PQ input is [0,1]; absolute linear components are [0,10000] cd/m². The normative `max(...,0)` inside the EOTF is retained; no extra clipping or tone mapping is added. Inverse-EOTF black is approximately `7.309559e-7`, not forced to zero. This is not the scene-referred OETF/OOTF chain. [ITU-R BT.2100-3, Table 4 and notes 4a–4b](https://www.itu.int/dms_pubrec/itu-r/rec/bt/R-REC-BT.2100-3-202502-I!!PDF-E.pdf).

PQ is applied independently to R, G and B. A “nits” result here is the absolute scale of a display-linear component; it is not an RGB-to-Y luminance calculation. EDR scaling is `componentNits / referenceWhiteNits`, with a finite positive white supplied explicitly. It preserves highlight values above 1 and does not fit them to display headroom. PQ cannot encode negative components; nits/EDR linear scaling can preserve them. A reference-white scale does not convert scene light to display light. [Apple EDR pixel values](https://developer.apple.com/documentation/metal/performing-your-own-tone-mapping).

`ColorPlan` requires equal source/target primaries. No gamut conversion is hidden in the transfer function. Straight RGBA alpha is copied bit-for-bit after validation, never gamma/PQ transformed. Premultiplied alpha is refused because it needs an explicit unpremultiply/re-premultiply policy. NaN/Inf, nonrepresentable Float outputs, invalid strides, arithmetic overflow and budget violations throw structured errors before any partial result is exposed. Invalid unused padding is ignored as padding, not manufactured into pixels.

The adapter is an independently tested preprocessing primitive. It does not implement DLSS, FSR, MetalFX, frame generation, HDR presentation or an NVIDIA API converter. Its static `diagnosticsSnapshot()` identifies only the CPU conversions actually implemented. `GraphicsFeatureContract` still reports no executable graphics backend.

CPU fixture command, after the orchestrator assigns the compilation slot:

```sh
nice -n 15 swiftc GraphicsFeatureContract.swift GraphicsFrameAdapter.swift tests/GraphicsFrameAdapterTests.swift -o Products.noindex/GraphicsFrameAdapterTests
nice -n 15 Products.noindex/GraphicsFrameAdapterTests
```

Fixtures use tiny arrays and independent numeric references: sRGB boundaries, PQ 100/1000/10000-nit values, alpha preservation, signed linear scaling, normalization/dejitter order, reset propagation, depth inversion, strides, overflow, bounds and non-aliasing. They are not a GPU, game, image-quality or model-parity test.
