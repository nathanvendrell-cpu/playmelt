// Read-only native MetalFX capability queries. No command queues, scalers,
// textures, captures, game processes, global settings, or GPU workloads.
import Foundation
import Metal
import MetalFX

func record(_ api: String, available: Bool, supported: Bool?) -> [String: Any] {
    ["api": api, "available": available, "supported": supported as Any? ?? NSNull(),
     "source": "MetalFX supportsDevice"]
}
let version = ProcessInfo.processInfo.operatingSystemVersion
var result: [String: Any] = ["schema": 1, "kind": "playmelt-metal-native-capabilities",
                             "os": ["major": version.majorVersion, "minor": version.minorVersion, "patch": version.patchVersion],
                             "device": NSNull(), "features": [:],
                             "limits": ["read-only capability advertisement; no scaler created or workload executed",
                                        "not evidence of Spider-Man 2 integration, output quality, DLSS or FPS"]]
guard let device = MTLCreateSystemDefaultDevice() else {
    result["status"] = "no_device"
    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10])); exit(1)
}
result["device"] = ["name": device.name, "isLowPower": device.isLowPower,
                    "isRemovable": device.isRemovable, "isHeadless": device.isHeadless]
var features: [String: Any] = [:]
if #available(macOS 13.0, *) {
    features["spatial"] = record("MTLFXSpatialScalerDescriptor.supportsDevice", available: true,
                                  supported: MTLFXSpatialScalerDescriptor.supportsDevice(device))
    features["temporal"] = record("MTLFXTemporalScalerDescriptor.supportsDevice", available: true,
                                   supported: MTLFXTemporalScalerDescriptor.supportsDevice(device))
} else {
    features["spatial"] = record("MTLFXSpatialScalerDescriptor.supportsDevice", available: false, supported: nil)
    features["temporal"] = record("MTLFXTemporalScalerDescriptor.supportsDevice", available: false, supported: nil)
}
if #available(macOS 26.0, *) {
    features["temporalDenoised"] = record("MTLFXTemporalDenoisedScalerDescriptor.supportsDevice", available: true,
                                           supported: MTLFXTemporalDenoisedScalerDescriptor.supportsDevice(device))
    features["frameInterpolation"] = record("MTLFXFrameInterpolatorDescriptor.supportsDevice", available: true,
                                             supported: MTLFXFrameInterpolatorDescriptor.supportsDevice(device))
} else {
    features["temporalDenoised"] = record("MTLFXTemporalDenoisedScalerDescriptor.supportsDevice", available: false, supported: nil)
    features["frameInterpolation"] = record("MTLFXFrameInterpolatorDescriptor.supportsDevice", available: false, supported: nil)
}
result["features"] = features; result["status"] = "queried"
let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
