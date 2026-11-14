import Foundation

/// Descriptor-only planning. No Metal/MLX/CoreML import, texture allocation, model
/// loading, device query or dispatch. See research/graphics_contract.md for the
/// canonical subset and primary sources; this is not a vendor SDK replacement.
enum GraphicsFeatureContract {
    enum Feature: String, Codable, CaseIterable {
        case nvidiaDLSSSuperResolution, nvidiaDLSS5NeuralRendering, nvidiaDLSSRayReconstruction
        case amdFSR1Spatial, amdFSR2Or3Temporal, amdFSR4ML
        case appleMetalFXSpatial, appleMetalFXTemporal, appleMetalFXTemporalDenoised, hdrEDRPresentation
        case experimentalNeuralRendering
        var isTemporal: Bool {
            [.nvidiaDLSSSuperResolution, .nvidiaDLSS5NeuralRendering, .nvidiaDLSSRayReconstruction,
             .amdFSR2Or3Temporal, .amdFSR4ML, .appleMetalFXTemporal, .appleMetalFXTemporalDenoised,
             .experimentalNeuralRendering].contains(self)
        }
        var isNeuralRendering: Bool { [.nvidiaDLSS5NeuralRendering, .experimentalNeuralRendering].contains(self) }
        var isRayReconstruction: Bool { [.nvidiaDLSSRayReconstruction, .appleMetalFXTemporalDenoised].contains(self) }
        var isTemporalUpscaler: Bool {
            [.nvidiaDLSSSuperResolution, .amdFSR2Or3Temporal, .amdFSR4ML, .appleMetalFXTemporal,
             .nvidiaDLSSRayReconstruction, .appleMetalFXTemporalDenoised].contains(self)
        }
        var provider: Provider {
            switch self {
            case .nvidiaDLSSSuperResolution, .nvidiaDLSS5NeuralRendering, .nvidiaDLSSRayReconstruction: return .nvidia
            case .amdFSR1Spatial, .amdFSR2Or3Temporal, .amdFSR4ML: return .amd
            case .appleMetalFXSpatial, .appleMetalFXTemporal, .appleMetalFXTemporalDenoised, .hdrEDRPresentation: return .apple
            case .experimentalNeuralRendering: return .experimental
            }
        }
    }
    enum Provider: String, Codable { case nvidia, amd, apple, experimental }
    enum API: String, Codable { case metal, directX11, directX12, vulkan }
    enum PixelFormat: String, Codable, CaseIterable {
        case rgba8Unorm, rgba8SRGB, rgb10a2Unorm, rgba16Float, rgba32Float
        case r8Unorm, r32Float, depth32Float, rg16Float, rg32Float
        var isColor: Bool { [.rgba8Unorm, .rgba8SRGB, .rgb10a2Unorm, .rgba16Float, .rgba32Float].contains(self) }
        var isFloatColor: Bool { self == .rgba16Float || self == .rgba32Float }
    }
    enum Usage: String, Codable { case shaderRead, shaderWrite, renderTarget, present }
    enum Primaries: String, Codable { case rec709, displayP3, rec2020 }
    enum Transfer: String, Codable { case linear, sRGB, pq, hlg }
    enum DynamicRange: String, Codable { case sdr, hdr }
    struct Extent: Codable, Equatable {
        var width: Int, height: Int
        var valid: Bool { (1...16_384).contains(width) && (1...16_384).contains(height) }
    }
    struct ColorEncoding: Codable, Equatable {
        var primaries: Primaries = .rec709
        var transfer: Transfer = .linear
        var range: DynamicRange = .sdr
        /// Required for HDR; the canonical linear representation maps 1.0 to this white.
        var referenceWhiteNits: Double? = nil
    }
    struct Texture: Codable {
        var resourceID: String
        /// Same underlying texture/view storage, NOT a heap or device identifier.
        /// Distinct subresources in shared storage are conservatively refused.
        var storageID: String
        var size: Extent
        var format: PixelFormat
        var usage: Set<Usage>
        var samples: Int = 1
    }
    struct Vector2: Codable { var x: Double, y: Double; var finite: Bool { x.isFinite && y.isFinite } }
    enum DepthConvention: String, Codable { case forwardZeroToOne, reversedZeroToOne }
    struct Depth: Codable {
        var texture: Texture
        var convention: DepthConvention
        var near: Double
        /// nil explicitly denotes an infinite far plane.
        var far: Double?
    }
    enum MotionDirection: String, Codable { case currentToPrevious, previousToCurrent }
    enum MotionUnits: String, Codable { case renderPixels, normalizedUV }
    struct Motion: Codable {
        var texture: Texture
        var direction: MotionDirection
        var units: MotionUnits
        var scale: Vector2
        var includesJitter: Bool = false
    }
    /// Metadata only; actual recurrent textures/state belong to the future adapter.
    struct History: Codable {
        var frameIndex: UInt64
        var sequenceID: String
        var contextID: String
        var renderSize: Extent, outputSize: Extent
        var color: ColorEncoding
    }
    struct Temporal: Codable {
        var frameIndex: UInt64
        var sequenceID: String
        /// Changes on backend, settings, camera/projection or render-pipeline discontinuity.
        var contextID: String
        var resetHistory: Bool
        var sceneCut: Bool = false
        var previous: History? = nil
        var depth: Depth? = nil
        var motion: Motion? = nil
        /// Canonical jitter is in render pixels, not normalized UV; NR SDK rules remain unresolved.
        var jitter: Vector2? = nil
        var colorIsJittered: Bool = false
        var exposure: Double? = nil
        var automaticExposure: Bool = false
        var reactiveMask: Texture? = nil
        var diffuseAlbedo: Texture? = nil
        var specularAlbedo: Texture? = nil
        var normals: Texture? = nil
        var roughness: Texture? = nil
        var specularHitDistance: Texture? = nil
    }
    enum ToneMapping: String, Codable { case none, mapToCurrentHeadroom }
    struct HDRPresentation: Codable {
        var wantsEDR: Bool
        /// Current display value supplied by caller; never substituted with potential capability.
        var currentHeadroom: Double?
        var maximumContentComponent: Double
        var toneMapping: ToneMapping
    }
    struct Request: Codable {
        var feature: Feature
        var api: API
        var color: Texture, output: Texture
        var inputEncoding: ColorEncoding, outputEncoding: ColorEncoding
        var temporal: Temporal? = nil
        var hdr: HDRPresentation? = nil
    }
    /// Untrusted declarations for planning, not detection/proof of hardware support.
    struct BackendDeclaration: Codable {
        var id: String
        var feature: Feature
        var provider: Provider
        var api: API
        var version: String
        var implementationDeclared: Bool = false
        var qualificationRecord: String? = nil
        var acceptedFormats: Set<PixelFormat> = []
        var maximumDimension: Int? = nil
    }
    enum Category: String, Codable { case descriptor, backend, qualification }
    enum Severity: String, Codable { case error, warning }
    struct Issue: Codable {
        var code: String, field: String
        var category: Category
        var severity: Severity = .error
    }
    enum Disposition: String, Codable {
        case invalidDescriptors, backendUnavailable, backendMismatch, qualificationRequired, runtimeValidationRequired
    }
    struct Report: Encodable {
        let schemaVersion = 1
        let requestedFeature: Feature
        let requestedAPI: API
        let backendID: String?
        let descriptorsValid: Bool
        let disposition: Disposition
        let issues: [Issue]
        // No execution capability is implemented in this module, even with a clean report.
        let executionAllowed = false
    }

    /// Static module inventory for diagnostics. This does not inspect the Mac,
    /// linked SDKs, installed drivers or any hardware/model capability.
    static func diagnosticsSnapshot() -> [String: Any] {
        ["schemaVersion": 1, "scope": "graphics-descriptor-contract", "deviceQueried": false,
         "executionAllowed": false, "features": Feature.allCases.map { feature -> [String: Any] in
            ["id": feature.rawValue, "provider": feature.provider.rawValue,
             "temporalInputs": feature.isTemporal, "backendImplemented": false,
             "backendQualified": false, "executionAllowed": false]
         }]
    }

    static func preflight(_ request: Request, backend: BackendDeclaration? = nil) -> Report {
        var issues: [Issue] = []
        func issue(_ code: String, _ field: String, _ category: Category = .descriptor, _ severity: Severity = .error) {
            issues.append(Issue(code: code, field: field, category: category, severity: severity))
        }
        func texture(_ value: Texture, _ field: String, usage: Usage, size: Extent? = nil) {
            if value.resourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || value.storageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issue("resourceIdentityMissing", field) }
            if !value.size.valid { issue("invalidExtent", field) }
            if let size, value.size != size { issue("extentMismatch", field) }
            if value.samples != 1 { issue("unresolvedMultisampling", field) }
            if !value.usage.contains(usage) { issue("missingUsage", field + "." + usage.rawValue) }
        }
        texture(request.color, "color", usage: .shaderRead)
        texture(request.output, "output", usage: request.feature == .hdrEDRPresentation ? .renderTarget : .shaderWrite)
        if !request.color.format.isColor || !request.output.format.isColor { issue("invalidColorFormat", "color/output") }
        if [.appleMetalFXSpatial, .appleMetalFXTemporal, .appleMetalFXTemporalDenoised, .hdrEDRPresentation].contains(request.feature) && request.api != .metal { issue("featureRequiresMetalAPI", "api") }
        if request.color.format == .rgba8SRGB || request.output.format == .rgba8SRGB { issue("srgbTypedViewAdapterRequired", "color/output.format") }
        if request.inputEncoding != request.outputEncoding { issue("explicitColorConversionRequired", "encoding") }
        if [.pq, .hlg].contains(request.inputEncoding.transfer) { issue("explicitTransferConversionRequired", "inputEncoding.transfer") }
        for (name, encoding, format) in [("inputEncoding", request.inputEncoding, request.color.format), ("outputEncoding", request.outputEncoding, request.output.format)] {
            if encoding.range == .hdr {
                if encoding.transfer != .linear || !format.isFloatColor { issue("linearFloatHDRRequired", name) }
                if let white = encoding.referenceWhiteNits, white.isFinite && white > 0 {} else { issue("referenceWhiteRequired", name) }
            } else if let white = encoding.referenceWhiteNits, !white.isFinite || white <= 0 { issue("invalidReferenceWhite", name) }
        }
        if request.feature == .amdFSR1Spatial && (request.inputEncoding.transfer != .sRGB || request.inputEncoding.range != .sdr) { issue("fsr1CanonicalPerceptualSDRRequired", "inputEncoding") }
        if request.feature.isTemporalUpscaler && request.inputEncoding.transfer != .linear { issue("canonicalLinearInputRequired", "inputEncoding") }
        if request.color.size.valid && request.output.size.valid {
            if request.feature == .hdrEDRPresentation || request.feature.isNeuralRendering {
                if request.color.size != request.output.size { issue("nonUpscalingStageExtentMismatch", "output") }
            } else if request.output.size.width < request.color.size.width || request.output.size.height < request.color.size.height {
                issue("notAnUpscaleExtent", "output")
            }
            let expectedHeight = Double(request.color.size.width) * Double(request.output.size.height) / Double(request.output.size.width)
            if abs(Double(request.color.size.height) - expectedHeight) > 1 { issue("cropOrAspectConversionRequired", "output") }
        }
        var inputs = [request.color]
        if request.feature.isTemporal {
            if let temporal = request.temporal {
                if temporal.sequenceID.isEmpty || temporal.contextID.isEmpty { issue("temporalIdentityMissing", "temporal") }
                if !temporal.resetHistory {
                    if let previous = temporal.previous {
                        let sequential = previous.frameIndex != UInt64.max && temporal.frameIndex == previous.frameIndex + 1
                        if temporal.sceneCut || !sequential || previous.sequenceID != temporal.sequenceID || previous.contextID != temporal.contextID ||
                            previous.renderSize != request.color.size || previous.outputSize != request.output.size || previous.color != request.inputEncoding {
                            issue("historyResetRequired", "temporal")
                        }
                    } else { issue("historyResetRequired", "temporal.previous") }
                }
                if let motion = temporal.motion {
                    texture(motion.texture, "motion", usage: .shaderRead, size: request.color.size); inputs.append(motion.texture)
                    if ![.rg16Float, .rg32Float].contains(motion.texture.format) { issue("invalidMotionFormat", "motion") }
                    if motion.direction != .currentToPrevious || motion.units != .renderPixels { issue("explicitMotionConversionRequired", "motion") }
                    if !motion.scale.finite || motion.scale.x == 0 || motion.scale.y == 0 { issue("invalidMotionScale", "motion.scale") }
                    if request.feature.isTemporalUpscaler && motion.includesJitter { issue("explicitJitterCancellationRequired", "motion") }
                } else { issue("motionRequired", "temporal.motion") }
                if let jitter = temporal.jitter, !jitter.finite { issue("invalidJitter", "temporal.jitter") }
                if let depth = temporal.depth {
                    texture(depth.texture, "depth", usage: .shaderRead, size: request.color.size); inputs.append(depth.texture)
                    if ![.r32Float, .depth32Float].contains(depth.texture.format) { issue("invalidDepthFormat", "depth") }
                    if !depth.near.isFinite || depth.near <= 0 || (depth.far.map { !$0.isFinite || $0 <= depth.near } ?? false) { issue("invalidDepthPlanes", "depth") }
                } else if request.feature.isTemporalUpscaler { issue("depthRequired", "temporal.depth") }
                if request.feature.isTemporalUpscaler {
                    if let jitter = temporal.jitter, jitter.finite, abs(jitter.x) <= 0.5, abs(jitter.y) <= 0.5 {} else { issue("renderPixelJitterRequired", "temporal.jitter") }
                    if !temporal.colorIsJittered { issue("jitteredColorRequired", "temporal.colorIsJittered") }
                    if let exposure = temporal.exposure, exposure.isFinite && exposure > 0 {} else if !temporal.automaticExposure { issue("exposurePolicyRequired", "temporal") }
                    if let exposure = temporal.exposure, !exposure.isFinite || exposure <= 0 { issue("invalidExposure", "temporal.exposure") }
                }
                if let mask = temporal.reactiveMask {
                    texture(mask, "reactiveMask", usage: .shaderRead, size: request.color.size); inputs.append(mask)
                    if mask.format != .r8Unorm { issue("invalidReactiveMaskFormat", "reactiveMask") }
                } else if [.amdFSR2Or3Temporal, .amdFSR4ML].contains(request.feature) { issue("reactiveMaskAbsent", "temporal", .descriptor, .warning) }
                if request.feature.isRayReconstruction {
                    if let albedo = temporal.diffuseAlbedo {
                        texture(albedo, "diffuseAlbedo", usage: .shaderRead, size: request.color.size); inputs.append(albedo)
                    } else { issue("diffuseAlbedoRequired", "temporal.diffuseAlbedo") }
                    if let normals = temporal.normals {
                        texture(normals, "normals", usage: .shaderRead, size: request.color.size); inputs.append(normals)
                    } else { issue("normalsRequired", "temporal.normals") }
                    if let roughness = temporal.roughness {
                        texture(roughness, "roughness", usage: .shaderRead, size: request.color.size); inputs.append(roughness)
                    } else { issue("roughnessRequired", "temporal.roughness") }
                    if let specAlbedo = temporal.specularAlbedo {
                        texture(specAlbedo, "specularAlbedo", usage: .shaderRead, size: request.color.size); inputs.append(specAlbedo)
                    }
                    if let hitDist = temporal.specularHitDistance {
                        texture(hitDist, "specularHitDistance", usage: .shaderRead, size: request.color.size); inputs.append(hitDist)
                    }
                }
            } else { issue("temporalInputsRequired", "temporal") }
        } else if request.temporal != nil { issue("temporalInputsUnused", "temporal", .descriptor, .warning) }
        if inputs.contains(where: { $0.storageID == request.output.storageID || $0.resourceID == request.output.resourceID }) { issue("inputOutputAliasing", "output") }
        if request.feature == .hdrEDRPresentation || request.hdr != nil {
            if let hdr = request.hdr {
                if request.api != .metal { issue("edrRequiresMetalPresentation", "api") }
                if !request.output.usage.contains(.present) { issue("presentUsageRequired", "output") }
                if !hdr.wantsEDR { issue("edrNotEnabled", "hdr") }
                if request.outputEncoding.range != .hdr || request.outputEncoding.transfer != .linear || request.output.format != .rgba16Float { issue("canonicalEDRSurfaceRequired", "output") }
                if !hdr.maximumContentComponent.isFinite || hdr.maximumContentComponent <= 0 { issue("invalidContentPeak", "hdr") }
                if let headroom = hdr.currentHeadroom, headroom.isFinite && headroom >= 1 {
                    if headroom == 1 { issue("displayCurrentlySDROnly", "hdr.currentHeadroom", .descriptor, .warning) }
                    if hdr.maximumContentComponent > headroom && hdr.toneMapping == .none { issue("toneMappingRequired", "hdr") }
                } else { issue("currentEDRHeadroomRequired", "hdr") }
            } else { issue("hdrPresentationRequired", "hdr") }
        }
        if let backend {
            if backend.feature != request.feature || backend.provider != request.feature.provider { issue("backendIdentityMismatch", "backend", .backend) }
            if backend.api != request.api { issue("backendAPIMismatchNoAutomaticTranslation", "backend.api", .backend) }
            if backend.id.isEmpty || backend.version.isEmpty { issue("backendVersionRequired", "backend", .backend) }
            if !backend.implementationDeclared { issue("backendNotImplemented", "backend", .backend) }
            if !backend.acceptedFormats.isEmpty && !([request.output] + inputs).allSatisfy({ backend.acceptedFormats.contains($0.format) }) { issue("backendFormatMismatch", "backend.acceptedFormats", .backend) }
            if let maximum = backend.maximumDimension, maximum <= 0 || ([request.output] + inputs).contains(where: { $0.size.width > maximum || $0.size.height > maximum }) { issue("backendExtentMismatch", "backend.maximumDimension", .backend) }
            if backend.qualificationRecord?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { issue("qualificationRecordMissing", "backend", .qualification) }
        } else { issue("backendAbsent", "backend", .backend) }
        if [.nvidiaDLSS5NeuralRendering, .amdFSR4ML, .experimentalNeuralRendering].contains(request.feature) {
            // Public feature descriptions are not a complete versioned SDK/model ABI.
            issue("vendorOrModelSchemaNotImplemented", "backend", .qualification)
        }
        issue("descriptorChecksDoNotAuthorizeExecution", "report", .qualification, .warning)
        let valid = !issues.contains { $0.category == .descriptor && $0.severity == .error }
        let disposition: Disposition
        if !valid { disposition = .invalidDescriptors }
        else if backend == nil || backend?.implementationDeclared != true { disposition = .backendUnavailable }
        else if issues.contains(where: { $0.category == .backend && $0.severity == .error }) { disposition = .backendMismatch }
        else if issues.contains(where: { $0.category == .qualification && $0.severity == .error }) { disposition = .qualificationRequired }
        else { disposition = .runtimeValidationRequired }
        return Report(requestedFeature: request.feature, requestedAPI: request.api, backendID: backend?.id,
                      descriptorsValid: valid, disposition: disposition, issues: issues)
    }
}
