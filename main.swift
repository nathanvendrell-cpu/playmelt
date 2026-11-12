import AppKit
import WebKit
import Foundation
import Darwin
import Sparkle

final class SteamArtworkHandler: NSObject, WKURLSchemeHandler {
    weak var handler: ScriptHandler?
    static func candidateFiles(root: URL, appID: String, info: SteamAppInfo?, portrait: Bool) -> [URL] {
        guard LibraryModel.validAppID(appID) else { return [] }
        let safeRoot = root.resolvingSymlinksInPath()
        let appDirectory = safeRoot.appendingPathComponent(appID)
        let metadataPaths = portrait ? info?.portraitAssets ?? [] : info?.landscapeAssets ?? []
        let legacy = portrait ? ["library_capsule.jpg", "library_600x900.jpg", "library_hero.jpg", "header.jpg"] : ["library_header.jpg", "header.jpg", "library_hero.jpg", "library_600x900.jpg"]
        var seen = Set<URL>()
        return (metadataPaths + legacy).filter(SteamAppInfo.validArtworkPath).compactMap { path in
            let file = appDirectory.appendingPathComponent(path).resolvingSymlinksInPath()
            guard file.path.hasPrefix(appDirectory.path + "/"), seen.insert(file).inserted else { return nil }
            return file
        }
    }
    static func appID(_ url: URL) -> String? {
        guard url.scheme == "metalmaxart", url.host == "steam", url.query == nil, url.fragment == nil,
              url.user == nil, url.password == nil, url.port == nil,
              url.pathComponents.count == 2 || (url.pathComponents.count == 3 && url.lastPathComponent == "portrait") else { return nil }
        let id = url.pathComponents[1]
        return LibraryModel.validAppID(id) ? id : nil
    }
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, let id = Self.appID(url), let model = handler?.model,
              model.games.contains(where: { $0.store == "steam" && $0.appId == id }) else {
            urlSchemeTask.didFailWithError(URLError(.badURL)); return
        }
        for runtime in model.runtimes {
            let root = runtime.steamRoot.appendingPathComponent("appcache/librarycache").resolvingSymlinksInPath()
            for file in Self.candidateFiles(root: root, appID: id, info: model.metadata[id], portrait: url.lastPathComponent == "portrait") {
                guard file.path.hasPrefix(root.appendingPathComponent(id).path + "/"),
                      let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= 8_000_000,
                      let data = try? Data(contentsOf: file) else { continue }
                let mime: String
                if data.starts(with: [0xff, 0xd8]) { mime = "image/jpeg" }
                else if data.starts(with: [0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a]) { mime = "image/png" }
                else if data.count >= 12, String(data: data.prefix(4), encoding: .ascii) == "RIFF", String(data: data[8..<12], encoding: .ascii) == "WEBP" { mime = "image/webp" }
                else { continue }
                urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
                urlSchemeTask.didReceive(data); urlSchemeTask.didFinish(); return
            }
        }
        urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

final class SteamAuthentication: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    var window: NSWindow?
    var webView: WKWebView?
    let model: LibraryModel
    let result: (Bool, String) -> Void
    private var lifetime = SteamAuthenticationLifetime()
    private var sessionStore: WKWebsiteDataStore?
    private var navigationContext: (WKNavigation, UUID)?
    init(model: LibraryModel, result: @escaping (Bool, String) -> Void) { self.model = model; self.result = result }
    static func allowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return ["steamcommunity.com", "steampowered.com", "steamstatic.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }
    func open() {
        guard lifetime.open() else { return }
        if let window { window.makeKeyAndOrderFront(nil); return }
        let config = WKWebViewConfiguration()
        // WebKit owns this isolated persistent Steam session. Playmelt never
        // extracts cookies or passwords; the page is still released after sync.
        if sessionStore == nil { sessionStore = WKWebsiteDataStore(forIdentifier: SteamAuthenticationLifetime.websiteDataStoreIdentifier) }
        config.websiteDataStore = sessionStore!
        // This web view has no privileged message handler or native bridge.
        let web = WKWebView(frame: .zero, configuration: config); web.navigationDelegate = self; web.uiDelegate = self
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Steam officiel — connexion et bibliothèque"; window.isReleasedWhenClosed = false; window.delegate = self
        let container = NSView(); let button = NSButton(title: "Lire la bibliothèque affichée", target: self, action: #selector(readLibrary))
        let reload = NSButton(title: "Recharger", target: self, action: #selector(reloadLibrary))
        let note = NSTextField(labelWithString: "steamcommunity.com · Compte Steam")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        for view in [web, button, reload, note] { view.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(view) }
        NSLayoutConstraint.activate([button.topAnchor.constraint(equalTo: container.topAnchor, constant: 10), button.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14), reload.trailingAnchor.constraint(equalTo: button.leadingAnchor, constant: -8), reload.centerYAnchor.constraint(equalTo: button.centerYAnchor), note.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14), note.centerYAnchor.constraint(equalTo: button.centerYAnchor), note.trailingAnchor.constraint(lessThanOrEqualTo: reload.leadingAnchor, constant: -12), web.topAnchor.constraint(equalTo: button.bottomAnchor, constant: 10), web.leadingAnchor.constraint(equalTo: container.leadingAnchor), web.trailingAnchor.constraint(equalTo: container.trailingAnchor), web.bottomAnchor.constraint(equalTo: container.bottomAnchor)])
        window.contentView = container; self.window = window; self.webView = web
        window.center(); window.makeKeyAndOrderFront(nil)
        web.load(URLRequest(url: URL(string: "https://steamcommunity.com/my/games/?tab=all")!))
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard self.webView === webView, let url = navigationAction.request.url, Self.allowed(url) else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if self.webView === webView, let url = navigationAction.request.url, Self.allowed(url) { webView.load(URLRequest(url: url)) }; return nil
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard self.webView === webView, let navigation, let token = lifetime.navigate() else { return }
        navigationContext = (navigation, token)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard self.webView === webView, let context = navigationContext, context.0 === navigation,
              lifetime.navigationFinished(context.1) else { return }
        navigationContext = nil; capture(manual: false)
    }
    private func navigationFailed(_ webView: WKWebView, navigation: WKNavigation?, error: Error) {
        guard self.webView === webView, let context = navigationContext, context.0 === navigation,
              lifetime.navigationFailed(context.1) else { return }
        navigationContext = nil
        let failure = error as NSError
        if failure.domain != NSURLErrorDomain || failure.code != NSURLErrorCancelled {
            result(false, "Steam n’a pas chargé la bibliothèque. Utilisez Recharger pour réessayer.")
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationFailed(webView, navigation: navigation, error: error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationFailed(webView, navigation: navigation, error: error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard self.webView === webView else { return }
        navigationContext = nil; lifetime.invalidateDocument()
        result(false, "La page Steam a été interrompue. Utilisez Recharger pour reprendre.")
    }
    @objc func reloadLibrary() {
        guard let webView else { return }
        lifetime.invalidateDocument(); navigationContext = nil
        webView.load(URLRequest(url: URL(string: "https://steamcommunity.com/my/games/?tab=all")!))
    }
    @objc func readLibrary() { capture(manual: true) }
    func capture(manual: Bool) {
        guard let webView, let url = webView.url, Self.allowed(url), url.host == "steamcommunity.com", url.path.contains("/games") else {
            if manual { result(false, "Terminez la connexion Steam, puis ouvrez Tous les jeux et cliquez sur Lire la bibliothèque affichée.") }; return
        }
        guard let scriptURL = Bundle.main.url(forResource: "SteamLibraryReader", withExtension: "js"),
              let script = try? String(contentsOf: scriptURL, encoding: .utf8) else {
            result(false, "Le lecteur de bibliothèque Steam est absent. Réinstallez Playmelt."); return
        }
        guard let generation = lifetime.beginCapture() else {
            if manual { result(false, "Attendez la fin du chargement ou utilisez Recharger.") }; return
        }
        let selectedAccount = model.selectedAccountID
        webView.callAsyncJavaScript(script, arguments: ["expectedAccountId": selectedAccount, "allowAccountDiscovery": selectedAccount.isEmpty], in: nil, in: .page) { [weak self] evaluation in
            guard let self, self.lifetime.finishCapture(generation) else { return }
            guard self.model.selectedAccountID == selectedAccount else { return }
            guard case .success(let value) = evaluation, let data = value as? [String: Any],
                  data["status"] as? String == "complete", data["source"] as? String == "steamcommunity-profile-gameslist",
                  let id = data["accountId"] as? String, let rows = data["games"] as? [[String: Any]],
                  data["count"] as? Int == rows.count else {
                if manual {
                    let status: String
                    if case .success(let value) = evaluation, let data = value as? [String: Any] { status = data["status"] as? String ?? "unavailable" }
                    else { status = "unavailable" }
                    let message: String
                    switch status {
                    case "account-mismatch", "identity-mismatch": message = "Le compte affiché ne correspond pas au compte Steam sélectionné."
                    case "signed-out", "identity-unverified": message = "Terminez la connexion dans la fenêtre Steam officielle."
                    case "wrong-page": message = "Ouvrez Tous les jeux dans votre profil Steam, puis relancez la lecture."
                    case "empty-unverified": message = "Steam ne fournit pas encore une liste vérifiable. La bibliothèque mémorisée est conservée."
                    default: message = "Les données complètes de la bibliothèque ne sont pas disponibles sur cette page Steam. Rechargez Tous les jeux, puis réessayez."
                    }
                    self.result(false, message)
                }
                return
            }
            guard self.model.acceptAuthenticatedLibrary(accountID: id, list: rows, source: "steamcommunity-profile-gameslist", allowAccountDiscovery: selectedAccount.isEmpty) else {
                self.result(false, "Le compte Steam connecté ne correspond pas au compte sélectionné, ou la liste reçue est invalide. Aucun compte n’a été remplacé."); return
            }
            self.result(true, "Bibliothèque Steam synchronisée : \(rows.count) jeux, identité du compte vérifiée.")
            self.releasePage()
        }
    }
    func windowWillClose(_ notification: Notification) { releasePage(closeWindow: false) }
    func releasePage(closeWindow: Bool = true) {
        lifetime.releasePage()
        navigationContext = nil
        let page = webView, oldWindow = window
        webView = nil; window = nil
        page?.stopLoading(); page?.navigationDelegate = nil; page?.uiDelegate = nil
        oldWindow?.delegate = nil; oldWindow?.contentView = nil
        if closeWindow { oldWindow?.close() }
    }
    func shutdown() { lifetime.shutdown(); releasePage(); sessionStore = nil }
}

final class EpicLoginSheetController: NSObject, WKNavigationDelegate, WKUIDelegate {
    private var window: NSWindow?
    private var completion: ((String?) -> Void)?
    private var didFinish = false
    private var webView: WKWebView?
    private var pasteboardTimer: Timer?
    private var statusLabel: NSTextField?
    private var currentURL: URL?

    func present(on parentWindow: NSWindow, url: URL, completion: @escaping (String?) -> Void) {
        self.completion = completion
        self.didFinish = false
        self.currentURL = url

        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        let sheetWidth: CGFloat = 580
        let sheetHeight: CGFloat = 720

        let container = NSView(frame: NSRect(x: 0, y: 0, width: sheetWidth, height: sheetHeight))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let header = NSView(frame: NSRect(x: 0, y: sheetHeight - 56, width: sheetWidth, height: 56))
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        let titleLabel = NSTextField(labelWithString: "Connexion Epic Games")
        titleLabel.frame = NSRect(x: 18, y: 26, width: 220, height: 20)
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        titleLabel.isBezeled = false; titleLabel.drawsBackground = false
        header.addSubview(titleLabel)

        let status = NSTextField(labelWithString: "Détection automatique active…")
        status.frame = NSRect(x: 18, y: 8, width: 250, height: 16)
        status.font = NSFont.systemFont(ofSize: 11)
        status.textColor = NSColor.secondaryLabelColor
        status.isBezeled = false; status.drawsBackground = false
        self.statusLabel = status
        header.addSubview(status)

        let chromeButton = NSButton(title: "Ouvrir Chrome", target: self, action: #selector(openInChromeClicked))
        chromeButton.frame = NSRect(x: sheetWidth - 250, y: 12, width: 105, height: 28)
        chromeButton.bezelStyle = .rounded
        chromeButton.toolTip = "Ouvrir la page de connexion dans Google Chrome si vous y êtes déjà connecté"
        header.addSubview(chromeButton)

        let pasteButton = NSButton(title: "Coller le code", target: self, action: #selector(pasteCodeClicked))
        pasteButton.frame = NSRect(x: sheetWidth - 140, y: 12, width: 85, height: 28)
        pasteButton.bezelStyle = .rounded
        header.addSubview(pasteButton)

        let cancelButton = NSButton(title: "✕", target: self, action: #selector(cancelClicked))
        cancelButton.frame = NSRect(x: sheetWidth - 48, y: 12, width: 36, height: 28)
        cancelButton.bezelStyle = .rounded
        header.addSubview(cancelButton)

        container.addSubview(header)

        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: sheetWidth, height: sheetHeight - 56), configuration: config)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
        self.webView = wv
        container.addSubview(wv)

        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: sheetWidth, height: sheetHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        sheet.title = "Connexion Epic Games"
        sheet.contentView = container
        self.window = sheet

        // Start sniffer on general pasteboard: if user logs in in Chrome or copies code/JSON,
        // it is detected automatically without any manual input!
        startPasteboardSniffer()

        wv.load(URLRequest(url: url))
        parentWindow.beginSheet(sheet) { [weak self] _ in
            self?.stopPasteboardSniffer()
            if self?.didFinish == false {
                self?.completion?(nil)
            }
        }
    }

    @objc private func openInChromeClicked() {
        if let url = currentURL {
            NSWorkspace.shared.open(url)
            statusLabel?.stringValue = "Page ouverte dans Chrome. Copiez le code si affiché."
        }
    }

    @objc private func pasteCodeClicked() {
        if let text = NSPasteboard.general.string(forType: .string),
           let code = extractCodeFromJSON(text) {
            statusLabel?.stringValue = "Code détecté dans le Presse-papier !"
            finishWithCode(code)
        } else {
            statusLabel?.stringValue = "Aucun code trouvé dans le Presse-papier."
        }
    }

    private func startPasteboardSniffer() {
        pasteboardTimer?.invalidate()
        pasteboardTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            guard let self, !self.didFinish else { return }
            if let text = NSPasteboard.general.string(forType: .string),
               let code = self.extractCodeFromJSON(text) {
                self.statusLabel?.stringValue = "Code détecté automatiquement !"
                self.finishWithCode(code)
            }
        }
    }

    private func stopPasteboardSniffer() {
        pasteboardTimer?.invalidate()
        pasteboardTimer = nil
    }

    @objc private func cancelClicked() {
        stopPasteboardSniffer()
        closeSheet()
        completion?(nil)
    }

    private func closeSheet() {
        stopPasteboardSniffer()
        guard let win = window else { return }
        if let parent = win.sheetParent {
            parent.endSheet(win)
        } else {
            win.close()
        }
        window = nil
    }

    private func checkURLForCode(_ url: URL) -> Bool {
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            if let code = comps.queryItems?.first(where: { $0.name == "code" || $0.name == "authorizationCode" })?.value, !code.isEmpty {
                finishWithCode(code)
                return true
            }
        }
        return false
    }

    private func finishWithCode(_ code: String) {
        guard !didFinish else { return }
        didFinish = true
        stopPasteboardSniffer()
        DispatchQueue.main.async { [weak self] in
            self?.closeSheet()
            self?.completion?(code)
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil || !(navigationAction.targetFrame?.isMainFrame ?? false) {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url {
            if checkURLForCode(url) {
                decisionHandler(.cancel)
                return
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        if checkURLForCode(url) { return }

        if url.absoluteString.contains("redirect") || url.absoluteString.contains("authorized") {
            webView.evaluateJavaScript("document.body.innerText") { [weak self] result, _ in
                guard let self, !self.didFinish else { return }
                if let text = result as? String, let code = self.extractCodeFromJSON(text) {
                    self.finishWithCode(code)
                }
            }
        }
    }

    private func extractCodeFromJSON(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let code = obj["authorizationCode"] as? String, !code.isEmpty {
            return code
        }
        if let match = trimmed.range(of: "\"authorizationCode\"\\s*:\\s*\"([^\"]+)\"", options: .regularExpression) {
            let sub = String(trimmed[match])
            if let start = sub.range(of: ":\"")?.upperBound, let end = sub.range(of: "\"", options: .backwards)?.lowerBound {
                return String(sub[start..<end])
            }
        }
        if trimmed.range(of: "^[A-Za-z0-9_-]{16,4096}$", options: .regularExpression) != nil {
            return trimmed
        }
        return nil
    }
}

final class XboxCloudWindowController: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    static let shared = XboxCloudWindowController()
    private var window: NSWindow?
    private var webView: WKWebView?
    /// Jeu demandé depuis Playmelt : si la session site n'est pas établie,
    /// le sign-in revient directement sur ce jeu (pont direct Playmelt → stream).
    private var pendingLaunchURL: URL?
    private var launchRetried = false
    private var authAttempted = false
    /// Notified after each completed navigation (sign-in state may have changed) and on close.
    var onSessionMayHaveChanged: (() -> Void)?

    func open(url: URL, isGameLaunch: Bool = false) {
        guard XboxConnector.isAllowedCloudURL(url) else { return }
        if isGameLaunch { pendingLaunchURL = url; launchRetried = false; authAttempted = false }
        if let win = window, let webView {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            webView.load(URLRequest(url: url))
            return
        }

        let config = WKWebViewConfiguration()
        // Persistent store: the Microsoft account session survives app restarts.
        config.websiteDataStore = WKWebsiteDataStore.default()
        config.preferences.isElementFullscreenEnabled = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.allowsAirPlayForMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1600, height: 900), configuration: config)
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        wv.navigationDelegate = self
        wv.uiDelegate = self
        self.webView = wv

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1600, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "Playmelt — Xbox Cloud Gaming"
        win.isReleasedWhenClosed = false
        win.collectionBehavior.insert(.fullScreenPrimary)
        win.contentView = wv
        win.delegate = self
        win.center()
        self.window = win

        wv.load(URLRequest(url: url))
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Microsoft sign-in (login.live.com / login.microsoftonline.com) uses window.open popups:
    // keep them inside the same view instead of silently dropping them.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, url.scheme == "https" { webView.load(URLRequest(url: url)) }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onSessionMayHaveChanged?()
        resumePendingLaunch(webView)
    }

    /// Pont direct : un clic sur un jeu dans Playmelt doit ouvrir le stream du jeu.
    /// Si xbox.com renvoie vers sa home (session absente), on réessaie le lancement,
    /// puis on passe par le sign-in avec returnUrl = le jeu, pour un lancement automatique.
    private func resumePendingLaunch(_ webView: WKWebView) {
        guard let target = pendingLaunchURL, let current = webView.url,
              let host = current.host?.lowercased(), host.hasSuffix("xbox.com") else { return }
        if current.path.contains("/play/launch/") || current.absoluteString.contains("/play/launch/") {
            pendingLaunchURL = nil
            launchRetried = false
            authAttempted = false
            return
        }
        let path = current.path
        var isPlayHome = (path == "/play" || path == "/")
        for locale in ["fr-FR", "en-US", "en-GB", "fr-FR"] where path == "/\(locale)/play" { isPlayHome = true }
        guard isPlayHome else { return }
        if !launchRetried {
            launchRetried = true
            webView.load(URLRequest(url: target))
            return
        }
        if !authAttempted {
            authAttempted = true
            launchRetried = false
            var comps = URLComponents(string: "https://www.xbox.com/auth/msa")!
            comps.queryItems = [
                URLQueryItem(name: "action", value: "logIn"),
                URLQueryItem(name: "returnUrl", value: target.absoluteString),
            ]
            if let authURL = comps.url {
                webView.load(URLRequest(url: authURL))
                return
            }
        }
        // Rien n'a fonctionné : on rend la main (home visible, sign-in manuel possible).
        pendingLaunchURL = nil
        launchRetried = false
        authAttempted = false
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if ["https", "about", "blob", "data"].contains(url.scheme ?? "") { decisionHandler(.allow); return }
        decisionHandler(.cancel)
    }

    // Voice chat in cloud games: ask macOS (system prompt) instead of auto-granting.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(origin.host.hasSuffix("xbox.com") ? .prompt : .deny)
    }

    func windowWillClose(_ notification: Notification) {
        onSessionMayHaveChanged?()
    }
}

final class AchievementToastWindowController {
    static let shared = AchievementToastWindowController()
    private var window: NSPanel?
    private var dismissTimer: Timer?

    func show(title: String, name: String, description: String, iconURL: String? = nil) {
        DispatchQueue.main.async {
            self.dismissTimer?.invalidate()
            self.window?.orderOut(nil)
            self.window = nil

            let panelWidth: CGFloat = 360
            let panelHeight: CGFloat = 76
            
            let screen = NSScreen.main ?? NSScreen.screens.first
            let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
            
            let xPos = screenFrame.origin.x + (screenFrame.width - panelWidth) / 2.0
            let yPos = screenFrame.origin.y + screenFrame.height - panelHeight - 32
            let frame = NSRect(x: xPos, y: yPos, width: panelWidth, height: panelHeight)

            let panel = NSPanel(contentRect: frame,
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered,
                                defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.hasShadow = true

            let visualEffect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
            visualEffect.material = .hudWindow
            visualEffect.state = .active
            visualEffect.wantsLayer = true
            visualEffect.layer?.cornerRadius = 14
            visualEffect.layer?.masksToBounds = true
            visualEffect.layer?.borderWidth = 1.0
            visualEffect.layer?.borderColor = NSColor(white: 1.0, alpha: 0.25).cgColor

            let iconView = NSImageView(frame: NSRect(x: 14, y: 14, width: 48, height: 48))
            iconView.imageScaling = .scaleProportionallyUpOrDown
            if let iconURL = iconURL, let url = URL(string: iconURL) {
                URLSession.shared.dataTask(with: url) { data, _, _ in
                    if let data = data, let img = NSImage(data: data) {
                        DispatchQueue.main.async { iconView.image = img }
                    }
                }.resume()
            }
            if iconView.image == nil {
                iconView.image = NSImage(systemSymbolName: "trophy.fill", accessibilityDescription: nil)
                iconView.contentTintColor = NSColor(red: 1.0, green: 0.8, blue: 0.2, alpha: 1.0)
            }

            let categoryLabel = NSTextField(labelWithString: title.uppercased())
            categoryLabel.frame = NSRect(x: 72, y: 48, width: 270, height: 14)
            categoryLabel.font = NSFont.systemFont(ofSize: 10, weight: .bold)
            categoryLabel.textColor = NSColor(red: 1.0, green: 0.82, blue: 0.28, alpha: 1.0)

            let nameLabel = NSTextField(labelWithString: name)
            nameLabel.frame = NSRect(x: 72, y: 28, width: 270, height: 18)
            nameLabel.font = NSFont.systemFont(ofSize: 13, weight: .bold)
            nameLabel.textColor = .white
            nameLabel.lineBreakMode = .byTruncatingTail

            let descLabel = NSTextField(labelWithString: description)
            descLabel.frame = NSRect(x: 72, y: 12, width: 270, height: 14)
            descLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
            descLabel.textColor = NSColor(white: 0.85, alpha: 1.0)
            descLabel.lineBreakMode = .byTruncatingTail

            visualEffect.addSubview(iconView)
            visualEffect.addSubview(categoryLabel)
            visualEffect.addSubview(nameLabel)
            visualEffect.addSubview(descLabel)

            panel.contentView = visualEffect
            panel.alphaValue = 0.0
            panel.orderFrontRegardless()

            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.35
                panel.animator().alphaValue = 1.0
            })

            NSSound(named: "Glass")?.play()

            self.window = panel
            self.dismissTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.5
                    self?.window?.animator().alphaValue = 0.0
                }, completionHandler: {
                    self?.window?.orderOut(nil)
                    self?.window = nil
                })
            }
        }
    }
}

final class ScriptHandler: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?
    let model = LibraryModel()
    let libraryScanner = LibraryScanner()
    private var scanID = UUID()
    private var afterRefresh: [() -> Void] = []
    let epicConnector = EpicConnector()
    let runtimeSetup = RuntimeSetup()
    let d3dMetalStore = D3DMetalStore()
    lazy var d3dMetalRuntime = D3DMetalRuntime(store: d3dMetalStore)
    private let rendererImportQueue = DispatchQueue(label: "fr.playmelt.renderer-import", qos: .utility)
    private var rendererImportBusy = false
    lazy var steamBootstrap = SteamWindowsBootstrap(runtime: runtimeSetup)
    lazy var d3dMetalSteamBootstrap = SteamWindowsBootstrap(downloadsRoot: runtimeSetup.root.appendingPathComponent("D3DMetal/downloads"), descriptor: { [weak self] in
        guard let self else { return nil }
        return try? self.d3dMetalRuntime.descriptor(base: self.runtimeSetup.descriptor())
    })
    let installCoordinator = SteamInstallCoordinator()
    let requestGate = SteamRequestGate()
    let clientLauncher = UserProcessLauncher()
    private let gameSettingsStore = GameSettingsStore(root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Playmelt/GameSettings", isDirectory: true),
                                                      nvidiaBridgeAvailable: { NvidiaBridgeStore.shared.available() })
    private let gameSettingsQueue = DispatchQueue(label: "fr.playmelt.game-settings", qos: .utility)
    /// Abonnement : inerte tant que PlaymeltPaywallEnabled n'est pas activé dans l'Info.plist.
    private let entitlementStore = EntitlementStore()
    private var gameSettingsPayload: [String: Any]?
    private var gameSettingsRequest = UUID()
    var authentication: SteamAuthentication?
    var loading = false
    private var closing = false
    let resourceURL: URL
    var activeInstallerProcess: Process?
    private var activeInstallerID: UUID?
    private var installerBuffer = Data()
    private var installerEOF = false
    private var installerExitStatus: Int32?
    private var installerShutdownWaiters: [() -> Void] = []
    private var lastNotifiedPhase = ""
    private var epicLoginController: EpicLoginSheetController?
    private var installerCancelledByUser = false
    private var xboxCatalogTimer: Timer?
    private var nvidiaBridgeStore: NvidiaBridgeStore { .shared }
    private var nvidiaBridgeInstalling: Bool { nvidiaBridgeStore.status()["busy"] as? Bool == true }

    private var epicCacheURL: URL {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Playmelt")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport.appendingPathComponent(".epic_cache.json")
    }

    func autoRestoreEpic() {
        let fm = FileManager.default
        let sessionFile = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Playmelt/.epic_session.dat")
        if fm.fileExists(atPath: sessionFile.path),
           let data = try? Data(contentsOf: sessionFile),
           let env = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let sess = env["session"] as? [String: Any] {
            let lgdConfigDir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".config/legendary")
            try? fm.createDirectory(at: lgdConfigDir, withIntermediateDirectories: true)
            let userJsonFile = lgdConfigDir.appendingPathComponent("user.json")
            if !fm.fileExists(atPath: userJsonFile.path),
               let sessData = try? JSONSerialization.data(withJSONObject: sess, options: [.prettyPrinted]) {
                try? sessData.write(to: userJsonFile, options: .atomic)
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: userJsonFile.path)
            }
        }

        if model.epicSnapshot == nil, FileManager.default.fileExists(atPath: epicCacheURL.path),
           let data = try? Data(contentsOf: epicCacheURL),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let snapshot = try? EpicConnector.validatedSnapshot(["snapshot": obj]).get() {
            model.epicSnapshot = snapshot
            model.epicSnapshotFresh = true
            refresh()
        }

        epicConnector.restoreSession { [weak self] restored in
            guard let self, !self.closing else { return }
            if case .success(true) = restored {
                self.epicConnector.sync { [weak self] outcome in
                    self?.receiveEpic(outcome)
                }
            }
        }
    }
    init(resourceURL: URL) {
        self.resourceURL = resourceURL; super.init()
        model.xboxConnector.onOpenCloud = { url, isGameLaunch in
            DispatchQueue.main.async {
                XboxCloudWindowController.shared.open(url: url, isGameLaunch: isGameLaunch)
            }
        }
        model.xboxConnector.onUpdate = { [weak self] in
            DispatchQueue.main.async {
                self?.sendState()
                self?.refresh()
            }
        }
        XboxCloudWindowController.shared.onSessionMayHaveChanged = { [weak self] in
            DispatchQueue.main.async {
                self?.model.xboxConnector.refreshSignInState()
            }
        }
        model.xboxConnector.refreshSignInState()
        model.xboxConnector.refreshCatalog()
        // Catalogue Game Pass toujours à jour : vérification légère toutes les 30 minutes
        // (aucun réseau tant que le cache est frais) + état de connexion Microsoft.
        DispatchQueue.main.async { [weak self] in self?.startXboxCatalogTimer() }
        installCoordinator.onChange = { [weak self] in self?.notifyInstallJob() }
        installCoordinator.onCancel = { [weak self] in
            self?.installerCancelledByUser = true
            self?.stopNativeInstaller()
        }
        steamBootstrap.onChange = { [weak self] in self?.notifyRuntime() }
        steamBootstrap.onInstalled = { [weak self] in self?.refresh() }
        d3dMetalSteamBootstrap.onChange = { [weak self] in self?.notifyRuntime() }
        d3dMetalSteamBootstrap.onInstalled = { [weak self] in self?.refresh() }
    }

    /// Vérification périodique légère du catalogue Game Pass + connexion Microsoft.
    private func startXboxCatalogTimer() {
        xboxCatalogTimer?.invalidate()
        xboxCatalogTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            self?.model.xboxConnector.refreshCatalog()
            self?.model.xboxConnector.refreshSignInState()
        }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !closing, message.frameInfo.isMainFrame, message.frameInfo.request.url?.standardizedFileURL == resourceURL.standardizedFileURL,
              webView?.url?.standardizedFileURL == resourceURL.standardizedFileURL,
              let dict = message.body as? [String: Any], let action = dict["action"] as? String else { return }
        print("Playmelt action: \(action)"); fflush(stdout)
        let duringScan: Set<String> = ["refresh", "setRenderProtection", "selectAccount", "cancelWindowsRuntime", "cancelD3DMetalRuntime", "cancelInstallAndPlay", "getGameSettings", "saveGameSettings"]
        guard !loading || duringScan.contains(action) else { result(false, "Lecture locale en cours. Réessayez dans un instant."); return }
        guard !RenderProtection.blocks(action, enabled: renderProtectionEnabled) else { result(false, "Rendus en cours : cette action est suspendue."); return }
        guard !WindowsExecutionPolicy.legacyActions.contains(action) else { result(false, WindowsExecutionPolicy.message); return }
        switch action {
        case "getGameSettings", "saveGameSettings":
            receiveGameSettings(action: action, payload: dict)
        case "activateLicense":
            guard let key = dict["key"] as? String, key.count <= 256 else { result(false, "Clé de licence invalide."); return }
            entitlementStore.activate(key: key) { [weak self] decision in
                DispatchQueue.main.async { self?.result(decision.allowsLaunch, decision.message); self?.sendState() }
            }
        case "deactivateLicense":
            entitlementStore.deactivate { [weak self] ok in
                DispatchQueue.main.async { self?.result(ok, ok ? "Ce Mac a été retiré de votre abonnement." : "Licence retirée de ce Mac ; le serveur n'a pas confirmé."); self?.sendState() }
            }
        case "openCheckout":
            guard let url = entitlementStore.configuration.checkoutURL, url.scheme == "https" else { result(false, "Boutique Playmelt pas encore ouverte."); return }
            NSWorkspace.shared.open(url)
        case "setRenderProtection":
            guard let enabled = dict["enabled"] as? Bool else { return }
            model.preferences.set(enabled, forKey: RenderProtection.preferenceKey)
            if enabled {
                installCoordinator.cancel(message: "Rendus en cours : lancement automatique annulé.")
                runtimeSetup.cancel(); d3dMetalRuntime.cancel()
                steamBootstrap.cancel { [weak self] in self?.notifyRuntime() }
                d3dMetalSteamBootstrap.cancel { [weak self] in self?.notifyRuntime() }
            }
            sendState()
        case "refresh": refresh()
        case "selectAccount":
            guard let id = dict["accountId"] as? String, model.accounts.contains(where: { $0.id == id }) else { result(false, "Compte non reconnu."); return }
            installCoordinator.cancel(message: "Compte changé : lancement automatique annulé.")
            model.selectedAccountID = id; model.preferences.set(id, forKey: "selectedSteamAccount"); model.libraryStatus = "local"; refresh()
        case "setupWindowsRuntime":
            guard !CommandLine.arguments.contains("--audit-read-only"), !anyRuntimeOperation else { result(false, "Préparation indisponible pendant cette opération."); return }
            runtimeSetup.start(progress: { [weak self] _ in self?.notifyRuntime() }) { [weak self] outcome in
                self?.refresh()
                if case .failure(let error) = outcome { self?.result(false, error.localizedDescription) }
            }
        case "cancelWindowsRuntime": runtimeSetup.cancel()
        case "setupD3DMetalRuntime":
            guard !CommandLine.arguments.contains("--audit-read-only"), !anyRuntimeOperation else { result(false, "Préparation indisponible pendant cette opération."); return }
            d3dMetalRuntime.start(base: runtimeSetup.descriptor(), progress: { [weak self] _ in self?.notifyRuntime() }) { [weak self] outcome in
                self?.refresh()
                if case .failure(let error) = outcome { self?.result(false, error.localizedDescription) }
            }
        case "cancelD3DMetalRuntime": d3dMetalRuntime.cancel()
        case "installSteamD3DMetal":
            guard !CommandLine.arguments.contains("--audit-read-only"), !anyRuntimeOperation else { result(false, "Installation Steam indisponible pendant cette opération."); return }
            d3dMetalSteamBootstrap.start()
        case "openD3DMetalSteam":
            guard !CommandLine.arguments.contains("--audit-read-only"), !anyRuntimeOperation else { result(false, "Steam DirectX 12 est indisponible pendant cette opération."); return }
            openWindowsSteam(runtimeID: "playmelt-d3dmetal")
        case "importD3DMetal": importD3DMetal()
        case "installNvidiaBridge":
            guard !CommandLine.arguments.contains("--audit-read-only"), !anyRuntimeOperation else { result(false, "Installation indisponible pendant cette opération."); return }
            installNvidiaBridge()
        case "openD3DMetalDownload":
            NSWorkspace.shared.open(URL(string: "https://developer.apple.com/games/game-porting-toolkit/")!)
        case "installSteamWindows":
            guard !CommandLine.arguments.contains("--audit-read-only"), !anyRuntimeOperation else { result(false, "Installation Steam indisponible pendant cette opération."); return }
            steamBootstrap.start()
        case "openWindowsSteam":
            guard !CommandLine.arguments.contains("--audit-read-only"), !anyRuntimeOperation else { result(false, "Steam Windows est indisponible pendant cette opération."); return }
            openWindowsSteam(runtimeID: "playmelt-windows")
        case "cancelInstallAndPlay":
            installCoordinator.cancel()
        case "installAndPlay":
            guard let id = dict["gameId"] as? String, let game = model.games.first(where: { $0.id == id }) else { result(false, "Jeu introuvable. Actualisez la bibliothèque."); return }
            if game.installed {
                route(game, installing: false, requestedRuntime: dict["runtimeId"] as? String)
            } else if game.store == "steam" {
                if prefersNativeSteam(game, requestedRuntime: dict["runtimeId"] as? String) {
                    installAndPlay(game, runtimeID: "steam-mac")
                } else {
                    startNativeSteamInstall(game: game, autoPlay: true, requestedRuntime: dict["runtimeId"] as? String)
                }
            } else {
                installAndPlay(game, runtimeID: dict["runtimeId"] as? String)
            }
        case "syncLibrary", "openSteamLogin":
            if authentication == nil { authentication = SteamAuthentication(model: model) { [weak self] ok, message in self?.sendState(); self?.result(ok, message) } }
            model.beginSteamLibrarySync(); sendState()
            authentication?.open(); result(true, "Fenêtre Steam officielle ouverte. Connectez-vous pour vérifier la bibliothèque complète.")
        case "openSteam": openSteam()
        case "connectEpic": connectEpic()
        case "disconnectEpic": disconnectEpic()
        case "syncEpic":
            guard epicConnector.availability()["authenticated"] as? Bool == true else { connectEpic(); return }
            model.epicSnapshotFresh = false
            epicConnector.sync { [weak self] outcome in self?.receiveEpic(outcome) }
        case "openEpic":
            let app = URL(fileURLWithPath: "/Applications/Epic Games Launcher.app")
            if FileManager.default.fileExists(atPath: app.path) { NSWorkspace.shared.openApplication(at: app, configuration: .init()) { [weak self] _, error in DispatchQueue.main.async { self?.result(error == nil, error == nil ? "Epic Games Launcher ouvert. La bibliothèque du compte reste gérée par Epic." : "Impossible d’ouvrir Epic Games Launcher.") } } }
            else { result(false, "Epic Games Launcher n’est pas installé.") }
        case "syncXbox":
            model.xboxConnector.refreshCatalog(force: true)
            model.xboxConnector.refreshSignInState()
            result(true, "Actualisation du catalogue Xbox Game Pass…")
        case "checkXbox":
            // Vérification silencieuse (aucun réseau si le cache est frais), sans toast.
            model.xboxConnector.refreshCatalog()
            model.xboxConnector.refreshSignInState()
        case "disconnectXbox":
            model.xboxConnector.disconnect { [weak self] in
                self?.sendState()
                self?.result(true, "Compte Microsoft déconnecté de Playmelt.")
            }
        case "openXbox", "launchXboxCloud":
            let raw = dict["url"] as? String ?? "https://www.xbox.com/fr-FR/play"
            if let url = URL(string: raw) {
                let isGameLaunch = action == "launchXboxCloud" && url.path.contains("/play/launch/")
                XboxCloudWindowController.shared.open(url: url, isGameLaunch: isGameLaunch)
                result(true, isGameLaunch ? "Lancement du jeu sur Xbox Cloud Gaming…" : "Xbox Cloud Gaming ouvert.")
            } else {
                result(false, "URL Xbox invalide.")
            }
        case "openGOG":
            model.gogConnector.openGalaxy { [weak self] ok, msg in
                DispatchQueue.main.async { self?.result(ok, msg) }
            }
        case "launchGame", "installGame", "openGameFolder", "uninstallGame":
            guard let id = dict["gameId"] as? String, let game = model.games.first(where: { $0.id == id }) else { result(false, "Jeu non reconnu. Actualisez la bibliothèque."); return }
            if action == "openGameFolder" {
                guard let path = game.path, FileManager.default.fileExists(atPath: path.path) else { result(false, "Dossier installé introuvable."); return }
                NSWorkspace.shared.activateFileViewerSelecting([path]); result(true, "Dossier du jeu affiché."); return
            }
            if action == "uninstallGame" {
                uninstallGame(game)
                return
            }
            route(game, installing: action == "installGame", requestedRuntime: dict["runtimeId"] as? String)
        case "getGameAchievements":
            guard let id = dict["gameId"] as? String, let game = model.games.first(where: { $0.id == id }) else {
                result(false, "Jeu non reconnu.")
                return
            }
            let appId = game.appId.isEmpty ? game.id : game.appId
            if let cached = AchievementStore.shared.cachedAchievements(for: appId) {
                notify("onGameAchievements", ["gameId": id, "appId": appId, "achievements": cached])
            }
            if game.store == "epic" || game.installSource == "epic" {
                fetchEpicAchievements(appId: appId) { [weak self] formatted in
                    if let formatted = formatted {
                        self?.notify("onGameAchievements", ["gameId": id, "appId": appId, "achievements": formatted])
                    }
                }
            }
            result(true, "Synchronisation des succès…")
        default: result(false, "Action non prise en charge.")
        }
    }
    func fetchEpicAchievements(appId: String, completion: @escaping ([String: Any]?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let scriptDir = (Bundle.main.infoDictionary?["MetalMaxSourceDirectory"] as? String) ?? Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().path
            let venvLegendary = "\(scriptDir)/Dependencies.noindex/epic-venv/bin/legendary"
            guard FileManager.default.fileExists(atPath: venvLegendary) else {
                completion(nil); return
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: venvLegendary)
            p.arguments = ["achievements", appId, "--json"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            do {
                try p.run()
                p.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                guard let out = String(data: data, encoding: .utf8),
                      let idx = out.firstIndex(of: "{") else { completion(nil); return }
                let jsonStr = String(out[idx...])
                if let rawData = jsonStr.data(using: .utf8),
                   let rawDict = (try? JSONSerialization.jsonObject(with: rawData)) as? [String: Any] {
                    AchievementStore.shared.saveAchievements(for: appId, rawDict: rawDict)
                    let formatted = AchievementStore.shared.formatPayload(rawDict)
                    DispatchQueue.main.async { completion(formatted) }
                    return
                }
            } catch {}
            completion(nil)
        }
    }
    func refresh(completion: (() -> Void)? = nil) {
        guard !closing else { return }; loading = true
        if let completion { afterRefresh.append(completion) }
        let id = UUID(); scanID = id
        model.windowsDescriptor = runtimeSetup.descriptor()
        model.d3dMetalDescriptor = try? d3dMetalRuntime.descriptor(base: runtimeSetup.descriptor())
        libraryScanner.scan(model.makeScanRequest()) { [weak self] snapshot in
            guard let self, !self.closing, self.scanID == id else { return }
            guard self.model.applyScan(snapshot) else { self.refresh(); return }
            self.loading = false; self.sendState()
            let callbacks = self.afterRefresh; self.afterRefresh.removeAll()
            for callback in callbacks { callback() }
        }
    }
    private func openWindowsSteam(runtimeID: String) {
        refresh { [weak self] in
            guard let self, !self.closing, !self.renderProtectionEnabled, !self.anyRuntimeOperation else { return }
            guard let runtime = self.model.runtimes.first(where: { $0.id == runtimeID && $0.available }) else { self.result(false, "Préparez cet environnement puis installez Steam."); return }
            self.runWindowsClient(runtime, arguments: ["steam://open/games"], onFailure: { [weak self] message in self?.result(false, message) }) { [weak self] ok, message in self?.result(ok, message) }
        }
    }
    var runtimeIsBusy: Bool { ["downloading", "verifying", "extracting", "initializing"].contains(runtimeSetup.snapshot()["status"] as? String ?? "") }
    var renderProtectionEnabled: Bool { RenderProtection.enabled(in: model.preferences) }
    var d3dMetalIsBusy: Bool { d3dMetalRuntime.snapshot(base: runtimeSetup.descriptor())["busy"] as? Bool == true }
    var anyRuntimeOperation: Bool { runtimeIsBusy || d3dMetalIsBusy || rendererImportBusy || steamBootstrap.busy || d3dMetalSteamBootstrap.busy || installCoordinator.isActive }
    func runtimePayload() -> [String: Any] {
        var state = runtimeSetup.snapshot(); state.merge(steamBootstrap.snapshot) { _, latest in latest }
        var directX12 = d3dMetalStore.snapshot()
        directX12.merge(d3dMetalRuntime.snapshot(base: runtimeSetup.descriptor())) { _, latest in latest }
        directX12.merge(d3dMetalSteamBootstrap.snapshot) { _, latest in latest }
        directX12["busy"] = rendererImportBusy || d3dMetalIsBusy || nvidiaBridgeInstalling
        // Le pont DLSS → MetalFX est un composant moteur séparé du payload Apple.
        let bridge = nvidiaBridgeStore.status()
        directX12["nvidiaBridge"] = (bridge["available"] as? Bool) == true ? "complete" : "absent"
        directX12["nvidiaBridgeComponent"] = bridge
        state["d3dMetal"] = directX12
        state["renderProtectionEnabled"] = renderProtectionEnabled
        state["executionPolicy"] = WindowsExecutionPolicy.json
        return state
    }
    func importD3DMetal() {
        guard !closing, !anyRuntimeOperation, !CommandLine.arguments.contains("--audit-read-only"),
              let window = webView?.window else { result(false, "Import indisponible pendant cette opération."); return }
        let picker = NSOpenPanel()
        picker.title = "Importer DirectX 12"
        picker.message = "Sélectionnez le dossier D3DMetal du paquet Apple."
        picker.prompt = "Importer"
        picker.canChooseDirectories = true; picker.canChooseFiles = false
        picker.allowsMultipleSelection = false; picker.canCreateDirectories = false
        rendererImportBusy = true; notifyRuntime()
        picker.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard !self.closing, response == .OK, let source = picker.url else {
                self.rendererImportBusy = false; self.notifyRuntime(); return
            }
            self.rendererImportQueue.async { [self] in
                let outcome = Result { try self.d3dMetalStore.importLocal(sourceURL: source) }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.rendererImportBusy = false
                    guard !self.closing else { return }
                    self.notifyRuntime()
                    switch outcome {
                    case .success: self.result(true, "Composant Apple importé. La validation graphique reste à effectuer.")
                    case .failure(let error): self.result(false, error.localizedDescription)
                    }
                }
            }
        }
    }
    func finishRendererImport(_ completion: @escaping () -> Void) {
        // A close waits for the exact import queue to finish or roll back staging.
        rendererImportQueue.async { DispatchQueue.main.async(execute: completion) }
    }
    /// Composant moteur : pont DLSS → MetalFX. Le DMG GPTK 4 (ou son dossier
    /// redist/lib extrait) est monté et vérifié, puis les shims sont installés
    /// dans un répertoire dédié, sans toucher au payload Apple.
    func installNvidiaBridge() {
        guard !closing, !anyRuntimeOperation, !CommandLine.arguments.contains("--audit-read-only"),
              let window = webView?.window else { result(false, "Installation indisponible pendant cette opération."); return }
        let picker = NSOpenPanel()
        picker.title = "Installer le pont DLSS → MetalFX"
        picker.message = "Sélectionnez le DMG Game Porting Toolkit 4 (ou son dossier redist/lib extrait)."
        picker.prompt = "Installer"
        picker.canChooseDirectories = true
        picker.canChooseFiles = true
        picker.allowsMultipleSelection = false
        picker.canCreateDirectories = false
        picker.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard !self.closing, response == .OK, let source = picker.url else { return }
            self.nvidiaBridgeStore.install(source: source) { [weak self] ok, message in
                guard let self, !self.closing else { return }
                self.notifyRuntime()
                self.result(ok, message)
            }
        }
    }
    func sendState() {
        model.epicAvailability = epicConnector.availability()
        var state = model.state(); state["windowsRuntime"] = runtimePayload(); state["installJob"] = installCoordinator.snapshot ?? NSNull()
        state["renderProtectionEnabled"] = renderProtectionEnabled
        if let gameSettingsPayload { state["gameSettings"] = gameSettingsPayload }
        state["subscription"] = entitlementStore.snapshot()
        notify("onNativeState", state)
    }
    private func gameSettingsContext(_ game: Game) -> GameSettingsContext {
        GameSettingsContext(id: game.id, appID: game.appId, platform: game.platform,
                            installed: game.installed, path: game.path?.path ?? "",
                            requiredRenderer: SteamGameLaunchProfile.requiredRenderer(appID: game.appId),
                            supportsLaunchArguments: game.store == "steam" || game.installSource == "local")
    }
    private func receiveGameSettings(action: String, payload: [String: Any]) {
        guard let id = payload["gameId"] as? String else { return }
        guard let game = model.games.first(where: { $0.id == id }) else {
            gameSettingsPayload = ["gameId": id, "status": "error", "error": "Ce jeu n’est plus dans la bibliothèque. Actualisez-la."]
            sendState(); return
        }
        let saving = action == "saveGameSettings"
        if saving && CommandLine.arguments.contains("--audit-read-only") {
            gameSettingsPayload = ["gameId": id, "status": "error", "error": "La sauvegarde est désactivée en mode de vérification."]
            sendState(); return
        }
        guard !saving || (payload["settings"] is [String: Any] && payload["changedFields"] is [String]) else {
            gameSettingsPayload = ["gameId": id, "status": "error", "error": "Les paramètres reçus sont incomplets."]
            sendState(); return
        }
        let context = gameSettingsContext(game)
        let displays = GameDisplayMetadata.screens()
        let hardware = hardwareState(renderProtectionEnabled: renderProtectionEnabled)
        let request = UUID(); gameSettingsRequest = request
        gameSettingsQueue.async { [weak self] in
            guard let self else { return }
            var response: [String: Any]
            if saving {
                response = self.gameSettingsStore.save(game: context, payload: payload["settings"] as! [String: Any], expectedRevision: payload["expectedRevision"] as? String, changedFields: payload["changedFields"] as! [String])
                if response["status"] as? String == "saved" {
                    response = self.gameSettingsStore.snapshot(game: context, hardware: hardware, displays: displays)
                    if response["status"] as? String != "error" { response["status"] = "saved" }
                }
            } else {
                response = self.gameSettingsStore.snapshot(game: context, hardware: hardware, displays: displays)
            }
            let completedResponse = response
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closing, self.gameSettingsRequest == request else { return }
                self.gameSettingsPayload = completedResponse
                self.sendState()
            }
        }
    }
    func notifyRuntime() { notify("onNativeRuntime", runtimePayload()) }
    func notifyInstallJob() {
        if let job = installCoordinator.snapshot {
            notify("onNativeInstallJob", job)
        } else {
            webView?.evaluateJavaScript("if (typeof window.onNativeInstallJob === 'function') window.onNativeInstallJob(null);", completionHandler: nil)
        }
    }
    func sendToast(_ message: String, error: Bool = false) {
        guard !closing, let data = try? JSONSerialization.data(withJSONObject: [message, error]),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("if (typeof showToast === 'function') { const [m, e] = \(json); showToast(m, e); }", completionHandler: nil)
    }
    func result(_ ok: Bool, _ message: String) { notify("onNativeResult", ["ok": ok, "message": message]) }
    func notify(_ name: String, _ payload: [String: Any]) {
        guard !closing, let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("if (typeof window.\(name) === 'function') window.\(name)(\(json));", completionHandler: nil)
    }
    func openSteam() {
        guard let runtime = model.runtimes.first(where: { $0.id == "steam-mac" && $0.available }), let app = runtime.appURL else { result(false, "Steam macOS est introuvable."); return }
        NSWorkspace.shared.openApplication(at: app, configuration: .init()) { [weak self] _, error in DispatchQueue.main.async { self?.result(error == nil, error == nil ? "Steam ouvert. Le compte actif se choisit dans Steam." : "Impossible d’ouvrir Steam.") } }
    }
    private func disconnectEpic() {
        guard !closing, !CommandLine.arguments.contains("--audit-read-only"),
              epicConnector.availability()["busy"] as? Bool != true,
              let window = webView?.window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Déconnecter Epic Games ?"
        alert.informativeText = "La connexion mémorisée par Playmelt sur ce Mac sera supprimée, sans copie de sauvegarde. Les jeux et la bibliothèque en cache seront conservés. Une nouvelle connexion sera nécessaire."
        alert.addButton(withTitle: "Déconnecter"); alert.addButton(withTitle: "Annuler")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, !self.closing, response == .alertFirstButtonReturn else { return }
            self.model.epicSnapshotFresh = false
            self.epicConnector.clearSession { [weak self] outcome in
                guard let self, !self.closing else { return }
                self.sendState()
                switch outcome {
                case .success: self.result(true, "Compte Epic déconnecté.")
                case .failure(let error): self.result(false, error.localizedDescription)
                }
            }
            self.sendState()
        }
    }
    func connectEpic() {
        guard epicConnector.availability()["available"] as? Bool == true else { result(false, "Le connecteur Epic optionnel n’est pas installé."); sendState(); return }
        model.epicSnapshotFresh = false
        epicConnector.restoreSession { [weak self] restored in
            guard let self, !self.closing else { return }
            switch restored {
            case .success(true): self.epicConnector.sync { [weak self] outcome in self?.receiveEpic(outcome) }
            case .success(false): self.openEpicSignIn()
            case .failure(let error):
                self.sendState(); self.result(false, error.localizedDescription)
                if case let EpicConnectorError.failed(code, _) = error, code == "cancelled" || code == "busy" { return }
                self.openEpicSignIn()
            }
        }
    }
    private var epicClipboardTimer: Timer?

    private func extractEpicCode(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let code = obj["authorizationCode"] as? String, !code.isEmpty {
            return code
        }
        if let match = trimmed.range(of: "\"authorizationCode\"\\s*:\\s*\"([^\"]+)\"", options: .regularExpression) {
            let sub = String(trimmed[match])
            if let start = sub.range(of: ":\"")?.upperBound, let end = sub.range(of: "\"", options: .backwards)?.lowerBound {
                return String(sub[start..<end])
            }
        }
        if trimmed.range(of: "^[A-Za-z0-9_-]{16,4096}$", options: .regularExpression) != nil {
            return trimmed
        }
        return nil
    }

    private func checkClipboardForEpicCode() -> String? {
        guard let text = NSPasteboard.general.string(forType: .string) else { return nil }
        return extractEpicCode(from: text)
    }

    private func openEpicSignIn() {
        guard !closing else { return }
        epicConnector.requestLoginURL { [weak self] outcome in
            guard let self, !self.closing else { return }
            switch outcome {
            case .failure(let error): self.result(false, error.localizedDescription)
            case .success(let url):
                guard let window = self.webView?.window else { self.result(false, "Fenêtre principale introuvable."); return }
                self.epicLoginController = EpicLoginSheetController()
                self.epicLoginController?.present(on: window, url: url) { [weak self] code in
                    guard let self else { return }
                    self.epicLoginController = nil
                    if let code, !code.isEmpty {
                        self.result(true, "Connexion Epic validée ! Synchronisation de la bibliothèque…")
                        self.epicConnector.authenticate(code: code) { [weak self] outcome in
                            self?.receiveEpic(outcome)
                        }
                    }
                }
            }
        }
    }

    func receiveEpic(_ outcome: Result<EpicSnapshot, Error>) {
        switch outcome {
        case .success(let snapshot):
            model.epicSnapshot = snapshot
            model.epicSnapshotFresh = true
            refresh()
            let cacheObj: [String: Any] = [
                "accountId": snapshot.accountId,
                "displayName": snapshot.displayName,
                "games": snapshot.games,
                "installed": snapshot.installed,
                "source": snapshot.source,
                "updatedAt": snapshot.updatedAt
            ]
            if let data = try? JSONSerialization.data(withJSONObject: cacheObj, options: [.prettyPrinted]) {
                try? data.write(to: self.epicCacheURL, options: .atomic)
            }
            result(true, "Bibliothèque Epic synchronisée : \(snapshot.games.count) jeux.")
        case .failure(let error):
            sendState()
            result(false, error.localizedDescription)
        }
    }
    func installAndPlay(_ game: Game, runtimeID: String?) {
        guard !closing, !renderProtectionEnabled else { result(false, "Rendus en cours : lancement suspendu."); return }
        guard !CommandLine.arguments.contains("--audit-read-only") else { result(false, "Mode de vérification : installation et lancement désactivés."); return }
        guard !installCoordinator.isActive, !runtimeIsBusy, !steamBootstrap.busy else { result(false, "Une opération est déjà en cours."); return }
        if game.store == "xbox" {
            let urlStr = game.epicLaunchID.isEmpty ? "https://www.xbox.com/play" : game.epicLaunchID
            if let url = URL(string: urlStr) {
                XboxCloudWindowController.shared.open(url: url, isGameLaunch: url.path.contains("/play/launch/"))
                result(true, "Lancement de \(game.title) sur Xbox Cloud Gaming…")
            }
            return
        }
        if game.store == "gog" {
            model.gogConnector.launch(gameID: game.id) { [weak self] ok, msg in
                self?.result(ok, msg)
            }
            return
        }
        if game.store == "epic" {
            if game.installed && game.complete { route(game, installing: false, requestedRuntime: runtimeID); return }
            installEpicGame(game)
            return
        }
        guard game.store == "steam", !model.selectedAccountID.isEmpty,
              let runtime = validatedSteamRuntime(game, installing: true, requestedRuntime: runtimeID) else { return }
        if let reason = SteamGameLaunchProfile.blockReason(appID: game.appId, platform: runtime.platform, renderer: runtime.renderer, graphicsValidated: runtime.graphicsValidated) { result(false, reason); return }
        let account = model.selectedAccountID
        guard let id = installCoordinator.begin(gameID: game.id, appID: game.appId, title: game.title, runtime: runtime, accountID: account, onReady: { [weak self] id in
            guard let self, !self.closing else { return }
            guard self.model.selectedAccountID == account else { self.installCoordinator.cancel(); return }
            self.refresh { [weak self] in
                guard let self, !self.closing else { return }
                guard self.installCoordinator.confirmLaunchContext(id: id, accountChanged: self.model.selectedAccountID != account,
                                                                  executionBlocked: self.renderProtectionEnabled) else { return }
                guard let installed = self.model.games.first(where: { $0.appId == game.appId && $0.runtimeId == runtime.id && $0.installed && $0.complete }),
                      let currentRuntime = self.validatedSteamRuntime(installed, installing: false, requestedRuntime: runtime.id) else {
                    self.installCoordinator.didRequestLaunch(id: id, success: false, message: "Installation à vérifier dans Steam."); return
                }
                let active = activeSteamAccount(TextVDF.read(currentRuntime.steamRoot.appendingPathComponent("config/loginusers.vdf")).object("users"))
                guard SteamInstallAccountContext.permitsAutoLaunch(expected: account, active: active) else {
                    self.installCoordinator.didRequestLaunch(id: id, success: false, message: "Le compte actif dans Steam doit être vérifié avant le lancement automatique."); return
                }
                self.dispatchSteam(installed, runtime: currentRuntime, installing: false, onFailure: { [weak self] message in self?.installCoordinator.launchFailed(id: id, message: message) }) { [weak self] ok, message in
                    self?.installCoordinator.didRequestLaunch(id: id, success: ok, message: message)
                }
            }
        }) else { result(false, "Un suivi d’installation est déjà actif."); return }
        dispatchSteam(game, runtime: runtime, installing: true, onFailure: { [weak self] message in self?.installCoordinator.requestFailed(id: id, message: message) }) { [weak self] ok, message in
            if !ok { self?.installCoordinator.requestFailed(id: id, message: message) }
        }
    }
    func prefersNativeSteam(_ game: Game, requestedRuntime: String?) -> Bool {
        SteamGameLaunchProfile.prefersNative(platform: game.platform, supportedPlatforms: game.supportedPlatforms, requestedRuntime: requestedRuntime)
    }

    func installEpicGame(_ game: Game) {
        guard !closing, !renderProtectionEnabled else { result(false, "Rendus en cours : installation suspendue."); return }
        guard !CommandLine.arguments.contains("--audit-read-only") else { result(false, "Mode de vérification : installation désactivée."); return }
        guard !installCoordinator.isActive else { result(false, "Une installation est déjà en cours."); return }

        let fm = FileManager.default

        // Ensure user.json in ~/.config/legendary has valid session before running
        let sessionFile = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Playmelt/.epic_session.dat")
        if fm.fileExists(atPath: sessionFile.path),
           let data = try? Data(contentsOf: sessionFile),
           let env = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let sess = env["session"] as? [String: Any] {
            let lgdConfigDir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".config/legendary")
            try? fm.createDirectory(at: lgdConfigDir, withIntermediateDirectories: true)
            let userJsonFile = lgdConfigDir.appendingPathComponent("user.json")
            if let sessData = try? JSONSerialization.data(withJSONObject: sess, options: [.prettyPrinted]) {
                try? sessData.write(to: userJsonFile, options: .atomic)
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: userJsonFile.path)
            }
        }

        let gamesRoot = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Playmelt/Games")
        try? fm.createDirectory(at: gamesRoot, withIntermediateDirectories: true)

        let safeFolder = game.title.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespaces)
        let destination = gamesRoot.appendingPathComponent(safeFolder)

        guard let token = installCoordinator.beginEpicDirect(gameID: game.id, appID: game.appId, title: game.title, accountID: "epic-primary", autoLaunch: false) else {
            result(false, "Impossible de démarrer le suivi d’installation Epic.")
            return
        }

        installerCancelledByUser = false
        sendState()
        result(true, "Installation de \(game.title) démarrée dans Playmelt (DirectX 12).")

        let legendaryURL = epicConnector.legendaryExecutableURL
        guard fm.isExecutableFile(atPath: legendaryURL.path) else {
            installCoordinator.finishDirect(id: token, success: false, message: "Téléchargeur Epic (Legendary) introuvable dans l’environnement Playmelt.")
            sendState()
            return
        }
        let targetPlatform = game.platform.lowercased() == "mac" ? "Mac" : "Windows"
        // Throughput tuning (measured 2026-11-11 on FF7 Rebirth chunks, 700 Mb/s line):
        // Fastly ≈ 40 MiB/s, Akamai ≈ 18 MiB/s, CloudFront ≈ 6 MiB/s (Legendary's default pick).
        // Legendary falls back to the API order when the preferred host is not offered.
        let cpuCount = ProcessInfo.processInfo.activeProcessorCount
        let workers = max(8, min(cpuCount * 3, 32))
        let physicalMiB = ProcessInfo.processInfo.physicalMemory / 1_048_576
        let sharedMemoryMiB = physicalMiB >= 32_768 ? 4096 : (physicalMiB >= 16_384 ? 2048 : 1024)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var attempt = 1
            let maxAttempts = 5
            var finalSuccess = false

            while attempt <= maxAttempts && !self.closing && !self.installerCancelledByUser {
                let process = Process()
                self.activeInstallerProcess = process
                process.executableURL = legendaryURL
                process.arguments = [
                    "-y", "install", game.appId,
                    "--platform", targetPlatform,
                    "--base-path", gamesRoot.path,
                    "--game-folder", safeFolder,
                    "--max-workers", String(workers),
                    "--max-shared-memory", String(sharedMemoryMiB),
                    "--preferred-cdn", "egdownload.fastly-edge.com",
                    "--dl-timeout", "20",
                    "--skip-sdl",
                    "--skip-dlcs"
                ]
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = legendaryURL.deletingLastPathComponent().path + ":" + (env["PATH"] ?? "")
                env["PYTHONUNBUFFERED"] = "1"
                process.environment = env

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                    DispatchQueue.main.async {
                        self?.parseLegendaryProgress(line: text, token: token, title: game.title)
                    }
                }

                do {
                    try process.run()
                    process.waitUntilExit()
                    pipe.fileHandleForReading.readabilityHandler = nil
                    self.activeInstallerProcess = nil
                    finalSuccess = (process.terminationStatus == 0)
                } catch {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    self.activeInstallerProcess = nil
                    finalSuccess = false
                }

                if finalSuccess || self.installerCancelledByUser || self.closing {
                    break
                }

                attempt += 1
                if attempt <= maxAttempts {
                    DispatchQueue.main.async { [weak self] in
                        self?.installCoordinator.updateDirect(
                            id: token,
                            status: "downloading",
                            message: "Connexion interrompue. Reprise automatique du téléchargement (tentative \(attempt)/\(maxAttempts)) dans 5 secondes…",
                            progress: nil,
                            phase: "Reprise automatique"
                        )
                        self?.sendState()
                    }
                    Thread.sleep(forTimeInterval: 5.0)
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if finalSuccess {
                    var updatedGame = game
                    updatedGame.installed = true
                    updatedGame.complete = true
                    updatedGame.path = destination
                    updatedGame.installSource = "epic"
                    _ = ensureLaunchScript(for: updatedGame, requestedBackend: "d3dmetal")
                    self.installCoordinator.finishDirect(id: token, success: true, message: "\(game.title) est prêt à jouer avec DirectX 12 & MetalFX !")
                    self.refresh()
                } else if self.installerCancelledByUser {
                    self.installCoordinator.finishDirect(id: token, success: false, message: "Installation annulée.")
                } else {
                    self.installCoordinator.finishDirect(id: token, success: false, message: "L’installation Epic de \(game.title) a été interrompue après plusieurs tentatives de reprise. Relancez pour continuer là où elle s’est arrêtée.")
                }
                self.sendState()
            }
        }
    }

    private func parseLegendaryProgress(line: String, token: UUID, title: String) {
        var progressVal: Double? = nil
        var speedStr = ""
        var phaseStr = "Téléchargement CDN haute vitesse"
        var downloadedBytes: UInt64 = 0
        var totalBytes: UInt64 = 0 // unknown until Legendary prints "Download size" (0 = keep previous)

        if line.contains("Progress:") || line.contains("downloading") || line.contains("Download") {
            phaseStr = "Téléchargement CDN haute vitesse"
        } else if line.contains("Verification") || line.contains("Verifying") {
            phaseStr = "Vérification des fichiers"
        } else if line.contains("Extracting") || line.contains("Installing") || line.contains("Finishing") || line.contains("Written") {
            phaseStr = "Décompression et écriture disque"
        }

        if let pctRange = line.range(of: "Progress:\\s*([0-9.]+)%", options: .regularExpression) {
            let sub = String(line[pctRange])
            if let numRange = sub.range(of: "[0-9.]+", options: .regularExpression),
               let val = Double(sub[numRange]) {
                progressVal = val / 100.0
            }
        } else if let pctRange = line.range(of: "([0-9]+(?:\\.[0-9]+)?)%", options: .regularExpression) {
            let pctSub = String(line[pctRange]).replacingOccurrences(of: "%", with: "")
            if let val = Double(pctSub) {
                progressVal = val / 100.0
            }
        }

        if let speedRange = line.range(of: "([0-9.]+\\s*(?:MiB/s|GiB/s|KiB/s|MB/s|GB/s|KB/s))", options: .regularExpression) {
            speedStr = String(line[speedRange])
        }

        if let downRange = line.range(of: "Downloaded:\\s*([0-9.]+)\\s*(GiB|MiB|KiB)", options: .regularExpression) {
            let sub = String(line[downRange])
            let parts = sub.replacingOccurrences(of: "Downloaded:", with: "").trimmingCharacters(in: .whitespaces).components(separatedBy: " ")
            if parts.count >= 2, let num = Double(parts[0]) {
                let unit = parts[1]
                let mult: Double = unit.hasPrefix("G") ? 1024 * 1024 * 1024 : (unit.hasPrefix("M") ? 1024 * 1024 : 1024)
                downloadedBytes = UInt64(num * mult)
            }
        }

        if let sizeRange = line.range(of: "Download size:\\s*([0-9.]+)\\s*(GiB|MiB)", options: .regularExpression) {
            let sub = String(line[sizeRange])
            let parts = sub.replacingOccurrences(of: "Download size:", with: "").trimmingCharacters(in: .whitespaces).components(separatedBy: " ")
            if parts.count >= 2, let num = Double(parts[0]) {
                let unit = parts[1]
                let mult: Double = unit.hasPrefix("G") ? 1024 * 1024 * 1024 : 1024 * 1024
                totalBytes = UInt64(num * mult)
            }
        }

        var etaFormatted = ""
        if let etaRange = line.range(of: "ETA:\\s*([0-9]{1,2}:[0-9]{2}:[0-9]{2})", options: .regularExpression) {
            let raw = String(line[etaRange]).replacingOccurrences(of: "ETA:", with: "").trimmingCharacters(in: .whitespaces)
            let parts = raw.components(separatedBy: ":")
            if parts.count == 3, let h = Int(parts[0]), let m = Int(parts[1]), let s = Int(parts[2]) {
                if h > 0 {
                    etaFormatted = "\(h)h \(m)min"
                } else if m > 0 {
                    etaFormatted = "\(m)min \(s)s"
                } else {
                    etaFormatted = "\(s)s"
                }
            } else {
                etaFormatted = raw
            }
        }

        let msg = speedStr.isEmpty ? "Téléchargement en cours…" : (etaFormatted.isEmpty ? "Téléchargement en cours à \(speedStr)" : "Téléchargement à \(speedStr) · \(etaFormatted) restant")
        installCoordinator.updateDirect(id: token, status: "downloading", message: msg, progress: progressVal, downloaded: downloadedBytes, total: totalBytes, speed: speedStr, phase: phaseStr, eta: etaFormatted)
        sendState()
    }
    func startNativeSteamInstall(game: Game, autoPlay: Bool, requestedRuntime: String? = nil) {
        guard !closing, !renderProtectionEnabled, !CommandLine.arguments.contains("--audit-read-only") else {
            result(false, "Mode de protection : installation suspendue."); return
        }
        guard !installCoordinator.isActive, activeInstallerProcess == nil else {
            result(false, "Une installation est déjà en cours. Patientez ou annulez-la.")
            return
        }
        guard LibraryModel.validAppID(game.appId) else {
            result(false, "Identifiant Steam manquant.")
            return
        }
        let account = model.selectedAccountID
        let steamRoot = model.home.appendingPathComponent("Library/Application Support/Steam")
        guard SteamInstallAccountContext.permitsAutoLaunch(expected: account, active: activeSteamAccount(TextVDF.read(steamRoot.appendingPathComponent("config/loginusers.vdf")).object("users"))) else {
            result(false, "Vérifiez le compte actif dans Steam avant l’installation."); return
        }
        guard game.store == "steam", model.metadata[game.appId]?.platforms.contains("windows") == true,
              let runtime = validatedSteamRuntime(game, installing: true, requestedRuntime: requestedRuntime ?? game.runtimeId), runtime.platform == "windows" else {
            result(false, "Choisissez et préparez une route Windows compatible avant l’installation."); return
        }
        if autoPlay, let reason = SteamGameLaunchProfile.blockReason(appID: game.appId, platform: runtime.platform, renderer: runtime.renderer, graphicsValidated: runtime.graphicsValidated) {
            result(false, reason); return
        }
        let bundleScript = Bundle.main.url(forResource: "steam-installer", withExtension: "py")
        let sourceScript = (Bundle.main.infoDictionary?["MetalMaxSourceDirectory"] as? String).map {
            URL(fileURLWithPath: $0).appendingPathComponent("scripts/steam-installer.py")
        }
        let devScript = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/steam-installer.py")
        var scriptURL: URL?
        if let b = bundleScript, FileManager.default.fileExists(atPath: b.path) { scriptURL = b }
        else if let s = sourceScript, FileManager.default.fileExists(atPath: s.path) { scriptURL = s }
        else if FileManager.default.fileExists(atPath: devScript.path) { scriptURL = devScript }
        guard let finalScript = scriptURL else {
            result(false, "Script d'installation Playmelt introuvable.")
            return
        }
        let pythonPaths = ["/opt/homebrew/bin/python3", "/usr/bin/python3", "/usr/local/bin/python3"]
        guard let pythonPath = pythonPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            result(false, "Interpréteur Python introuvable pour l'installation.")
            return
        }
        guard let id = installCoordinator.beginDirect(gameID: game.id, appID: game.appId, title: game.title, accountID: account, autoLaunch: autoPlay) else { return }
        lastNotifiedPhase = ""
        sendToast("Démarrage du téléchargement de \(game.title)…")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = [finalScript.path, "--appid", game.appId, "--title", game.title, "--accountid", account, "--renderer", runtime.renderer]
        let pipe = Pipe()
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        self.activeInstallerProcess = proc
        activeInstallerID = id; installerBuffer = Data(); installerEOF = false; installerExitStatus = nil
        pipe.fileHandleForReading.readabilityHandler = { [weak self, weak proc] handle in
            let chunk = (try? handle.read(upToCount: 65_536)) ?? Data()
            if chunk.isEmpty { handle.readabilityHandler = nil; try? handle.close() }
            DispatchQueue.main.async {
                guard let self, let proc, self.activeInstallerProcess === proc, self.activeInstallerID == id else { return }
                if chunk.isEmpty { self.installerEOF = true; self.finishNativeInstallerIfExited(id: id, process: proc); return }
                guard self.installCoordinator.acceptsDirect(id: id) else { return }
                self.installerBuffer.append(chunk)
                guard self.installerBuffer.count <= 262_144 else {
                    self.installCoordinator.requestFailed(id: id, message: "Sortie de l’installateur invalide."); self.stopNativeInstaller(); return
                }
                while let range = self.installerBuffer.range(of: Data([0x0A])) {
                    let lineData = self.installerBuffer.subdata(in: 0..<range.lowerBound)
                    self.installerBuffer.removeSubrange(0..<range.upperBound)
                    if let parsed = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                        self.handleInstallerUpdate(json: parsed, game: game, id: id, account: account)
                    }
                }
            }
        }
        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.activeInstallerProcess === p, self.activeInstallerID == id else { return }
                self.installerExitStatus = p.terminationStatus
                self.finishNativeInstallerIfExited(id: id, process: p)
            }
        }
        do {
            try proc.run()
            result(true, "Téléchargement de \(game.title) en cours dans Playmelt.")
            sendState()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close()
            activeInstallerProcess = nil; activeInstallerID = nil
            installCoordinator.finishDirect(id: id, success: false, message: "Impossible de lancer l'installateur : \(error.localizedDescription)")
            result(false, "Erreur au lancement de l'installation.")
            sendToast("Erreur au lancement de l'installation.", error: true)
            sendState()
        }
    }
    func stopNativeInstaller(completion: (() -> Void)? = nil) {
        guard let process = activeInstallerProcess else { completion?(); return }
        if let completion { installerShutdownWaiters.append(completion) }
        if process.isRunning { process.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak process] in
            guard let self, let process, self.activeInstallerProcess === process, process.isRunning else { return }
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }
    private func finishNativeInstallerIfExited(id: UUID, process: Process) {
        guard activeInstallerProcess === process, activeInstallerID == id, installerEOF, installerExitStatus != nil else { return }
        if installCoordinator.acceptsDirect(id: id) {
            installCoordinator.finishDirect(id: id, success: false, message: "L’installateur s’est arrêté sans confirmation de fin Steam.")
            if !closing { sendState() }
        }
        activeInstallerProcess = nil; activeInstallerID = nil; installerBuffer = Data()
        let callbacks = installerShutdownWaiters; installerShutdownWaiters.removeAll()
        for callback in callbacks { callback() }
    }
    func handleInstallerUpdate(json: [String: Any], game: Game, id: UUID, account: String) {
        guard !closing, installCoordinator.acceptsDirect(id: id), model.selectedAccountID == account else { return }
        let status = json["status"] as? String ?? "downloading"
        let phase = json["phase"] as? String ?? "Téléchargement"
        let message = json["message"] as? String ?? "Installation en cours…"
        let percent = json["percent"] as? Double
        let downloaded = (json["bytesDownloaded"] as? NSNumber)?.uint64Value ?? 0
        let total = (json["bytesTotal"] as? NSNumber)?.uint64Value ?? 0
        let speed = json["speed"] as? String ?? ""
        if phase != lastNotifiedPhase && !phase.isEmpty {
            lastNotifiedPhase = phase
            if phase == "Installation" {
                sendToast("Installation des fichiers de \(game.title)…")
            } else if phase == "Vérification" {
                sendToast("Configuration du moteur pour \(game.title)…")
            }
        }
        if status == "launch-ready" {
            guard installCoordinator.finishDirect(id: id, success: true, message: message) else { return }
            sendToast("Fichiers de \(game.title) préparés. Le lancement reste à vérifier.")
            refresh { [weak self] in
                guard let self else { return }
                self.result(true, "Fichiers de \(game.title) préparés.")
                let active = activeSteamAccount(TextVDF.read(self.model.home.appendingPathComponent("Library/Application Support/Steam/config/loginusers.vdf")).object("users"))
                if self.installCoordinator.permitsDirectAutoLaunch(id: id, accountID: self.model.selectedAccountID, executionBlocked: self.renderProtectionEnabled),
                   SteamInstallAccountContext.permitsAutoLaunch(expected: account, active: active),
                   let installed = self.model.games.first(where: { $0.appId == game.appId && $0.installed && $0.complete }) {
                    self.route(installed, installing: false, requestedRuntime: nil)
                }
            }
        } else if status == "failed" {
            installCoordinator.finishDirect(id: id, success: false, message: message)
            sendToast("Échec de l'installation de \(game.title) : \(message)", error: true)
            sendState()
        } else {
            installCoordinator.updateDirect(id: id, status: status, message: message, progress: percent, downloaded: downloaded, total: total, speed: speed, phase: phase)
        }
    }
    func validatedSteamRuntime(_ game: Game, installing: Bool, requestedRuntime: String?) -> Runtime? {
        guard !renderProtectionEnabled else { result(false, "Rendus en cours : installation et lancement suspendus."); return nil }
        guard LibraryModel.validAppID(game.appId), let runtime = model.runtimes.first(where: { $0.id == (installing ? requestedRuntime ?? game.runtimeId : game.runtimeId) && $0.available }) else { result(false, "Aucun client Steam utilisable pour cette route."); return nil }
        guard SteamGameLaunchProfile.supportsInstallation(appID: game.appId, runtime: runtime) else { result(false, "Ce jeu nécessite un autre moteur graphique."); return nil }
        if !installing, let reason = SteamGameLaunchProfile.blockReason(appID: game.appId, platform: runtime.platform, renderer: runtime.renderer, graphicsValidated: runtime.graphicsValidated) { result(false, reason); return nil }
        if runtime.platform == "windows" && (runtimeIsBusy || d3dMetalIsBusy || steamBootstrap.busy || d3dMetalSteamBootstrap.busy) { result(false, "La préparation Windows est encore en cours."); return nil }
        if installing {
            guard !model.hasCompleteInstallation(appID: game.appId, runtimeID: runtime.id), let info = model.metadata[game.appId], info.platforms.contains(runtime.platform == "mac" ? "macos" : "windows") else { result(false, "Cette édition ne peut pas être installée avec le client choisi."); return nil }
        } else if !game.installed || !game.complete || game.json(runtimes: model.runtimes)["canLaunch"] as? Bool != true { result(false, "Installation absente ou incomplète. Vérifiez-la dans Steam."); return nil }
        let active = activeSteamAccount(TextVDF.read(runtime.steamRoot.appendingPathComponent("config/loginusers.vdf")).object("users"))
        if let active, !model.selectedAccountID.isEmpty, active != model.selectedAccountID { result(false, "Changez de compte dans Steam pour utiliser le compte sélectionné."); return nil }
        return runtime
    }
    static func windowsLaunchArguments(appID: String) -> [String]? {
        SteamGameLaunchProfile.windowsArguments(appID: appID)
    }
    func dispatchSteam(_ game: Game, runtime: Runtime, installing: Bool, onFailure: @escaping (String) -> Void,
                       completion: @escaping (Bool, String) -> Void) {
        guard !renderProtectionEnabled else { completion(false, "Rendus en cours : installation et lancement suspendus."); return }
        guard runtime.executionAllowed else { completion(false, WindowsExecutionPolicy.message); return }
        let key = "game:\(runtime.id):\(game.appId)"
        guard !closing, let token = requestGate.acquire(key) else { completion(false, "Demande déjà envoyée à Steam."); return }
        let finish: (Bool, String) -> Void = { [weak self] ok, message in
            self?.requestGate.finish(key, token: token); completion(ok, message)
        }
        let message = installing ? "Installation demandée dans Steam." : "Ouverture de \(game.title)…"
        let uri = "steam://\(installing ? "install" : "rungameid")/\(game.appId)"
        if let app = runtime.appURL, let url = URL(string: uri) {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: .init()) { _, error in DispatchQueue.main.async { finish(error == nil, error == nil ? message : "Steam n’a pas accepté la demande.") } }
        } else if runtime.platform == "windows" {
            guard let args = installing ? [uri] : SteamGameLaunchProfile.windowsArguments(appID: game.appId, renderer: runtime.renderer, graphicsValidated: runtime.graphicsValidated) else { finish(false, "Le moteur graphique de ce jeu reste à valider."); return }
            let extra = installing ? [] : gameSettingsStore.launchArguments(for: gameSettingsContext(game))
            runWindowsClient(runtime, arguments: args + extra, onFailure: onFailure) { ok, error in finish(ok, ok ? message : error) }
        } else { finish(false, "Client Steam indisponible.") }
    }
    func runWindowsClient(_ runtime: Runtime, arguments: [String], onFailure: @escaping (String) -> Void,
                          completion: @escaping (Bool, String) -> Void) {
        guard runtime.executionAllowed else { completion(false, WindowsExecutionPolicy.message); return }
        let key = "windows-client:" + arguments.joined(separator: "\u{1f}")
        guard !closing, let token = requestGate.acquire(key) else { completion(false, "Demande déjà envoyée à Steam Windows."); return }
        defer { requestGate.finish(key, token: token) }
        guard !renderProtectionEnabled else { completion(false, "Rendus en cours : Steam Windows est suspendu."); return }
        let candidate = runtime.id == "playmelt-d3dmetal" ? try? d3dMetalRuntime.descriptor(base: runtimeSetup.descriptor()) : runtimeSetup.descriptor()
        guard let descriptor = candidate else { completion(false, "Le moteur DirectX 12 n’est pas préparé."); return }
        guard runtime.verifiedIndependentEngine, descriptor.readyEngine, descriptor.steamInstalled,
              runtime.prefixURL == descriptor.prefixURL, runtime.wineURL == descriptor.wineURL else { completion(false, "Le moteur Windows ou Steam Windows n’est pas prêt."); return }
        do {
            _ = try clientLauncher.launch(executable: descriptor.wineURL, arguments: [descriptor.steamRoot.appendingPathComponent("steam.exe").path] + arguments,
                                          environment: descriptor.environment, directory: descriptor.prefixURL) { code in
                if code != 0 { onFailure("Steam Windows s’est arrêté avec une erreur.") }
            }
            completion(true, "Ouverture de Steam Windows…")
        }
        catch { completion(false, "Impossible d’ouvrir Steam Windows.") }
    }
    func route(_ game: Game, installing: Bool, requestedRuntime: String?) {
        guard !closing, !renderProtectionEnabled else { result(false, "Rendus en cours : installation et lancement suspendus."); return }
        guard !CommandLine.arguments.contains("--audit-read-only") else { result(false, "Mode de vérification : installations et lancements désactivés."); return }
        if installing {
            guard !installCoordinator.isActive else { result(false, "Un suivi d’installation est déjà en cours. Arrêtez le suivi avant une autre demande."); return }
        } else {
            // Abonnement : sans effet tant que le paywall n'est pas activé.
            let access = entitlementStore.decision()
            guard access.allowsLaunch else { result(false, access.message); return }
        }
        if game.store == "xbox" {
            let urlStr = game.epicLaunchID.isEmpty ? "https://www.xbox.com/play" : game.epicLaunchID
            if let url = URL(string: urlStr) {
                XboxCloudWindowController.shared.open(url: url, isGameLaunch: url.path.contains("/play/launch/"))
                result(true, "Lancement de \(game.title) sur Xbox Cloud Gaming…")
            }
            return
        }
        if game.store == "gog" {
            model.gogConnector.launch(gameID: game.id) { [weak self] ok, msg in
                self?.result(ok, msg)
            }
            return
        }
        if installing, game.store == "epic" {
            installEpicGame(game)
            return
        }
        var extraArguments: [String] = []
        var requestedBackend = "auto"
        if !installing, game.platform == "windows", game.installed {
            let context = gameSettingsContext(game)
            let preferences = gameSettingsStore.snapshot(game: context, hardware: [:], displays: [])
            guard preferences["status"] as? String != "error" else {
                result(false, "Ouvrez les paramètres du jeu : \(preferences["error"] as? String ?? "configuration invalide").")
                return
            }
            extraArguments = gameSettingsStore.launchArguments(for: context)
            requestedBackend = gameSettingsStore.requestedBackend(for: context)
        }
        if !installing, game.platform == "windows", game.installed, game.complete,
           let script = ensureLaunchScript(for: game, requestedBackend: requestedBackend) {
            let key = "launch-script:\(game.appId.isEmpty ? game.id : game.appId)"
            guard let token = requestGate.acquire(key) else { result(false, "Demande déjà envoyée."); return }
            defer { requestGate.finish(key, token: token) }
            do {
                let launchStartTime = Date()
                let gameKey = game.appId.isEmpty ? game.id : game.appId
                let isEpic = game.store == "epic" || game.installSource == "epic"
                var monitorTimer: Timer?
                var knownUnlockedIDs: Set<String> = []
                if isEpic, let cached = AchievementStore.shared.cachedAchievements(for: gameKey),
                   let completed = cached["completed"] as? [[String: Any]] {
                    knownUnlockedIDs = Set(completed.compactMap { $0["name"] as? String })
                }
                if isEpic {
                    monitorTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
                        self?.fetchEpicAchievements(appId: gameKey) { formatted in
                            guard let formatted = formatted,
                                  let completed = formatted["completed"] as? [[String: Any]] else { return }
                            for item in completed {
                                if let name = item["name"] as? String, !knownUnlockedIDs.contains(name) {
                                    knownUnlockedIDs.insert(name)
                                    let dispName = item["displayName"] as? String ?? name
                                    let desc = item["description"] as? String ?? ""
                                    let icon = item["iconLink"] as? String
                                    AchievementToastWindowController.shared.show(title: "Succès débloqué !", name: dispName, description: desc, iconURL: icon)
                                }
                            }
                        }
                    }
                }
                _ = try clientLauncher.launch(executable: URL(fileURLWithPath: "/bin/bash"),
                                              arguments: [script.path] + (game.appId == "2651280" ? [] : extraArguments),
                                              environment: ProcessInfo.processInfo.environment,
                                              directory: script.deletingLastPathComponent()) { [weak self] code in
                    monitorTimer?.invalidate()
                    monitorTimer = nil
                    let elapsed = Int64(Date().timeIntervalSince(launchStartTime))
                    if elapsed > 2 {
                        PlaytimeStore.shared.addSession(key: gameKey, seconds: elapsed)
                        self?.refresh()
                    }
                    if code != 0 { self?.result(false, "Le jeu s’est arrêté (code \(code)). Consultez le diagnostic du lancement.") }
                }
                result(true, "Ouverture de \(game.title)…")
                return
            } catch {
                result(false, "Impossible de lancer le jeu.")
                return
            }
        }
        if !installing, game.platform == "windows", game.installed, game.complete,
           game.installSource == "local" || game.appId == "2651280" || requestedBackend != "auto" {
            result(false, "Le lancement de cette installation locale n’est pas prêt. Vérifiez son dossier, ses paramètres et le moteur choisi.")
            return
        }
        if installing, game.store == "steam", !game.appId.isEmpty {
            if prefersNativeSteam(game, requestedRuntime: requestedRuntime) {
                guard let runtime = validatedSteamRuntime(game, installing: true, requestedRuntime: "steam-mac") else { return }
                dispatchSteam(game, runtime: runtime, installing: true, onFailure: { [weak self] in self?.result(false, $0) }) { [weak self] in self?.result($0, $1) }
                return
            }
            startNativeSteamInstall(game: game, autoPlay: false, requestedRuntime: requestedRuntime)
            return
        }
        if game.store == "epic" {
            if installing {
                installEpicGame(game)
                return
            }
            guard WindowsExecutionPolicy.permits(platform: game.platform) else { result(false, WindowsExecutionPolicy.message); return }
            guard game.complete, !game.epicLaunchID.isEmpty, let encoded = game.epicLaunchID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), let url = URL(string: "com.epicgames.launcher://apps/\(encoded)?action=launch&silent=true") else { result(false, "Route Epic indisponible."); return }
            let key = "epic:\(game.appId)"
            guard let token = requestGate.acquire(key) else { result(false, "Demande déjà envoyée à Epic."); return }
            NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/Applications/Epic Games Launcher.app"), configuration: .init()) { [weak self] _, error in DispatchQueue.main.async {
                self?.requestGate.finish(key, token: token)
                self?.result(error == nil, error == nil ? "Ouverture de \(game.title)…" : "Epic n’a pas accepté la demande.")
            } }; return
        }
        if game.store == "xbox" {
            model.xboxConnector.launch(titleID: game.appId) { [weak self] ok, msg in
                DispatchQueue.main.async { self?.result(ok, msg) }
            }
            return
        }
        if game.store == "gog" {
            model.gogConnector.launch(gameID: game.id) { [weak self] ok, msg in
                DispatchQueue.main.async { self?.result(ok, msg) }
            }
            return
        }
        guard let runtime = validatedSteamRuntime(game, installing: installing, requestedRuntime: requestedRuntime) else { return }
        dispatchSteam(game, runtime: runtime, installing: installing, onFailure: { [weak self] message in self?.result(false, message) }) { [weak self] ok, message in self?.result(ok, message) }
    }
    func uninstallGame(_ game: Game) {
        guard !closing, !renderProtectionEnabled, !CommandLine.arguments.contains("--audit-read-only") else {
            result(false, "Désinstallation suspendue par le mode de protection."); return
        }
        guard !installCoordinator.isActive, clientLauncher.activeCount == 0 else { result(false, "Terminez l’installation ou fermez le jeu avant de désinstaller."); return }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let steamRoots = model.runtimes.flatMap { model.libraryRoots($0) }
        let roots = [home.appendingPathComponent("Library/Application Support/Playmelt/Games")] + steamRoots.map { $0.appendingPathComponent("steamapps/common") }
        do {
            let plan = try GameUninstallPlan.make(game: game, installRoots: roots, steamRoots: steamRoots)
            let alert = NSAlert()
            alert.messageText = "Désinstaller \(game.title) ?"
            alert.informativeText = "Voulez-vous vraiment désinstaller ce jeu ?\n\nLes fichiers du jeu seront placés dans votre Corbeille pour libérer de l'espace sur le disque.\n\nVos sauvegardes synchronisées sur le Cloud restent conservées."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Annuler")
            let trashButton = alert.addButton(withTitle: "Déplacer dans la Corbeille")
            if #available(macOS 11.0, *) {
                trashButton.hasDestructiveAction = true
            }
            guard alert.runModal() == .alertSecondButtonReturn else { return }
            guard !closing, !renderProtectionEnabled, !installCoordinator.isActive, clientLauncher.activeCount == 0,
                  try GameUninstallPlan.make(game: game, installRoots: roots, steamRoots: steamRoots) == plan else {
                result(false, "L’installation a changé. Aucun fichier n’a été déplacé."); return
            }
            for item in plan.items { try fm.trashItem(at: item, resultingItemURL: nil) }
            refresh { [weak self] in self?.result(true, "\(game.title) a été désinstallé. Ses fichiers sont dans la Corbeille.") }
        } catch {
            refresh()
            result(false, "Désinstallation incomplète : \(error.localizedDescription). Vérifiez la Corbeille avant de réessayer.")
        }
    }
    func beginShutdown() {
        closing = true; requestGate.shutdown(); installCoordinator.cancel(); installCoordinator.shutdown(); clientLauncher.shutdown()
        authentication?.shutdown(); authentication = nil
        scanID = UUID(); afterRefresh.removeAll()
    }
}

/// Bande de déplacement de la fenêtre, posée au-dessus du web dans la zone des
/// boutons de fenêtre : glisser déplace, double-clic agrandit (réglage système).
final class WindowDragStrip: NSView {
    static let height: CGFloat = 52
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
            if action == "Minimize" { window.performMiniaturize(nil) } else if action != "None" { window.performZoom(nil) }
        } else {
            window.performDrag(with: event)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    var handler: ScriptHandler!
    var shuttingDown = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        if UserDefaults.standard.object(forKey: RenderProtection.preferenceKey) == nil {
            UserDefaults.standard.set(true, forKey: RenderProtection.preferenceKey)
        }
        guard let resource = Bundle.main.url(forResource: "index", withExtension: "html") else { NSApp.terminate(nil); return }
        handler = ScriptHandler(resourceURL: resource)
        let content = WKUserContentController(); content.add(handler!, name: "metalmax")
        let config = WKWebViewConfiguration(); config.userContentController = content; config.websiteDataStore = .nonPersistent()
        let artwork = SteamArtworkHandler(); artwork.handler = handler; config.setURLSchemeHandler(artwork, forURLScheme: "metalmaxart")
        webView = WKWebView(frame: .zero, configuration: config); webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground"); handler.webView = webView
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: min(1380, visible.width - 60), height: min(900, visible.height - 60)), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = Bundle.main.bundleIdentifier?.hasSuffix(".preview") == true ? "MetalMax Preview" : "Playmelt"
        // Barre intégrée : le contenu occupe toute la fenêtre, plus de bande transparente sur le bureau.
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true; window.titlebarSeparatorStyle = .none
        window.minSize = NSSize(width: 820, height: 600); window.backgroundColor = .clear; window.isOpaque = false
        window.appearance = NSAppearance(named: .aqua)
        let backdrop = NSVisualEffectView(); backdrop.material = .underWindowBackground; backdrop.blendingMode = .behindWindow; backdrop.state = .followsWindowActiveState
        backdrop.addSubview(webView); webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([webView.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor), webView.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor), webView.topAnchor.constraint(equalTo: backdrop.topAnchor), webView.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor)])
        let dragStrip = WindowDragStrip(); dragStrip.translatesAutoresizingMaskIntoConstraints = false; backdrop.addSubview(dragStrip)
        NSLayoutConstraint.activate([dragStrip.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor), dragStrip.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor), dragStrip.topAnchor.constraint(equalTo: backdrop.topAnchor), dragStrip.heightAnchor.constraint(equalToConstant: WindowDragStrip.height)])
        window.contentView = backdrop; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        webView.loadFileURL(resource, allowingReadAccessTo: resource.deletingLastPathComponent())
        handler.autoRestoreEpic()
        let menu = NSMenu(); let appMenu = NSMenu()
        UpdaterController.shared.start()
        if let target = UpdaterController.shared.updaterMenuTarget {
            let updateItem = appMenu.addItem(withTitle: "Rechercher les mises à jour…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
            updateItem.target = target
        }
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quitter Playmelt", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let item = NSMenuItem(); item.submenu = appMenu; menu.addItem(item); NSApp.mainMenu = menu
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { handler.refresh() }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.standardizedFileURL == handler.resourceURL.standardizedFileURL ? .allow : .cancel)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if shuttingDown { return .terminateLater }; shuttingDown = true
        guard let handler else { return .terminateNow }
        handler.beginShutdown()
        let group = DispatchGroup()
        group.enter(); handler.steamBootstrap.shutdown { group.leave() }
        group.enter(); handler.d3dMetalSteamBootstrap.shutdown { group.leave() }
        group.enter(); handler.d3dMetalRuntime.shutdown { group.leave() }
        group.enter(); handler.runtimeSetup.shutdown { group.leave() }
        group.enter(); handler.epicConnector.shutdown { group.leave() }
        group.enter(); handler.finishRendererImport { group.leave() }
        group.enter(); handler.libraryScanner.shutdown { group.leave() }
        group.enter(); handler.stopNativeInstaller { group.leave() }
        group.notify(queue: .main) { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
if CommandLine.arguments.contains("--self-test") {
    runSelfTests()
} else if CommandLine.arguments.contains("--diagnose-json") {
    let model = LibraryModel(); let runtime = RuntimeSetup(); let metalStore = D3DMetalStore(); let metalRuntime = D3DMetalRuntime(store: metalStore)
    model.windowsDescriptor = runtime.descriptor(); model.d3dMetalDescriptor = try? metalRuntime.descriptor(base: runtime.descriptor()); model.refresh(); model.epicAvailability = EpicConnector().availability()
    var state = model.state(); var runtimeState = runtime.snapshot(); var metalState = metalStore.snapshot()
    metalState.merge(metalRuntime.snapshot(base: runtime.descriptor())) { _, latest in latest }; runtimeState["d3dMetal"] = metalState
    state["windowsRuntime"] = runtimeState; state["installJob"] = NSNull()
    state["renderProtectionEnabled"] = RenderProtection.enabled(in: model.preferences)
    runtimeState["executionPolicy"] = WindowsExecutionPolicy.json; state["windowsRuntime"] = runtimeState
    if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) { FileHandle.standardOutput.write(data); print("") }
} else {
    let app = NSApplication.shared; app.setActivationPolicy(.regular)
    let delegate = AppDelegate(); app.delegate = delegate; app.run()
}
