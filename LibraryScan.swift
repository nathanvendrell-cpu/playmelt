import Foundation
import Darwin

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

private struct ScannedManifest { let appID: String, name: String, directory: String, flags: UInt32 }

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
    private func perform(_ request: LibraryScanRequest) -> LibraryScanSnapshot {
        let start = ProcessInfo.processInfo.systemUptime
        var metrics = LibraryScanMetrics(), accounts: [Account] = [], metadata: [String: SteamAppInfo] = [:]
        let availability = Dictionary(uniqueKeysWithValues: request.runtimes.map { ($0.id, $0.available) })
        func assignWindowsRuntime(to game: inout Game) {
            let runtime = request.runtimes.first {
                $0.platform == "windows" && $0.executionAllowed && availability[$0.id] == true &&
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
                        if let dict = appVal as? [String: Any], let lp = Int64(dict.string("LastPlayed")), lp > 0 {
                            lastPlayedTimes[appKey] = max(lastPlayedTimes[appKey] ?? 0, lp)
                        }
                    }
                    return Set(apps.keys.filter { LibraryModel.validAppID($0) && (UInt32($0) ?? 0) > 100 })
                } ?? [])
                if let value = self.readVDF(local) {
                    let apps = value.object("UserLocalConfigStore").object("Software").object("Valve").object("Steam").object("apps")
                    for (appKey, appVal) in apps {
                        if let dict = appVal as? [String: Any], let lp = Int64(dict.string("LastPlayed")), lp > 0 {
                            lastPlayedTimes[appKey] = max(lastPlayedTimes[appKey] ?? 0, lp)
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
        for runtime in request.runtimes where !stopped {
            let file = runtime.steamRoot.appendingPathComponent("steamapps/libraryfolders.vdf")
            let paths = folders.read(file, metrics: &metrics) {
                self.readVDF(file)?.object("libraryfolders").values.map { ($0 as? [String: Any])?.string("path") ?? ($0 as? String ?? "") }
            } ?? []
            for root in LibraryModel.libraryRoots(runtime, paths: paths) where !stopped {
                let apps = root.appendingPathComponent("steamapps")
                for file in listing(apps) where file.lastPathComponent.hasPrefix("appmanifest_") && file.pathExtension == "acf" && !stopped {
                    guard let m = manifests.read(file, metrics: &metrics, loader: {
                        guard let v = self.readVDF(file)?.object("AppState"), LibraryModel.validAppID(v.string("appid")) else { return nil }
                        return ScannedManifest(appID: v.string("appid"), name: String(v.string("name").prefix(200)), directory: v.string("installdir"), flags: UInt32(v.string("StateFlags")) ?? 0)
                    }), m.appID != "228980", !["tool", "dlc", "music", "video", "config"].contains(metadata[m.appID]?.type ?? ""),
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
                    if isLocalPlaymelt { game.installSource = "local" }
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
                    games.append(game); installedIDs.insert(m.appID)
                }
            }
        }
        let playmeltGamesRoot = request.home.appendingPathComponent("Library/Application Support/Playmelt/Games")
        if FileManager.default.fileExists(atPath: playmeltGamesRoot.path) {
            for folder in listing(playmeltGamesRoot) where !stopped {
                guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                let appidFile = folder.appendingPathComponent("Windows/steam_appid.txt")
                let appidAlt = folder.appendingPathComponent("steam_appid.txt")
                let targetAppID: String? = {
                    if let data = try? Data(contentsOf: appidFile), let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), LibraryModel.validAppID(str) { return str }
                    if let data = try? Data(contentsOf: appidAlt), let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), LibraryModel.validAppID(str) { return str }
                    return nil
                }()
                guard let id = targetAppID else { continue }
                let script = findLaunchScript(in: folder)
                let hasBinary = containsLaunchBinary(folder, platform: "windows", cancelled: { self.stopped }) || script != nil
                let localPaths = Set([folder.resolvingSymlinksInPath().path, folder.appendingPathComponent("Windows").resolvingSymlinksInPath().path])
                let existingIdx = games.firstIndex {
                    $0.appId == id && $0.platform == "windows" &&
                    $0.path.map { localPaths.contains($0.resolvingSymlinksInPath().path) } == true
                }
                var localGame = existingIdx.map { games[$0] } ?? LibraryModel.makeGame(id, ownership: cachedIDs.contains(id) ? "account-cache" : "installed-only", metadata: metadata, runtimes: request.runtimes, availability: availability)
                localGame.id = existingIdx.map { games[$0].id } ?? "local:\(id):\(folder.lastPathComponent)"
                localGame.installed = true
                localGame.complete = hasBinary
                localGame.installSource = "local"
                localGame.platform = "windows"
                localGame.path = folder
                localGame.lastPlayed = max(localGame.lastPlayed, lastPlayedTimes[id] ?? 0)
                assignWindowsRuntime(to: &localGame)
                if let existingIdx { games[existingIdx] = localGame } else { games.append(localGame) }
                installedIDs.insert(id)
            }
        }
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
        let saved = stopped ? nil : savedLibrary(request.readSavedSnapshot(selected), account: selected)
        metrics.elapsedMilliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
        return LibraryScanSnapshot(generation: request.generation, requestedAccountID: request.requestedAccountID, selectedAccountID: selected,
                                   runtimes: request.runtimes, accounts: accounts, steamGames: games, epicInstalledGames: epic,
                                   metadata: metadata, runtimeAvailability: availability, savedLibrary: saved, metrics: metrics)
    }
}
