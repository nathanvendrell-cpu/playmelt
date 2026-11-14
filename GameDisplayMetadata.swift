import AppKit
import CoreGraphics
import Foundation

/// Display metadata only. This never changes a mode, captures pixels or allocates GPU work.
enum GameDisplayMetadata {
    static func screens() -> [[String: Any]] {
        NSScreen.screens.enumerated().compactMap { index, screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let displayID = CGDirectDisplayID(number.uint32Value)
            guard let reference = CGDisplayCreateUUIDFromDisplayID(displayID),
                  let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
            let identifier = CFUUIDCreateString(nil, reference.takeRetainedValue()) as String
            let scale = Double(screen.backingScaleFactor)
            // Use the current framebuffer, including an explicitly scaled Retina mode.
            let width = scale > 1 ? mode.pixelWidth : mode.width
            let height = scale > 1 ? mode.pixelHeight : mode.height
            return ["id": identifier, "name": screen.localizedName,
                    "displayID": number.uint32Value, "scale": scale,
                    "width": width, "height": height,
                    "nativeWidth": width, "nativeHeight": height,
                    "refreshRate": mode.refreshRate, "isPrimary": index == 0,
                    "wineIndex": index]
        }
    }

    static func hints() -> [String: Any] {
        let displays = screens()
        return ["primary": displays.first as Any? ?? NSNull(), "displays": displays]
    }
}
