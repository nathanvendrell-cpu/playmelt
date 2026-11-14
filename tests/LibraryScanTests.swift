import Foundation

@main
enum LibraryScanTests {
    static func main() throws {
        let fm = FileManager.default
        let scratch = URL(fileURLWithPath:fm.currentDirectoryPath).appendingPathComponent("Products.noindex/playmelt-library-tests-" + UUID().uuidString).resolvingSymlinksInPath()
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: scratch) }
        let suite = "PlaymeltLibraryTests." + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        var checks = 0
        func require(_ value: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !value() {
                prefs.removePersistentDomain(forName: suite)
                try? fm.removeItem(at: scratch)
                fatalError(message)
            }
        }
        func write(_ value: Data, _ file: URL) throws {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try value.write(to: file)
        }
        func text(_ value: String, _ file: URL) throws { try write(Data(value.utf8), file) }
        func u32(_ value: UInt32) -> Data { var v = value.littleEndian; return withUnsafeBytes(of: &v) { Data($0) } }
        func appinfo(name: String, windowsOnlyID: UInt32? = nil) -> Data {
            func string(_ value: String) -> Data { Data(value.utf8) + Data([0]) }
            func property(_ key: String, _ value: String) -> Data { Data([1]) + string(key) + string(value) }
            var data = u32(0x07564427) + u32(1)
            for id in 1000..<2000 {
                let body = Data([0]) + string("appinfo") + Data([0]) + string("common") + property("name", name + String(id)) + property("oslist", "macos,windows") + property("type", "game") + Data([8,8,8])
                data += u32(UInt32(id)) + u32(UInt32(40 + body.count)) + Data(repeating: 0, count: 40) + body
            }
            if let id = windowsOnlyID {
                let body = Data([0]) + string("appinfo") + Data([0]) + string("common") + property("name", "Windows only") + property("oslist", "windows") + property("type", "game") + Data([8,8,8])
                data += u32(id) + u32(UInt32(40 + body.count)) + Data(repeating: 0, count: 40) + body
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

        let localFolder=scratch.appendingPathComponent("Library/Application Support/Playmelt/Games/MarvelsSpiderMan2")
        let localExecutable=localFolder.appendingPathComponent("Spider-Man2.exe")
        try write(Data([0x4d,0x5a,0,0]),localExecutable)
        let localScan=scanner.scanSynchronously(model.makeScanRequest())
        require(localScan.launchPreflights["local:2651280"]?.directCandidate == true,"worker prepares display diagnostics for local Windows games")
        try fm.removeItem(at:localExecutable)
        let removedLocal=scanner.scanSynchronously(model.makeScanRequest())
        require(removedLocal.launchPreflights["local:2651280"]?.issue != nil,"next scan invalidates readiness after executable deletion")

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

        // Inert fixtures still model the real engine prerequisites: an
        // executable host file, an independent engine and a selected prefix.
        // No fixture executable is ever run by this test.
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: app.path)
        let dxmt = Runtime(id: "dxmt", name: "Windows", platform: "windows", steamRoot: steam, appURL: nil, wineURL: app, prefixURL: scratch, verifiedIndependentEngine: true)
        let dx12 = Runtime(id: "dx12", name: "Windows12", platform: "windows", steamRoot: steam, appURL: nil, wineURL: app, prefixURL: scratch, verifiedIndependentEngine: true, renderer: "d3dmetal")
        require(dxmt.installationAvailable && dx12.installationAvailable, "route fixtures meet independent-engine/executable/prefix installation prerequisites")
        var satisfactory = Game(id: "s", appId: "526870", title: "Satisfactory", store: "steam", installed: false, platform: "windows", runtimeId: "dxmt", runtimeName: "Windows", ownership: "authenticated-library")
        satisfactory.supportedPlatforms = ["windows"]
        let routes = satisfactory.json(runtimes: [dxmt, dx12])["installRoutes"] as! [[String: Any]]
        require(routes.count == 1 && routes[0]["runtimeId"] as? String == "dxmt", "Satisfactory cannot choose DX12")
        satisfactory.appId = "2584270"
        let dx12Routes = satisfactory.json(runtimes: [dxmt, dx12])["installRoutes"] as! [[String: Any]]
        require(dx12Routes.count == 1 && dx12Routes[0]["canInstall"] as? Bool == true && dx12Routes[0]["canInstallAndPlay"] as? Bool == true, "prepared DX12 offers an official first launch without claiming graphics qualification")
        require(dxmt.displayName == "DirectX 11" && dx12.displayName == "DirectX 12", "route labels match renderers")

        func pump(until condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(3)
            while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
            require(condition(), "async fixture timed out")
        }

        // Distinct installed routes for a shared AppID must survive discovery
        // of a local Windows copy. These are inert files, never executables run.
        let routeHome = scratch.appendingPathComponent("route-fixtures")
        let nativeSteam = routeHome.appendingPathComponent("Library/Application Support/Steam")
        let win11Prefix = routeHome.appendingPathComponent("Windows11Prefix")
        let win12Prefix = routeHome.appendingPathComponent("Windows12Prefix")
        let win11Steam = win11Prefix.appendingPathComponent("drive_c/Steam")
        let win12Steam = win12Prefix.appendingPathComponent("drive_c/Steam")
        let fixtureWine = routeHome.appendingPathComponent("fixture-engine/bin/wine")
        try text("inert host fixture; never execute", fixtureWine)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixtureWine.path)
        for root in [win11Steam, win12Steam] { try write(Data([0x4d, 0x5a]), root.appendingPathComponent("steam.exe")) }
        let nativeRuntime = Runtime(id: "native-route", name: "Fixture Mac", platform: "mac", steamRoot: nativeSteam, appURL: app)
        let win11Runtime = Runtime(id: "dx11-route", name: "Fixture DX11", platform: "windows", steamRoot: win11Steam, appURL: nil, wineURL: fixtureWine, prefixURL: win11Prefix, verifiedIndependentEngine: true)
        let win12Runtime = Runtime(id: "dx12-route", name: "Fixture DX12", platform: "windows", steamRoot: win12Steam, appURL: nil, wineURL: fixtureWine, prefixURL: win12Prefix, verifiedIndependentEngine: true, renderer: "d3dmetal")
        require(win11Runtime.installationAvailable && win11Runtime.available && win12Runtime.installationAvailable && win12Runtime.available, "mixed-platform fixtures provide independent executable engines, separate prefixes and inert Windows clients")
        try write(appinfo(name: "Mixed", windowsOnlyID: 1783560), nativeSteam.appendingPathComponent("appcache/appinfo.vdf"))
        let nativeGamePath = nativeSteam.appendingPathComponent("steamapps/common/NativeCopy")
        let win11GamePath = win11Steam.appendingPathComponent("steamapps/common/Windows11Copy")
        let win12GamePath = win12Steam.appendingPathComponent("steamapps/common/Windows12Copy")
        for (root, directory) in [(nativeSteam, "NativeCopy"), (win11Steam, "Windows11Copy"), (win12Steam, "Windows12Copy")] {
            try text("\"AppState\" { \"appid\" \"1000\" \"name\" \"Mixed\" \"installdir\" \"\(directory)\" \"StateFlags\" \"4\" }", root.appendingPathComponent("steamapps/appmanifest_1000.acf"))
        }
        let nativeBinary = nativeGamePath.appendingPathComponent("Game")
        try write(Data([0xcf, 0xfa, 0xed, 0xfe]), nativeBinary)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: nativeBinary.path)
        try write(Data([0x4d, 0x5a]), win11GamePath.appendingPathComponent("Game.exe"))
        try write(Data([0x4d, 0x5a]), win12GamePath.appendingPathComponent("Game.exe"))
        let localGames = routeHome.appendingPathComponent("Library/Application Support/Playmelt/Games")
        let localMixed = localGames.appendingPathComponent("MixedLocal")
        let localOtherMixed = localGames.appendingPathComponent("MixedOtherLocal")
        let localDX12 = localGames.appendingPathComponent("CaretakerLocal")
        for (folder, id) in [(localMixed, "1000"), (localOtherMixed, "1000"), (localDX12, "1783560")] {
            try text(id + "\n", folder.appendingPathComponent("Windows/steam_appid.txt"))
            try write(Data([0x4d, 0x5a]), folder.appendingPathComponent("Windows/Game.exe"))
        }
        func sourceContents() throws -> [String: Data] {
            var result: [String: Data] = [:]
            let walker = fm.enumerator(at: routeHome, includingPropertiesForKeys: [.isRegularFileKey])!
            for case let file as URL in walker where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                result[file.path] = try Data(contentsOf: file)
            }
            return result
        }
        let unchangedSources = try sourceContents()
        let routeScanner = LibraryScanner()
        func scanRoutes(_ runtimes: [Runtime], generation: UInt64) -> LibraryScanSnapshot {
            routeScanner.scanSynchronously(LibraryScanRequest(generation: generation, requestedAccountID: account, home: routeHome, runtimes: runtimes, readSavedSnapshot: { _ in nil }))
        }
        func routeSignature(_ snapshot: LibraryScanSnapshot) -> [String] {
            snapshot.steamGames.map { [$0.id, $0.platform, $0.runtimeId, $0.runtimeName, $0.path?.path ?? ""].joined(separator: "|") }.sorted()
        }
        let allRuntimes = [nativeRuntime, win11Runtime, win12Runtime]
        let localCold = scanRoutes(allRuntimes, generation: 1)
        let nativeRows = localCold.steamGames.filter { $0.appId == "1000" && $0.platform == "mac" }
        require(nativeRows.count == 1 && nativeRows[0].runtimeId == nativeRuntime.id && nativeRows[0].path?.path == nativeGamePath.path, "local Windows discovery preserves the distinct native Mac installation and path")
        require(localCold.steamGames.contains { $0.appId == "1000" && $0.runtimeId == win11Runtime.id && $0.path?.path == win11GamePath.path }, "distinct DX11 Steam installation retains its route and path")
        require(localCold.steamGames.contains { $0.appId == "1000" && $0.runtimeId == win12Runtime.id && $0.path?.path == win12GamePath.path }, "distinct DX12 Steam installation retains its route and path")
        let mixedLocalRows = localCold.steamGames.filter { $0.appId == "1000" && $0.installSource == "local" }
        require(mixedLocalRows.count == 2 && mixedLocalRows.allSatisfy { $0.platform == "windows" && $0.runtimeId == win11Runtime.id && $0.runtimeName == win11Runtime.name }, "local mixed-platform copies use Windows rather than inheriting Mac")
        require(Set(localCold.steamGames.map(\.id)).count == localCold.steamGames.count, "multiple local folders for one AppID have distinct stable identities")
        let dx12LocalRows = localCold.steamGames.filter { $0.appId == "1783560" && $0.installSource == "local" }
        require(dx12LocalRows.count == 1, "one local DX12 installation is represented")
        require(dx12LocalRows[0].platform == "windows" && dx12LocalRows[0].runtimeId == win12Runtime.id && dx12LocalRows[0].runtimeName == win12Runtime.name, "DX12-only local game skips the first DXMT runtime")
        require(dx12LocalRows[0].path?.resolvingSymlinksInPath().path == localDX12.resolvingSymlinksInPath().path, "DX12 local path preserved: actual \(dx12LocalRows[0].path?.path ?? "nil"), expected \(localDX12.path)")
        let localWarm = scanRoutes(allRuntimes, generation: 2)
        require(localWarm.metrics.filesParsed == 0 && localWarm.metrics.cacheHits > 0 && routeSignature(localWarm) == routeSignature(localCold), "warm cache preserves every route, label, path and identity")
        let missingDX12 = scanRoutes([nativeRuntime, win11Runtime], generation: 3)
        require(missingDX12.steamGames.contains { $0.appId == "1783560" && $0.runtimeId.isEmpty && $0.runtimeName == "Moteur Windows non configuré" }, "absent DX12 runtime cannot inherit DXMT or Mac")
        let unavailableDX12 = Runtime(id: win12Runtime.id, name: win12Runtime.name, platform: "windows", steamRoot: win12Steam, appURL: nil, wineURL: routeHome.appendingPathComponent("missing-runtime/bin/wine"), prefixURL: win12Prefix, verifiedIndependentEngine: true, renderer: "d3dmetal")
        require(!unavailableDX12.installationAvailable && !unavailableDX12.available, "unavailable fixture fails because its host executable is actually absent")
        let unavailable = scanRoutes([nativeRuntime, win11Runtime, unavailableDX12], generation: 4)
        require(unavailable.steamGames.contains { $0.appId == "1783560" && $0.runtimeId.isEmpty && $0.runtimeName == "Moteur Windows non configuré" }, "unavailable DX12 runtime is not represented as usable")
        let noWindows = scanRoutes([nativeRuntime], generation: 5)
        require(noWindows.steamGames.filter { $0.installSource == "local" }.allSatisfy { $0.runtimeId.isEmpty && $0.runtimeName == "Moteur Windows non configuré" }, "all local Windows routes stay unconfigured when only Mac is available")
        let sourcesAfterScan = try sourceContents()
        require(sourcesAfterScan == unchangedSources, "all scan passes leave fixture source files byte-identical")
        require(nativeRows[0].path?.path == nativeGamePath.path && routeSignature(localCold) == routeSignature(localWarm), "later scans do not mutate previous value snapshots")
        var routesClosed = false; routeScanner.shutdown { routesClosed = true }; pump { routesClosed }

        // A prepared capsule is a logical alias only for one exact official
        // destination. No source file is removed, moved or certified by a scan.
        let adoptionHome = scratch.appendingPathComponent("adoption-fixtures")
        let adoptionNativeSteam = adoptionHome.appendingPathComponent("Library/Application Support/Steam")
        let adoptionPrefix = adoptionHome.appendingPathComponent("WindowsPrefix")
        let adoptionSteam = adoptionPrefix.appendingPathComponent("drive_c/Steam")
        let adoptionTarget = adoptionSteam.appendingPathComponent("steamapps/common/Publisher Game")
        let adoptionManifest = adoptionSteam.appendingPathComponent("steamapps/appmanifest_1000.acf")
        let capsule = adoptionHome.appendingPathComponent("Library/Application Support/Playmelt/Games/Prepared")
        let capsuleReceipt = capsule.appendingPathComponent("playmelt-install.json")
        let capsuleLaunch = SteamDepotLaunchManifest.file(capsule)
        let adoptionNative = Runtime(id: "adoption-mac", name: "Native", platform: "mac", steamRoot: adoptionNativeSteam, appURL: app)
        let adoptionRuntime = Runtime(id: "adoption-win", name: "Windows", platform: "windows", steamRoot: adoptionSteam, appURL: nil, wineURL: fixtureWine, prefixURL: adoptionPrefix, verifiedIndependentEngine: true)
        try write(appinfo(name: "Alias"), adoptionNativeSteam.appendingPathComponent("appcache/appinfo.vdf"))
        try write(Data([0x4d,0x5a]), adoptionSteam.appendingPathComponent("steam.exe"))
        try write(Data([0x4d,0x5a]), adoptionTarget.appendingPathComponent("Game.exe"))
        try write(Data([0x4d,0x5a]), capsule.appendingPathComponent("Windows/Game.exe"))
        try text("1000\n", capsule.appendingPathComponent("steam_appid.txt"))
        let receiptDocument: [String: Any] = ["appID":"1000", "accountID":account, "source":"official-steam-console-completion",
            "officialInstallDirectory":"Publisher Game", "planSHA256":String(repeating:"a",count:64),
            "files":["Game.exe":2], "fileSHA256":["Game.exe":String(repeating:"b",count:64)]]
        let launchDocument: [String: Any] = ["schema":1, "appID":"1000", "source":"official-steam-console-completion", "renderer":"dxmt",
            "executable":"Game.exe", "arguments":[String](), "workingDirectory":"", "steamClientRequired":true]
        func writeJSON(_ value:[String:Any],_ path:URL)throws {try write(JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]),path)}
        try writeJSON(receiptDocument,capsuleReceipt);try writeJSON(launchDocument,capsuleLaunch)
        try text("\"users\" { \"\(account)\" { \"MostRecent\" \"1\" } }",adoptionSteam.appendingPathComponent("config/loginusers.vdf"))
        let fakeDescriptor = PlaymeltRuntimeDescriptor(engineID:"fixture",wineURL:fixtureWine,wineserverURL:fixtureWine,prefixURL:adoptionPrefix,
            steamRoot:adoptionSteam,environment:[:],readyEngine:true,steamInstalled:true)
        let explicitAccountManifest = SteamDepotLaunchManifest.read(capsule,appID:"1000")!
        require(explicitAccountManifest.officialClientIssue(accountID:account,descriptor:fakeDescriptor) == nil, "explicit fixture account validates its own client without a global selected-account preference")
        require(explicitAccountManifest.officialClientIssue(accountID:"",descriptor:fakeDescriptor) != nil, "missing explicit account never inherits a global account implicitly")
        let globalSelectionBefore = UserDefaults.standard.string(forKey:"selectedSteamAccount")
        let preflightGame = Game(id:"steam:1000:fixture",appId:"1000",title:"Explicit account",store:"steam",installed:true,platform:"windows",
            runtimeId:adoptionRuntime.id,runtimeName:adoptionRuntime.name,ownership:"installed-only",path:capsule,complete:true,installSource:"steam-depots")
        require(GameLaunchPreflight.inspect(preflightGame,steamAccountID:account,runtimeDescriptor:fakeDescriptor).issue == nil, "real preflight chain accepts the supplied account and isolated descriptor")
        require(GameLaunchPreflight.inspect(preflightGame,steamAccountID:"",runtimeDescriptor:fakeDescriptor).issue != nil &&
                GameLaunchPreflight.inspect(preflightGame,steamAccountID:other,runtimeDescriptor:fakeDescriptor).issue != nil, "real preflight chain refuses missing or different accounts")
        require(UserDefaults.standard.string(forKey:"selectedSteamAccount") == globalSelectionBefore, "preflight fixtures never mutate the global selected account")
        func officialManifest(_ path:URL,owner:String=account,flags:String="2",directory:String="Publisher Game")throws {
            try text("\"AppState\" { \"appid\" \"1000\" \"name\" \"Alias\" \"installdir\" \"\(directory)\" \"StateFlags\" \"\(flags)\" \"LastOwner\" \"\(owner)\" \"buildid\" \"\(flags == "4" ? "1":"0")\" }",path)
        }
        try officialManifest(adoptionManifest)
        let adoptionScanner = LibraryScanner()
        func adoptionScan(_ runtimes:[Runtime]?=nil,selected:String=account)->LibraryScanSnapshot {
            adoptionScanner.scanSynchronously(LibraryScanRequest(generation:1,requestedAccountID:selected,home:adoptionHome,
                runtimes:runtimes ?? [adoptionNative,adoptionRuntime],readSavedSnapshot:{_ in nil}))
        }
        func adoptionRows(_ snapshot:LibraryScanSnapshot)->[Game] {snapshot.steamGames.filter{$0.appId == "1000"}}
        let originalBytes = [capsuleReceipt,capsuleLaunch,capsule.appendingPathComponent("Windows/Game.exe"),capsule.appendingPathComponent("steam_appid.txt")].map {try! Data(contentsOf:$0)}
        let capsuleOnly = adoptionRows(adoptionScan([adoptionNative]))
        let capsuleID = capsuleOnly[0].id
        let grouped = adoptionRows(adoptionScan())
        require(grouped.count == 1 && grouped[0].id == capsuleID && grouped[0].path?.path == capsule.path, "exact official destination retains capsule identity and recovery path: \(grouped.map { [$0.id,$0.path?.path ?? "nil",$0.runtimeId].joined(separator:"|") })")
        require(!grouped[0].complete && grouped[0].runtimeId == adoptionRuntime.id, "StateFlags2 stays incomplete and uses the runtime reading the manifest despite mixed-platform metadata")
        let aliasWarm = adoptionScan()
        require(aliasWarm.metrics.filesParsed == 0 && adoptionRows(aliasWarm).map(\.id) == [capsuleID], "warm caches preserve the exact logical alias without reparsing")
        try officialManifest(adoptionManifest,flags:"4")
        let completedAlias = adoptionRows(adoptionScan())
        require(completedAlias.count == 1 && completedAlias[0].complete, "only observed official completion completes the grouped row")
        for owner in [other,"0",""] {
            try officialManifest(adoptionManifest,owner:owner)
            require(adoptionRows(adoptionScan()).count == 2, "another or unknown Steam owner cannot consume the capsule row")
        }
        try officialManifest(adoptionManifest)
        require(adoptionRows(adoptionScan(selected:other)).count == 2, "selection from another account refuses grouping")
        for patch in [["accountID":other],["source":"unknown"],["planSHA256":"invalid"],["officialInstallDirectory":"../escape"]] {
            try writeJSON(receiptDocument.merging(patch){_,new in new},capsuleReceipt)
            require(adoptionRows(adoptionScan()).count == 2, "invalid or mismatched prepared receipts remain separate")
        }
        try writeJSON(receiptDocument,capsuleReceipt)
        for renderer in ["auto","d3dmetal"] {
            try writeJSON(launchDocument.merging(["renderer":renderer]){_,new in new},capsuleLaunch)
            require(adoptionRows(adoptionScan()).count == 2, "unknown or different concrete renderer cannot group into the Windows route")
        }
        try writeJSON(launchDocument,capsuleLaunch)
        try write(Data([0x4d,0x5a]), adoptionSteam.appendingPathComponent("steamapps/common/Another Publisher Folder/Game.exe"))
        try officialManifest(adoptionManifest,directory:"Another Publisher Folder")
        require(adoptionRows(adoptionScan()).count == 2, "same app and account with another publisher directory remains distinct")
        try officialManifest(adoptionManifest)
        let realReceipt = adoptionHome.appendingPathComponent("original-receipt.json")
        try fm.moveItem(at:capsuleReceipt,to:realReceipt);try fm.createSymbolicLink(at:capsuleReceipt,withDestinationURL:realReceipt)
        require(adoptionRows(adoptionScan()).count == 2, "symlinked capsule receipt never proves an adoption")
        try fm.removeItem(at:capsuleReceipt);try fm.moveItem(at:realReceipt,to:capsuleReceipt)
        let linkedPrefix = adoptionHome.appendingPathComponent("LinkedPrefix")
        try fm.createSymbolicLink(at:linkedPrefix,withDestinationURL:adoptionPrefix)
        let linkedRuntime = Runtime(id:adoptionRuntime.id,name:adoptionRuntime.name,platform:"windows",steamRoot:adoptionSteam,appURL:nil,wineURL:fixtureWine,prefixURL:linkedPrefix,verifiedIndependentEngine:true)
        require(adoptionRows(adoptionScan([adoptionNative,linkedRuntime])).count == 2, "symlinked prefix cannot establish a canonical destination")
        let secondPrefix = adoptionHome.appendingPathComponent("SecondWindowsPrefix"),secondSteam = secondPrefix.appendingPathComponent("drive_c/Steam")
        try write(Data([0x4d,0x5a]),secondSteam.appendingPathComponent("steam.exe"))
        try write(Data([0x4d,0x5a]),secondSteam.appendingPathComponent("steamapps/common/Publisher Game/Game.exe"))
        try officialManifest(secondSteam.appendingPathComponent("steamapps/appmanifest_1000.acf"))
        let secondRuntime = Runtime(id:"second-adoption-win",name:"Second Windows",platform:"windows",steamRoot:secondSteam,appURL:nil,wineURL:fixtureWine,prefixURL:secondPrefix,verifiedIndependentEngine:true)
        require(adoptionRows(adoptionScan([adoptionNative,adoptionRuntime,secondRuntime])).count == 3, "two eligible Windows destinations are ambiguous and preserve every installation")
        let secondRenderer = Runtime(id:secondRuntime.id,name:secondRuntime.name,platform:"windows",steamRoot:secondSteam,appURL:nil,wineURL:fixtureWine,prefixURL:secondPrefix,verifiedIndependentEngine:true,renderer:"d3dmetal")
        let differentRoutes = adoptionRows(adoptionScan([adoptionNative,adoptionRuntime,secondRenderer]))
        require(differentRoutes.count == 2 && differentRoutes.contains{$0.path?.path == secondSteam.appendingPathComponent("steamapps/common/Publisher Game").path}, "a different renderer installation survives the exact matching route's grouping")
        let extraCapsule = capsule.deletingLastPathComponent().appendingPathComponent("OtherPrepared")
        try fm.copyItem(at:capsule,to:extraCapsule)
        require(adoptionRows(adoptionScan()).count == 3, "two eligible capsules for one official destination remain separate")
        try fm.moveItem(at:extraCapsule,to:adoptionHome.appendingPathComponent("SavedOtherPrepared"))
        try fm.removeItem(at:adoptionManifest)
        let removedAlias = adoptionRows(adoptionScan())
        require(removedAlias.count == 1 && removedAlias[0].id == capsuleID && removedAlias[0].path?.path == capsule.path && removedAlias[0].complete, "removing the official manifest restores the unchanged prepared source")
        try officialManifest(adoptionManifest)
        require(adoptionRows(adoptionScan()).count == 1, "reappearing exact manifest restores grouping without a new identity")
        let finalOriginalBytes = [capsuleReceipt,capsuleLaunch,capsule.appendingPathComponent("Windows/Game.exe"),capsule.appendingPathComponent("steam_appid.txt")].map {try! Data(contentsOf:$0)}
        require(originalBytes == finalOriginalBytes, "all grouping and negative scans preserve original payload and receipts byte for byte")
        var adoptionClosed=false;adoptionScanner.shutdown{adoptionClosed=true};pump{adoptionClosed}

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
        print("LibraryScan: \(checks) fixture checks passed; inert game files only, no game or client launched.")
    }
}
