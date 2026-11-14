import AppKit
import ImageIO

/// Identité Dock par jeu.
///
/// Un lanceur Wine nu n'a aucune identité de bundle : le Dock affiche une
/// icône générique. Ce composant crée un bundle .app **par jeu** — clones APFS
/// de wine/wineserver du moteur, liens `lib`/`share` vers l'engine, Info.plist
/// nommé d'après le jeu, icône .icns générée depuis l'artwork local du jeu —
/// et c'est le wine de CE bundle que les lanceurs exécutent. La fenêtre du jeu
/// porte alors son logo et son nom dans le Dock, et le mode Jeu macOS
/// (LSSupportsGameMode) continue de la reconnaître.
///
/// Aucun fichier du moteur n'est modifié ; sans icône disponible le bundle
/// reste utilisable (icône ajoutée plus tard quand l'artwork local arrive).
enum GameDockRuntime {
    static let dirName = "GameDock"

    static func safeComponent(_ title: String, appID: String) -> String {
        let base = String(title.map { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "_" ? $0 : "-" })
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(60)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -_"))
        let clean = base.isEmpty ? "Jeu" : String(base)
        let id = appID.filter { $0.isLetter || $0.isNumber }
        return "\(clean)-\(id.isEmpty ? "app" : id.prefix(24))"
    }

    static func bundleURL(appID: String, title: String, runtimeRoot: URL) -> URL {
        runtimeRoot.appendingPathComponent(dirName, isDirectory: true)
            .appendingPathComponent(safeComponent(title, appID: appID) + ".app", isDirectory: true)
    }

    /// Chemin du wine du bundle sous forme injectable dans un script lanceur.
    static func scriptWine(appID: String, title: String, runtimeRoot: URL) -> String {
        let relative = runtimeRoot.path
            .replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "")
        let escaped = relative.replacingOccurrences(of: "\"", with: "")
        return "$HOME/Library/Application Support/Playmelt/Runtime" + escaped
            + "/\(dirName)/\(safeComponent(title, appID: appID)).app/Contents/MacOS/wine"
    }

    private static func escapeXML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func plist(appID: String, title: String) -> String {
        let name = escapeXML(String(title.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines))
        let cleanID = appID.filter { $0.isLetter || $0.isNumber }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleExecutable</key><string>wine</string>
        <key>CFBundleIdentifier</key><string>fr.playmelt.game.\(cleanID.isEmpty ? "app" : escapeXML(cleanID))</string>
        <key>CFBundleName</key><string>\(name.isEmpty ? "Jeu Playmelt" : name)</string>
        <key>CFBundleDisplayName</key><string>\(name.isEmpty ? "Jeu Playmelt" : name)</string>
        <key>CFBundlePackageType</key><string>APPL</string>
        <key>CFBundleShortVersionString</key><string>10.0</string>
        <key>CFBundleVersion</key><string>10.0</string>
        <key>CFBundleIconFile</key><string>game</string>
        <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
        <key>LSSupportsGameMode</key><true/>
        <key>GCSupportsGameMode</key><true/>
        <key>NSPrincipalClass</key><string>WineApplication</string>
        <key>NSHighResolutionCapable</key><true/>
        </dict></plist>

        """
    }

    /// Icône .icns depuis des octets d'artwork (png/jpg/webp) : fond plein,
    /// coins en squircle léger comme les icônes macOS.
    static func icnsData(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 512,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let side = 512
        let radius = CGFloat(side) * 23 / 100
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.setFillColor(CGColor(red: 0.055, green: 0.09, blue: 0.125, alpha: 1))
        context.addPath(path)
        context.fillPath()
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.interpolationQuality = .high
        let width = CGFloat(cg.width), height = CGFloat(cg.height)
        let scale = max(CGFloat(side) / width, CGFloat(side) / height)
        let drawn = CGRect(x: (CGFloat(side) - width * scale) / 2, y: (CGFloat(side) - height * scale) / 2,
                           width: width * scale, height: height * scale)
        context.draw(cg, in: drawn)
        context.restoreGState()
        guard let composed = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "com.apple.icns" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, composed, [kCGImagePropertyPixelWidth: side,
                                                           kCGImagePropertyPixelHeight: side] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func binaryMatches(_ candidate: URL, _ original: URL) -> Bool {
        let fm = FileManager.default
        guard let first = try? fm.attributesOfItem(atPath: candidate.path),
              let second = try? fm.attributesOfItem(atPath: original.path),
              first[.type] as? FileAttributeType == .typeRegular,
              second[.type] as? FileAttributeType == .typeRegular,
              fm.isExecutableFile(atPath: candidate.path) else { return false }
        return (first[.size] as? NSNumber) == (second[.size] as? NSNumber)
            && (first[.modificationDate] as? Date) == (second[.modificationDate] as? Date)
    }

    /// Crée ou rafraîchit le bundle du jeu. `nil` : le moteur n'est pas prêt,
    /// les lanceurs garderont leur wine habituel. Coût : clones APFS une fois.
    static func ensure(appID: String, title: String, runtimeRoot: URL, iconData: Data?) -> URL? {
        let fm = FileManager.default
        guard LibraryModel.validAppID(appID) else { return nil }
        let engine = runtimeRoot.appendingPathComponent(GameModeRuntime.engineID, isDirectory: true)
        let binaries = engine.appendingPathComponent("engine/bin", isDirectory: true)
        guard ["wine", "wineserver"].allSatisfy({ fm.isExecutableFile(atPath: binaries.appendingPathComponent($0).path) }),
              ["lib", "share"].allSatisfy({ fm.fileExists(atPath: engine.appendingPathComponent($0).path) }) else { return nil }
        let bundle = bundleURL(appID: appID, title: title, runtimeRoot: runtimeRoot)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let wantedPlist = plist(appID: appID, title: title)
        let plistURL = contents.appendingPathComponent("Info.plist")
        let iconURL = contents.appendingPathComponent("Resources/game.icns")

        if let iconData, let icns = icnsData(from: iconData), (try? Data(contentsOf: iconURL)) != icns {
            try? fm.createDirectory(at: iconURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            guard (try? icns.write(to: iconURL, options: .atomic)) != nil else { return nil }
            // LaunchServices rafraîchit l'icône quand le bundle change.
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: bundle.path)
        }
        let current = ["wine", "wineserver"].allSatisfy { binaryMatches(contents.appendingPathComponent("MacOS/" + $0), binaries.appendingPathComponent($0)) }
            && ["lib", "share"].allSatisfy { (try? fm.destinationOfSymbolicLink(atPath: contents.appendingPathComponent($0).path)) == "../../engine/" + $0 }
            && ((try? String(contentsOf: plistURL, encoding: .utf8)) ?? "") == wantedPlist
        if current, fm.fileExists(atPath: contents.appendingPathComponent("MacOS/wine").path) { return bundle }

        let staging = bundle.deletingLastPathComponent()
            .appendingPathComponent("." + bundle.lastPathComponent + "." + UUID().uuidString, isDirectory: true)
        do {
            let staged = staging.appendingPathComponent("Contents", isDirectory: true)
            try fm.createDirectory(at: staged.appendingPathComponent("MacOS", isDirectory: true), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            for name in ["wine", "wineserver"] {
                try fm.copyItem(at: binaries.appendingPathComponent(name), to: staged.appendingPathComponent("MacOS/" + name))
            }
            for name in ["lib", "share"] {
                try fm.createSymbolicLink(atPath: staged.appendingPathComponent(name).path, withDestinationPath: "../../engine/" + name)
            }
            try Data(wantedPlist.utf8).write(to: plistURL, options: .atomic)
            if fm.fileExists(atPath: iconURL.path) {
                try fm.createDirectory(at: iconURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: iconURL, to: staging.appendingPathComponent("Contents/Resources/game.icns"))
            }
            guard ["wine", "wineserver"].allSatisfy({ binaryMatches(staged.appendingPathComponent("MacOS/" + $0), binaries.appendingPathComponent($0)) }) else {
                throw CocoaError(.fileWriteUnknown)
            }
            if fm.fileExists(atPath: bundle.path) || (try? fm.destinationOfSymbolicLink(atPath: bundle.path)) != nil {
                try fm.removeItem(at: bundle)
            }
            try fm.moveItem(at: staging, to: bundle)
            return bundle
        } catch {
            try? fm.removeItem(at: staging)
            return fm.fileExists(atPath: contents.appendingPathComponent("MacOS/wine").path) ? bundle : nil
        }
    }
}
