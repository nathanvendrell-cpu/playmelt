import AppKit
import WebKit
import Foundation
import Darwin
import Sparkle
import GameController

final class SteamArtworkHandler: NSObject, WKURLSchemeHandler {
    weak var handler: ScriptHandler?
    private let ioQueue = DispatchQueue(label: "fr.playmelt.artwork", qos: .userInitiated)
    private let memory = NSCache<NSString, NSData>()
    private var tasks: [ObjectIdentifier: UUID] = [:]
    // Let NSCache respond to system memory pressure without a fixed Playmelt cap.
    override init() { super.init(); memory.totalCostLimit = 0 }
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
        let key = ObjectIdentifier(urlSchemeTask as AnyObject), token = UUID()
        tasks[key] = token
        let files = model.runtimes.flatMap { runtime -> [URL] in
            let root = runtime.steamRoot.appendingPathComponent("appcache/librarycache").resolvingSymlinksInPath()
            return Self.candidateFiles(root: root, appID: id, info: model.metadata[id], portrait: url.lastPathComponent == "portrait")
        }
        ioQueue.async { [weak self] in
            guard let self else { return }
            var found: (Data, String)?
            for file in files {
                guard let info = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                      let size = info.fileSize, size > 0, size <= 8_000_000 else { continue }
                let cacheKey = "\(file.path):\(size):\(info.contentModificationDate?.timeIntervalSince1970 ?? 0)" as NSString
                guard let data = (self.memory.object(forKey: cacheKey) as Data?) ?? (try? Data(contentsOf: file)) else { continue }
                let mime: String
                if data.starts(with: [0xff, 0xd8]) { mime = "image/jpeg" }
                else if data.starts(with: [0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a]) { mime = "image/png" }
                else if data.count >= 12, String(data: data.prefix(4), encoding: .ascii) == "RIFF", String(data: data[8..<12], encoding: .ascii) == "WEBP" { mime = "image/webp" }
                else { continue }
                self.memory.setObject(data as NSData, forKey: cacheKey, cost: data.count)
                found = (data,mime); break
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.tasks[key] == token else { return }
                self.tasks.removeValue(forKey: key)
                guard let (data,mime) = found else { urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist)); return }
                urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
                urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
            }
        }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask as AnyObject))
    }
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
                    case "signed-out", "identity-unverified":
                        let reasons = [
                            "userinfo-too-large": "La réponse d’identité Steam dépasse le format attendu.",
                            "userinfo-malformed": "La réponse d’identité Steam est illisible.",
                            "userinfo-not-signed-in": "La page Steam ne confirme pas une session connectée dans ses données d’identité.",
                            "logged-in-string": "Steam fournit un état de connexion textuel non pris en charge.",
                            "logged-in-number": "Steam fournit un état de connexion numérique non pris en charge.",
                            "logged-in-string-true": "Steam fournit l’état de connexion textuel « true », non pris en charge.",
                            "logged-in-string-false": "Steam fournit l’état de connexion textuel « false », non pris en charge.",
                            "logged-in-string-one": "Steam fournit l’état de connexion textuel « 1 », non pris en charge.",
                            "logged-in-string-zero": "Steam fournit l’état de connexion textuel « 0 », non pris en charge.",
                            "logged-in-number-one": "Steam fournit l’état de connexion numérique 1, non pris en charge.",
                            "logged-in-number-zero": "Steam fournit l’état de connexion numérique 0, non pris en charge.",
                            "logged-in-unavailable": "L’état de connexion est absent des données d’identité Steam.",
                            "userinfo-id-number": "Steam fournit un identifiant numérique dont la précision ne peut pas être garantie.",
                            "userinfo-id-unavailable": "L’identifiant est absent des données d’identité Steam.",
                            "userinfo-id-invalid": "La page Steam ne fournit pas un identifiant de compte vérifiable dans ses données d’identité.",
                            "identity-node-unavailable": "Le bloc d’identité Steam n’est pas présent dans le format de cette page.",
                            "userinfo-attribute-unavailable": "Le bloc Steam ne contient pas ses données d’identité attendues.",
                            "viewer-id-unavailable": "L’identifiant du compte connecté n’est pas disponible dans le format de cette page Steam."
                        ]
                        if case .success(let value) = evaluation, let data = value as? [String: Any], let reason = data["reason"] as? String, let detail = reasons[reason] {
                            message = detail + " La session et la bibliothèque mémorisée sont conservées."
                        } else { message = "Terminez la connexion dans la fenêtre Steam officielle." }
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

final class XboxCloudWindowController: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate, WKScriptMessageHandler {
    var authorizeLaunch:((@escaping(Bool,String)->Void)->Void)?
    var requiresController:((URL)->Bool)?
    var onRecentGames:(([String],XboxRecentGames.Evidence)->Void)?
    var isVisible:Bool {panel?.superview != nil}
    static let shared = XboxCloudWindowController()
    private var panel: NSView?
    private var webView: WKWebView?
    private let status = NSTextField(labelWithString: "Xbox Cloud Gaming")
    /// Jeu demandé depuis Playmelt : si la session site n'est pas établie,
    /// le sign-in revient directement sur ce jeu (pont direct Playmelt → stream).
    private var pendingLaunchURL: URL?
    private var launchRetried = false
    private var authAttempted = false
    /// Notified after each completed navigation (sign-in state may have changed) and on close.
    var onSessionMayHaveChanged: (() -> Void)?

    func open(url: URL, isGameLaunch: Bool = false, over localView: WKWebView) {
        XboxWebSession.prepare { [weak self,weak localView] in
            guard let self,let localView else{return};self.openPrepared(url:url,isGameLaunch:isGameLaunch,over:localView)
        }
    }
    private func openPrepared(url:URL,isGameLaunch:Bool,over localView:WKWebView) {
        guard XboxConnector.isAllowedCloudURL(url), let parent = localView.superview else { return }
        if isGameLaunch,requiresController?(url)==true,GCController.controllers().isEmpty {
            let alert=NSAlert();alert.messageText="Connecte une manette pour ce jeu"
            alert.informativeText="Ce jeu Xbox Cloud est annoncé pour la manette. Connecte-la en Bluetooth ou en USB, puis clique à nouveau sur Jouer."
            alert.addButton(withTitle:"Compris")
            if let window=localView.window {alert.beginSheetModal(for:window)}
            return
        }
        pendingLaunchURL = isGameLaunch ? url : nil;launchRetried=false;authAttempted=false
        if let panel, let webView {
            panel.isHidden = false
            if webView.url != url { webView.load(URLRequest(url: url)) }
            localView.window?.makeFirstResponder(webView)
            return
        }

        let config = WKWebViewConfiguration()
        // Persistent store: the Microsoft account session survives app restarts.
        config.websiteDataStore = XboxWebSession.store
        config.preferences.isElementFullscreenEnabled = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.allowsAirPlayForMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(self,name:"playmeltXboxPlayback")
        config.userContentController.addUserScript(WKUserScript(source:Self.playbackObservation,injectionTime:.atDocumentEnd,forMainFrameOnly:false))

        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1600, height: 900), configuration: config)
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        wv.navigationDelegate = self
        wv.uiDelegate = self
        self.webView = wv

        let panel = NSVisualEffectView()
        panel.material = .windowBackground; panel.state = .active
        panel.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: parent.topAnchor, constant: 52),
            panel.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        ])
        let back = NSButton(title: "Retour à Playmelt", target: self, action: #selector(closePanel))
        let previous = NSButton(title: "←", target: self, action: #selector(goBack))
        previous.setAccessibilityLabel("Page précédente")
        let reload = NSButton(title: "Actualiser", target: self, action: #selector(reloadPage))
        status.lineBreakMode = .byTruncatingMiddle
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [back, previous, status, reload])
        bar.spacing = 12; bar.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        for view in [bar, wv] { view.translatesAutoresizingMaskIntoConstraints = false; panel.addSubview(view) }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: panel.topAnchor), bar.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: panel.trailingAnchor), bar.heightAnchor.constraint(equalToConstant: 52),
            wv.topAnchor.constraint(equalTo: bar.bottomAnchor), wv.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: panel.trailingAnchor), wv.bottomAnchor.constraint(equalTo: panel.bottomAnchor)
        ])
        self.panel = panel
        wv.load(URLRequest(url: url)); localView.window?.makeFirstResponder(wv)
    }
    @objc func closePanel() {
        // Destroy the player to release video/audio and controllers; cookies remain in WebKit.
        webView?.stopLoading(); webView?.navigationDelegate = nil; webView?.uiDelegate = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName:"playmeltXboxPlayback")
        webView?.removeFromSuperview(); panel?.removeFromSuperview(); webView = nil; panel = nil
        pendingLaunchURL = nil; launchRetried = false; authAttempted = false
        onSessionMayHaveChanged?()
    }
    @objc private func goBack() { webView?.goBack() }
    @objc private func reloadPage() { webView?.reload() }
    private static let playbackObservation="""
    (()=>{
      if(!/(^|\\.)xbox\\.com$/.test(location.hostname))return;
      const sent=new Set();let recentSent=false,timer=null;
      function notify(ids,evidence){try{window.webkit.messageHandlers.playmeltXboxPlayback.postMessage({ids,evidence});}catch{}}
      function productID(path){return (path.match(/^\\/(?:stream|products)\\/([A-Za-z0-9]{12})(?:\\/|$)/)?.[1]||path.match(/\\/(?:launch|games)\\/(?:[^/]+\\/)?([A-Za-z0-9]{12})(?:\\/|$)/)?.[1])?.toUpperCase();}
      function scan(){
        const id=/^\\/stream\\/|\\/launch\\//.test(location.pathname)?productID(location.pathname):undefined;
        if(id && Array.from(document.querySelectorAll('video')).some(v=>!v.paused&&v.readyState>=2&&v.videoWidth>0)&&!sent.has(id)){sent.add(id);notify([id],"video-playback");}
        if(!recentSent){
          const heading=Array.from(document.querySelectorAll('h1,h2,h3')).find(h=>/jump back in|reprendre une partie|reprendre le jeu|reprenez votre partie/i.test(h.textContent||''));
          if(heading){let section=heading.parentElement;for(let n=0;section&&n<4;n++,section=section.parentElement){
            const ids=Array.from(section.querySelectorAll('a[href]')).map(a=>productID(a.pathname)).filter(Boolean);
            if(ids.length){recentSent=true;notify(Array.from(new Set(ids)).slice(0,12),"recent-list");break;}
          }}
        }
      }
      document.addEventListener('playing',scan,true);
      const observer=new MutationObserver(()=>{if(timer===null)timer=setTimeout(()=>{timer=null;scan()},500)});observer.observe(document.documentElement,{childList:true,subtree:true});scan();
      addEventListener('pagehide',()=>{observer.disconnect();if(timer!==null)clearTimeout(timer)},{once:true});
    })();
    """
    func userContentController(_ userContentController:WKUserContentController,didReceive message:WKScriptMessage) {
        guard message.name=="playmeltXboxPlayback",XboxCloudRoute.isXboxHost(message.frameInfo.securityOrigin.host.lowercased()),
              let body=message.body as? [String:Any],Set(body.keys)==["ids","evidence"],
              let raw=body["evidence"] as? String,let evidence=XboxRecentGames.Evidence(rawValue:raw),
              let ids=body["ids"] as? [String],ids.count<=20,
              ids.allSatisfy(XboxRecentGames.validID) else{return}
        onRecentGames?(ids,evidence)
    }

    // Microsoft sign-in (login.live.com / login.microsoftonline.com) uses window.open popups:
    // keep them inside the same view instead of silently dropping them.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, url.scheme == "https" { webView.load(URLRequest(url: url)) }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        status.stringValue = [webView.url?.host, webView.title].compactMap { $0 }.joined(separator: " · ")
        onSessionMayHaveChanged?()
        resumePendingLaunch(webView)
    }

    /// Pont direct : un clic sur un jeu dans Playmelt doit ouvrir le stream du jeu.
    /// Si xbox.com renvoie vers sa home (session absente), on réessaie le lancement,
    /// puis on passe par le sign-in avec returnUrl = le jeu, pour un lancement automatique.
    private func resumePendingLaunch(_ webView: WKWebView) {
        guard let target = pendingLaunchURL, let current = webView.url,
              let host = current.host?.lowercased(), (host == "xbox.com" || host.hasSuffix(".xbox.com")) else { return }
        if XboxCloudRoute.isLaunch(current) {
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
        if XboxCloudRoute.isLaunch(url),let authorizeLaunch {
            authorizeLaunch { [weak self] ok,message in if !ok {self?.status.stringValue=message};decisionHandler(ok ? .allow : .cancel) };return
        }
        if ["https", "about", "blob", "data"].contains(url.scheme ?? "") { decisionHandler(.allow); return }
        decisionHandler(.cancel)
    }

    // Voice chat in cloud games: ask macOS (system prompt) instead of auto-granting.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler((origin.host == "xbox.com" || origin.host.hasSuffix(".xbox.com")) ? .prompt : .deny)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { status.stringValue = "Connexion Xbox indisponible · Actualiser pour réessayer" }
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
    lazy var d3dMetalSteamBootstrap = SteamWindowsBootstrap(downloadsRoot: runtimeSetup.root.appendingPathComponent("D3DMetal/downloads"), cacheRoot: runtimeSetup.root.appendingPathComponent("downloads/SteamBootstrap"), descriptor: { [weak self] in
        guard let self else { return nil }
        return try? self.d3dMetalRuntime.descriptor(base: self.runtimeSetup.descriptor())
    })
    let installCoordinator = SteamInstallCoordinator(recoveryURL:FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Playmelt/Installations/installation-state.json"))
    let requestGate = SteamRequestGate()
    let clientLauncher = UserProcessLauncher()
    let steamProcessLauncher = SteamClientUserProcessLauncher()
    lazy var steamClientLifecycle = SteamClientLifecycle(launcher: steamProcessLauncher)
    private let gameSettingsStore = GameSettingsStore(root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Playmelt/GameSettings", isDirectory: true),
                                                      nvidiaBridgeAvailable: { NvidiaBridgeStore.shared.available() })
    private let gameSettingsQueue = DispatchQueue(label: "fr.playmelt.game-settings", qos: .utility)
    let accountService = AccountService()
    let accountWebAuthentication = AccountWebAuthentication()
    private let hubFeed = HubFeedStore()
    private let gameMedia = GameMediaCatalog()
    private let gameMediaPlayer = GameMediaPlayer()
    private let profileProgression = ProfileProgression()
    private let playerProfile = PlayerProfile()
    private let issueReports = IssueReports()
    let benchmarks = Benchmarks()
    let localGameImport = LocalGameImport()
    private var launchDiagnostics: [[String:Any]] = []
    private var gameSettingsPayload: [String: Any]?
    private var gameSettingsRequest = UUID()
    var authentication: SteamAuthentication?
    var loading = false
    private var closing = false
    private let hubBrowser = HubBrowserPanel()
    private var bigPictureEnteredFullscreen = false
    let resourceURL: URL
    var activeInstallerProcess: Process?
    private var openingNativeSteamForInstall = false
    private var queuedSteamInstall:(id:UUID,game:Game,account:String,runtimeID:String,autoPlay:Bool)?
    private var preparingSteamBaseEngine = false, preparingSteamRenderer = false
    private var officialSteamPreparation:SteamOfficialPreparation?
    private var officialSteamTimer:Timer?
    private var officialSteamBootstrapIntent:SteamBootstrapIntent?
    private var officialSteamRendererOwnerID:UUID?
    private var officialSteamBaseEngineOwnerID:UUID?
    private let officialSteamBaseEngineGroup=DispatchGroup()
    private var officialSteamStopping=0
    let officialSteamStopGroup=DispatchGroup()
    private var steamReuseToken:OwnedOperationToken?
    let steamReuseGroup=DispatchGroup()
    private let steamReuseQueue=DispatchQueue(label:"playmelt.steam-reuse",qos:.utility)
    private var activeInstallerID: UUID?
    private var installerBuffer = Data()
    private var installerEOF = false
    private var installerExitStatus: Int32?
    private var installerShutdownWaiters: [() -> Void] = []
    private var lastNotifiedPhase = ""
    private var epicLoginController: EpicLoginSheetController?
    private var xboxCatalogTimer: Timer?
    private var nvidiaBridgeStore: NvidiaBridgeStore { .shared }
    private var nvidiaBridgeInstalling: Bool { nvidiaBridgeStore.status()["busy"] as? Bool == true }

    private var epicCacheURL: URL {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Playmelt")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport.appendingPathComponent(".epic_cache.json")
    }

    func autoRestoreEpic() {
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
        hubBrowser.onXboxCloud = { [weak self] url in
            guard let self,!self.closing,let webView=self.webView else{return}
            self.hubBrowser.closePanel();XboxCloudWindowController.shared.open(url:url,isGameLaunch:XboxCloudRoute.isLaunch(url),over:webView)
        }
        hubBrowser.authorizeCloud = { [weak self] done in
            guard let self,!self.closing else{done(false,"Playmelt indisponible.");return}
            self.accountService.authorize(done)
        }
        accountService.onChange = { [weak self] in self?.sendState() }
        accountService.onGoogleSignInEnded = { [weak self] in self?.accountWebAuthentication.cancel() }
        XboxCloudWindowController.shared.requiresController = { [weak self] url in self?.model.xboxConnector.requiresController(for:url) ?? false }
        XboxCloudWindowController.shared.onRecentGames = { [weak self] ids,evidence in
            guard let self,!self.closing else{return}
            let known=Set(self.model.games.filter{$0.store=="xbox"}.map(\.appId))
            self.model.xboxConnector.recentGames.record(ids.filter{known.contains($0)},evidence:evidence)
            for index in self.model.games.indices where self.model.games[index].store=="xbox" {self.model.games[index].lastPlayed=self.model.xboxConnector.recentGames.lastPlayed(self.model.games[index].appId)}
            self.sendState()
        }
        if accountService.config.serviceReady {accountService.refresh()}
        accountService.refreshSignInProviders()
        XboxCloudWindowController.shared.authorizeLaunch = { [weak self] done in guard let self,!self.closing else {done(false,"Playmelt indisponible.");return};self.accountService.authorize(done) }
        model.xboxConnector.onOpenCloud = { [weak self] url, isGameLaunch in
            DispatchQueue.main.async {
                guard let self, let webView = self.webView else { return }
                self.accountService.authorize { [weak self] ok,message in guard let self,!self.closing else{return};guard ok else{self.result(false,message);return};self.hubBrowser.closePanel();XboxCloudWindowController.shared.open(url:url,isGameLaunch:isGameLaunch,over:webView) }
            }
        }
        model.gogConnector.onUpdate = { [weak self] in
            guard let self, !self.closing else { return }
            self.model.games = self.model.gogConnector.mergingLibraryGames(self.model.games)
            self.sendState()
        }
        model.gogConnector.onInstallUpdate = { [weak self] in
            guard let self, !self.closing else { return }
            self.notifyInstallJob()
        }
        model.gogConnector.startInstallObservation()
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
            if let self,let pending=self.officialSteamPreparation,let id=pending.installationJobID,
               self.installCoordinator.snapshot?["id"] as? String == id.uuidString {self.cancelOfficialSteamPreparation()}
            self?.epicConnector.cancelOperation()
            self?.queuedSteamInstall = nil
            if self?.preparingSteamBaseEngine == true {self?.runtimeSetup.cancel()}
            if self?.preparingSteamRenderer == true {self?.d3dMetalRuntime.cancel()}
            self?.stopNativeInstaller()
        }
        steamBootstrap.onChange = { [weak self] in self?.notifyRuntime() }
        steamBootstrap.onInstalled = { [weak self] in self?.refresh {self?.resumeOfficialSteamPreparation()} }
        d3dMetalSteamBootstrap.onChange = { [weak self] in self?.notifyRuntime() }
        d3dMetalSteamBootstrap.onInstalled = { [weak self] in self?.refresh {self?.resumeOfficialSteamPreparation()} }
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
        let duringScan: Set<String> = ["getGameMedia", "playGameVideo", "submitGameIssue", "retryGameIssue", "refreshGameIssues", "connectPlaymelt", "signInPlaymelt", "signInPlaymeltGoogle", "cancelPlaymeltGoogle", "refreshPlaymelt", "disconnectPlaymelt", "openPlaymeltAccount", "savePlayerProfile", "choosePlayerPhoto", "chooseGameAvatar", "getGameTheme", "completeSetup", "setVMInstallPreference", "setAutomaticBenchmarks", "stopBenchmark", "setBigPicture", "refreshHub", "openHubLink", "openXbox", "refresh", "setRenderProtection", "selectAccount", "cancelWindowsRuntime", "cancelD3DMetalRuntime", "cancelInstallAndPlay", "getGameSettings", "saveGameSettings", "checkServices"]
        guard !loading || duringScan.contains(action) else { result(false, "Lecture locale en cours. Réessayez dans un instant."); return }
        guard !RenderProtection.blocks(action, enabled: renderProtectionEnabled) else { result(false, "Rendus en cours : cette action est suspendue."); return }
        guard !WindowsExecutionPolicy.legacyActions.contains(action) else { result(false, WindowsExecutionPolicy.message); return }
        if let capability=AccountProtectedAction.capability(for:action) {
            accountService.authorize(capability:capability) { [weak self] ok,message in
                guard let self,!self.closing else{return}
                guard ok else {self.result(false,message);self.sendState();self.notify("onAccountRequired",[:]);return}
                self.performAction(action,payload:dict)
            }
        } else {performAction(action,payload:dict)}
    }
    private func performAction(_ action:String,payload dict:[String:Any]) {
        guard !closing,!RenderProtection.blocks(action,enabled:renderProtectionEnabled) else{return}
        switch action {
        case "getGameMedia":
            guard let id = dict["gameId"] as? String, let game = model.games.first(where: { $0.id == id }) else { return }
            let artwork = (hubFeed.feed["art"] as? [String:[String:Any]])?[id]
            let knownID = game.store == "steam" && LibraryModel.validAppID(game.appId) ? game.appId : (artwork?["appId"] as? NSNumber).map { $0.stringValue }
            gameMedia.request(gameID: id, title: game.title, knownSteamAppID: knownID) { [weak self] payload in
                guard let self, !self.closing else { return }
                self.notify("onGameMedia", payload)
            }
        case "playGameVideo":
            guard let id = dict["gameId"] as? String, model.games.contains(where: { $0.id == id }),
                  let videoID = dict["videoId"] as? String,
                  let video = gameMedia.cachedVideo(gameID: id, videoID: videoID), let webView else {
                result(false, "Cette vidéo doit être actualisée depuis la fiche du jeu."); return
            }
            hubBrowser.closePanel(); XboxCloudWindowController.shared.closePanel()
            gameMediaPlayer.open(video: video, over: webView)
        case "submitGameIssue":
            guard let id=dict["gameId"] as? String,let game=model.games.first(where:{$0.id==id}),let category=dict["category"] as? String,let message=dict["message"] as? String else{return}
            var diagnostics=hardwareState(renderProtectionEnabled:renderProtectionEnabled)
            diagnostics["version"]=Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "dev"
            diagnostics["macOS"]=ProcessInfo.processInfo.operatingSystemVersionString;diagnostics["renderer"]=game.runtimeName;diagnostics["graphicsAPI"]=SteamGameLaunchProfile.requiredGraphicsAPI(appID:game.appId);diagnostics["installed"]=game.installed
            diagnostics["launchBlocked"]=(localLaunchBlockReason(for:game,steamAccountID:model.selectedAccountID) ?? gameSettingsStore.launchBlockReason(for:gameSettingsContext(game))) != nil
            do {let report=try issueReports.create(gameID:game.id,title:game.title,store:game.store,category:category,message:message,diagnostics:diagnostics);transmitIssue(report)}catch{result(false,error.localizedDescription)}
        case "retryGameIssue":
            guard let id=dict["clientId"] as? String,let report=issueReports.all().first(where:{$0["clientId"] as? String==id}) else{return};transmitIssue(report)
        case "refreshGameIssues":
            accountService.reportStatuses { [weak self] rows in
                guard let self else{return}
                for row in rows {if let id=row["clientId"] as? String,let remote=row["id"] as? String,let status=row["status"] as? String {try? self.issueReports.update(id:id,serverID:remote,status:status)}}
                self.sendState()
            }
        case "connectPlaymelt":
            accountService.refreshSignInProviders()
            notify("onPlaymeltSignInRequested",[:])
        case "signInPlaymeltGoogle":
            accountService.signInWithGoogle { [weak self] url,done in
                guard let self,!self.closing else{done(nil);return}
                self.accountWebAuthentication.start(url:url,window:self.webView?.window,completion:done)
            }
        case "cancelPlaymeltGoogle":
            accountService.cancelGoogleSignIn();accountWebAuthentication.cancel()
        case "signInPlaymelt":
            guard let email=dict["email"] as? String,let password=dict["password"] as? String else{return}
            accountService.signIn(email:email,password:password)
        case "refreshPlaymelt": accountService.refresh()
        case "disconnectPlaymelt": accountService.logout();sendState()
        case "openPlaymeltAccount":
            let section=dict["section"] as? String
            let mode=section == "registration" ? "signup" : section == "password" ? "forgot" : nil
            guard let destination=accountService.config.accountPage(plan:dict["plan"] as? String,activateCode:section == "activation",mode:mode) else {result(false,"Le compte sera disponible à l’ouverture du service.");return}
            if !NSWorkspace.shared.open(destination) {result(false,"Le navigateur n’a pas pu ouvrir ton compte Playmelt.")}
        case "getGameSettings", "saveGameSettings":
            receiveGameSettings(action: action, payload: dict)
        case "completeSetup": UserDefaults.standard.set(true,forKey:"playmeltSetupCompleted");sendState()
        case "chooseLocalGame":
            guard !renderProtectionEnabled,let window=webView?.window else {result(false,"Désactivez la protection des rendus pour importer un jeu.");return}
            localGameImport.onChange = { [weak self] in guard let self else {return};self.sendState();if self.localGameImport.state["status"] as? String == "imported" {self.refresh()} }
            localGameImport.choose(in:window)
        case "installLocalGame":
            guard !renderProtectionEnabled,let title=dict["title"] as? String,let executable=dict["executable"] as? String else {return}
            localGameImport.install(title:title,executable:executable)
        case "cancelLocalImport": localGameImport.cancel()
        case "setVMInstallPreference": UserDefaults.standard.set(dict["enabled"] as? Bool ?? false,forKey:"vmInstallPreference");sendState()
        case "savePlayerProfile":
            do {try playerProfile.save(name:dict["name"] as? String,avatar:dict["avatar"] as? String);sendState();result(true,"Profil enregistré.")} catch {result(false,error.localizedDescription)}
        case "getGameTheme":
            guard let gameID=dict["gameId"] as? String, model.games.contains(where:{$0.id==gameID}),let raw=dict["url"] as? String,let url=URL(string:raw) else {return}
            GameTheme.load(url) { [weak self] theme in DispatchQueue.main.async {self?.notify("onGameTheme",["gameId":gameID,"theme":theme])} }
        case "chooseGameAvatar":
            guard let gameID=dict["gameId"] as? String, let game=model.games.first(where:{$0.id==gameID}),let style=dict["style"] as? String,["portrait","scene","logo"].contains(style) else {return}
            let art=(hubFeed.feed["art"] as? [String:[String:Any]])?[gameID] ?? [:]
            let base="https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/\(game.appId)/"
            let raw:String
            if style == "logo" {raw=art["logo"] as? String ?? (game.store == "steam" ? base+"logo.png" : "")}
            else if style == "scene" {raw=art["hero"] as? String ?? (!game.customImageURL.isEmpty ? game.customImageURL : game.store == "steam" ? base+"library_hero.jpg" : "")}
            else {raw = !game.customPortraitURL.isEmpty ? game.customPortraitURL : game.store == "steam" ? base+"library_600x900.jpg" : game.customImageURL}
            guard let url=URL(string:raw),GameTheme.isArtworkURL(url) else {result(false,"Ce visuel n’est pas disponible. Choisissez un autre jeu ou importez une photo.");return}
            result(true,"Préparation de votre avatar…")
            let name=dict["name"] as? String
            URLSession.shared.dataTask(with:URLRequest(url:url,timeoutInterval:15)) { [weak self] data,response,error in
                DispatchQueue.main.async {
                    guard let self else {return}
                    guard let data,(response as? HTTPURLResponse)?.statusCode == 200,error == nil else {self.result(false,"Ce visuel est indisponible. Essayez une autre affiche.");return}
                    do {try self.playerProfile.photo(data:data,name:name,fit:style == "logo");self.sendState();self.result(true,"Avatar enregistré.")} catch {self.result(false,error.localizedDescription)}
                }
            }.resume()
        case "choosePlayerPhoto":
            guard let window=webView?.window else {return}
            let picker=NSOpenPanel();picker.title="Votre photo de profil";picker.prompt="Choisir";picker.canChooseDirectories=false;picker.allowsMultipleSelection=false;picker.allowedFileTypes=["png","jpg","jpeg","heic","webp"]
            picker.beginSheetModal(for:window) { [weak self] answer in
                guard let self,answer == .OK,let url=picker.url else {return}
                do {try self.playerProfile.photo(url);self.sendState();self.result(true,"Photo enregistrée sur ce Mac.")}catch{self.result(false,error.localizedDescription)}
            }
        case "setAutomaticBenchmarks":
            guard let enabled=dict["enabled"] as? Bool else { return }
            benchmarks.setEnabled(enabled);sendState()
        case "stopBenchmark": benchmarks.stop();sendState()
        case "checkInstalledGames":
            launchDiagnostics = model.games.filter { $0.installed }.map { game in
                let issue = game.platform == "windows" ? localLaunchBlockReason(for:game,steamAccountID:model.selectedAccountID) ?? gameSettingsStore.launchBlockReason(for:gameSettingsContext(game)) : (game.path.map { FileManager.default.fileExists(atPath:$0.path) } == true ? nil : "Dossier du jeu introuvable.")
                return ["gameId":game.id,"title":game.title,"ready":issue == nil,"message":issue ?? "Fichiers et prérequis présents", "checkedAt":Date().timeIntervalSince1970]
            }
            sendState()
        case "refreshHub":
            // Accueil : la page envoie ses jeux suivis ; le flux en cache part tout de suite,
            // l'actualisation réseau seulement s'il est périmé (ou sur demande, 1 fois par minute).
            let refs = (dict["games"] as? [Any] ?? []).prefix(400).compactMap(HubGameRef.init)
            let force = dict["force"] as? Bool ?? false
            if !hubFeed.feed.isEmpty { notify("onHubFeed", hubFeed.feed) }
            hubFeed.refresh(games: refs, force: force) { [weak self] feed in
                guard let self, !self.closing else { return }
                self.notify("onHubFeed", feed)
            }
        case "checkServices":
            ConnectedServices.detect { [weak self] found in
                guard let self, !self.closing else { return }
                self.notify("onServices", ["connected": found])
            }
            ConnectedServices.geforceCatalog { [weak self] games in
                guard let self, !self.closing, !games.isEmpty else { return }
                self.notify("onGeforceCatalog", ["games": games])
            }
        case "openHubLink":
            guard let raw = dict["url"] as? String, raw.count <= 512, let url = HubFeedStore.allowedLink(raw) else { result(false, "Lien non autorisé."); return }
            if XboxCloudRoute.isCloudPage(url),let webView {
                hubBrowser.closePanel();XboxCloudWindowController.shared.open(url:url,isGameLaunch:XboxCloudRoute.isLaunch(url),over:webView);return
            }
            let items = hubFeed.feed["items"] as? [[String:Any]] ?? []
            var article = items.first { $0["url"] as? String == raw }
            if let gameID = article?["gameId"] as? String {
                article?["related"] = Array(items.filter { $0["gameId"] as? String == gameID && $0["url"] as? String != raw }.prefix(4))
            }
            if let webView { XboxCloudWindowController.shared.closePanel(); hubBrowser.open(url, article: article, over: webView) }
        case "setBigPicture":
            guard let enabled = dict["enabled"] as? Bool, let window = webView?.window else { return }
            window.appearance = NSAppearance(named: enabled ? .darkAqua : .aqua)
            window.backgroundColor = enabled ? .black : .clear
            webView?.superview?.subviews.filter { $0 is WindowDragStrip }.forEach { $0.isHidden = enabled }
            if enabled && !window.styleMask.contains(.fullScreen) { bigPictureEnteredFullscreen = true; window.toggleFullScreen(nil) }
            else if !enabled && bigPictureEnteredFullscreen { bigPictureEnteredFullscreen = false; if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) } }
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
        case "refresh": model.gogConnector.invalidate(); refresh()
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
            if dict["gameId"] != nil {if rememberOfficialSteamPreparation(dict,runtimeID:"playmelt-d3dmetal"){resumeOfficialSteamPreparation()}}
            else{d3dMetalSteamBootstrap.start()}
        case "openD3DMetalSteam":
            guard !CommandLine.arguments.contains("--audit-read-only"), !anyRuntimeOperation else { result(false, "Steam DirectX 12 est indisponible pendant cette opération."); return }
            if dict["gameId"] != nil {if rememberOfficialSteamPreparation(dict,runtimeID:"playmelt-d3dmetal"){resumeOfficialSteamPreparation()}}
            else{openWindowsSteam(runtimeID:"playmelt-d3dmetal")}
        case "importD3DMetal": importD3DMetal()
        case "installNvidiaBridge":
            guard !CommandLine.arguments.contains("--audit-read-only"), !anyRuntimeOperation else { result(false, "Installation indisponible pendant cette opération."); return }
            installNvidiaBridge()
        case "openD3DMetalDownload":
            NSWorkspace.shared.open(URL(string: "https://developer.apple.com/games/game-porting-toolkit/")!)
        case "installSteamWindows":
            guard !CommandLine.arguments.contains("--audit-read-only"), !anyRuntimeOperation else { result(false, "Installation Steam indisponible pendant cette opération."); return }
            if dict["gameId"] != nil {if rememberOfficialSteamPreparation(dict,runtimeID:"playmelt-windows"){resumeOfficialSteamPreparation()}}
            else{steamBootstrap.start()}
        case "openWindowsSteam":
            guard !CommandLine.arguments.contains("--audit-read-only"), !anyRuntimeOperation else { result(false, "Steam Windows est indisponible pendant cette opération."); return }
            if dict["gameId"] != nil {if rememberOfficialSteamPreparation(dict,runtimeID:"playmelt-windows"){resumeOfficialSteamPreparation()}}
            else{openWindowsSteam(runtimeID:"playmelt-windows")}
        case "cancelInstallAndPlay":
            let scope=SteamPreparationCancellation.decide(preparationOnly:dict["preparationOnly"] as? Bool == true,requestedGame:dict["gameId"] as? String,pendingGame:officialSteamPreparation?.gameID,currentJobGame:installCoordinator.snapshot?["gameId"] as? String)
            let linkedJob=officialSteamPreparation?.installationJobID.map{$0.uuidString==installCoordinator.snapshot?["id"] as? String} ?? false
            if scope.preparation || (dict["preparationOnly"] as? Bool != true && linkedJob){cancelOfficialSteamPreparation()}
            if scope.installationJob{installCoordinator.cancel()}
        case "retryInstallAndPlay":
            guard !closing,!renderProtectionEnabled,!CommandLine.arguments.contains("--audit-read-only"),
                  let jobID=dict["jobId"] as? String,
                  let retry=installCoordinator.retryContext(jobID:jobID,selectedAccount:model.selectedAccountID),
                  !anyRuntimeOperation,officialSteamPreparation == nil else {
                result(false,"Cette reprise n’est plus disponible pour le compte et l’installation sélectionnés.");return
            }
            let candidates=model.games.filter{$0.store=="steam" && $0.appId==retry.appID && ($0.platform=="windows" || $0.supportedPlatforms.contains("windows"))}
            guard let game=candidates.first(where:{$0.id==retry.gameID}) ?? (candidates.count==1 ? candidates.first:nil) else {
                result(false,"Le jeu de cette reprise doit être retrouvé sans ambiguïté dans la bibliothèque du compte courant.");return
            }
            if let folder=game.path,SteamDepotLaunchManifest.read(folder,appID:game.appId)?.requiresOfficialSteam == true,let id=UUID(uuidString:jobID) {
                installCoordinator.updatePreparedStage(id:id,status:"preparing-client",message:"Reprise des fichiers conservés…")
                do {
                    guard let manifest=try SteamDepotLaunchManifest.selectAutomaticRenderer(folder:folder,appID:game.appId,preferredRuntimeID:retry.runtimeID),manifest.requiresOfficialSteam else {
                        installCoordinator.finishDirect(id:id,success:false,message:"Le plan de lancement doit être revérifié. Les fichiers sont conservés.",code:"launch-plan-missing",retryable:true,resumePoint:"files-prepared");return
                    }
                    let route=manifest.renderer == "d3dmetal" ? "playmelt-d3dmetal":"playmelt-windows"
                    guard installCoordinator.configurePreparedFiles(id:id,accountID:retry.accountID,runtimeID:route) else{return}
                    beginOfficialSteamPreparation(game:game,runtimeID:route,account:retry.accountID,installationJobID:id)
                    resumeOfficialSteamPreparation()
                } catch {installCoordinator.finishDirect(id:id,success:false,message:error.localizedDescription,code:"renderer-selection-failed",retryable:true,resumePoint:"files-prepared")}
            } else {
                startNativeSteamInstall(game:game,autoPlay:retry.autoLaunch,requestedRuntime:retry.runtimeID)
            }
        case "installAndPlay":
            guard let id = dict["gameId"] as? String, let game = model.games.first(where: { $0.id == id }) else { result(false, "Jeu introuvable. Actualisez la bibliothèque."); return }
            if resumePreparedSteamPayload(game,preferredRuntimeID:dict["runtimeId"] as? String){return}
            if needsWindowsSteamRepair(game,requestedRuntime:dict["runtimeId"] as? String) {
                startNativeSteamInstall(game:game,autoPlay:true,requestedRuntime:dict["runtimeId"] as? String);return
            }
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
                XboxCloudWindowController.shared.closePanel()
                self?.sendState()
                self?.result(true, "Compte Microsoft déconnecté de Playmelt.")
            }
        case "openXbox", "launchXboxCloud":
            let raw = dict["url"] as? String ?? "https://www.xbox.com/fr-FR/play"
            if let url = URL(string: raw) {
                let isGameLaunch = XboxCloudRoute.isLaunch(url)
                guard XboxConnector.isAllowedCloudURL(url), let webView else { result(false, "URL Xbox invalide."); return }
                hubBrowser.closePanel()
                XboxCloudWindowController.shared.open(url: url, isGameLaunch: isGameLaunch, over: webView)
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
        let legendary = epicConnector.legendaryExecutableURL
        DispatchQueue.global(qos: .utility).async {
            guard let legendary, FileManager.default.isExecutableFile(atPath: legendary.path) else {
                DispatchQueue.main.async { completion(nil) }; return
            }
            let p = Process()
            p.executableURL = legendary
            if let runtime = PortablePythonRuntime.resolve(requireLegendary:true,requireCertificates:true) { p.environment = runtime.environment(merging:ProcessInfo.processInfo.environment) }
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
        // Peinture immédiate : la bibliothèque en cache (snapshot) s'affiche avant le scan.
        if !model.games.isEmpty { sendState() }
        if let completion { afterRefresh.append(completion) }
        let id = UUID(); scanID = id
        model.windowsDescriptor = runtimeSetup.descriptor()
        model.d3dMetalDescriptor = try? d3dMetalRuntime.descriptor(base: runtimeSetup.descriptor())
        libraryScanner.scan(model.makeScanRequest()) { [weak self] snapshot in
            guard let self, !self.closing, self.scanID == id else { return }
            let gogHistory = self.model.games.filter { $0.store == "gog" }
            guard self.model.applyScan(snapshot) else { self.refresh(); return }
            self.mergeManagedEpicInstallations()
            self.model.games = self.model.gogConnector.mergingLibraryGames(self.model.games, preservingLocalHistoryFrom: gogHistory)
            self.loading = false; self.model.persistGamesSnapshot(); self.sendState()
            let callbacks = self.afterRefresh; self.afterRefresh.removeAll()
            for callback in callbacks { callback() }
        }
    }
    private func openWindowsSteam(runtimeID: String) {
        refresh { [weak self] in
            guard let self, !self.closing, !self.renderProtectionEnabled, !self.anyRuntimeOperation else { return }
            guard let runtime = self.model.runtimes.first(where: { $0.id == runtimeID && $0.available }) else { self.result(false, "Préparez cet environnement puis installez Steam."); return }
            self.accountService.authorize { [weak self] ok,message in
                guard let self,!self.closing,!self.renderProtectionEnabled,!self.anyRuntimeOperation else{return}
                guard ok else{self.result(false,message);self.notify("onAccountRequired",[:]);return}
                self.runWindowsClient(runtime, arguments:["steam://open/games"],onFailure:{[weak self] message in self?.result(false,message)}){[weak self] ok,message in self?.result(ok,message)}
            }
        }
    }
    var runtimeIsBusy: Bool { ["downloading", "verifying", "extracting", "initializing"].contains(runtimeSetup.snapshot()["status"] as? String ?? "") }
    var renderProtectionEnabled: Bool { RenderProtection.enabled(in: model.preferences) }
    var d3dMetalIsBusy: Bool { d3dMetalRuntime.snapshot(base: runtimeSetup.descriptor())["busy"] as? Bool == true }
    var updateBusy:Bool {renderProtectionEnabled || loading || anyRuntimeOperation || officialSteamPreparation != nil || nvidiaBridgeInstalling || (clientLauncher.activeCount>0 || steamProcessLauncher.activeCount>0) || EpicLaunchAuthorization.activeLaunchCount>0 || benchmarks.isRunning || ["checking","installing"].contains(localGameImport.state["status"] as? String ?? "") || XboxCloudWindowController.shared.isVisible}
    var anyRuntimeOperation: Bool { runtimeIsBusy || officialSteamBaseEngineOwnerID != nil || d3dMetalIsBusy || rendererImportBusy || steamBootstrap.busy || d3dMetalSteamBootstrap.busy || steamReuseToken != nil || officialSteamStopping>0 || openingNativeSteamForInstall || installCoordinator.isActive }
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
        if let pending=officialSteamPreparation {state["steamPreparation"]=["gameId":pending.gameID,"waitingForLogin":pending.loginOpened,"busy":pending.requestInFlight,"remainingSeconds":max(0,pending.expiresAt-ProcessInfo.processInfo.systemUptime)]}
        else{state["steamPreparation"]=NSNull()}
        state["steamPreparationStopping"]=officialSteamStopping>0
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
        state["installJobs"] = installationJobs
        if var games = state["games"] as? [[String:Any]] {
            let models = Dictionary(uniqueKeysWithValues: model.games.map { ($0.id, $0) })
            for index in games.indices {
                if let id = games[index]["id"] as? String, let game = models[id], game.installed,
                   let issue = gameSettingsStore.launchBlockReason(for: gameSettingsContext(game)) {
                    games[index]["canLaunch"] = false; games[index]["launchBlockReason"] = issue
                }
            }
            let managedEpic=epicConnector.managedInstallations()
            for index in games.indices {
                guard let id=games[index]["id"] as? String,let game=models[id],game.store=="epic",game.installed,game.complete,
                      let path=game.path,managedEpic.contains(where:{$0.appName==game.appId && $0.directory.path==path.path}) else {continue}
                let issue=game.platform=="windows" ? localLaunchBlockReason(for:game,steamAccountID:model.selectedAccountID):nil
                games[index]["canLaunch"]=issue==nil && gameSettingsStore.launchBlockReason(for:gameSettingsContext(game))==nil
                if let issue {games[index]["launchBlockReason"]=issue}
            }
            for index in games.indices {
                guard let id = games[index]["id"] as? String, let game = models[id], game.store == "gog" else { continue }
                let nativeReady = model.gogConnector.nativeLaunchURL(gameID: id) != nil
                games[index]["canLaunch"] = nativeReady
                games[index]["canInstall"] = false
                games[index]["canInstallAndPlay"] = false
                games[index]["canRemoveFiles"] = model.gogConnector.verifiedInstallationDirectory(gameID: id) != nil
                if nativeReady { games[index]["launchBlockReason"] = "" }
            }
            state["games"] = games
            state["profile"] = profileProgression.snapshot(games:games, account:state["selectedAccountId"] as? String ?? "local")
        }
        state["renderProtectionEnabled"] = renderProtectionEnabled
        if let gameSettingsPayload { state["gameSettings"] = gameSettingsPayload }
        state["plans"] = PlaymeltPlan.catalog()
        state["setupSuggested"] = model.games.isEmpty && !UserDefaults.standard.bool(forKey:"playmeltSetupCompleted")
        state["localImport"] = localGameImport.state
        state["vmInstallPreference"] = UserDefaults.standard.bool(forKey:"vmInstallPreference")
        var playerState = playerProfile.snapshot()
        playerState["storage"] = storageSnapshot()
        state["player"] = playerState
        state["account"] = accountService.snapshot()
        state["issueReports"] = issueReports.all()
        state["benchmarks"] = benchmarks.snapshot()
        state["launchDiagnostics"] = launchDiagnostics
        notify("onNativeState", state)
        UpdaterController.shared.resumeWhenIdle()
    }
    /// Espace du volume qui accueille les jeux installés par Playmelt.
    /// Une seule mesure statfs : légère, appelable à chaque état.
    private func storageSnapshot() -> [String: Any] {
        let games = model.home.appendingPathComponent("Library/Application Support/Playmelt/Games", isDirectory: true)
        var exists: ObjCBool = false
        let root: URL = FileManager.default.fileExists(atPath: games.path, isDirectory: &exists) && exists.boolValue
            ? games
            : model.home.appendingPathComponent("Library/Application Support/Playmelt", isDirectory: true)
        let values = try? root.standardizedFileURL.resourceValues(forKeys: [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        guard let total = values?.volumeTotalCapacity, total > 0,
              let free = values?.volumeAvailableCapacityForImportantUsage, free >= 0 else { return ["ready": false] }
        let used = max(0, Int(total) - Int(free))
        return ["ready": true,
                "volume": values?.volumeName ?? "Macintosh HD",
                "total": total, "free": free, "used": used,
                "freePercent": Double(free) / Double(total),
                "usedPercent": Double(used) / Double(total)]
    }
    private func transmitIssue(_ report:[String:Any]) {
        sendState()
        accountService.submitReport(report) { [weak self] ok,response in
            guard let self,!self.closing else{return}
            if ok,let id=report["clientId"] as? String,let remote=response["id"] as? String,let status=response["status"] as? String,IssueReports.statuses.contains(status) {
                do {try self.issueReports.update(id:id,serverID:remote,status:status);self.result(true,"Signalement transmis au support Playmelt.")}catch{self.result(false,"Réponse reçue, mais le suivi local n’a pas pu être enregistré.")}
            } else {self.result(false,"Signalement enregistré sur ce Mac, en attente d’envoi. La connexion au support n’a pas été confirmée.")}
            self.sendState()
        }
    }
    private func d3dMetalFPSQualified() -> Bool {
        GamePerformanceRuntime.d3dMetalFPSVersionSupported(d3dMetalStore.snapshot()["version"] as? String) &&
            (try? d3dMetalRuntime.descriptor(base: runtimeSetup.descriptor()))?.readyEngine == true
    }
    private func gameSettingsContext(_ game: Game, requestedBackend: String? = nil, performanceUnavailableReason: String? = nil) -> GameSettingsContext {
        let base = GameSettingsContext(id: game.id, appID: game.appId, platform: game.platform,
                            installed: game.installed, path: game.path?.path ?? "",
                            requiredRenderer: SteamGameLaunchProfile.requiredRenderer(appID: game.appId),
                            supportsLaunchArguments: game.store == "steam" || game.installSource == "local", store: game.store)
        let backend = requestedBackend ?? gameSettingsStore.requestedBackend(for: base)
        let selection = localGamePerformanceSelection(for: game, requestedBackend: backend)
        let official = game.path.flatMap { SteamDepotLaunchManifest.read($0, appID: game.appId) }?.requiresOfficialSteam == true
        let managedEpic = game.store == "epic" && game.path?.resolvingSymlinksInPath().path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Playmelt/Games").resolvingSymlinksInPath().path + "/") == true
        let direct = game.platform == "windows" && game.installed && game.appId != "2651280" && !official &&
            (game.installSource == "local" || game.store == "steam" || managedEpic)
        let renderer = selection?.renderer ?? ""
        let supportedRenderer = renderer == "dxmt" || (["d3dmetal", "d3dmetal-nv", "d3dmetal-nv-rt"].contains(renderer) && d3dMetalFPSQualified())
        let performance = direct && selection != nil && supportedRenderer && performanceUnavailableReason == nil
        let spatial = performance && renderer == "dxmt" && selection?.resolution != .unavailable
        let reason = performanceUnavailableReason ?? (official ? GamePerformanceRuntime.officialSteamReason :
            (game.appId == "2651280" ? "Le profil Spider-Man 2 est verrouillé et conserve ses réglages qualifiés." :
             (renderer.hasPrefix("d3dmetal") && !supportedRenderer ? "La limite FPS exige D3DMetal 4.0b3 préparé et vérifié." : "Ces réglages exigent une route Windows directe qualifiée ; ils ne s’appliquent pas aux jeux Mac natifs ou cloud.")))
        return GameSettingsContext(id: game.id, appID: game.appId, platform: game.platform,
            installed: game.installed, path: game.path?.path ?? "", requiredRenderer: base.requiredRenderer,
            supportsLaunchArguments: base.supportsLaunchArguments, store: game.store,
            supportsPerformanceSettings: performance, supportsSpatialUpscaling: spatial,
            performanceReadOnlyReason: performance ? nil : reason,
            spatialUpscalingReadOnlyReason: spatial ? nil : (performance && renderer == "dxmt" ? GamePerformanceRuntime.spatialReason : "L’upscaling spatial est réservé à une route DirectX 11/DXMT avec résolution de rendu pilotable."),
            resolvedPerformanceBackend: selection?.renderer)
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
        // A draft value is a route choice only when this transaction actually
        // applies backend. Untouched draft controls never change qualification.
        let changingBackend = saving && (payload["changedFields"] as? [String])?.contains("backend") == true
        let draftBackend = changingBackend ? (payload["settings"] as? [String: Any])?["backend"] as? String : nil
        let context = gameSettingsContext(game, requestedBackend: draftBackend)
        let displays = GameDisplayMetadata.screens()
        let hardware = hardwareState(renderProtectionEnabled: renderProtectionEnabled)
        let request = UUID(); gameSettingsRequest = request
        gameSettingsQueue.async { [weak self] in
            guard let self else { return }
            var response: [String: Any]
            if saving {
                response = self.gameSettingsStore.save(game: context, payload: payload["settings"] as! [String: Any], expectedRevision: payload["expectedRevision"] as? String, changedFields: payload["changedFields"] as! [String])
                if response["status"] as? String == "saved" {
                    var rendererError:String?
                    if (payload["changedFields"] as? [String])?.contains("backend") == true,let folder=game.path {
                        let backend=self.gameSettingsStore.requestedBackend(for:context)
                        let renderer=backend.hasPrefix("d3dmetal") ? "d3dmetal":backend
                        if ["auto","dxmt","d3dmetal"].contains(renderer),SteamDepotLaunchManifest.read(folder,appID:game.appId) != nil {
                            do {try SteamDepotLaunchManifest.chooseRenderer(renderer,folder:folder,appID:game.appId)}
                            catch {rendererError="Le réglage est enregistré, mais le moteur du lanceur n’a pas pu être mis à jour : " + error.localizedDescription}
                        }
                    }
                    response = self.gameSettingsStore.snapshot(game: self.gameSettingsContext(game), hardware: hardware, displays: displays)
                    if let rendererError {response["status"]="error";response["error"]=rendererError}
                    else if response["status"] as? String != "error" { response["status"] = "saved" }
                }
            } else {
                response = self.gameSettingsStore.snapshot(game: context, hardware: hardware, displays: displays)
            }
            let completedResponse = response
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closing, self.gameSettingsRequest == request else { return }
                self.gameSettingsPayload = completedResponse
                if saving {self.refresh()}else{self.sendState()}
            }
        }
    }
    func notifyRuntime() { notify("onNativeRuntime", runtimePayload());UpdaterController.shared.resumeWhenIdle() }
    var installationJobs: [[String: Any]] {
        InstallOperations.snapshots(managed: installCoordinator.snapshot, observed: model.gogConnector.installationJobs())
    }
    func notifyInstallJob() {
        notify("onNativeInstallJobs", ["jobs": installationJobs])
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
    // MARK: - Suivi de lancement
    private var launchWatchTimers: [String: Timer] = [:]
    /// Informe l'interface de l'avancement réel : préparation, fenêtre du jeu ouverte, blocage.
    func startLaunchWatch(gameID: String, title: String, startedAt: Date) {
        launchWatchTimers[gameID]?.invalidate()
        var announcedWindow = false
        let timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] timer in
            guard let self, !self.closing else { timer.invalidate(); return }
            let elapsed = max(0, Int(Date().timeIntervalSince(startedAt)))
            if !announcedWindow, self.gameWindowVisible() {
                announcedWindow = true
                self.notify("onLaunchProgress", ["gameId": gameID, "title": title, "state": "running", "elapsed": elapsed])
                timer.invalidate()
                self.launchWatchTimers[gameID] = nil
                return
            }
            guard !announcedWindow else { return }
            let state = elapsed >= 600 ? "stalled" : "preparing"
            self.notify("onLaunchProgress", ["gameId": gameID, "title": title, "state": state, "elapsed": elapsed])
        }
        launchWatchTimers[gameID] = timer
    }
    @discardableResult
    func stopLaunchWatch(_ gameID: String) -> Bool {
        let wasActive = launchWatchTimers[gameID] != nil
        launchWatchTimers[gameID]?.invalidate()
        launchWatchTimers[gameID] = nil
        return wasActive
    }
    /// Vrai si une fenêtre de jeu (wine ou Playmelt) est visible, hors fenêtre Playmelt elle-même.
    private func gameWindowVisible() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        let own = ProcessInfo.processInfo.processIdentifier
        for info in list {
            guard let owner = info[kCGWindowOwnerName as String] as? String, !owner.isEmpty else { continue }
            let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            let isWine = owner == "wine" || owner.hasPrefix("wine")
            let isPlaymeltGame = owner.hasPrefix("Playmelt") && ownerPID != own
            guard isWine || isPlaymeltGame else { continue }
            guard (info[kCGWindowLayer as String] as? Int ?? -1) == 0 else { continue }
            let name = info[kCGWindowName as String] as? String ?? ""
            guard !name.isEmpty, name != "Playmelt" else { continue }
            guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue,
                  width >= 640, height >= 360 else { continue }
            return true
        }
        return false
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
    private func needsWindowsSteamRepair(_ game:Game,requestedRuntime:String?)->Bool {
        SteamInstallCoordinator.needsWindowsPayloadRepair(store:game.store,installed:game.installed,complete:game.complete,platform:game.platform,
            nativePreferred:prefersNativeSteam(game,requestedRuntime:requestedRuntime),
            payloadMarkerPresent:game.path.map{FileManager.default.fileExists(atPath:SteamDepotLaunchManifest.file($0).path)} ?? false,
            payloadManifestValid:game.path.flatMap{SteamDepotLaunchManifest.read($0,appID:game.appId)} != nil)
    }
    /// A checked publisher launch manifest is the boundary between obtaining
    /// payload bytes and asking the official Windows client to finish its work.
    /// This branch never starts the Mac depot downloader for preserved files.
    @discardableResult
    private func resumePreparedSteamPayload(_ game:Game,preferredRuntimeID:String?,autoPlay:Bool=true)->Bool {
        guard game.store == "steam",!prefersNativeSteam(game,requestedRuntime:preferredRuntimeID),let folder=game.path,
              SteamDepotLaunchManifest.read(folder,appID:game.appId)?.requiresOfficialSteam == true else{return false}
        guard !closing,!renderProtectionEnabled,!CommandLine.arguments.contains("--audit-read-only"),
              LibraryModel.validAccountID(model.selectedAccountID) else {result(false,"Préparation suspendue : vérifiez le compte et la protection des rendus.");return true}
        if let pending=officialSteamPreparation {
            guard pending.appID == game.appId,pending.account == model.selectedAccountID else {result(false,"Une préparation Steam est déjà en cours. Arrêtez-la avant un autre jeu.");return true}
            resumeOfficialSteamPreparation();return true
        }
        guard !anyRuntimeOperation else {result(false,"Une opération est déjà en cours.");return true}
        do {
            guard let manifest=try SteamDepotLaunchManifest.selectAutomaticRenderer(folder:folder,appID:game.appId,preferredRuntimeID:preferredRuntimeID),manifest.requiresOfficialSteam else {
                result(false,"Le plan de lancement doit être revérifié. Les fichiers sont conservés.");return true
            }
            let route=manifest.renderer == "d3dmetal" ? "playmelt-d3dmetal":"playmelt-windows"
            let account=model.selectedAccountID
            guard let id=installCoordinator.beginPreparedFiles(gameID:game.id,appID:game.appId,title:game.title,accountID:account,runtimeID:route,autoLaunch:autoPlay) else {
                result(false,"Un suivi d’installation est déjà actif.");return true
            }
            beginOfficialSteamPreparation(game:game,runtimeID:route,account:account,installationJobID:id)
            resumeOfficialSteamPreparation();sendState()
        } catch {result(false,error.localizedDescription)}
        return true
    }
    func installAndPlay(_ game: Game, runtimeID: String?,autoPlay:Bool = true) {
        guard !closing, !renderProtectionEnabled else { result(false, "Rendus en cours : lancement suspendu."); return }
        gameMediaPlayer.close()
        guard !CommandLine.arguments.contains("--audit-read-only") else { result(false, "Mode de vérification : installation et lancement désactivés."); return }
        guard !installCoordinator.isActive, !runtimeIsBusy, !steamBootstrap.busy else { result(false, "Une opération est déjà en cours."); return }
        if game.store == "xbox" {
            let urlStr = game.epicLaunchID.isEmpty ? "https://www.xbox.com/play" : game.epicLaunchID
            if let url = URL(string: urlStr), let webView {
                hubBrowser.closePanel()
                XboxCloudWindowController.shared.open(url: url, isGameLaunch: XboxCloudRoute.isLaunch(url), over: webView)
                result(true, "Lancement de \(game.title) sur Xbox Cloud Gaming…")
            }
            return
        }
        if game.store == "gog" {
            if game.platform == "windows", game.installSource == "local", game.installed, game.complete {
                route(game, installing: false, requestedRuntime: runtimeID); return
            }
            launchGOGGame(game)
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
        guard let id = installCoordinator.begin(gameID: game.id, appID: game.appId, title: game.title, runtime: runtime, accountID: account, autoLaunch:autoPlay,onReady: { [weak self] id in
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
                if !autoPlay {
                    self.installCoordinator.finishDirect(id:id,success:true,message:"Installation Steam vérifiée. Le jeu peut être lancé depuis sa fiche.")
                    self.sendState();return
                }
                let active = activeSteamAccount(TextVDF.read(currentRuntime.steamRoot.appendingPathComponent("config/loginusers.vdf")).object("users"))
                guard SteamInstallAccountContext.permitsAutoLaunch(expected: account, active: active) else {
                    self.installCoordinator.didRequestLaunch(id: id, success: false, message: "Le compte actif dans Steam doit être vérifié avant le lancement automatique."); return
                }
                // Installation may take longer than the entitlement. Re-check
                // immediately before automatic play, not just when it was queued.
                self.accountService.authorize { [weak self] allowed,message in
                    guard let self,!self.closing else{return}
                    guard allowed else {self.installCoordinator.didRequestLaunch(id:id,success:false,message:message);self.notify("onAccountRequired",[:]);return}
                    guard self.installCoordinator.confirmLaunchContext(id:id,accountChanged:self.model.selectedAccountID != account,executionBlocked:self.renderProtectionEnabled) else{return}
                    let activeNow=activeSteamAccount(TextVDF.read(currentRuntime.steamRoot.appendingPathComponent("config/loginusers.vdf")).object("users"))
                    guard SteamInstallAccountContext.permitsAutoLaunch(expected:account,active:activeNow) else {self.installCoordinator.didRequestLaunch(id:id,success:false,message:"Le compte Steam a changé pendant la vérification d’accès.");return}
                    self.dispatchSteam(installed, runtime: currentRuntime, installing: false, onFailure: { [weak self] message in self?.installCoordinator.launchFailed(id: id, message: message) }) { [weak self] ok, message in
                        self?.installCoordinator.didRequestLaunch(id: id, success: ok, message: message)
                    }
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

    private func mergeManagedEpicInstallations() {
        for install in epicConnector.managedInstallations() {
            let platform=install.platform=="Mac" ? "mac":"windows"
            let executable=install.directory.appendingPathComponent(install.executable.replacingOccurrences(of:"\\",with:"/"))
            let complete=platform=="mac" ? LibraryModel.verifiedEpicMacExecutable(root:install.directory,executable:install.executable) != nil:FileManager.default.fileExists(atPath:executable.path)
            if let index=model.games.firstIndex(where:{$0.store=="epic" && $0.appId==install.appName}) {
                model.games[index].installed=true;model.games[index].complete=complete;model.games[index].path=install.directory;model.games[index].platform=platform;model.games[index].installSource="epic"
            } else {
                model.games.append(Game(id:"epic-owned:"+install.appName,appId:install.appName,title:install.title,store:"epic",installed:true,platform:platform,runtimeId:"epic-mac",runtimeName:"Playmelt · Epic",ownership:"installed-only",path:install.directory,complete:complete,installSource:"epic"))
            }
        }
    }
    func installEpicGame(_ game: Game) {
        guard !closing,!renderProtectionEnabled,!CommandLine.arguments.contains("--audit-read-only"),!installCoordinator.isActive else {result(false,"Installation Epic indisponible pendant cette opération.");return}
        guard let account=model.epicSnapshot?.accountId else {result(false,"Connectez et actualisez votre bibliothèque Epic.");return}
        guard ["mac","windows"].contains(game.platform) else {result(false,"Cette édition Epic ne propose pas d’installation Mac/Windows.");return}
        guard let token=installCoordinator.beginEpicDirect(gameID:game.id,appID:game.appId,title:game.title,accountID:account,autoLaunch:false) else{return}
        installCoordinator.updateDirect(id:token,status:"downloading",message:"Téléchargement Epic avec le compte vérifié, puis contrôle des fichiers…",progress:nil,phase:"Téléchargement et vérification Epic")
        sendState()
        epicConnector.install(appName:game.appId,platform:game.platform=="mac" ? "Mac":"Windows",libraryAccountID:account) { [weak self] outcome in
            guard let self,!self.closing else{return}
            switch outcome {
            case .success(let install):
                if install.prerequisitesRequired {self.installCoordinator.finishPrepared(id:token,message:"Fichiers Epic vérifiés. Les prérequis éditeur restent à vérifier avant le premier lancement.")}
                else {self.installCoordinator.finishDirect(id:token,success:true,message:"Fichiers Epic téléchargés et vérifiés. Le premier lancement reste à tester.")}
                self.refresh()
            case .failure(let error):self.installCoordinator.finishDirect(id:token,success:false,message:error.localizedDescription);self.sendState()
            }
        }
    }
    private func launchManagedEpic(_ game:Game,backend:String,arguments:[String],environment:[String:String]?) {
        guard let account=model.epicSnapshot?.accountId,let directory=game.path else {result(false,"Actualisez votre bibliothèque Epic avant le lancement.");return}
        let key="epic-private:"+game.appId
        guard let gate=requestGate.acquire(key) else {result(false,"Un lancement Epic est déjà demandé.");return}
        epicConnector.authorizeLaunch(appName:game.appId,platform:game.platform=="mac" ? "Mac":"Windows",directory:directory,libraryAccountID:account) { [weak self] outcome in
            guard let self,!self.closing else{return}
            switch outcome {
            case .failure(let error):self.requestGate.finish(key,token:gate);self.result(false,error.localizedDescription)
            case .success(let authorization):
                self.accountService.authorize { [weak self] allowed,message in
                    guard let self,!self.closing else {authorization.close();return}
                    guard allowed,!self.renderProtectionEnabled,self.epicConnector.availability()["accountId"] as? String==account else {authorization.close();self.requestGate.finish(key,token:gate);self.result(false,allowed ? "Le contexte Epic a changé.":message);return}
                    let started=Date()
                    let exited:(Int32)->Void = { [weak self,authorization] code in
                        authorization.close();guard let self,!self.closing else{return}
                        self.requestGate.finish(key,token:gate)
                        let seconds=Int64(Date().timeIntervalSince(started));if seconds>2 {PlaytimeStore.shared.addSession(key:game.appId,seconds:seconds)}
                        if code != 0 {self.result(false,"Le jeu Epic s’est arrêté. Aucun paramètre d’authentification n’est ajouté au diagnostic.")}
                        self.refresh()
                    }
                    do {
                        if game.platform=="windows" {
                            guard let environment,localLaunchBlockReason(for:game,steamAccountID:self.model.selectedAccountID)==nil,let script=ensureLaunchScript(for:game,requestedBackend:backend,iconData:self.gameArtworkData(game)) else {throw EpicConnectorError.invalidResponse}
                            let win=directory.appendingPathComponent("Windows"),target=FileManager.default.fileExists(atPath:win.path) ? win:directory
                            let files=try FileManager.default.subpathsOfDirectory(atPath:target.path)
                            guard let chosen=resolvedGameExecutable(appID:game.appId,folder:directory,files:files) else {throw EpicConnectorError.invalidResponse}
                            let template=try String(contentsOf:script,encoding:.utf8)
                            try authorization.launchWithScript(template,legacyAuthBlock:localGameEpicAuthBlock(appID:game.appId,store:game.store),scriptExecutable:target.appendingPathComponent(chosen).path,additionalArguments:arguments,environment:environment,directory:script.deletingLastPathComponent(),onExit:exited)
                        } else {
                            try authorization.consume { parameters in
                                _=try self.clientLauncher.launch(executable:parameters.executable,arguments:parameters.arguments+arguments,environment:ProcessInfo.processInfo.environment,directory:parameters.directory,onExit:exited)
                            }
                        }
                        self.result(true,"Ouverture de \(game.title)…")
                    } catch {authorization.close();self.requestGate.finish(key,token:gate);self.result(false,"Le lanceur Epic n’est pas reconnu ou ne peut pas être ouvert. Aucun ancien profil Legendary n’est utilisé en secours.")}
                }
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
    private func advanceSteamInstallPreparation() {
        guard let request=queuedSteamInstall,installCoordinator.acceptsDirect(id:request.id) else{return}
        func fail(_ message:String) {
            queuedSteamInstall=nil
            installCoordinator.finishDirect(id:request.id,success:false,message:message)
            result(false,message);sendState()
        }
        guard !closing,!renderProtectionEnabled,model.selectedAccountID == request.account else {fail("Préparation suspendue : le compte ou la protection des rendus a changé.");return}
        let base=runtimeSetup.descriptor()
        let progress:([String:Any])->Void = { [weak self] state in
            guard let self,self.queuedSteamInstall?.id == request.id,self.installCoordinator.acceptsDirect(id:request.id) else{return}
            self.installCoordinator.updateDirect(id:request.id,status:"preparing-engine",message:state["message"] as? String ?? "Préparation du moteur…",progress:state["progress"] as? Double,downloaded:(state["bytesDownloaded"] as? NSNumber)?.uint64Value ?? 0,total:(state["bytesTotal"] as? NSNumber)?.uint64Value ?? 0,phase:"Préparation du moteur")
        }
        if !base.readyEngine {
            accountService.authorize(capability:"runtime.download") { [weak self] allowed,message in
                guard let self,self.queuedSteamInstall?.id == request.id,self.installCoordinator.acceptsDirect(id:request.id) else{return}
                guard allowed else{fail(message);return}
                self.preparingSteamBaseEngine=true
                self.runtimeSetup.start(progress:progress) { [weak self] outcome in
                    guard let self else{return};self.preparingSteamBaseEngine=false
                    guard self.queuedSteamInstall?.id == request.id else{return}
                    switch outcome {case .success(let engine):if engine.readyEngine {self.advanceSteamInstallPreparation()}else{fail("Le moteur Windows n’a pas terminé sa préparation.")};case .failure(let error):fail(error.localizedDescription)}
                }
            };return
        }
        if request.runtimeID == "playmelt-d3dmetal",(try? d3dMetalRuntime.descriptor(base:base))?.readyEngine != true {
            guard d3dMetalStore.snapshot()["imported"] as? Bool == true else {fail("Ce jeu nécessite DirectX 12. Importez le composant officiel Apple dans Paramètres, puis relancez l’installation.");return}
            accountService.authorize(capability:"runtime.download") { [weak self] allowed,message in
                guard let self,self.queuedSteamInstall?.id == request.id,self.installCoordinator.acceptsDirect(id:request.id) else{return}
                guard allowed else{fail(message);return}
                self.preparingSteamRenderer=true
                self.d3dMetalRuntime.start(base:base,progress:progress) { [weak self] outcome in
                    guard let self else{return};self.preparingSteamRenderer=false
                    guard self.queuedSteamInstall?.id == request.id else{return}
                    switch outcome {case .success(let engine):if engine.readyEngine {self.advanceSteamInstallPreparation()}else{fail("DirectX 12 n’a pas terminé sa préparation.")};case .failure(let error):fail(error.localizedDescription)}
                }
            };return
        }
        if NSRunningApplication.runningApplications(withBundleIdentifier:"com.valvesoftware.steam").isEmpty {
            guard !openingNativeSteamForInstall,let app=model.runtimes.first(where:{$0.id == "steam-mac"})?.appURL else {fail("Ouvrez Steam et connectez votre compte pour installer ce jeu.");return}
            openingNativeSteamForInstall=true
            installCoordinator.updateDirect(id:request.id,status:"preparing-steam",message:"Connexion au client Steam…",progress:nil,phase:"Connexion Steam")
            let config=NSWorkspace.OpenConfiguration();config.activates=false;config.hides=true
            NSWorkspace.shared.openApplication(at:app,configuration:config) { [weak self] application,error in
                DispatchQueue.main.async {
                    guard let self else{return};self.openingNativeSteamForInstall=false
                    guard self.queuedSteamInstall?.id == request.id else{return}
                    guard error == nil,application != nil else {fail("Steam n’a pas pu démarrer. Ouvrez-le puis réessayez.");return}
                    self.advanceSteamInstallPreparation()
                }
            };return
        }
        refresh { [weak self] in
            guard let self,self.queuedSteamInstall?.id == request.id,self.installCoordinator.acceptsDirect(id:request.id) else{return}
            self.accountService.authorize { [weak self] allowed,message in
                guard let self,self.queuedSteamInstall?.id == request.id,self.installCoordinator.acceptsDirect(id:request.id) else{return}
                guard allowed else{fail(message);return}
                self.startNativeSteamInstall(game:request.game,autoPlay:request.autoPlay,requestedRuntime:request.runtimeID,preparedJobID:request.id)
            }
        }
    }
    func startNativeSteamInstall(game: Game, autoPlay: Bool, requestedRuntime: String? = nil,preparedJobID:UUID? = nil) {
        if preparedJobID == nil,resumePreparedSteamPayload(game,preferredRuntimeID:requestedRuntime,autoPlay:autoPlay){return}
        var dispatched=false
        var preparationFailure="La préparation du jeu n’a pas pu aboutir."
        func reportFailure(_ message:String){preparationFailure=message;result(false,message)}
        defer {
            if !dispatched,let id=preparedJobID,installCoordinator.acceptsDirect(id:id) {
                queuedSteamInstall=nil
                installCoordinator.finishDirect(id:id,success:false,message:preparationFailure,code:"preparation-failed",retryable:true,resumePoint:"engine-preflight")
                sendState()
            }
        }
        guard !closing, !renderProtectionEnabled, !CommandLine.arguments.contains("--audit-read-only") else {
            reportFailure("Mode de protection : installation suspendue."); return
        }
        guard (!installCoordinator.isActive || preparedJobID.map({installCoordinator.acceptsDirect(id:$0)}) == true), activeInstallerProcess == nil else {
            reportFailure("Une installation est déjà en cours. Patientez ou annulez-la.")
            return
        }
        guard LibraryModel.validAppID(game.appId) else {
            reportFailure("Identifiant Steam manquant.")
            return
        }
        guard game.installBlockReason.isEmpty else {reportFailure(game.installBlockReason);return}
        let account = model.selectedAccountID
        let steamRoot = model.home.appendingPathComponent("Library/Application Support/Steam")
        guard SteamInstallAccountContext.permitsAutoLaunch(expected: account, active: activeSteamAccount(TextVDF.read(steamRoot.appendingPathComponent("config/loginusers.vdf")).object("users"))) else {
            reportFailure("Vérifiez le compte actif dans Steam avant l’installation."); return
        }
        if preparedJobID == nil {
            guard officialSteamPreparation == nil,!anyRuntimeOperation,game.store == "steam",model.metadata[game.appId]?.platforms.contains("windows") == true else {result(false,"Une préparation est en cours ou les métadonnées Windows du jeu manquent.");return}
            let required=SteamGameLaunchProfile.requiredRenderer(appID:game.appId)
            let route=requestedRuntime ?? (required == "d3dmetal" ? "playmelt-d3dmetal" : "playmelt-windows")
            guard ["playmelt-windows","playmelt-d3dmetal"].contains(route),required == "auto" || (route == "playmelt-d3dmetal" ? "d3dmetal":"dxmt") == required else {result(false,"Le moteur choisi ne correspond pas à ce jeu.");return}
            guard let id=installCoordinator.beginDirect(gameID:game.id,appID:game.appId,title:game.title,accountID:account,runtimeID:route,autoLaunch:autoPlay) else{return}
            queuedSteamInstall=(id,game,account,route,autoPlay)
            installCoordinator.updateDirect(id:id,status:"preparing-engine",message:"Préparation de l’installation…",progress:nil,phase:"Préparation du moteur")
            advanceSteamInstallPreparation();sendState();return
        }
        guard game.store == "steam", model.metadata[game.appId]?.platforms.contains("windows") == true,
              let runtime = validatedSteamRuntime(game, installing: true, requestedRuntime: requestedRuntime ?? game.runtimeId,repairJobID:preparedJobID), runtime.platform == "windows" else {
            reportFailure("Choisissez et préparez une route Windows compatible avant l’installation."); return
        }
        if autoPlay, let reason = SteamGameLaunchProfile.blockReason(appID: game.appId, platform: runtime.platform, renderer: runtime.renderer, graphicsValidated: runtime.graphicsValidated) {
            reportFailure(reason); return
        }
        let bundleScript = Bundle.main.url(forResource: "steam-installer", withExtension: "py")
        let sourceScript = (Bundle.main.infoDictionary?["MetalMaxSourceDirectory"] as? String).map {
            URL(fileURLWithPath: $0).appendingPathComponent("scripts/steam-installer.py")
        }
        let devScript = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/steam-installer.py")
        var scriptURL: URL?
        if let b = bundleScript, FileManager.default.fileExists(atPath: b.path) { scriptURL = b }
        else if PortablePythonRuntime.developmentAllowed,let s = sourceScript, FileManager.default.fileExists(atPath: s.path) { scriptURL = s }
        else if PortablePythonRuntime.developmentAllowed,FileManager.default.fileExists(atPath: devScript.path) { scriptURL = devScript }
        guard let finalScript = scriptURL else {
            reportFailure("Script d'installation Playmelt introuvable.")
            return
        }
        guard let python = PortablePythonRuntime.resolve(requireCertificates:true) else {
            reportFailure("Le runtime Python embarqué est absent ou incomplet. Réinstallez une version complète de Playmelt.")
            return
        }
        guard let id=preparedJobID,queuedSteamInstall?.account == account else{return}
        queuedSteamInstall=nil
        lastNotifiedPhase = ""
        sendToast("Démarrage du téléchargement de \(game.title)…")
        let proc = Process()
        proc.executableURL = python.pythonURL
        proc.arguments = [finalScript.path, "--appid", game.appId, "--title", game.title, "--accountid", account, "--renderer", runtime.renderer]
        proc.environment = python.environment(merging:ProcessInfo.processInfo.environment)
        let pipe = Pipe()
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        self.activeInstallerProcess = proc
        activeInstallerID = id; installerBuffer = Data(); installerEOF = false; installerExitStatus = nil
        pipe.fileHandleForReading.readabilityHandler = { [weak self, weak proc] handle in
            // Foundation read(upToCount:) waits for the requested count or EOF
            // on this pipe. Read the available bytes so progress is delivered
            // while the installer is still running, not only when it exits.
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; try? handle.close() }
            DispatchQueue.main.async {
                guard let self, let proc, self.activeInstallerProcess === proc, self.activeInstallerID == id else { return }
                if chunk.isEmpty {
                    if self.installCoordinator.acceptsDirect(id:id), !self.installerBuffer.isEmpty,
                       let parsed=try? JSONSerialization.jsonObject(with:self.installerBuffer) as? [String:Any] {
                        self.handleInstallerUpdate(json:parsed,game:game,id:id,account:account)
                    }
                    self.installerBuffer.removeAll()
                    self.installerEOF = true; self.finishNativeInstallerIfExited(id: id, process: proc); return
                }
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
            dispatched=true
            result(true, "Téléchargement de \(game.title) en cours dans Playmelt.")
            sendState()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close()
            activeInstallerProcess = nil; activeInstallerID = nil
            installCoordinator.finishDirect(id: id, success: false, message: "Impossible de lancer l'installateur : \(error.localizedDescription)")
            reportFailure("Erreur au lancement de l'installation.")
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
            installCoordinator.finishDirect(id:id,success:false,message:"L’installateur s’est arrêté sans confirmation de fin Steam (code \(installerExitStatus ?? -1)). Les fichiers sont conservés.",code:"installer-exited",retryable:true,resumePoint:"steam-depot-validation")
            if !closing { sendState() }
        }
        activeInstallerProcess = nil; activeInstallerID = nil; installerBuffer = Data()
        let callbacks = installerShutdownWaiters; installerShutdownWaiters.removeAll()
        for callback in callbacks { callback() }
    }
    func handleInstallerUpdate(json: [String: Any], game: Game, id: UUID, account: String) {
        guard !closing, installCoordinator.acceptsDirect(id: id), model.selectedAccountID == account else { return }
        installCoordinator.recordStageMetrics(id:id,stages:json["stages"] as? [[String:Any]] ?? [])
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
        if status == "files-prepared" {
            guard installCoordinator.finishPrepared(id:id,message:message) else{return}
            installCoordinator.updatePreparedStage(id:id,status:"preparing-client",message:"Fichiers conservés. Préparation automatique du lancement…")
            refresh { [weak self] in
                guard let self,!self.closing,self.model.selectedAccountID == account,
                      let runtimeID=self.installCoordinator.snapshot?["runtimeId"] as? String,
                      self.installCoordinator.acceptsPrepared(id:id,accountID:account,runtimeID:runtimeID) else{return}
                do {
                    guard let updated=self.model.games.first(where:{$0.store == "steam" && $0.appId == game.appId && $0.path.map{SteamDepotLaunchManifest.read($0,appID:game.appId)?.requiresOfficialSteam == true} == true}),let folder=updated.path,
                          let manifest=try SteamDepotLaunchManifest.selectAutomaticRenderer(folder:folder,appID:game.appId,preferredRuntimeID:runtimeID),manifest.requiresOfficialSteam else {
                        self.installCoordinator.finishDirect(id:id,success:false,message:"Le plan de lancement doit être revérifié. Les fichiers sont conservés.",code:"launch-plan-missing",retryable:true,resumePoint:"files-prepared");return
                    }
                    let route=manifest.renderer == "d3dmetal" ? "playmelt-d3dmetal":"playmelt-windows"
                    guard self.installCoordinator.configurePreparedFiles(id:id,accountID:account,runtimeID:route) else{return}
                    self.beginOfficialSteamPreparation(game:updated,runtimeID:route,account:account,installationJobID:id)
                    self.resumeOfficialSteamPreparation()
                } catch {self.installCoordinator.finishDirect(id:id,success:false,message:error.localizedDescription,code:"renderer-selection-failed",retryable:true,resumePoint:"files-prepared")}
            }
        } else if status == "launch-ready" {
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
            installCoordinator.finishDirect(id:id,success:false,message:message,code:(json["code"] as? String).flatMap{$0.range(of:"^[a-z0-9_-]{1,80}$",options:.regularExpression) != nil ? $0:nil} ?? "installer-failed",retryable:json["retryable"] as? Bool ?? false,resumePoint:json["resumePoint"] as? String)
            sendToast("Échec de l'installation de \(game.title) : \(message)", error: true)
            sendState()
        } else {
            installCoordinator.updateDirect(id: id, status: status, message: message, progress: percent, downloaded: downloaded, total: total, speed: speed, phase: phase)
        }
    }
    private func beginOfficialSteamPreparation(game:Game,runtimeID:String,account:String,installationJobID:UUID?=nil) {
        guard LibraryModel.validAppID(game.appId),LibraryModel.validAccountID(account) else{return}
        if let id=installationJobID,!installCoordinator.acceptsPrepared(id:id,accountID:account,runtimeID:runtimeID){return}
        if let pending=officialSteamPreparation,pending.gameID==game.id,pending.appID==game.appId,pending.runtimeID==runtimeID,pending.account==account,ProcessInfo.processInfo.systemUptime<pending.expiresAt {
            return
        }
        cancelOfficialSteamPreparation()
        officialSteamPreparation=SteamOfficialPreparation(gameID:game.id,appID:game.appId,runtimeID:runtimeID,account:account,installationJobID:installationJobID)
        if let id=installationJobID {installCoordinator.updatePreparedStage(id:id,status:"preparing-client",message:"Fichiers du jeu conservés. Préparation du client Steam Windows…")}
        officialSteamTimer=Timer.scheduledTimer(withTimeInterval:2,repeats:true){[weak self] _ in self?.resumeOfficialSteamPreparation()}
        notifyRuntime()
    }
    private func preparationStage(_ pending:SteamOfficialPreparation,status:String,message:String) {
        guard officialSteamPreparation?.id==pending.id,let id=pending.installationJobID else{return}
        installCoordinator.updatePreparedStage(id:id,status:status,message:message)
        sendState()
    }
    private func failOfficialPreparation(_ pending:SteamOfficialPreparation,message:String,code:String="steam-client-preparation",retryable:Bool=true) {
        guard officialSteamPreparation?.id==pending.id else{return}
        cancelOfficialSteamPreparation()
        if let id=pending.installationJobID {installCoordinator.finishDirect(id:id,success:false,message:message,code:code,retryable:retryable,resumePoint:"official-steam-windows")}
        result(false,message);sendState()
    }
    private func cancelOfficialSteamPreparation() {
        officialSteamTimer?.invalidate();officialSteamTimer=nil;officialSteamPreparation=nil
        steamReuseToken?.cancel()
        let intent=officialSteamBootstrapIntent;officialSteamBootstrapIntent=nil
        let rendererOwner=officialSteamRendererOwnerID;officialSteamRendererOwnerID=nil
        let baseOwner=officialSteamBaseEngineOwnerID;officialSteamBaseEngineOwnerID=nil
        guard intent != nil || steamReuseToken != nil || rendererOwner != nil || baseOwner != nil else{if !closing{notifyRuntime()};return}
        officialSteamStopping+=1;officialSteamStopGroup.enter()
        let stopped=DispatchGroup()
        if let intent{stopped.enter();intent.cancel{stopped.leave()}}
        if let rendererOwner{stopped.enter();d3dMetalRuntime.cancel(ifOwnedBy:rendererOwner){stopped.leave()}}
        if baseOwner != nil {runtimeSetup.cancel();stopped.enter();officialSteamBaseEngineGroup.notify(queue:.main){stopped.leave()}}
        stopped.enter();steamReuseGroup.notify(queue:.main){stopped.leave()}
        stopped.notify(queue:.main){[self] in officialSteamStopping-=1;officialSteamStopGroup.leave();if !closing{notifyRuntime()}}
        if !closing{notifyRuntime()}
    }
    private func rememberOfficialSteamPreparation(_ payload:[String:Any],runtimeID:String)->Bool {
        guard let id=payload["gameId"] as? String,let game=model.games.first(where:{$0.id==id && $0.store == "steam"}),let folder=game.path,
              let manifest=SteamDepotLaunchManifest.read(folder,appID:game.appId),manifest.requiresOfficialSteam,manifest.renderer != "auto",
              runtimeID == (manifest.renderer == "d3dmetal" ? "playmelt-d3dmetal":"playmelt-windows") else{return false}
        beginOfficialSteamPreparation(game:game,runtimeID:runtimeID,account:model.selectedAccountID)
        return true
    }
    private func authorizeSteamPreparation(_ pending:SteamOfficialPreparation,capability:String,action:@escaping()->Void) {
        guard officialSteamPreparation?.id == pending.id else{return}
        officialSteamPreparation?.requestInFlight=true
        accountService.authorize(capability:capability){[weak self] allowed,message in
            guard let self,self.officialSteamPreparation?.id == pending.id,!self.closing else{return}
            self.officialSteamPreparation?.requestInFlight=false
            guard self.model.selectedAccountID == pending.account else{self.failOfficialPreparation(pending,message:"Le compte Steam a changé. La préparation est arrêtée sans lancer de jeu.",code:"steam-account-changed",retryable:false);return}
            guard ProcessInfo.processInfo.systemUptime<pending.expiresAt else{self.failOfficialPreparation(pending,message:"La préparation Steam a expiré. Les fichiers sont conservés.");return}
            guard !self.renderProtectionEnabled,!self.anyRuntimeOperation else{return}
            guard allowed else{self.failOfficialPreparation(pending,message:message,code:"access-required");return}
            action()
        }
    }
    private func resumeOfficialSteamPreparation() {
        guard let pending=officialSteamPreparation,!closing else{return}
        if let id=pending.installationJobID,!installCoordinator.acceptsPrepared(id:id,accountID:pending.account,runtimeID:pending.runtimeID){cancelOfficialSteamPreparation();return}
        guard pending.account == model.selectedAccountID,ProcessInfo.processInfo.systemUptime<pending.expiresAt else {
            failOfficialPreparation(pending,message:"Reprise Steam arrêtée : compte changé ou attente expirée. Les fichiers et connexions sont conservés.",retryable:pending.account==model.selectedAccountID);return
        }
        if let intent=officialSteamBootstrapIntent,intent.ownerID==pending.id {
            if case .stopped(let message)=intent.poll(){failOfficialPreparation(pending,message:message);return}
        }
        guard let game=model.games.first(where:{$0.id==pending.gameID && $0.appId==pending.appID}),let folder=game.path,
              let manifest=SteamDepotLaunchManifest.read(folder,appID:game.appId),manifest.renderer != "auto",
              pending.runtimeID == (manifest.renderer == "d3dmetal" ? "playmelt-d3dmetal":"playmelt-windows") else{failOfficialPreparation(pending,message:"Le plan de lancement du jeu a changé. Les fichiers sont conservés.",code:"launch-plan-changed",retryable:false);return}
        guard !pending.requestInFlight,!renderProtectionEnabled,!anyRuntimeOperation else{return}
        let base=runtimeSetup.descriptor(),dx12=pending.runtimeID == "playmelt-d3dmetal"
        if !base.readyEngine {
            guard clientLauncher.activeCount == 0, steamProcessLauncher.activeCount == 0 else{return}
            preparationStage(pending,status:"preparing-client",message:"Préparation du moteur Windows. Les fichiers du jeu sont conservés…")
            authorizeSteamPreparation(pending,capability:"runtime.download"){[weak self] in
                guard let self else{return}
                self.officialSteamBaseEngineOwnerID=pending.id
                let group=self.officialSteamBaseEngineGroup;group.enter()
                self.runtimeSetup.start(progress:{[weak self] _ in self?.notifyRuntime()}){[weak self] outcome in
                    defer{group.leave()}
                    guard let self,self.officialSteamBaseEngineOwnerID==pending.id else{return}
                    self.officialSteamBaseEngineOwnerID=nil
                    guard !self.closing,self.officialSteamPreparation?.id==pending.id,self.model.selectedAccountID==pending.account else{return}
                    switch outcome {
                    case .success(let engine):
                        if engine.readyEngine {self.refresh{self.resumeOfficialSteamPreparation()}}
                        else {self.failOfficialPreparation(pending,message:"Le moteur Windows n’a pas terminé sa préparation.",code:"engine-not-ready")}
                    case .failure(let error):self.failOfficialPreparation(pending,message:error.localizedDescription,code:"engine-preparation-failed")
                    }
                }
            };return
        }
        if dx12,(try? d3dMetalRuntime.descriptor(base:base))?.readyEngine != true {
            guard clientLauncher.activeCount == 0, steamProcessLauncher.activeCount == 0 else{return}
            guard d3dMetalStore.snapshot()["imported"] as? Bool == true else {failOfficialPreparation(pending,message:"Importe le composant Apple DirectX 12 pour terminer la préparation du jeu.",code:"renderer-import-required");return}
            preparationStage(pending,status:"preparing-client",message:"Préparation du moteur DirectX 12…")
            authorizeSteamPreparation(pending,capability:"runtime.download"){[weak self] in
                guard let self else{return}
                self.officialSteamRendererOwnerID=pending.id
                self.d3dMetalRuntime.start(base:base,ownerID:pending.id,progress:{[weak self] _ in self?.notifyRuntime()}){[weak self] result in
                    guard let self,self.officialSteamRendererOwnerID==pending.id else{return}
                    self.officialSteamRendererOwnerID=nil
                    guard !self.closing,self.officialSteamPreparation?.id==pending.id,self.model.selectedAccountID==pending.account else{return}
                    switch result {case .success:self.refresh{self.resumeOfficialSteamPreparation()};case .failure(let error):self.failOfficialPreparation(pending,message:error.localizedDescription)}
                }
            };return
        }
        let descriptor=dx12 ? (try? d3dMetalRuntime.descriptor(base:base)):base
        guard let descriptor,descriptor.readyEngine else{failOfficialPreparation(pending,message:"Le moteur Windows doit terminer sa préparation.",code:"engine-not-ready");return}
        let active=activeSteamAccount(TextVDF.read(descriptor.steamRoot.appendingPathComponent("config/loginusers.vdf")).object("users"))
        switch pending.next(selectedAccount:model.selectedAccountID,steamInstalled:descriptor.steamInstalled,activeAccount:active) {
        case .prepareClient:
            preparationStage(pending,status:"preparing-client",message:"Installation du client officiel Steam Windows. Les fichiers du jeu sont conservés.")
            guard clientLauncher.activeCount == 0, steamProcessLauncher.activeCount == 0 else{return}
            guard officialSteamBootstrapIntent == nil else {
                failOfficialPreparation(pending,message:"La préparation du client Steam s’est arrêtée. Les fichiers du jeu sont conservés.");return
            }
            authorizeSteamPreparation(pending,capability:"runtime.download"){[weak self] in
                guard let self else{return}
                self.result(true,"Préparation automatique du client officiel Steam Windows. Le jeu choisi et ses fichiers sont conservés ; une première connexion sera demandée uniquement si Steam en a besoin.")
                let intent=SteamBootstrapIntent(ownerID:pending.id,bootstrap:dx12 ? self.d3dMetalSteamBootstrap:self.steamBootstrap)
                self.officialSteamBootstrapIntent=intent
                if case .stopped(let message)=intent.poll(){self.failOfficialPreparation(pending,message:message)}
            }
        case .openLogin:
            preparationStage(pending,status:"awaiting-account",message:"Connecte le même compte dans Steam Windows. L’installation reprendra ensuite automatiquement.")
            officialSteamPreparation?.loginOpened=true;notifyRuntime()
            openWindowsSteam(runtimeID:pending.runtimeID)
            result(true,"Connecte le même compte dans Steam Windows. Playmelt reprendra le jeu choisi après cette connexion ; tu peux arrêter cette reprise depuis sa fiche.")
        case .waitForLogin:break
        case .prepareFiles:
            preparationStage(pending,status:"preparing-files",message:"Réutilisation des fichiers du jeu dans la bibliothèque officielle Steam…")
            authorizeSteamPreparation(pending,capability:"runtime.download"){[weak self] in self?.prepareOfficialSteamReuse(pending,folder:folder,descriptor:descriptor)}
        case .install:
            authorizeSteamPreparation(pending,capability:"launch"){[weak self] in
                guard let self,let current=self.officialSteamPreparation,current.id==pending.id,
                      let runtime=self.model.runtimes.first(where:{$0.id==pending.runtimeID && $0.available}),
                      current.next(selectedAccount:self.model.selectedAccountID,steamInstalled:descriptor.steamInstalled,activeAccount:activeSteamAccount(TextVDF.read(descriptor.steamRoot.appendingPathComponent("config/loginusers.vdf")).object("users"))) == .install("steam://install/"+pending.appID) else{return}
                _=runtime
                let autoPlay=pending.installationJobID.map{self.installCoordinator.snapshot?["id"] as? String==$0.uuidString && self.installCoordinator.snapshot?["autoLaunch"] as? Bool==true} ?? false
                self.preparationStage(pending,status:"awaiting-steam",message:"Vérification finale des fichiers et composants par Steam Windows…")
                self.cancelOfficialSteamPreparation()
                self.officialSteamStopGroup.notify(queue:.main){[weak self] in
                    guard let self,!self.closing,self.model.selectedAccountID==pending.account else{return}
                    if let id=pending.installationJobID {
                        guard self.installCoordinator.snapshot?["id"] as? String==id.uuidString,self.installCoordinator.snapshot?["status"] as? String=="awaiting-steam" else{return}
                    }
                    // Follow the official client's real manifest to completion;
                    // dispatching an install URI alone is never success.
                    self.installAndPlay(game,runtimeID:pending.runtimeID,autoPlay:autoPlay)
                    if !self.installCoordinator.isActive,let id=pending.installationJobID {
                        self.installCoordinator.finishDirect(id:id,success:false,message:"Le suivi du client Steam n’a pas pu démarrer. Les fichiers sont conservés.",code:"steam-followup-unavailable",retryable:true,resumePoint:"official-steam-windows")
                    }
                    self.sendState()
                }
            }
        case .cancelled,.expired:failOfficialPreparation(pending,message:"La préparation Steam est interrompue. Les fichiers sont conservés.")
        }
    }
    private func prepareOfficialSteamReuse(_ pending:SteamOfficialPreparation,folder:URL,descriptor:PlaymeltRuntimeDescriptor) {
        guard officialSteamPreparation?.id==pending.id,steamReuseToken == nil,
              let script=PortablePythonRuntime.resource(named:"steam_reuse.py"),let python=PortablePythonRuntime.resolve(requireCertificates:true) else {failOfficialPreparation(pending,message:"Préparation de réutilisation Steam indisponible.");return}
        let token=OwnedOperationToken();steamReuseToken=token;officialSteamPreparation?.requestInFlight=true
        notifyRuntime();steamReuseGroup.enter()
        steamReuseQueue.async{[self] in
            defer{steamReuseGroup.leave()}
            var request=OwnedProcessRequest(executable:python.pythonURL,arguments:["-B",script.path,"--game-folder",folder.path,"--steam-root",descriptor.steamRoot.path,"--appid",pending.appID],environment:python.environment(merging:["PATH":"/usr/bin:/bin","LANG":"en_US.UTF-8"]))
            request.timeout=600;request.outputLimit=32000
            let response:[String:Any]
            do {
                let output=try OwnedProcessRunner().run(request,cancelled:{token.isCancelled})
                let decoded=(try? JSONSerialization.jsonObject(with:output.output)) as? [String:Any] ?? ["status":"error","error":"Réponse de réutilisation Steam invalide."]
                response=output.exitCode == 0 ? decoded:["status":"error","error":decoded["error"] as? String ?? "La préparation des fichiers Steam a échoué."]
            }catch{response=["status":"error","error":error.localizedDescription]}
            DispatchQueue.main.async{[self] in
                if steamReuseToken === token{steamReuseToken=nil}
                guard !closing,officialSteamPreparation?.id==pending.id else{return}
                officialSteamPreparation?.requestInFlight=false
                guard !token.isCancelled,model.selectedAccountID==pending.account else{failOfficialPreparation(pending,message:"La préparation des fichiers a été interrompue ou le compte a changé.",code:"steam-context-changed",retryable:false);return}
                if ["prepared","existing-directory"].contains(response["status"] as? String ?? "") {
                    officialSteamPreparation?.reusePrepared=true;notifyRuntime();resumeOfficialSteamPreparation()
                }else{failOfficialPreparation(pending,message:response["error"] as? String ?? "Réutilisation des fichiers Steam à vérifier.")}
            }
        }
    }
    func validatedSteamRuntime(_ game: Game, installing: Bool, requestedRuntime: String?,repairJobID:UUID?=nil) -> Runtime? {
        guard !renderProtectionEnabled else { result(false, "Rendus en cours : installation et lancement suspendus."); return nil }
        guard LibraryModel.validAppID(game.appId), let runtime = model.runtimes.first(where: { $0.id == (installing ? requestedRuntime ?? game.runtimeId : game.runtimeId) && (installing ? $0.installationAvailable : $0.available) }) else { result(false, "Aucun moteur utilisable pour cette route."); return nil }
        guard SteamGameLaunchProfile.supportsInstallation(appID: game.appId, runtime: runtime) else { result(false, "Ce jeu nécessite un autre moteur graphique."); return nil }
        if !installing, let reason = SteamGameLaunchProfile.blockReason(appID: game.appId, platform: runtime.platform, renderer: runtime.renderer, graphicsValidated: runtime.graphicsValidated) { result(false, reason); return nil }
        if runtime.platform == "windows" && (runtimeIsBusy || d3dMetalIsBusy || steamBootstrap.busy || d3dMetalSteamBootstrap.busy) { result(false, "La préparation Windows est encore en cours."); return nil }
        if installing {
            let payload=game.store == "steam" ? game.path.flatMap{SteamDepotLaunchManifest.read($0,appID:game.appId)}:nil
            let officialFollowup=installCoordinator.permitsPreparedFollowup(appID:game.appId,accountID:model.selectedAccountID,runtimeID:runtime.id,
                platform:runtime.platform,renderer:runtime.renderer,payloadRenderer:payload?.requiresOfficialSteam == true ? payload?.renderer:nil)
            let repairing=repairJobID.map{installCoordinator.permitsPayloadRepair(id:$0,appID:game.appId,accountID:model.selectedAccountID,runtimeID:runtime.id,
                needsRepair:runtime.platform == "windows" && needsWindowsSteamRepair(game,requestedRuntime:runtime.id))} ?? false
            guard !model.hasCompleteInstallation(appID: game.appId, runtimeID: runtime.id) || officialFollowup || repairing,
                  let info = model.metadata[game.appId], info.platforms.contains(runtime.platform == "mac" ? "macos" : "windows") else { result(false, "Cette édition ne peut pas être installée avec le client choisi."); return nil }
        } else if !game.installed || !game.complete || game.json(runtimes: model.runtimes,steamAccountID:model.selectedAccountID)["canLaunch"] as? Bool != true { result(false, "Installation absente ou incomplète. Vérifiez-la dans Steam."); return nil }
        let accountRoot = installing && runtime.platform == "windows" ? model.home.appendingPathComponent("Library/Application Support/Steam") : runtime.steamRoot
        let active = activeSteamAccount(TextVDF.read(accountRoot.appendingPathComponent("config/loginusers.vdf")).object("users"))
        if let active, !model.selectedAccountID.isEmpty, active != model.selectedAccountID { result(false, "Changez de compte dans Steam pour utiliser le compte sélectionné."); return nil }
        return runtime
    }
    static func windowsLaunchArguments(appID: String) -> [String]? {
        SteamGameLaunchProfile.windowsArguments(appID: appID)
    }
    func dispatchSteam(_ game: Game, runtime: Runtime, installing: Bool, onFailure: @escaping (String) -> Void,
                       completion: @escaping (Bool, String) -> Void) {
        accountService.authorize { [weak self] ok,message in
            guard let self,!self.closing else {completion(false,"Playmelt se ferme.");return}
            guard ok else {completion(false,message);return}
            self.dispatchAuthorizedSteam(game,runtime:runtime,installing:installing,onFailure:onFailure,completion:completion)
        }
    }
    private func dispatchAuthorizedSteam(_ game:Game,runtime:Runtime,installing:Bool,onFailure:@escaping(String)->Void,completion:@escaping(Bool,String)->Void) {
        guard !renderProtectionEnabled else { completion(false, "Rendus en cours : installation et lancement suspendus."); return }
        guard runtime.executionAllowed else { completion(false, WindowsExecutionPolicy.message); return }
        let key = "game:\(runtime.id):\(game.appId)"
        guard !closing, let token = requestGate.acquire(key) else { completion(false, "Demande déjà envoyée à Steam."); return }
        let finish: (Bool, String) -> Void = { [weak self] ok, message in
            self?.requestGate.finish(key, token: token); completion(ok, message)
        }
        if !installing, runtime.platform == "windows", game.appId != "2651280" {
            do {
                let context = gameSettingsContext(game, performanceUnavailableReason: GamePerformanceRuntime.officialSteamReason)
                _ = try gameSettingsStore.performanceRequest(for: context, resolvedBackend: runtime.renderer)
            } catch { finish(false, error.localizedDescription); return }
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
    /// Octets d'icône locaux pour un jeu : cache Steam (librarycache des deux
    /// clients), sinon fichiers d'artwork locaux (imports, Epic/GOG téléchargés).
    func gameArtworkData(_ game: Game) -> Data? {
        let roots = [model.home.appendingPathComponent("Library/Application Support/Steam/appcache/librarycache")]
            + model.runtimes.map { $0.steamRoot.appendingPathComponent("appcache/librarycache") }
        let info = model.metadata[game.appId]
        for root in roots {
            for file in SteamArtworkHandler.candidateFiles(root: root, appID: game.appId, info: info, portrait: false) {
                guard let data = try? Data(contentsOf: file), data.count > 64, data.count <= 8_000_000 else { continue }
                return data
            }
        }
        for raw in [game.customImageURL, game.customPortraitURL] where !raw.isEmpty {
            let url = raw.hasPrefix("file://") ? URL(fileURLWithPath: String(raw.dropFirst(7))) : URL(fileURLWithPath: raw)
            guard url.path.hasPrefix("/"), !(raw.lowercased().hasPrefix("http://") || raw.lowercased().hasPrefix("https://")),
                  FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url), data.count > 64, data.count <= 8_000_000 else { continue }
            return data
        }
        return nil
    }
    func runWindowsClient(_ runtime: Runtime, arguments: [String], onFailure: @escaping (String) -> Void,
                          completion: @escaping (Bool, String) -> Void) {
        guard runtime.executionAllowed else { completion(false, WindowsExecutionPolicy.message); return }
        guard !closing else { completion(false, "Playmelt se ferme."); return }
        guard !renderProtectionEnabled else { completion(false, "Rendus en cours : Steam Windows est suspendu."); return }
        let candidate = runtime.id == "playmelt-d3dmetal" ? try? d3dMetalRuntime.descriptor(base: runtimeSetup.descriptor()) : runtimeSetup.descriptor()
        guard let descriptor = candidate else { completion(false, "Le moteur DirectX 12 n’est pas préparé."); return }
        guard runtime.verifiedIndependentEngine, descriptor.readyEngine, descriptor.steamInstalled,
              runtime.prefixURL == descriptor.prefixURL, runtime.wineURL == descriptor.wineURL else { completion(false, "Le moteur Windows ou Steam Windows n’est pas prêt."); return }
        do {
            let target=try GameDisplayMetadata.launchTarget(GameDisplayMetadata.screens())
            guard let library=Bundle.main.url(forResource:"libPlaymeltDisplayGuard",withExtension:"dylib") else {throw RuntimeSetupError.failed("Protection des écrans absente.")}
            let safeEnvironment=try GameDisplayMetadata.guardedEnvironment(descriptor.environment,target:target,library:library)
            // Identité Dock : quand la demande vise un jeu précis, le client démarre
            // sous le bundle de CE jeu (logo + nom dans le Dock, mode Jeu inclus).
            var wine=descriptor.wineURL
            if let uri=arguments.first(where:{$0.hasPrefix("steam://")}) {
                let parts=uri.dropFirst("steam://".count).split(separator:"/").map(String.init)
                if parts.count>=2,["install","rungameid"].contains(parts[0]),LibraryModel.validAppID(parts[1]) {
                    let appID=parts[1]
                    let game=model.games.first(where:{$0.appId==appID})
                    let title=game?.title ?? "Jeu \(appID)"
                    let bundle=GameDockRuntime.ensure(appID:appID,title:title,
                        runtimeRoot:model.home.appendingPathComponent("Library/Application Support/Playmelt/Runtime",isDirectory:true),
                        iconData:game.map { gameArtworkData($0) } ?? nil)
                    if let bundle { wine=bundle.appendingPathComponent("Contents/MacOS/wine") }
                }
            }
            steamClientLifecycle.request(prefix: descriptor.prefixURL, wine: wine,
                steam: descriptor.steamRoot.appendingPathComponent("steam.exe"), arguments: arguments,
                environment: safeEnvironment, directory: descriptor.prefixURL) { [weak self] outcome in
                guard let self, !self.closing else { return }
                switch outcome {
                case .success: completion(true, "Demande transmise au client Steam Windows.")
                case .failure(let error): completion(false, error.localizedDescription)
                }
            }
        }
        catch { completion(false, error.localizedDescription) }
    }
    func route(_ game: Game, installing: Bool, requestedRuntime: String?) {
        accountService.authorize { [weak self] ok,message in
            guard let self,!self.closing else{return}
            guard ok else {self.result(false,message);self.notify("onAccountRequired",[:]);return}
            self.routeAuthorized(game,installing:installing,requestedRuntime:requestedRuntime)
        }
    }
    private func routeAuthorized(_ game:Game,installing:Bool,requestedRuntime:String?) {
        guard !closing, !renderProtectionEnabled else { result(false, "Rendus en cours : installation et lancement suspendus."); return }
        gameMediaPlayer.close()
        guard !CommandLine.arguments.contains("--audit-read-only") else { result(false, "Mode de vérification : installations et lancements désactivés."); return }
        if installing {
            guard !installCoordinator.isActive else { result(false, "Un suivi d’installation est déjà en cours. Arrêtez le suivi avant une autre demande."); return }
        }
        if game.store == "xbox" {
            let urlStr = game.epicLaunchID.isEmpty ? "https://www.xbox.com/play" : game.epicLaunchID
            if let url = URL(string: urlStr), let webView {
                hubBrowser.closePanel()
                XboxCloudWindowController.shared.open(url: url, isGameLaunch: XboxCloudRoute.isLaunch(url), over: webView)
                result(true, "Lancement de \(game.title) sur Xbox Cloud Gaming…")
            }
            return
        }
        if game.store == "gog", !(game.platform == "windows" && game.installSource == "local") {
            launchGOGGame(game)
            return
        }
        if installing, game.store == "epic" {
            installEpicGame(game)
            return
        }
        if !installing,game.store == "steam",let folder=game.path,
           let manifest=SteamDepotLaunchManifest.read(folder,appID:game.appId),manifest.requiresOfficialSteam {
            let runtimeID=manifest.renderer == "d3dmetal" ? "playmelt-d3dmetal":"playmelt-windows"
            guard manifest.officialClientIssue(accountID:model.selectedAccountID)==nil else {
                resumePreparedSteamPayload(game,preferredRuntimeID:runtimeID,autoPlay:true);return
            }
            // The manifest selects the environment. Revalidate the completed
            // payload against that actual route, without install/duplicate rules.
            var preparedGame=game;preparedGame.runtimeId=runtimeID
            guard let runtime=validatedSteamRuntime(preparedGame,installing:false,requestedRuntime:runtimeID) else{return}
            // Steam validates the licence and executes its signed first-start
            // scripts. No pending prerequisite is bypassed by running the EXE.
            dispatchSteam(preparedGame,runtime:runtime,installing:false,onFailure:{[weak self] message in self?.result(false,message)}){[weak self] ok,message in self?.result(ok,message)}
            return
        }
        var extraArguments: [String] = []
        var requestedBackend = "auto"
        var safeWindowsEnvironment:[String:String]?
        if !installing, game.platform == "windows", game.installed {
            if let issue = localLaunchBlockReason(for: game,steamAccountID:model.selectedAccountID) { result(false, issue); refresh(); return }
            let context = gameSettingsContext(game)
            let preferences = gameSettingsStore.snapshot(game: context, hardware: [:], displays: [])
            guard preferences["status"] as? String != "error" else {
                result(false, "Ouvrez les paramètres du jeu : \(preferences["error"] as? String ?? "configuration invalide").")
                return
            }
            if let issue = preferences["launchBlockReason"] as? String, !issue.isEmpty {
                result(false, issue)
                return
            }
            extraArguments = gameSettingsStore.launchArguments(for: context)
            requestedBackend = gameSettingsStore.requestedBackend(for: context)
            do {
                let screen=(preferences["settings"] as? [String:Any])?["display"] as? [String:Any]
                let target=try GameDisplayMetadata.launchTarget(GameDisplayMetadata.screens(),requested:screen?["screenID"] as? String ?? "primary")
                guard let library=Bundle.main.url(forResource:"libPlaymeltDisplayGuard",withExtension:"dylib") else {throw RuntimeSetupError.failed("Protection des écrans absente.")}
                let displayEnvironment = try GameDisplayMetadata.guardedEnvironment(ProcessInfo.processInfo.environment,target:target,library:library)
                guard let selection = localGamePerformanceSelection(for: game, requestedBackend: requestedBackend) else {
                    throw GamePerformanceRuntime.Failure(message: "Le processus Windows et son moteur doivent être identifiés avant le lancement.")
                }
                let performanceContext = gameSettingsContext(game, requestedBackend: requestedBackend)
                let performance = try gameSettingsStore.performanceRequest(for: performanceContext, resolvedBackend: selection.renderer)
                safeWindowsEnvironment = try GamePerformanceRuntime.environment(base: displayEnvironment, request: performance,
                    appID: game.appId, renderer: selection.renderer, executable: selection.executable,
                    resolution: selection.resolution, d3dMetalFPSQualified: selection.renderer.hasPrefix("d3dmetal") && d3dMetalFPSQualified())
            }catch{result(false,error.localizedDescription);return}
        }
        if !installing,game.store=="epic",game.installed,let directory=game.path,
           directory.resolvingSymlinksInPath().path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Playmelt/Games").resolvingSymlinksInPath().path+"/") {
            launchManagedEpic(game,backend:requestedBackend,arguments:extraArguments,environment:safeWindowsEnvironment)
            return
        }
        if !installing, game.platform == "windows", game.installed, game.complete,
           let script = ensureLaunchScript(for: game, requestedBackend: requestedBackend, iconData: gameArtworkData(game)) {
            let key = "launch-script:\(game.appId.isEmpty ? game.id : game.appId)"
            guard let token = requestGate.acquire(key) else { result(false, "Demande déjà envoyée."); return }
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
                let benchmarkSession=UUID().uuidString
                guard var launchEnvironment=safeWindowsEnvironment else {throw RuntimeSetupError.failed("L’écran du jeu n’a pas été vérifié.")}
                guard (try String(contentsOf:script,encoding:.utf8)).contains("# Playmelt display guard v1") else {throw RuntimeSetupError.failed("Ce lanceur doit être mis à jour avant de pouvoir protéger les autres écrans.")}
                launchEnvironment["PLAYMELT_BENCHMARK_SESSION"]=benchmarkSession
                _ = try clientLauncher.launch(executable: URL(fileURLWithPath: "/bin/bash"),
                                              arguments: [script.path] + (game.appId == "2651280" ? [] : extraArguments),
                                              environment: launchEnvironment,
                                              directory: script.deletingLastPathComponent()) { [weak self] code in
                    if self?.stopLaunchWatch(gameKey) == true {
                        self?.notify("onLaunchProgress", ["gameId": gameKey, "title": game.title, "state": "ended", "elapsed": Int(Date().timeIntervalSince(launchStartTime))])
                    }
                    self?.requestGate.finish(key, token: token)
                    monitorTimer?.invalidate()
                    monitorTimer = nil
                    let elapsed = Int64(Date().timeIntervalSince(launchStartTime))
                    if elapsed > 2 {
                        PlaytimeStore.shared.addSession(key: gameKey, seconds: elapsed)
                        self?.refresh()
                    }
                    if code != 0 { self?.result(false, "Le jeu s’est arrêté (code \(code)). Consultez le diagnostic du lancement.") }
                }
                benchmarks.onChange = { [weak self] in self?.sendState() }
                benchmarks.start(game:game,session:benchmarkSession,settings:gameSettingsStore.snapshot(game:gameSettingsContext(game),hardware:[:],displays:[]),hardware:hardwareState(renderProtectionEnabled:renderProtectionEnabled))
                startLaunchWatch(gameID: gameKey, title: game.title, startedAt: launchStartTime)
                result(true, "Ouverture de \(game.title)…")
                return
            } catch {
                requestGate.finish(key, token: token)
                result(false, "Impossible de lancer le jeu : \(error.localizedDescription)")
                return
            }
        }
        if !installing, game.platform == "windows", game.installed, game.complete,
           game.store != "xbox" {
            result(false, "La protection des écrans de ce lancement Windows reste à valider. Le lancement est suspendu pour préserver votre bureau.")
            return
        }
        if installing, game.store == "steam", !game.appId.isEmpty {
            if prefersNativeSteam(game, requestedRuntime: requestedRuntime) {
                installAndPlay(game,runtimeID:"steam-mac",autoPlay:false)
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
            launchGOGGame(game)
            return
        }
        guard let runtime = validatedSteamRuntime(game, installing: installing, requestedRuntime: requestedRuntime) else { return }
        dispatchSteam(game, runtime: runtime, installing: installing, onFailure: { [weak self] message in self?.result(false, message) }) { [weak self] ok, message in self?.result(ok, message) }
    }
    private func launchGOGGame(_ game: Game) {
        guard !closing, !renderProtectionEnabled, !CommandLine.arguments.contains("--audit-read-only") else { return }
        guard let app = model.gogConnector.nativeLaunchURL(gameID: game.id),
              FileManager.default.fileExists(atPath: app.path) else {
            notifyInstallJob()
            let observed = installationJobs.first { $0["store"] as? String == "gog" && $0["gameId"] as? String == game.id }
            result(false, observed?["message"] as? String ?? "Aucune installation GOG prête n’a été vérifiée pour ce jeu. Actualisez la bibliothèque.")
            return
        }
        let key = "gog-native:" + game.appId
        guard let token = requestGate.acquire(key) else { result(false, "Le démarrage de ce jeu est déjà demandé."); return }
        NSWorkspace.shared.openApplication(at: app, configuration: .init()) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.requestGate.finish(key, token: token)
                guard !self.closing else { return }
                self.result(error == nil, error == nil ? "Démarrage de \(game.title)…" : "Le jeu n’a pas pu démarrer : \(error!.localizedDescription)")
            }
        }
    }
    func uninstallGame(_ game: Game) {
        guard !closing, !renderProtectionEnabled, !CommandLine.arguments.contains("--audit-read-only") else {
            result(false, "Désinstallation suspendue par le mode de protection."); return
        }
        guard !installCoordinator.isActive, clientLauncher.activeCount == 0, steamProcessLauncher.activeCount == 0, EpicLaunchAuthorization.activeLaunchCount == 0 else { result(false, "Terminez l’installation ou fermez le jeu avant de désinstaller."); return }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let steamRoots = model.runtimes.flatMap { model.libraryRoots($0) }
        var roots = [home.appendingPathComponent("Library/Application Support/Playmelt/Games")] + steamRoots.map { $0.appendingPathComponent("steamapps/common") }
        var uninstallTarget = game
        let gogDirectory = game.store == "gog" ? model.gogConnector.verifiedInstallationDirectory(gameID: game.id) : nil
        if game.store == "gog" {
            guard let directory = gogDirectory, let app = model.gogConnector.nativeLaunchURL(gameID: game.id),
                  !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL?.resolvingSymlinksInPath() == app.resolvingSymlinksInPath() }) else {
                result(false, "Fermez le jeu et attendez la vérification de son installation GOG avant de désinstaller."); return
            }
            // The registered game directory contains the app and its data. The
            // Galaxy client/session directories never become uninstall targets.
            roots.append(directory.deletingLastPathComponent())
            uninstallTarget.path = directory
        }
        do {
            let plan = try GameUninstallPlan.make(game: uninstallTarget, installRoots: roots, steamRoots: steamRoots)
            let alert = NSAlert()
            alert.messageText = game.store == "gog" ? "Retirer les fichiers de \(game.title) ?" : "Désinstaller \(game.title) ?"
            alert.informativeText = "Le dossier suivant et ses fichiers seront déplacés dans la Corbeille :\n\n\(plan.installation.path)\n\nVous pourrez les restaurer depuis la Corbeille. Les sauvegardes stockées hors de ce dossier et vos comptes de plateforme sont conservés."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Annuler")
            let trashButton = alert.addButton(withTitle: "Déplacer dans la Corbeille")
            if #available(macOS 11.0, *) {
                trashButton.hasDestructiveAction = true
            }
            guard alert.runModal() == .alertSecondButtonReturn else { return }
            guard !closing, !renderProtectionEnabled, !installCoordinator.isActive, clientLauncher.activeCount == 0, steamProcessLauncher.activeCount == 0,
                  game.store != "gog" || model.gogConnector.verifiedInstallationDirectory(gameID: game.id) == gogDirectory,
                  try GameUninstallPlan.make(game: uninstallTarget, installRoots: roots, steamRoots: steamRoots) == plan else {
                result(false, "L’installation a changé. Aucun fichier n’a été déplacé."); return
            }
            if game.store == "gog", let app = model.gogConnector.nativeLaunchURL(gameID: game.id),
               NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL?.resolvingSymlinksInPath() == app.resolvingSymlinksInPath() }) {
                result(false, "Le jeu est ouvert. Aucun fichier n’a été déplacé."); return
            }
            for item in plan.items { try fm.trashItem(at: item, resultingItemURL: nil) }
            if game.store == "gog" { model.gogConnector.invalidate(); model.gogConnector.startInstallObservation() }
            refresh { [weak self] in
                self?.result(true, game.store == "gog" ? "Les fichiers de \(game.title) sont dans la Corbeille. Le registre de Galaxy sera vérifié lors de l’actualisation." : "\(game.title) a été désinstallé. Ses fichiers sont dans la Corbeille.")
            }
        } catch {
            refresh()
            result(false, "Désinstallation incomplète : \(error.localizedDescription). Vérifiez la Corbeille avant de réessayer.")
        }
    }
    func beginShutdown() {
        guard !closing else { return }
        closing = true
        hubBrowser.closePanel()
        gameMediaPlayer.close(); gameMedia.shutdown()
        XboxCloudWindowController.shared.closePanel()
        queuedSteamInstall = nil
        cancelOfficialSteamPreparation(); accountService.shutdown(); accountWebAuthentication.cancel(); localGameImport.cancel(); benchmarks.stop(); requestGate.shutdown()
        // Closing the app interrupts work; only an explicit cancellation makes
        // a job terminal. Recovery restores this checkpoint without autoplay.
        installCoordinator.shutdown(); stopNativeInstaller(); steamClientLifecycle.shutdown(); clientLauncher.shutdown()
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
        guard let resource = Bundle.main.url(forResource: "index", withExtension: "html") else { NSApp.terminate(nil); return }
        handler = ScriptHandler(resourceURL: resource)
        let content = WKUserContentController(); content.add(handler!, name: "metalmax")
        let config = WKWebViewConfiguration(); config.userContentController = content; config.websiteDataStore = WKWebsiteDataStore(forIdentifier: UUID(uuidString: "7D3A6B70-D366-4C67-9FE3-0A6FC95DF1AB")!)
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
        handler.refresh()
        let menu = NSMenu(); let appMenu = NSMenu()
        UpdaterController.shared.isBusy = { [weak self] in self?.handler?.updateBusy ?? true }
        UpdaterController.shared.updateGrantProvider = { [weak self] completion in
            guard let account=self?.handler?.accountService else{completion(.failure(AccountUpdateGrantError.unavailable));return}
            account.requestUpdateGrant(completion:completion)
        }
        UpdaterController.shared.onFailure = { [weak self] message in self?.handler?.result(false,message) }
        handler.accountService.onUpdateAuthorizationInvalidated = { UpdaterController.shared.clearUpdateAuthorization() }
        handler.accountService.onUpdateCredentialsReady = { UpdaterController.shared.credentialsDidBecomeReady() }
        UpdaterController.shared.start()
        if let target = UpdaterController.shared.updaterMenuTarget {
            let updateItem = appMenu.addItem(withTitle: "Rechercher les mises à jour…", action: #selector(UpdaterController.checkForUpdates(_:)), keyEquivalent: "")
            updateItem.target = target
        } else {
            let updateItem=appMenu.addItem(withTitle:"Télécharger la dernière version…",action:#selector(openAccountDownloads(_:)),keyEquivalent:"")
            updateItem.target=self
        }
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quitter Playmelt", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let item = NSMenuItem(); item.submenu = appMenu; menu.addItem(item); NSApp.mainMenu = menu
    }
    func applicationDidBecomeActive(_ notification: Notification) { handler?.accountService.refreshAfterReturning();handler?.refresh();UpdaterController.shared.resumeWhenIdle() }
    @objc private func openAccountDownloads(_ sender:Any?) {
        guard let url=handler?.accountService.config.accountPage(),var target=URLComponents(url:url,resolvingAgainstBaseURL:false) else{return}
        target.fragment="download-panel"
        if let url=target.url {NSWorkspace.shared.open(url)}
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
        group.enter(); handler.localGameImport.shutdown { group.leave() }
        group.enter(); handler.benchmarks.shutdown { group.leave() }
        group.enter(); handler.steamBootstrap.shutdown { group.leave() }
        group.enter(); handler.d3dMetalSteamBootstrap.shutdown { group.leave() }
        group.enter(); handler.d3dMetalRuntime.shutdown { group.leave() }
        group.enter(); handler.runtimeSetup.shutdown { group.leave() }
        group.enter(); handler.epicConnector.shutdown { group.leave() }
        group.enter(); handler.model.gogConnector.shutdown { group.leave() }
        group.enter(); handler.finishRendererImport { group.leave() }
        group.enter(); handler.libraryScanner.shutdown { group.leave() }
        group.enter(); handler.stopNativeInstaller { group.leave() }
        group.enter(); handler.steamReuseGroup.notify(queue:.main){group.leave()}
        group.enter(); handler.officialSteamStopGroup.notify(queue:.main){group.leave()}
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
