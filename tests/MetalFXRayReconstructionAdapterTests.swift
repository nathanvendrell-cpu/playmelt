import Foundation
import Metal
import MetalFX
import simd

/// Vérifie l'adaptateur sur le vrai GPU : refus des entrées incohérentes, puis
/// séquence de 8 images bruitées réellement débruitées et relues.
/// Ce test ne prouve rien sur un jeu : aucun jeu n'est branché à cet adaptateur.
@main
struct MetalFXRayReconstructionAdapterTests {
    static func main() throws {
        guard #available(macOS 26.0, *) else { print("macOS < 26 : débruiteur MetalFX absent, test ignoré"); return }
        try run()
    }

    @available(macOS 26.0, *)
    static func run() throws {
        typealias R = MetalFXRayReconstructionAdapter
        func expectFailure(_ label: String, _ body: () throws -> Void) {
            var failed = false
            do { try body() } catch { failed = true }
            precondition(failed, label)
        }

        let config = R.Configuration(inputWidth: 960, inputHeight: 540, outputWidth: 1920, outputHeight: 1080)
        try config.validate()
        expectFailure("Rapport d'aspect discordant refusé") {
            try R.Configuration(inputWidth: 960, inputHeight: 700, outputWidth: 1920, outputHeight: 1080).validate()
        }
        expectFailure("Réduction refusée") {
            try R.Configuration(inputWidth: 1920, inputHeight: 1080, outputWidth: 960, outputHeight: 540).validate()
        }

        let projection = simd_float4x4(rows: [
            SIMD4(1.0, 0, 0, 0), SIMD4(0, 1.777, 0, 0), SIMD4(0, 0, -1.0001, -0.10001), SIMD4(0, 0, -1, 0),
        ])
        func meta(_ index: UInt64, reset: Bool, jitter: Float = 0.25) -> R.Metadata {
            R.Metadata(frameIndex: index, resetHistory: reset, jitterX: jitter, jitterY: -jitter,
                       worldToView: matrix_identity_float4x4, viewToClip: projection)
        }
        expectFailure("Jitter > 0,5 px refusé") { try meta(0, reset: true, jitter: 0.75).validate() }
        expectFailure("Projection singulière refusée") {
            var m = meta(0, reset: true); m.viewToClip = simd_float4x4(); try m.validate()
        }

        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            print("Aucun GPU Metal : tests GPU ignorés"); return
        }
        let snapshot = R.capabilitySnapshot(device: device)
        precondition(snapshot.temporalDenoisedScalerAvailable, "\(device.name) sous macOS 26+ doit exposer le débruiteur MetalFX")
        precondition(!snapshot.gameFrameProviderConnected && !snapshot.neuralEngineAccelerationVerified)

        let adapter = try R(configuration: config, device: device)
        print("Débruiteur créé sur \(device.name), échelle acceptée \(adapter.inputContentScaleRange)")

        func texture(_ w: Int, _ h: Int, _ format: MTLPixelFormat, _ usage: MTLTextureUsage) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
            d.usage = usage
            d.storageMode = format == .depth32Float ? .private : .shared
            return device.makeTexture(descriptor: d)!
        }
        func fillHalf(_ t: MTLTexture, channels: Int, _ value: (Int, Int, Int) -> Float) {
            var data = [Float16](repeating: 0, count: t.width * t.height * channels)
            for y in 0..<t.height { for x in 0..<t.width { for c in 0..<channels {
                data[(y * t.width + x) * channels + c] = Float16(value(x, y, c))
            } } }
            t.replace(region: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0,
                      withBytes: data, bytesPerRow: t.width * channels * 2)
        }

        let (iw, ih, ow, oh) = (config.inputWidth, config.inputHeight, config.outputWidth, config.outputHeight)
        let readWrite: MTLTextureUsage = [.shaderRead, .shaderWrite, .renderTarget]
        let color = texture(iw, ih, .rgba16Float, readWrite)
        let depth = texture(iw, ih, .depth32Float, readWrite)
        let motion = texture(iw, ih, .rg16Float, readWrite)
        let albedo = texture(iw, ih, .rgba16Float, readWrite)
        let specular = texture(iw, ih, .rgba16Float, readWrite)
        let normal = texture(iw, ih, .rgba16Float, readWrite)
        let roughness = texture(iw, ih, .r16Float, readWrite)
        let output = texture(ow, oh, .rgba16Float, readWrite)

        // Surface grise uniforme (0,5) perturbée par un bruit déterministe type
        // « peu d'échantillons par pixel » : le débruiteur doit réduire l'écart.
        fillHalf(motion, channels: 2) { _, _, _ in 0 }
        fillHalf(albedo, channels: 4) { _, _, c in c == 3 ? 1 : 0.5 }
        fillHalf(specular, channels: 4) { _, _, c in c == 3 ? 1 : 0.04 }
        fillHalf(normal, channels: 4) { _, _, c in c == 2 ? 1 : 0 }
        fillHalf(roughness, channels: 1) { _, _, _ in 0.6 }
        func noisy(_ frame: Int) {
            fillHalf(color, channels: 4) { x, y, c in
                if c == 3 { return 1 }
                var h = UInt32(truncatingIfNeeded: x &* 73856093 ^ y &* 19349663 ^ frame &* 83492791)
                h = (h ^ (h >> 13)) &* 1274126177
                return 0.5 + (Float(h & 0xFFFF) / 65535 - 0.5) * 0.6
            }
        }
        if let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
            // Profondeur 0,5 partout via un rendu de clear.
            blit.endEncoding()
            let pass = MTLRenderPassDescriptor()
            pass.depthAttachment.texture = depth
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.clearDepth = 0.5
            pass.depthAttachment.storeAction = .store
            cb.makeRenderCommandEncoder(descriptor: pass)!.endEncoding()
            cb.commit(); cb.waitUntilCompleted()
        }

        func frame(_ index: UInt64, reset: Bool) -> R.Frame {
            R.Frame(color: color, depth: depth, motion: motion, diffuseAlbedo: albedo, specularAlbedo: specular,
                    normal: normal, roughness: roughness, output: output, metadata: meta(index, reset: reset))
        }
        guard let rejected = queue.makeCommandBuffer() else { fatalError("command buffer") }
        expectFailure("Image hors séquence sans reset refusée") { try adapter.encode(commandBuffer: rejected, frame: frame(5, reset: false)) }
        let wrongFormat = texture(iw, ih, .rgba32Float, readWrite)
        expectFailure("Format de couleur non déclaré refusé") {
            try adapter.encode(commandBuffer: rejected, frame: R.Frame(
                color: wrongFormat, depth: depth, motion: motion, diffuseAlbedo: albedo, specularAlbedo: specular,
                normal: normal, roughness: roughness, output: output, metadata: meta(0, reset: true)))
        }
        expectFailure("Distance spéculaire non déclarée refusée") {
            var f = frame(0, reset: true); f.specularHitDistance = roughness
            try adapter.encode(commandBuffer: rejected, frame: f)
        }

        func stats(_ t: MTLTexture, step: Int) -> (mean: Float, deviation: Float, finite: Bool) {
            var data = [Float16](repeating: 0, count: t.width * t.height * 4)
            t.getBytes(&data, bytesPerRow: t.width * 8, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
            var values: [Float] = []
            for y in stride(from: t.height / 4, to: 3 * t.height / 4, by: step) {
                for x in stride(from: t.width / 4, to: 3 * t.width / 4, by: step) { values.append(Float(data[(y * t.width + x) * 4])) }
            }
            let mean = values.reduce(0, +) / Float(values.count)
            let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(values.count)
            return (mean, variance.squareRoot(), values.allSatisfy { $0.isFinite })
        }

        let start = Date()
        for index in 0..<8 {
            noisy(index)
            guard let cb = queue.makeCommandBuffer() else { fatalError("command buffer") }
            try adapter.encode(commandBuffer: cb, frame: frame(UInt64(index), reset: index == 0))
            cb.commit(); cb.waitUntilCompleted()
            precondition(cb.status == .completed, "Image \(index) : \(String(describing: cb.error))")
        }
        let perFrameMs = Date().timeIntervalSince(start) * 1000 / 8
        let input = stats(color, step: 3), result = stats(output, step: 6)
        print(String(format: "Entrée : moyenne %.3f écart %.3f · Sortie 1920×1080 : moyenne %.3f écart %.3f · %.1f ms/image (CPU+GPU, indicatif)",
                     input.mean, input.deviation, result.mean, result.deviation, perFrameMs))
        precondition(result.finite, "La sortie doit être finie")
        precondition(result.mean > 0.05, "La sortie ne doit pas être noire : le débruiteur a-t-il écrit ?")
        precondition(result.deviation < input.deviation, "Le débruiteur doit réduire le bruit")
        print("Adaptateur MetalFX Temporal Denoised : tous les contrôles passent.")
    }
}
