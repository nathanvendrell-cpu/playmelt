import AppKit
import WebKit

/// Remote content stays in the existing app window and never receives the
/// local library's script bridge or file access.
final class HubBrowserPanel: NSObject, WKNavigationDelegate, WKUIDelegate {
    var onXboxCloud:((URL)->Void)?
    var authorizeCloud:((@escaping(Bool,String)->Void)->Void)?
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
        config.websiteDataStore = XboxCloudRoute.isCloudPage(url) ? XboxWebSession.store : article == nil ? WKWebsiteDataStore(forIdentifier: UUID(uuidString: "8BCDA5D0-5533-4672-A758-B265EF735D87")!) : .nonPersistent()
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
        guard let url, url.scheme == "https", url.host != nil, url.user == nil, url.password == nil, url.port == nil else { return false }
        return true
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
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
        if article != nil, action.navigationType == .other, action.request.url?.absoluteString == "about:blank" {
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
