import Foundation

// CPU metadata only. No Metal/ML framework, device, backend, subprocess or model.
@main enum GraphicsFeatureContractTests {
    typealias C = GraphicsFeatureContract
    static var checks = 0
    static func expect(_ condition: Bool, _ label: String) {
        checks += 1; if !condition { fatalError("FAIL: " + label) }
    }
    static func has(_ request: C.Request, _ code: String, backend: C.BackendDeclaration? = nil) -> Bool {
        C.preflight(request, backend: backend).issues.contains { $0.code == code }
    }
    static func texture(_ id: String, _ size: C.Extent, _ format: C.PixelFormat, _ usage: Set<C.Usage> = [.shaderRead]) -> C.Texture {
        .init(resourceID: id, storageID: "allocation-" + id, size: size, format: format, usage: usage)
    }
    static func temporal() -> C.Request {
        let render = C.Extent(width: 1280, height: 720), output = C.Extent(width: 1920, height: 1080)
        return .init(feature: .appleMetalFXTemporal, api: .metal,
            color: texture("color", render, .rgba16Float), output: texture("output", output, .rgba16Float, [.shaderWrite]),
            inputEncoding: .init(), outputEncoding: .init(),
            temporal: .init(frameIndex: 0, sequenceID: "sequence-A", contextID: "backend-settings-A", resetHistory: true,
                depth: .init(texture: texture("depth", render, .depth32Float), convention: .reversedZeroToOne, near: 0.1, far: nil),
                motion: .init(texture: texture("motion", render, .rg16Float), direction: .currentToPrevious, units: .renderPixels, scale: .init(x: 1, y: 1)),
                jitter: .init(x: 0.25, y: -0.25), colorIsJittered: true, exposure: 1))
    }
    static func history(_ request: C.Request) -> C.History {
        .init(frameIndex: request.temporal!.frameIndex, sequenceID: request.temporal!.sequenceID,
              contextID: request.temporal!.contextID, renderSize: request.color.size, outputSize: request.output.size, color: request.inputEncoding)
    }
    static func hdr() -> C.Request {
        let size = C.Extent(width: 1920, height: 1080)
        let encoding = C.ColorEncoding(primaries: .displayP3, transfer: .linear, range: .hdr, referenceWhiteNits: 100)
        return .init(feature: .hdrEDRPresentation, api: .metal, color: texture("color", size, .rgba16Float),
            output: texture("surface", size, .rgba16Float, [.renderTarget, .present]), inputEncoding: encoding, outputEncoding: encoding,
            hdr: .init(wantsEDR: true, currentHeadroom: 4, maximumContentComponent: 3, toneMapping: .none))
    }
    static func main() throws {
        let base = temporal()
        let report = C.preflight(base)
        expect(report.descriptorsValid && report.disposition == .backendUnavailable, "valid descriptors are separate from absent backend")
        expect(!report.executionAllowed, "validation never enables execution")
        let inventory = C.diagnosticsSnapshot()
        expect(inventory["deviceQueried"] as? Bool == false, "static diagnostics do not query GPU")
        let features = inventory["features"] as! [[String: Any]]
        expect(features.count == C.Feature.allCases.count && features.allSatisfy { $0["backendImplemented"] as? Bool == false && $0["backendQualified"] as? Bool == false && $0["executionAllowed"] as? Bool == false }, "no current feature is advertised as implemented/qualified")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as! [String: Any]
        expect(encoded["executionAllowed"] as? Bool == false && encoded["descriptorsValid"] as? Bool == true, "diagnostic JSON preserves evidence boundary")
        let decoded = try JSONDecoder().decode(C.Request.self, from: JSONEncoder().encode(base))
        expect(C.preflight(decoded).descriptorsValid, "request metadata roundtrip")

        var r = base; r.color.size.width = Int.max
        expect(has(r, "invalidExtent"), "oversized extents cannot overflow")
        r = base; r.output.size.width = 0; expect(has(r, "invalidExtent"), "zero extent")
        r = base; r.output.size = .init(width: 640, height: 360); expect(has(r, "notAnUpscaleExtent"), "downscale is not silently treated as upscale")
        r = base; r.output.size = .init(width: 1920, height: 1200); expect(has(r, "cropOrAspectConversionRequired"), "crop requires explicit adapter")
        r = base; r.color.samples = 4; expect(has(r, "unresolvedMultisampling"), "MSAA must be resolved")
        r = base; r.output.usage = [.shaderRead]; expect(has(r, "missingUsage"), "output write usage required")
        r = base; r.color.storageID = ""; expect(has(r, "resourceIdentityMissing"), "storage identity required")
        r = base; r.output.storageID = r.color.storageID; expect(has(r, "inputOutputAliasing"), "views sharing color storage rejected")
        r = base; r.output.storageID = r.temporal!.motion!.texture.storageID; expect(has(r, "inputOutputAliasing"), "output cannot overwrite motion")
        r = base; r.output.resourceID = r.color.resourceID; expect(has(r, "inputOutputAliasing"), "same texture with different storage claims rejected")
        r = base; r.color.format = .r8Unorm; expect(has(r, "invalidColorFormat"), "single-channel color refused")
        r = base; r.inputEncoding.primaries = .rec2020; expect(has(r, "explicitColorConversionRequired"), "no silent gamut conversion")
        r = base; r.inputEncoding.transfer = .pq; expect(has(r, "explicitTransferConversionRequired"), "PQ is not linear light")
        r = base; r.color.format = .rgba8SRGB; expect(has(r, "srgbTypedViewAdapterRequired"), "typed sRGB decoding cannot be assumed away")
        r = base; r.temporal = nil; expect(has(r, "temporalInputsRequired"), "temporal reconstruction needs engine inputs")
        r = base; r.temporal!.depth = nil; expect(has(r, "depthRequired"), "depth required for temporal upscale")
        r = base; r.temporal!.motion = nil; expect(has(r, "motionRequired"), "motion not synthesized from color")
        r = base; r.temporal!.depth!.texture.size.width = 1920; expect(has(r, "extentMismatch"), "depth extent")
        r = base; r.temporal!.depth!.near = 0; expect(has(r, "invalidDepthPlanes"), "near plane positive")
        r = base; r.temporal!.depth!.far = 0.01; expect(has(r, "invalidDepthPlanes"), "far exceeds near")
        r = base; r.temporal!.depth!.convention = .forwardZeroToOne; r.temporal!.depth!.far = 1000
        expect(C.preflight(r).descriptorsValid, "finite forward depth accepted alongside reversed infinite depth")
        r = base; r.temporal!.motion!.units = .normalizedUV; expect(has(r, "explicitMotionConversionRequired"), "motion normalization explicit")
        r = base; r.temporal!.motion!.direction = .previousToCurrent; expect(has(r, "explicitMotionConversionRequired"), "motion direction explicit")
        r = base; r.temporal!.motion!.scale.x = .nan; expect(has(r, "invalidMotionScale"), "nonfinite motion")
        r = base; r.temporal!.motion!.includesJitter = true; expect(has(r, "explicitJitterCancellationRequired"), "no double jitter")
        r = base; r.temporal!.motion!.texture.format = .rgba16Float; expect(has(r, "invalidMotionFormat"), "motion format")
        r = base; r.temporal!.jitter = nil; expect(has(r, "renderPixelJitterRequired"), "jitter required")
        r = base; r.temporal!.jitter!.x = 0.75; expect(has(r, "renderPixelJitterRequired"), "canonical jitter bounded")
        r = base; r.temporal!.colorIsJittered = false; expect(has(r, "jitteredColorRequired"), "jitter metadata cannot replace jittered rendering")
        r = base; r.temporal!.exposure = nil; expect(has(r, "exposurePolicyRequired"), "exposure policy explicit")
        r.temporal!.automaticExposure = true; expect(C.preflight(r).descriptorsValid, "declared automatic exposure satisfies metadata only")
        r.temporal!.exposure = -.infinity; expect(has(r, "invalidExposure"), "auto exposure does not hide invalid explicit exposure")
        r = base; r.temporal!.resetHistory = false; expect(has(r, "historyResetRequired"), "first frame resets history")
        r.temporal!.previous = history(base); r.temporal!.frameIndex = 1
        expect(C.preflight(r).descriptorsValid, "contiguous history metadata")
        let continued = r
        r.temporal!.sceneCut = true; expect(has(r, "historyResetRequired"), "camera cut resets")
        r = continued; r.temporal!.frameIndex = 3; expect(has(r, "historyResetRequired"), "missing frame resets")
        r = continued; r.temporal!.contextID = "another-backend"; expect(has(r, "historyResetRequired"), "backend/settings switch resets")
        r = continued; r.temporal!.sequenceID = "another-camera"; expect(has(r, "historyResetRequired"), "sequence switch resets")
        r = continued; r.temporal!.previous!.outputSize.width = 2560; expect(has(r, "historyResetRequired"), "resolution switch resets")
        r = continued; r.temporal!.previous!.color.primaries = .displayP3; expect(has(r, "historyResetRequired"), "color domain switch resets")
        r = continued; r.temporal!.previous!.frameIndex = UInt64.max; expect(has(r, "historyResetRequired"), "frame overflow resets safely")
        r.temporal!.resetHistory = true; expect(C.preflight(r).descriptorsValid, "explicit reset discards stale metadata")

        r = base; r.feature = .amdFSR2Or3Temporal
        expect(C.preflight(r).descriptorsValid && has(r, "reactiveMaskAbsent"), "FSR reactive mask optional but absence visible")
        r.temporal!.reactiveMask = texture("mask", r.color.size, .rgba8Unorm)
        expect(has(r, "invalidReactiveMaskFormat"), "mask format checked")
        r = base; r.feature = .amdFSR1Spatial; r.temporal = nil
        expect(has(r, "fsr1CanonicalPerceptualSDRRequired"), "spatial FSR1 differs from temporal FSR")
        r.inputEncoding.transfer = .sRGB; r.outputEncoding = r.inputEncoding; r.color.format = .rgba8Unorm; r.output.format = .rgba8Unorm
        expect(C.preflight(r).descriptorsValid, "FSR1 accepts perceptual SDR shader values without depth/motion")
        r = base; r.feature = .appleMetalFXSpatial; r.temporal = nil
        expect(C.preflight(r).descriptorsValid, "spatial MetalFX does not require temporal buffers")
        r.api = .directX12; expect(has(r, "featureRequiresMetalAPI"), "MetalFX does not reinterpret a DirectX API")
        r = base; r.feature = .nvidiaDLSS5NeuralRendering; r.output.size = r.color.size
        r.temporal!.depth = nil; r.temporal!.jitter = nil; r.temporal!.colorIsJittered = false
        expect(C.preflight(r).descriptorsValid && has(r, "vendorOrModelSchemaNotImplemented"), "NR minimum metadata does not invent a complete DLSS5 SDK contract")
        r.temporal!.motion = nil; expect(has(r, "motionRequired"), "NR still requires actual engine motion")

        r = base; r.feature = .appleMetalFXTemporalDenoised
        expect(has(r, "diffuseAlbedoRequired"), "Ray Reconstruction requires diffuse albedo")
        r.temporal!.diffuseAlbedo = texture("albedo", r.color.size, .rgba16Float)
        expect(has(r, "normalsRequired"), "Ray Reconstruction requires normals")
        r.temporal!.normals = texture("normals", r.color.size, .rgba16Float)
        expect(has(r, "roughnessRequired"), "Ray Reconstruction requires roughness")
        r.temporal!.roughness = texture("roughness", r.color.size, .r8Unorm)
        expect(C.preflight(r).descriptorsValid, "Ray Reconstruction descriptors valid with required G-buffers")
        r.api = .directX12; expect(has(r, "featureRequiresMetalAPI"), "MetalFX Temporal Denoised requires Metal API")

        r = hdr(); expect(C.preflight(r).descriptorsValid, "linear HDR EDR descriptor baseline")
        r.hdr!.wantsEDR = false; expect(has(r, "edrNotEnabled"), "HDR flag required")
        r = hdr(); r.hdr!.currentHeadroom = nil; expect(has(r, "currentEDRHeadroomRequired"), "unknown headroom never treated as HDR support")
        r = hdr(); r.hdr!.currentHeadroom = .infinity; expect(has(r, "currentEDRHeadroomRequired"), "headroom finite")
        r = hdr(); r.hdr!.currentHeadroom = 1; expect(has(r, "displayCurrentlySDROnly") && has(r, "toneMappingRequired"), "current SDR headroom cannot display HDR peak")
        r.hdr!.toneMapping = .mapToCurrentHeadroom; expect(C.preflight(r).descriptorsValid && !C.preflight(r).executionAllowed, "planned tone map is not an implementation")
        r = hdr(); r.output.format = .rgb10a2Unorm; expect(has(r, "canonicalEDRSurfaceRequired"), "ten-bit format alone is not EDR")
        r = hdr(); r.output.usage.remove(.present); expect(has(r, "presentUsageRequired"), "HDR intermediate texture is not presentation")
        r = hdr(); r.inputEncoding.referenceWhiteNits = nil; expect(has(r, "referenceWhiteRequired"), "HDR reference white explicit")
        r = hdr(); r.outputEncoding.primaries = .rec2020; expect(has(r, "explicitColorConversionRequired"), "HDR gamut must match actual encoding")

        var backend = C.BackendDeclaration(id: "fixture-only", feature: base.feature, provider: .apple, api: .metal, version: "fixture-1", implementationDeclared: true, qualificationRecord: "fixture-record")
        expect(C.preflight(base, backend: backend).disposition == .runtimeValidationRequired && !C.preflight(base, backend: backend).executionAllowed, "declarations never turn CPU validation into execution authority")
        backend.qualificationRecord = nil; expect(C.preflight(base, backend: backend).disposition == .qualificationRequired, "qualification separate from structural validity")
        backend.api = .directX12; expect(has(base, "backendAPIMismatchNoAutomaticTranslation", backend: backend), "no automatic API translation")
        backend.api = .metal; backend.provider = .experimental; expect(has(base, "backendIdentityMismatch", backend: backend), "experimental implementation cannot claim vendor identity")
        backend.provider = .apple; backend.acceptedFormats = [.rgba16Float]; expect(has(base, "backendFormatMismatch", backend: backend), "backend must accept depth and motion too")
        backend.acceptedFormats = []; backend.maximumDimension = 1024; expect(has(base, "backendExtentMismatch", backend: backend), "backend extent limit")
        for feature in C.Feature.allCases {
            var candidate = base; candidate.feature = feature
            expect(!C.preflight(candidate).executionAllowed, "absent backend stays disabled for " + feature.rawValue)
        }
        print("GraphicsFeatureContract: \(checks) CPU descriptor checks passed; no backend/GPU/model executed")
    }
}
