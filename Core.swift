import Foundation
import AppKit
import Metal

enum ReadError: Error { case malformed, limit, unavailable }

// Bounded, read-only parsers. Steam configuration files contain more than the
// metadata needed here; credentials are never copied into our model or logs.
struct TextVDF {
    static func parse(_ text: String) throws -> [String: Any] {
        let chars = Array(text); var index = 0; var count = 0
        func token() throws -> String? {
            while index < chars.count {
                if chars[index].isWhitespace { index += 1; continue }
                if chars[index] == "/", index + 1 < chars.count, chars[index + 1] == "/" {
                    while index < chars.count && chars[index] != "\n" { index += 1 }; continue
                }; break
            }
            guard index < chars.count else { return nil }
            count += 1; guard count < 500_000 else { throw ReadError.limit }
            let c = chars[index]; index += 1
            if c == "{" || c == "}" { return String(c) }
            var result = ""
            if c == "\"" {
                while index < chars.count {
                    let x = chars[index]; index += 1
                    if x == "\"" { return result }
                    if x == "\\", index < chars.count {
                        let next = chars[index]; index += 1
                        if next == "\\" || next == "\"" { result.append(next) }
                        else { result.append("\\"); result.append(next) }
                    } else { result.append(x) }
                }; throw ReadError.malformed
            }
            result.append(c)
            while index < chars.count && !chars[index].isWhitespace && chars[index] != "{" && chars[index] != "}" { result.append(chars[index]); index += 1 }
            return result
        }
        func object(_ depth: Int, nested: Bool) throws -> [String: Any] {
            guard depth < 48 else { throw ReadError.limit }; var output: [String: Any] = [:]
            while let key = try token() {
                if key == "}" { if nested { return output }; throw ReadError.malformed }
                guard key != "{", let value = try token(), value != "}" else { throw ReadError.malformed }
                output[key] = value == "{" ? try object(depth + 1, nested: true) : value
            }
            if nested { throw ReadError.malformed }; return output
        }
        return try object(0, nested: false)
    }
    static func read(_ url: URL) -> [String: Any] {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 10_000_000,
              let s = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return (try? parse(s)) ?? [:]
    }
}

extension Dictionary where Key == String, Value == Any {
    func value(_ key: String) -> Any? { first { $0.key.lowercased() == key.lowercased() }?.value }
    func object(_ key: String) -> [String: Any] { value(key) as? [String: Any] ?? [:] }
    func string(_ key: String) -> String { value(key) as? String ?? "" }
}

func activeSteamAccount(_ users: [String: Any]) -> String? {
    let entries = users.filter { LibraryModel.validAccountID($0.key) }.sorted { $0.key < $1.key }
    return entries.first { ($0.value as? [String: Any])?.string("MostRecent") == "1" }?.key
        ?? entries.first { ($0.value as? [String: Any])?.string("AutoLogin") == "1" }?.key
}

struct SteamAppInfo {
    let name: String
    let platforms: Set<String>
    let type: String
    var portraitAssets: [String] = []
    var landscapeAssets: [String] = []
    static func validArtworkPath(_ path: String) -> Bool {
        guard path.count < 200, !path.contains("%"), !path.contains("\\") else { return false }
        let pattern = "^(?:[a-fA-F0-9]{40}/)?(?:library_capsule|library_600x900|library_header|header|library_hero)(?:_[A-Za-z0-9_-]+)?\\.(?:jpg|jpeg|png|webp)$"
        return path.range(of: pattern, options: .regularExpression) != nil
    }
    static func artworkPaths(_ common: [String: Any], portrait: Bool) -> [String] {
        let assets = common.object("library_assets_full")
        let kinds = portrait ? ["library_capsule", "library_header", "library_hero"] : ["library_header", "library_hero", "library_capsule"]
        func localized(_ object: [String: Any]) -> [String] {
            let keys = ["french", "english"] + object.keys.filter { !["french", "english"].contains($0) }.sorted()
            return keys.compactMap { object[$0] as? String }.filter(validArtworkPath)
        }
        var paths: [String] = []
        for kind in kinds {
            for size in ["image", "image2x"] { paths += localized(assets.object(kind).object(size)) }
        }
        paths += localized(common.object("header_image"))
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }
    static func artworkURL(appID: String, path: String) -> String? {
        guard LibraryModel.validAppID(appID), validArtworkPath(path) else { return nil }
        return "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/\(appID)/\(path)"
    }
    static func load(_ url: URL) -> [String: SteamAppInfo] {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size < 64_000_000,
              let handle = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64_000_000), data.count < 64_000_000 else { return [:] }
        let bytes = [UInt8](data)
        func integer(_ at: Int, _ length: Int) throws -> UInt64 {
            guard at >= 0, at + length <= bytes.count else { throw ReadError.malformed }
            return (0..<length).reduce(0) { $0 | UInt64(bytes[at + $1]) << ($1 * 8) }
        }
        func cstring(_ pos: inout Int, end: Int) throws -> String {
            let start = pos
            while pos < end && bytes[pos] != 0 { pos += 1 }
            guard pos < end else { throw ReadError.malformed }
            let result = String(decoding: bytes[start..<pos], as: UTF8.self); pos += 1; return result
        }
        do {
            let magic = try integer(0, 4)
            guard [0x07564427, 0x07564428, 0x07564429].contains(magic) else { return [:] }
            var strings: [String] = []; var end = bytes.count; var position = 8
            if magic == 0x07564429 {
                end = Int(try integer(8, 8)); guard end >= 16 && end < bytes.count else { return [:] }
                var cursor = end; let count = Int(try integer(cursor, 4)); cursor += 4
                guard count < 100_000 else { return [:] }
                for _ in 0..<count { strings.append(try cstring(&cursor, end: bytes.count)) }; position = 16
            }
            func readObject(_ cursor: inout Int, _ limit: Int, _ depth: Int) throws -> [String: Any] {
                guard depth < 48 else { throw ReadError.limit }; var object: [String: Any] = [:]
                while cursor < limit {
                    let kind = bytes[cursor]; cursor += 1
                    if kind == 8 { return object }
                    let key: String
                    if magic == 0x07564429 {
                        let id = Int(try integer(cursor, 4)); cursor += 4
                        guard id < strings.count else { throw ReadError.malformed }; key = strings[id]
                    } else { key = try cstring(&cursor, end: limit) }
                    switch kind {
                    case 0: object[key] = try readObject(&cursor, limit, depth + 1)
                    case 1: object[key] = try cstring(&cursor, end: limit)
                    case 2, 3, 4, 6:
                        guard cursor + 4 <= limit else { throw ReadError.malformed }
                        object[key] = String(try integer(cursor, 4)); cursor += 4
                    case 7, 10:
                        guard cursor + 8 <= limit else { throw ReadError.malformed }
                        object[key] = String(try integer(cursor, 8)); cursor += 8
                    default: throw ReadError.malformed
                    }
                }; throw ReadError.malformed
            }
            var result: [String: SteamAppInfo] = [:]
            while position + 8 <= end {
                let id = try integer(position, 4); if id == 0 { break }
                let size = Int(try integer(position + 4, 4)); let next = position + 8 + size
                guard size >= 40 && next <= end && next > position else { break }
                var body = position + (magic >= 0x07564428 ? 68 : 48)
                // Record prefix: appID,size,state,lastUpdated,accessToken,sha1,
                // changeNumber, then (v28+) binary-data SHA1.
                if let root = try? readObject(&body, next, 0) {
                    let common = root.object("appinfo").object("common")
                    let name = common.string("name")
                    if !name.isEmpty {
                        result[String(id)] = SteamAppInfo(name: name, platforms: Set(common.string("oslist").split(separator: ",").map(String.init)), type: common.string("type").lowercased(), portraitAssets: artworkPaths(common, portrait: true), landscapeAssets: artworkPaths(common, portrait: false))
                    }
                }
                position = next
            }
            return result
        } catch { return [:] }
    }
}

struct Runtime {
    let id: String, name: String, platform: String
    let steamRoot: URL, appURL: URL?
    var wineURL: URL? = nil
    var prefixURL: URL? = nil
    var environment: [String: String] = [:]
    var verifiedIndependentEngine = false
    var available: Bool {
        if let appURL { return FileManager.default.fileExists(atPath: appURL.path) }
        return platform == "windows" && verifiedIndependentEngine && wineURL.map { FileManager.default.isExecutableFile(atPath: $0.path) } == true && FileManager.default.fileExists(atPath: steamRoot.appendingPathComponent("steam.exe").path)
    }
    var json: [String: Any] { ["id": id, "name": name, "platform": platform, "available": available] }
}
struct Account {
    let id: String, name: String, source: String, recent: Bool
    var shortID: String? { guard let value = UInt64(id), value >= 76561197960265728 else { return nil }; return String(value - 76561197960265728) }
}
struct Game {
    var id: String, appId: String, title: String, store: String, installed: Bool, platform: String, runtimeId: String, runtimeName: String, ownership: String
    var path: URL?, complete: Bool = false, epicLaunchID: String = ""
    var supportedPlatforms: [String] = []
    var customImageURL = ""
    var customPortraitURL = ""
    func json(runtimes: [Runtime]) -> [String: Any] {
        let available = runtimes.contains { $0.id == runtimeId && $0.available }
        let launchSupported = store != "steam" || SteamGameLaunchProfile.blockReason(appID: appId, platform: platform) == nil
        return ["id": id, "appId": appId, "title": title, "store": store, "installed": installed,
                "platform": platform, "runtimeId": runtimeId, "runtimeName": runtimeName, "ownership": ownership,
                "platforms": supportedPlatforms.isEmpty ? (platform == "unknown" ? [] : [platform]) : supportedPlatforms,
                "imageURL": !customImageURL.isEmpty ? customImageURL : store == "steam" ? "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/\(appId)/header.jpg" : "",
                "localImageURL": store == "steam" ? "metalmaxart://steam/\(appId)" : "",
                "portraitImageURL": !customPortraitURL.isEmpty ? customPortraitURL : store == "steam" ? "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/\(appId)/library_600x900.jpg" : "",
                "localPortraitURL": store == "steam" ? "metalmaxart://steam/\(appId)/portrait" : "",
                "canLaunch": installed && complete && launchSupported && (store == "epic" ? FileManager.default.fileExists(atPath: "/Applications/Epic Games Launcher.app") : available),
                "canInstall": store == "steam" && !complete && platform != "unknown" && available,
                "canInstallAndPlay": store == "steam" && !complete && platform != "unknown" && available && launchSupported,
                "installComplete": complete]
    }
}

enum SteamGameLaunchProfile {
    static func blockReason(appID: String, platform: String) -> String? {
        // Mortal Shell II's official Steam requirements specify DirectX 12.
        // The current Playmelt renderer is DXMT (DirectX 10/11), not a DX12 backend.
        platform == "windows" && appID == "2584270" ? "Ce jeu nécessite DirectX 12. Le moteur actuel prend en charge DirectX 10 et 11." : nil
    }
    static func windowsArguments(appID: String) -> [String]? {
        guard LibraryModel.validAppID(appID), blockReason(appID: appID, platform: "windows") == nil else { return nil }
        return ["-applaunch", appID] + (appID == "526870" ? ["-dx11"] : [])
    }
}

/// Coalesces duplicate UI clicks without a polling timer. A pending request stays
/// locked until its actual dispatch callback; stale callbacks cannot unlock a retry.
final class SteamRequestGate {
    private struct Entry { let token: UUID; let started: TimeInterval; var pending: Bool }
    private var entries: [String: Entry] = [:]
    private var closed = false
    private let clock: () -> TimeInterval
    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { self.clock = clock }
    func acquire(_ key: String) -> UUID? {
        guard !closed else { return nil }
        let now = clock()
        entries = entries.filter { $0.value.pending || now - $0.value.started < 2 }
        guard entries[key] == nil else { return nil }
        let token = UUID(); entries[key] = Entry(token: token, started: now, pending: true); return token
    }
    func finish(_ key: String, token: UUID) {
        guard entries[key]?.token == token else { return }
        entries[key]?.pending = false
    }
    func shutdown() { closed = true; entries.removeAll() }
}

func steamInstallationPath(apps: URL, directory: String) -> URL? {
    guard !directory.isEmpty, directory != ".", directory != "..", !directory.contains("/"), !directory.contains("\\") else { return nil }
    let base = apps.resolvingSymlinksInPath()
    let common = base.appendingPathComponent("common").resolvingSymlinksInPath()
    let path = common.appendingPathComponent(directory).resolvingSymlinksInPath()
    guard common.path.hasPrefix(base.path + "/"), path.path.hasPrefix(common.path + "/") else { return nil }
    return path
}

func containsLaunchBinary(_ root: URL, platform: String) -> Bool {
    guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey], options: [.skipsHiddenFiles]) else { return false }
    var count = 0
    while let file = walker.nextObject() as? URL {
        count += 1; if count > 1500 { break }
        if walker.level > 6 { walker.skipDescendants(); continue }
        if platform == "windows", file.pathExtension.lowercased() == "exe",
           (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
           let handle = try? FileHandle(forReadingFrom: file) {
            let prefix = try? handle.read(upToCount: 2); try? handle.close()
            if prefix == Data([0x4d, 0x5a]) { return true }
        }
        if platform == "mac", !["dylib", "so", "bundle", "dll", "exe"].contains(file.pathExtension.lowercased()),
           (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
           FileManager.default.isExecutableFile(atPath: file.path), let handle = try? FileHandle(forReadingFrom: file) {
            let prefix = try? handle.read(upToCount: 4); try? handle.close()
            if let prefix, [Data([0xcf,0xfa,0xed,0xfe]), Data([0xce,0xfa,0xed,0xfe]), Data([0xca,0xfe,0xba,0xbe]), Data([0xbe,0xba,0xfe,0xca])].contains(prefix) { return true }
        }
    }
    return false
}

final class LibraryModel {
    let home: URL
    var runtimes: [Runtime] = [], accounts: [Account] = [], games: [Game] = []
    var selectedAccountID = "", libraryStatus = "local", libraryMessage = "", lastSync = ""
    var warnings: [String] = []
    var metadata: [String: SteamAppInfo] = [:]
    var authenticatedGames: [String: [[String: Any]]] = [:]
    var authenticatedDates: [String: String] = [:]
    var liveAuthenticatedAccounts = Set<String>()
    var epicSnapshot: EpicSnapshot?
    var epicSnapshotFresh = false
    var epicAvailability: [String: Any] = [:]
    var windowsDescriptor: PlaymeltRuntimeDescriptor?
    let preferences: UserDefaults
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, preferences: UserDefaults = .standard) {
        self.home = home; self.preferences = preferences
        selectedAccountID = preferences.string(forKey: "selectedSteamAccount") ?? ""
    }
    static func validAppID(_ id: String) -> Bool { !id.isEmpty && id.count <= 10 && id.allSatisfy(\.isNumber) && UInt32(id) != nil && UInt32(id) != 0 }
    static func validAccountID(_ id: String) -> Bool { id.count == 17 && id.allSatisfy(\.isNumber) && UInt64(id) != nil }
    func discoverRuntimes() -> [Runtime] {
        let fm = FileManager.default
        let nativeRoot = home.appendingPathComponent("Library/Application Support/Steam")
        let app = [URL(fileURLWithPath: "/Applications/Steam.app"), home.appendingPathComponent("Applications/Steam.app"), nativeRoot.appendingPathComponent("Steam.AppBundle/Steam")].first { fm.fileExists(atPath: $0.appendingPathComponent("Contents/MacOS/steam_osx").path) }
        var runtimes = [Runtime(id: "steam-mac", name: "Steam · macOS", platform: "mac", steamRoot: nativeRoot, appURL: app)]
        if let engine = windowsDescriptor, engine.readyEngine && engine.steamInstalled {
            runtimes.append(Runtime(id: "playmelt-windows", name: "Playmelt · Windows", platform: "windows", steamRoot: engine.steamRoot, appURL: nil,
                                    wineURL: engine.wineURL, prefixURL: engine.prefixURL, environment: engine.environment, verifiedIndependentEngine: true))
        }
        return runtimes
    }
    func refresh() {
        runtimes = discoverRuntimes(); warnings = []; accounts = []; metadata = [:]
        for runtime in runtimes {
            let users = TextVDF.read(runtime.steamRoot.appendingPathComponent("config/loginusers.vdf")).object("users")
            for (id, value) in users where Self.validAccountID(id) {
                let v = value as? [String: Any] ?? [:]
                if !accounts.contains(where: { $0.id == id }) {
                    accounts.append(Account(id: id, name: v.string("PersonaName").isEmpty ? "Compte Steam" : v.string("PersonaName"), source: runtime.name, recent: v.string("MostRecent") == "1" || v.string("AutoLogin") == "1"))
                }
            }
            metadata.merge(SteamAppInfo.load(runtime.steamRoot.appendingPathComponent("appcache/appinfo.vdf"))) { first, _ in first }
        }
        accounts.sort { $0.recent != $1.recent ? $0.recent : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !accounts.contains(where: { $0.id == selectedAccountID }) { selectedAccountID = accounts.first?.id ?? "" }
        if authenticatedGames[selectedAccountID] == nil, Self.validAccountID(selectedAccountID),
           let data = preferences.data(forKey: "steamLibrarySnapshot." + selectedAccountID), data.count < 8_000_000,
           let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           saved["accountId"] as? String == selectedAccountID,
           let source = saved["source"] as? String, Self.steamLibrarySources.contains(source),
           let rows = saved["games"] as? [[String: Any]], !rows.isEmpty, rows.count < 20_000,
           rows.allSatisfy({ ($0["appid"] as? String).map(Self.validAppID) == true }),
           let date = saved["updatedAt"] as? String, ISO8601DateFormatter().date(from: date) != nil {
            authenticatedGames[selectedAccountID] = rows
            authenticatedDates[selectedAccountID] = date
        }
        var cachedIDs = Set<String>(); var playedIDs = Set<String>()
        if let short = accounts.first(where: { $0.id == selectedAccountID })?.shortID {
            for runtime in runtimes {
                let config = runtime.steamRoot.appendingPathComponent("userdata/\(short)/config")
                let local = TextVDF.read(config.appendingPathComponent("localconfig.vdf")).object("UserLocalConfigStore").object("Software").object("Valve").object("Steam").object("apps")
                for id in local.keys where Self.validAppID(id) && (UInt32(id) ?? 0) > 100 { playedIDs.insert(id) }
                let cache = config.appendingPathComponent("librarycache")
                for file in (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? [] {
                    let id = file.deletingPathExtension().lastPathComponent
                    if file.pathExtension == "json", Self.validAppID(id), metadata[id] != nil { cachedIDs.insert(id) }
                }
            }
        }
        cachedIDs.formUnion(playedIDs)
        games = []
        for runtime in runtimes {
            for root in libraryRoots(runtime) {
                let apps = root.appendingPathComponent("steamapps")
                for manifest in ((try? FileManager.default.contentsOfDirectory(at: apps, includingPropertiesForKeys: nil)) ?? []).filter({ $0.lastPathComponent.hasPrefix("appmanifest_") && $0.pathExtension == "acf" }) {
                    let m = TextVDF.read(manifest).object("AppState"); let id = m.string("appid")
                    guard Self.validAppID(id), id != "228980" else { continue }
                    let kind = metadata[id]?.type ?? ""; if ["tool", "dlc", "music", "video", "config"].contains(kind) { continue }
                    let dir = m.string("installdir"); guard let path = steamInstallationPath(apps: apps, directory: dir) else { continue }
                    let exists = FileManager.default.fileExists(atPath: path.path)
                    let flags = UInt32(m.string("StateFlags")) ?? 0
                    let unfinished: UInt32 = 1 | 2 | 32 | 128 | 256 | 512 | 1024 | 2048 | 4096 | 65536 | 131072 | 262144 | 524288 | 1048576 | 2097152 | 4194304 | 8388608
                    let complete = flags & 4 == 4 && flags & unfinished == 0 && exists
                    var g = makeGame(id, ownership: cachedIDs.contains(id) ? "account-cache" : "installed-only")
                    g.id = "steam:\(id):\(runtime.id)"; g.title = m.string("name").isEmpty ? g.title : m.string("name")
                    let platformSupported = metadata[id]?.platforms.contains(runtime.platform == "mac" ? "macos" : "windows") == true
                    g.installed = exists; g.path = path; g.complete = complete && platformSupported && containsLaunchBinary(path, platform: runtime.platform)
                    g.platform = platformSupported ? runtime.platform : "unknown"; g.runtimeId = runtime.id; g.runtimeName = runtime.name
                    games.append(g)
                }
            }
        }
        for id in cachedIDs.sorted() where !games.contains(where: { $0.appId == id && $0.store == "steam" }) {
            guard let info = metadata[id], !["tool", "dlc", "music", "video", "config"].contains(info.type) else { continue }
            games.append(makeGame(id, ownership: "account-cache"))
        }
        if let verified = authenticatedGames[selectedAccountID] { mergeVerified(verified) }
        games.append(contentsOf: epicGames())
        if let snapshot = epicSnapshot { mergeEpic(snapshot) }
        games.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        if let verified = authenticatedGames[selectedAccountID] {
            let live = liveAuthenticatedAccounts.contains(selectedAccountID)
            libraryStatus = live ? "synced" : "snapshot"
            lastSync = authenticatedDates[selectedAccountID] ?? ""
            libraryMessage = live ? "Bibliothèque lue dans votre session Steam officielle (\(verified.count) jeux). Les installations et les performances restent vérifiées séparément." : "Dernière bibliothèque Steam vérifiée : \(verified.count) jeux. Copie locale datée, à synchroniser pour confirmer les droits actuels."
        } else if libraryStatus != "syncing" {
            libraryStatus = "local"
            lastSync = ""
            libraryMessage = selectedAccountID.isEmpty ? "Ouvrez Steam et connectez votre compte, puis actualisez." : "Compte repéré dans Steam. Historique local et installations détectés ; la propriété et l’exhaustivité restent à vérifier par connexion Steam."
        }
        if FileManager.default.fileExists(atPath: "/Applications/Highball.app") { warnings.append("Highball est installé. Aucune bibliothèque Steam Highball n’est reliée à Playmelt.") }
        warnings.append("Une entrée du cache local peut être un ancien jeu, une démo ou un jeu partagé. Steam contrôle les droits lors de l’installation.")
    }
    func makeGame(_ id: String, ownership: String) -> Game {
        let info = metadata[id]
        let platform = info?.platforms.contains("macos") == true ? "mac" : info?.platforms.contains("windows") == true ? "windows" : "unknown"
        let runtime = runtimes.first { $0.platform == platform && $0.available }
        var game = Game(id: "steam:\(id)", appId: id, title: info?.name ?? "Steam \(id)", store: "steam", installed: false, platform: platform, runtimeId: runtime?.id ?? "", runtimeName: runtime?.name ?? (platform == "windows" ? "Moteur Windows non configuré" : "Aucune route vérifiée"), ownership: ownership)
        game.supportedPlatforms = ["macos", "windows"].filter { info?.platforms.contains($0) == true }.map { $0 == "macos" ? "mac" : "windows" }
        if let path = info?.portraitAssets.first { game.customPortraitURL = SteamAppInfo.artworkURL(appID: id, path: path) ?? "" }
        if let path = info?.landscapeAssets.first { game.customImageURL = SteamAppInfo.artworkURL(appID: id, path: path) ?? "" }
        return game
    }
    func libraryRoots(_ runtime: Runtime) -> [URL] {
        var result = [runtime.steamRoot]
        let folders = TextVDF.read(runtime.steamRoot.appendingPathComponent("steamapps/libraryfolders.vdf")).object("libraryfolders")
        for value in folders.values {
            let path = (value as? [String: Any])?.string("path") ?? (value as? String ?? "")
            let resolved: URL?
            if runtime.platform == "mac", path.hasPrefix("/") { resolved = URL(fileURLWithPath: path) }
            else if runtime.platform == "windows", path.lowercased().hasPrefix("c:\\"), let prefix = runtime.prefixURL {
                let drive = prefix.appendingPathComponent("drive_c").resolvingSymlinksInPath()
                let candidate = drive.appendingPathComponent(String(path.dropFirst(3)).replacingOccurrences(of: "\\", with: "/")).standardizedFileURL.resolvingSymlinksInPath()
                resolved = candidate.path == drive.path || candidate.path.hasPrefix(drive.path + "/") ? candidate : nil
            } else { resolved = nil }
            if let resolved, FileManager.default.fileExists(atPath: resolved.path), !result.contains(resolved) { result.append(resolved) }
        }; return result
    }
    func epicGames() -> [Game] {
        let root = home.appendingPathComponent("Library/Application Support/Epic/EpicGamesLauncher/Data/Manifests")
        var result: [Game] = []; var seen = Set<String>()
        for file in ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []).filter({ $0.pathExtension == "item" }) {
            guard let data = try? Data(contentsOf: file), data.count < 2_000_000, let m = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let app = m.string("AppName"), namespace = m.string("CatalogNamespace"), item = m.string("CatalogItemId")
            guard !app.isEmpty, !seen.contains(app), namespace != "ue", !m.string("LaunchExecutable").isEmpty else { continue }
            seen.insert(app)
            let path = URL(fileURLWithPath: m.string("InstallLocation")); let exists = FileManager.default.fileExists(atPath: path.path)
            guard exists else { continue }
            let launchID = [namespace, item, app].joined(separator: ":")
            result.append(Game(id: "epic:" + app, appId: app, title: m.string("DisplayName"), store: "epic", installed: true, platform: "mac", runtimeId: "epic-mac", runtimeName: "Epic Games Launcher", ownership: "installed-only", path: path, complete: m.value("bIsIncompleteInstall") as? Bool != true, epicLaunchID: launchID))
        }; return result
    }
    func mergeVerified(_ list: [[String: Any]]) {
        let ids = Set(list.compactMap { ($0["appid"] as? String).flatMap { Self.validAppID($0) ? $0 : nil } })
        // A verified account list supersedes cached history. Local installations
        // remain visible without claiming that the selected account owns them.
        games.removeAll { $0.store == "steam" && !$0.installed && !ids.contains($0.appId) }
        for index in games.indices where games[index].store == "steam" {
            if ids.contains(games[index].appId) { games[index].ownership = "authenticated-library" }
            else if games[index].installed { games[index].ownership = "installed-only" }
        }
        for row in list {
            guard let id = row["appid"] as? String, Self.validAppID(id) else { continue }
            if !games.contains(where: { $0.appId == id && $0.store == "steam" }) {
                var g = makeGame(id, ownership: "authenticated-library")
                if let name = row["name"] as? String, !name.isEmpty { g.title = String(name.prefix(200)) }; games.append(g)
            }
        }
    }
    static let steamLibrarySources: Set<String> = ["steamcommunity-authenticated-all-games", "steamcommunity-profile-gameslist"]
    func beginSteamLibrarySync() {
        liveAuthenticatedAccounts.remove(selectedAccountID)
        if let cached = authenticatedGames[selectedAccountID] {
            libraryStatus = "snapshot"; lastSync = authenticatedDates[selectedAccountID] ?? ""
            libraryMessage = "Dernière bibliothèque Steam vérifiée : \(cached.count) jeux. Synchronisation en attente."
        } else {
            libraryStatus = "local"; lastSync = ""
            libraryMessage = "Connexion Steam en attente. Historique local disponible."
        }
    }
    func acceptAuthenticatedLibrary(accountID: String, list: [[String: Any]], source: String = "steamcommunity-authenticated-all-games") -> Bool {
        guard accountID == selectedAccountID, Self.validAccountID(accountID), Self.steamLibrarySources.contains(source), !list.isEmpty, list.count < 20000,
              list.allSatisfy({ ($0["appid"] as? String).map(Self.validAppID) == true && !($0["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(list.compactMap { $0["appid"] as? String }).count == list.count else { return false }
        let sanitized = list.map { ["appid": $0["appid"] as! String, "name": String(($0["name"] as? String ?? "").prefix(200))] }
        authenticatedGames[accountID] = sanitized; liveAuthenticatedAccounts.insert(accountID)
        libraryStatus = "synced"; lastSync = ISO8601DateFormatter().string(from: Date()); authenticatedDates[accountID] = lastSync
        if let data = try? JSONSerialization.data(withJSONObject: ["accountId": accountID, "games": sanitized, "source": source, "updatedAt": lastSync]) {
            preferences.set(data, forKey: "steamLibrarySnapshot." + accountID)
        }
        libraryMessage = "Bibliothèque lue dans votre session Steam officielle (\(list.count) jeux). Les installations et les performances restent vérifiées séparément."
        refresh(); return true
    }
    func mergeEpic(_ snapshot: EpicSnapshot) {
        for row in snapshot.games {
            guard let appName = row["appName"] as? String, !appName.isEmpty, appName.count <= 512,
                  let title = row["title"] as? String else { continue }
            let platforms = (row["platforms"] as? [String] ?? []).map { $0.lowercased() }.filter { ["mac", "windows"].contains($0) }
            if let index = games.firstIndex(where: { $0.store == "epic" && $0.appId == appName }) {
                games[index].ownership = "authenticated-library"; games[index].supportedPlatforms = platforms
                games[index].customImageURL = row["imageURL"] as? String ?? ""
            } else {
                var game = Game(id: "epic-owned:" + appName, appId: appName, title: String(title.prefix(200)), store: "epic", installed: false,
                                platform: platforms.contains("mac") ? "mac" : platforms.contains("windows") ? "windows" : "unknown",
                                runtimeId: "epic-mac", runtimeName: "Epic Games Launcher", ownership: "authenticated-library")
                game.supportedPlatforms = platforms; game.customImageURL = row["imageURL"] as? String ?? ""; games.append(game)
            }
        }
    }
    func state() -> [String: Any] {
        let hardware = hardwareState()
        let epicCount = games.filter { $0.store == "epic" && $0.installed }.count
        let epicPresent = FileManager.default.fileExists(atPath: "/Applications/Epic Games Launcher.app")
        var epic: [String: Any] = ["status": epicPresent ? "launcher-present" : "unavailable", "message": epicPresent ? "Lanceur officiel présent. \(epicCount) jeux installés détectés. Bibliothèque du compte Epic non synchronisée." : "Epic Games Launcher n’est pas installé.", "installedCount": epicCount]
        epic.merge(epicAvailability) { _, new in new }
        if let snapshot = epicSnapshot {
            let current = epicSnapshotFresh && epicAvailability["authenticated"] as? Bool == true
            epic["status"] = current ? "synced" : "snapshot"; epic["displayName"] = snapshot.displayName; epic["updatedAt"] = snapshot.updatedAt
            epic["message"] = current ? "\(snapshot.displayName) · \(snapshot.games.count) jeux dans la bibliothèque Epic." : "Dernière bibliothèque Epic de \(snapshot.displayName) : \(snapshot.games.count) jeux. Nouvelle connexion ou synchronisation à vérifier."
        }
        return ["version": "2.0.0", "accounts": accounts.map { ["id": $0.id, "name": $0.name, "source": $0.source, "selected": $0.id == selectedAccountID] as [String: Any] },
                "selectedAccountId": selectedAccountID, "libraryStatus": ["status": libraryStatus, "message": libraryMessage, "updatedAt": lastSync],
                "games": games.map { $0.json(runtimes: runtimes) }, "runtimes": runtimes.map(\.json), "hardware": hardware,
                "warnings": warnings, "epic": epic]
    }
}

func hardwareState() -> [String: Any] {
    func sysString(_ name: String) -> String {
        var size = 0; guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0, size < 1024 else { return "Indisponible" }
        var bytes = [CChar](repeating: 0, count: size); guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return "Indisponible" }; return String(cString: bytes)
    }
    let thermal: String
    switch ProcessInfo.processInfo.thermalState { case .nominal: thermal = "nominal"; case .fair: thermal = "fair"; case .serious: thermal = "serious"; case .critical: thermal = "critical"; @unknown default: thermal = "unknown" }
    var swap = xsw_usage(); var swapSize = MemoryLayout<xsw_usage>.size
    let hasSwap = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0
    var result: [String: Any] = ["chip": sysString("machdep.cpu.brand_string"), "memoryGB": ProcessInfo.processInfo.physicalMemory / 1_073_741_824,
                               "cpuCores": ProcessInfo.processInfo.processorCount, "gpuName": MTLCreateSystemDefaultDevice()?.name ?? "Indisponible",
                               "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled, "thermalState": thermal,
                               "performanceStatus": "Aucun benchmark lancé. Aucun réglage système ou bouteille modifié."]
    if hasSwap { result["swapUsedGB"] = Double(swap.xsu_used) / 1_073_741_824 }
    return result
}
