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

/// Full announcements are fetched on demand; the home feed keeps its small summaries.
enum HubArticle {
    static func request(for item: [String: Any]) -> URL? {
        guard let raw = item["url"] as? String, let url = HubFeedStore.allowedLink(raw),
              url.host == "store.steampowered.com",
              let appID = (item["appId"] as? NSNumber)?.intValue, appID > 0,
              let date = (item["date"] as? NSNumber)?.doubleValue, date.isFinite, date > 0, date < 10_000_000_000,
              url.path == "/news/app/\(appID)/view/\(url.lastPathComponent)",
              !url.lastPathComponent.isEmpty, url.lastPathComponent.allSatisfy(\.isNumber) else { return nil }
        var components = URLComponents(string: "https://api.steampowered.com/ISteamNews/GetNewsForApp/v2/")!
        components.queryItems = [URLQueryItem(name: "appid", value: String(appID)),
            .init(name: "count", value: "5"), .init(name: "maxlength", value: "0"),
            .init(name: "enddate", value: String(Int(date) + 1)),
            .init(name: "feeds", value: "steam_community_announcements")]
        return components.url
    }
    static func contents(_ data: Data?, matching item: [String: Any]) -> String? {
        guard let raw = item["url"] as? String, let gid = URL(string: raw)?.lastPathComponent,
              let data, data.count <= 4_000_000,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let news = (root["appnews"] as? [String: Any])?["newsitems"] as? [[String: Any]],
              let content = news.first(where: { $0["gid"] as? String == gid })?["contents"] as? String,
              !content.isEmpty, content.count <= 250_000 else { return nil }
        return content
    }
    static func escape(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
    private static func link(_ raw: String) -> String? {
        let value = raw.replacingOccurrences(of: "{STEAM_CLAN_IMAGE}", with: "https://clan.fastly.steamstatic.com/images/").replacingOccurrences(of:"&amp;", with:"&")
        guard let url = URL(string:value), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil, url.port == nil else { return nil }
        return escape(url.absoluteString)
    }
    private static func formatted(_ raw: String) -> String {
        var text = escape(raw)
        for (pattern, replacement) in [
            ("\\[/?(?:list|olist)\\]", "\n"), ("\\[\\*\\]", "\n• "),
            ("\\[h[1-6]\\]", "\n<strong class=\"section-title\">"), ("\\[/h[1-6]\\]", "</strong>\n"),
            ("\\[b\\]", "<strong>"), ("\\[/b\\]", "</strong>"),
            ("\\[i\\]", "<em>"), ("\\[/i\\]", "</em>"),
            ("\\[/?[a-zA-Z][^\\]]*\\]", "")
        ] {
            if let regex = try? NSRegularExpression(pattern:pattern, options:[.caseInsensitive,.dotMatchesLineSeparators]) {
                text = regex.stringByReplacingMatches(in:text, range:NSRange(text.startIndex...,in:text), withTemplate:replacement)
            }
        }
        return text
    }
    static func body(_ raw: String) -> String {
        let pattern = #"\[img[^\]]*\](.*?)\[/img\]|\[url=([^\]]+)\](.*?)\[/url\]|https://[^\s<>\[\]]+"#
        guard let regex = try? NSRegularExpression(pattern:pattern, options:[.caseInsensitive,.dotMatchesLineSeparators]) else { return formatted(raw) }
        var output = "", cursor = raw.startIndex
        for match in regex.matches(in:raw,range:NSRange(raw.startIndex...,in:raw)) {
            guard let range = Range(match.range,in:raw) else { continue }
            output += formatted(String(raw[cursor..<range.lowerBound]))
            if let image = Range(match.range(at:1),in:raw) {
                if let url = link(String(raw[image])) { output += "<figure><img loading=\"lazy\" referrerpolicy=\"no-referrer\" alt=\"Visuel de l’annonce\" src=\"\(url)\"></figure>" }
            } else if let target = Range(match.range(at:2),in:raw), let label = Range(match.range(at:3),in:raw) {
                let label = formatted(String(raw[label]))
                if let url = link(String(raw[target])) { output += "<a href=\"\(url)\">\(label) ↗</a>" } else { output += label }
            } else {
                let value = String(raw[range])
                output += link(value).map { "<a href=\"\($0)\">\(escape(value))</a>" } ?? escape(value)
            }
            cursor = range.upperBound
        }
        return (output + formatted(String(raw[cursor...]))).replacingOccurrences(of:"\\n[ \t]*\\n(?:[ \t]*\\n)+",with:"\n\n",options:.regularExpression)
    }
    static func page(item: [String: Any], contents: String) -> String {
        let title = escape(item["title"] as? String ?? "Actualité"), game = escape(item["gameTitle"] as? String ?? "Steam")
        let kind = item["kind"] as? String == "update" ? "Correctif" : "Actualité"
        let rawTheme = item["theme"] as? [String:String] ?? [:]
        func tone(_ key:String,_ fallback:String)->String { guard let v=rawTheme[key], v.range(of:"^#[0-9a-fA-F]{6}$",options:.regularExpression) != nil else {return fallback};return v }
        let accent=tone("accent","#edab7e"), background=tone("background","#141a20"), surface=tone("surface","#222b34"), muted=tone("muted","#b8c4cf")
        let appID = (item["appId"] as? NSNumber)?.intValue ?? 0
        let base = "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/\(appID)/"
        let date = Date(timeIntervalSince1970:item["date"] as? Double ?? 0).formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier:"fr_FR")))
        let reading = max(1, contents.split(whereSeparator:{$0.isWhitespace}).count / 220)
        let related = (item["related"] as? [[String:Any]] ?? []).compactMap { other -> String? in
            guard let url = other["url"] as? String, let safe = link(url) else { return nil }
            return "<a class=\"related-item\" href=\"\(safe)\"><span>\(other["kind"] as? String == "update" ? "Correctif" : "Actualité")</span><b>\(escape(other["title"] as? String ?? ""))</b><i>Lire l’annonce →</i></a>"
        }.joined()
        return """
        <!doctype html><html lang="fr"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
        <title>\(title)</title><style>
        :root{color-scheme:light}*{box-sizing:border-box}body{margin:0;background:#eef1f4;color:#242d35;font:15px/1.75 -apple-system,BlinkMacSystemFont,sans-serif}a{color:#bb4f28;text-underline-offset:4px}a:hover{color:#e66c39}a:focus-visible{outline:3px solid #ec7a42;outline-offset:5px}
        .hero{position:relative;min-height:440px;display:flex;align-items:end;background:#16212c;color:#fff;overflow:hidden}.hero>img{position:absolute;inset:0;width:100%;height:100%;object-fit:cover;object-position:center 30%}.hero:after{content:'';position:absolute;inset:0;background:linear-gradient(0deg,#101c2cf5,transparent 120%),linear-gradient(90deg,#101b29b3,transparent)}
        .hero-copy{position:relative;z-index:1;width:100%;max-width:1240px;margin:auto;padding:110px 48px 62px;display:flex;gap:30px;align-items:end}.cover{width:112px;border-radius:10px;box-shadow:0 18px 45px #0008;transform:perspective(650px) rotateY(9deg)}.hero-copy>div{max-width:850px}.eyebrow{font-size:11px;letter-spacing:.12em;text-transform:uppercase;color:#bfcbd6}.eyebrow b{background:#f17a43;color:white;padding:5px 9px;border-radius:5px;margin-right:10px;font-weight:600}h1{font-size:clamp(28px,4vw,52px);line-height:1.07;letter-spacing:-.04em;margin:18px 0 16px;text-wrap:balance}.hero-meta{font-size:12px;color:#c5d0db;display:flex;gap:20px}
        .layout{max-width:1240px;margin:-24px auto 70px;padding:0 48px;display:grid;grid-template-columns:minmax(0,1fr) 250px;gap:24px;position:relative;z-index:2}article{padding:40px 44px;border:1px solid #e0e6eb;border-radius:18px;background:#fff;box-shadow:0 12px 44px #1b283808}.body{white-space:pre-wrap;overflow-wrap:anywhere}.body strong{font-weight:700;color:#182c40}.body .section-title{display:block;font-size:24px;line-height:1.25;letter-spacing:-.025em;border-bottom:1px solid #e5eaf0;padding:8px 0 14px}.body figure{margin:22px -12px;white-space:normal}.body img{width:100%;height:auto;display:block;border-radius:12px}.body a{font-weight:550}.editor{display:flex;gap:12px;align-items:center;border-bottom:1px solid #edf0f3;margin-bottom:24px;padding-bottom:20px;font-size:12px;color:#80909b}.editor b{display:block;color:#34485b}.editor .seal{display:grid;place-items:center;width:38px;height:38px;border-radius:50%;background:#f5ede5;color:#bc6d40;font-size:18px}
        aside{padding-top:42px}.game-card{overflow:hidden;border-radius:15px;background:#152235;color:white;box-shadow:0 12px 28px #12223618}.game-card img{display:block;width:100%}.game-card div{padding:18px}.game-card b{display:block;font-size:17px;line-height:1.25}.game-card a{display:block;margin-top:16px;color:#ffb58d;font-size:12px;text-decoration:none}.related{margin-top:28px}.related h2{font-size:12px;letter-spacing:.08em;text-transform:uppercase;color:#778591}.related-item{display:block;text-decoration:none;color:#233548;border-top:1px solid #dbe2e8;padding:18px 0}.related-item span{font-size:10px;color:#b8623c;text-transform:uppercase;letter-spacing:.09em}.related-item b{display:block;font-size:14px;line-height:1.4;margin:6px 0}.related-item i{font-size:11px;font-style:normal;color:#7e8c99}footer{border-top:1px solid #e1e5eb;margin-top:36px;padding-top:20px;color:#8996a0;font-size:11px}
        @media(max-width:850px){.layout{grid-template-columns:1fr;padding:0 24px}.hero-copy{padding:80px 24px 50px}.cover{width:80px}aside{padding-top:0;display:grid;grid-template-columns:1fr 1fr;gap:24px}.related{margin-top:0}article{padding:28px}.hero{min-height:350px}}
        :root{color-scheme:dark;--accent:\(accent);--game-bg:\(background);--game-surface:\(surface);--game-muted:\(muted)}
        body{background:radial-gradient(ellipse at 85% 8%,color-mix(in srgb,var(--accent) 14%,transparent),transparent 48%),var(--game-bg);color:#e6e8eb}
        body:before{content:'';position:fixed;inset:0;background:linear-gradient(180deg,transparent,var(--game-bg) 72%);pointer-events:none;z-index:-1}
        a,.game-card a{color:var(--accent)}a:hover{color:white}.hero{background:var(--game-bg)}.hero:after{background:linear-gradient(0deg,var(--game-bg),transparent 100%),linear-gradient(90deg,#0009,transparent)}
        .eyebrow b{background:var(--accent);color:#181b1f}.eyebrow,.hero-meta{color:#d7dadd}.layout{gap:34px;margin-top:-8px}article{background:linear-gradient(135deg,color-mix(in srgb,var(--accent) 5%,var(--game-surface)),var(--game-surface));border:1px solid color-mix(in srgb,var(--accent) 15%,transparent);box-shadow:0 24px 70px #0003;color:#e6e8eb}
        .body{font-size:16px;line-height:1.9}.body strong,.editor b{color:#f7f7f8}.body .section-title{color:var(--accent);border-color:#ffffff18}.editor{color:var(--game-muted);border-color:#ffffff16}.editor .seal{background:color-mix(in srgb,var(--accent) 13%,transparent);color:var(--accent)}
        .game-card{background:var(--game-surface);border:1px solid #ffffff12;box-shadow:0 20px 50px #0003}.related h2,.related-item i,footer{color:var(--game-muted)}.related-item{color:#e3e6e9;border-color:#ffffff18}.related-item span{color:var(--accent)}.related-item:hover{color:white}.related-item:hover b{text-decoration:underline;text-decoration-color:var(--accent)}footer{border-color:#ffffff16}
        .hero{min-height:360px}.hero-copy{padding-top:80px;padding-bottom:48px;gap:24px}h1{font-size:clamp(28px,3.7vw,46px);line-height:1.12;letter-spacing:-.035em}.layout{max-width:1160px;grid-template-columns:minmax(0,1fr) 230px;gap:28px}article{padding:30px 36px}.body{font-size:16px;line-height:1.75;max-width:68ch;letter-spacing:.002em}.body .section-title{font-size:22px;margin-top:8px;padding-bottom:12px}.editor{margin-bottom:20px;padding-bottom:18px}.hero-meta{flex-wrap:wrap;gap:8px 20px}.related-item{padding:15px 0}.body figure{margin:18px 0}.cover{width:96px}@media(max-width:850px){.layout{grid-template-columns:1fr}.hero{min-height:300px}.hero-copy{padding:64px 24px 38px}.body{font-size:15px}article{padding:24px}.cover{width:72px}}
        </style><header class="hero"><img src="\(base)library_hero.jpg" alt=""><div class="hero-copy"><img class="cover" src="\(base)library_600x900.jpg" alt="\(game)"><div><div class="eyebrow"><b>\(kind)</b>\(game)</div><h1>\(title)</h1><div class="hero-meta"><span>\(date)</span><span>\(reading) min de lecture</span><span>Annonce officielle</span></div></div></div></header>
        <main class="layout"><article><div class="editor"><span class="seal">✓</span><div><b>\(game)</b>Publication de l’éditeur · Steam</div></div><div class="body">\(body(contents))</div><footer>Texte et visuels de l’éditeur · consultés dans Playmelt</footer></article><aside><section class="game-card"><img src="\(base)header.jpg" alt=""><div><b>\(game)</b><a href="https://store.steampowered.com/app/\(appID)/">Découvrir le jeu →</a></div></section><section class="related"><h2>Autour du jeu</h2>\(related)</section></aside></main></html>
        """
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
        if feed["offerSources"] == nil { return true }
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
        var offers: [[String:Any]] = [], offerSources: [String:String] = [:]
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
            lock.lock(); free = parsed; offerSources["epic"] = data == nil ? "unavailable" : "free-only"; lock.unlock(); group.leave()
        }
        group.enter()
        transport.get(URL(string: "https://store.steampowered.com/api/featuredcategories?cc=fr&l=french")!) { data in
            let parsed = Self.parseReleases(data)
            lock.lock(); releases = parsed; offers += OffersCatalog.steam(data); offerSources["steam"] = data == nil ? "unavailable" : "ready"; lock.unlock(); group.leave()
        }
        for (store, url, parser) in [("gog", OffersCatalog.gogURL, OffersCatalog.gog), ("xbox", OffersCatalog.xboxURL, OffersCatalog.xbox)] {
            group.enter()
            transport.get(url) { data in
                let parsed = parser(data)
                lock.lock(); offers += parsed; offerSources[store] = data == nil || parsed.isEmpty ? "unavailable" : "ready"; lock.unlock(); group.leave()
            }
        }
        group.notify(queue: queue) { [now] in
            items.sort { ($0["date"] as? Double ?? 0) > ($1["date"] as? Double ?? 0) }
            completion(["fetchedAt": now().timeIntervalSince1970, "items": Array(items.prefix(80)), "art": art,
                        "freeGames": free, "releases": releases, "offers": offers.filter { ($0["end"] as? Double ?? 0) == 0 || ($0["end"] as? Double ?? 0) > now().timeIntervalSince1970 }, "offerSources": offerSources])
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
        if host == "7agency.fr", url.path.hasPrefix("/Playmelt/") {return url}
        return ["store.steampowered.com", "store.epicgames.com", "www.gog.com", "www.xbox.com", "luna.amazon.fr", "www.ea.com", "www.ubisoft.com", "eu.shop.battle.net", "itch.io", "www.humblebundle.com", "play.geforcenow.com"].contains(host) ? url : nil
    }
}
