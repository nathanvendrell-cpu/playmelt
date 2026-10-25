import Foundation

/// Small CPU buffer conversions only. No GPU, model, tone mapper, resampling or
/// vendor upscaler. Source conventions/formulas: research/graphics_contract.md.
enum GraphicsFrameAdapter {
    typealias Contract = GraphicsFeatureContract
    static let dimensionCeiling = 4096
    static let combinedByteCeiling = 64 * 1024 * 1024

    struct Limits {
        var maximumDimension: Int = dimensionCeiling
        var maximumCombinedBytes: Int = combinedByteCeiling
        static let standard = Limits()
    }
    struct BufferLayout: Equatable {
        var width: Int, height: Int, channels: Int, rowStrideFloats: Int
        var offsetFloats: Int = 0
    }
    struct OwnedFrame {
        var samples: [Float]
        let layout: BufferLayout
        /// Forwarded metadata only. No recurrent state is allocated or invented.
        let resetHistory: Bool
    }
    struct ProjectedJitterPair {
        /// Actual projected-position offsets in render pixels, not API sample offsets.
        var current: Contract.Vector2
        var previous: Contract.Vector2
    }
    struct MotionPlan {
        var direction: Contract.MotionDirection
        var units: Contract.MotionUnits
        var scale: Contract.Vector2
        var includesJitter: Bool
        var resetHistory: Bool
        var projectedJitter: ProjectedJitterPair? = nil
    }
    enum DepthEncoding { case normalizedZeroToOne, linearViewDistance }
    enum ProjectionRelation { case identical, differentOrUnknown }
    struct DepthPlan {
        var source: Contract.DepthConvention
        var target: Contract.DepthConvention
        var projection: ProjectionRelation
        var sourceEncoding: DepthEncoding = .normalizedZeroToOne
        var targetEncoding: DepthEncoding = .normalizedZeroToOne
    }
    enum AlphaMode { case none, straightLastChannel, premultiplied }
    enum TransferOperation {
        case sRGBToLinearSDR, linearSDRToSRGB
        case pqToNits, nitsToPQ
        case nitsToEDR(referenceWhiteNits: Double), edrToNits(referenceWhiteNits: Double)
        case pqToEDR(referenceWhiteNits: Double), edrToPQ(referenceWhiteNits: Double)
    }
    struct ColorPlan {
        var operation: TransferOperation
        var sourcePrimaries: Contract.Primaries
        var targetPrimaries: Contract.Primaries
        var alpha: AlphaMode
    }
    enum Code: String {
        case invalidLimits, invalidLayout, arithmeticOverflow, byteBudgetExceeded, bufferTooShort
        case unsupportedChannels, nonFiniteInput, sampleOutOfRange, nonRepresentableOutput
        case invalidMotionScale, jitterMetadataRequired, invalidProjectedJitter
        case projectionConversionNotImplemented, gamutConversionNotImplemented
        case premultipliedAlphaNotSupported, referenceWhiteRequired
    }
    struct Failure: Error, Equatable {
        let code: Code
        let field: String
        var sampleIndex: Int? = nil
    }
    private struct ValidatedLayout {
        let outputCount: Int
        let packed: BufferLayout
    }

    static func diagnosticsSnapshot() -> [String: Any] {
        ["schemaVersion": 1, "scope": "bounded-cpu-frame-conversions",
         "implemented": ["motion-normalization", "zero-to-one-depth-inversion", "sdr-srgb-linear", "pq-st2084-nits-edr"],
         "maximumDimension": dimensionCeiling, "maximumCombinedBytes": combinedByteCeiling,
         "gpuExecution": false, "inferenceExecution": false, "vendorBackendImplemented": false]
    }

    private static func product(_ a: Int, _ b: Int) throws -> Int {
        let (value, overflow) = a.multipliedReportingOverflow(by: b)
        guard !overflow else { throw Failure(code: .arithmeticOverflow, field: "layout") }
        return value
    }
    private static func sum(_ a: Int, _ b: Int) throws -> Int {
        let (value, overflow) = a.addingReportingOverflow(b)
        guard !overflow else { throw Failure(code: .arithmeticOverflow, field: "layout") }
        return value
    }
    private static func validate(_ input: [Float], _ layout: BufferLayout, channels: Set<Int>, limits: Limits) throws -> ValidatedLayout {
        guard limits.maximumDimension > 0, limits.maximumDimension <= dimensionCeiling,
              limits.maximumCombinedBytes > 0, limits.maximumCombinedBytes <= combinedByteCeiling else {
            throw Failure(code: .invalidLimits, field: "limits")
        }
        guard layout.width > 0, layout.height > 0, layout.width <= limits.maximumDimension,
              layout.height <= limits.maximumDimension, layout.offsetFloats >= 0, layout.rowStrideFloats > 0 else {
            throw Failure(code: .invalidLayout, field: "layout")
        }
        guard channels.contains(layout.channels) else { throw Failure(code: .unsupportedChannels, field: "layout.channels") }
        let row = try product(layout.width, layout.channels)
        guard layout.rowStrideFloats >= row else { throw Failure(code: .invalidLayout, field: "layout.rowStrideFloats") }
        let required = try sum(try sum(layout.offsetFloats, product(layout.height - 1, layout.rowStrideFloats)), row)
        let outputCount = try product(row, layout.height)
        // Account for the entire supplied array, including padding/unused prefix;
        // no output allocation occurs before these checked bounds.
        let combinedBytes = try product(sum(input.count, outputCount), MemoryLayout<Float>.stride)
        guard combinedBytes <= limits.maximumCombinedBytes else { throw Failure(code: .byteBudgetExceeded, field: "input+output") }
        guard input.count >= required else { throw Failure(code: .bufferTooShort, field: "input") }
        return .init(outputCount: outputCount, packed: .init(width: layout.width, height: layout.height, channels: layout.channels, rowStrideFloats: row))
    }
    private static func finite(_ value: Double, field: String) throws {
        guard value.isFinite else { throw Failure(code: .nonFiniteInput, field: field) }
    }
    private static func unit(_ value: Double, field: String) throws {
        try finite(value, field: field)
        guard value >= 0 && value <= 1 else { throw Failure(code: .sampleOutOfRange, field: field) }
    }
    private static func checkedFloat(_ value: Double, index: Int) throws -> Float {
        let result = Float(value)
        guard value.isFinite, result.isFinite else { throw Failure(code: .nonRepresentableOutput, field: "output", sampleIndex: index) }
        return result
    }
    private static func jitter(_ value: Contract.Vector2) -> Bool {
        value.finite && abs(value.x) <= 0.5 && abs(value.y) <= 0.5
    }

    /// Output: current-to-previous render-pixel displacement with jitter removed.
    /// Direction is normalized BEFORE subtracting previousProjectedJitter-current.
    static func convertMotion(_ input: [Float], layout: BufferLayout, plan: MotionPlan, limits: Limits = .standard) throws -> OwnedFrame {
        let validated = try validate(input, layout, channels: [2], limits: limits)
        guard plan.scale.finite, plan.scale.x != 0, plan.scale.y != 0 else { throw Failure(code: .invalidMotionScale, field: "motion.scale") }
        var deltaX = 0.0, deltaY = 0.0
        if plan.includesJitter {
            guard let pair = plan.projectedJitter else { throw Failure(code: .jitterMetadataRequired, field: "motion.projectedJitter") }
            guard jitter(pair.current), jitter(pair.previous) else { throw Failure(code: .invalidProjectedJitter, field: "motion.projectedJitter") }
            deltaX = pair.previous.x - pair.current.x; deltaY = pair.previous.y - pair.current.y
        } else if plan.projectedJitter != nil {
            // A supplied pair is not applied a second time, but invalid metadata is still refused.
            guard let pair = plan.projectedJitter, jitter(pair.current), jitter(pair.previous) else { throw Failure(code: .invalidProjectedJitter, field: "motion.projectedJitter") }
        }
        let direction = plan.direction == .currentToPrevious ? 1.0 : -1.0
        let factorX = plan.scale.x * (plan.units == .normalizedUV ? Double(layout.width) : 1) * direction
        let factorY = plan.scale.y * (plan.units == .normalizedUV ? Double(layout.height) : 1) * direction
        guard factorX.isFinite, factorY.isFinite else { throw Failure(code: .invalidMotionScale, field: "motion.scale") }
        var output = [Float](repeating: 0, count: validated.outputCount)
        for y in 0..<layout.height {
            for x in 0..<layout.width {
                let source = layout.offsetFloats + y * layout.rowStrideFloats + x * 2
                let target = (y * layout.width + x) * 2
                guard input[source].isFinite, input[source + 1].isFinite else { throw Failure(code: .nonFiniteInput, field: "motion", sampleIndex: source) }
                output[target] = try checkedFloat(Double(input[source]) * factorX - deltaX, index: target)
                output[target + 1] = try checkedFloat(Double(input[source + 1]) * factorY - deltaY, index: target + 1)
            }
        }
        return .init(samples: output, layout: validated.packed, resetHistory: plan.resetHistory)
    }

    /// Only z or 1-z for the same projection/clip interval. No near/far inference,
    /// linearization, reprojection, resampling or camera-matrix reconstruction.
    static func convertDepth(_ input: [Float], layout: BufferLayout, plan: DepthPlan, resetHistory: Bool = false, limits: Limits = .standard) throws -> OwnedFrame {
        let validated = try validate(input, layout, channels: [1], limits: limits)
        guard plan.projection == .identical, plan.sourceEncoding == .normalizedZeroToOne, plan.targetEncoding == .normalizedZeroToOne else {
            throw Failure(code: .projectionConversionNotImplemented, field: "depth.projection")
        }
        var output = [Float](repeating: 0, count: validated.outputCount)
        for y in 0..<layout.height {
            for x in 0..<layout.width {
                let source = layout.offsetFloats + y * layout.rowStrideFloats + x
                let target = y * layout.width + x
                do { try unit(Double(input[source]), field: "depth") }
                catch let failure as Failure { throw Failure(code: failure.code, field: failure.field, sampleIndex: source) }
                output[target] = plan.source == plan.target ? input[source] : Float(1 - Double(input[source]))
            }
        }
        return .init(samples: output, layout: validated.packed, resetHistory: resetHistory)
    }

    /// PQ applies independently to RGB components, NOT an RGB-to-Y luminance
    /// calculation. nits/EDR are display-linear component scales; primaries stay fixed.
    static func convertScalar(_ value: Double, operation: TransferOperation) throws -> Double {
        try finite(value, field: "color")
        func white(_ reference: Double) throws -> Double {
            guard reference.isFinite, reference > 0 else { throw Failure(code: .referenceWhiteRequired, field: "referenceWhiteNits") }
            return reference
        }
        func pqToNits(_ encoded: Double) throws -> Double {
            try unit(encoded, field: "PQ")
            let power = pow(encoded, 1 / 78.84375)
            let normalized = pow(max(power - 0.8359375, 0) / (18.8515625 - 18.6875 * power), 1 / 0.1593017578125)
            return 10_000 * normalized
        }
        func nitsToPQ(_ nits: Double) throws -> Double {
            guard nits.isFinite else { throw Failure(code: .nonRepresentableOutput, field: "nits") }
            guard nits >= 0, nits <= 10_000 else { throw Failure(code: .sampleOutOfRange, field: "nits") }
            let power = pow(nits / 10_000, 0.1593017578125)
            return pow((0.8359375 + 18.8515625 * power) / (1 + 18.6875 * power), 78.84375)
        }
        let result: Double
        switch operation {
        case .sRGBToLinearSDR:
            try unit(value, field: "sRGB-SDR")
            result = value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        case .linearSDRToSRGB:
            try unit(value, field: "linear-SDR")
            result = value <= 0.0031308 ? 12.92 * value : 1.055 * pow(value, 1 / 2.4) - 0.055
        case .pqToNits: result = try pqToNits(value)
        case .nitsToPQ: result = try nitsToPQ(value)
        case .nitsToEDR(let reference): result = value / (try white(reference))
        case .edrToNits(let reference): result = value * (try white(reference))
        case .pqToEDR(let reference): result = try pqToNits(value) / white(reference)
        case .edrToPQ(let reference): result = try nitsToPQ(value * white(reference))
        }
        guard result.isFinite else { throw Failure(code: .nonRepresentableOutput, field: "color") }
        return result
    }

    static func convertColor(_ input: [Float], layout: BufferLayout, plan: ColorPlan, resetHistory: Bool = false, limits: Limits = .standard) throws -> OwnedFrame {
        let validated = try validate(input, layout, channels: [1, 3, 4], limits: limits)
        guard plan.sourcePrimaries == plan.targetPrimaries else { throw Failure(code: .gamutConversionNotImplemented, field: "color.primaries") }
        guard plan.alpha != .premultiplied else { throw Failure(code: .premultipliedAlphaNotSupported, field: "color.alpha") }
        guard (layout.channels == 4 && plan.alpha == .straightLastChannel) || (layout.channels != 4 && plan.alpha == .none) else {
            throw Failure(code: .unsupportedChannels, field: "color.alpha")
        }
        _ = try convertScalar(0, operation: plan.operation) // validate reference parameters before allocation.
        var output = [Float](repeating: 0, count: validated.outputCount)
        for y in 0..<layout.height {
            for x in 0..<layout.width {
                for channel in 0..<layout.channels {
                    let source = layout.offsetFloats + y * layout.rowStrideFloats + x * layout.channels + channel
                    let target = (y * layout.width + x) * layout.channels + channel
                    do {
                        if layout.channels == 4 && channel == 3 {
                            try unit(Double(input[source]), field: "alpha")
                            output[target] = input[source] // bit-preserving copy, including signed zero.
                        } else {
                            output[target] = try checkedFloat(convertScalar(Double(input[source]), operation: plan.operation), index: target)
                        }
                    } catch let failure as Failure {
                        throw Failure(code: failure.code, field: failure.field, sampleIndex: source)
                    }
                }
            }
        }
        return .init(samples: output, layout: validated.packed, resetHistory: resetHistory)
    }
}
