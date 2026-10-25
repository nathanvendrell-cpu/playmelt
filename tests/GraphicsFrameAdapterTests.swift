import Foundation

// Tiny CPU arrays only; no backend, image loader, GPU, inference or process.
@main enum GraphicsFrameAdapterTests {
    typealias A = GraphicsFrameAdapter
    typealias C = GraphicsFeatureContract
    static var checks = 0
    static func expect(_ condition: Bool, _ label: String) {
        checks += 1; if !condition { fatalError("FAIL: " + label) }
    }
    static func close(_ actual: Double, _ expected: Double, _ label: String) {
        close(actual, expected, 1e-9, label)
    }
    static func close(_ actual: Double, _ expected: Double, _ tolerance: Double, _ label: String) {
        expect(actual.isFinite && abs(actual - expected) <= tolerance, label)
    }
    static func rejects(_ code: A.Code, _ label: String, _ operation: () throws -> Void) {
        checks += 1
        do { try operation(); fatalError("FAIL accepted: " + label) }
        catch let failure as A.Failure { if failure.code != code { fatalError("FAIL wrong rejection for \(label): \(failure)") } }
        catch { fatalError("FAIL unexpected error for \(label): \(error)") }
    }
    static func depthPlan() -> A.DepthPlan {
        .init(source: .forwardZeroToOne, target: .reversedZeroToOne, projection: .identical)
    }
    static func colorPlan(_ operation: A.TransferOperation, alpha: A.AlphaMode = .none) -> A.ColorPlan {
        .init(operation: operation, sourcePrimaries: .rec2020, targetPrimaries: .rec2020, alpha: alpha)
    }
    static func main() throws {
        let scalarLayout = A.BufferLayout(width: 1, height: 1, channels: 1, rowStrideFloats: 1)
        close(try A.convertScalar(0, operation: .sRGBToLinearSDR), 0, "sRGB zero")
        close(try A.convertScalar(1, operation: .sRGBToLinearSDR), 1, "sRGB one")
        close(try A.convertScalar(0.04045, operation: .sRGBToLinearSDR), 0.0031308049535603713, 1e-15, "sRGB lower branch boundary")
        close(try A.convertScalar(0.5, operation: .sRGBToLinearSDR), 0.21404114048223255, 1e-14, "sRGB nonlinear reference")
        close(try A.convertScalar(0.0031308, operation: .linearSDRToSRGB), 0.040449936, 1e-14, "linear SDR lower branch boundary")
        close(try A.convertScalar(1, operation: .linearSDRToSRGB), 1, 1e-14, "linear SDR one")
        for value in [0.0, 0.001, 0.02, 0.5, 0.9, 1] {
            close(try A.convertScalar(A.convertScalar(value, operation: .sRGBToLinearSDR), operation: .linearSDRToSRGB), value, 1e-12, "SDR roundtrip")
        }
        rejects(.sampleOutOfRange, "negative sRGB is explicitly unsupported") { _ = try A.convertScalar(-0.1, operation: .sRGBToLinearSDR) }
        rejects(.sampleOutOfRange, "extended scene-linear is not silently SDR-clamped") { _ = try A.convertScalar(2, operation: .linearSDRToSRGB) }
        rejects(.sampleOutOfRange, "negative scene-linear is not silently gamma mapped") { _ = try A.convertScalar(-0.1, operation: .linearSDRToSRGB) }
        for value in [Double.nan, .infinity, -.infinity] {
            rejects(.nonFiniteInput, "nonfinite scalar") { _ = try A.convertScalar(value, operation: .pqToNits) }
        }

        // ITU-R BT.2100-3 Table 4 EOTF/inverse EOTF, display-linear component nits.
        close(try A.convertScalar(0, operation: .pqToNits), 0, "PQ zero decodes to black")
        close(try A.convertScalar(1, operation: .pqToNits), 10_000, 1e-7, "PQ one is 10000 nits")
        close(try A.convertScalar(100, operation: .nitsToPQ), 0.508078421517399, 1e-12, "100-nit PQ reference")
        close(try A.convertScalar(1000, operation: .nitsToPQ), 0.751827096247041, 1e-12, "1000-nit PQ reference")
        close(try A.convertScalar(0, operation: .nitsToPQ), 7.309559025783966e-7, 1e-17, "normative inverse PQ black is not silently forced to zero")
        close(try A.convertScalar(0.508078421517399, operation: .pqToNits), 100, 1e-8, "PQ100 decode")
        close(try A.convertScalar(0.751827096247041, operation: .pqToNits), 1000, 1e-7, "PQ1000 decode")
        for value in [0.0001, 0.1, 1, 100, 203, 1000, 10_000] {
            close(try A.convertScalar(A.convertScalar(value, operation: .nitsToPQ), operation: .pqToNits), value, max(1e-8, value * 1e-10), "PQ nits roundtrip")
        }
        rejects(.sampleOutOfRange, "PQ range upper bound") { _ = try A.convertScalar(1.01, operation: .pqToNits) }
        rejects(.sampleOutOfRange, "PQ range lower bound") { _ = try A.convertScalar(-0.01, operation: .pqToNits) }
        rejects(.sampleOutOfRange, "nits above PQ domain") { _ = try A.convertScalar(10_001, operation: .nitsToPQ) }
        close(try A.convertScalar(203, operation: .nitsToEDR(referenceWhiteNits: 203)), 1, "EDR white explicit")
        close(try A.convertScalar(1000, operation: .nitsToEDR(referenceWhiteNits: 100)), 10, "HDR highlight retained without tone mapping")
        close(try A.convertScalar(-0.25, operation: .edrToNits(referenceWhiteNits: 203)), -50.75, "signed finite display-linear component preserved")
        close(try A.convertScalar(-50.75, operation: .nitsToEDR(referenceWhiteNits: 203)), -0.25, "signed display-linear roundtrip")
        close(try A.convertScalar(0.508078421517399, operation: .pqToEDR(referenceWhiteNits: 100)), 1, 1e-10, "PQ component to EDR")
        close(try A.convertScalar(10, operation: .edrToPQ(referenceWhiteNits: 100)), 0.751827096247041, 1e-12, "EDR component to PQ")
        rejects(.sampleOutOfRange, "negative linear component cannot be encoded as PQ") { _ = try A.convertScalar(-0.25, operation: .edrToPQ(referenceWhiteNits: 100)) }
        for white in [0.0, -1, .nan, .infinity] {
            rejects(.referenceWhiteRequired, "invalid white") { _ = try A.convertScalar(1, operation: .nitsToEDR(referenceWhiteNits: white)) }
        }
        rejects(.nonRepresentableOutput, "Double arithmetic overflow") { _ = try A.convertScalar(1e308, operation: .edrToNits(referenceWhiteNits: 1e308)) }

        let rgbaLayout = A.BufferLayout(width: 1, height: 2, channels: 4, rowStrideFloats: 6, offsetFloats: 1)
        let rgba: [Float] = [.nan, 0, 0.5, 1, 0.375, .nan, .infinity, 1, 0, 0.04045, -0.0]
        var frame = try A.convertColor(rgba, layout: rgbaLayout, plan: colorPlan(.sRGBToLinearSDR, alpha: .straightLastChannel), resetHistory: true)
        expect(frame.samples.count == 8 && frame.layout.rowStrideFloats == 4 && frame.layout.offsetFloats == 0, "strided RGBA packed without padding")
        close(Double(frame.samples[1]), 0.21404114048223255, 2e-8, "RGB channel converted")
        expect(frame.samples[3].bitPattern == rgba[4].bitPattern && frame.samples[7].bitPattern == rgba[10].bitPattern, "alpha bit patterns preserved including signed zero")
        expect(frame.resetHistory, "reset flag propagated without creating state")
        frame.samples[0] = 42
        expect(rgba[1] == 0, "output does not alias input storage")
        let pqRGB: [Float] = [0, Float(0.508078421517399), Float(0.751827096247041)]
        let rgbLayout = A.BufferLayout(width: 1, height: 1, channels: 3, rowStrideFloats: 3)
        let rgb = try A.convertColor(pqRGB, layout: rgbLayout, plan: colorPlan(.pqToNits))
        close(Double(rgb.samples[0]), 0, "PQ RGB black component")
        close(Double(rgb.samples[1]), 100, 0.0001, "PQ RGB decoded independently at100nits")
        close(Double(rgb.samples[2]), 1000, 0.001, "PQ RGB decoded independently at1000nits")
        var wrongGamut = colorPlan(.pqToNits); wrongGamut.targetPrimaries = .rec709
        rejects(.gamutConversionNotImplemented, "no silent primaries conversion") { _ = try A.convertColor(pqRGB, layout: rgbLayout, plan: wrongGamut) }
        rejects(.premultipliedAlphaNotSupported, "premultiplied alpha requires explicit unpremultiply pipeline") { _ = try A.convertColor([0,0,0,1], layout: .init(width: 1, height: 1, channels: 4, rowStrideFloats: 4), plan: colorPlan(.sRGBToLinearSDR, alpha: .premultiplied)) }
        rejects(.sampleOutOfRange, "alpha cannot be silently clipped") { _ = try A.convertColor([0,0,0,2], layout: .init(width: 1, height: 1, channels: 4, rowStrideFloats: 4), plan: colorPlan(.sRGBToLinearSDR, alpha: .straightLastChannel)) }
        rejects(.nonFiniteInput, "NaN active channel rejected") { _ = try A.convertColor([.nan], layout: scalarLayout, plan: colorPlan(.pqToNits)) }
        rejects(.nonRepresentableOutput, "Float narrowing overflow rejected") { _ = try A.convertColor([.greatestFiniteMagnitude], layout: scalarLayout, plan: colorPlan(.edrToNits(referenceWhiteNits: 1000))) }

        let motionLayout = A.BufferLayout(width: 2, height: 2, channels: 2, rowStrideFloats: 6, offsetFloats: 1)
        let motion: [Float] = [99, 0.25, -0.5, -0.25, 0.5, .nan, .infinity, 0.125, 0.25, -0.125, -0.25]
        var motionPlan = A.MotionPlan(direction: .currentToPrevious, units: .normalizedUV, scale: .init(x: 1,y: 1), includesJitter: false, resetHistory: false)
        let packed = try A.convertMotion(motion, layout: motionLayout, plan: motionPlan)
        expect(packed.samples == [0.5,-1,-0.5,1,0.25,0.5,-0.25,-0.5], "UV motion scales each axis into render pixels")
        expect(!packed.resetHistory, "false reset preserved")
        let xyLayout = A.BufferLayout(width: 1, height: 1, channels: 2, rowStrideFloats: 2)
        motionPlan.direction = .previousToCurrent; motionPlan.units = .renderPixels; motionPlan.resetHistory = true
        motionPlan.includesJitter = true
        motionPlan.projectedJitter = .init(current: .init(x: 0.25,y: -0.25), previous: .init(x: -0.25,y: 0.25))
        let dejittered = try A.convertMotion([2,3], layout: xyLayout, plan: motionPlan)
        expect(dejittered.samples == [-1.5,-3.5] && dejittered.resetHistory, "direction normalized BEFORE dejitter; reset never zeros motion")
        motionPlan.includesJitter = false
        expect(try A.convertMotion([2,3], layout: xyLayout, plan: motionPlan).samples == [-2,-3], "unjittered input is not dejittered twice")
        motionPlan.projectedJitter = nil; motionPlan.includesJitter = true
        rejects(.jitterMetadataRequired, "reset does not fabricate previous jitter") { _ = try A.convertMotion([2,3], layout: xyLayout, plan: motionPlan) }
        motionPlan.projectedJitter = .init(current: .init(x: 0.75,y: 0), previous: .init(x: 0,y: 0))
        rejects(.invalidProjectedJitter, "jitter convention bounded in render pixels") { _ = try A.convertMotion([2,3], layout: xyLayout, plan: motionPlan) }
        motionPlan.includesJitter = false; motionPlan.projectedJitter = nil; motionPlan.scale.x = .nan
        rejects(.invalidMotionScale, "NaN motion scale") { _ = try A.convertMotion([2,3], layout: xyLayout, plan: motionPlan) }
        motionPlan.scale = .init(x: -1,y: 2)
        expect(try A.convertMotion([2,3], layout: xyLayout, plan: motionPlan).samples == [2,-6], "signed axis scales are explicit")
        rejects(.nonFiniteInput, "Inf motion sample") { _ = try A.convertMotion([.infinity,0], layout: xyLayout, plan: motionPlan) }
        motionPlan.scale = .init(x: 1e308,y: 1)
        rejects(.nonRepresentableOutput, "motion cannot narrow an overflowing Float") { _ = try A.convertMotion([1,0], layout: xyLayout, plan: motionPlan) }

        let zLayout = A.BufferLayout(width: 3, height: 1, channels: 1, rowStrideFloats: 3)
        let inverse = try A.convertDepth([0,0.25,1], layout: zLayout, plan: depthPlan(), resetHistory: true)
        expect(inverse.samples == [1,0.75,0] && inverse.resetHistory, "depth inverse is only one-minus-z")
        var same = depthPlan(); same.target = .forwardZeroToOne
        let negativeZero: Float = -0.0
        expect(try A.convertDepth([negativeZero], layout: scalarLayout, plan: same).samples[0].bitPattern == negativeZero.bitPattern, "same depth convention preserves bits")
        same.projection = .differentOrUnknown
        rejects(.projectionConversionNotImplemented, "changed projection cannot be guessed") { _ = try A.convertDepth([0.5], layout: scalarLayout, plan: same) }
        same.projection = .identical; same.targetEncoding = .linearViewDistance
        rejects(.projectionConversionNotImplemented, "no false depth linearization") { _ = try A.convertDepth([0.5], layout: scalarLayout, plan: same) }
        rejects(.sampleOutOfRange, "depth outside clip interval") { _ = try A.convertDepth([1.1], layout: scalarLayout, plan: depthPlan()) }
        rejects(.nonFiniteInput, "depth NaN") { _ = try A.convertDepth([.nan], layout: scalarLayout, plan: depthPlan()) }

        for invalid in [A.BufferLayout(width: 0,height: 1,channels: 1,rowStrideFloats: 1), .init(width: 1,height: -1,channels: 1,rowStrideFloats: 1), .init(width: 4097,height: 1,channels: 1,rowStrideFloats: 4097), .init(width: 2,height: 1,channels: 1,rowStrideFloats: 1), .init(width: 1,height: 1,channels: 1,rowStrideFloats: 1,offsetFloats: -1)] {
            rejects(.invalidLayout, "invalid layout") { _ = try A.convertDepth([0], layout: invalid, plan: depthPlan()) }
        }
        rejects(.unsupportedChannels, "wrong depth channel count") { _ = try A.convertDepth([0,0], layout: xyLayout, plan: depthPlan()) }
        rejects(.arithmeticOverflow, "row stride overflow before indexing") { _ = try A.convertDepth([0], layout: .init(width: 1,height: 2,channels: 1,rowStrideFloats: Int.max), plan: depthPlan()) }
        rejects(.arithmeticOverflow, "offset overflow before indexing") { _ = try A.convertDepth([0], layout: .init(width: 1,height: 1,channels: 1,rowStrideFloats: 1,offsetFloats: Int.max), plan: depthPlan()) }
        rejects(.bufferTooShort, "short backing array") { _ = try A.convertDepth([], layout: scalarLayout, plan: depthPlan()) }
        rejects(.invalidLimits, "cannot expand dimension ceiling") { _ = try A.convertDepth([0], layout: scalarLayout, plan: depthPlan(), limits: .init(maximumDimension: 4097)) }
        rejects(.invalidLimits, "cannot expand byte ceiling") { _ = try A.convertDepth([0], layout: scalarLayout, plan: depthPlan(), limits: .init(maximumCombinedBytes: 64*1024*1024+1)) }
        rejects(.byteBudgetExceeded, "input and output both counted") { _ = try A.convertDepth([0], layout: scalarLayout, plan: depthPlan(), limits: .init(maximumCombinedBytes: 7)) }
        expect(try A.convertDepth([0], layout: scalarLayout, plan: depthPlan(), limits: .init(maximumCombinedBytes: 8)).samples == [1], "exact combined budget accepted")
        rejects(.byteBudgetExceeded, "unused input padding still consumes memory budget") { _ = try A.convertDepth([0,0,0], layout: scalarLayout, plan: depthPlan(), limits: .init(maximumCombinedBytes: 12)) }
        let snapshot = A.diagnosticsSnapshot()
        expect(snapshot["gpuExecution"] as? Bool == false && snapshot["inferenceExecution"] as? Bool == false && snapshot["vendorBackendImplemented"] as? Bool == false, "CPU conversions never claim a graphics backend")
        print("GraphicsFrameAdapter: \(checks) CPU checks passed; tiny scalar/buffer fixtures only")
    }
}
