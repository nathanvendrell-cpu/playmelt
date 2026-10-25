import Foundation

func runSelfTests() {
    var passed = 0; var failed = 0
    func check(_ label: String, _ test: @autoclosure () -> Bool) { if test() { passed += 1; print("PASS \(label)") } else { failed += 1; print("FAIL \(label)") } }
    var loginLifetime = SteamAuthenticationLifetime()
    check("closed sign-in page cannot start capture", loginLifetime.beginCapture() == nil)
    check("sign-in page opens explicitly", loginLifetime.open())
    let firstCapture = loginLifetime.beginCapture()!
    check("duplicate sign-in capture is coalesced", loginLifetime.beginCapture() == nil)
    loginLifetime.releasePage()
    check("closing page invalidates pending sign-in result", !loginLifetime.finishCapture(firstCapture) && !loginLifetime.isOpen)
    check("released sign-in page can be reopened", loginLifetime.open())
    let beforeNavigation = loginLifetime.beginCapture()!
    loginLifetime.navigate()
    check("navigation invalidates previous capture", !loginLifetime.finishCapture(beforeNavigation))
    let currentCapture = loginLifetime.beginCapture()!
    check("only current sign-in capture can finish", loginLifetime.finishCapture(currentCapture))
    check("one capture can finish only once", !loginLifetime.finishCapture(currentCapture))
    loginLifetime.shutdown()
    check("app shutdown prevents reopening sign-in page", !loginLifetime.open() && loginLifetime.beginCapture() == nil)
    var cadence = SteamInstallPollingPolicy()
    let pause = SteamInstallObservation(status: "paused", message: "Paused")
    check("paused installation uses slower fallback", cadence.delay(for: pause) == 10)
    check("unchanged pause backs off to thirty seconds", cadence.delay(for: pause) == 30)
    let activeDownload = SteamInstallObservation(status: "downloading", message: "Downloading", downloaded: 1, total: 100)
    check("resumed download returns to responsive cadence", cadence.delay(for: activeDownload) == 2)
    check("unchanged active manifest avoids two-second parsing", cadence.delay(for: activeDownload) == 5)
    let completedDownload = SteamInstallObservation(status: "installing", message: "Ready", ready: true, signature: "build:1")
    check("completion retains a second separated validation", cadence.delay(for: completedDownload) == 2 && cadence.delay(for: completedDownload) == 2)
    let parsed = try? TextVDF.parse("// comment\n\"AppState\" { \"appid\" \"427520\" \"name\" \"A \\\"quoted\\\" game\" \"path\" \"C:\\\\Games\" }")
    check("VDF nested app identifier", parsed?.object("appstate").string("appid") == "427520")
    check("VDF escaped quotes", parsed?.object("AppState").string("name") == "A \"quoted\" game")
    check("VDF escaped path", parsed?.object("AppState").string("path") == "C:\\Games")
    check("VDF truncated rejected", (try? TextVDF.parse("\"x\" { \"y\" \"z\"")) == nil)
    check("VDF orphan close rejected", (try? TextVDF.parse("}")) == nil)
    check("VDF deep nesting rejected", (try? TextVDF.parse(String(repeating: "x { ", count: 60) + String(repeating: "}", count: 60))) == nil)
    check("valid app ID", LibraryModel.validAppID("526870"))
    check("shell injection rejected", !LibraryModel.validAppID("1; touch /tmp/owned"))
    check("URL injection rejected", !LibraryModel.validAppID("1/../../2"))
    check("overflow app ID rejected", !LibraryModel.validAppID("999999999999999999"))
    check("zero app ID rejected", !LibraryModel.validAppID("0"))
    check("Steam host allowed", SteamAuthentication.allowed(URL(string: "https://steamcommunity.com/my/games/")!))
    check("Steam subdomain allowed", SteamAuthentication.allowed(URL(string: "https://store.steampowered.com/login")!))
    check("host suffix attack rejected", !SteamAuthentication.allowed(URL(string: "https://steamcommunity.com.attacker.example/")!))
    check("prefix spoof rejected", !SteamAuthentication.allowed(URL(string: "https://evilsteamcommunity.com/")!))
    check("HTTP rejected", !SteamAuthentication.allowed(URL(string: "http://steamcommunity.com/")!))
    check("file rejected", !SteamAuthentication.allowed(URL(string: "file:///tmp/index.html")!))
    check("Steam credential URL rejected", !SteamAuthentication.allowed(URL(string: "https://user:pass@steamcommunity.com/")!))
    check("Steam alternate port rejected", !SteamAuthentication.allowed(URL(string: "https://steamcommunity.com:9443/")!))
    check("artwork ID accepted", SteamArtworkHandler.appID(URL(string: "metalmaxart://steam/427520")!) == "427520")
    check("artwork host rejected", SteamArtworkHandler.appID(URL(string: "metalmaxart://attacker/427520")!) == nil)
    check("artwork traversal rejected", SteamArtworkHandler.appID(URL(string: "metalmaxart://steam/427520/../../secret")!) == nil)
    check("artwork query rejected", SteamArtworkHandler.appID(URL(string: "metalmaxart://steam/427520?path=secret")!) == nil)
    check("portrait artwork accepted", SteamArtworkHandler.appID(URL(string: "metalmaxart://steam/427520/portrait")!) == "427520")
    check("unknown artwork variant rejected", SteamArtworkHandler.appID(URL(string: "metalmaxart://steam/427520/secret")!) == nil)
    check("artwork credential URL rejected", SteamArtworkHandler.appID(URL(string: "metalmaxart://user@steam/427520")!) == nil)
    let artworkHash = "369aba23e970440c4cee20e332d6ac4fdc2d3ce1"
    let artworkFixture: [String: Any] = ["library_assets_full": ["library_capsule": ["image": ["english": artworkHash + "/library_capsule.jpg"]], "library_header": ["image": ["english": artworkHash + "/library_header.jpg"]]]]
    check("modern portrait metadata selected", SteamAppInfo.artworkPaths(artworkFixture, portrait: true).first == artworkHash + "/library_capsule.jpg")
    check("modern landscape metadata selected", SteamAppInfo.artworkPaths(artworkFixture, portrait: false).first == artworkHash + "/library_header.jpg")
    check("metadata traversal rejected", !SteamAppInfo.validArtworkPath("../library_capsule.jpg"))
    check("metadata encoded traversal rejected", !SteamAppInfo.validArtworkPath("%2e%2e/library_capsule.jpg"))
    check("metadata external URL rejected", !SteamAppInfo.validArtworkPath("https://attacker.example/library_capsule.jpg"))
    check("metadata unrelated image rejected", !SteamAppInfo.validArtworkPath(artworkHash + "/logo.png"))
    check("metadata exact CDN path retained", SteamAppInfo.artworkURL(appID: "4731620", path: artworkHash + "/library_capsule.jpg") == "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/4731620/" + artworkHash + "/library_capsule.jpg")
    let preferenceSuite = "com.robtech.metalmax.selftest.\(UUID().uuidString)"
    let prefs = UserDefaults(suiteName: preferenceSuite)!
    check("render protection defaults to on", RenderProtection.enabled(in: prefs))
    prefs.set(false, forKey: RenderProtection.preferenceKey)
    check("render protection changes only after explicit setting", !RenderProtection.enabled(in: prefs))
    prefs.removeObject(forKey: RenderProtection.preferenceKey)
    check("all execution routes are protected", ["launchGame", "installGame", "installAndPlay", "setupD3DMetalRuntime", "installSteamD3DMetal", "openD3DMetalSteam", "setupWindowsRuntime", "installSteamWindows", "openWindowsSteam"].allSatisfy { RenderProtection.blocks($0, enabled: true) })
    check("read and cancel routes remain available during renders", ["refresh", "importD3DMetal", "openSteamLogin", "cancelD3DMetalRuntime", "cancelInstallAndPlay"].allSatisfy { !RenderProtection.blocks($0, enabled: true) })
    check("explicit render protection off releases action gate only", !RenderProtection.blocks("launchGame", enabled: false))
    let model = LibraryModel(home: URL(fileURLWithPath: "/nonexistent-metalmax-fixture"), preferences: prefs)
    check("discovery exposes only native Steam without independent engine", model.discoverRuntimes().allSatisfy { $0.id == "steam-mac" && $0.platform == "mac" })
    check("recent Steam account preferred over autologin", activeSteamAccount(["76561198000000000": ["AutoLogin": "1"], "76561198000000001": ["MostRecent": "1"]]) == "76561198000000001")
    check("official Steam installer URL allowed", SteamWindowsBootstrap.allowed(URL(string: "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe")!))
    check("untrusted installer URL rejected", !SteamWindowsBootstrap.allowed(URL(string: "https://cdn.akamai.steamstatic.com.evil.example/client/installer/SteamSetup.exe")!))
    check("unexpected Steam executable URL rejected", !SteamWindowsBootstrap.allowed(URL(string: "https://cdn.akamai.steamstatic.com/client/installer/Other.exe")!))
    check("Steam installer query redirect rejected", !SteamWindowsBootstrap.allowed(URL(string: "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe?other=1")!))
    check("Steam disk-full error is not called a network error", SteamWindowsBootstrap.downloadErrorMessage(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)).contains("Espace disque"))
    check("Steam network error is actionable", SteamWindowsBootstrap.downloadErrorMessage(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)).contains("réseau"))
    var requestTime: TimeInterval = 10
    let gate = SteamRequestGate(clock: { requestTime })
    let firstRequest = gate.acquire("game")!
    check("duplicate dispatch rejected while pending", gate.acquire("game") == nil)
    requestTime = 20
    check("pending dispatch stays locked until callback", gate.acquire("game") == nil)
    gate.finish("game", token: UUID())
    check("unrelated dispatch callback cannot unlock request", gate.acquire("game") == nil)
    gate.finish("game", token: firstRequest)
    let secondRequest = gate.acquire("game")!
    gate.finish("game", token: firstRequest)
    check("stale callback cannot unlock replacement request", gate.acquire("game") == nil)
    gate.finish("game", token: secondRequest)
    check("rapid repeated completed dispatch is coalesced", gate.acquire("game") == nil)
    requestTime = 23
    check("later explicit dispatch can retry", gate.acquire("game") != nil)
    gate.shutdown()
    check("shutdown refuses every new dispatch", gate.acquire("other") == nil)
    check("Satisfactory launch profile explicitly selects DX11", ScriptHandler.windowsLaunchArguments(appID: "526870") == ["-applaunch", "526870", "-dx11"])
    check("known DX12-only game has no DX11 launch profile", ScriptHandler.windowsLaunchArguments(appID: "2584270") == nil)
    let fixtureRoot = URL(fileURLWithPath: "/nonexistent-playmelt-runtime")
    let dxmtRoute = Runtime(id: "dxmt-fixture", name: "DXMT", platform: "windows", steamRoot: fixtureRoot, appURL: nil)
    var metalRoute = dxmtRoute; metalRoute.renderer = "d3dmetal"
    check("Mortal Shell cannot install into DXMT", !SteamGameLaunchProfile.supportsInstallation(appID: "2584270", runtime: dxmtRoute))
    check("Mortal Shell installs only into its DX12 route", SteamGameLaunchProfile.supportsInstallation(appID: "2584270", runtime: metalRoute))
    check("Satisfactory keeps its DX11 route", !SteamGameLaunchProfile.supportsInstallation(appID: "526870", runtime: metalRoute))
    check("prepared DX12 is not qualified to launch", SteamGameLaunchProfile.windowsArguments(appID: "2584270", renderer: "d3dmetal") == nil)
    check("unqualified DX12 also blocks unprofiled games", SteamGameLaunchProfile.windowsArguments(appID: "12345", renderer: "d3dmetal") == nil)
    check("future qualified DX12 route uses game default API", SteamGameLaunchProfile.windowsArguments(appID: "2584270", renderer: "d3dmetal", graphicsValidated: true) == ["-applaunch", "2584270"])
    check("a qualification flag cannot turn DXMT into DX12", SteamGameLaunchProfile.windowsArguments(appID: "2584270", renderer: "dxmt", graphicsValidated: true) == nil)
    let originalRuntime = PlaymeltRuntimeDescriptor(engineID: "fixture", wineURL: fixtureRoot.appendingPathComponent("wine"), wineserverURL: fixtureRoot.appendingPathComponent("wineserver"), prefixURL: fixtureRoot.appendingPathComponent("dxmt-prefix"), steamRoot: fixtureRoot.appendingPathComponent("Steam"), environment: ["WINEPREFIX": "dxmt-prefix"], readyEngine: true, steamInstalled: false)
    let otherPrefix = PlaymeltRuntimeDescriptor(engineID: originalRuntime.engineID, wineURL: originalRuntime.wineURL, wineserverURL: originalRuntime.wineserverURL, prefixURL: fixtureRoot.appendingPathComponent("d3dmetal-prefix"), steamRoot: originalRuntime.steamRoot, environment: originalRuntime.environment, readyEngine: true, steamInstalled: false)
    let otherOverlay = PlaymeltRuntimeDescriptor(engineID: originalRuntime.engineID, wineURL: originalRuntime.wineURL, wineserverURL: originalRuntime.wineserverURL, prefixURL: originalRuntime.prefixURL, steamRoot: originalRuntime.steamRoot, environment: ["WINEDLLPATH_PREPEND": "other"], readyEngine: true, steamInstalled: false)
    check("installer remains bound to the selected runtime", SteamWindowsBootstrap.sameRuntime(originalRuntime, originalRuntime))
    check("installer refuses prefix change during download", !SteamWindowsBootstrap.sameRuntime(originalRuntime, otherPrefix))
    check("installer refuses overlay change during download", !SteamWindowsBootstrap.sameRuntime(originalRuntime, otherOverlay))
    let unavailableBootstrap = SteamWindowsBootstrap(downloadsRoot: fixtureRoot.appendingPathComponent("downloads"), descriptor: { nil })
    unavailableBootstrap.start()
    check("missing DX12 descriptor cannot fall back to another Steam", !unavailableBootstrap.busy && unavailableBootstrap.snapshot["steamPhase"] as? String == "failed")
    var bootstrapStopped = false
    unavailableBootstrap.shutdown { bootstrapStopped = true }
    let bootstrapDeadline = Date().addingTimeInterval(2)
    while !bootstrapStopped && Date() < bootstrapDeadline {
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    check("unused Steam bootstrap shutdown completes without a process", bootstrapStopped && !unavailableBootstrap.busy)
    check("injected game launch args rejected", ScriptHandler.windowsLaunchArguments(appID: "526870 -exec anything") == nil)
    model.selectedAccountID = "76561198000000000"
    check("account mismatch rejected", !model.acceptAuthenticatedLibrary(accountID: "76561198000000001", list: [["appid": "427520", "name": "Factorio"]]))
    check("invalid game data rejected", !model.acceptAuthenticatedLibrary(accountID: "76561198000000000", list: [["appid": "bad", "name": "test"]]))
    check("mismatch never imports", model.authenticatedGames.isEmpty)
    let bad = Game(id: "test", appId: "1", title: "Test", store: "steam", installed: true, platform: "windows", runtimeId: "missing", runtimeName: "Missing", ownership: "installed-only", path: nil, complete: true)
    check("unavailable runtime cannot launch", bad.json(runtimes: [])["canLaunch"] as? Bool == false)
    check("installed game cannot install", bad.json(runtimes: [])["canInstall"] as? Bool == false)
    model.games = [Game(id: "epic-owned:one", appId: "one", title: "Owned", store: "epic", installed: false, platform: "mac", runtimeId: "epic-mac", runtimeName: "Epic", ownership: "authenticated-library")]
    model.epicSnapshot = EpicSnapshot(accountId: "fixture", displayName: "Fixture", games: [["appName": "one"]], installed: [], source: "fixture", updatedAt: "2026-10-24T00:00:00Z")
    model.epicAvailability = ["authenticated": true]
    check("owned Epic game not counted as installed", (model.state()["epic"] as? [String: Any])?["installedCount"] as? Int == 0)
    check("failed Epic refresh leaves snapshot status", (model.state()["epic"] as? [String: Any])?["status"] as? String == "snapshot")
    model.epicSnapshotFresh = true
    check("fresh authenticated Epic snapshot synced", (model.state()["epic"] as? [String: Any])?["status"] as? String == "synced")
    model.epicAvailability = ["authenticated": false]
    check("expired Epic session never synced", (model.state()["epic"] as? [String: Any])?["status"] as? String == "snapshot")
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("metalmax-selftest-\(UUID().uuidString)")
    do {
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let cache = temporary.appendingPathComponent("cache")
        let fixtureHome = temporary.appendingPathComponent("home")
        let loginConfig = fixtureHome.appendingPathComponent("Library/Application Support/Steam/config")
        try FileManager.default.createDirectory(at: loginConfig, withIntermediateDirectories: true)
        try "\"users\" { \"76561198000000000\" { \"PersonaName\" \"Fixture\" \"MostRecent\" \"1\" } }".write(to: loginConfig.appendingPathComponent("loginusers.vdf"), atomically: true, encoding: .utf8)
        let authenticated = LibraryModel(home: fixtureHome, preferences: prefs)
        authenticated.selectedAccountID = "76561198000000000"
        check("empty Steam library cannot overwrite a snapshot", !authenticated.acceptAuthenticatedLibrary(accountID: authenticated.selectedAccountID, list: []))
        check("duplicate Steam ownership entries rejected", !authenticated.acceptAuthenticatedLibrary(accountID: authenticated.selectedAccountID, list: [["appid":"427520","name":"A"],["appid":"427520","name":"B"]]))
        check("modern Steam source accepted for matching account", authenticated.acceptAuthenticatedLibrary(accountID: authenticated.selectedAccountID, list: [["appid":"427520","name":"Factorio"]], source: "steamcommunity-profile-gameslist") && authenticated.libraryStatus == "synced")
        authenticated.beginSteamLibrarySync()
        check("new sync invalidates stale connected status", authenticated.libraryStatus == "snapshot" && authenticated.authenticatedGames[authenticated.selectedAccountID]?.count == 1 && authenticated.liveAuthenticatedAccounts.isEmpty)
        let verified180: [[String: Any]] = (0..<180).map { ["appid": String(1000 + $0), "name": "Game \($0)"] }
        authenticated.games = (0..<195).map { authenticated.makeGame(String(1000 + $0), ownership: "account-cache") }
        authenticated.mergeVerified(verified180)
        check("180 verified games replace 195 historical cards", authenticated.games.count == 180 && authenticated.games.allSatisfy { $0.ownership == "authenticated-library" })
        var otherInstalled = authenticated.makeGame("1194", ownership: "authenticated-library"); otherInstalled.installed = true
        authenticated.games.append(otherInstalled); authenticated.mergeVerified(verified180)
        check("unowned local installation preserved without ownership claim", authenticated.games.count == 181 && authenticated.games.first(where: { $0.appId == "1194" })?.ownership == "installed-only")
        let bootstrap = SteamWindowsBootstrap(runtime: RuntimeSetup(root: temporary.appendingPathComponent("runtime")))
        let staleSession = URLSession(configuration: .ephemeral)
        let staleTask = staleSession.downloadTask(with: URL(string: "https://example.invalid/never-requested")!)
        defer { staleTask.cancel(); staleSession.invalidateAndCancel() }
        bootstrap.urlSession(staleSession, downloadTask: staleTask, didWriteData: 70_000_000, totalBytesWritten: 70_000_000, totalBytesExpectedToWrite: 70_000_000)
        bootstrap.urlSession(staleSession, downloadTask: staleTask, didFinishDownloadingTo: temporary.appendingPathComponent("must-not-open"))
        bootstrap.urlSession(staleSession, task: staleTask, didCompleteWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        check("stale download callbacks cannot mutate or restart bootstrap", bootstrap.snapshot["steamPhase"] as? String == "idle" && !bootstrap.busy)
        let imageDirectory = cache.appendingPathComponent("4731620").appendingPathComponent(artworkHash)
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        let capsule = imageDirectory.appendingPathComponent("library_capsule.jpg")
        try Data([0xff,0xd8,0xff,0xd9]).write(to: capsule)
        let info = SteamAppInfo(name: "Fixture", platforms: ["macos"], type: "game", portraitAssets: [artworkHash + "/library_capsule.jpg"], landscapeAssets: [])
        let candidates = SteamArtworkHandler.candidateFiles(root: cache, appID: "4731620", info: info, portrait: true)
        check("hashed local capsule resolved before legacy paths", candidates.first == capsule.resolvingSymlinksInPath())
        check("hashed local capsule exists", candidates.first.map { FileManager.default.fileExists(atPath: $0.path) } == true)
        let otherApp = cache.appendingPathComponent("999")
        try FileManager.default.createDirectory(at: otherApp, withIntermediateDirectories: true)
        let unsafeHash = String(repeating: "a", count: 40)
        try FileManager.default.createSymbolicLink(at: cache.appendingPathComponent("4731620").appendingPathComponent(unsafeHash), withDestinationURL: otherApp)
        let unsafeInfo = SteamAppInfo(name: "Fixture", platforms: [], type: "game", portraitAssets: [unsafeHash + "/library_capsule.jpg"])
        check("artwork symlink into another game rejected", !SteamArtworkHandler.candidateFiles(root: cache, appID: "4731620", info: unsafeInfo, portrait: true).contains { $0.path.hasPrefix(otherApp.path + "/") })
        let executable = temporary.appendingPathComponent("game")
        check("empty installation has no binary", !containsLaunchBinary(temporary, platform: "mac"))
        try Data([0xcf, 0xfa, 0xed, 0xfe]).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        check("MachO signature detected without execution", containsLaunchBinary(temporary, platform: "mac"))
        try Data("not a Mac executable".utf8).write(to: executable)
        check("executable text not classified as native binary", !containsLaunchBinary(temporary, platform: "mac"))
        let appInfo = temporary.appendingPathComponent("appinfo.vdf")
        try Data([0x29,0x44,0x56,0x07,0,0,0,0]).write(to: appInfo)
        check("truncated appinfo rejected", SteamAppInfo.load(appInfo).isEmpty)
        let steam = temporary.appendingPathComponent("Steam"), apps = steam.appendingPathComponent("steamapps")
        let gameDirectory = apps.appendingPathComponent("common/Fixture")
        try FileManager.default.createDirectory(at: gameDirectory, withIntermediateDirectories: true)
        check("dot install directory cannot reuse another game binary", steamInstallationPath(apps: apps, directory: ".") == nil)
        try FileManager.default.createSymbolicLink(at: apps.appendingPathComponent("common/Escape"), withDestinationURL: temporary)
        check("game directory symlink escape rejected", steamInstallationPath(apps: apps, directory: "Escape") == nil)
        let pe = gameDirectory.appendingPathComponent("Fixture.exe"); try Data([0x4d,0x5a,0,0]).write(to: pe)
        let manifest = apps.appendingPathComponent("appmanifest_526870.acf")
        let accountID = "76561198000000000"
        func writeManifest(flags: String = "4", extra: String = "", updateResult: String? = "0", downloaded: String = "100", owner: String? = nil) throws {
            let result = updateResult.map { "\"UpdateResult\" \"\($0)\"" } ?? ""
            let value = "\"AppState\" { \"appid\" \"526870\" \"StateFlags\" \"\(flags)\" \"installdir\" \"Fixture\" \"buildid\" \"123\" \"LastOwner\" \"\(owner ?? accountID)\" \"BytesToDownload\" \"100\" \"BytesDownloaded\" \"\(downloaded)\" \(result) \(extra) }"
            try value.write(to: manifest, atomically: true, encoding: .utf8)
        }
        func observe() -> SteamInstallObservation { SteamInstallManifest.inspect(manifest, appID: "526870", platform: "windows", accountID: accountID) }
        try writeManifest(); check("completed manifest and PE ready", observe().ready)
        try writeManifest(flags: "1048576"); check("100 percent bytes is not installation complete", !observe().ready && observe().status == "downloading")
        try writeManifest(flags: "516"); check("paused download never auto-launches", !observe().ready && observe().status == "paused")
        try writeManifest(flags: "131072"); check("validation phase never auto-launches", !observe().ready && observe().status == "validating")
        try writeManifest(updateResult: "54"); check("disk full reported without auto-launch", !observe().ready && observe().status == "disk-space")
        try writeManifest(updateResult: "2"); check("Steam failure stops installation job", observe().failed)
        try writeManifest(extra: "\"TargetBuildID\" \"124\""); check("target build mismatch blocks auto-launch", !observe().ready)
        try writeManifest(extra: "\"BytesToStage\" \"100\" \"BytesStaged\" \"20\""); check("pending staging blocks auto-launch", !observe().ready)
        try writeManifest(updateResult: nil); check("legacy complete manifest can omit UpdateResult", observe().ready)
        try writeManifest(owner: "76561198000000001"); check("different installation account blocks auto-launch", observe().failed)
        try writeManifest(); try FileManager.default.removeItem(at: pe); check("missing game binary blocks auto-launch", !observe().ready)
        let newerManifest = temporary.appendingPathComponent("new-library.acf")
        try "\"AppState\" {".write(to: newerManifest, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 10)], ofItemAtPath: manifest.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 20)], ofItemAtPath: newerManifest.path)
        check("new library manifest supersedes stale original location", SteamInstallManifest.latestManifest(in: [manifest, newerManifest]) == newerManifest)
        check("partially written manifest cannot signal ready", !SteamInstallManifest.inspect(newerManifest, appID: "526870", platform: "windows", accountID: accountID).ready)
        let prefix = temporary.appendingPathComponent("prefix"), drive = prefix.appendingPathComponent("drive_c")
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: drive.appendingPathComponent("Escape"), withDestinationURL: temporary)
        let folders = "\"libraryfolders\" { \"0\" { \"path\" \"C:\\\\Games\" } \"1\" { \"path\" \"C:\\\\..\\\\outside\" } \"2\" { \"path\" \"C:\\\\Escape\" } }"
        try folders.write(to: apps.appendingPathComponent("libraryfolders.vdf"), atomically: true, encoding: .utf8)
        let locations = SteamInstallManifest.locations(steamRoot: steam, appID: "526870", platform: "windows", prefix: prefix)
        check("owned Windows C library mapped", locations.contains { $0.path.contains("/drive_c/Games/") })
        check("Windows traversal library rejected", !locations.contains { $0.path.contains("/outside/") })
        check("Windows symlink escape library rejected", locations.count == 2)
        let coordinator = SteamInstallCoordinator()
        let fixtureRuntime = Runtime(id: "fixture", name: "Fixture", platform: "windows", steamRoot: steam, appURL: nil)
        let jobID = coordinator.begin(gameID: "fixture", appID: "526870", title: "Fixture", runtime: fixtureRuntime, accountID: accountID) { _ in }
        check("single install job starts", jobID != nil && coordinator.isActive)
        check("parallel installation job rejected", coordinator.begin(gameID: "two", appID: "427520", title: "Two", runtime: fixtureRuntime, accountID: accountID) { _ in } == nil)
        coordinator.cancel(); check("cancel stops auto-launch observation", !coordinator.isActive && coordinator.snapshot?["status"] as? String == "cancelled")
        let secondJob = coordinator.begin(gameID: "two", appID: "427520", title: "Two", runtime: fixtureRuntime, accountID: accountID) { _ in }
        if let jobID { coordinator.requestFailed(id: jobID, message: "late error") }
        check("late error from cancelled job cannot stop new job", coordinator.isActive && coordinator.snapshot?["id"] as? String == secondJob?.uuidString)
        coordinator.shutdown(); check("shutdown never resumes installation job", !coordinator.isActive)
        let observer = SteamInstallCoordinator()
        var emitted = 0, launched = 0
        observer.onChange = { emitted += 1 }
        let observedID = observer.begin(gameID: "fixture", appID: "526870", title: "Fixture", runtime: fixtureRuntime, accountID: accountID) { _ in launched += 1 }!
        let downloading = SteamInstallObservation(status: "downloading", message: "Downloading", downloaded: 10, total: 100)
        observer.receive(downloading, id: observedID) { _ in launched += 1 }
        let announcements = emitted
        observer.receive(downloading, id: observedID) { _ in launched += 1 }
        check("unchanged install observation does not redraw UI", emitted == announcements)
        let ready = SteamInstallObservation(status: "installing", message: "Ready", downloaded: 100, total: 100, ready: true, signature: "fixture:123")
        observer.receive(ready, id: observedID) { _ in launched += 1 }
        check("one complete observation never auto-launches", launched == 0)
        observer.receive(.init(status: "paused", message: "Paused"), id: observedID) { _ in launched += 1 }
        observer.receive(ready, id: observedID) { _ in launched += 1 }
        check("interrupted completion needs two new ready observations", launched == 0)
        observer.receive(ready, id: observedID) { _ in launched += 1 }
        observer.receive(ready, id: observedID) { _ in launched += 1 }
        check("stable completed install hands off exactly once", launched == 1 && observer.isActive)
        check("ready job remains cancellable during library refresh", observer.snapshot?["cancellable"] as? Bool == true)
        check("account change during handoff finishes the exact job", !observer.confirmLaunchContext(id: observedID, accountChanged: true, executionBlocked: false) && !observer.isActive && observer.snapshot?["status"] as? String == "cancelled")
        check("stale handoff cannot resume after context invalidation", !observer.confirmLaunchContext(id: observedID, accountChanged: false, executionBlocked: false))
        observer.cancel()
        observer.didRequestLaunch(id: observedID, success: true, message: "late launch callback")
        check("cancellation cannot resurrect a launch callback", observer.snapshot?["status"] as? String == "cancelled")
        let timeoutID = observer.begin(gameID: "fixture", appID: "526870", title: "Fixture", runtime: fixtureRuntime, accountID: accountID) { _ in launched += 1 }!
        observer.receive(ready, id: timeoutID, expired: true) { _ in launched += 1 }
        check("expired job stops without launch", !observer.isActive && launched == 1 && observer.snapshot?["status"] as? String == "timed-out")
        let launchID = observer.begin(gameID: "fixture", appID: "526870", title: "Fixture", runtime: fixtureRuntime, accountID: accountID) { _ in }!
        observer.didRequestLaunch(id: launchID, success: true, message: "Requested")
        observer.launchFailed(id: launchID, message: "Client exited with error")
        check("late client failure replaces launch-requested status", observer.snapshot?["status"] as? String == "failed")
        let nextID = observer.begin(gameID: "next", appID: "427520", title: "Next", runtime: fixtureRuntime, accountID: accountID) { _ in }!
        observer.launchFailed(id: launchID, message: "Old failure")
        check("late launch failure cannot overwrite another job", observer.snapshot?["id"] as? String == nextID.uuidString && observer.isActive)
        observer.didRequestLaunch(id: nextID, success: true, message: "Requested")
        observer.shutdown()
        observer.launchFailed(id: nextID, message: "Callback after shutdown")
        check("shutdown ignores late client failure", observer.snapshot?["status"] as? String == "launch-requested")
        check("new app session never restores an automatic job", SteamInstallCoordinator().snapshot == nil)

        let cacheFile = temporary.appendingPathComponent("observer-cache.vdf")
        try Data("\"state\" { \"value\" \"before\" }".utf8).write(to: cacheFile)
        let readCache = SteamInstallReadCache()
        _ = readCache.read(cacheFile); _ = readCache.read(cacheFile)
        check("unchanged install input is parsed once", readCache.reads == 1)
        try Data("\"state\" { \"value\" \"after\" }".utf8).write(to: cacheFile, options: .atomic)
        check("atomic manifest replacement invalidates cache", readCache.read(cacheFile).object("state").string("value") == "after" && readCache.reads == 2)
        try FileManager.default.removeItem(at: cacheFile)
        check("deleted install input cannot return cached state", readCache.read(cacheFile).isEmpty)

        let watchedRoot = temporary.appendingPathComponent("watched-steam")
        let watchedApps = watchedRoot.appendingPathComponent("steamapps")
        try FileManager.default.createDirectory(at: watchedApps, withIntermediateDirectories: true)
        let watchedManifest = watchedApps.appendingPathComponent("appmanifest_526870.acf")
        try Data("\"AppState\" { \"appid\" \"526870\" \"StateFlags\" \"512\" }".utf8).write(to: watchedManifest)
        let watchedRuntime = Runtime(id: "fixture-watcher", name: "Fixture", platform: "windows", steamRoot: watchedRoot, appURL: nil)
        var observations: [String] = [], monitorStopped = false
        var monitor: SteamInstallObserver? = SteamInstallObserver(runtime: watchedRuntime, appID: "526870", accountID: "", timeout: 60) { observation, _, _ in
            check("install observation delivered on main thread", Thread.isMainThread)
            observations.append(observation.status)
        }
        defer { monitor?.stop() }
        func waitFor(_ condition: () -> Bool, seconds: TimeInterval) {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() && Date() < deadline { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        }
        waitFor({ observations.contains("paused") }, seconds: 4)
        check("real filesystem observer reads paused fixture", observations == ["paused"])
        try Data("\"AppState\" { \"appid\" \"526870\" \"StateFlags\" \"1024\" \"BytesDownloaded\" \"1\" \"BytesToDownload\" \"100\" }".utf8).write(to: watchedManifest, options: .atomic)
        waitFor({ observations.contains("downloading") }, seconds: 4)
        check("directory notification bypasses long paused fallback", observations.last == "downloading")
        weak let releasedMonitor = monitor
        monitor?.stop { monitorStopped = true }; monitor = nil
        waitFor({ monitorStopped && releasedMonitor == nil }, seconds: 2)
        check("stopped observer releases sources and instance", monitorStopped && releasedMonitor == nil)
    } catch { failed += 1; print("FAIL temporary fixture setup") }
    prefs.removePersistentDomain(forName: preferenceSuite)
    print("\(passed) passed; \(failed) failed")
    exit(failed == 0 ? 0 : 1)
}
