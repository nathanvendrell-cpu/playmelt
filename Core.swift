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

/// Wine + Metal is the production compatibility route. The separate PE loader
/// remains a research prototype and cannot be selected as a game fallback.
enum WindowsExecutionPolicy {
    static let mode = "wine-metal"
    static let message = "Cette route Windows nécessite le moteur Wine + Metal préparé."
    static let legacyActions: Set<String> = []
    static func permits(platform: String, hasWine: Bool = false) -> Bool { (platform == "mac" && !hasWine) || (platform == "windows" && hasWine) }
    static var json: [String: Any] {
        ["mode": mode, "wineAllowed": true, "nativeEngineAvailable": false,
         "message": message, "missingNativeComponents": ["game-compatible-pe-loader", "win32-api-runtime", "validated-dx12-device"],
         "gameExecutionVerified": false]
    }
}

struct Runtime {
    let id: String, name: String, platform: String
    let steamRoot: URL, appURL: URL?
    var wineURL: URL? = nil
    var prefixURL: URL? = nil
    var environment: [String: String] = [:]
    var verifiedIndependentEngine = false
    var renderer = "dxmt"
    var graphicsValidated = false
    var executionAllowed: Bool { WindowsExecutionPolicy.permits(platform: platform, hasWine: wineURL != nil) }
    var available: Bool {
        guard executionAllowed else { return false }
        if let appURL { return FileManager.default.fileExists(atPath: appURL.path) }
        return platform == "windows" && verifiedIndependentEngine && wineURL.map { FileManager.default.isExecutableFile(atPath: $0.path) } == true && FileManager.default.fileExists(atPath: steamRoot.appendingPathComponent("steam.exe").path)
    }
    var displayName: String { platform == "mac" ? "Mac natif" : renderer == "d3dmetal" ? "DirectX 12" : "DirectX 11" }
    var json: [String: Any] { ["id": id, "name": name, "displayName": displayName, "platform": platform, "available": available, "executionAllowed": executionAllowed, "renderer": renderer, "graphicsValidated": graphicsValidated] }
}
struct Account {
    let id: String, name: String, source: String, recent: Bool
    var shortID: String? { guard let value = UInt64(id), value >= 76561197960265728 else { return nil }; return String(value - 76561197960265728) }
}
final class PlaytimeStore {
    static let shared = PlaytimeStore()
    private let lock = NSLock()
    private let fileURL: URL
    private var data: [String: [String: Any]] = [:]

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let playmeltDir = appSupport.appendingPathComponent("Playmelt")
        try? FileManager.default.createDirectory(at: playmeltDir, withIntermediateDirectories: true)
        self.fileURL = playmeltDir.appendingPathComponent("playtime.json")
        load()
    }

    private func load() {
        guard let raw = try? Data(contentsOf: fileURL),
              let dict = (try? JSONSerialization.jsonObject(with: raw)) as? [String: [String: Any]] else { return }
        self.data = dict
    }

    private func saveLocked() {
        guard let raw = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted]) else { return }
        try? raw.write(to: fileURL, options: [.atomic])
    }

    func playtime(for key: String) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        if let entry = data[key] {
            if let sec = entry["totalSeconds"] as? Int64 { return sec }
            if let num = entry["totalSeconds"] as? NSNumber { return num.int64Value }
        }
        return 0
    }

    func addSession(key: String, seconds: Int64) {
        guard seconds > 0 else { return }
        lock.lock()
        var entry = data[key] ?? [:]
        let currentTotal = (entry["totalSeconds"] as? NSNumber)?.int64Value ?? (entry["totalSeconds"] as? Int64 ?? 0)
        let newTotal = currentTotal + seconds
        entry["totalSeconds"] = newTotal
        entry["lastSessionSeconds"] = seconds
        entry["lastPlayed"] = Int64(Date().timeIntervalSince1970)
        data[key] = entry
        saveLocked()
        lock.unlock()
    }

    func registerBaseline(key: String, totalSeconds: Int64) {
        guard totalSeconds > 0 else { return }
        lock.lock()
        var entry = data[key] ?? [:]
        let currentTotal = (entry["totalSeconds"] as? NSNumber)?.int64Value ?? (entry["totalSeconds"] as? Int64 ?? 0)
        if totalSeconds > currentTotal {
            entry["totalSeconds"] = totalSeconds
            entry["lastPlayed"] = max((entry["lastPlayed"] as? NSNumber)?.int64Value ?? 0, Int64(Date().timeIntervalSince1970))
            data[key] = entry
            saveLocked()
        }
        lock.unlock()
    }

    static func formatted(seconds: Int64) -> String {
        guard seconds > 0 else { return "Jamais joué" }
        if seconds < 60 {
            return "Moins d’une minute"
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes) min"
        }
        let hours = minutes / 60
        let remMinutes = minutes % 60
        if remMinutes == 0 {
            return "\(hours) h"
        }
        return "\(hours) h \(remMinutes) min"
    }
}

final class AchievementStore {
    static let shared = AchievementStore()
    private let lock = NSLock()
    private let cacheDir: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        self.cacheDir = appSupport.appendingPathComponent("Playmelt/Achievements")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    func cachedAchievements(for appID: String) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        let file = cacheDir.appendingPathComponent("\(appID).json")
        guard let data = try? Data(contentsOf: file),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return formatPayload(dict)
    }

    func saveAchievements(for appID: String, rawDict: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        let file = cacheDir.appendingPathComponent("\(appID).json")
        if let data = try? JSONSerialization.data(withJSONObject: rawDict, options: [.prettyPrinted]) {
            try? data.write(to: file, options: [.atomic])
        }
    }

    func formatPayload(_ dict: [String: Any]) -> [String: Any] {
        let total = dict["total_achievements"] as? Int ?? (dict["total_achievements"] as? NSNumber)?.intValue ?? 0
        let unlockedCount = dict["user_unlocked"] as? Int ?? (dict["user_unlocked"] as? NSNumber)?.intValue ?? 0
        let userXP = dict["user_xp"] as? Int ?? (dict["user_xp"] as? NSNumber)?.intValue ?? 0
        let totalXP = dict["total_product_xp"] as? Int ?? (dict["total_product_xp"] as? NSNumber)?.intValue ?? 1000
        let pct = total > 0 ? Int(Double(unlockedCount) / Double(total) * 100.0) : 0
        let completed = (dict["completed"] as? [[String: Any]]) ?? []
        let formattedCompleted = completed.map { item -> [String: Any] in
            return [
                "name": item["name"] as? String ?? "",
                "displayName": item["display_name"] as? String ?? "",
                "description": item["description"] as? String ?? "",
                "iconLink": item["icon_link"] as? String ?? "",
                "unlockDate": item["unlock_date"] as? String ?? "",
                "xp": item["xp"] as? Int ?? (item["xp"] as? NSNumber)?.intValue ?? 0,
                "tier": (item["tier"] as? [String: Any])?["name"] as? String ?? "bronze",
                "rarity": (item["rarity"] as? [String: Any])?["percent"] as? Double ?? 0.0
            ]
        }
        return [
            "total": total,
            "unlockedCount": unlockedCount,
            "percentage": pct,
            "userXP": userXP,
            "totalXP": totalXP,
            "completed": formattedCompleted
        ]
    }
}

struct Game {
    var id: String, appId: String, title: String, store: String, installed: Bool, platform: String, runtimeId: String, runtimeName: String, ownership: String
    var path: URL?, complete: Bool = false, epicLaunchID: String = ""
    var supportedPlatforms: [String] = []
    var customImageURL = ""
    var customPortraitURL = ""
    var lastPlayed: Int64 = 0
    var installSource: String = "steam"
    var playtime: Int64 {
        let key = appId.isEmpty ? id : appId
        let storeTime = PlaytimeStore.shared.playtime(for: key)
        let fallbackTime = key != id ? PlaytimeStore.shared.playtime(for: id) : 0
        return max(storeTime, fallbackTime)
    }
    func json(runtimes: [Runtime], availability: [String: Bool]? = nil, completedRuntimeIDs: Set<String>? = nil) -> [String: Any] {
        func usable(_ runtime: Runtime) -> Bool { runtime.executionAllowed && (availability?[runtime.id] ?? runtime.available) }
        let runtime = runtimes.first { $0.id == runtimeId && usable($0) }
        let available = runtime != nil
        let routeMatches = runtime.map { SteamGameLaunchProfile.supportsInstallation(appID: appId, runtime: $0) } ?? false
        let launchSupported = store != "steam" || (routeMatches && SteamGameLaunchProfile.blockReason(appID: appId, platform: platform, renderer: runtime?.renderer ?? "", graphicsValidated: runtime?.graphicsValidated ?? false) == nil)
        let platforms = supportedPlatforms.isEmpty ? (platform == "unknown" ? [] : [platform]) : supportedPlatforms
        let completedRoutes = completedRuntimeIDs ?? (complete ? [runtimeId] : [])
        let routes: [[String: Any]] = store == "steam" ? runtimes.filter {
            usable($0) && platforms.contains($0.platform) && SteamGameLaunchProfile.supportsInstallation(appID: appId, runtime: $0)
        }.map { candidate in
            let allowed = !completedRoutes.contains(candidate.id)
            let canPlay = SteamGameLaunchProfile.blockReason(appID: appId, platform: candidate.platform, renderer: candidate.renderer, graphicsValidated: candidate.graphicsValidated) == nil
            return ["runtimeId": candidate.id, "canInstall": allowed, "canInstallAndPlay": allowed && canPlay]
        } : []
        let directCanLaunch = installed && complete && (installSource == "local" || findLaunchScript(in: path) != nil)
        let standardCanLaunch = installed && complete && launchSupported && (store == "epic" ? WindowsExecutionPolicy.permits(platform: platform) && FileManager.default.fileExists(atPath: "/Applications/Epic Games Launcher.app") : available)
        let cloudCanLaunch = store == "xbox" && platform == "cloud"
        let canLaunch = directCanLaunch || standardCanLaunch || cloudCanLaunch
        let effectivePlaytime = playtime
        return ["id": id, "appId": appId, "title": title, "store": store, "installed": installed,
                "platform": platform, "runtimeId": runtimeId, "runtimeName": runtimeName, "ownership": ownership,
                "platforms": platforms, "installRoutes": routes,
                "requiredRenderer": store == "steam" ? SteamGameLaunchProfile.requiredRenderer(appID: appId) : "auto",
                "requiredGraphicsAPI": store == "steam" ? SteamGameLaunchProfile.requiredGraphicsAPI(appID: appId) : "unknown",
                "imageURL": !customImageURL.isEmpty ? customImageURL : store == "steam" ? "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/\(appId)/header.jpg" : "",
                "localImageURL": store == "steam" ? "metalmaxart://steam/\(appId)" : "",
                "portraitImageURL": !customPortraitURL.isEmpty ? customPortraitURL : store == "steam" ? "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/\(appId)/library_600x900.jpg" : "",
                "localPortraitURL": store == "steam" ? "metalmaxart://steam/\(appId)/portrait" : "",
                "canLaunch": canLaunch,
                "canInstall": store == "steam" && !complete && platform != "unknown" && available && routeMatches,
                "canInstallAndPlay": store == "steam" && !complete && platform != "unknown" && available && launchSupported,
                "installComplete": complete,
                "lastPlayed": lastPlayed > 0 ? lastPlayed : (effectivePlaytime > 0 ? Int64(Date().timeIntervalSince1970) : 0),
                "playtime": effectivePlaytime,
                "playtimeFormatted": PlaytimeStore.formatted(seconds: effectivePlaytime),
                "achievements": AchievementStore.shared.cachedAchievements(for: appId.isEmpty ? id : appId) ?? NSNull(),
                "installSource": installSource]
    }
}

enum SteamGameLaunchProfile {
    static func localRenderer(appID: String, unity: Bool, dx12Markers: Bool) -> String {
        let required = requiredRenderer(appID: appID)
        if required != "auto" { return required }
        return !unity && dx12Markers ? "d3dmetal" : "dxmt"
    }
    static func prefersNative(platform: String, supportedPlatforms: [String], requestedRuntime: String?) -> Bool {
        if let requestedRuntime { return requestedRuntime == "steam-mac" }
        return platform == "mac" || supportedPlatforms.contains("mac")
    }
    // The open beta has a distinct Steam app ID; it must retain the same DX12
    // requirement as the retail game instead of falling through to DX11.
    private static let directX12Games: Set<String> = ["1783560", "2584270", "4711740", "2651280"]
    static func requiredRenderer(appID: String) -> String {
        let lower = appID.lowercased()
        if directX12Games.contains(appID) || lower.contains("rebirth") || lower.contains("catnip") || lower.contains("spiderman") { return "d3dmetal" }
        return appID == "526870" ? "dxmt" : "auto"
    }
    static func requiredGraphicsAPI(appID: String) -> String {
        let lower = appID.lowercased()
        if directX12Games.contains(appID) || lower.contains("rebirth") || lower.contains("catnip") || lower.contains("spiderman") { return "DirectX12" }
        return appID == "526870" ? "DirectX11" : "unknown"
    }
    static func supportsInstallation(appID: String, runtime: Runtime) -> Bool {
        guard runtime.platform == "windows" else { return true }
        let required = requiredRenderer(appID: appID)
        return required == "auto" || runtime.renderer == required
    }
    static func blockReason(appID: String, platform: String, renderer: String = "dxmt", graphicsValidated: Bool = false) -> String? {
        guard platform == "windows" else { return nil }
        if requiredRenderer(appID: appID) == "d3dmetal", renderer != "d3dmetal" { return "Ce jeu nécessite le moteur DirectX 12 de Playmelt." }
        return renderer == "d3dmetal" && !graphicsValidated ? "DirectX 12 doit encore être validé avant le lancement de ce jeu." : nil
    }
    static func windowsArguments(appID: String, renderer: String = "dxmt", graphicsValidated: Bool = false) -> [String]? {
        guard LibraryModel.validAppID(appID), blockReason(appID: appID, platform: "windows", renderer: renderer, graphicsValidated: graphicsValidated) == nil else { return nil }
        return ["-applaunch", appID] + (appID == "526870" ? ["-dx11"] : [])
    }
}

/// A dry-run inventory for one detected installation. No title-based guesses,
/// parent folders, or unrelated Steam manifests are included.
struct GameUninstallPlan: Equatable {
    let installation: URL
    let items: [URL]
    static func make(game: Game, installRoots: [URL], steamRoots: [URL], fileManager fm: FileManager = .default) throws -> GameUninstallPlan {
        func blocked(_ message: String) -> NSError { NSError(domain: "Playmelt.Uninstall", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        guard game.installed, let original = game.path, fm.fileExists(atPath: original.path) else { throw blocked("Installation absente. Actualisez la bibliothèque.") }
        let target = original.standardizedFileURL.resolvingSymlinksInPath()
        let roots = installRoots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        let protectedRoots = ["03_PROJECTS", "Documents/Codex", ".codex"].map { fm.homeDirectoryForCurrentUser.appendingPathComponent($0).resolvingSymlinksInPath() }
        guard !roots.contains(where: { $0.path == "/" || $0.path == fm.homeDirectoryForCurrentUser.path }),
              roots.contains(where: { target.path.hasPrefix($0.path + "/") }),
              !protectedRoots.contains(where: { target == $0 || target.path.hasPrefix($0.path + "/") }),
              (try? target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              !roots.contains(target), target.path != fm.homeDirectoryForCurrentUser.path,
              target.path != "/" else { throw blocked("Le dossier détecté sort des bibliothèques autorisées. Aucun fichier n’a été déplacé.") }
        var ancestor = target
        while roots.contains(where: { ancestor == $0 || ancestor.path.hasPrefix($0.path + "/") }) {
            guard !fm.fileExists(atPath: ancestor.appendingPathComponent(".git").path) else { throw blocked("Le dossier appartient à un dépôt ou worktree. Désinstallation manuelle nécessaire.") }
            ancestor.deleteLastPathComponent()
        }
        var items = [target]
        if game.store == "steam", LibraryModel.validAppID(game.appId) {
            for steam in steamRoots {
                let apps = steam.appendingPathComponent("steamapps").standardizedFileURL.resolvingSymlinksInPath()
                let manifest = apps.appendingPathComponent("appmanifest_\(game.appId).acf")
                guard fm.fileExists(atPath: manifest.path) else { continue }
                guard manifest.resolvingSymlinksInPath() == manifest else { throw blocked("Le manifeste Steam est un lien. Vérification manuelle nécessaire.") }
                let state = TextVDF.read(manifest).object("AppState")
                let directory = state.string("installdir")
                guard state.string("appid") == game.appId, !directory.isEmpty, directory != ".", directory != "..",
                      !directory.contains("/"), !directory.contains("\\") else { throw blocked("Le manifeste Steam est invalide. Aucun fichier n’a été déplacé.") }
                let link = apps.appendingPathComponent("common").appendingPathComponent(directory).standardizedFileURL
                let resolved = link.resolvingSymlinksInPath()
                // A local Playmelt entry can represent the containing game folder.
                guard resolved == target || resolved.path.hasPrefix(target.path + "/") else { continue }
                if link != resolved {
                    guard roots.contains(where: { resolved.path.hasPrefix($0.path + "/") }) else { throw blocked("Le lien Steam sort des bibliothèques autorisées.") }
                    if !link.path.hasPrefix(target.path + "/") { items.append(link) }
                }
                items.append(manifest)
            }
        }
        return .init(installation: target, items: Array(Set(items)).sorted { $0.path < $1.path })
    }
}

enum RenderProtection {
    static let preferenceKey = "renderProtectionEnabled"
    static let executionActions: Set<String> = ["launchGame", "installGame", "installAndPlay", "uninstallGame", "setupWindowsRuntime", "installSteamWindows", "openWindowsSteam", "setupD3DMetalRuntime", "installSteamD3DMetal", "openD3DMetalSteam", "openSteam", "openEpic"]
    static func enabled(in preferences: UserDefaults) -> Bool { preferences.object(forKey: preferenceKey) as? Bool ?? true }
    static func blocks(_ action: String, enabled: Bool) -> Bool { enabled && executionActions.contains(action) }
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

func shellLiteral(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

func localGameEnvironmentExports(appID: String) -> String {
    let lower = appID.lowercased()
    var exports: [String] = []
    if appID == "2651280" || lower.contains("spiderman") {
        exports.append("export ROSETTA_ADVERTISE_AVX=\"1\"")
    }
    if lower.contains("rebirth") || appID == "33e6ac38b5a14098b079fd62d71aabc6" {
        exports.append("export WINEMSYNC=\"0\"")
    }
    return exports.joined(separator: "\n")
}

func localGameDX12Arguments(appID: String, projectName: String?) -> [String] {
    appID == "2651280" ? [] : (projectName.map { [$0] } ?? []) + ["-d3d12"]
}

func localGameEpicAuthBlock(appID: String, store: String) -> String {
    guard store == "epic" || appID == "33e6ac38b5a14098b079fd62d71aabc6" || appID.lowercased().contains("rebirth") else { return "EPIC_PARAMS=()" }
    return """
    EPIC_PARAMS=()
    LEGENDARY_BIN="$HOME/Library/Application Support/Playmelt/Dependencies.noindex/epic-venv/bin/legendary"
    PYTHON_BIN="$HOME/Library/Application Support/Playmelt/Dependencies.noindex/epic-venv/bin/python3"
    if [ -x "$LEGENDARY_BIN" ] && [ -x "$PYTHON_BIN" ]; then
        AUTH_ARGS=$("$PYTHON_BIN" - "$LEGENDARY_BIN" "\(appID)" << 'EOF'
    import sys, subprocess, re

    legendary, app_name = sys.argv[1], sys.argv[2]
    def get_args(offline=False):
        cmd = [legendary, "launch", app_name, "--dry-run", "--wine", "wine"]
        if offline:
            cmd.append("--offline")
        out = subprocess.check_output(cmd, stderr=subprocess.STDOUT, text=True)
        m = re.search(r"Launch parameters:\\s+wine\\s+\\x27[^\\x27]+\\x27\\s+(.+)", out)
        return m.group(1).strip() if m else None

    args = None
    try:
        args = get_args(offline=False)
    except Exception:
        pass
    if not args:
        try:
            args = get_args(offline=True)
        except Exception:
            pass
    if args:
        print(args)
    EOF
    )
        if [ -n "$AUTH_ARGS" ]; then
            read -r -a EPIC_PARAMS <<< "$AUTH_ARGS"
        fi
    fi
    """
}

func localGameDisplaySyncBlock(appID: String) -> String {
    guard appID == "33e6ac38b5a14098b079fd62d71aabc6" || appID.lowercased().contains("rebirth") else { return "" }
    return """
    # Synchronisation automatique de l'affichage (HDMI / Écran externe / Retina)
    PYTHON_APPKIT=""
    for p in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
        if [ -x "$p" ] && "$p" -c "import AppKit" 2>/dev/null; then
            PYTHON_APPKIT="$p"
            break
        fi
    done

    if [ -n "$PYTHON_APPKIT" ]; then
        "$PYTHON_APPKIT" - << 'EOF'
    import AppKit, os, re

    try:
        main = AppKit.NSScreen.mainScreen()
        if main:
            w = int(main.frame().size.width)
            h = int(main.frame().size.height)
            scale = int(main.backingScaleFactor())
            retina = "Y" if scale == 2 else "N"
            
            runtime_dir = os.path.expanduser("~/Library/Application Support/Playmelt/Runtime")
            user_reg = os.path.join(runtime_dir, "D3DMetal/prefix/user.reg")
            if os.path.exists(user_reg):
                with open(user_reg, "r", encoding="utf-8") as f:
                    rcontent = f.read()
                if "[Software\\\\\\\\Wine\\\\\\\\Mac Driver]" in rcontent:
                    rcontent = re.sub(r'"RetinaMode"="[YN]"', f'"RetinaMode"="{retina}"', rcontent)
                    if '"RetinaMode"' not in rcontent:
                        rcontent = rcontent.replace("[Software\\\\\\\\Wine\\\\\\\\Mac Driver]", f'[Software\\\\\\\\Wine\\\\\\\\Mac Driver]\\n"RetinaMode"="{retina}"\\n"CaptureDisplaysForFullscreen"="N"')
                    with open(user_reg, "w", encoding="utf-8") as f:
                        f.write(rcontent)
            
            ini_path = os.path.expanduser("~/Library/Application Support/Playmelt/Runtime/D3DMetal/prefix/drive_c/users/robtech/Documents/My Games/FINAL FANTASY VII REBIRTH/Saved/Config/WindowsNoEditor/GameUserSettings.ini")
            if os.path.exists(ini_path):
                with open(ini_path, "r", encoding="utf-8") as f:
                    content = f.read()
                replacements = {
                    r"ResolutionSizeX=\\\\d+": f"ResolutionSizeX={w}",
                    r"ResolutionSizeY=\\\\d+": f"ResolutionSizeY={h}",
                    r"LastUserConfirmedResolutionSizeX=\\\\d+": f"LastUserConfirmedResolutionSizeX={w}",
                    r"LastUserConfirmedResolutionSizeY=\\\\d+": f"LastUserConfirmedResolutionSizeY={h}",
                    r"DesiredScreenWidth=\\\\d+": f"DesiredScreenWidth={w}",
                    r"DesiredScreenHeight=\\\\d+": f"DesiredScreenHeight={h}",
                    r"LastUserConfirmedDesiredScreenWidth=\\\\d+": f"LastUserConfirmedDesiredScreenWidth={w}",
                    r"LastUserConfirmedDesiredScreenHeight=\\\\d+": f"LastUserConfirmedDesiredScreenHeight={h}",
                    r"FullscreenMode=\\\\d+": "FullscreenMode=1",
                    r"LastConfirmedFullscreenMode=\\\\d+": "LastConfirmedFullscreenMode=1",
                    r"PreferredFullscreenMode=\\\\d+": "PreferredFullscreenMode=1",
                    r"WindowPosX=[-\\\\d]+": "WindowPosX=0",
                    r"WindowPosY=[-\\\\d]+": "WindowPosY=0",
                    r"sg\\\\.ViewDistanceQuality=\\\\d+": "sg.ViewDistanceQuality=3",
                    r"sg\\\\.AntiAliasingQuality=\\\\d+": "sg.AntiAliasingQuality=3",
                    r"sg\\\\.ShadowQuality=\\\\d+": "sg.ShadowQuality=3",
                    r"sg\\\\.PostProcessQuality=\\\\d+": "sg.PostProcessQuality=3",
                    r"sg\\\\.TextureQuality=\\\\d+": "sg.TextureQuality=3",
                    r"sg\\\\.EffectsQuality=\\\\d+": "sg.EffectsQuality=3",
                    r"sg\\\\.FoliageQuality=\\\\d+": "sg.FoliageQuality=3",
                    r"sg\\\\.ShadingQuality=\\\\d+": "sg.ShadingQuality=3",
                    r"sg\\\\.SkeletalMeshQuality=\\\\d+": "sg.SkeletalMeshQuality=3",
                    r"sg\\\\.StaticMeshQuality=\\\\d+": "sg.StaticMeshQuality=3",
                }
                for pat, rep in replacements.items():
                    content = re.sub(pat, rep, content)
                with open(ini_path, "w", encoding="utf-8") as f:
                    f.write(content)
            
            engine_ini = os.path.expanduser("~/Library/Application Support/Playmelt/Runtime/D3DMetal/prefix/drive_c/users/robtech/Documents/My Games/FINAL FANTASY VII REBIRTH/Saved/Config/WindowsNoEditor/Engine.ini")
            if not os.path.exists(engine_ini) or "r.SSR.Quality=4" not in open(engine_ini, encoding="utf-8").read():
                with open(engine_ini, "w", encoding="utf-8") as f:
                    f.write("[SystemSettings]\\nr.SSR.Quality=4\\nr.SSR.MaxRoughness=1.0\\nr.SSR.HalfResAtFillRatio=0\\nr.Shadow.MaxResolution=4096\\nr.Shadow.CSM.MaxCascades=5\\nr.Shadow.DistanceScale=2.0\\nr.Shadow.RadiusThreshold=0.01\\nr.ShadowQuality=5\\nr.VolumetricFog=1\\nr.VolumetricFog.GridPixelSizeHorizontal=4\\nr.VolumetricFog.GridPixelSizeVertical=4\\nr.VolumetricFog.GridSizeZ=128\\nr.ViewDistanceScale=2.0\\nr.StaticMeshLODDistanceScale=0.5\\nr.SkeletalMeshLODBias=-1\\nr.Streaming.PoolSize=4096\\nr.Streaming.LimitPoolSizeToVRAM=0\\nr.Streaming.FullyLoadUsedTextures=1\\nr.MaxAnisotropy=16\\nr.DynamicRes.OperationMode=0\\nr.Tonemapper.Sharpen=0.8\\nr.AmbientOcclusionLevels=3\\nr.BloomQuality=5\\nr.DepthOfFieldQuality=2\\n")
    except Exception:
        pass
    EOF
    fi
    """
}

func localGameExecutable(appID: String, files: [String]) -> String? {
    if appID == "2651280" {
        let matches = files.filter { !$0.contains("/") && $0.lowercased() == "spider-man2.exe" }
        return matches.count == 1 ? matches[0] : nil
    }
    let exeCandidates = files.filter { path in
        let lower = path.lowercased()
        guard lower.hasSuffix(".exe") else { return false }
        let ignoredWords = ["crash", "sentry", "redist", "setup", "install", "unins", "vcredist", "dxsetup", "patch", "update", "prereq"]
        guard !ignoredWords.contains(where: { lower.contains($0) }) else { return false }
        guard !lower.contains("engine/extras") && !lower.contains("engine/programs") && !lower.contains("plugins/") else { return false }
        return true
    }
    // Unreal Engine and modern game engines: prioritize real binaries in Binaries/Win64/
    if let shipping = exeCandidates.first(where: { $0.lowercased().contains("binaries/win64/") && $0.lowercased().contains("-shipping.exe") }) {
        return shipping
    }
    if let rebirthOrUnderscore = exeCandidates.first(where: { $0.lowercased().contains("binaries/win64/") && $0.lowercased().hasSuffix("_.exe") }) {
        return rebirthOrUnderscore
    }
    if let win64Exe = exeCandidates.first(where: { $0.lowercased().contains("binaries/win64/") }) {
        return win64Exe
    }
    if let win32Exe = exeCandidates.first(where: { $0.lowercased().contains("binaries/win32/") }) {
        return win32Exe
    }
    return exeCandidates.first(where: { $0.lowercased().contains("-shipping.exe") }) ??
           exeCandidates.filter { !$0.contains("/") }.sorted(by: { $0.count < $1.count }).first ??
           exeCandidates.sorted(by: { $0.count < $1.count }).first
}

func findLaunchScript(in url: URL?) -> URL? {
    guard let url else { return nil }
    let fm = FileManager.default
    if ["command", "sh"].contains(url.pathExtension.lowercased()), fm.isExecutableFile(atPath: url.path) { return url }
    let directories = url.lastPathComponent == "Windows" ? [url, url.deletingLastPathComponent()] : [url]
    for directory in directories {
        let root = directory.resolvingSymlinksInPath()
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        if let script = files.sorted(by: { $0.path < $1.path }).first(where: {
            $0.lastPathComponent.hasPrefix("Lancer-") && $0.pathExtension.lowercased() == "command" &&
            $0.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") && fm.isExecutableFile(atPath: $0.path)
        }) { return script }
    }
    return nil
}

private func contentIsOwnedLaunchScript(_ url: URL) -> Bool {
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 65_536,
          let content = try? String(contentsOf: url, encoding: .utf8) else { return false }
    return content.hasPrefix("#!/bin/bash") && content.contains("# Lanceur direct Playmelt") && content.contains("# Playmelt launcher v3")
}

func ensureLaunchScript(for game: Game, requestedBackend: String = "auto") -> URL? {
    let fm = FileManager.default
    guard LibraryModel.validAppID(game.appId) || game.store == "epic" || game.installSource == "local" || !game.appId.isEmpty else { return nil }
    let requiredBackend = SteamGameLaunchProfile.requiredRenderer(appID: game.appId)
    let bridgeRequested = requestedBackend == "d3dmetal-nv" || requestedBackend == "d3dmetal-nv-rt"
    guard ["auto", "dxmt", "d3dmetal", "d3dmetal-nv", "d3dmetal-nv-rt"].contains(requestedBackend),
          requestedBackend == "auto" || requiredBackend == "auto" || requestedBackend == requiredBackend ||
            (bridgeRequested && requiredBackend == "d3dmetal") else { return nil }
    guard (game.installSource == "local" || game.store == "steam" || game.store == "epic"), let folder = game.path else { return nil }
    let winFolder = folder.appendingPathComponent("Windows")
    let targetDir = fm.fileExists(atPath: winFolder.path) ? winFolder : folder
    guard let files = try? fm.subpathsOfDirectory(atPath: targetDir.path) else { return nil }
    guard let chosen = localGameExecutable(appID: game.appId, files: files) else { return nil }

    if game.appId != "2651280", let existing = findLaunchScript(in: game.path) {
        // Upgrade legacy flawed launch scripts that mixed D3DMetal into DXMT, or launched a wrapper bootstrap
        if let content = try? String(contentsOf: existing, encoding: .utf8),
           content.contains("WINEDLLPATH_PREPEND=\"$RENDERER_DIR/wine:$RUNTIME_DIR") ||
           (game.appId == "1783560" && content.contains("-dx11")) ||
           !content.contains(chosen) ||
           !content.contains("ROSETTA_ADVERTISE_AVX") ||
           (game.appId.lowercased().contains("rebirth") && content.contains("WINEMSYNC=\"1\"")) ||
           ((game.store == "epic" || game.appId == "33e6ac38b5a14098b079fd62d71aabc6") && !content.contains("EPIC_PARAMS")) ||
           (game.appId.lowercased().contains("rebirth") && !content.contains("r.SSR.Quality=4")) ||
           (content.contains("# Lanceur direct Playmelt") && !content.contains("# Playmelt launcher v3")) {
            // Needs regeneration below
        } else if requestedBackend == "auto",
                  let content = try? String(contentsOf: existing, encoding: .utf8),
                  content.contains("D3DM_ENABLE_METALFX") || content.contains("D3DM_SUPPORT_DXR") {
            // Retour en automatique : ne pas garder le pont NVIDIA / DXR d'un ancien choix.
        } else if requestedBackend == "auto" {
            return existing
        } else if !contentIsOwnedLaunchScript(existing) {
            return nil
        }
    }
    if game.appId == "2651280" {
        let executable = targetDir.appendingPathComponent(chosen)
        guard let values = try? executable.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
    }

    let isUnity = chosen.lowercased().contains("unity") || files.contains(where: { $0.lowercased().hasSuffix("_data") || $0.lowercased().contains("unityplayer.dll") })
    let dx12Markers = files.contains(where: { $0.lowercased().contains("d3d12core.dll") || $0.lowercased().contains("d3d12sdklayers.dll") || $0.lowercased().contains("plugins/nne") })
    let selectedBackend = requestedBackend == "auto" ? SteamGameLaunchProfile.localRenderer(appID: game.appId, unity: isUnity, dx12Markers: dx12Markers) : requestedBackend
    let isDX12 = ["d3dmetal", "d3dmetal-nv", "d3dmetal-nv-rt"].contains(selectedBackend)
    let useNvidiaBridge = selectedBackend == "d3dmetal-nv" || selectedBackend == "d3dmetal-nv-rt"
    // Ray tracing DXR : opt-in par jeu, uniquement avec le pont (Ray Reconstruction).
    let useDXR = selectedBackend == "d3dmetal-nv-rt"
    let base = RuntimeSetup().descriptor()
    guard base.readyEngine else { return nil }
    if isDX12 {
        guard let metal = try? D3DMetalRuntime(store: D3DMetalStore()).descriptor(base: base), metal.readyEngine else { return nil }
        if useNvidiaBridge, !NvidiaBridgeStore.shared.available() { return nil }
    }

    var projName: String? = nil
    if chosen.lowercased().contains("-shipping.exe") {
        projName = (try? fm.contentsOfDirectory(atPath: targetDir.path))?.first(where: { item in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: targetDir.appendingPathComponent(item).path, isDirectory: &isDir) && isDir.boolValue && !["engine", "communityresources", "binaries", "redist"].contains(item.lowercased())
        })
    }

    let extraArgs: String
    let scriptContent: String
    if game.appId == "2651280" {
        let expected = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Playmelt/Games/MarvelsSpiderMan2", isDirectory: true).standardizedFileURL
        guard targetDir.standardizedFileURL == expected, chosen == "Spider-Man2.exe",
              let runner = Bundle.main.url(forResource: "spiderman2_profile", withExtension: "py"),
              let python = ["/opt/homebrew/bin/python3", "/usr/bin/python3", "/usr/local/bin/python3"].first(where: { fm.isExecutableFile(atPath: $0) }) else { return nil }
        extraArgs = ""
        scriptContent = """
        #!/bin/bash
        # Lanceur direct Playmelt (Wine / D3DMetal DX12)
        # Playmelt launcher v3
        exec \(shellLiteral(python)) -B \(shellLiteral(runner.path)) --run
        \n
        """
    } else if isDX12 {
        extraArgs = localGameDX12Arguments(appID: game.appId, projectName: projName).map(shellLiteral).joined(separator: " ")
        // Pont DLSS → MetalFX : exports runtime + répertoire wine du composant moteur.
        let bridgeExports = (useNvidiaBridge ? "export D3DM_ENABLE_METALFX=\"1\"\nexport WINEDLLOVERRIDES=\"nvapi64,nvngx=b,n;$WINEDLLOVERRIDES\"\n" : "")
            + (useDXR ? "export D3DM_SUPPORT_DXR=\"1\"\n" : "")
        let bridgeWinePath = useNvidiaBridge ? ":" + shellLiteral(NvidiaBridgeStore.shared.winePath) : ""
        scriptContent = """
        #!/bin/bash
        # Lanceur direct Playmelt (Wine / D3DMetal DX12)
        # Playmelt launcher v3
        set -eo pipefail
        GAME_DIR=\(shellLiteral(targetDir.path))
        RUNTIME_DIR="$HOME/Library/Application Support/Playmelt/Runtime"
        RENDERER_DIR="$HOME/Library/Application Support/Playmelt/Renderers/D3DMetal/payload"

        cd "$GAME_DIR"

        export ROSETTA_ADVERTISE_AVX="1"
        export WINEPREFIX="$RUNTIME_DIR/D3DMetal/prefix"
        export WINEDEBUG="-all"
        export WINEMSYNC="1"
        export WINEESYNC="0"
        \(localGameEnvironmentExports(appID: game.appId))
        export D3DM_MTL4="1"
        export WINEDLLOVERRIDES="d3d12,d3d12core,dxgi=n,b;winemenubuilder.exe=d"
        \(bridgeExports)export WINEDLLPATH_PREPEND="$RENDERER_DIR/wine\(bridgeWinePath)"
        export CX_D3DMETALPATH="$RENDERER_DIR/external"
        export DYLD_FALLBACK_LIBRARY_PATH="$RENDERER_DIR/external:$RENDERER_DIR/external/D3DMetal.framework/Versions/A/Resources:$RUNTIME_DIR/playmelt-wine10-dxmt-20261017/frameworks:$RUNTIME_DIR/playmelt-wine10-dxmt-20261017/frameworks/GStreamer.framework/Versions/1.0/lib"
        export DYLD_FALLBACK_FRAMEWORK_PATH="$RENDERER_DIR/external:$RUNTIME_DIR/playmelt-wine10-dxmt-20261017/frameworks"
        export MVK_CONFIG_LOG_LEVEL=0

        \(localGameDisplaySyncBlock(appID: game.appId))

        \(localGameEpicAuthBlock(appID: game.appId, store: game.store))

        mkdir -p "$RUNTIME_DIR/logs"
        exec "$RUNTIME_DIR/playmelt-wine10-dxmt-20261017/engine/bin/wine" \(shellLiteral(chosen)) \(extraArgs) "${EPIC_PARAMS[@]}" "$@" 2>&1 | /usr/bin/tail -c 1048576 >"$RUNTIME_DIR/logs/game-\(game.appId).log"
        \n
        """
    } else {
        extraArgs = (isUnity ? ["-force-d3d11"] : ((projName.map { [$0] } ?? []) + ["-dx11"])).map(shellLiteral).joined(separator: " ")
        scriptContent = """
        #!/bin/bash
        # Lanceur direct Playmelt (Wine / DXMT)
        # Playmelt launcher v3
        set -eo pipefail
        GAME_DIR=\(shellLiteral(targetDir.path))
        RUNTIME_DIR="$HOME/Library/Application Support/Playmelt/Runtime"

        cd "$GAME_DIR"

        export ROSETTA_ADVERTISE_AVX="1"
        export WINEPREFIX="$RUNTIME_DIR/prefix"
        export WINEDEBUG="-all"
        export WINEMSYNC="1"
        export WINEESYNC="0"
        \(localGameEnvironmentExports(appID: game.appId))
        export WINEDLLOVERRIDES="d3d11,dxgi,nvapi64=n,b;winemenubuilder.exe=d"
        export WINEDLLPATH_PREPEND="$RUNTIME_DIR/playmelt-wine10-dxmt-20261017/renderers/dxmt/wine"
        export DYLD_FALLBACK_LIBRARY_PATH="$RUNTIME_DIR/playmelt-wine10-dxmt-20261017/frameworks:$RUNTIME_DIR/playmelt-wine10-dxmt-20261017/frameworks/GStreamer.framework/Versions/1.0/lib"
        export DYLD_FALLBACK_FRAMEWORK_PATH="$RUNTIME_DIR/playmelt-wine10-dxmt-20261017/frameworks"
        export MVK_CONFIG_LOG_LEVEL=0

        \(localGameEpicAuthBlock(appID: game.appId, store: game.store))

        mkdir -p "$RUNTIME_DIR/logs"
        exec "$RUNTIME_DIR/playmelt-wine10-dxmt-20261017/engine/bin/wine" \(shellLiteral(chosen)) \(extraArgs) "${EPIC_PARAMS[@]}" "$@" 2>&1 | /usr/bin/tail -c 1048576 >"$RUNTIME_DIR/logs/game-\(game.appId).log"
        \n
        """
    }

    let safeTitle = game.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespaces)
    let scriptURL = folder.appendingPathComponent("Lancer-\(safeTitle).command")
    if game.appId == "2651280", fm.fileExists(atPath: scriptURL.path) {
        guard let content = try? String(contentsOf: scriptURL, encoding: .utf8),
              content.contains("# Lanceur direct Playmelt") else { return nil }
    }
    let runtimeDir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Playmelt/Runtime")
    RuntimeSetup.ensureVisualCRuntimeKeys(runtimeDir.appendingPathComponent(isDX12 ? "D3DMetal/prefix" : "prefix"))
    if useNvidiaBridge {
        // Clé NGXCore pour le plugin NGX d'Unreal Engine (FF7 Rebirth, etc.).
        NvidiaBridgeStore.shared.ensurePrefixRegistryKeys(runtimeDir.appendingPathComponent("D3DMetal/prefix"))
    }
    do {
        try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
        guard chmod(scriptURL.path, 0o755) == 0 else { return nil }
    } catch { return nil }

    return scriptURL
}

func steamInstallationPath(apps: URL, directory: String) -> URL? {
    guard !directory.isEmpty, directory != ".", directory != "..", !directory.contains("/"), !directory.contains("\\") else { return nil }
    let base = apps.resolvingSymlinksInPath()
    let common = base.appendingPathComponent("common").resolvingSymlinksInPath()
    let path = common.appendingPathComponent(directory).resolvingSymlinksInPath()
    let home = FileManager.default.homeDirectoryForCurrentUser
    let playmeltGames = home.appendingPathComponent("Library/Application Support/Playmelt/Games").resolvingSymlinksInPath()
    let commonPath = common.path
    let resolvedPath = path.path
    if (commonPath.hasPrefix(base.path + "/") && resolvedPath.hasPrefix(commonPath + "/")) ||
       resolvedPath.hasPrefix(playmeltGames.path + "/") || resolvedPath == playmeltGames.path {
        return path
    }
    return nil
}

func containsLaunchBinary(_ root: URL, platform: String, cancelled: () -> Bool = { false }) -> Bool {
    guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey], options: [.skipsHiddenFiles]) else { return false }
    var count = 0
    while let file = walker.nextObject() as? URL {
        if cancelled() { return false }
        count += 1; if count > 1500 { break }
        if walker.level > 6 { walker.skipDescendants(); continue }
        if file.pathExtension.lowercased() == "command", FileManager.default.isExecutableFile(atPath: file.path) {
            return true
        }
        if (platform == "windows" || platform == "any" || platform == "unknown"), file.pathExtension.lowercased() == "exe",
           (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
           let handle = try? FileHandle(forReadingFrom: file) {
            let prefix = try? handle.read(upToCount: 2); try? handle.close()
            if prefix == Data([0x4d, 0x5a]) { return true }
        }
        if (platform == "mac" || platform == "any" || platform == "unknown"), !["dylib", "so", "bundle", "dll", "exe"].contains(file.pathExtension.lowercased()),
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
    let xboxConnector = XboxConnector()
    let gogConnector = GOGConnector()
    var windowsDescriptor: PlaymeltRuntimeDescriptor?
    var d3dMetalDescriptor: PlaymeltRuntimeDescriptor?
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
        if let engine = d3dMetalDescriptor, engine.readyEngine && engine.steamInstalled {
            runtimes.append(Runtime(id: "playmelt-d3dmetal", name: "Playmelt · DirectX 12", platform: "windows", steamRoot: engine.steamRoot, appURL: nil,
                                    wineURL: engine.wineURL, prefixURL: engine.prefixURL, environment: engine.environment, verifiedIndependentEngine: true,
                                    renderer: "d3dmetal", graphicsValidated: false))
        }
        return runtimes
    }
    private var scanGeneration: UInt64 = 0
    private let auditScanner = LibraryScanner()
    private var scannedAvailability: [String: Bool] = [:]
    private(set) var lastScanMetrics = LibraryScanMetrics()
    func makeScanRequest() -> LibraryScanRequest {
        scanGeneration &+= 1
        let store = preferences
        return LibraryScanRequest(generation: scanGeneration, requestedAccountID: selectedAccountID,
                                  home: home, runtimes: discoverRuntimes(),
                                  readSavedSnapshot: { id in
            guard Self.validAccountID(id) else { return nil }
            return store.data(forKey: "steamLibrarySnapshot." + id)
        })
    }
    @discardableResult func applyScan(_ snapshot: LibraryScanSnapshot) -> Bool {
        guard snapshot.generation == scanGeneration, snapshot.requestedAccountID == selectedAccountID else { return false }
        runtimes = snapshot.runtimes; accounts = snapshot.accounts; metadata = snapshot.metadata
        selectedAccountID = snapshot.selectedAccountID; scannedAvailability = snapshot.runtimeAvailability
        lastScanMetrics = snapshot.metrics
        if authenticatedGames[selectedAccountID] == nil, let saved = snapshot.savedLibrary, saved.accountID == selectedAccountID {
            authenticatedGames[selectedAccountID] = saved.games.map { $0 as [String: Any] }
            authenticatedDates[selectedAccountID] = saved.updatedAt
        }
        games = snapshot.steamGames + snapshot.epicInstalledGames
        // Merge only current authenticated state. An auth response arriving while
        // the worker scans cannot be overwritten by an older copy of the model.
        if let verified = authenticatedGames[selectedAccountID] { mergeVerified(verified) }
        if let epicSnapshot { mergeEpic(epicSnapshot) }
        games += xboxConnector.games()
        games += gogConnector.games()
        games.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        updateLibraryStatus()
        warnings = ["Une entrée du cache local peut être un ancien jeu, une démo ou un jeu partagé. Steam contrôle les droits lors de l’installation."]
        return true
    }
    /// Synchronous CLI audit/test entrypoint. UI refresh uses LibraryScanner.scan.
    func refresh() { _ = applyScan(auditScanner.scanSynchronously(makeScanRequest())) }
    private func updateLibraryStatus() {
        if let verified = authenticatedGames[selectedAccountID] {
            let live = liveAuthenticatedAccounts.contains(selectedAccountID)
            libraryStatus = live ? "synced" : "snapshot"
            lastSync = authenticatedDates[selectedAccountID] ?? ""
            libraryMessage = live ? "Bibliothèque lue dans votre session Steam officielle (\(verified.count) jeux). Les installations et les performances restent vérifiées séparément." : "Dernière bibliothèque Steam vérifiée : \(verified.count) jeux. Copie locale datée, à synchroniser pour confirmer les droits actuels."
        } else if libraryStatus != "syncing" {
            libraryStatus = "local"; lastSync = ""
            libraryMessage = selectedAccountID.isEmpty ? "Ouvrez Steam et connectez votre compte, puis actualisez." : "Compte repéré dans Steam. Historique local et installations détectés ; la propriété et l’exhaustivité restent à vérifier par connexion Steam."
        }
    }
    func makeGame(_ id: String, ownership: String) -> Game {
        Self.makeGame(id, ownership: ownership, metadata: metadata, runtimes: runtimes, availability: scannedAvailability.isEmpty ? nil : scannedAvailability)
    }
    static func makeGame(_ id: String, ownership: String, metadata: [String: SteamAppInfo], runtimes: [Runtime], availability: [String: Bool]? = nil) -> Game {
        let info = metadata[id]
        let platform = info?.platforms.contains("macos") == true ? "mac" : info?.platforms.contains("windows") == true ? "windows" : "unknown"
        let runtime = runtimes.first { $0.executionAllowed && $0.platform == platform && (availability?[$0.id] ?? $0.available) && SteamGameLaunchProfile.supportsInstallation(appID: id, runtime: $0) }
        var game = Game(id: "steam:\(id)", appId: id, title: info?.name ?? "Steam \(id)", store: "steam", installed: false, platform: platform, runtimeId: runtime?.id ?? "", runtimeName: runtime?.name ?? (platform == "windows" ? "Moteur Windows non configuré" : "Aucune route vérifiée"), ownership: ownership)
        game.supportedPlatforms = ["macos", "windows"].filter { info?.platforms.contains($0) == true }.map { $0 == "macos" ? "mac" : "windows" }
        if let path = info?.portraitAssets.first { game.customPortraitURL = SteamAppInfo.artworkURL(appID: id, path: path) ?? "" }
        if let path = info?.landscapeAssets.first { game.customImageURL = SteamAppInfo.artworkURL(appID: id, path: path) ?? "" }
        return game
    }
    func libraryRoots(_ runtime: Runtime) -> [URL] {
        let folders = TextVDF.read(runtime.steamRoot.appendingPathComponent("steamapps/libraryfolders.vdf")).object("libraryfolders")
        return Self.libraryRoots(runtime, paths: folders.values.map { ($0 as? [String: Any])?.string("path") ?? ($0 as? String ?? "") })
    }
    static func libraryRoots(_ runtime: Runtime, paths: [String]) -> [URL] {
        var result = [runtime.steamRoot]
        for path in paths {
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
    static func readEpicManifest(_ file: URL) -> Game? {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 2_000_000,
              let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 2_000_000), data.count < 2_000_000,
              let m = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let app = m.string("AppName"), namespace = m.string("CatalogNamespace"), item = m.string("CatalogItemId")
        let identifiers = [app, namespace, item]
        guard identifiers.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 && $0.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil }),
              namespace != "ue", !m.string("LaunchExecutable").isEmpty,
              m.string("InstallLocation").hasPrefix("/") else { return nil }
        let path = URL(fileURLWithPath: m.string("InstallLocation")).resolvingSymlinksInPath()
        guard (try? path.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
        let incomplete: Bool
        if let raw = m.value("bIsIncompleteInstall") {
            guard let flag = raw as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { return nil }
            incomplete = flag.boolValue
        } else { incomplete = false }
        let complete = !incomplete && verifiedEpicMacExecutable(root: path, executable: m.string("LaunchExecutable")) != nil
        return Game(id: "epic:" + app, appId: app, title: m.string("DisplayName"), store: "epic", installed: true,
                    platform: "mac", runtimeId: "epic-mac", runtimeName: "Epic Games Launcher", ownership: "installed-only",
                    path: path, complete: complete,
                    epicLaunchID: [namespace, item, app].joined(separator: ":"),
                    supportedPlatforms: [], customImageURL: "", customPortraitURL: "", lastPlayed: 0, installSource: "epic")
    }
    /// Checks the manifest's actual launch target, not an unrelated helper in the
    /// installation tree. A readable manifest or MZ Windows file is not a native
    /// Mac installation. This structural check does not certify code signing,
    /// entitlement, DRM, or successful execution by the Epic launcher.
    /// Layouts: Apple's mach-o/loader.h and mach-o/fat.h in xnu/EXTERNAL_HEADERS.
    static func verifiedEpicMacExecutable(root: URL, executable: String) -> URL? {
        guard !executable.isEmpty, executable.utf8.count <= 4096, !executable.contains("\0"),
              !executable.hasPrefix("/"), !executable.contains("\\"),
              !executable.split(separator: "/").contains(".."),
              (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
        let base = root.resolvingSymlinksInPath()
        var target = base.appendingPathComponent(executable).standardizedFileURL.resolvingSymlinksInPath()
        guard target.path.hasPrefix(base.path + "/") else { return nil }
        if target.pathExtension.lowercased() == "app" {
            guard let bundle = Bundle(url: target), let binary = bundle.executableURL else { return nil }
            target = binary.resolvingSymlinksInPath()
            guard target.path.hasPrefix(base.path + "/") else { return nil }
        }
        guard (try? target.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              FileManager.default.isExecutableFile(atPath: target.path),
              let handle = try? FileHandle(forReadingFrom: target) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size >= 28 else { return nil }
        func read(_ offset: UInt64, _ count: Int) -> [UInt8]? {
            guard offset <= size, UInt64(count) <= size - offset else { return nil }
            do { try handle.seek(toOffset: offset) } catch { return nil }
            guard let data = try? handle.read(upToCount: count), data.count == count else { return nil }
            return Array(data)
        }
        func number(_ bytes: [UInt8], _ at: Int, _ count: Int, little: Bool) -> UInt64 {
            (0..<count).reduce(UInt64(0)) { value, index in
                value | UInt64(bytes[at + index]) << (8 * (little ? index : count - 1 - index))
            }
        }
        func thin(_ offset: UInt64, expectedCPU: UInt64? = nil) -> Bool {
            guard let h = read(offset, 32), Array(h.prefix(4)) == [0xcf, 0xfa, 0xed, 0xfe] else { return false }
            let cpu = number(h, 4, 4, little: true)
            return [UInt64(0x01000007), UInt64(0x0100000c)].contains(cpu) &&
                (expectedCPU == nil || cpu == expectedCPU) && number(h, 12, 4, little: true) == 2
        }
        if thin(0) { return target }
        guard let header = read(0, 8) else { return nil }
        let magic = Array(header.prefix(4))
        let fat64 = magic == [0xca,0xfe,0xba,0xbf] || magic == [0xbf,0xba,0xfe,0xca]
        guard fat64 || magic == [0xca,0xfe,0xba,0xbe] || magic == [0xbe,0xba,0xfe,0xca] else { return nil }
        let little = magic[0] == 0xbe || magic[0] == 0xbf
        let count = number(header, 4, 4, little: little), stride = fat64 ? 32 : 20
        guard count > 0, count <= 16, let table = read(8, Int(count) * stride) else { return nil }
        let tableEnd = UInt64(8 + table.count)
        for index in 0..<Int(count) {
            let at = index * stride, cpu = number(table, at, 4, little: little)
            guard [UInt64(0x01000007), UInt64(0x0100000c)].contains(cpu) else { continue }
            let width = fat64 ? 8 : 4
            let offset = number(table, at + 8, width, little: little)
            let length = number(table, at + 8 + width, width, little: little)
            if offset >= tableEnd, length >= 32, offset <= size, length <= size - offset,
               thin(offset, expectedCPU: cpu) { return target }
        }
        return nil
    }
    func epicGames() -> [Game] {
        let root = home.appendingPathComponent("Library/Application Support/Epic/EpicGamesLauncher/Data/Manifests")
        var seen = Set<String>()
        return ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "item" }.compactMap(Self.readEpicManifest).filter {
                guard let path = $0.path else { return false }
                return FileManager.default.fileExists(atPath: path.path) && seen.insert($0.appId).inserted
            }
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
        var present = Set(games.filter { $0.store == "steam" }.map(\.appId))
        for row in list {
            guard let id = row["appid"] as? String, Self.validAppID(id) else { continue }
            if present.insert(id).inserted {
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
    func acceptAuthenticatedLibrary(accountID: String, list: [[String: Any]], source: String = "steamcommunity-authenticated-all-games", allowAccountDiscovery: Bool = false) -> Bool {
        // Discovery is explicit and only permitted while no account is selected.
        // Validate the entire authenticated response before persisting a selection.
        guard accountID == selectedAccountID || (allowAccountDiscovery && selectedAccountID.isEmpty),
              Self.validAccountID(accountID), Self.steamLibrarySources.contains(source), !list.isEmpty, list.count < 20000,
              list.allSatisfy({ ($0["appid"] as? String).map(Self.validAppID) == true && !($0["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(list.compactMap { $0["appid"] as? String }).count == list.count else { return false }
        let sanitized = list.map { ["appid": $0["appid"] as! String, "name": String(($0["name"] as? String ?? "").prefix(200))] }
        if selectedAccountID.isEmpty {
            selectedAccountID = accountID
            preferences.set(accountID, forKey: "selectedSteamAccount")
            if !accounts.contains(where: { $0.id == accountID }) {
                accounts.append(Account(id: accountID, name: "Compte Steam", source: "Session Steam vérifiée", recent: true))
            }
        }
        authenticatedGames[accountID] = sanitized; liveAuthenticatedAccounts.insert(accountID)
        libraryStatus = "synced"; lastSync = ISO8601DateFormatter().string(from: Date()); authenticatedDates[accountID] = lastSync
        if let data = try? JSONSerialization.data(withJSONObject: ["accountId": accountID, "games": sanitized, "source": source, "updatedAt": lastSync]) {
            preferences.set(data, forKey: "steamLibrarySnapshot." + accountID)
        }
        libraryMessage = "Bibliothèque lue dans votre session Steam officielle (\(list.count) jeux). Les installations et les performances restent vérifiées séparément."
        mergeVerified(sanitized); games.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return true
    }
    func mergeEpic(_ snapshot: EpicSnapshot) {
        for row in snapshot.games {
            guard let appName = row["appName"] as? String, !appName.isEmpty, appName.count <= 512,
                  let title = row["title"] as? String else { continue }
            let platforms = (row["platforms"] as? [String] ?? []).map { $0.lowercased() }.filter { ["mac", "windows"].contains($0) }
            let imageURL = row["imageURL"] as? String ?? ""
            if let index = games.firstIndex(where: { $0.store == "epic" && $0.appId == appName }) {
                games[index].ownership = "authenticated-library"; games[index].supportedPlatforms = platforms
                if !imageURL.isEmpty {
                    games[index].customImageURL = imageURL
                    games[index].customPortraitURL = imageURL
                }
            } else {
                let game = Game(id: "epic-owned:" + appName, appId: appName, title: String(title.prefix(200)), store: "epic", installed: false,
                                platform: platforms.contains("mac") ? "mac" : platforms.contains("windows") ? "windows" : "unknown",
                                runtimeId: "epic-mac", runtimeName: "Epic Games Launcher", ownership: "authenticated-library",
                                path: nil, complete: false, epicLaunchID: "", supportedPlatforms: platforms,
                                customImageURL: imageURL, customPortraitURL: imageURL, lastPlayed: 0, installSource: "epic")
                games.append(game)
            }
        }
    }
    func state() -> [String: Any] {
        let hardware = hardwareState(renderProtectionEnabled: RenderProtection.enabled(in: preferences))
        let availability = Dictionary(uniqueKeysWithValues: runtimes.map { ($0.id, $0.available) })
        var completedRoutes: [String: Set<String>] = [:]
        for game in games where game.store == "steam" && game.installed && game.complete {
            completedRoutes[game.appId, default: []].insert(game.runtimeId)
        }
        let epicCount = games.filter { $0.store == "epic" && $0.installed }.count
        let epicPresent = FileManager.default.fileExists(atPath: "/Applications/Epic Games Launcher.app")
        var epic: [String: Any] = ["status": epicPresent ? "launcher-present" : "unavailable", "message": epicPresent ? "Lanceur officiel présent. \(epicCount) jeux installés détectés. Bibliothèque du compte Epic non synchronisée." : "Epic Games Launcher n’est pas installé.", "installedCount": epicCount]
        epic.merge(epicAvailability) { _, new in new }
        if let snapshot = epicSnapshot {
            let current = epicSnapshotFresh && epicAvailability["authenticated"] as? Bool == true &&
                epicAvailability["sessionVerified"] as? Bool == true &&
                epicAvailability["accountId"] as? String == snapshot.accountId
            epic["status"] = current ? "synced" : "snapshot"; epic["displayName"] = snapshot.displayName; epic["updatedAt"] = snapshot.updatedAt
            epic["message"] = current ? "\(snapshot.displayName) · \(snapshot.games.count) jeux dans la bibliothèque Epic." : "Dernière bibliothèque Epic de \(snapshot.displayName) : \(snapshot.games.count) jeux. Nouvelle connexion ou synchronisation à vérifier."
        }
        return ["version": "2.0.0", "accounts": accounts.map { ["id": $0.id, "name": $0.name, "source": $0.source, "selected": $0.id == selectedAccountID] as [String: Any] },
                "selectedAccountId": selectedAccountID, "libraryStatus": ["status": libraryStatus, "message": libraryMessage, "updatedAt": lastSync],
                "games": games.map { $0.json(runtimes: runtimes, availability: availability, completedRuntimeIDs: completedRoutes[$0.appId] ?? []) }, "runtimes": runtimes.map(\.json), "hardware": hardware,
                "warnings": warnings, "epic": epic, "xbox": xboxConnector.availability(), "gog": gogConnector.availability(), "executionPolicy": WindowsExecutionPolicy.json,
                "graphicsFeatures": GraphicsFeatureContract.diagnosticsSnapshot(),
                "graphicsFrameAdapters": GraphicsFrameAdapter.diagnosticsSnapshot()]
    }
    func hasCompleteInstallation(appID: String, runtimeID: String) -> Bool {
        games.contains { $0.store == "steam" && $0.appId == appID && $0.runtimeId == runtimeID && $0.installed && $0.complete }
    }
}

func hardwareState(renderProtectionEnabled: Bool = true) -> [String: Any] {
    func sysString(_ name: String) -> String {
        var size = 0; guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0, size < 1024 else { return "Indisponible" }
        var bytes = [CChar](repeating: 0, count: size); guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return "Indisponible" }; return String(cString: bytes)
    }
    let thermal: String
    switch ProcessInfo.processInfo.thermalState { case .nominal: thermal = "nominal"; case .fair: thermal = "fair"; case .serious: thermal = "serious"; case .critical: thermal = "critical"; @unknown default: thermal = "unknown" }
    var swap = xsw_usage(); var swapSize = MemoryLayout<xsw_usage>.size
    let hasSwap = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0
    // Metadata only. No buffer, heap, texture, command queue or GPU work is created.
    let device = MTLCreateSystemDefaultDevice()
    let memory = GraphicsMemoryBudget.evaluate(inputs: .init(
        totalUnifiedBytes: ProcessInfo.processInfo.physicalMemory,
        recommendedWorkingSetBytes: device?.recommendedMaxWorkingSetSize,
        observedOwnAllocatedBytes: device.map { UInt64($0.currentAllocatedSize) },
        hasUnifiedMemory: device?.hasUnifiedMemory ?? false,
        renderProtectionEnabled: renderProtectionEnabled, pressure: .unknown))
    var result: [String: Any] = ["chip": sysString("machdep.cpu.brand_string"), "memoryGB": ProcessInfo.processInfo.physicalMemory / 1_073_741_824,
                               "cpuCores": ProcessInfo.processInfo.processorCount, "gpuName": device?.name ?? "Indisponible",
                               "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled, "thermalState": thermal,
                               "gpuMemoryBudget": memory.json, "gpuAllocatorConnected": false,
                               "metalFXBackend": MetalFXFrameAdapter.diagnosticsSnapshot(device: device),
                               "performanceStatus": "Configuration observée du Mac. Aucun test de charge automatique."]
    if hasSwap { result["swapUsedGB"] = Double(swap.xsu_used) / 1_073_741_824 }
    return result
}
