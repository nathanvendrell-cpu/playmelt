import Foundation
import Metal
import MetalFX

@main
struct MetalFXRayReconstructionAdapterTests {
    static func main() throws {
        typealias R = MetalFXRayReconstructionAdapter
        print("Starting MetalFXRayReconstructionAdapter tests...")

        // 1. Validation de la configuration
        let validConfig = R.Configuration(
            inputWidth: 1280, inputHeight: 720,
            outputWidth: 2560, outputHeight: 1440
        )
        try validConfig.validate()

        // Configuration invalide (aspect ratio différent)
        let invalidAspect = R.Configuration(
            inputWidth: 1280, inputHeight: 800,
            outputWidth: 2560, outputHeight: 1440
        )
        var caughtAspect = false
        do { try invalidAspect.validate() } catch { caughtAspect = true }
        precondition(caughtAspect, "L'aspect ratio discordant doit être rejeté")

        // 2. Validation des métadonnées
        var meta = R.Metadata(
            sequence: UUID(), frameIndex: 0, resetHistory: true,
            jitterX: 0.25, jitterY: -0.25, preExposure: 1.0
        )
        try meta.validate()

        meta.jitterX = 2.0 // out of bounds
        var caughtJitter = false
        do { try meta.validate() } catch { caughtJitter = true }
        precondition(caughtJitter, "Le jitter > 1.0 doit être rejeté")

        // 3. Test de support matériel sur Apple Silicon
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("No Metal device available; skipping live GPU tests")
            return
        }

        let supported = R.supports(device: device)
        print("Device '\(device.name)' Ray Reconstruction support:", supported)
        precondition(supported, "M3 Max sous macOS 27 doit supporter MetalFX Ray Reconstruction")

        let snapshot = R.capabilitySnapshot(device: device)
        precondition(snapshot.nativeRayReconstructionAvailable, "Capability snapshot must report available")
        precondition(snapshot.neuralEngineAccelerated, "Capability snapshot must report neural acceleration")

        // 4. Instanciation du Scaler
        let adapter = try R(configuration: validConfig, device: device)
        print("Adapter created successfully with valid configuration")

        // 5. Test d'encodage complet avec textures réelles
        guard let queue = device.makeCommandQueue() else {
            fatalError("Could not create MTLCommandQueue")
        }

        func makeTex(_ w: Int, _ h: Int, _ fmt: MTLPixelFormat, _ usage: MTLTextureUsage = [.shaderRead, .shaderWrite]) -> MTLTexture {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: w, height: h, mipmapped: false)
            td.usage = usage
            return device.makeTexture(descriptor: td)!
        }

        let inW = validConfig.inputWidth, inH = validConfig.inputHeight
        let outW = validConfig.outputWidth, outH = validConfig.outputHeight

        let colorTex = makeTex(inW, inH, .rgba16Float, [.shaderRead])
        let depthTex = makeTex(inW, inH, .depth32Float, [.shaderRead])
        let motionTex = makeTex(inW, inH, .rg16Float, [.shaderRead])
        let albedoTex = makeTex(inW, inH, .rgba16Float, [.shaderRead])
        let normalTex = makeTex(inW, inH, .rgba16Float, [.shaderRead])
        let roughnessTex = makeTex(inW, inH, .r8Unorm, [.shaderRead])
        let outTex = makeTex(outW, outH, .rgba16Float, [.shaderWrite])

        let frame = R.Frame(
            color: colorTex,
            depth: depthTex,
            motion: motionTex,
            diffuseAlbedo: albedoTex,
            normal: normalTex,
            roughness: roughnessTex,
            output: outTex,
            metadata: R.Metadata(
                sequence: UUID(), frameIndex: 1, resetHistory: true,
                jitterX: 0.1, jitterY: -0.1, preExposure: 1.0
            )
        )

        guard let cb = queue.makeCommandBuffer() else {
            fatalError("Could not make command buffer")
        }

        try adapter.encode(commandBuffer: cb, frame: frame)
        cb.commit()
        cb.waitUntilCompleted()

        precondition(cb.status == .completed, "Command buffer execution must succeed")
        print("Full MetalFX Ray Reconstruction pass completed on GPU! Status: COMPLETED")
        print("ALL Ray Reconstruction Adapter tests passed with flying colors!")
    }
}
