import AppKit
import Foundation

// Package the approved Playmelt artwork without redrawing or recolouring it.
let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let resources = project.appendingPathComponent("Resources")
let sourceURL = resources.appendingPathComponent("PlaymeltIcon.png")
let products = project.appendingPathComponent("Products.noindex")
let iconset = products.appendingPathComponent("AppIcon.iconset")
let fm = FileManager.default
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
guard let source = NSImage(contentsOf: sourceURL), source.size.width > 0, source.size.height > 0 else {
    fatalError("Approved Resources/PlaymeltIcon.png is missing or invalid")
}
guard abs(source.size.width-source.size.height) < 0.5 else {
    fatalError("Approved icon must be square; refusing to crop or distort artwork")
}
func png(_ pixels: Int) -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot allocate icon bitmap") }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    source.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .sourceOver, fraction: 1)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode icon") }
    return data
}
for size in [16, 32, 128, 256, 512] {
    try png(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"), options: .atomic)
    try png(size*2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"), options: .atomic)
}
try png(1024).write(to: products.appendingPathComponent("AppIcon-preview.png"), options: .atomic)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Resources/AppIcon.icns packaged from approved PlaymeltIcon.png")
