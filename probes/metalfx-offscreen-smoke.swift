import Foundation
import Metal
import MetalFX
import CoreGraphics
import ImageIO
import CryptoKit

// Bounded synthetic GPU validation. This never starts or attaches to a game.
// Its timings are not gameplay FPS, and its images are not game captures.
@main
struct MetalFXOffscreenSmoke {
    struct Failure: Error { let message: String }
    static let inputWidth = 1280, inputHeight = 800
    static let outputWidth = 2560, outputHeight = 1600

    static let source = """
    #include <metal_stdlib>
    using namespace metal;
    float3 test_scene(float2 uv) {
        float grid = float((uint(floor(uv.x * 32.0)) + uint(floor(uv.y * 20.0))) & 1);
        float3 c = mix(float3(0.055, 0.09, 0.14), float3(0.18, 0.27, 0.36), grid);
        if (uv.x < 0.32) {
            float stripe = smoothstep(-0.15, 0.15, sin(uv.x * 900.0 + uv.y * 90.0));
            c = mix(float3(0.08, 0.12, 0.18), float3(0.70, 0.75, 0.82), stripe);
        }
        float2 p = (uv - float2(0.58, 0.49)) * float2(1.6, 1.0);
        float radius = length(p);
        if (radius < 0.23) {
            float z = sqrt(max(0.0, 1.0 - pow(radius / 0.23, 2.0)));
            float shine = pow(max(0.0, z * 0.82 - p.x * 1.3 - p.y * 1.8), 12.0);
            c = float3(0.07, 0.22, 0.32) + z * float3(0.09, 0.21, 0.26) + shine * 0.38;
        }
        float wire = abs(uv.y - 0.22 - uv.x * 0.51);
        if (wire < 0.0018) c = float3(0.86, 0.42, 0.13);
        return clamp(c, 0.0, 1.0);
    }
    kernel void inputs(texture2d<half, access::write> color [[texture(0)]],
                       texture2d<float, access::write> depth [[texture(1)]],
                       texture2d<half, access::write> motion [[texture(2)]],
                       uint2 p [[thread_position_in_grid]]) {
        if (p.x >= color.get_width() || p.y >= color.get_height()) return;
        float2 uv = (float2(p) + 0.5) / float2(color.get_width(), color.get_height());
        color.write(half4(half3(test_scene(uv)), 1.0h), p);
        float d = length((uv - float2(0.58, 0.49)) * float2(1.6, 1.0)) < 0.23 ? 0.35 : 0.80;
        depth.write(float4(d, 0, 0, 0), p);
        // Static geometry, zero projection jitter: true motion is zero.
        motion.write(half4(0), p);
    }
    kernel void reference(texture2d<half, access::write> color [[texture(0)]],
                          uint2 p [[thread_position_in_grid]]) {
        if (p.x >= color.get_width() || p.y >= color.get_height()) return;
        float2 uv = (float2(p) + 0.5) / float2(color.get_width(), color.get_height());
        color.write(half4(half3(test_scene(uv)), 1.0h), p);
    }
    kernel void bilinear(texture2d<half, access::sample> input [[texture(0)]],
                         texture2d<half, access::write> output [[texture(1)]],
                         uint2 p [[thread_position_in_grid]]) {
        if (p.x >= output.get_width() || p.y >= output.get_height()) return;
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 uv = (float2(p) + 0.5) / float2(output.get_width(), output.get_height());
        output.write(input.sample(s, uv), p);
    }
    """

    static func complete(_ cb: MTLCommandBuffer) throws {
        let finished = DispatchSemaphore(value: 0)
        cb.addCompletedHandler { _ in finished.signal() }
        cb.commit()
        guard finished.wait(timeout: .now() + 30) == .success else { throw Failure(message: "GPU completion timeout") }
        guard cb.status == .completed else { throw Failure(message: "GPU failure: \(cb.error?.localizedDescription ?? "unknown")") }
    }

    static func texture(_ device: MTLDevice, width: Int, height: Int, format: MTLPixelFormat,
                        usage: MTLTextureUsage, storage: MTLStorageMode = .private) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        d.usage = usage; d.storageMode = storage
        guard let t = device.makeTexture(descriptor: d) else { throw Failure(message: "texture allocation failed") }
        return t
    }

    static func dispatch(_ cb: MTLCommandBuffer, pipeline: MTLComputePipelineState,
                         textures: [MTLTexture], width: Int, height: Int) throws {
        guard let encoder = cb.makeComputeCommandEncoder() else { throw Failure(message: "compute encoder unavailable") }
        encoder.setComputePipelineState(pipeline)
        for (index, texture) in textures.enumerated() { encoder.setTexture(texture, index: index) }
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
    }

    static func readback(_ texture: MTLTexture, queue: MTLCommandQueue) throws -> [UInt16] {
        let row = texture.width * 8, size = row * texture.height
        guard let buffer = texture.device.makeBuffer(length: size, options: .storageModeShared),
              let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { throw Failure(message: "readback allocation failed") }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1), to: buffer,
                  destinationOffset: 0, destinationBytesPerRow: row, destinationBytesPerImage: size)
        blit.endEncoding(); try complete(cb)
        return Array(UnsafeBufferPointer(start: buffer.contents().bindMemory(to: UInt16.self, capacity: size / 2), count: size / 2))
    }

    static func writePNG(_ pixels: [UInt16], to path: URL) throws -> [String: Any] {
        var bytes = [UInt8](repeating: 255, count: outputWidth * outputHeight * 4)
        var minimum = Float.greatestFiniteMagnitude, maximum = -Float.greatestFiniteMagnitude
        for pixel in 0..<(outputWidth * outputHeight) {
            for channel in 0..<3 {
                let index = pixel * 4 + channel, f = Float(Float16(bitPattern: pixels[index]))
                guard f.isFinite else { throw Failure(message: "non-finite output sample") }
                minimum = min(minimum, f); maximum = max(maximum, f)
                let x = max(0, min(1, f)), srgb = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
                bytes[index] = UInt8(max(0, min(255, Int((srgb * 255).rounded()))))
            }
        }
        guard maximum - minimum > 0.05 else { throw Failure(message: "blank or constant output") }
        let data = Data(bytes), provider = CGDataProvider(data: data as CFData)
        guard let provider, let image = CGImage(width: outputWidth, height: outputHeight, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: outputWidth * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(path as CFURL, "public.png" as CFString, 1, nil) else {
            throw Failure(message: "PNG encoder unavailable")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure(message: "PNG write failed") }
        return ["path": path.path, "width": outputWidth, "height": outputHeight,
                "rgbMinimum": minimum, "rgbMaximum": maximum,
                "sha256": SHA256.hash(data: try Data(contentsOf: path)).map { String(format: "%02x", $0) }.joined()]
    }

    static func run(output: URL) throws -> [String: Any] {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw Failure(message: "Metal device/queue unavailable") }
        guard MetalFXFrameAdapter.supports(device: device) else { throw Failure(message: "MetalFX temporal unsupported") }
        let createStart = Date()
        let adapter = try MetalFXFrameAdapter(device: device, configuration: .init(inputWidth: inputWidth, inputHeight: inputHeight,
                         outputWidth: outputWidth, outputHeight: outputHeight, depthFormat: .r32Float))
        let createMs = Date().timeIntervalSince(createStart) * 1000
        let usages = adapter.requiredUsages
        let color = try texture(device, width: inputWidth, height: inputHeight, format: .rgba16Float, usage: usages.color.union(.shaderWrite))
        let depth = try texture(device, width: inputWidth, height: inputHeight, format: .r32Float, usage: usages.depth.union(.shaderWrite))
        let motion = try texture(device, width: inputWidth, height: inputHeight, format: .rg16Float, usage: usages.motion.union(.shaderWrite))
        let result = try texture(device, width: outputWidth, height: outputHeight, format: .rgba16Float, usage: usages.output.union(.pixelFormatView))
        let reference = try texture(device, width: outputWidth, height: outputHeight, format: .rgba16Float, usage: [.shaderWrite, .shaderRead])
        let baseline = try texture(device, width: outputWidth, height: outputHeight, format: .rgba16Float, usage: [.shaderWrite, .shaderRead])
        let exposure = try texture(device, width: 1, height: 1, format: .r16Float, usage: usages.exposure, storage: .shared)
        var one = Float16(1)
        withUnsafeBytes(of: &one) { exposure.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 2) }
        let library = try device.makeLibrary(source: source, options: nil)
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let f = library.makeFunction(name: name) else { throw Failure(message: "fixture shader missing") }
            return try device.makeComputePipelineState(function: f)
        }
        let inputPipeline = try pipeline("inputs"), referencePipeline = try pipeline("reference"), bilinearPipeline = try pipeline("bilinear")
        guard let initial = queue.makeCommandBuffer() else { throw Failure(message: "initial command buffer missing") }
        try dispatch(initial, pipeline: inputPipeline, textures: [color, depth, motion], width: inputWidth, height: inputHeight)
        try dispatch(initial, pipeline: referencePipeline, textures: [reference], width: outputWidth, height: outputHeight)
        try dispatch(initial, pipeline: bilinearPipeline, textures: [color, baseline], width: outputWidth, height: outputHeight)
        try complete(initial)
        var gpuMs: [Double] = []
        let sequences = [UUID(), UUID()]
        func frame(_ index: Int, output: MTLTexture) -> MetalFXFrameAdapter.Frame {
            .init(color: color, depth: depth, motion: motion, exposure: exposure, output: output,
                  metadata: .init(sequence: sequences[index < 4 ? 0 : 1], frameIndex: UInt64(index % 4),
                                  resetHistory: index == 0 || index == 4, jitterX: 0, jitterY: 0, depth: .forward,
                                  motion: .currentToPreviousPixelsWithoutJitter,
                                  color: .linearRec709SDROpaque, stage: .sceneBeforeUI))
        }
        func rejects(_ expected: MetalFXFrameAdapter.Failure, _ action: () throws -> Void) throws {
            do { try action() }
            catch let actual as MetalFXFrameAdapter.Failure {
                guard actual == expected else { throw Failure(message: "unexpected adapter failure: \(actual)") }
                return
            }
            throw Failure(message: "adapter accepted invalid state: \(expected)")
        }
        guard let outputView = result.makeTextureView(pixelFormat: .rgba16Float), let viewCB = queue.makeCommandBuffer() else {
            throw Failure(message: "texture-view validation fixture unavailable")
        }
        try rejects(.aliasedTextures) { try adapter.encode(frame(0, output: outputView), commandBuffer: viewCB) }
        var lastCB: MTLCommandBuffer?
        for index in 0..<8 {
            guard let cb = queue.makeCommandBuffer() else { throw Failure(message: "frame command buffer missing") }
            try adapter.encode(frame(index, output: result), commandBuffer: cb)
            if index == 0 {
                guard let concurrent = queue.makeCommandBuffer() else { throw Failure(message: "concurrent validation fixture unavailable") }
                try rejects(.frameInFlight) { try adapter.encode(frame(1, output: result), commandBuffer: concurrent) }
            }
            try complete(cb)
            lastCB = cb
            if cb.gpuEndTime > cb.gpuStartTime && cb.gpuStartTime > 0 { gpuMs.append((cb.gpuEndTime - cb.gpuStartTime) * 1000) }
        }
        guard let lastCB else { throw Failure(message: "completed command buffer missing") }
        try rejects(.wrongCommandBuffer) { try adapter.encode(frame(7, output: result), commandBuffer: lastCB) }
        let temporalPixels = try readback(result, queue: queue)
        let baselinePixels = try readback(baseline, queue: queue)
        let referencePixels = try readback(reference, queue: queue)
        let images = try [writePNG(baselinePixels, to: output.appendingPathComponent("bilinear.png")),
                          writePNG(temporalPixels, to: output.appendingPathComponent("metalfx-temporal.png")),
                          writePNG(referencePixels, to: output.appendingPathComponent("reference-native.png"))]
        return ["schema": 1, "status": "gpu-completed", "device": device.name,
                "inputWidth": inputWidth, "inputHeight": inputHeight, "outputWidth": outputWidth, "outputHeight": outputHeight,
                "synthetic": true, "gameLaunched": false, "gameFrameProviderConnected": false,
                "framesEncoded": 8, "historyResetCount": 2, "jitter": [0, 0], "scalerCreationWallMs": createMs,
                "validatedGuards": ["texture-view-rejected", "concurrent-frame-rejected", "completed-command-buffer-rejected"],
                "adapterCommandBufferGpuMs": gpuMs, "images": images,
                "limits": ["Synthetic static scene with zero jitter and motion, not a gameplay or quality benchmark.",
                           "GPU timings cover only this fixture's adapter command buffers; not game FPS.",
                           "No D3DMetal/DXMT game textures, UI, denoising or interpolation are connected."]]
    }

    static func main() {
        do {
            guard CommandLine.arguments.count == 2, CommandLine.arguments[1].hasPrefix("/") else { throw Failure(message: "pass a new absolute output directory") }
            let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            guard !FileManager.default.fileExists(atPath: output.path) else { throw Failure(message: "output already exists") }
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            let receipt = try run(output: output)
            let data = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: output.appendingPathComponent("receipt.json"), options: [.atomic])
            FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
        } catch {
            let data = try! JSONSerialization.data(withJSONObject: ["status": "failed", "error": String(describing: error)], options: [.sortedKeys])
            FileHandle.standardError.write(data); FileHandle.standardError.write(Data([10])); exit(1)
        }
    }
}
