import Foundation

@main
enum LibraryScanTests {
    static func main() throws {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("playmelt-library-tests-" + UUID().uuidString)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: scratch) }
        let suite = "PlaymeltLibraryTests." + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        var checks = 0
        func require(_ value: @autoclosure () -> Bool, _ message: String) { checks += 1; if !value() { fatalError(message) } }
        func write(_ value: Data, _ file: URL) throws {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try value.write(to: file)
        }
        func text(_ value: String, _ file: URL) throws { try write(Data(value.utf8), file) }
        func u32(_ value: UInt32) -> Data { var v = value.littleEndian; return withUnsafeBytes(of: &v) { Data($0) } }
        func appinfo(name: String) -> Data {
            func string(_ value: String) -> Data { Data(value.utf8) + Data([0]) }
            func property(_ key: String, _ value: String) -> Data { Data([1]) + string(key) + string(value) }
            var data = u32(0x07564427) + u32(1)
            for id in 1000..<2000 {
                let body = Data([0]) + string("appinfo") + Data([0]) + string("common") + property("name", name + String(id)) + property("oslist", "macos,windows") + property("type", "game") + Data([8,8,8])
                data += u32(UInt32(id)) + u32(UInt32(40 + body.count)) + Data(repeating: 0, count: 40) + body
            }
            return data + Data(repeating: 0, count: 8)
        }
        let steam = scratch.appendingPathComponent("Library/Application Support/Steam")
        let app = steam.appendingPathComponent("Steam.AppBundle/Steam/Contents/MacOS/steam_osx")
        let account = "76561198000000000", other = "76561198000000001"
        let login = steam.appendingPathComponent("config/loginusers.vdf")
        try text("fixture", app)
        try text("\"users\" { \"\(account)\" { \"PersonaName\" \"Fixture\" \"MostRecent\" \"1\" } \"\(other)\" { \"PersonaName\" \"Other\" } }", login)
        let info = steam.appendingPathComponent("appcache/appinfo.vdf")
        try write(appinfo(name: "Alpha"), info)
        let apps = steam.appendingPathComponent("steamapps")
        try text("\"libraryfolders\" {}", apps.appendingPathComponent("libraryfolders.vdf"))
        let manifest = apps.appendingPathComponent("appmanifest_1000.acf")
        try text("\"AppState\" { \"appid\" \"1000\" \"name\" \"Installed\" \"installdir\" \"FixtureGame\" \"StateFlags\" \"4\" }", manifest)
        let executable = apps.appendingPathComponent("common/FixtureGame/bin/game")
        try write(Data([0xcf, 0xfa, 0xed, 0xfe]), executable)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let short = String(UInt64(account)! - 76561197960265728)
        try text("\"UserLocalConfigStore\" { \"Software\" { \"Valve\" { \"Steam\" { \"apps\" { \"1001\" {} } } } } }", steam.appendingPathComponent("userdata/\(short)/config/localconfig.vdf"))
        prefs.set(account, forKey: "selectedSteamAccount")
        let model = LibraryModel(home: scratch, preferences: prefs)
        let scanner = LibraryScanner()
        let first = scanner.scanSynchronously(model.makeScanRequest())
        require(first.metadata.count == 1000, "all fixture appinfo records parsed")
        require(first.steamGames.contains { $0.appId == "1000" && $0.complete }, "binary verified without executing it")
        require(model.applyScan(first), "initial result accepted")
        let second = scanner.scanSynchronously(model.makeScanRequest())
        require(second.metrics.filesParsed == 0 && second.metrics.cacheHits >= 5, "unchanged files must not be reparsed")
        require(model.applyScan(second), "latest result accepted")
        print("Fixture1000 records: cold parses=\(first.metrics.filesParsed), warm parses=\(second.metrics.filesParsed), hits=\(second.metrics.cacheHits); cold=\(String(format: "%.2f", first.metrics.elapsedMilliseconds))ms warm=\(String(format: "%.2f", second.metrics.elapsedMilliseconds))ms (not a gaming benchmark)")

        let oldDate = try info.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        try appinfo(name: "Bravo").write(to: info, options: .atomic) // Same size + restored mtime, different inode.
        try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: info.path)
        let changed = scanner.scanSynchronously(model.makeScanRequest())
        require(changed.metadata["1001"]?.name == "Bravo1001" && changed.metrics.filesParsed == 1, "inode replacement invalidates only changed appinfo")
        try fm.removeItem(at: executable)
        let noBinary = scanner.scanSynchronously(model.makeScanRequest())
        require(noBinary.steamGames.first { $0.appId == "1000" }?.complete == false, "binary deletion cannot reuse cached complete state")
        try text("invalid {", manifest)
        let malformed = scanner.scanSynchronously(model.makeScanRequest())
        require(!malformed.steamGames.contains { $0.appId == "1000" && $0.installed }, "malformed manifest cannot reuse stale installed state")

        let stale = scanner.scanSynchronously(model.makeScanRequest())
        model.selectedAccountID = other
        require(!model.applyScan(stale), "account change rejects an earlier result")
        model.selectedAccountID = account
        let oldGeneration = scanner.scanSynchronously(model.makeScanRequest())
        _ = model.makeScanRequest()
        require(!model.applyScan(oldGeneration), "new generation rejects earlier same-account result")

        let beforeAuth = scanner.scanSynchronously(model.makeScanRequest())
        require(model.acceptAuthenticatedLibrary(accountID: account, list: [["appid":"1999", "name":"Live auth"]]), "new auth accepted while scan result is pending")
        model.epicSnapshot = EpicSnapshot(accountId: "epic-fixture", displayName: "Epic", games: [["appName":"epic-new", "title":"Latest Epic", "platforms":["mac"]]], installed: [], source: "fixture", updatedAt: "2026-10-25T00:00:00Z")
        model.epicSnapshotFresh = true
        require(model.applyScan(beforeAuth), "pending matching result applies")
        require(model.games.contains { $0.appId == "1999" && $0.ownership == "authenticated-library" }, "live Steam auth survives apply")
        require(model.games.contains { $0.appId == "epic-new" && $0.title == "Latest Epic" }, "latest Epic snapshot survives apply")
        require(model.libraryStatus == "synced" && model.epicSnapshotFresh, "auth freshness is retained")
        try fm.removeItem(at: login)
        let missingLogin = scanner.scanSynchronously(model.makeScanRequest())
        require(model.applyScan(missingLogin) && model.selectedAccountID == account && model.libraryStatus == "synced", "transient local login absence is not logout")
        require(!model.warnings.contains { $0.contains("Highball") }, "no unrelated launcher warning")

        let dxmt = Runtime(id: "dxmt", name: "Windows", platform: "windows", steamRoot: steam, appURL: steam)
        let dx12 = Runtime(id: "dx12", name: "Windows12", platform: "windows", steamRoot: steam, appURL: steam, renderer: "d3dmetal")
        var satisfactory = Game(id: "s", appId: "526870", title: "Satisfactory", store: "steam", installed: false, platform: "windows", runtimeId: "dxmt", runtimeName: "Windows", ownership: "authenticated-library")
        satisfactory.supportedPlatforms = ["windows"]
        let routes = satisfactory.json(runtimes: [dxmt, dx12])["installRoutes"] as! [[String: Any]]
        require(routes.count == 1 && routes[0]["runtimeId"] as? String == "dxmt", "Satisfactory cannot choose DX12")
        satisfactory.appId = "2584270"
        let dx12Routes = satisfactory.json(runtimes: [dxmt, dx12])["installRoutes"] as! [[String: Any]]
        require(dx12Routes.count == 1 && dx12Routes[0]["canInstall"] as? Bool == true && dx12Routes[0]["canInstallAndPlay"] as? Bool == false, "unvalidated DX12 offers installation only")
        require(dxmt.displayName == "DirectX 11" && dx12.displayName == "DirectX 12", "route labels match renderers")

        func pump(until condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(3)
            while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
            require(condition(), "async fixture timed out")
        }
        let raceScanner = LibraryScanner(), raceEntered = DispatchSemaphore(value: 0), raceRelease = DispatchSemaphore(value: 0)
        let raceBasis = model.makeScanRequest()
        let oldSavedData = prefs.data(forKey: "steamLibrarySnapshot." + account)
        let raceRequest = LibraryScanRequest(generation: raceBasis.generation, requestedAccountID: account, home: scratch, runtimes: raceBasis.runtimes,
                                            readSavedSnapshot: { _ in raceEntered.signal(); _ = raceRelease.wait(timeout: .now()+2); return oldSavedData })
        var raceApplied = false
        raceScanner.scan(raceRequest) { result in raceApplied = model.applyScan(result) }
        require(raceEntered.wait(timeout: .now()+2) == .success, "auth race reaches worker while running")
        require(model.acceptAuthenticatedLibrary(accountID: account, list: [["appid":"1888", "name":"Newer auth"]]), "auth arrives during worker scan")
        model.epicSnapshot = EpicSnapshot(accountId: "epic-fixture", displayName: "Epic", games: [["appName":"epic-latest", "title":"During scan", "platforms":["mac"]]], installed: [], source: "fixture", updatedAt: "2026-10-25T00:00:01Z")
        raceRelease.signal(); pump { raceApplied }
        require(model.games.contains { $0.appId == "1888" && $0.ownership == "authenticated-library" } && !model.games.contains { $0.appId == "1999" }, "old saved auth cannot overwrite newer live auth")
        require(model.games.contains { $0.appId == "epic-latest" } && !model.games.contains { $0.appId == "epic-new" }, "Epic change during worker is preserved")
        var raceClosed = false; raceScanner.shutdown { raceClosed = true }; pump { raceClosed }
        let asyncScanner = LibraryScanner(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let basis = model.makeScanRequest()
        let held = LibraryScanRequest(generation: 1, requestedAccountID: account, home: scratch, runtimes: basis.runtimes,
                                      readSavedSnapshot: { _ in entered.signal(); _ = release.wait(timeout: .now()+2); return nil })
        var delivered: [UInt64] = []
        asyncScanner.scan(held) { result in require(Thread.isMainThread, "callbacks must arrive on main"); delivered.append(result.generation) }
        require(entered.wait(timeout: .now()+2) == .success, "worker reached held snapshot read")
        for generation in [UInt64(2), UInt64(3)] {
            let request = LibraryScanRequest(generation: generation, requestedAccountID: account, home: scratch, runtimes: basis.runtimes, readSavedSnapshot: { _ in nil })
            asyncScanner.scan(request) { result in require(Thread.isMainThread, "callback main thread"); delivered.append(result.generation) }
        }
        release.signal(); pump { !delivered.isEmpty }
        require(delivered == [3], "only latest pending request delivered")
        var closed = false; asyncScanner.shutdown { closed = true }; pump { closed }

        let closingScanner = LibraryScanner(), closingEntered = DispatchSemaphore(value: 0), closingRelease = DispatchSemaphore(value: 0)
        let closingRequest = LibraryScanRequest(generation: 4, requestedAccountID: account, home: scratch, runtimes: basis.runtimes,
                                                readSavedSnapshot: { _ in closingEntered.signal(); _ = closingRelease.wait(timeout: .now()+2); return nil })
        var unwanted = false, shutdown = false
        closingScanner.scan(closingRequest) { _ in unwanted = true }
        require(closingEntered.wait(timeout: .now()+2) == .success, "shutdown test reached running scan")
        closingScanner.scan(basis) { _ in unwanted = true }
        closingScanner.shutdown { shutdown = true }; closingRelease.signal(); pump { shutdown }
        require(!unwanted, "shutdown suppresses queued and in-flight result callbacks")
        var stopped = false; scanner.shutdown { stopped = true }; pump { stopped }
        print("LibraryScan: \(checks) CPU fixture checks passed; no app, Steam, Wine, Metal device or game launched.")
    }
}
