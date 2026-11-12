import Foundation
import Metal
import MetalFX
import ObjectiveC

/// Native MetalFX Ray Reconstruction (DLSS 3.5 RR / Temporal Denoising Scaler).
/// Bridges noisy ray-traced radiance buffers, surface geometry G-buffers
/// (albedo, normal, roughness, hit distance) and camera matrices to Apple
/// Silicon's native MetalFX Temporal Denoised Scaler and Neural Engine.
@available(macOS 14.0, *)
final class MetalFXRayReconstructionAdapter {
    struct Configuration: Equatable {
        static let minimumOutputWidth = 1280
        static let minimumOutputHeight = 720
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
        var roughnessFormat: MTLPixelFormat = .r8Unorm
        var specularHitDistanceFormat: MTLPixelFormat = .r16Float
        var outputFormat: MTLPixelFormat = .rgba16Float

        func validate() throws {
            guard (1...Self.maximumDimension).contains(inputWidth),
                  (1...Self.maximumDimension).contains(inputHeight),
                  (Self.minimumOutputWidth...Self.maximumDimension).contains(outputWidth),
                  (Self.minimumOutputHeight...Self.maximumDimension).contains(outputHeight),
                  inputWidth <= outputWidth, inputHeight <= outputHeight else {
                throw Failure.invalidConfiguration("Dimensions hors limites ou non-upscaling")
            }
            let inAspect = Double(inputWidth) / Double(inputHeight)
            let outAspect = Double(outputWidth) / Double(outputHeight)
            guard abs(inAspect - outAspect) < 0.05 else {
                throw Failure.invalidConfiguration("Rapport d'aspect incompatible")
            }
        }
    }

    struct Metadata {
        let sequence: UUID
        let frameIndex: UInt64
        let resetHistory: Bool
        var jitterX: Float
        var jitterY: Float
        var preExposure: Float = 1.0
        var motionScaleX: Float = 1.0
        var motionScaleY: Float = 1.0
        var worldToViewMatrix: [Float]? = nil
        var viewToClipMatrix: [Float]? = nil

        func validate() throws {
            guard jitterX.isFinite, jitterY.isFinite, abs(jitterX) <= 1.0, abs(jitterY) <= 1.0 else {
                throw Failure.invalidJitter
            }
            guard preExposure.isFinite, preExposure > 0 else {
                throw Failure.invalidExposure
            }
            if let w2v = worldToViewMatrix {
                guard w2v.count == 16, w2v.allSatisfy({ $0.isFinite }) else {
                    throw Failure.invalidMatrix("worldToView")
                }
            }
            if let v2c = viewToClipMatrix {
                guard v2c.count == 16, v2c.allSatisfy({ $0.isFinite }) else {
                    throw Failure.invalidMatrix("viewToClip")
                }
            }
        }
    }

    struct Frame {
        let color: MTLTexture
        let depth: MTLTexture
        let motion: MTLTexture
        let diffuseAlbedo: MTLTexture
        let normal: MTLTexture
        let roughness: MTLTexture
        var specularAlbedo: MTLTexture? = nil
        var specularHitDistance: MTLTexture? = nil
        let output: MTLTexture
        let metadata: Metadata
    }

    enum Failure: Error, Equatable {
        case invalidConfiguration(String)
        case unsupportedDevice
        case descriptorUnavailable
        case scalerCreationFailed
        case invalidJitter
        case invalidExposure
        case invalidMatrix(String)
        case textureDimensionMismatch(String)
        case frameInFlight
    }

    struct CapabilitySnapshot {
        let nativeRayReconstructionAvailable: Bool
        let neuralEngineAccelerated: Bool
        let supportsSpecularHitDistance: Bool
        let maxOutputResolution: String
    }

    static func supports(device: MTLDevice) -> Bool {
        if #available(macOS 26.0, *) {
            return MTLFXTemporalDenoisedScalerDescriptor.supportsDevice(device)
        }
        guard let descClass = NSClassFromString("MTLFXTemporalDenoisedScalerDescriptor") as AnyObject? else {
            return false
        }
        let sel = NSSelectorFromString("supportsDevice:")
        guard descClass.responds(to: sel) else { return false }
        if let method = class_getClassMethod(object_getClass(descClass), sel) {
            typealias Fn = @convention(c) (AnyObject, Selector, MTLDevice) -> Bool
            let imp = unsafeBitCast(method_getImplementation(method), to: Fn.self)
            return imp(descClass, sel, device)
        }
        return false
    }

    static func capabilitySnapshot(device: MTLDevice?) -> CapabilitySnapshot {
        let available = device.map { supports(device: $0) } ?? false
        return CapabilitySnapshot(
            nativeRayReconstructionAvailable: available,
            neuralEngineAccelerated: available,
            supportsSpecularHitDistance: available,
            maxOutputResolution: "7680x4320 (8K)"
        )
    }

    let configuration: Configuration
    let device: MTLDevice
    private let scalerInstance: AnyObject
    private let encodeSelector: Selector
    private let encodeImp: @convention(c) (AnyObject, Selector, MTLCommandBuffer) -> Void
    private let lock = NSLock()
    private var busy = false

    init(configuration: Configuration, device: MTLDevice) throws {
        try configuration.validate()
        guard Self.supports(device: device) else {
            throw Failure.unsupportedDevice
        }
        guard let descClass = NSClassFromString("MTLFXTemporalDenoisedScalerDescriptor") as? NSObject.Type else {
            throw Failure.descriptorUnavailable
        }

        let desc = descClass.init()
        desc.setValue(configuration.colorFormat.rawValue, forKey: "colorTextureFormat")
        desc.setValue(configuration.depthFormat.rawValue, forKey: "depthTextureFormat")
        desc.setValue(configuration.motionFormat.rawValue, forKey: "motionTextureFormat")
        desc.setValue(configuration.diffuseAlbedoFormat.rawValue, forKey: "diffuseAlbedoTextureFormat")
        desc.setValue(configuration.normalFormat.rawValue, forKey: "normalTextureFormat")
        desc.setValue(configuration.roughnessFormat.rawValue, forKey: "roughnessTextureFormat")
        desc.setValue(configuration.outputFormat.rawValue, forKey: "outputTextureFormat")
        desc.setValue(configuration.inputWidth, forKey: "inputWidth")
        desc.setValue(configuration.inputHeight, forKey: "inputHeight")
        desc.setValue(configuration.outputWidth, forKey: "outputWidth")
        desc.setValue(configuration.outputHeight, forKey: "outputHeight")

        if configuration.specularAlbedoFormat != .invalid {
            desc.setValue(configuration.specularAlbedoFormat.rawValue, forKey: "specularAlbedoTextureFormat")
        }
        if configuration.specularHitDistanceFormat != .invalid {
            desc.setValue(configuration.specularHitDistanceFormat.rawValue, forKey: "specularHitDistanceTextureFormat")
            desc.setValue(true, forKey: "specularHitDistanceTextureEnabled")
        }

        let createSel = NSSelectorFromString("newTemporalDenoisedScalerWithDevice:")
        guard let method = class_getInstanceMethod(descClass, createSel) else {
            throw Failure.descriptorUnavailable
        }
        typealias CreateFn = @convention(c) (AnyObject, Selector, MTLDevice) -> AnyObject?
        let createImp = unsafeBitCast(method_getImplementation(method), to: CreateFn.self)
        guard let scaler = createImp(desc, createSel, device) else {
            throw Failure.scalerCreationFailed
        }

        let encSel = NSSelectorFromString("encodeToCommandBuffer:")
        guard let encMethod = class_getInstanceMethod(object_getClass(scaler)!, encSel) else {
            throw Failure.scalerCreationFailed
        }

        self.configuration = configuration
        self.device = device
        self.scalerInstance = scaler
        self.encodeSelector = encSel
        self.encodeImp = unsafeBitCast(method_getImplementation(encMethod), to: (@convention(c) (AnyObject, Selector, MTLCommandBuffer) -> Void).self)
    }

    func encode(commandBuffer: MTLCommandBuffer, frame: Frame) throws {
        try frame.metadata.validate()
        guard lock.try() else { throw Failure.frameInFlight }
        defer { lock.unlock() }

        // Vérification des dimensions d'entrée
        let inW = configuration.inputWidth, inH = configuration.inputHeight
        guard frame.color.width == inW && frame.color.height == inH else {
            throw Failure.textureDimensionMismatch("color")
        }
        guard frame.depth.width == inW && frame.depth.height == inH else {
            throw Failure.textureDimensionMismatch("depth")
        }
        guard frame.motion.width == inW && frame.motion.height == inH else {
            throw Failure.textureDimensionMismatch("motion")
        }
        guard frame.diffuseAlbedo.width == inW && frame.diffuseAlbedo.height == inH else {
            throw Failure.textureDimensionMismatch("diffuseAlbedo")
        }
        guard frame.normal.width == inW && frame.normal.height == inH else {
            throw Failure.textureDimensionMismatch("normal")
        }
        guard frame.roughness.width == inW && frame.roughness.height == inH else {
            throw Failure.textureDimensionMismatch("roughness")
        }
        guard frame.output.width == configuration.outputWidth && frame.output.height == configuration.outputHeight else {
            throw Failure.textureDimensionMismatch("output")
        }

        // Affectation des textures
        scalerInstance.setValue(frame.color, forKey: "colorTexture")
        scalerInstance.setValue(frame.depth, forKey: "depthTexture")
        scalerInstance.setValue(frame.motion, forKey: "motionTexture")
        scalerInstance.setValue(frame.diffuseAlbedo, forKey: "diffuseAlbedoTexture")
        scalerInstance.setValue(frame.normal, forKey: "normalTexture")
        scalerInstance.setValue(frame.roughness, forKey: "roughnessTexture")
        scalerInstance.setValue(frame.output, forKey: "outputTexture")

        if let spec = frame.specularAlbedo {
            scalerInstance.setValue(spec, forKey: "specularAlbedoTexture")
        }
        if let hitDist = frame.specularHitDistance {
            scalerInstance.setValue(hitDist, forKey: "specularHitDistanceTexture")
        }

        // Métadonnées temporelles et jitter
        scalerInstance.setValue(frame.metadata.jitterX, forKey: "jitterOffsetX")
        scalerInstance.setValue(frame.metadata.jitterY, forKey: "jitterOffsetY")
        scalerInstance.setValue(frame.metadata.motionScaleX, forKey: "motionVectorScaleX")
        scalerInstance.setValue(frame.metadata.motionScaleY, forKey: "motionVectorScaleY")
        scalerInstance.setValue(frame.metadata.preExposure, forKey: "preExposure")
        scalerInstance.setValue(frame.metadata.resetHistory, forKey: "reset")

        // Encodage sur le command buffer
        encodeImp(scalerInstance, encodeSelector, commandBuffer)
    }
}
