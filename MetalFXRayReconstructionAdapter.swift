import Foundation
import Metal
import MetalFX
import simd

/// Adaptateur Playmelt vers le débruiteur-agrandisseur MetalFX
/// (`MTLFXTemporalDenoisedScaler`, macOS 26+), l'équivalent Apple du
/// DLSS Ray Reconstruction.
///
/// Portée réelle :
/// - Pour les **jeux Windows DX12**, cet adaptateur n'est PAS le chemin utilisé :
///   D3DMetal (GPTK 4) traduit lui-même les appels NGX « DLSSD » vers ce même
///   débruiteur, à l'intérieur du jeu, quand le pont NVIDIA est installé
///   (`D3DM_ENABLE_METALFX=1`) et le ray tracing activé (`D3DM_SUPPORT_DXR=1`).
/// - Cet adaptateur sert au futur moteur natif / post-traitement Playmelt, qui
///   possède ses propres textures Metal. Il n'est branché à aucun jeu
///   (`gameFrameProviderConnected == false`).
/// - Apple ne documente pas l'unité de calcul utilisée par MetalFX : aucune
///   accélération Neural Engine n'est revendiquée.
@available(macOS 26.0, *)
final class MetalFXRayReconstructionAdapter {
    struct Configuration: Equatable {
        static let maximumDimension = 7680

        let inputWidth: Int
        let inputHeight: Int
        let outputWidth: Int
        let outputHeight: Int

        var colorFormat: MTLPixelFormat = .rgba16Float
        var depthFormat: MTLPixelFormat = .depth32Float
        var motionFormat: MTLPixelFormat = .rg16Float
        var diffuseAlbedoFormat: MTLPixelFormat = .rgba16Float
        var specularAlbedoFormat: MTLPixelFormat = .rgba16Float
        var normalFormat: MTLPixelFormat = .rgba16Float
        var roughnessFormat: MTLPixelFormat = .r16Float
        var outputFormat: MTLPixelFormat = .rgba16Float
        /// Distance d'impact spéculaire : optionnelle, déclarée à la création.
        var specularHitDistanceFormat: MTLPixelFormat? = nil
        var depthReversed = false
        var autoExposure = false

        func validate() throws {
            guard (1...Self.maximumDimension).contains(inputWidth),
                  (1...Self.maximumDimension).contains(inputHeight),
                  (1...Self.maximumDimension).contains(outputWidth),
                  (1...Self.maximumDimension).contains(outputHeight),
                  inputWidth <= outputWidth, inputHeight <= outputHeight else {
                throw Failure.invalidConfiguration("Dimensions hors limites ou réduction demandée")
            }
            let inAspect = Double(inputWidth) / Double(inputHeight)
            let outAspect = Double(outputWidth) / Double(outputHeight)
            guard abs(inAspect - outAspect) < 0.05 else {
                throw Failure.invalidConfiguration("Rapport d'aspect incompatible")
            }
        }
    }

    struct Metadata {
        let frameIndex: UInt64
        let resetHistory: Bool
        /// Jitter de la caméra en pixels d'entrée, dans [-0,5 ; 0,5].
        var jitterX: Float
        var jitterY: Float
        var preExposure: Float = 1.0
        var motionScaleX: Float = 1.0
        var motionScaleY: Float = 1.0
        /// Matrices caméra exigées par le débruiteur (colonnes majeures, simd).
        var worldToView: simd_float4x4
        var viewToClip: simd_float4x4

        func validate() throws {
            guard jitterX.isFinite, jitterY.isFinite, abs(jitterX) <= 0.5, abs(jitterY) <= 0.5 else {
                throw Failure.invalidJitter
            }
            guard preExposure.isFinite, preExposure > 0 else { throw Failure.invalidExposure }
            guard motionScaleX.isFinite, motionScaleY.isFinite else { throw Failure.invalidMotionScale }
            guard Self.finite(worldToView) else { throw Failure.invalidMatrix("worldToView") }
            guard Self.finite(viewToClip), viewToClip.determinant != 0 else { throw Failure.invalidMatrix("viewToClip") }
        }

        private static func finite(_ m: simd_float4x4) -> Bool {
            [m.columns.0, m.columns.1, m.columns.2, m.columns.3].allSatisfy {
                $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite
            }
        }
    }

    struct Frame {
        let color: MTLTexture
        let depth: MTLTexture
        let motion: MTLTexture
        let diffuseAlbedo: MTLTexture
        let specularAlbedo: MTLTexture
        let normal: MTLTexture
        let roughness: MTLTexture
        var specularHitDistance: MTLTexture? = nil
        let output: MTLTexture
        let metadata: Metadata
    }

    enum Failure: Error, Equatable {
        case invalidConfiguration(String)
        case unsupportedDevice
        case scalerCreationFailed
        case invalidJitter
        case invalidExposure
        case invalidMotionScale
        case invalidMatrix(String)
        case textureMismatch(String)
        case frameOutOfOrder
        case frameInFlight
    }

    struct CapabilitySnapshot: Equatable {
        let temporalDenoisedScalerAvailable: Bool
        /// Toujours faux : aucun fournisseur d'images de jeu n'est branché ici.
        let gameFrameProviderConnected = false
        /// Toujours faux : Apple ne documente pas l'unité de calcul de MetalFX.
        let neuralEngineAccelerationVerified = false
        /// Les jeux Windows DX12 passent par la traduction NGX de D3DMetal.
        let windowsGamesPath = "D3DMetal (GPTK 4) : DLSSD → MTLFXTemporalDenoisedScaler, in-process"
    }

    static func supports(device: MTLDevice) -> Bool {
        MTLFXTemporalDenoisedScalerDescriptor.supportsDevice(device)
    }

    static func capabilitySnapshot(device: MTLDevice?) -> CapabilitySnapshot {
        CapabilitySnapshot(temporalDenoisedScalerAvailable: device.map { supports(device: $0) } ?? false)
    }

    let configuration: Configuration
    let device: MTLDevice
    private let scaler: MTLFXTemporalDenoisedScaler
    private let lock = NSLock()
    private var lastFrameIndex: UInt64?

    var inputContentScaleRange: ClosedRange<Float> { scaler.inputContentMinScale...scaler.inputContentMaxScale }

    init(configuration: Configuration, device: MTLDevice) throws {
        try configuration.validate()
        guard Self.supports(device: device) else { throw Failure.unsupportedDevice }

        let desc = MTLFXTemporalDenoisedScalerDescriptor()
        desc.colorTextureFormat = configuration.colorFormat
        desc.depthTextureFormat = configuration.depthFormat
        desc.motionTextureFormat = configuration.motionFormat
        desc.diffuseAlbedoTextureFormat = configuration.diffuseAlbedoFormat
        desc.specularAlbedoTextureFormat = configuration.specularAlbedoFormat
        desc.normalTextureFormat = configuration.normalFormat
        desc.roughnessTextureFormat = configuration.roughnessFormat
        desc.outputTextureFormat = configuration.outputFormat
        desc.inputWidth = configuration.inputWidth
        desc.inputHeight = configuration.inputHeight
        desc.outputWidth = configuration.outputWidth
        desc.outputHeight = configuration.outputHeight
        desc.isAutoExposureEnabled = configuration.autoExposure
        if let hitFormat = configuration.specularHitDistanceFormat {
            desc.specularHitDistanceTextureFormat = hitFormat
            desc.isSpecularHitDistanceTextureEnabled = true
        }
        guard let scaler = desc.makeTemporalDenoisedScaler(device: device) else {
            throw Failure.scalerCreationFailed
        }
        scaler.isDepthReversed = configuration.depthReversed

        // MetalFX exprime l'échelle en facteur d'agrandissement (sortie / entrée).
        let scale = Float(configuration.outputWidth) / Float(configuration.inputWidth)
        guard scale >= scaler.inputContentMinScale - 1e-4, scale <= scaler.inputContentMaxScale + 1e-4 else {
            throw Failure.invalidConfiguration(
                "Échelle \(scale) hors de [\(scaler.inputContentMinScale), \(scaler.inputContentMaxScale)] acceptée par MetalFX")
        }
        self.configuration = configuration
        self.device = device
        self.scaler = scaler
    }

    func encode(commandBuffer: MTLCommandBuffer, frame: Frame) throws {
        try frame.metadata.validate()
        guard lock.try() else { throw Failure.frameInFlight }
        defer { lock.unlock() }
        if !frame.metadata.resetHistory {
            guard let last = lastFrameIndex, frame.metadata.frameIndex == last &+ 1 else {
                throw Failure.frameOutOfOrder
            }
        }

        let c = configuration
        let inputs: [(String, MTLTexture, MTLPixelFormat, MTLTextureUsage)] = [
            ("color", frame.color, c.colorFormat, scaler.colorTextureUsage),
            ("depth", frame.depth, c.depthFormat, scaler.depthTextureUsage),
            ("motion", frame.motion, c.motionFormat, scaler.motionTextureUsage),
            ("diffuseAlbedo", frame.diffuseAlbedo, c.diffuseAlbedoFormat, scaler.diffuseAlbedoTextureUsage),
            ("specularAlbedo", frame.specularAlbedo, c.specularAlbedoFormat, scaler.specularAlbedoTextureUsage),
            ("normal", frame.normal, c.normalFormat, scaler.normalTextureUsage),
            ("roughness", frame.roughness, c.roughnessFormat, scaler.roughnessTextureUsage),
        ]
        for (name, texture, format, usage) in inputs {
            try Self.check(name, texture, width: c.inputWidth, height: c.inputHeight, format: format, usage: usage)
        }
        switch (c.specularHitDistanceFormat, frame.specularHitDistance) {
        case let (format?, texture?):
            try Self.check("specularHitDistance", texture, width: c.inputWidth, height: c.inputHeight,
                           format: format, usage: scaler.specularHitDistanceTextureUsage)
        case (nil, nil): break
        default: throw Failure.textureMismatch("specularHitDistance déclarée à la création mais absente (ou l'inverse)")
        }
        try Self.check("output", frame.output, width: c.outputWidth, height: c.outputHeight,
                       format: c.outputFormat, usage: scaler.outputTextureUsage)

        scaler.colorTexture = frame.color
        scaler.depthTexture = frame.depth
        scaler.motionTexture = frame.motion
        scaler.diffuseAlbedoTexture = frame.diffuseAlbedo
        scaler.specularAlbedoTexture = frame.specularAlbedo
        scaler.normalTexture = frame.normal
        scaler.roughnessTexture = frame.roughness
        scaler.specularHitDistanceTexture = frame.specularHitDistance
        scaler.outputTexture = frame.output

        let m = frame.metadata
        scaler.jitterOffsetX = m.jitterX
        scaler.jitterOffsetY = m.jitterY
        scaler.motionVectorScaleX = m.motionScaleX
        scaler.motionVectorScaleY = m.motionScaleY
        scaler.preExposure = m.preExposure
        scaler.shouldResetHistory = m.resetHistory
        scaler.worldToViewMatrix = m.worldToView
        scaler.viewToClipMatrix = m.viewToClip

        scaler.encode(commandBuffer: commandBuffer)
        lastFrameIndex = m.frameIndex
    }

    private static func check(_ name: String, _ texture: MTLTexture, width: Int, height: Int,
                              format: MTLPixelFormat, usage: MTLTextureUsage) throws {
        guard texture.width == width, texture.height == height else {
            throw Failure.textureMismatch("\(name) : \(texture.width)×\(texture.height) au lieu de \(width)×\(height)")
        }
        guard texture.pixelFormat == format else { throw Failure.textureMismatch("\(name) : format inattendu") }
        guard texture.usage.contains(usage) else { throw Failure.textureMismatch("\(name) : usage Metal insuffisant") }
    }
}
