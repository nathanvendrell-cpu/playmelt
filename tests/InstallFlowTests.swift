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
        let root = fm.temporaryDirectory.appendingPathComponent("playmelt-install-fixtures-" + UUID().uuidString)
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
        let connector = EpicConnector(projectRoot: root, pythonURL: URL(fileURLWithPath: "/usr/bin/true"), workerURL: worker, runner: runner)
        var delivered = false, succeeded = false
        connector.authenticate(code: "fixture") { outcome in delivered = true; if case .success = outcome { succeeded = true } }
        // Keep main blocked until credentials were committed, so its callback
        // cannot run yet. This reproduces logout AFTER worker completion.
        let until = Date().addingTimeInterval(3)
        while connector.availability()["authenticated"] as? Bool != true && Date() < until { Thread.sleep(forTimeInterval: 0.001) }
        check(connector.availability()["accountId"] as? String == "first-account", "worker identity known before queued completion")
        connector.clearSession(); wait { delivered }
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
