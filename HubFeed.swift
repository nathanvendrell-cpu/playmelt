import Foundation

/// Flux de l'Accueil : actus et mises à jour des jeux de la bibliothèque, jeux offerts
/// sur Epic, sorties Steam. Sources publiques uniquement (aucune clé, aucun cookie, aucun
/// compte). La page web n'a pas d'accès réseau : tout passe par ici, puis par `onHubFeed`.
struct HubGameRef: Equatable {
    let gameID: String, title: String, store: String, appID: String, installed: Bool, lastPlayed: Double

    init?(_ object: Any) {
        guard let d = object as? [String: Any],
              let gameID = d["gameId"] as? String, !gameID.isEmpty, gameID.count <= 128,
              let title = d["title"] as? String, !title.isEmpty, title.count <= 200 else { return nil }
        self.gameID = gameID; self.title = title
        store = String((d["store"] as? String ?? "").prefix(16))
        appID = String((d["appId"] as? String ?? "").prefix(16))
        installed = d["installed"] as? Bool ?? false
        lastPlayed = (d["lastPlayed"] as? NSNumber)?.doubleValue ?? 0
    }
    init(gameID: String, title: String, store: String, appID: String, installed: Bool, lastPlayed: Double) {
        self.gameID = gameID; self.title = title; self.store = store; self.appID = appID; self.installed = installed; self.lastPlayed = lastPlayed
    }
    /// Identifiant Steam connu sans recherche (jeux Steam).
    var knownSteamAppID: Int? {
        guard store == "steam", let n = Int(appID), n > 0, n < 100_000_000 else { return nil }
        return n
    }
}

protocol HubTransport {
    func get(_ url: URL, completion: @escaping (Data?) -> Void)
}

final class URLSessionHubTransport: HubTransport {
    private let session: URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil
        config.timeoutIntervalForRequest = 12; config.timeoutIntervalForResource = 25
        config.httpAdditionalHeaders = ["User-Agent": "Playmelt"]
        session = URLSession(configuration: config)
    }
    func get(_ url: URL, completion: @escaping (Data?) -> Void) {
        session.dataTask(with: url) { data, response, _ in
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            completion(ok ? data : nil)
        }.resume()
    }
}

enum HubText {
    /// Titre comparable : minuscules, sans ™ ® ©, ponctuation et espaces multiples.
    static func normalized(_ title: String) -> String {
        let folded = title.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en"))
        let kept = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }
    /// Résumé lisible d'une annonce Steam (BBCode, HTML, liens et marqueurs retirés).
    static func summary(_ raw: String, limit: Int = 180) -> String {
        var s = raw
        for pattern in ["\\[img[^\\]]*\\][^\\[]*\\[/img\\]", "\\{STEAM_CLAN_IMAGE\\}[^\\s]*", "\\[/?[a-zA-Z0-9*]+[^\\]]*\\]", "<[^>]+>", "https?://\\S+"] {
            s = s.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "’").replacingOccurrences(of: "&nbsp;", with: " ")
        s = s.replacingOccurrences(of: "([,.!?;:])(\\p{Lu})", with: "$1 $2", options: .regularExpression)
        s = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard s.count > limit else { return s }
        let cut = s.prefix(limit)
        return (cut.range(of: " ", options: .backwards).map { String(cut[..<$0.lowerBound]) } ?? String(cut)) + "…"
    }
}

final class HubFeedStore {
    static let maxGames = 24
    static let newsPerGame = 5
    static let staleAfter: TimeInterval = 3 * 3600
    static let minInterval: TimeInterval = 10 * 60

    private let transport: HubTransport
    private let cacheURL: URL?
    private let now: () -> Date
    private let queue = DispatchQueue(label: "fr.playmelt.hubfeed", qos: .utility)
    private var appIDCache: [String: Int] = [:]   // titre normalisé → appid (0 = introuvable)
    /// Lu et écrit sur la file principale (l'écriture finale passe par la file principale).
    private(set) var feed: [String: Any] = [:]
    private var running = false
    private var lastAttempt: Date?

    init(transport: HubTransport = URLSessionHubTransport(), cacheURL: URL? = HubFeedStore.defaultCacheURL(), now: @escaping () -> Date = Date.init) {
        self.transport = transport; self.cacheURL = cacheURL; self.now = now
        if let cacheURL, let data = try? Data(contentsOf: cacheURL),
           let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            feed = saved["feed"] as? [String: Any] ?? [:]
            appIDCache = (saved["appIDs"] as? [String: Int]) ?? [:]
        }
    }

    static func defaultCacheURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Playmelt", isDirectory: true).appendingPathComponent("hub-feed.json")
    }

    var fetchedAt: Date? { (feed["fetchedAt"] as? Double).map { Date(timeIntervalSince1970: $0) } }

    /// Vrai si une actualisation est utile : cache absent ou vieux, et pas d'essai récent.
    func shouldRefresh(force: Bool) -> Bool {
        if running { return false }
        if let lastAttempt, now().timeIntervalSince(lastAttempt) < (force ? 60 : Self.minInterval) { return false }
        guard !force, let fetchedAt else { return true }
        return now().timeIntervalSince(fetchedAt) > Self.staleAfter
    }

    /// Jeux suivis : installés d'abord, puis les plus récemment joués.
    static func selection(_ games: [HubGameRef]) -> [HubGameRef] {
        var seen = Set<String>()
        return games.sorted { ($0.installed ? 1 : 0, $0.lastPlayed) > ($1.installed ? 1 : 0, $1.lastPlayed) }
            .filter { ($0.installed || $0.lastPlayed > 0) && seen.insert(HubText.normalized($0.title)).inserted }
            .prefix(maxGames).map { $0 }
    }

    func refresh(games: [HubGameRef], force: Bool, completion: @escaping ([String: Any]) -> Void) {
        guard shouldRefresh(force: force) else { return }
        running = true; lastAttempt = now()
        let selected = Self.selection(games)
        queue.async { [weak self] in
            guard let self else { return }
            self.resolveAppIDs(selected) { resolved in
                self.collect(resolved) { result in
                    self.queue.async {
                        self.save(result)
                        DispatchQueue.main.async { self.feed = result; self.running = false; completion(result) }
                    }
                }
            }
        }
    }

    // MARK: - Identifiants Steam

    private func resolveAppIDs(_ games: [HubGameRef], completion: @escaping ([(HubGameRef, Int)]) -> Void) {
        let group = DispatchGroup(); let lock = NSLock()
        var resolved: [(HubGameRef, Int)] = []
        for game in games {
            if let id = game.knownSteamAppID { lock.lock(); resolved.append((game, id)); lock.unlock(); continue }
            let key = HubText.normalized(game.title)
            lock.lock(); let cached = appIDCache[key]; lock.unlock()
            if let cached { if cached > 0 { lock.lock(); resolved.append((game, cached)); lock.unlock() }; continue }
            var c = URLComponents(string: "https://store.steampowered.com/api/storesearch/")!
            c.queryItems = [.init(name: "term", value: game.title), .init(name: "cc", value: "FR"), .init(name: "l", value: "french")]
            guard let url = c.url else { continue }
            group.enter()
            transport.get(url) { [weak self] data in
                let id = Self.matchSearch(data, title: game.title)
                lock.lock()
                if let id { resolved.append((game, id)) }
                if data != nil { self?.appIDCache[key] = id ?? 0 }
                lock.unlock(); group.leave()
            }
        }
        group.notify(queue: queue) {
            let order = Dictionary(uniqueKeysWithValues: games.enumerated().map { ($1.gameID, $0) })
            completion(resolved.sorted { (order[$0.0.gameID] ?? 0) < (order[$1.0.gameID] ?? 0) })
        }
    }

    /// Correspondance stricte du titre : on préfère ne rien afficher qu'un mauvais jeu.
    static func matchSearch(_ data: Data?, title: String) -> Int? {
        guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else { return nil }
        let wanted = HubText.normalized(title)
        return items.first { HubText.normalized($0["name"] as? String ?? "") == wanted }.flatMap { ($0["id"] as? NSNumber)?.intValue }
    }

    // MARK: - Collecte

    private func collect(_ games: [(HubGameRef, Int)], completion: @escaping ([String: Any]) -> Void) {
        let group = DispatchGroup(); let lock = NSLock()
        var items: [[String: Any]] = [], art: [String: Any] = [:], free: [[String: Any]] = [], releases: [[String: Any]] = []
        for (game, appID) in games {
            art[game.gameID] = Self.artwork(appID: appID)
            var c = URLComponents(string: "https://api.steampowered.com/ISteamNews/GetNewsForApp/v2/")!
            c.queryItems = [.init(name: "appid", value: String(appID)), .init(name: "count", value: String(Self.newsPerGame)),
                            .init(name: "maxlength", value: "600"), .init(name: "feeds", value: "steam_community_announcements")]
            guard let url = c.url else { continue }
            group.enter()
            transport.get(url) { data in
                let parsed = Self.parseNews(data, game: game, appID: appID)
                lock.lock(); items += parsed; lock.unlock(); group.leave()
            }
        }
        group.enter()
        transport.get(URL(string: "https://store-site-backend-static-ipv4.ak.epicgames.com/freeGamesPromotions?locale=fr&country=FR&allowCountries=FR")!) { [now] data in
            let parsed = Self.parseEpicFree(data, now: now())
            lock.lock(); free = parsed; lock.unlock(); group.leave()
        }
        group.enter()
        transport.get(URL(string: "https://store.steampowered.com/api/featuredcategories?cc=fr&l=french")!) { data in
            let parsed = Self.parseReleases(data)
            lock.lock(); releases = parsed; lock.unlock(); group.leave()
        }
        group.notify(queue: queue) { [now] in
            items.sort { ($0["date"] as? Double ?? 0) > ($1["date"] as? Double ?? 0) }
            completion(["fetchedAt": now().timeIntervalSince1970, "items": Array(items.prefix(80)), "art": art,
                        "freeGames": free, "releases": releases])
        }
    }

    static func artwork(appID: Int) -> [String: Any] {
        let base = "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/"
        return ["appId": appID, "hero": base + "library_hero.jpg", "logo": base + "logo.png", "header": base + "header.jpg"]
    }

    static func parseNews(_ data: Data?, game: HubGameRef, appID: Int) -> [[String: Any]] {
        guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = (json["appnews"] as? [String: Any])?["newsitems"] as? [[String: Any]] else { return [] }
        return list.compactMap { n in
            guard let gid = n["gid"] as? String, gid.allSatisfy(\.isNumber), let title = n["title"] as? String, !title.isEmpty,
                  let date = (n["date"] as? NSNumber)?.doubleValue else { return nil }
            let tags = n["tags"] as? [String] ?? []
            return ["id": "\(appID)-\(gid)", "gameId": game.gameID, "gameTitle": game.title, "appId": appID,
                    "kind": tags.contains("patchnotes") ? "update" : "news",
                    "title": String(title.prefix(160)), "summary": HubText.summary(n["contents"] as? String ?? ""),
                    "date": date, "url": "https://store.steampowered.com/news/app/\(appID)/view/\(gid)"]
        }
    }

    static func parseEpicFree(_ data: Data?, now: Date) -> [[String: Any]] {
        guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = ((((json["data"] as? [String: Any])?["Catalog"] as? [String: Any])?["searchStore"] as? [String: Any])?["elements"]) as? [[String: Any]] else { return [] }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        func date(_ s: Any?) -> Date? { (s as? String).flatMap { iso.date(from: $0) ?? isoPlain.date(from: $0) } }
        var out: [[String: Any]] = []
        for e in elements {
            guard let title = e["title"] as? String, let promos = e["promotions"] as? [String: Any] else { continue }
            func offers(_ key: String) -> [[String: Any]] { (promos[key] as? [[String: Any]] ?? []).flatMap { $0["promotionalOffers"] as? [[String: Any]] ?? [] } }
            // Gratuit = remise de 100 % (les autres promos du flux ne sont pas des cadeaux).
            let freeOnly = { (o: [String: Any]) -> Bool in ((o["discountSetting"] as? [String: Any])?["discountPercentage"] as? NSNumber)?.intValue == 0 }
            let current = offers("promotionalOffers").first(where: freeOnly)
            let upcoming = offers("upcomingPromotionalOffers").first(where: freeOnly)
            guard let offer = current ?? upcoming, let start = date(offer["startDate"]), let end = date(offer["endDate"]), end > now else { continue }
            let images = e["keyImages"] as? [[String: Any]] ?? []
            let image = ["OfferImageWide", "DieselStoreFrontWide", "Thumbnail"].lazy.compactMap { t in images.first { $0["type"] as? String == t }?["url"] as? String }.first ?? ""
            let mappings = ((e["catalogNs"] as? [String: Any])?["mappings"] as? [[String: Any]]) ?? []
            let slug = (mappings.first?["pageSlug"] as? String) ?? (e["productSlug"] as? String) ?? ""
            let safeSlug = slug.range(of: "^[a-z0-9-]{1,120}$", options: .regularExpression) != nil ? slug : ""
            out.append(["title": String(title.prefix(120)), "image": image.hasPrefix("https://") ? image : "",
                        "start": start.timeIntervalSince1970, "end": end.timeIntervalSince1970,
                        "current": current != nil && start <= now,
                        "url": safeSlug.isEmpty ? "https://store.epicgames.com/fr/free-games" : "https://store.epicgames.com/fr/p/\(safeSlug)"])
        }
        return out.sorted { (($0["current"] as? Bool) == true ? 0 : 1, $0["start"] as? Double ?? 0) < (($1["current"] as? Bool) == true ? 0 : 1, $1["start"] as? Double ?? 0) }
    }

    static func parseReleases(_ data: Data?) -> [[String: Any]] {
        guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = (json["new_releases"] as? [String: Any])?["items"] as? [[String: Any]] else { return [] }
        var seen = Set<Int>()
        return items.compactMap { i -> [String: Any]? in
            guard let id = (i["id"] as? NSNumber)?.intValue, seen.insert(id).inserted, let name = i["name"] as? String else { return nil }
            let image = (i["header_image"] as? String) ?? (i["large_capsule_image"] as? String) ?? ""
            let cents = (i["final_price"] as? NSNumber)?.intValue ?? 0
            return ["appId": id, "name": String(name.prefix(120)), "priceCents": cents, "currency": i["currency"] as? String ?? "EUR",
                    "image": image.hasPrefix("https://") ? image : "", "url": "https://store.steampowered.com/app/\(id)/"]
        }.prefix(6).map { $0 }
    }

    private func save(_ feed: [String: Any]) {
        guard let cacheURL else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: ["feed": feed, "appIDs": appIDCache]) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    /// Liens ouvrables depuis l'Accueil : uniquement les boutiques, jamais une URL arbitraire.
    static func allowedLink(_ raw: String) -> URL? {
        guard let url = URL(string: raw), url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              let host = url.host?.lowercased() else { return nil }
        return ["store.steampowered.com", "store.epicgames.com"].contains(host) ? url : nil
    }
}
