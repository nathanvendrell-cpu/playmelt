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
                    "refreshRate": mode.refreshRate, "isPrimary": displayID == CGMainDisplayID(),
                    "isBuiltIn": CGDisplayIsBuiltin(displayID) != 0,
                    "originX": CGDisplayBounds(displayID).origin.x, "originY": CGDisplayBounds(displayID).origin.y,
                    "desktopWidth": mode.width, "desktopHeight": mode.height,
                    "wineIndex": index]
        }
    }

    static func hints() -> [String: Any] {
        let displays = screens()
        return ["primary": displays.first(where:{$0["isPrimary"] as? Bool == true}) as Any? ?? NSNull(), "displays": displays]
    }

    /// The current Wine driver can only switch its primary adapter. Never guess
    /// that a NSScreen array index is a Windows/DXGI monitor index.
    static func launchTarget(_ displays:[[String:Any]],requested:String="primary")throws->[String:Any] {
        let external=displays.filter{$0["isBuiltIn"] as? Bool == false}
        let chosen:[String:Any]?
        if requested != "primary" {chosen=external.first{$0["id"] as? String == requested}}
        else {chosen=external.first{$0["isPrimary"] as? Bool == true} ?? (external.isEmpty ? displays.first{$0["isPrimary"] as? Bool == true} : external.count == 1 ? external[0] : nil)}
        guard let chosen else {throw NSError(domain:"Playmelt.Display",code:1,userInfo:[NSLocalizedDescriptionKey:"Rebranchez l’écran sélectionné pour ce jeu ou choisissez un écran disponible."])}
        guard chosen["isPrimary"] as? Bool == true else {throw NSError(domain:"Playmelt.Display",code:2,userInfo:[NSLocalizedDescriptionKey:"Ce moteur doit encore être validé sur un écran externe secondaire. Le lancement est suspendu pour préserver l’écran du Mac."])}
        guard let width=chosen["desktopWidth"] as? Int,let height=chosen["desktopHeight"] as? Int,(640...16384).contains(width),(480...16384).contains(height),let hz=chosen["refreshRate"] as? Double,hz.isFinite,hz>0,hz<=1000 else {throw NSError(domain:"Playmelt.Display",code:3,userInfo:[NSLocalizedDescriptionKey:"Le mode actuel de l’écran externe n’a pas pu être vérifié."])}
        return chosen
    }
    static func guardedEnvironment(_ base:[String:String],target:[String:Any],library:URL)throws->[String:String] {
        guard library.isFileURL,!library.path.contains(":"),FileManager.default.fileExists(atPath:library.path) else {throw NSError(domain:"Playmelt.Display",code:4,userInfo:[NSLocalizedDescriptionKey:"La protection des écrans est absente. Réinstallez Playmelt avant de lancer ce jeu."])}
        var env=base
        env["DYLD_INSERT_LIBRARIES"]=([library.path]+(base["DYLD_INSERT_LIBRARIES"] ?? "").split(separator:":").map(String.init).filter{$0 != library.path}).joined(separator:":")
        env["SDL_VIDEO_MAC_FULLSCREEN_SPACES"]="0"
        env["PLAYMELT_DISPLAY_POLICY"]="external-windowed-v1"
        env["PLAYMELT_DISPLAY_GUARD_LIBRARY"]=library.path
        env["PLAYMELT_DISPLAY_INSERT_LIBRARIES"]=env["DYLD_INSERT_LIBRARIES"]
        let width=target["desktopWidth"] as? Int ?? 1280,height=target["desktopHeight"] as? Int ?? 720
        // Plein écran sans bordure sur l’écran visé (mode Jeu macOS) ; la protection interdit toujours capture et changement de mode.
        env["PLAYMELT_GAME_WIDTH"]=String(max(640,width));env["PLAYMELT_GAME_HEIGHT"]=String(max(480,height))
        env["PLAYMELT_GAME_X"]=String(Int(target["originX"] as? Double ?? 0));env["PLAYMELT_GAME_Y"]=String(Int(target["originY"] as? Double ?? 0))
        env["PLAYMELT_DISPLAY_TARGET"]=target["id"] as? String ?? ""
        if let scale=target["scale"] as? Double,[1.0,2.0].contains(scale),let pixelWidth=target["width"] as? Int,let pixelHeight=target["height"] as? Int {
            env["PLAYMELT_DISPLAY_SCALE"]=String(Int(scale))
            env["PLAYMELT_DISPLAY_DESKTOP_WIDTH"]=String(width);env["PLAYMELT_DISPLAY_DESKTOP_HEIGHT"]=String(height)
            env["PLAYMELT_DISPLAY_PIXEL_WIDTH"]=String(pixelWidth);env["PLAYMELT_DISPLAY_PIXEL_HEIGHT"]=String(pixelHeight)
        }
        return env
    }
}
