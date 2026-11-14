import Foundation
import Darwin
import CryptoKit
import CoreFoundation

struct LibraryScanRequest {
    let generation: UInt64
    let requestedAccountID: String
    let home: URL
    let runtimes: [Runtime]
    // Captures only the thread-safe UserDefaults store, never the UI/model.
    // Data returned from it is a value snapshot; authenticated state is merged on main.
    let readSavedSnapshot: (String) -> Data?
}

struct LibraryScanMetrics {
    var filesParsed = 0, cacheHits = 0, unstableFiles = 0, binaryScans = 0
    var elapsedMilliseconds = 0.0
}

struct SavedSteamLibrary {
    let accountID: String, updatedAt: String
    let games: [[String: String]]
}

struct LibraryScanSnapshot {
    let generation: UInt64, requestedAccountID: String, selectedAccountID: String
    let runtimes: [Runtime], accounts: [Account], steamGames: [Game], epicInstalledGames: [Game]
    let metadata: [String: SteamAppInfo], runtimeAvailability: [String: Bool]
    let savedLibrary: SavedSteamLibrary?
    let metrics: LibraryScanMetrics
    var launchPreflights: [String: GameLaunchPreflight] = [:]
}

private struct ScanFileIdentity: Equatable {
    let device: Int32, inode: UInt64, size: Int64, modifiedSeconds: Int, modifiedNanoseconds: Int, changedSeconds: Int, changedNanoseconds: Int
    static func read(_ url: URL) -> Self? {
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return Self(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                    modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec,
                    changedSeconds: info.st_ctimespec.tv_sec, changedNanoseconds: info.st_ctimespec.tv_nsec)
    }
}

/// Accessed only on the scanner's serial queue. Values contain selected metadata,
/// never the original login/localconfig objects or credentials.
private final class ScanFileCache<Value> {
    private struct Entry { let identity: ScanFileIdentity, value: Value; var used: UInt64 }
    private var entries: [String: Entry] = [:]
    private var tick: UInt64 = 0
    private let maximumEntries: Int, maximumBytes: Int64
    init(entries: Int = 4096, bytes: Int64 = 16_000_000) { maximumEntries = entries; maximumBytes = bytes }
    func read(_ url: URL, metrics: inout LibraryScanMetrics, loader: () -> Value?) -> Value? {
        let key = url.standardizedFileURL.path
        guard let before = ScanFileIdentity.read(url) else { entries.removeValue(forKey: key); return nil }
        tick &+= 1
        if var entry = entries[key], entry.identity == before {
            entry.used = tick; entries[key] = entry; metrics.cacheHits += 1; return entry.value
        }
        entries.removeValue(forKey: key); metrics.filesParsed += 1
        guard let value = loader() else { return nil }
        guard ScanFileIdentity.read(url) == before else { metrics.unstableFiles += 1; return nil }
        if before.size <= maximumBytes {
            entries[key] = Entry(identity: before, value: value, used: tick)
            var bytes = entries.values.reduce(Int64(0)) { $0 + $1.identity.size }
            while entries.count > maximumEntries || bytes > maximumBytes {
                guard let oldest = entries.min(by: { $0.value.used < $1.value.used }) else { break }
                bytes -= oldest.value.identity.size; entries.removeValue(forKey: oldest.key)
            }
        }
        return value
    }
}

private struct ScannedManifest { let appID: String, name: String, directory: String, flags: UInt32, owner: String }

private func canonicalScanDirectory(_ url: URL) -> Bool {
    url.isFileURL && url.path == url.standardizedFileURL.path && url.resolvingSymlinksInPath().path == url.path &&
    (try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map { $0.isDirectory == true && $0.isSymbolicLink != true } == true
}

/// Selected metadata only. This proves a logical destination, never that Steam
/// validated the payload or that equal-sized files have identical contents.
private struct PreparedCapsuleReceipt {
    let appID: String, accountID: String, directory: String
    static func read(_ url: URL) -> Self? {
        guard canonicalScanDirectory(url.deletingLastPathComponent()), url.resolvingSymlinksInPath().path == url.path,
              let identity = ScanFileIdentity.read(url), identity.size > 0, identity.size <= 16_000_000,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16_000_001), data.count <= 16_000_000,
              let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              raw["source"] as? String == "official-steam-console-completion",
              let appID = raw["appID"] as? String, LibraryModel.validAppID(appID),
              let account = raw["accountID"] as? String, LibraryModel.validAccountID(account),
              let plan = raw["planSHA256"] as? String, plan.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              let files = raw["files"] as? [String: Any], !files.isEmpty,
              files.count <= 200_000, files.values.allSatisfy({ value in
                  guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return false }
                  return n.doubleValue.isFinite && n.doubleValue >= 0 && n.doubleValue.rounded() == n.doubleValue
              }),
              let hashes = raw["fileSHA256"] as? [String: String], Set(files.keys) == Set(hashes.keys),
              hashes.values.allSatisfy({ $0.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }),
              let directory = raw["officialInstallDirectory"] as? String, !directory.isEmpty, directory.count <= 160,
              directory == directory.trimmingCharacters(in: .whitespacesAndNewlines), ![".",".."].contains(directory),
              !directory.contains(where: { "/\\:".contains($0) }), !directory.unicodeScalars.contains(where: { $0.value < 32 }) else { return nil }
        return .init(appID: appID, accountID: account, directory: directory)
    }
}

private struct OfficialCapsuleDestination {
    let gameID: String, appID: String, owner: String, directory: String
    let runtime: Runtime, target: URL, manifest: URL, identity: ScanFileIdentity
}

/// One scan in flight and one replaceable pending request. No timers or processes.
final class LibraryScanner {
    private let queue = DispatchQueue(label: "Playmelt.library.scan", qos: .utility)
    private let lock = NSLock()
    private var pending: (LibraryScanRequest, (LibraryScanSnapshot) -> Void, UUID)?
    private var latest = UUID(), running = false, closed = false
    private var shutdownCallbacks: [() -> Void] = []
    private let appInfo = ScanFileCache<[String: SteamAppInfo]>(entries: 4, bytes: 96_000_000)
    private let users = ScanFileCache<[Account]>(entries: 16)
    private let played = ScanFileCache<Set<String>>(entries: 64)
    private let folders = ScanFileCache<[String]>(entries: 16)
    private let manifests = ScanFileCache<ScannedManifest>()
    private let preparedReceipts = ScanFileCache<PreparedCapsuleReceipt>(entries: 256)
    private let epicManifests = ScanFileCache<Game>(entries: 4096)

    func scan(_ request: LibraryScanRequest, completion: @escaping (LibraryScanSnapshot) -> Void) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        let token = UUID(); latest = token; pending = (request, completion, token)
        let start = !running; running = true; lock.unlock()
        if start { queue.async { self.drain() } }
    }
    func shutdown(completion: @escaping () -> Void = {}) {
        lock.lock(); closed = true; pending = nil; latest = UUID()
        if running { shutdownCallbacks.append(completion); lock.unlock() }
        else { lock.unlock(); DispatchQueue.main.async(execute: completion) }
    }
    /// CLI audit/tests only; the application uses scan(_:completion:).
    func scanSynchronously(_ request: LibraryScanRequest) -> LibraryScanSnapshot { queue.sync { perform(request) } }
    private var stopped: Bool { lock.lock(); defer { lock.unlock() }; return closed }
    private func drain() {
        while true {
            lock.lock()
            guard !closed, let job = pending else {
                pending = nil; running = false
                let callbacks = shutdownCallbacks; shutdownCallbacks = []; lock.unlock()
                for callback in callbacks { DispatchQueue.main.async(execute: callback) }; return
            }
            pending = nil; lock.unlock()
            let snapshot = perform(job.0)
            DispatchQueue.main.async {
                self.lock.lock(); let deliver = !self.closed && self.latest == job.2; self.lock.unlock()
                if deliver { job.1(snapshot) }
            }
        }
    }
    private func listing(_ root: URL) -> [URL] {
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return [] }
        var result: [URL] = []
        while let file = files.nextObject() as? URL, result.count < 20_000, !stopped { result.append(file) }
        return result.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    private func readVDF(_ url: URL) -> [String: Any]? {
        guard let identity = ScanFileIdentity.read(url), identity.size >= 0, identity.size < 10_000_000,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 10_000_000), data.count < 10_000_000,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return try? TextVDF.parse(text)
    }
    private func savedLibrary(_ data: Data?, account: String) -> SavedSteamLibrary? {
        guard let data, data.count < 8_000_000, LibraryModel.validAccountID(account),
              let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              saved["accountId"] as? String == account,
              let source = saved["source"] as? String, LibraryModel.steamLibrarySources.contains(source),
              let rows = saved["games"] as? [[String: String]], !rows.isEmpty, rows.count < 20_000,
              rows.allSatisfy({ ($0["appid"]).map(LibraryModel.validAppID) == true }),
              let date = saved["updatedAt"] as? String, ISO8601DateFormatter().date(from: date) != nil else { return nil }
        return SavedSteamLibrary(accountID: account, updatedAt: date,
                                 games: rows.map { ["appid": $0["appid"]!, "name": String(($0["name"] ?? "").prefix(200))] })
    }
    private func reconcilePreparedCapsules(_ games: inout [Game], destinations: [OfficialCapsuleDestination], account: String, metrics: inout LibraryScanMetrics) {
        guard LibraryModel.validAccountID(account), !destinations.isEmpty else { return }
        var pairs: [(cache: Int, officialIndex: Int, official: OfficialCapsuleDestination, receipt: URL, receiptIdentity: ScanFileIdentity, launch: URL, launchIdentity: ScanFileIdentity)] = []
        for (index, game) in games.enumerated() where !stopped && game.store == "steam" && game.installSource == "steam-depots" && game.complete {
            guard let capsule = game.path, canonicalScanDirectory(capsule), canonicalScanDirectory(capsule.appendingPathComponent("Windows")) else { continue }
            let receiptFile = capsule.appendingPathComponent("playmelt-install.json"), launchFile = SteamDepotLaunchManifest.file(capsule)
            guard let receiptIdentity = ScanFileIdentity.read(receiptFile), let launchIdentity = ScanFileIdentity.read(launchFile),
                  launchFile.resolvingSymlinksInPath().path == launchFile.path,
                  let receipt = preparedReceipts.read(receiptFile, metrics: &metrics, loader: { PreparedCapsuleReceipt.read(receiptFile) }),
                  receipt.appID == game.appId, receipt.accountID == account,
                  let launch = SteamDepotLaunchManifest.read(capsule, appID: game.appId), launch.requiresOfficialSteam,
                  ["dxmt","d3dmetal"].contains(launch.renderer) else { continue }
            for candidate in destinations where candidate.appID == receipt.appID && candidate.owner == account && candidate.directory == receipt.directory {
                // Earlier local discovery can remove special-case rows. Resolve
                // the exact manifest row now rather than retaining array offsets.
                let rows = games.indices.filter { games[$0].id == candidate.gameID && games[$0].path == candidate.target && games[$0].store == "steam" }
                guard rows.count == 1, let officialIndex = rows.first, officialIndex != index else { continue }
                let runtime = candidate.runtime
                guard runtime.platform == "windows", runtime.verifiedIndependentEngine, runtime.executionAllowed, runtime.installationAvailable,
                      runtime.renderer == launch.renderer, SteamGameLaunchProfile.supportsInstallation(appID: game.appId, runtime: runtime),
                      let prefix = runtime.prefixURL, canonicalScanDirectory(prefix), canonicalScanDirectory(runtime.steamRoot),
                      runtime.steamRoot.path.hasPrefix(prefix.appendingPathComponent("drive_c").path + "/") else { continue }
                let expected = runtime.steamRoot.appendingPathComponent("steamapps/common").appendingPathComponent(receipt.directory)
                // steam_reuse prepares this exact default library, never an
                // unrelated Windows library with the same publisher folder name.
                guard canonicalScanDirectory(expected), candidate.target.path == expected.path,
                      candidate.manifest.path == runtime.steamRoot.appendingPathComponent("steamapps/appmanifest_\(game.appId).acf").path,
                      candidate.manifest.resolvingSymlinksInPath().path == candidate.manifest.path,
                      ScanFileIdentity.read(candidate.manifest) == candidate.identity else { continue }
                pairs.append((index, officialIndex, candidate, receiptFile, receiptIdentity, launchFile, launchIdentity))
            }
        }
        let cacheCounts = Dictionary(grouping: pairs, by: { $0.cache }).mapValues(\.count)
        let officialCounts = Dictionary(grouping: pairs, by: { $0.officialIndex }).mapValues(\.count)
        guard !stopped else { return }
        var hidden = Set<Int>()
        for pair in pairs where cacheCounts[pair.cache] == 1 && officialCounts[pair.officialIndex] == 1 {
            guard ScanFileIdentity.read(pair.receipt) == pair.receiptIdentity, ScanFileIdentity.read(pair.launch) == pair.launchIdentity,
                  ScanFileIdentity.read(pair.official.manifest) == pair.official.identity else { continue }
            // Keep the capsule identity/path for an in-flight job or retry. Only
            // Steam's observed completion can complete the grouped presentation.
            let official = games[pair.officialIndex]
            games[pair.cache].complete = official.complete
            games[pair.cache].runtimeId = pair.official.runtime.id
            games[pair.cache].runtimeName = pair.official.runtime.name
            games[pair.cache].lastPlayed = max(games[pair.cache].lastPlayed, official.lastPlayed)
            hidden.insert(pair.officialIndex)
        }
        games = games.enumerated().filter { !hidden.contains($0.offset) }.map(\.element)
    }
    private func perform(_ request: LibraryScanRequest) -> LibraryScanSnapshot {
        let start = ProcessInfo.processInfo.systemUptime
        var metrics = LibraryScanMetrics(), accounts: [Account] = [], metadata: [String: SteamAppInfo] = [:]
        let availability = Dictionary(uniqueKeysWithValues: request.runtimes.map { ($0.id, $0.available) })
        func assignWindowsRuntime(to game: inout Game) {
            let publisherRenderer=game.path.flatMap{SteamDepotLaunchManifest.read($0,appID:game.appId)}?.renderer
            let runtime = request.runtimes.first {
                $0.platform == "windows" && $0.executionAllowed && $0.installationAvailable &&
                (publisherRenderer == nil || publisherRenderer == "auto" || publisherRenderer == $0.renderer) &&
                SteamGameLaunchProfile.supportsInstallation(appID: game.appId, runtime: $0)
            }
            game.runtimeId = runtime?.id ?? ""
            game.runtimeName = runtime?.name ?? "Moteur Windows non configuré"
        }
        for runtime in request.runtimes where !stopped {
            let login = runtime.steamRoot.appendingPathComponent("config/loginusers.vdf")
            let found = users.read(login, metrics: &metrics) {
                self.readVDF(login)?.object("users").compactMap { id, raw -> Account? in
                    guard LibraryModel.validAccountID(id), let v = raw as? [String: Any] else { return nil }
                    return Account(id: id, name: v.string("PersonaName").isEmpty ? "Compte Steam" : String(v.string("PersonaName").prefix(200)),
                                   source: runtime.name, recent: v.string("MostRecent") == "1" || v.string("AutoLogin") == "1")
                }
            } ?? []
            for account in found where !accounts.contains(where: { $0.id == account.id }) { accounts.append(account) }
            let info = runtime.steamRoot.appendingPathComponent("appcache/appinfo.vdf")
            metadata.merge(appInfo.read(info, metrics: &metrics) { SteamAppInfo.load(info) } ?? [:]) { first, _ in first }
        }
        accounts.sort { $0.recent != $1.recent ? $0.recent : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        // Keep an explicit choice if Steam is rewriting loginusers or the account
        // was authenticated through the web session. Missing local data is not logout.
        let selected = LibraryModel.validAccountID(request.requestedAccountID) ? request.requestedAccountID : accounts.first?.id ?? ""
        if !selected.isEmpty, !accounts.contains(where: { $0.id == selected }) {
            accounts.append(Account(id: selected, name: "Compte Steam", source: "Compte sélectionné", recent: false))
        }
        var cachedIDs = Set<String>()
        var lastPlayedTimes: [String: Int64] = [:]
        if let short = accounts.first(where: { $0.id == selected })?.shortID {
            for runtime in request.runtimes where !stopped {
                let config = runtime.steamRoot.appendingPathComponent("userdata/\(short)/config")
                let local = config.appendingPathComponent("localconfig.vdf")
                cachedIDs.formUnion(played.read(local, metrics: &metrics) {
                    guard let value = self.readVDF(local) else { return nil }
                    let apps = value.object("UserLocalConfigStore").object("Software").object("Valve").object("Steam").object("apps")
                    for (appKey, appVal) in apps {
                        if let dict = appVal as? [String: Any] {
                            if let lp = Int64(dict.string("LastPlayed")), lp > 0 {
                                lastPlayedTimes[appKey] = max(lastPlayedTimes[appKey] ?? 0, lp)
                            }
                            if let pt = Int64(dict.string("Playtime")), pt > 0 {
                                PlaytimeStore.shared.registerBaseline(key: appKey, totalSeconds: pt * 60)
                            }
                        }
                    }
                    return Set(apps.keys.filter { LibraryModel.validAppID($0) && (UInt32($0) ?? 0) > 100 })
                } ?? [])
                if let value = self.readVDF(local) {
                    let apps = value.object("UserLocalConfigStore").object("Software").object("Valve").object("Steam").object("apps")
                    for (appKey, appVal) in apps {
                        if let dict = appVal as? [String: Any] {
                            if let lp = Int64(dict.string("LastPlayed")), lp > 0 {
                                lastPlayedTimes[appKey] = max(lastPlayedTimes[appKey] ?? 0, lp)
                            }
                            if let pt = Int64(dict.string("Playtime")), pt > 0 {
                                PlaytimeStore.shared.registerBaseline(key: appKey, totalSeconds: pt * 60)
                            }
                        }
                    }
                }
                for file in listing(config.appendingPathComponent("librarycache")) where file.pathExtension == "json" {
                    let id = file.deletingPathExtension().lastPathComponent
                    if LibraryModel.validAppID(id), metadata[id] != nil { cachedIDs.insert(id) }
                }
            }
        }
        var games: [Game] = [], installedIDs = Set<String>()
        var officialDestinations: [OfficialCapsuleDestination] = []
        for runtime in request.runtimes where !stopped {
            let file = runtime.steamRoot.appendingPathComponent("steamapps/libraryfolders.vdf")
            let paths = folders.read(file, metrics: &metrics) {
                self.readVDF(file)?.object("libraryfolders").values.map { ($0 as? [String: Any])?.string("path") ?? ($0 as? String ?? "") }
            } ?? []
            for root in LibraryModel.libraryRoots(runtime, paths: paths) where !stopped {
                let apps = root.appendingPathComponent("steamapps")
                for file in listing(apps) where file.lastPathComponent.hasPrefix("appmanifest_") && file.pathExtension == "acf" && !stopped {
                    guard let manifestIdentity = ScanFileIdentity.read(file), let m = manifests.read(file, metrics: &metrics, loader: {
                        guard let v = self.readVDF(file)?.object("AppState"), LibraryModel.validAppID(v.string("appid")) else { return nil }
                        return ScannedManifest(appID: v.string("appid"), name: String(v.string("name").prefix(200)), directory: v.string("installdir"), flags: UInt32(v.string("StateFlags")) ?? 0, owner: v.string("LastOwner"))
                    }), ScanFileIdentity.read(file) == manifestIdentity,
                          m.appID != "228980", !["tool", "dlc", "music", "video", "config"].contains(metadata[m.appID]?.type ?? ""),
                          let path = steamInstallationPath(apps: apps, directory: m.directory) else { continue }
                    let exists = FileManager.default.fileExists(atPath: path.path)
                    let unfinished: UInt32 = 1 | 2 | 32 | 128 | 256 | 512 | 1024 | 2048 | 4096 | 65536 | 131072 | 262144 | 524288 | 1048576 | 2097152 | 4194304 | 8388608
                    if let v = self.readVDF(file)?.object("AppState"), let lp = Int64(v.string("LastPlayed")), lp > 0 {
                        lastPlayedTimes[m.appID] = max(lastPlayedTimes[m.appID] ?? 0, lp)
                    }
                    let playmeltGames = request.home.appendingPathComponent("Library/Application Support/Playmelt/Games").resolvingSymlinksInPath()
                    let isLocalPlaymelt = path.path.hasPrefix(playmeltGames.path + "/") || path.path == playmeltGames.path
                    let platformSupported = metadata[m.appID]?.platforms.contains(runtime.platform == "mac" ? "macos" : "windows") == true || isLocalPlaymelt
                    var game = LibraryModel.makeGame(m.appID, ownership: cachedIDs.contains(m.appID) ? "account-cache" : "installed-only", metadata: metadata, runtimes: request.runtimes, availability: availability)
                    game.id = "steam:\(m.appID):\(runtime.id)"; if !m.name.isEmpty { game.title = m.name }
                    game.installed = exists; game.path = path
                    game.lastPlayed = lastPlayedTimes[m.appID] ?? 0
                    if m.flags & 4 == 4 && m.flags & unfinished == 0 && exists {
                        metrics.binaryScans += 1
                        if platformSupported && containsLaunchBinary(path, platform: runtime.platform, cancelled: { self.stopped }) {
                            game.complete = true
                            game.platform = runtime.platform
                            game.runtimeId = runtime.id
                            game.runtimeName = runtime.name
                            if runtime.platform == "windows", !SteamGameLaunchProfile.supportsInstallation(appID: game.appId, runtime: runtime) {
                                assignWindowsRuntime(to: &game)
                            }
                        } else if containsLaunchBinary(path, platform: "windows", cancelled: { self.stopped }) || findLaunchScript(in: path) != nil || isLocalPlaymelt {
                            game.complete = true
                            game.platform = "windows"
                            assignWindowsRuntime(to: &game)
                        }
                    }
                    if isLocalPlaymelt {
                        game.platform = "windows"
                        assignWindowsRuntime(to: &game)
                    }
                    if game.platform == "unknown" && platformSupported { game.platform = runtime.platform }
                    // Bind to the runtime reading this manifest. An unfinished
                    // mixed-platform title can still have an inferred Mac route.
                    if runtime.platform == "windows" {
                        officialDestinations.append(.init(gameID: game.id, appID: m.appID, owner: m.owner, directory: m.directory,
                            runtime: runtime, target: path, manifest: file, identity: manifestIdentity))
                    }
                    games.append(game); installedIDs.insert(m.appID)
                }
            }
        }
        let playmeltGamesRoot = request.home.appendingPathComponent("Library/Application Support/Playmelt/Games")
        if FileManager.default.fileExists(atPath: playmeltGamesRoot.path) {
            for folder in listing(playmeltGamesRoot) where !stopped {
                guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                if let manifest=LocalGameManifest.read(folder) {
                    var game=Game(id:"local:"+manifest.id,appId:manifest.id,title:manifest.title,store:"local",installed:true,platform:"windows",runtimeId:"playmelt-windows",runtimeName:"Windows",ownership:"installed-only",path:folder,complete:true,installSource:"local")
                    assignWindowsRuntime(to:&game);games.append(game);continue
                }
                let appidFile = folder.appendingPathComponent("Windows/steam_appid.txt")
                let appidAlt = folder.appendingPathComponent("steam_appid.txt")
                let targetAppID: String? = {
                    // A publisher may ship its own marker in a shared depot.
                    // Keep that file unchanged; our receipt is bound to the
                    // selected app and its parent discovery marker instead.
                    let modern=FileManager.default.fileExists(atPath:SteamDepotLaunchManifest.file(folder).path)
                    for marker in modern ? [appidAlt]:[appidFile,appidAlt] {
                        if let data=try? Data(contentsOf:marker),let str=String(data:data,encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines),LibraryModel.validAppID(str) {return str}
                    }
                    return nil
                }()

                // Marvel's Spider-Man 2 is the unique local custom game
                if folder.lastPathComponent == "MarvelsSpiderMan2" || targetAppID == "2651280" {
                    let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
                    let hasBinary = localGameExecutable(appID: "2651280", files: files) != nil && containsLaunchBinary(folder, platform: "windows", cancelled: { self.stopped })
                    var spiderman = Game(
                        id: "local:2651280",
                        appId: "2651280",
                        title: "Marvel's Spider-Man 2",
                        store: "local",
                        installed: true,
                        platform: "windows",
                        runtimeId: "playmelt-d3dmetal",
                        runtimeName: "D3DMetal (DirectX 12)",
                        ownership: "installed-only",
                        path: folder,
                        complete: hasBinary,
                        epicLaunchID: "",
                        supportedPlatforms: ["windows"],
                        customImageURL: "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/2651280/header.jpg",
                        customPortraitURL: "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/2651280/library_600x900.jpg",
                        lastPlayed: lastPlayedTimes["2651280"] ?? 0,
                        installSource: "local"
                    )
                    assignWindowsRuntime(to: &spiderman)
                    games.removeAll { $0.appId == "2651280" }
                    games.append(spiderman)
                    installedIDs.insert("2651280")
                    continue
                }

                // Final Fantasy VII Rebirth is an Epic Games Store installation handled via legendaryInstalled
                if folder.lastPathComponent == "FINALFANTASYVIIREBIRTH" {
                    continue
                }

                guard let id = targetAppID else { continue }
                let hasBinary = containsLaunchBinary(folder, platform: "windows", cancelled: { self.stopped })
                let localPaths = Set([folder.resolvingSymlinksInPath().path, folder.appendingPathComponent("Windows").resolvingSymlinksInPath().path])
                let existingIdx = games.firstIndex {
                    $0.appId == id && ($0.platform == "windows" || $0.store == "steam") &&
                    $0.path.map { localPaths.contains($0.resolvingSymlinksInPath().path) } == true
                }
                var localGame = existingIdx.map { games[$0] } ?? LibraryModel.makeGame(id, ownership: cachedIDs.contains(id) ? "account-cache" : "installed-only", metadata: metadata, runtimes: request.runtimes, availability: availability)
                let localIdentity=SHA256.hash(data:Data(folder.resolvingSymlinksInPath().path.utf8)).map{String(format:"%02x",$0)}.joined()
                localGame.id = existingIdx.map { games[$0].id } ?? "steam:\(id):local:\(localIdentity)"
                localGame.installed = true
                localGame.complete = hasBinary
                localGame.store = "steam"
                localGame.installSource = SteamDepotLaunchManifest.read(folder,appID:id) != nil ? "steam-depots":"local"
                localGame.platform = "windows"
                localGame.path = folder
                localGame.lastPlayed = max(localGame.lastPlayed, lastPlayedTimes[id] ?? 0)
                assignWindowsRuntime(to: &localGame)
                if let existingIdx { games[existingIdx] = localGame } else { games.append(localGame) }
                installedIDs.insert(id)
            }
        }
        reconcilePreparedCapsules(&games, destinations: officialDestinations, account: selected, metrics: &metrics)
        for id in cachedIDs.sorted() where !installedIDs.contains(id) {
            guard let info = metadata[id], !["tool", "dlc", "music", "video", "config"].contains(info.type) else { continue }
            var g = LibraryModel.makeGame(id, ownership: "account-cache", metadata: metadata, runtimes: request.runtimes, availability: availability)
            g.lastPlayed = lastPlayedTimes[id] ?? 0
            games.append(g)
        }
        let epicRoot = request.home.appendingPathComponent("Library/Application Support/Epic/EpicGamesLauncher/Data/Manifests")
        var epic: [Game] = [], epicIDs = Set<String>()
        for file in listing(epicRoot) where file.pathExtension == "item" && !stopped {
            guard let game = epicManifests.read(file, metrics: &metrics, loader: { LibraryModel.readEpicManifest(file) }),
                  let path = game.path, FileManager.default.fileExists(atPath: path.path), epicIDs.insert(game.appId).inserted else { continue }
            epic.append(game)
        }
        // Epic games installed by Playmelt itself (Legendary): ~/.config/legendary/installed.json.
        // They stay in the Epic store and are routed to the Windows engine through their launch script.
        let epicCacheFile = request.home.appendingPathComponent("Library/Application Support/Playmelt/.epic_cache.json")
        var epicImageURLs: [String: String] = [:]
        if let data = try? Data(contentsOf: epicCacheFile),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let gameList = obj["games"] as? [[String: Any]] {
            for item in gameList {
                if let aName = item["appName"] as? String, let url = item["imageURL"] as? String, !url.isEmpty {
                    epicImageURLs[aName] = url
                }
            }
        }
        let legendaryInstalled = request.home.appendingPathComponent(".config/legendary/installed.json")
        if !stopped, let data = try? Data(contentsOf: legendaryInstalled), data.count < 8_000_000,
           let rows = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for (appName, raw) in rows {
                guard let row = raw as? [String: Any], !appName.isEmpty, appName.utf8.count <= 512,
                      let installPath = row["install_path"] as? String, installPath.hasPrefix("/"),
                      epicIDs.insert(appName).inserted else { continue }
                let path = URL(fileURLWithPath: installPath).resolvingSymlinksInPath()
                guard FileManager.default.fileExists(atPath: path.path) else { continue }
                let executable = row["executable"] as? String ?? ""
                let platform = (row["platform"] as? String ?? "Windows").lowercased() == "mac" ? "mac" : "windows"
                let hasExecutable = !executable.isEmpty && FileManager.default.fileExists(atPath: path.appendingPathComponent(executable.replacingOccurrences(of: "\\", with: "/")).path)
                let artUrl = epicImageURLs[appName] ?? ""
                var game = Game(id: "epic:" + appName, appId: appName,
                                title: String((row["title"] as? String ?? appName).prefix(200)), store: "epic",
                                installed: true, platform: platform, runtimeId: "", runtimeName: "",
                                ownership: "installed-only", path: path,
                                complete: hasExecutable && row["needs_verification"] as? Bool != true,
                                epicLaunchID: "", supportedPlatforms: [platform],
                                customImageURL: artUrl,
                                customPortraitURL: artUrl,
                                lastPlayed: 0, installSource: "epic")
                if platform == "windows" { assignWindowsRuntime(to: &game) }
                epic.append(game)
            }
        }
        let saved = stopped ? nil : savedLibrary(request.readSavedSnapshot(selected), account: selected)
        var preflights:[String:GameLaunchPreflight]=[:]
        for game in games+epic where !stopped {preflights[game.id]=GameLaunchPreflight.inspect(game,steamAccountID:selected)}
        metrics.elapsedMilliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
        return LibraryScanSnapshot(generation: request.generation, requestedAccountID: request.requestedAccountID, selectedAccountID: selected,
                                   runtimes: request.runtimes, accounts: accounts, steamGames: games, epicInstalledGames: epic,
                                   metadata: metadata, runtimeAvailability: availability, savedLibrary: saved, metrics: metrics,launchPreflights:preflights)
    }
}
