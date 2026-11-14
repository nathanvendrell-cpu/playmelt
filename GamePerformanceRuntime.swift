import Foundation

/// Process-local requests only. These values are not observations of game FPS,
/// swapchain size, window size or GPU support.
enum GamePerformanceResolutionStrategy: String {
    case unavailable, unity, unreal
}

enum GamePerformanceRuntime {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static let officialSteamReason = "Ces réglages ne sont pas transmis au jeu par le client Steam Windows officiel. Aucun client n’est fermé ou redémarré automatiquement."
    static let spatialReason = "La résolution de rendu de ce jeu n’est pas pilotable par un lanceur Unity ou Unreal qualifié. L’upscaling spatial n’est pas appliqué."

    static func d3dMetalFPSVersionSupported(_ version: String?) -> Bool {
        version == "4.0b3"
    }

    static func renderer(requested: String, manifest: String?, fallback: String) -> String {
        requested == "auto" ? (manifest ?? fallback) : requested
    }

    static func resolutionShellArguments(unity: Bool, unreal: Bool) -> String {
        if unity { return " -screen-fullscreen 1 -window-mode borderless -screen-width \"${PLAYMELT_RENDER_WIDTH:-$PLAYMELT_GAME_WIDTH}\" -screen-height \"${PLAYMELT_RENDER_HEIGHT:-$PLAYMELT_GAME_HEIGHT}\"" }
        if unreal { return " -fullscreen -ResX=\"${PLAYMELT_RENDER_WIDTH:-$PLAYMELT_GAME_WIDTH}\" -ResY=\"${PLAYMELT_RENDER_HEIGHT:-$PLAYMELT_GAME_HEIGHT}\"" }
        return ""
    }

    static func resolutionStrategy(executable: String, files: [String]) -> GamePerformanceResolutionStrategy {
        let lower = executable.replacingOccurrences(of: "\\", with: "/").lowercased()
        let directory = (lower as NSString).deletingLastPathComponent
        let unityDLL = directory.isEmpty ? "unityplayer.dll" : directory + "/unityplayer.dll"
        let names = Set(files.map { $0.replacingOccurrences(of: "\\", with: "/").lowercased() })
        if names.contains(unityDLL) { return .unity }
        if lower.hasSuffix("-shipping.exe"), lower.contains("/binaries/win64/"),
           names.contains(where: { $0.hasPrefix("engine/") || $0.contains("/engine/") }) { return .unreal }
        return .unavailable
    }

    static func environment(base: [String: String], request: GamePerformanceRequest?, appID: String,
                            renderer: String, executable: String,
                            resolution: GamePerformanceResolutionStrategy,
                            d3dMetalFPSQualified: Bool = false) throws -> [String: String] {
        // The fingerprinted profile is intentionally byte-for-byte outside this
        // policy, including inherited environment values and resolution args.
        if appID == "2651280" { return base }
        var environment = base
        guard let request else { return environment }
        let fields = request.appliedFields
        let fpsRequested = fields.contains("performance.fpsLimit")
        let spatialRequested = fields.contains("performance.metalFXScale")
        guard fpsRequested || spatialRequested else { return environment }
        guard request.fpsLimit == nil || [30, 40, 45, 60, 90, 120].contains(request.fpsLimit!),
              [1.0, 1.5, 2.0].contains(request.metalFXScale),
              (640...16384).contains(request.outputWidth), (480...16384).contains(request.outputHeight) else {
            throw Failure(message: "Demande de performances invalide. Ouvrez les paramètres du jeu.")
        }
        let metal = ["d3dmetal", "d3dmetal-nv", "d3dmetal-nv-rt"].contains(renderer)
        if metal {
            guard request.metalFXScale == 1 else { throw Failure(message: "L’upscaling spatial est réservé à DirectX 11 avec DXMT.") }
            guard request.fpsLimit == nil || d3dMetalFPSQualified else { throw Failure(message: "La limite de FPS exige le moteur D3DMetal 4.0b3 préparé et vérifié.") }
            if fpsRequested {
                environment.removeValue(forKey: "D3DM_MAX_FPS")
                if let fps = request.fpsLimit { environment["D3DM_MAX_FPS"] = String(fps) }
            }
            return environment
        }
        guard renderer == "dxmt" else { throw Failure(message: "Ces réglages ne sont pas disponibles pour ce moteur.") }
        guard !executable.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw Failure(message: "Le nom de l’exécutable ne peut pas être ciblé sans ambiguïté par DXMT.")
        }
        let name = URL(fileURLWithPath: executable.replacingOccurrences(of: "\\", with: "/")).lastPathComponent
        guard name.lowercased().hasSuffix(".exe"), name.utf8.count <= 255,
              !name.contains(where: { ";[]\r\n\0".contains($0) }),
              !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw Failure(message: "Le nom de l’exécutable ne peut pas être ciblé sans ambiguïté par DXMT.")
        }
        if request.metalFXScale > 1 {
            guard resolution != .unavailable else { throw Failure(message: spatialReason) }
            let width = Int((Double(request.outputWidth) / request.metalFXScale).rounded(.down)) / 2 * 2
            let height = Int((Double(request.outputHeight) / request.metalFXScale).rounded(.down)) / 2 * 2
            guard width > 0, height > 0, request.renderWidth == width, request.renderHeight == height else {
                throw Failure(message: "Les résolutions de rendu et de sortie demandées ne correspondent plus.")
            }
            // Pixels requested from the game's swapchain. Do not overwrite
            // PLAYMELT_GAME_* (display guard desktop coordinates/points), nor
            // DISPLAY_PIXEL_* (observed Retina framebuffer geometry).
            environment["PLAYMELT_RENDER_WIDTH"] = String(width)
            environment["PLAYMELT_RENDER_HEIGHT"] = String(height)
        } else if spatialRequested {
            environment.removeValue(forKey: "PLAYMELT_RENDER_WIDTH")
            environment.removeValue(forKey: "PLAYMELT_RENDER_HEIGHT")
        }
        var additions: [String] = []
        if fpsRequested { additions.append("d3d11.preferredMaxFrameRate=\(request.fpsLimit ?? 0)") }
        if spatialRequested {
            additions.append("d3d11.metalSpatialUpscaleFactor=\(request.metalFXScale)")
            environment["DXMT_METALFX_SPATIAL_SWAPCHAIN"] = request.metalFXScale > 1 ? "1" : "0"
        }
        let existing = environment["DXMT_CONFIG"] ?? ""
        guard existing.utf8.count <= 65_536, !existing.contains("\0") else { throw Failure(message: "La configuration DXMT héritée ne peut pas être conservée dans cette demande.") }
        // The explicit, case-sensitive PE basename reactivates the config parser
        // after any nonmatching file/env section. Existing user options and the
        // DXMT_CONFIG_FILE path stay intact; no shared file is written.
        environment["DXMT_CONFIG"] = existing + (existing.isEmpty || existing.hasSuffix(";") ? "" : ";") + "[\(name)];" + additions.joined(separator: ";") + ";"
        return environment
    }
}
