import Foundation
import Metal
import MetalFX

@main
struct MetalFXFrameAdapterTests {
    static func main() throws {
        typealias A = MetalFXFrameAdapter
        let config = A.Configuration(inputWidth: 1280, inputHeight: 800, outputWidth: 2560, outputHeight: 1600)
        let d = try A.makeDescriptor(config)
        precondition(d.inputWidth == 1280 && d.inputHeight == 800 && d.outputWidth == 2560 && d.outputHeight == 1600)
        precondition(d.colorTextureFormat == .rgba16Float && d.depthTextureFormat == .depth32Float)
        precondition(d.motionTextureFormat == .rg16Float && d.outputTextureFormat == .rgba16Float)
        precondition(!d.isAutoExposureEnabled && !d.isInputContentPropertiesEnabled)
        var floatDepth = config
        floatDepth.depthFormat = .r32Float
        let floatDepthDescriptor = try A.makeDescriptor(floatDepth)
        precondition(floatDepthDescriptor.depthTextureFormat == .r32Float)
        precondition(A.capabilitySnapshot.implementedTemporal && !A.capabilitySnapshot.gameFrameProviderConnected)
        precondition(!A.capabilitySnapshot.implementedDenoising && !A.capabilitySnapshot.implementedInterpolation)
        let snapshot = A.diagnosticsSnapshot(device: nil)
        precondition(snapshot["temporalDeviceSupported"] is NSNull)
        precondition(snapshot["implementedTemporal"] as? Bool == true)
        precondition(snapshot["gameFrameProviderConnected"] as? Bool == false)
        precondition(snapshot["minimumOutputWidth"] as? Int == 2560 && snapshot["minimumOutputHeight"] as? Int == 1600)
        precondition(snapshot["maximumDimension"] as? Int == 4096)
        precondition(snapshot["colorContract"] as? String == "linear-rec709-sdr-opaque")
        precondition(snapshot["renderStage"] as? String == "scene-before-ui")
        precondition(snapshot["maxFramesInFlight"] as? Int == 1 && snapshot["callerWaitsForCompletion"] as? Bool == true)
        precondition(JSONSerialization.isValidJSONObject(snapshot))
        let again = A.diagnosticsSnapshot(device: nil)
        precondition(NSDictionary(dictionary: snapshot).isEqual(to: again))
        func fails(_ expected: A.Failure, _ body: () throws -> Void) {
            do { try body(); fatalError("expected \(expected)") }
            catch let actual as A.Failure { precondition(actual == expected) }
            catch { fatalError("unexpected \(error)") }
        }
        fails(.invalidConfiguration) { try A.Configuration(inputWidth: 1280, inputHeight: 720, outputWidth: 2560, outputHeight: 1600).validate() }
        fails(.invalidConfiguration) { try A.Configuration(inputWidth: 1280, inputHeight: 800, outputWidth: 2559, outputHeight: 1599).validate() }
        fails(.invalidConfiguration) { try A.Configuration(inputWidth: Int.max, inputHeight: 1, outputWidth: 2560, outputHeight: 1600).validate() }
        fails(.invalidConfiguration) { try A.Configuration(inputWidth: 1280, inputHeight: 800, outputWidth: 5120, outputHeight: 3200).validate() }
        try A.Configuration(inputWidth: 1920, inputHeight: 1080, outputWidth: 3840, outputHeight: 2160).validate()
        try A.validateScale(0.5, minimum: 0.5, maximum: 1)
        fails(.unsupportedScale) { try A.validateScale(Float(8) / 2560, minimum: 0.5, maximum: 1) }
        fails(.unsupportedScale) { try A.validateScale(.infinity, minimum: 0.5, maximum: 1) }
        let sequence = UUID()
        func metadata(_ index: UInt64, _ reset: Bool, _ depth: A.DepthConvention = .forward,
                      _ motion: A.MotionConvention = .currentToPreviousPixelsWithoutJitter,
                      _ jitter: Float = 0, color: A.ColorConvention = .linearRec709SDROpaque,
                      stage: A.RenderStage = .sceneBeforeUI) -> A.Metadata {
            .init(sequence: sequence, frameIndex: index, resetHistory: reset, jitterX: jitter, jitterY: 0, depth: depth, motion: motion, color: color, stage: stage)
        }
        try metadata(0, true).validate()
        try A.validateHistory(metadata(0, true), previous: nil)
        try A.validateHistory(metadata(1, false), previous: (sequence, 0, .forward))
        fails(.historyResetRequired) { try A.validateHistory(metadata(0, false), previous: nil) }
        fails(.historyResetRequired) { try A.validateHistory(metadata(2, false), previous: (sequence, 0, .forward)) }
        fails(.historyResetRequired) { try A.validateHistory(metadata(1, false, .reversed), previous: (sequence, 0, .forward)) }
        fails(.historyResetRequired) { try A.validateHistory(metadata(0, false), previous: (sequence, UInt64.max, .forward)) }
        fails(.unsupportedMotion) { try metadata(0, true, .forward, .unsupported).validate() }
        fails(.unsupportedColor) { try metadata(0, true, color: .unsupported).validate() }
        fails(.unsupportedRenderStage) { try metadata(0, true, stage: .compositedUI).validate() }
        fails(.unsupportedRenderStage) { try metadata(0, true, stage: .unknown).validate() }
        fails(.invalidJitter) { try metadata(0, true, .forward, .currentToPreviousPixelsWithoutJitter, .infinity).validate() }
        fails(.invalidJitter) { try metadata(0, true, .forward, .currentToPreviousPixelsWithoutJitter, 0.51).validate() }
        print("MetalFX descriptor and history tests passed; GPU not exercised")
    }
}
