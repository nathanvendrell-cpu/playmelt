import Foundation

private final class EpicFlowRunner: OwnedProcessRunning {
    var response: [String: Any] = [:]
    func run(_ request: OwnedProcessRequest, cancelled: () -> Bool, handoff: () -> Bool,
             onDetachedExit: @escaping (Int32) -> Void) throws -> OwnedProcessResult {
        if cancelled() { throw OwnedProcessError.cancelled }
        return .init(output: try JSONSerialization.data(withJSONObject: response), exitCode: 0, pid: 0, handedOff: false)
    }
}

@main enum InstallFlowTests {
    static var checks = 0
    static let fm = FileManager.default
    static func check(_ value: Bool, _ label: String) {
        checks += 1; if !value { fatalError("FAIL: " + label) }
    }
    static func rejects(_ label: String, _ body: () throws -> Void) {
        do { try body(); check(false, label) } catch { check(true, label) }
    }
    static func wait(_ done: () -> Bool) {
        let limit = Date().addingTimeInterval(3)
        while !done() && Date() < limit { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
        check(done(), "bounded main callback")
    }
    static func put(_ data: Data, at url: URL, executable: Bool = false) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        if executable { try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }
    }
    static func thin(cpu: UInt32 = 0x0100000c, type: UInt32 = 2) -> Data {
        var values: [UInt32] = [0xfeedfacf, cpu, 0, type, 0, 0, 0, 0]
        return values.withUnsafeMutableBytes { Data($0) }
    }
    static func response(account: String, snapshotAccount: String? = nil) -> [String: Any] {
        ["ok": true, "session": ["account_id": account, "access_token": "fixture-only-token"],
         "snapshot": ["accountId": snapshotAccount ?? account, "displayName": "Fixture", "games": [], "installed": [],
                      "source": "fixture", "updatedAt": "2026-10-25T00:00:00Z"]]
    }
    static func main() throws {
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("playmelt-install-fixtures-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let install = root.appendingPathComponent("game")
        let binary = install.appendingPathComponent("Game")
        try put(thin(), at: binary, executable: true)
        let manifest = root.appendingPathComponent("game.item")
        var item: [String: Any] = ["AppName": "game", "DisplayName": "Fixture", "CatalogNamespace": "games",
            "CatalogItemId": "catalog-id", "InstallLocation": install.path, "LaunchExecutable": "Game"]
        func read() throws -> Game? {
            try JSONSerialization.data(withJSONObject: item).write(to: manifest, options: .atomic)
            return LibraryModel.readEpicManifest(manifest)
        }
        check(try read()?.complete == true, "native target structure accepted")
        try put(thin(cpu: 0x01000007), at: binary, executable: true)
        check(try read()?.complete == true, "x86_64 Mach-O target accepted structurally")
        try put(thin(type: 6), at: binary, executable: true)
        check(try read()?.complete == false, "dylib cannot masquerade as launch executable")
        try put(Data([0x4d, 0x5a]) + Data(repeating: 0, count: 30), at: binary, executable: true)
        check(try read()?.complete == false, "Windows PE is never native Mac ready")
        try put(thin(cpu: 12), at: binary, executable: true)
        check(try read()?.complete == false, "32-bit architecture not playable on current macOS")
        try put(thin(), at: binary)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: binary.path)
        check(try read()?.complete == false, "nonexecutable target rejected")
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        item["LaunchExecutable"] = "missing"
        check(try read()?.complete == false, "other executable in folder does not validate missing target")
        item["LaunchExecutable"] = "../outside"
        try put(thin(), at: root.appendingPathComponent("outside"), executable: true)
        check(try read()?.complete == false, "relative escape rejected")
        try fm.createSymbolicLink(at: install.appendingPathComponent("escaped"), withDestinationURL: root.appendingPathComponent("outside"))
        item["LaunchExecutable"] = "escaped"
        check(try read()?.complete == false, "symlink escape rejected")
        item["LaunchExecutable"] = "Game"; item["bIsIncompleteInstall"] = true
        check(try read()?.complete == false, "incomplete manifest remains incomplete")
        item["bIsIncompleteInstall"] = "true"
        check(try read() == nil, "malformed completion flag cannot claim ready")
        item["bIsIncompleteInstall"] = false; item["InstallLocation"] = root.appendingPathComponent("absent").path
        check(try read() == nil, "stale installation folder is not installed")
        item["InstallLocation"] = install.path; item["AppName"] = "game?action=install"
        check(try read() == nil, "launch identifier cannot inject URL parameters")
        item["AppName"] = "game"
        let app = install.appendingPathComponent("Example.app")
        try put(thin(), at: app.appendingPathComponent("Contents/MacOS/Example"), executable: true)
        let info: [String: Any] = ["CFBundleIdentifier": "test.playmelt.fixture", "CFBundleExecutable": "Example", "CFBundlePackageType": "APPL"]
        try put(PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0), at: app.appendingPathComponent("Contents/Info.plist"))
        item["LaunchExecutable"] = "Example.app"
        check(try read()?.complete == true, "bundle resolves its declared executable without launching")
        // Big-endian FAT header and one architecture table; no binary is executed.
        var fat = Data([0xca,0xfe,0xba,0xbe, 0,0,0,1, 1,0,0,12, 0,0,0,0, 0,0,0,32, 0,0,0,32, 0,0,0,0, 0,0,0,0])
        fat.append(thin())
        try put(fat, at: binary, executable: true); item["LaunchExecutable"] = "Game"
        check(try read()?.complete == true, "universal wrapper points to supported executable slice")
        fat.replaceSubrange(16..<20, with: [0xff,0xff,0xff,0xff])
        try put(fat, at: binary, executable: true)
        check(try read()?.complete == false, "FAT offset outside file rejected")

        let account = "76561198000000001"
        check(SteamGameLaunchProfile.prefersNative(platform: "mac", supportedPlatforms: ["mac", "windows"], requestedRuntime: nil), "Mac edition stays native by default")
        check(SteamGameLaunchProfile.prefersNative(platform: "windows", supportedPlatforms: ["mac", "windows"], requestedRuntime: "steam-mac"), "explicit Mac choice is preserved")
        check(!SteamGameLaunchProfile.prefersNative(platform: "mac", supportedPlatforms: ["mac", "windows"], requestedRuntime: "playmelt-windows"), "explicit Windows choice is preserved")
        check(!SteamGameLaunchProfile.prefersNative(platform: "windows", supportedPlatforms: ["windows"], requestedRuntime: nil), "Windows-only title cannot fall back to Mac")
        check(SteamGameLaunchProfile.localRenderer(appID: "526870", unity: false, dx12Markers: true) == "dxmt", "Satisfactory retains its working DX11 route despite bundled DX12 libraries")
        check(SteamGameLaunchProfile.localRenderer(appID: "1783560", unity: true, dx12Markers: false) == "d3dmetal", "explicit DX12 requirement cannot be overridden by a Unity heuristic")
        for action in ["launchGame", "installGame", "installAndPlay", "uninstallGame"] {
            check(RenderProtection.blocks(action, enabled: true), "render gate covers \(action)")
        }
        let direct = SteamInstallCoordinator()
        let old = direct.beginDirect(gameID: "steam:10", appID: "10", title: "A", accountID: account, autoLaunch: true)!
        direct.cancel()
        let current = direct.beginDirect(gameID: "steam:20", appID: "20", title: "B", accountID: account, autoLaunch: true)!
        direct.updateDirect(id: old, status: "installing", message: "stale", progress: 1)
        check(direct.snapshot?["appId"] as? String == "20" && direct.snapshot?["status"] as? String == "downloading", "late old output cannot mutate the new installation")
        check(!direct.finishDirect(id: old, success: true, message: "late"), "late completion cannot finish another job")
        check(direct.finishDirect(id: current, success: true, message: "prepared"), "current direct completion is accepted")
        check(direct.permitsDirectAutoLaunch(id: current, accountID: account, executionBlocked: false), "current account can request its own automatic launch")
        check(!direct.permitsDirectAutoLaunch(id: current, accountID: "76561198000000002", executionBlocked: false), "changed account blocks automatic launch")
        check(!direct.permitsDirectAutoLaunch(id: current, accountID: account, executionBlocked: true), "render protection blocks queued automatic launch")
        direct.cancel()
        check(!direct.permitsDirectAutoLaunch(id: current, accountID: account, executionBlocked: false), "cancel invalidates launch queued after completion")
        direct.shutdown()
        check(direct.beginDirect(gameID: "steam:30", appID: "30", title: "C", accountID: account) == nil, "shutdown refuses new direct workers")

        let gameRoot = root.appendingPathComponent("games")
        let gameFolder = gameRoot.appendingPathComponent("Game A")
        try put(Data("fixture data".utf8), at: gameFolder.appendingPathComponent("save.dat"))
        try put(Data("other game".utf8), at: gameRoot.appendingPathComponent("Game A Other/save.dat"))
        var removalGame = Game(id: "local:10", appId: "10", title: "Game A", store: "steam", installed: true, platform: "windows", runtimeId: "", runtimeName: "", ownership: "installed-only", path: gameFolder, complete: true, installSource: "local")
        let removal = try GameUninstallPlan.make(game: removalGame, installRoots: [gameRoot], steamRoots: [])
        check(removal.items.map(\.path) == [gameFolder.path] && fm.fileExists(atPath: gameFolder.appendingPathComponent("save.dat").path), "uninstall dry run is exact and does not delete files")
        removalGame.path = gameRoot
        rejects("uninstall refuses the whole games root") { _ = try GameUninstallPlan.make(game: removalGame, installRoots: [gameRoot], steamRoots: []) }
        removalGame.path = fm.homeDirectoryForCurrentUser
        rejects("uninstall refuses HOME even as a configured root") { _ = try GameUninstallPlan.make(game: removalGame, installRoots: [fm.homeDirectoryForCurrentUser], steamRoots: []) }
        let outside = root.appendingPathComponent("project")
        try put(Data("preserve".utf8), at: outside.appendingPathComponent("source.swift"))
        let escape = gameRoot.appendingPathComponent("Escape")
        try fm.createSymbolicLink(at: escape, withDestinationURL: outside)
        removalGame.path = escape
        rejects("uninstall refuses a symlink outside game roots") { _ = try GameUninstallPlan.make(game: removalGame, installRoots: [gameRoot], steamRoots: []) }
        removalGame.path = gameFolder
        try put(Data("gitdir: fixture".utf8), at: gameFolder.appendingPathComponent(".git"))
        rejects("uninstall preserves a detected Git worktree") { _ = try GameUninstallPlan.make(game: removalGame, installRoots: [gameRoot], steamRoots: []) }

        let literal = "spaces ' $(touch \(root.appendingPathComponent("injected").path)) `echo unexpected`"
        let quoteCheck = Process(), quoteOutput = Pipe()
        quoteCheck.executableURL = URL(fileURLWithPath: "/bin/sh")
        quoteCheck.arguments = ["-c", "printf '%s' " + shellLiteral(literal)]
        quoteCheck.standardOutput = quoteOutput; quoteCheck.standardError = FileHandle.nullDevice
        try quoteCheck.run(); quoteCheck.waitUntilExit()
        check(quoteCheck.terminationStatus == 0 && String(decoding: quoteOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == literal && !fm.fileExists(atPath: root.appendingPathComponent("injected").path), "launcher quotes preserve text without executing substitutions")
        let ready = SteamInstallObservation(status: "installing", message: "Ready", ready: true, signature: "complete")
        check(SteamInstallAccountContext.gate(ready, expected: account, active: account).ready, "matching Steam account allows handoff")
        for active in [nil, "76561198000000002"] as [String?] {
            let gated = SteamInstallAccountContext.gate(ready, expected: account, active: active)
            check(!gated.ready && gated.signature.isEmpty && gated.status == "awaiting-account", "unknown/different Steam account cannot autolaunch")
        }
        check(!SteamInstallAccountContext.permitsAutoLaunch(expected: "", active: nil), "empty selected account cannot autolaunch")
        let downloading = SteamInstallObservation(status: "downloading", message: "Download", downloaded: 2, total: 10)
        check(SteamInstallAccountContext.gate(downloading, expected: account, active: nil).downloaded == 2, "unknown account does not stop progress reads")
        let apps = root.appendingPathComponent("steamapps")
        for folder in ["One", "Two"] { try put(Data([0x4d,0x5a]), at: apps.appendingPathComponent("common/\(folder)/Game.exe")) }
        let steamManifest = apps.appendingPathComponent("appmanifest_526870.acf")
        var state: [String: Any] = ["appid":"526870", "StateFlags":"4", "buildid":"123", "installdir":"One", "LastOwner":account]
        try put(Data("fixture".utf8), at: steamManifest)
        let first = SteamInstallManifest.inspect(steamManifest, appID: "526870", platform: "windows", accountID: account, cachedState: state)
        state["installdir"] = "Two"
        let moved = SteamInstallManifest.inspect(steamManifest, appID: "526870", platform: "windows", accountID: account, cachedState: state)
        check(first.ready && moved.ready && first.signature != moved.signature, "moving same build resets stable completion evidence")

        let worker = root.appendingPathComponent("worker.py"); try put(Data("# fixture never executed".utf8), at: worker)
        let runner = EpicFlowRunner(); runner.response = response(account: "first-account")
        let connector = EpicConnector(projectRoot: root, pythonURL: URL(fileURLWithPath: "/usr/bin/true"), workerURL: worker, runner: runner, sessionStore: EpicMemorySessionStore())
        var delivered = false, succeeded = false
        connector.authenticate(code: "fixture") { outcome in delivered = true; if case .success = outcome { succeeded = true } }
        // Keep main blocked until credentials were committed, so its callback
        // cannot run yet. This reproduces logout AFTER worker completion.
        let until = Date().addingTimeInterval(3)
        while connector.availability()["authenticated"] as? Bool != true && Date() < until { Thread.sleep(forTimeInterval: 0.001) }
        check(connector.availability()["accountId"] as? String == "first-account", "worker identity known before queued completion")
        var cleared = false
        connector.clearSession { _ in cleared = true }; wait { delivered && cleared }
        check(!succeeded && connector.availability()["authenticated"] as? Bool == false, "queued success cannot restore logged-out account")
        delivered = false
        connector.authenticate(code: "fixture") { outcome in delivered = true; if case .success = outcome { succeeded = true } }
        wait { delivered }; check(succeeded, "fresh login succeeds after cancelled delivery")
        runner.response = response(account: "other-account")
        delivered = false; succeeded = false
        connector.sync { outcome in delivered = true; if case .success = outcome { succeeded = true } }
        wait { delivered }
        check(!succeeded && connector.availability()["authenticated"] as? Bool == false, "changed refresh account clears session without new library")
        runner.response = response(account: "first-account", snapshotAccount: "different-snapshot")
        delivered = false
        connector.authenticate(code: "fixture") { outcome in delivered = true; if case .success = outcome { succeeded = true } }
        wait { delivered }
        check(!succeeded && connector.availability()["authenticated"] as? Bool == false, "mismatched snapshot never authenticates")
        var closed = false; connector.shutdown { closed = true }; wait { closed }
        print("Install flows: \(checks) PASS; CPU fixtures only, no clients, auth network, runtime or GPU.")
    }
}
