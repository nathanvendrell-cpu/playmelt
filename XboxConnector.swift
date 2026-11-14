import Foundation
import AppKit
import WebKit

/// Xbox Game Pass Ultimate — Cloud Gaming & PC Game Pass connector for Playmelt.
///
/// Catalogue: the official, public Game Pass catalogue feeds (catalog.gamepass.com SIGL lists)
/// for both Cloud Gaming and PC Game Pass, resolved through the Microsoft Store display catalogue
/// (displaycatalog.mp.microsoft.com).
///
/// Each game is tagged with its capabilities: Cloud Gaming (`hasCloud`), PC Game Pass (`hasPC`), or both.
///
/// Account: the Microsoft sign-in happens inside Playmelt's Xbox Cloud window (WKWebView, persistent
/// default data store). "Connected" is reported only when a Microsoft account session cookie exists.
final class XboxConnector {
    struct Title: Codable {
        let id: String          // Microsoft Store product ID (BigId), e.g. 9NKX70BBCDRN
        let title: String
        let imageURL: String    // 16:9 hero art
        let portraitURL: String // 2:3 poster
        let developer: String
        let category: String
        var hasCloud: Bool
        var hasPC: Bool

        enum CodingKeys: String, CodingKey {
            case id, title, imageURL, portraitURL, developer, category, hasCloud, hasPC
        }

        init(id: String, title: String, imageURL: String, portraitURL: String, developer: String, category: String, hasCloud: Bool, hasPC: Bool) {
            self.id = id
            self.title = title
            self.imageURL = imageURL
            self.portraitURL = portraitURL
            self.developer = developer
            self.category = category
            self.hasCloud = hasCloud
            self.hasPC = hasPC
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            title = try container.decode(String.self, forKey: .title)
            imageURL = try container.decode(String.self, forKey: .imageURL)
            portraitURL = try container.decode(String.self, forKey: .portraitURL)
            developer = try container.decodeIfPresent(String.self, forKey: .developer) ?? ""
            category = try container.decodeIfPresent(String.self, forKey: .category) ?? ""
            hasCloud = try container.decodeIfPresent(Bool.self, forKey: .hasCloud) ?? true
            hasPC = try container.decodeIfPresent(Bool.self, forKey: .hasPC) ?? false
        }

        var cloudURL: URL? {
            guard hasCloud else { return nil }
            return URL(string: "https://www.xbox.com/fr-FR/play/launch/\(XboxConnector.slug(title))/\(id)")
        }

        var storeURL: URL {
            URL(string: "https://www.xbox.com/fr-FR/games/store/\(XboxConnector.slug(title))/\(id)")!
        }
    }

    private struct CachedCatalog: Codable {
        let fetchedAt: Date
        let titles: [Title]
    }

    /// Official SIGL ids for Game Pass lists: Cloud Gaming and PC Game Pass
    static let cloudSiglID = "29a81209-df6f-41fd-a528-2ae6b91f719c"
    static let pcSiglID = "fdd9e2a7-0fee-49f6-ad69-4354098401ff"
    static let market = "FR", language = "fr-fr"
    private static let cacheLifetime: TimeInterval = 6 * 60 * 60
    private static let failureRetryLifetime: TimeInterval = 15 * 60

    private let lock = NSLock()
    private var titles: [Title] = []
    private var fetchedAt: Date?
    private var fetching = false
    private var lastError = ""
    private var lastAttempt: Date?
    private var signedIn = false
    private let cacheURL: URL
    private let session: URLSession

    /// Called on the main queue when the catalogue or the sign-in state changed.
    var onUpdate: (() -> Void)?
    var onOpenCloud: ((URL, Bool) -> Void)?

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let support = home.appendingPathComponent("Library/Application Support/Playmelt", isDirectory: true)
        cacheURL = support.appendingPathComponent(".xbox_cloud_catalog.json")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: configuration)
        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode(CachedCatalog.self, from: data) {
            titles = cached.titles
            fetchedAt = cached.fetchedAt
        }
    }

    static func slug(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR")).lowercased()
        let parts = folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber || !$0.isASCII })
        let joined = parts.joined(separator: "-")
        return joined.isEmpty ? "game" : String(joined.prefix(80))
    }

    // MARK: State

    func availability() -> [String: Any] {
        lock.lock()
        let count = titles.count
        let cloudCount = titles.filter(\.hasCloud).count
        let pcCount = titles.filter(\.hasPC).count
        let busy = fetching, error = lastError, connected = signedIn, date = fetchedAt
        lock.unlock()
        let message: String
        if count == 0 {
            message = busy ? "Chargement du catalogue Xbox Game Pass Ultimate…" : (error.isEmpty ? "Catalogue Xbox non chargé." : error)
        } else if connected {
            message = "Compte Microsoft connecté · \(cloudCount) jeux Cloud & \(pcCount) jeux PC (Game Pass Ultimate)."
        } else {
            message = "\(count) jeux Game Pass disponibles (\(cloudCount) Cloud, \(pcCount) PC). Connectez votre compte Microsoft pour jouer."
        }
        return [
            "status": connected ? "connected" : (count > 0 ? "requiresLogin" : (busy ? "loading" : "unavailable")),
            "available": count > 0,
            "authenticated": connected,
            "cloudEnabled": true,
            "cloudCount": cloudCount,
            "pcCount": pcCount,
            "catalogCount": count,
            "busy": busy,
            "updatedAt": date.map { ISO8601DateFormatter().string(from: $0) } ?? "",
            "cloudProvider": "Xbox Game Pass Ultimate",
            "message": message
        ]
    }

    func games() -> [Game] {
        lock.lock(); let list = titles; lock.unlock()
        return list.map { title in
            var platforms: [String] = []
            if title.hasCloud { platforms.append("cloud") }
            if title.hasPC { platforms.append("windows") }
            let rName = title.hasCloud && title.hasPC ? "Cloud & PC Game Pass" : (title.hasCloud ? "Xbox Cloud Gaming" : "PC Game Pass")
            return Game(id: "xbox:" + title.id, appId: title.id, title: title.title, store: "xbox",
                 installed: false, platform: title.hasCloud ? "cloud" : "windows",
                 runtimeId: title.hasCloud ? "xbox-cloud" : "pc-gamepass",
                 runtimeName: rName,
                 ownership: "game-pass", path: nil, complete: true,
                 epicLaunchID: title.cloudURL?.absoluteString ?? title.storeURL.absoluteString,
                 supportedPlatforms: platforms, customImageURL: title.imageURL, customPortraitURL: title.portraitURL,
                 lastPlayed: 0, installSource: "xbox")
        }
    }

    // MARK: Catalogue

    /// Refreshes the cloud & PC catalogue when stale (or when forced). Safe to call often.
    func refreshCatalog(force: Bool = false) {
        lock.lock()
        let now = Date()
        let stale = fetchedAt.map { now.timeIntervalSince($0) > Self.cacheLifetime } ?? true
        // Un échec précédent est retenté régulièrement pour ne jamais rester bloqué sur un vieux cache.
        let retryDue = lastError.isEmpty == false &&
            (lastAttempt.map { now.timeIntervalSince($0) > Self.failureRetryLifetime } ?? true)
        guard !fetching, force || stale || retryDue || titles.isEmpty else { lock.unlock(); return }
        fetching = true; lastError = ""; lastAttempt = now
        lock.unlock()
        DispatchQueue.main.async { self.onUpdate?() }

        let group = DispatchGroup()
        var cloudIds: [String] = []
        var pcIds: [String] = []
        let idsLock = NSLock()

        // 1. Fetch Cloud SIGL
        group.enter()
        let cloudURL = URL(string: "https://catalog.gamepass.com/sigls/v2?id=\(Self.cloudSiglID)&language=\(Self.language)&market=\(Self.market)")!
        session.dataTask(with: cloudURL) { data, _, _ in
            defer { group.leave() }
            guard let data, let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
            var seen = Set<String>()
            let extracted = rows.compactMap { $0["id"] as? String }
                .filter { $0.range(of: "^[A-Z0-9]{12}$", options: .regularExpression) != nil && seen.insert($0).inserted }
            idsLock.lock(); cloudIds = extracted; idsLock.unlock()
        }.resume()

        // 2. Fetch PC SIGL
        group.enter()
        let pcURL = URL(string: "https://catalog.gamepass.com/sigls/v2?id=\(Self.pcSiglID)&language=\(Self.language)&market=\(Self.market)")!
        session.dataTask(with: pcURL) { data, _, _ in
            defer { group.leave() }
            guard let data, let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
            var seen = Set<String>()
            let extracted = rows.compactMap { $0["id"] as? String }
                .filter { $0.range(of: "^[A-Z0-9]{12}$", options: .regularExpression) != nil && seen.insert($0).inserted }
            idsLock.lock(); pcIds = extracted; idsLock.unlock()
        }.resume()

        group.notify(queue: .global(qos: .userInitiated)) { [weak self] in
            guard let self else { return }
            let cloudSet = Set(cloudIds)
            let pcSet = Set(pcIds)
            guard !cloudSet.isEmpty || !pcSet.isEmpty else {
                self.finish(nil, error: "Catalogue Xbox Game Pass injoignable. Réessayez plus tard.")
                return
            }
            var seen = Set<String>()
            var combinedIds: [String] = []
            for id in cloudIds where seen.insert(id).inserted {
                combinedIds.append(id)
            }
            for id in pcIds where seen.insert(id).inserted {
                combinedIds.append(id)
            }
            self.resolve(combinedIds, cloudSet: cloudSet, pcSet: pcSet)
        }
    }

    private func resolve(_ ids: [String], cloudSet: Set<String>, pcSet: Set<String>) {
        let batches = stride(from: 0, to: ids.count, by: 20).map { Array(ids[$0..<min($0 + 20, ids.count)]) }
        let group = DispatchGroup()
        let resultLock = NSLock()
        var resolved: [String: Title] = [:]
        for batch in batches {
            group.enter()
            var components = URLComponents(string: "https://displaycatalog.mp.microsoft.com/v7.0/products")!
            components.queryItems = [URLQueryItem(name: "bigIds", value: batch.joined(separator: ",")),
                                     URLQueryItem(name: "market", value: Self.market),
                                     URLQueryItem(name: "languages", value: Self.language)]
            session.dataTask(with: components.url!) { data, _, _ in
                defer { group.leave() }
                guard let data, let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let products = root["Products"] as? [[String: Any]] else { return }
                for p in products {
                    if let id = p["ProductId"] as? String,
                       let title = Self.parseProduct(p, hasCloud: cloudSet.contains(id), hasPC: pcSet.contains(id)) {
                        resultLock.lock(); resolved[id] = title; resultLock.unlock()
                    }
                }
            }.resume()
        }
        group.notify(queue: .global(qos: .utility)) { [weak self] in
            let ordered = ids.compactMap { resolved[$0] }
            self?.finish(ordered.isEmpty ? nil : ordered, error: ordered.isEmpty ? "Le catalogue Microsoft n’a renvoyé aucun jeu." : "")
        }
    }

    private static func parseProduct(_ product: [String: Any], hasCloud: Bool, hasPC: Bool) -> Title? {
        guard let id = product["ProductId"] as? String,
              let localized = (product["LocalizedProperties"] as? [[String: Any]])?.first,
              let name = localized["ProductTitle"] as? String, !name.isEmpty else { return nil }
        let images = localized["Images"] as? [[String: Any]] ?? []
        func image(_ purposes: [String]) -> String {
            for purpose in purposes {
                if let uri = images.first(where: { $0["ImagePurpose"] as? String == purpose })?["Uri"] as? String {
                    return uri.hasPrefix("//") ? "https:" + uri : uri
                }
            }
            return ""
        }
        let hero = image(["SuperHeroArt", "TitledHeroArt", "BoxArt"])
        let poster = image(["Poster", "BoxArt", "BrandedKeyArt"])
        let properties = product["Properties"] as? [String: Any]
        return Title(id: id, title: String(name.prefix(200)), imageURL: hero, portraitURL: poster,
                     developer: localized["DeveloperName"] as? String ?? "",
                     category: properties?["Category"] as? String ?? "",
                     hasCloud: hasCloud, hasPC: hasPC)
    }

    private func finish(_ list: [Title]?, error: String) {
        lock.lock()
        fetching = false
        lastError = error
        if let list {
            titles = list
            fetchedAt = Date()
            if let data = try? JSONEncoder().encode(CachedCatalog(fetchedAt: fetchedAt!, titles: list)) {
                try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: cacheURL, options: .atomic)
            }
        }
        lock.unlock()
        DispatchQueue.main.async { self.onUpdate?() }
    }

    // MARK: Microsoft account

    /// Reads the persistent WebKit cookie store used by the Xbox Cloud window. Main thread.
    func refreshSignInState() {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            let now = Date()
            // Jetons de session Microsoft (MSA) et Xbox Live réellement présents après sign-in.
            let sessionNames: Set<String> = ["MSPAuth", "MSPPre", "MSPProf", "PPLState", "RPSSAuth", "WLSSC", "__Host-MSAAUTH"]
            let connected = cookies.contains { cookie in
                let domain = cookie.domain.lowercased()
                let name = cookie.name
                let isXboxToken = name.hasPrefix("XBXXtk") || name.hasPrefix("XNXXtk")
                return (domain.hasSuffix("live.com") || domain.hasSuffix("xbox.com")) &&
                    (sessionNames.contains(name) || isXboxToken) &&
                    (cookie.expiresDate.map { $0 > now } ?? true)
            }
            self.lock.lock(); let changed = self.signedIn != connected; self.signedIn = connected; self.lock.unlock()
            if changed { self.onUpdate?() }
        }
    }

    /// Clears Microsoft & Xbox session cookies from the persistent WebKit store.
    func disconnect(completion: @escaping () -> Void) {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { completion(); return }
            let group = DispatchGroup()
            for cookie in cookies where cookie.domain.hasSuffix("live.com") || cookie.domain.hasSuffix("xbox.com") || cookie.domain.hasSuffix("microsoft.com") {
                group.enter()
                WKWebsiteDataStore.default().httpCookieStore.delete(cookie) { group.leave() }
            }
            group.notify(queue: .main) {
                self.lock.lock()
                self.signedIn = false
                self.lock.unlock()
                self.onUpdate?()
                completion()
            }
        }
    }

    // MARK: Launch

    func launch(titleID: String, completion: @escaping (Bool, String) -> Void) {
        let clean = titleID.replacingOccurrences(of: "xbox:", with: "")
        lock.lock(); let title = titles.first(where: { $0.id == clean }); lock.unlock()
        guard let title else {
            completion(false, "Jeu Xbox introuvable dans le catalogue Game Pass actuel.")
            return
        }
        if let cloudURL = title.cloudURL {
            open(cloudURL, isGameLaunch: true)
            completion(true, "Lancement de \(title.title) sur Xbox Cloud Gaming…")
        } else {
            NSWorkspace.shared.open(title.storeURL)
            completion(true, "Ouverture de la fiche Microsoft Store de \(title.title)…")
        }
    }

    func openCatalog(completion: @escaping (Bool, String) -> Void) {
        open(URL(string: "https://www.xbox.com/fr-FR/play")!)
        completion(true, "Ouverture d’Xbox Cloud Gaming…")
    }

    /// Only Microsoft/Xbox HTTPS URLs may be opened in the cloud window.
    static func isAllowedCloudURL(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "www.xbox.com" || host == "xbox.com" || host.hasSuffix(".xbox.com") ||
               host == "login.live.com" || host.hasSuffix(".live.com") || host == "login.microsoftonline.com"
    }

    private func open(_ url: URL, isGameLaunch: Bool = false) {
        if let onOpenCloud { onOpenCloud(url, isGameLaunch) } else { NSWorkspace.shared.open(url) }
    }
}
