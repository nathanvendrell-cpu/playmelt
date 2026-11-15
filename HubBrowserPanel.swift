import AppKit
import WebKit

/// Remote content stays in the existing app window and never receives the
/// local library's script bridge or file access.
final class HubBrowserPanel: NSObject, WKNavigationDelegate, WKUIDelegate {
    static let sharedProcessPool = WKProcessPool()
    static let browserStoreID = UUID(uuidString: "8BCDA5D0-5533-4672-A758-B265EF735D87")!
    static let sharedStore = WKWebsiteDataStore(forIdentifier: browserStoreID)
    var onXboxCloud:((URL)->Void)?
    var authorizeCloud:((@escaping(Bool,String)->Void)->Void)?
    var onGeForceSessionCompleted: ((Int64) -> Void)?
    private var geforceStartTime: Date?
    private var panel: NSView?
    private var browser: WKWebView?
    private let status = NSTextField(labelWithString: "")
    private var previous: NSButton?
    private var next: NSButton?
    private var article: [String: Any]?
    private var articleTask: URLSessionDataTask?
    private var themeTask: URLSessionDataTask?
    private var generation = UUID()

    func open(_ url: URL, article: [String: Any]? = nil, over localView: WKWebView) {
        closePanel()
        if url.host?.contains("geforcenow.com") == true {
            geforceStartTime = Date()
        }
        guard let parent = localView.superview else { return }
        let panel = NSVisualEffectView()
        panel.material = .windowBackground; panel.state = .active
        if article != nil { panel.appearance = NSAppearance(named: .darkAqua) }
        panel.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: parent.topAnchor, constant: 52),
            panel.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        ])
        let config = WKWebViewConfiguration()
        config.processPool = Self.sharedProcessPool
        config.websiteDataStore = Self.sharedStore
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let browser = WKWebView(frame: .zero, configuration: config)
        browser.navigationDelegate = self; browser.uiDelegate = self
        browser.allowsBackForwardNavigationGestures = true
        let close = NSButton(title: "Retour à Playmelt", target: self, action: #selector(closePanel))
        close.keyEquivalent = "\u{1b}"
        let previous = NSButton(title: "←", target: self, action: #selector(goBack))
        previous.setAccessibilityLabel("Page précédente")
        let next = NSButton(title: "→", target: self, action: #selector(goForward))
        next.setAccessibilityLabel("Page suivante")
        let reload = NSButton(title: "Actualiser", target: self, action: #selector(reloadPage))
        status.lineBreakMode = .byTruncatingMiddle
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [close, previous, next, status, reload])
        bar.spacing = 12; bar.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        for view in [bar, browser] { view.translatesAutoresizingMaskIntoConstraints = false; panel.addSubview(view) }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: panel.topAnchor), bar.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: panel.trailingAnchor), bar.heightAnchor.constraint(equalToConstant: 52),
            browser.topAnchor.constraint(equalTo: bar.bottomAnchor), browser.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            browser.trailingAnchor.constraint(equalTo: panel.trailingAnchor), browser.bottomAnchor.constraint(equalTo: panel.bottomAnchor)
        ])
        self.panel = panel; self.browser = browser; self.previous = previous; self.next = next
        status.stringValue = "Chargement · " + (url.host ?? "")
        if let article, HubArticle.request(for: article) != nil {
            self.article = article; loadArticle(article)
        } else { browser.load(URLRequest(url: url)) }
    }
    @objc func closePanel() {
        if let start = geforceStartTime {
            geforceStartTime = nil
            let elapsed = Int64(Date().timeIntervalSince(start))
            if elapsed > 5 {
                onGeForceSessionCompleted?(elapsed)
            }
        }
        generation = UUID(); articleTask?.cancel(); articleTask = nil; themeTask?.cancel(); themeTask = nil; article = nil
        browser?.stopLoading(); browser?.navigationDelegate = nil; browser?.uiDelegate = nil
        browser?.removeFromSuperview(); panel?.removeFromSuperview()
        browser = nil; panel = nil; previous = nil; next = nil
    }
    @objc private func goBack() { browser?.goBack() }
    @objc private func goForward() { browser?.goForward() }
    @objc private func reloadPage() {
        if let article, browser?.url?.scheme != "https" { loadArticle(article) } else { browser?.reload() }
    }
    private func loadArticle(_ item: [String: Any]) {
        guard let url = HubArticle.request(for: item) else { return }
        articleTask?.cancel(); themeTask?.cancel(); generation = UUID(); let token = generation
        previous?.isEnabled = false; next?.isEnabled = false
        browser?.loadHTMLString(HubArticle.page(item: item, contents: "Chargement de l’article…"), baseURL: nil)
        var request = URLRequest(url: url); request.timeoutInterval = 20
        request.setValue("Playmelt", forHTTPHeaderField: "User-Agent")
        articleTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            let contents = ok ? HubArticle.contents(data, matching: item) : nil
            DispatchQueue.main.async {
                guard let self, self.generation == token, self.browser != nil else { return }
                self.articleTask = nil
                let text = contents ?? "L’article n’a pas pu être chargé. Utilisez Actualiser pour réessayer."
                let appID = (item["appId"] as? NSNumber)?.intValue ?? 0
                let art = URL(string:"https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/\(appID)/header.jpg")!
                self.themeTask = GameTheme.load(art) { [weak self] theme in
                    DispatchQueue.main.async {
                        guard let self, self.generation == token else { return }
                        var themed = item; themed["theme"] = theme
                        self.browser?.loadHTMLString(HubArticle.page(item: themed, contents: text), baseURL: nil)
                        self.status.stringValue = "Steam · " + (item["gameTitle"] as? String ?? "Actualité")
                    }
                }
            }
        }
        articleTask?.resume()
    }
    static func permits(_ url: URL?) -> Bool {
        guard let url else { return false }
        if url.absoluteString == "about:blank" { return true }
        guard let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              url.host != nil, url.user == nil, url.password == nil, url.port == nil else { return false }
        return true
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let currentHost = webView.url?.host, currentHost.contains("geforcenow.com"),
           let targetHost = action.request.url?.host, !targetHost.contains("geforcenow.com") {
            if let start = geforceStartTime {
                geforceStartTime = nil
                let elapsed = Int64(Date().timeIntervalSince(start))
                if elapsed > 5 {
                    onGeForceSessionCompleted?(elapsed)
                }
            }
        } else if let targetHost = action.request.url?.host, targetHost.contains("geforcenow.com"), geforceStartTime == nil {
            geforceStartTime = Date()
        }
        if let url=action.request.url,XboxCloudRoute.isCloudPage(url),action.targetFrame?.isMainFrame != false,let onXboxCloud {
            decisionHandler(.cancel);DispatchQueue.main.async{onXboxCloud(url)};return
        }
        if let url=action.request.url,AccountProtectedAction.embeddedCloudCapability(for:url) != nil {
            guard let authorizeCloud else {status.stringValue="Accès Playmelt non vérifié.";decisionHandler(.cancel);return}
            let current=generation
            status.stringValue="Vérification de votre accès Playmelt…"
            authorizeCloud { [weak self] allowed,message in
                guard let self,self.generation==current,self.browser===webView else{decisionHandler(.cancel);return}
                if !allowed {self.status.stringValue=message}
                decisionHandler(allowed ? .allow : .cancel)
            }
            return
        }
        if let url=action.request.url,Self.permits(url),["checkout.stripe.com","billing.stripe.com"].contains(url.host ?? ""),action.targetFrame?.isMainFrame != false {
            decisionHandler(.cancel);NSWorkspace.shared.open(url);return
        }
        if action.request.url?.absoluteString == "about:blank" {
            decisionHandler(.allow); return
        }
        if action.navigationType == .linkActivated,
           var related = (article?["related"] as? [[String:Any]])?.first(where: { $0["url"] as? String == action.request.url?.absoluteString }) {
            var previous = article!
            let siblings = (previous.removeValue(forKey:"related") as? [[String:Any]] ?? []).filter { $0["url"] as? String != related["url"] as? String }.map { item in var item=item;item.removeValue(forKey:"related");return item }
            related["related"] = [previous] + siblings
            article = related; decisionHandler(.cancel); loadArticle(related); return
        }
        guard Self.permits(action.request.url) else {
            status.stringValue = "Ce lien ne peut pas être affiché dans Playmelt."
            decisionHandler(.cancel); return
        }
        if action.targetFrame == nil {
            decisionHandler(.cancel); webView.load(action.request); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url=action.request.url,Self.permits(url) {
            if ["checkout.stripe.com","billing.stripe.com"].contains(url.host ?? "") {NSWorkspace.shared.open(url)}else{webView.load(action.request)}
        }
        return nil
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        status.stringValue = (webView.url?.scheme == "https" ? nil : article).map { "Steam · " + ($0["gameTitle"] as? String ?? "Actualité") }
            ?? [webView.url?.host, webView.title].compactMap { $0 }.joined(separator: " · ")
        previous?.isEnabled = webView.canGoBack; next?.isEnabled = webView.canGoForward
        UnifiedBrowserSessionManager.synchronizeAllSessions()
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { status.stringValue = "Page indisponible. Réessayez avec Actualiser." }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
    }
}

/// Services connectés via le navigateur intégré : on ne lit que le NOM et le domaine
/// des cookies d'authentification (jamais leur valeur), pour savoir si une session existe.
enum ConnectedServices {
    static let browserStoreID = UUID(uuidString: "8BCDA5D0-5533-4672-A758-B265EF735D87")!
    // Magasin gardé en vie : un magasin temporaire peut être libéré avant de rendre ses cookies.
    private static let store = WKWebsiteDataStore(forIdentifier: browserStoreID)
    private static let rules: [(service: String, domains: [String], match: (String) -> Bool)] = [
        ("amazon", ["amazon.fr", "amazon.com", "amazon.de", "amazon.co.uk", "amazon.es", "amazon.it"], { $0.hasPrefix("at-") || $0.hasPrefix("sess-at-") }),
        ("battle", ["battle.net", "blizzard.com"], { $0 == "BA-tassadar" }),
        ("humble", ["humblebundle.com"], { $0 == "_simpleauth_sess" }),
        ("itch", ["itch.io"], { $0 == "itchio_token" || $0 == "itchio" }),
        ("ea", ["ea.com"], { $0 == "remid" })
    ]
    static func detect(_ completion: @escaping ([String: Bool]) -> Void) {
        store.httpCookieStore.getAllCookies { cookies in
            var found: [String: Bool] = [:]
            for rule in rules {
                found[rule.service] = cookies.contains { cookie in
                    let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    let fresh = cookie.expiresDate.map { $0 > Date() } ?? true
                    return fresh && rule.domains.contains { domain == $0 || domain.hasSuffix("." + $0) } && rule.match(cookie.name)
                }
            }
            DispatchQueue.main.async { completion(found) }
        }
    }

    // Liste publique des jeux GeForce NOW (NVIDIA), mise en cache 12 h.
    private static var geforceCache: (at: Date, games: [[String: Any]])?
    static func geforceCatalog(_ completion: @escaping ([[String: Any]]) -> Void) {
        if let cache = geforceCache, Date().timeIntervalSince(cache.at) < 12 * 3600 { completion(cache.games); return }
        let url = URL(string: "https://static.nvidiagrid.net/supported-public-game-list/locales/gfnpc-fr-FR.json")!
        URLSession.shared.dataTask(with: url) { data, response, _ in
            var games: [[String: Any]] = []
            if (response as? HTTPURLResponse)?.statusCode == 200, let data, data.count < 20_000_000,
               let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
                for row in rows.prefix(5000) {
                    guard let title = row["title"] as? String, !title.isEmpty, (row["status"] as? String ?? "AVAILABLE") == "AVAILABLE" else { continue }
                    let steam = (row["steamUrl"] as? String).flatMap { $0.split(separator: "/").last.map(String.init) } ?? ""
                    games.append(["title": String(title.prefix(160)), "store": String((row["store"] as? String ?? "").prefix(40)),
                                  "steamAppId": steam.allSatisfy(\.isNumber) ? steam : ""])
                }
            }
            DispatchQueue.main.async {
                if !games.isEmpty { geforceCache = (Date(), games) }
                completion(games)
            }
        }.resume()
    }
}

/// Suivi de consommation et quotas d'heures GeForce NOW (Gratuit, Performance, Ultimate, Fondateur).
struct GeForceUsage: Codable {
    struct Session: Codable {
        let timestamp: Double
        let durationSeconds: Int64
        let title: String?
    }

    var tier: String = "performance" // "free", "performance", "ultimate", "founders"
    var sessions: [Session] = []
    var rolloverSeconds: Int64 = 0 // heures reportées du mois précédent (max 15 h = 54 000 s)

    static let performanceMonthlyQuotaSeconds: Int64 = 100 * 3600
    static let ultimateMonthlyQuotaSeconds: Int64 = 100 * 3600
    static let maxRolloverSeconds: Int64 = 15 * 3600

    static func fileURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Playmelt/geforce-cloud-usage.json")
    }

    static func load(from url: URL) -> GeForceUsage {
        guard let data = try? Data(contentsOf: url),
              let usage = try? JSONDecoder().decode(GeForceUsage.self, from: data) else {
            return GeForceUsage()
        }
        return usage
    }

    func save(to url: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func usedSecondsThisMonth(now: Date = Date()) -> Int64 {
        let calendar = Calendar.current
        let currentMonth = calendar.component(.month, from: now)
        let currentYear = calendar.component(.year, from: now)
        return sessions.filter { session in
            let date = Date(timeIntervalSince1970: session.timestamp)
            return calendar.component(.month, from: date) == currentMonth &&
                   calendar.component(.year, from: date) == currentYear
        }.reduce(0) { $0 + $1.durationSeconds }
    }

    func sessionLimitHours() -> Int {
        switch tier {
        case "free": return 1
        case "performance": return 6
        case "ultimate": return 8
        case "founders": return 6
        default: return 6
        }
    }

    func monthlyQuotaSeconds() -> Int64? {
        switch tier {
        case "free": return nil
        case "performance": return Self.performanceMonthlyQuotaSeconds + min(max(0, rolloverSeconds), Self.maxRolloverSeconds)
        case "ultimate": return Self.ultimateMonthlyQuotaSeconds + min(max(0, rolloverSeconds), Self.maxRolloverSeconds)
        case "founders": return -1
        default: return Self.performanceMonthlyQuotaSeconds
        }
    }

    func remainingHoursThisMonth(now: Date = Date()) -> Int? {
        guard let quota = monthlyQuotaSeconds() else { return nil }
        if quota < 0 { return -1 }
        let used = usedSecondsThisMonth(now: now)
        let remaining = max(0, quota - used)
        return max(0, Int(ceil(Double(remaining) / 3600.0)))
    }

    func payload(now: Date = Date()) -> [String: Any] {
        let used = usedSecondsThisMonth(now: now)
        let remHours = remainingHoursThisMonth(now: now)
        let limitHours = sessionLimitHours()
        let quota = monthlyQuotaSeconds()

        var dict: [String: Any] = [
            "tier": tier,
            "sessionLimitHours": limitHours,
            "usedSeconds": used,
            "usedHours": Double(used) / 3600.0
        ]
        if let quota = quota {
            if quota < 0 {
                dict["isUnlimited"] = true
                dict["monthlyQuotaHours"] = -1
                dict["remainingHours"] = -1
            } else {
                dict["isUnlimited"] = false
                dict["monthlyQuotaHours"] = Int(quota / 3600)
                dict["remainingHours"] = remHours ?? 100
                dict["remainingSeconds"] = max(0, quota - used)
            }
        } else {
            dict["isPerSessionOnly"] = true
            dict["monthlyQuotaHours"] = 0
            dict["remainingHours"] = 0
        }
        return dict
    }
}

final class GeForceUsageStore {
    static let shared = GeForceUsageStore()
    private let lock = NSLock()
    private let url: URL
    private var usage: GeForceUsage
    private let now: () -> Date

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, now: @escaping () -> Date = Date.init) {
        let file = GeForceUsage.fileURL(home: home)
        self.url = file
        self.usage = GeForceUsage.load(from: file)
        self.now = now
    }

    func recordSession(seconds: Int64, title: String? = nil) {
        guard seconds > 5 else { return }
        lock.lock(); defer { lock.unlock() }
        usage.sessions.append(GeForceUsage.Session(timestamp: now().timeIntervalSince1970, durationSeconds: seconds, title: title))
        usage.save(to: url)
    }

    func setTier(_ tier: String) {
        guard ["free", "performance", "ultimate", "founders"].contains(tier) else { return }
        lock.lock(); defer { lock.unlock() }
        usage.tier = tier
        usage.save(to: url)
    }

    func currentUsage() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return usage.payload(now: now())
    }
}
