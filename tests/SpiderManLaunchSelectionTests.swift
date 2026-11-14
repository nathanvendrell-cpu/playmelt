import Foundation

@main enum SpiderManLaunchSelectionTests {
    static func main() throws {
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAIL: " + label) }
        }
        let app = "2651280"
        expect(SteamGameLaunchProfile.requiredRenderer(appID: app) == "d3dmetal", "DX12 renderer")
        expect(SteamGameLaunchProfile.requiredGraphicsAPI(appID: app) == "DirectX12", "DX12 API")
        expect(SteamGameLaunchProfile.localRenderer(appID: app, unity: true, dx12Markers: false) == "d3dmetal", "known route overrides heuristics")
        expect(localGameDX12Arguments(appID: app, projectName: nil).isEmpty, "no invented Spider-Man argument")
        expect(localGameDX12Arguments(appID: "2584270", projectName: "Project") == ["Project", "-d3d12"], "other DX12 arguments unchanged")
        expect(localGameExecutable(appID: app, files: ["crs-video.exe", "crs-handler.exe", "Spider-Man2.exe"]) == "Spider-Man2.exe", "main executable selected")
        expect(localGameExecutable(appID: app, files: ["crs-video.exe", "crs-handler.exe"]) == nil, "missing main executable rejected")
        expect(localGameExecutable(appID: app, files: ["bin/Spider-Man2.exe", "crs-video.exe"]) == nil, "nested executable rejected")
        expect(localGameExecutable(appID: app, files: ["Spider-Man2.exe", "spider-man2.exe"]) == nil, "ambiguous names rejected")
        expect(localGameExecutable(appID: "unknown", files: ["aa.exe", "longer.exe"]) == "aa.exe", "unknown game selection preserved")
        func childEnvironment(appID: String) throws -> (Int32, String) {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", localGameEnvironmentExports(appID: appID) + "\n/usr/bin/printenv ROSETTA_ADVERTISE_AVX"]
            process.environment = [:]
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }
        let spiderEnvironment = try childEnvironment(appID: app)
        expect(spiderEnvironment.0 == 0 && spiderEnvironment.1 == "1\n", "Spider-Man child inherits AVX setting")
        let otherEnvironment = try childEnvironment(appID: "2584270")
        expect(otherEnvironment.0 != 0 && otherEnvironment.1.isEmpty, "other DX12 game does not receive setting")
        expect(localGameEnvironmentExports(appID: "unknown").isEmpty, "unknown game receives no added setting")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("playmelt-spider-selection-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("Lancer-Spider.command")
        try "#!/bin/sh\nexit 0\n".write(to: legacy, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: legacy.path)
        let game = Game(id: app, appId: app, title: "Spider", store: "steam", installed: true, platform: "windows", runtimeId: "", runtimeName: "", ownership: "owned", path: root, complete: true, installSource: "local")
        var invalidID = game; invalidID.appId = "$(invalid)"
        expect(ensureLaunchScript(for: invalidID) == nil, "invalid identifier never enters shell source")
        expect(ensureLaunchScript(for: game) == nil, "existing script cannot bypass absent executable")
        expect(localLaunchBlockReason(for: game, steamAccountID: "")?.contains("introuvable") == true, "missing executable has a concrete diagnosis")
        expect(game.json(runtimes: [])["canLaunch"] as? Bool == false, "a script alone cannot advertise a playable game")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Spider-Man2.exe"), withDestinationURL: legacy)
        expect(ensureLaunchScript(for: game) == nil, "symlink executable rejected")
        expect(localLaunchBlockReason(for: game, steamAccountID: "")?.contains("invalide") == true, "symlink rejected before launch")
        print("Spider-Man launch selection: 19 PASS")
    }
}
