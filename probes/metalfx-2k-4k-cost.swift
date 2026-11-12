// Mesure du coût GPU de MetalFX en sortie 2K et 4K, par mode DLSS.
// - Temporal scaler (= DLSS Super Resolution traduit par D3DMetal)
// - Temporal denoised scaler (= DLSS Ray Reconstruction traduit par D3DMetal)
// Temps GPU par horodatage du command buffer (gpuStartTime/gpuEndTime),
// 10 images de chauffe puis médiane sur 30. Textures privées, sans remplissage
// CPU : le coût mesuré est celui de MetalFX seul, pas celui du jeu.
// swiftc -O -target arm64-apple-macos26.0 probes/metalfx-2k-4k-cost.swift -framework Metal -framework MetalFX -o /tmp/x
import Foundation
import Metal
import MetalFX
import simd

let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!
let modes: [(String, Double)] = [("Qualité", 1.5), ("Équilibré", 1.72), ("Performance", 2.0), ("Ultra perf.", 3.0)]
let outputs: [(String, Int, Int)] = [("2K", 2560, 1440), ("4K", 3840, 2160)]

func tex(_ w: Int, _ h: Int, _ f: MTLPixelFormat) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: w, height: h, mipmapped: false)
    d.usage = [.shaderRead, .shaderWrite, .renderTarget]; d.storageMode = .private
    return device.makeTexture(descriptor: d)!
}
func median(_ v: [Double]) -> Double { let s = v.sorted(); return s[s.count / 2] }
func time(_ encode: (MTLCommandBuffer, Int) -> Void) -> Double {
    var samples: [Double] = []
    for i in 0..<40 {
        let cb = queue.makeCommandBuffer()!
        encode(cb, i); cb.commit(); cb.waitUntilCompleted()
        precondition(cb.status == .completed, "\(String(describing: cb.error))")
        if i >= 10 { samples.append((cb.gpuEndTime - cb.gpuStartTime) * 1000) }
    }
    return median(samples)
}

var rows: [[String: Any]] = []
print("Appareil : \(device.name) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
for (label, ow, oh) in outputs {
    for (mode, factor) in modes {
        let iw = Int((Double(ow) / factor).rounded()), ih = Int((Double(oh) / factor).rounded())
        var row: [String: Any] = ["output": label, "outputSize": "\(ow)x\(oh)", "mode": mode, "inputSize": "\(iw)x\(ih)"]

        let sd = MTLFXTemporalScalerDescriptor()
        sd.colorTextureFormat = .rgba16Float; sd.depthTextureFormat = .depth32Float
        sd.motionTextureFormat = .rg16Float; sd.outputTextureFormat = .rgba16Float
        sd.inputWidth = iw; sd.inputHeight = ih; sd.outputWidth = ow; sd.outputHeight = oh
        let maxSR = MTLFXTemporalScalerDescriptor.supportedInputContentMaxScale(device: device)
        if Double(maxSR) + 1e-3 >= factor, let sr = sd.makeTemporalScaler(device: device) {
            let c = tex(iw, ih, .rgba16Float), d = tex(iw, ih, .depth32Float), m = tex(iw, ih, .rg16Float), o = tex(ow, oh, .rgba16Float)
            sr.colorTexture = c; sr.depthTexture = d; sr.motionTexture = m; sr.outputTexture = o
            sr.inputContentWidth = iw; sr.inputContentHeight = ih
            row["superResolutionGpuMs"] = time { cb, i in sr.reset = i == 0; sr.jitterOffsetX = 0.25; sr.encode(commandBuffer: cb) }
        } else { row["superResolutionGpuMs"] = "refusé (max ×\(maxSR))" }

        let dd = MTLFXTemporalDenoisedScalerDescriptor()
        dd.colorTextureFormat = .rgba16Float; dd.depthTextureFormat = .depth32Float; dd.motionTextureFormat = .rg16Float
        dd.diffuseAlbedoTextureFormat = .rgba16Float; dd.specularAlbedoTextureFormat = .rgba16Float
        dd.normalTextureFormat = .rgba16Float; dd.roughnessTextureFormat = .r16Float; dd.outputTextureFormat = .rgba16Float
        dd.inputWidth = iw; dd.inputHeight = ih; dd.outputWidth = ow; dd.outputHeight = oh
        if let rr = dd.makeTemporalDenoisedScaler(device: device) {
            let f = Float(ow) / Float(iw)
            row["rayReconstructionScaleRange"] = "×\(rr.inputContentMinScale)–×\(rr.inputContentMaxScale)"
            if f >= rr.inputContentMinScale - 1e-3 && f <= rr.inputContentMaxScale + 1e-3 {
                rr.colorTexture = tex(iw, ih, .rgba16Float); rr.depthTexture = tex(iw, ih, .depth32Float)
                rr.motionTexture = tex(iw, ih, .rg16Float); rr.diffuseAlbedoTexture = tex(iw, ih, .rgba16Float)
                rr.specularAlbedoTexture = tex(iw, ih, .rgba16Float); rr.normalTexture = tex(iw, ih, .rgba16Float)
                rr.roughnessTexture = tex(iw, ih, .r16Float); rr.outputTexture = tex(ow, oh, .rgba16Float)
                rr.worldToViewMatrix = matrix_identity_float4x4
                rr.viewToClipMatrix = simd_float4x4(rows: [SIMD4(1, 0, 0, 0), SIMD4(0, 1.777, 0, 0), SIMD4(0, 0, -1.0001, -0.10001), SIMD4(0, 0, -1, 0)])
                row["rayReconstructionGpuMs"] = time { cb, i in rr.shouldResetHistory = i == 0; rr.jitterOffsetX = 0.25; rr.encode(commandBuffer: cb) }
            } else { row["rayReconstructionGpuMs"] = "refusé (échelle ×\(f))" }
        } else { row["rayReconstructionGpuMs"] = "création refusée" }
        rows.append(row)
        func fmt(_ v: Any?) -> String { (v as? Double).map { String(format: "%.2f ms", $0) } ?? "\(v ?? "-")" }
        print("\(label) \(mode.padding(toLength: 12, withPad: " ", startingAt: 0)) rendu \(iw)×\(ih) · SR \(fmt(row["superResolutionGpuMs"])) · RR \(fmt(row["rayReconstructionGpuMs"])) \(row["rayReconstructionScaleRange"] ?? "")")
    }
}
if CommandLine.arguments.count > 1 {
    let json = try JSONSerialization.data(withJSONObject: ["device": device.name, "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "method": "gpuEndTime-gpuStartTime, median of 30 after 10 warm-up, private textures, MetalFX only", "rows": rows], options: [.prettyPrinted, .sortedKeys])
    try json.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
}
