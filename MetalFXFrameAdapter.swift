import Foundation
import Metal
import MetalFX

/// Fixed-resolution temporal scaling. The caller supplies real, synchronized
/// scene inputs; this adapter does not intercept or alter another renderer.
/// V1 accepts opaque linear Rec.709 SDR scene color before UI. The caller
/// composites UI afterwards and waits for completion before the next frame.
@available(macOS 13.0, *)
final class MetalFXFrameAdapter {
    struct Configuration: Equatable {
        static let minimumOutputWidth = 2560
        static let minimumOutputHeight = 1600
        static let maximumDimension = 4096
        let inputWidth: Int, inputHeight: Int
        let outputWidth: Int, outputHeight: Int
        var depthFormat: MTLPixelFormat = .depth32Float

        func validate() throws {
            guard (1...Self.maximumDimension).contains(inputWidth), (1...Self.maximumDimension).contains(inputHeight),
                  (Self.minimumOutputWidth...Self.maximumDimension).contains(outputWidth),
                  (Self.minimumOutputHeight...Self.maximumDimension).contains(outputHeight),
                  inputWidth <= outputWidth, inputHeight <= outputHeight,
                  inputWidth * outputHeight == inputHeight * outputWidth,
                  depthFormat == .depth32Float || depthFormat == .r32Float else {
                throw Failure.invalidConfiguration
            }
        }
    }
    enum DepthConvention { case forward, reversed }
    enum MotionConvention { case currentToPreviousPixelsWithoutJitter, unsupported }
    enum ColorConvention { case linearRec709SDROpaque, unsupported }
    enum RenderStage { case sceneBeforeUI, compositedUI, unknown }
    struct Metadata {
        let sequence: UUID
        let frameIndex: UInt64
        let resetHistory: Bool
        let jitterX: Float, jitterY: Float
        let depth: DepthConvention
        let motion: MotionConvention
        let color: ColorConvention
        let stage: RenderStage

        func validate() throws {
            guard jitterX.isFinite, jitterY.isFinite, abs(jitterX) <= 0.5, abs(jitterY) <= 0.5 else {
                throw Failure.invalidJitter
            }
            guard motion == .currentToPreviousPixelsWithoutJitter else { throw Failure.unsupportedMotion }
            guard color == .linearRec709SDROpaque else { throw Failure.unsupportedColor }
            guard stage == .sceneBeforeUI else { throw Failure.unsupportedRenderStage }
        }
    }
    struct Frame {
        let color: MTLTexture
        let depth: MTLTexture
        let motion: MTLTexture
        let exposure: MTLTexture
        let output: MTLTexture
        let metadata: Metadata
    }
    struct CapabilitySnapshot {
        let implementedTemporal = true
        let gameFrameProviderConnected = false
        let implementedDenoising = false
        let implementedInterpolation = false
    }
    static let capabilitySnapshot = CapabilitySnapshot()
    static func supports(device: MTLDevice) -> Bool { MTLFXTemporalScalerDescriptor.supportsDevice(device) }
    /// Builds a JSON-compatible value; no scaler, frame resources or GPU work
    /// are created. Device support is queried afresh for each supplied device.
    static func diagnosticsSnapshot(device: MTLDevice?) -> [String: Any] {
        let queriedSupport: Any = device.map { supports(device: $0) as Any } ?? NSNull()
        return ["implementedTemporal": true, "gameFrameProviderConnected": false,
                "implementedDenoising": false, "implementedInterpolation": false,
                "colorContract": "linear-rec709-sdr-opaque", "renderStage": "scene-before-ui",
                "maxFramesInFlight": 1, "callerWaitsForCompletion": true,
                "temporalDeviceSupported": queriedSupport,
                "minimumOutputWidth": Configuration.minimumOutputWidth,
                "minimumOutputHeight": Configuration.minimumOutputHeight,
                "maximumDimension": Configuration.maximumDimension]
    }
    struct RequiredUsages {
        let color: MTLTextureUsage, depth: MTLTextureUsage, motion: MTLTextureUsage, exposure: MTLTextureUsage, output: MTLTextureUsage
    }
    var requiredUsages: RequiredUsages {
        .init(color: scaler.colorTextureUsage, depth: scaler.depthTextureUsage,
              motion: scaler.motionTextureUsage, exposure: .shaderRead, output: scaler.outputTextureUsage)
    }
    enum Failure: Error, Equatable {
        case invalidConfiguration, unsupportedDevice, unsupportedScale, scalerCreationFailed
        case invalidJitter, unsupportedMotion, unsupportedColor, unsupportedRenderStage, invalidTexture(String), aliasedTextures
        case wrongCommandBuffer, frameInFlight, historyResetRequired
    }

    let configuration: Configuration
    private let device: MTLDevice
    private let scaler: MTLFXTemporalScaler
    private let lock = NSLock()
    private var busy = false
    private var previous: (UUID, UInt64, DepthConvention)?

    init(device: MTLDevice, configuration: Configuration) throws {
        try configuration.validate()
        guard MTLFXTemporalScalerDescriptor.supportsDevice(device) else { throw Failure.unsupportedDevice }
        if #available(macOS 14.0, *) {
            let minimum = MTLFXTemporalScalerDescriptor.supportedInputContentMinScale(device: device)
            let maximum = MTLFXTemporalScalerDescriptor.supportedInputContentMaxScale(device: device)
            let scale = Float(configuration.inputWidth) / Float(configuration.outputWidth)
            try Self.validateScale(scale, minimum: minimum, maximum: maximum)
        } else {
            // Without the device bounds, do not assume a scaling ratio is supported.
            throw Failure.unsupportedScale
        }
        let descriptor = try Self.makeDescriptor(configuration)
        guard let scaler = descriptor.makeTemporalScaler(device: device) else { throw Failure.scalerCreationFailed }
        self.device = device
        self.configuration = configuration
        self.scaler = scaler
    }

    static func validateScale(_ scale: Float, minimum: Float, maximum: Float) throws {
        guard scale.isFinite, minimum.isFinite, maximum.isFinite,
              minimum > 0, maximum >= minimum, scale >= minimum, scale <= maximum else {
            throw Failure.unsupportedScale
        }
    }

    static func makeDescriptor(_ configuration: Configuration) throws -> MTLFXTemporalScalerDescriptor {
        try configuration.validate()
        let descriptor = MTLFXTemporalScalerDescriptor()
        descriptor.inputWidth = configuration.inputWidth
        descriptor.inputHeight = configuration.inputHeight
        descriptor.outputWidth = configuration.outputWidth
        descriptor.outputHeight = configuration.outputHeight
        descriptor.colorTextureFormat = .rgba16Float
        descriptor.depthTextureFormat = configuration.depthFormat
        descriptor.motionTextureFormat = .rg16Float
        descriptor.outputTextureFormat = .rgba16Float
        descriptor.isAutoExposureEnabled = false
        descriptor.isInputContentPropertiesEnabled = false
        return descriptor
    }

    static func validateHistory(_ metadata: Metadata, previous: (UUID, UInt64, DepthConvention)?) throws {
        if !metadata.resetHistory {
            guard let previous, previous.0 == metadata.sequence, previous.2 == metadata.depth, previous.1 != UInt64.max,
                  previous.1 + 1 == metadata.frameIndex else { throw Failure.historyResetRequired }
        }
    }

    /// Caller's command buffer must be committed. Only one frame may be in
    /// flight; a failed GPU completion invalidates the history. Textures must
    /// remain valid and be synchronized by the caller until completion.
    func encode(_ frame: Frame, commandBuffer: MTLCommandBuffer) throws {
        try frame.metadata.validate()
        guard commandBuffer.device === device, commandBuffer.status == .notEnqueued else { throw Failure.wrongCommandBuffer }
        let c = configuration
        try validateTexture(frame.color, name: "color", width: c.inputWidth, height: c.inputHeight, format: .rgba16Float, usage: scaler.colorTextureUsage)
        try validateTexture(frame.depth, name: "depth", width: c.inputWidth, height: c.inputHeight, format: c.depthFormat, usage: scaler.depthTextureUsage)
        try validateTexture(frame.motion, name: "motion", width: c.inputWidth, height: c.inputHeight, format: .rg16Float, usage: scaler.motionTextureUsage)
        try validateTexture(frame.exposure, name: "exposure", width: 1, height: 1, format: .r16Float, usage: .shaderRead)
        try validateTexture(frame.output, name: "output", width: c.outputWidth, height: c.outputHeight, format: .rgba16Float, usage: scaler.outputTextureUsage)
        guard frame.output.storageMode == .private else { throw Failure.invalidTexture("output.storageMode") }
        let textures = [frame.color, frame.depth, frame.motion, frame.exposure, frame.output]
        // Conservatively reject texture views, buffer-backed textures and heap
        // resources: their subresource overlap is not established here.
        guard textures.allSatisfy({ $0.parent == nil && $0.buffer == nil && $0.heap == nil && $0.iosurface == nil }),
              Set(textures.map { ObjectIdentifier($0 as AnyObject) }).count == textures.count else { throw Failure.aliasedTextures }
        lock.lock()
        defer { lock.unlock() }
        guard !busy else { throw Failure.frameInFlight }
        let m = frame.metadata
        try Self.validateHistory(m, previous: previous)
        busy = true
        scaler.colorTexture = frame.color
        scaler.depthTexture = frame.depth
        scaler.motionTexture = frame.motion
        scaler.exposureTexture = frame.exposure
        scaler.outputTexture = frame.output
        scaler.inputContentWidth = c.inputWidth
        scaler.inputContentHeight = c.inputHeight
        scaler.jitterOffsetX = m.jitterX
        scaler.jitterOffsetY = m.jitterY
        scaler.motionVectorScaleX = 1
        scaler.motionVectorScaleY = 1
        scaler.isDepthReversed = m.depth == .reversed
        scaler.reset = m.resetHistory
        scaler.preExposure = 1
        scaler.encode(commandBuffer: commandBuffer)
        commandBuffer.addCompletedHandler { [self, frame] buffer in
            // Keep all resources alive even for an unretained command buffer.
            _ = frame
            lock.lock()
            previous = buffer.status == .completed ? (m.sequence, m.frameIndex, m.depth) : nil
            busy = false
            lock.unlock()
        }
    }

    private func validateTexture(_ texture: MTLTexture, name: String, width: Int, height: Int,
                                 format: MTLPixelFormat, usage: MTLTextureUsage) throws {
        guard texture.device === device, texture.textureType == .type2D,
              texture.width == width, texture.height == height, texture.pixelFormat == format,
              texture.sampleCount == 1, texture.mipmapLevelCount == 1, texture.arrayLength == 1,
              texture.storageMode != .memoryless, texture.usage.contains(usage) else {
            throw Failure.invalidTexture(name)
        }
    }
}
