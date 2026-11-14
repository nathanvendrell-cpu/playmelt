import Foundation

@main enum GamePerformanceRuntimeTests {
    static var checks = 0
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message); checks += 1
    }
    static func request(fps: Int? = 40, scale: Double = 1, width: Int = 1920, height: Int = 1080,
                        fields: Set<String> = ["performance.fpsLimit", "performance.metalFXScale"]) -> GamePerformanceRequest {
        .init(fpsLimit: fps, metalFXScale: scale, outputWidth: width, outputHeight: height,
              renderWidth: Int((Double(width) / scale).rounded(.down)) / 2 * 2,
              renderHeight: Int((Double(height) / scale).rounded(.down)) / 2 * 2, appliedFields: fields)
    }
    static func environment(_ r: GamePerformanceRequest?, base: [String: String] = [:], renderer: String = "dxmt",
                            exe: String = "ExactGame.exe", resolution: GamePerformanceResolutionStrategy = .unity,
                            qualified: Bool = false, appID: String = "fixture") throws -> [String: String] {
        try GamePerformanceRuntime.environment(base: base, request: r, appID: appID, renderer: renderer,
            executable: exe, resolution: resolution, d3dMetalFPSQualified: qualified)
    }
    static func rejects(_ message: String, _ action: () throws -> Void) {
        do { try action(); preconditionFailure(message) } catch { checks += 1 }
    }
    static func main() throws {
        let inherited = ["DXMT_CONFIG": "[Other.exe];other.option=keep", "DXMT_CONFIG_FILE": "/fixture/user dxmt.conf",
            "UNRELATED": "$(literal);`literal`", "PLAYMELT_GAME_WIDTH": "1920", "PLAYMELT_GAME_HEIGHT": "1080",
            "PLAYMELT_DISPLAY_PIXEL_WIDTH": "3840", "PLAYMELT_DISPLAY_PIXEL_HEIGHT": "2160", "PLAYMELT_DISPLAY_SCALE": "2"]
        let legacy = try environment(nil, base: inherited)
        expect(legacy == inherited, "legacy defaults do not introduce settings")
        let active = try environment(request(scale: 2, width: 3840, height: 2160), base: inherited)
        expect(active["DXMT_CONFIG"] == "[Other.exe];other.option=keep;[ExactGame.exe];d3d11.preferredMaxFrameRate=40;d3d11.metalSpatialUpscaleFactor=2.0;", "preserve prior sections and explicitly reactivate exact PE basename")
        expect(active["DXMT_CONFIG_FILE"] == inherited["DXMT_CONFIG_FILE"], "preserve user config file")
        expect(active["UNRELATED"] == inherited["UNRELATED"], "no shell expansion or unrelated key mutation")
        expect(active["PLAYMELT_RENDER_WIDTH"] == "1920" && active["PLAYMELT_RENDER_HEIGHT"] == "1080", "Retina output request has separate lower pixel input")
        for key in ["PLAYMELT_GAME_WIDTH", "PLAYMELT_GAME_HEIGHT", "PLAYMELT_DISPLAY_PIXEL_WIDTH", "PLAYMELT_DISPLAY_PIXEL_HEIGHT", "PLAYMELT_DISPLAY_SCALE"] {
            expect(active[key] == inherited[key], "display guard geometry is preserved: " + key)
        }
        expect(active["DXMT_METALFX_SPATIAL_SWAPCHAIN"] == "1", "spatial flag reaches direct launch only")
        let ordinary = try environment(request(scale: 1.5), base: ["PLAYMELT_GAME_WIDTH": "1920", "PLAYMELT_GAME_HEIGHT": "1080"], resolution: .unreal)
        expect(ordinary["PLAYMELT_RENDER_WIDTH"] == "1280" && ordinary["PLAYMELT_RENDER_HEIGHT"] == "720", "1x screen request scales only render pixels")
        expect(ordinary["PLAYMELT_GAME_WIDTH"] == "1920", "render size does not replace display target")
        let off = try environment(request(fps: nil), base: active)
        expect(off["DXMT_CONFIG"]!.hasSuffix("[ExactGame.exe];d3d11.preferredMaxFrameRate=0;d3d11.metalSpatialUpscaleFactor=1.0;"), "explicit off overrides prior managed values")
        expect(off["DXMT_METALFX_SPATIAL_SWAPCHAIN"] == "0" && off["PLAYMELT_RENDER_WIDTH"] == nil && off["PLAYMELT_RENDER_HEIGHT"] == nil, "explicit off disables flag and render override")
        let fpsOnly = try environment(request(fields: ["performance.fpsLimit"]), base: inherited, resolution: .unavailable)
        expect(fpsOnly["DXMT_CONFIG"]!.hasSuffix("[ExactGame.exe];d3d11.preferredMaxFrameRate=40;"), "unknown engine supports direct FPS without changing spatial state")
        expect(fpsOnly["DXMT_METALFX_SPATIAL_SWAPCHAIN"] == nil && fpsOnly["PLAYMELT_RENDER_WIDTH"] == nil, "FPS does not fabricate a render path")
        rejects("unknown resolution cannot silently upscale") { _ = try environment(request(scale: 2), resolution: .unavailable) }
        rejects("unvalidated FPS never enters runtime environment") { _ = try environment(request(fps: 99)) }
        for bad in ["Game;injection.exe", "Game].exe", "Game[.exe", "Game\n.exe", "Game\r.exe", "Game\0.exe"] {
            rejects("config section name must not inject: " + bad) { _ = try environment(request(), exe: bad) }
        }
        let other = try environment(request(fps: 60), exe: "OtherCase.EXE")
        expect(other["DXMT_CONFIG"]!.hasPrefix("[OtherCase.EXE];") && !other["DXMT_CONFIG"]!.contains("ExactGame.exe"), "per-launch configuration and executable case remain separate")
        expect(inherited["DXMT_CONFIG"] == "[Other.exe];other.option=keep", "input dictionary was not mutated")
        let windowsPath = try environment(request(), exe: "Folder\\CaseGame.exe")
        expect(windowsPath["DXMT_CONFIG"]!.hasPrefix("[CaseGame.exe];"), "PE section uses basename, never a Windows path")
        expect(GamePerformanceRuntime.resolutionStrategy(executable: "Game.exe", files: ["Game.exe", "UnityPlayer.dll"]) == .unity, "Unity exact sibling marker")
        expect(GamePerformanceRuntime.resolutionStrategy(executable: "Game.exe", files: ["Another/UnityPlayer.dll"]) == .unavailable, "unrelated Unity runtime is not a resolution proof")
        expect(GamePerformanceRuntime.resolutionStrategy(executable: "Foo/Binaries/Win64/Foo-Win64-Shipping.exe", files: ["Engine/Config/BaseEngine.ini"]) == .unreal, "Unreal shipping layout has explicit resolution arguments")
        expect(GamePerformanceRuntime.resolutionStrategy(executable: "Foo-Shipping.exe", files: ["anything"]) == .unavailable, "filename alone is not an Unreal route")
        for fps in [30, 40, 45, 60, 90, 120] {
            let metal = try environment(request(fps: fps), renderer: "d3dmetal", qualified: true)
            expect(metal["D3DM_MAX_FPS"] == String(fps) && metal["DXMT_CONFIG"] == nil, "documented D3DMetal cap is process-local and renderer-specific")
        }
        let metalOff = try environment(request(fps: nil), base: ["D3DM_MAX_FPS": "60", "KEEP": "yes"], renderer: "d3dmetal")
        expect(metalOff["D3DM_MAX_FPS"] == nil && metalOff["KEEP"] == "yes", "D3DMetal off removes key, never writes zero, including after version change")
        rejects("unknown D3DMetal version cannot acquire cap") { _ = try environment(request(), renderer: "d3dmetal") }
        rejects("D3DMetal never takes spatial DXMT flag") { _ = try environment(request(scale: 2), renderer: "d3dmetal", qualified: true) }
        expect(GamePerformanceRuntime.d3dMetalFPSVersionSupported("4.0b3"), "exact qualified version")
        for version in [nil, "4.0", "unknown", "4.0b4"] as [String?] {
            expect(!GamePerformanceRuntime.d3dMetalFPSVersionSupported(version), "unqualified version remains unavailable")
        }
        expect(GamePerformanceRuntime.renderer(requested: "auto", manifest: "d3dmetal", fallback: "dxmt") == "d3dmetal", "automatic uses actual manifest renderer")
        expect(GamePerformanceRuntime.renderer(requested: "auto", manifest: nil, fallback: "dxmt") == "dxmt", "automatic local fallback resolved before request")
        expect(GamePerformanceRuntime.renderer(requested: "dxmt", manifest: "d3dmetal", fallback: "d3dmetal") == "dxmt", "explicit backend has precedence")
        func captureArguments(_ environment: [String: String], unity: Bool, unreal: Bool) throws -> [String] {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", "set -eu\n/usr/bin/printf '%s\\n'" + GamePerformanceRuntime.resolutionShellArguments(unity: unity, unreal: unreal)]
            process.environment = environment; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            precondition(process.terminationStatus == 0)
            return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        }
        let unityArgs = try captureArguments(active, unity: true, unreal: false)
        expect(unityArgs.suffix(4) == ["-screen-width", "1920", "-screen-height", "1080"], "production Unity args receive lower render pixels")
        let unrealArgs = try captureArguments(ordinary, unity: false, unreal: true)
        expect(unrealArgs.suffix(2) == ["-ResX=1280", "-ResY=720"], "production Unreal args receive lower render pixels")
        let ordinaryArgs = try captureArguments(inherited, unity: true, unreal: false)
        expect(ordinaryArgs.suffix(4) == ["-screen-width", "1920", "-screen-height", "1080"], "no request preserves prior display fallback")
        expect(GamePerformanceRuntime.resolutionShellArguments(unity: false, unreal: false).isEmpty, "unknown engine gets no invented resolution args")
        let protected = try environment(request(scale: 2), base: inherited, renderer: "d3dmetal", appID: "2651280")
        expect(protected == inherited, "fingerprinted SM2 profile has no new FPS, spatial or resolution environment")
        // Real inert child, explicit fixture environment only; no shell, Wine,
        // game, user settings, engine/prefix or network is involved.
        let child = Process(), pipe = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        child.environment = active; child.standardOutput = pipe; child.standardError = FileHandle.nullDevice
        try child.run(); let bytes = pipe.fileHandleForReading.readDataToEndOfFile(); child.waitUntilExit()
        let captured = String(decoding: bytes, as: UTF8.self)
        expect(child.terminationStatus == 0 && captured.contains("DXMT_CONFIG=" + active["DXMT_CONFIG"]!), "actual direct child inherits exact DXMT request")
        expect(captured.contains("PLAYMELT_RENDER_WIDTH=1920") && captured.contains("PLAYMELT_GAME_WIDTH=1920"), "actual child receives separate render and guard channels")
        print("Game performance runtime: \(checks) PASS; inert process only, no runtime/FPS qualification")
    }
}
