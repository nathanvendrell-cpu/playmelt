import AppKit
import WebKit
import Foundation

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

final class SteamAuthentication: NSObject, WKNavigationDelegate, WKUIDelegate {
    var window: NSWindow?
    var webView: WKWebView?
    let model: LibraryModel
    let result: (Bool, String) -> Void
    private var captureInFlight = false
    private var captureGeneration = UUID()
    init(model: LibraryModel, result: @escaping (Bool, String) -> Void) { self.model = model; self.result = result }
    static func allowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return ["steamcommunity.com", "steampowered.com", "steamstatic.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }
    func open() {
        if let window { window.makeKeyAndOrderFront(nil); return }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        // This web view has no privileged message handler or native bridge.
        let web = WKWebView(frame: .zero, configuration: config); web.navigationDelegate = self; web.uiDelegate = self
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Steam officiel — connexion et bibliothèque"; window.isReleasedWhenClosed = false
        let container = NSView(); let button = NSButton(title: "Lire la bibliothèque affichée", target: self, action: #selector(readLibrary))
        let note = NSTextField(labelWithString: "steamcommunity.com · session temporaire · aucun mot de passe transmis à Playmelt")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        for view in [web, button, note] { view.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(view) }
        NSLayoutConstraint.activate([button.topAnchor.constraint(equalTo: container.topAnchor, constant: 10), button.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14), note.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14), note.centerYAnchor.constraint(equalTo: button.centerYAnchor), note.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -12), web.topAnchor.constraint(equalTo: button.bottomAnchor, constant: 10), web.leadingAnchor.constraint(equalTo: container.leadingAnchor), web.trailingAnchor.constraint(equalTo: container.trailingAnchor), web.bottomAnchor.constraint(equalTo: container.bottomAnchor)])
        window.contentView = container; self.window = window; self.webView = web
        window.center(); window.makeKeyAndOrderFront(nil)
        web.load(URLRequest(url: URL(string: "https://steamcommunity.com/my/games/?tab=all")!))
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, Self.allowed(url) else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, Self.allowed(url) { webView.load(URLRequest(url: url)) }; return nil
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { captureGeneration = UUID(); captureInFlight = false }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { capture(manual: false) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { result(false, "Steam n’a pas chargé la bibliothèque. Réessayez dans la fenêtre officielle.") }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { result(false, "Connexion Steam indisponible. Vérifiez le réseau puis réessayez.") }
    @objc func readLibrary() { capture(manual: true) }
    func capture(manual: Bool) {
        guard let webView, let url = webView.url, Self.allowed(url), url.host == "steamcommunity.com", url.path.contains("/games") else {
            if manual { result(false, "Terminez la connexion Steam, puis ouvrez Tous les jeux et cliquez sur Lire la bibliothèque affichée.") }; return
        }
        guard !captureInFlight else { return }
        guard let scriptURL = Bundle.main.url(forResource: "SteamLibraryReader", withExtension: "js"),
              let script = try? String(contentsOf: scriptURL, encoding: .utf8) else {
            result(false, "Le lecteur de bibliothèque Steam est absent. Réinstallez Playmelt."); return
        }
        let generation = UUID(); captureGeneration = generation; captureInFlight = true
        let selectedAccount = model.selectedAccountID
        webView.callAsyncJavaScript(script, arguments: ["expectedAccountId": selectedAccount], in: nil, in: .page) { [weak self] evaluation in
            guard let self, self.captureGeneration == generation else { return }
            self.captureInFlight = false
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
            guard self.model.acceptAuthenticatedLibrary(accountID: id, list: rows, source: "steamcommunity-profile-gameslist") else {
                self.result(false, "Le compte Steam connecté ne correspond pas au compte sélectionné, ou la liste reçue est invalide. Aucun compte n’a été remplacé."); return
            }
            self.result(true, "Bibliothèque Steam synchronisée : \(rows.count) jeux, identité du compte vérifiée.")
            self.window?.orderOut(nil)
        }
    }
}

final class ScriptHandler: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?
    let model = LibraryModel()
    let epicConnector = EpicConnector()
    let runtimeSetup = RuntimeSetup()
    lazy var steamBootstrap = SteamWindowsBootstrap(runtime: runtimeSetup)
    let installCoordinator = SteamInstallCoordinator()
    let requestGate = SteamRequestGate()
    var clientLaunchers: [UUID: Process] = [:]
    var authentication: SteamAuthentication?
    var loading = false
    private var closing = false
    let resourceURL: URL
    init(resourceURL: URL) {
        self.resourceURL = resourceURL; super.init()
        installCoordinator.onChange = { [weak self] in self?.notifyInstallJob() }
        steamBootstrap.onChange = { [weak self] in self?.notifyRuntime() }
        steamBootstrap.onInstalled = { [weak self] in self?.refresh() }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !closing, message.frameInfo.isMainFrame, message.frameInfo.request.url?.standardizedFileURL == resourceURL.standardizedFileURL,
              webView?.url?.standardizedFileURL == resourceURL.standardizedFileURL,
              let dict = message.body as? [String: Any], let action = dict["action"] as? String else { return }
        print("Playmelt action: \(action)"); fflush(stdout)
        guard !loading || action == "refresh" else { result(false, "Lecture locale en cours. Réessayez dans un instant."); return }
        switch action {
        case "refresh": refresh()
        case "selectAccount":
            guard let id = dict["accountId"] as? String, model.accounts.contains(where: { $0.id == id }) else { result(false, "Compte non reconnu."); return }
            installCoordinator.cancel(message: "Compte changé : lancement automatique annulé.")
            model.selectedAccountID = id; model.preferences.set(id, forKey: "selectedSteamAccount"); model.libraryStatus = "local"; refresh()
        case "setupWindowsRuntime":
            guard !CommandLine.arguments.contains("--audit-read-only"), !steamBootstrap.busy, !installCoordinator.isActive else { result(false, "Préparation indisponible pendant cette opération."); return }
            runtimeSetup.start(progress: { [weak self] _ in self?.notifyRuntime() }) { [weak self] outcome in
                self?.refresh()
                if case .failure(let error) = outcome { self?.result(false, error.localizedDescription) }
            }
        case "cancelWindowsRuntime": runtimeSetup.cancel()
        case "installSteamWindows":
            guard !CommandLine.arguments.contains("--audit-read-only"), !runtimeIsBusy, !installCoordinator.isActive else { result(false, "Installation Steam indisponible pendant cette opération."); return }
            steamBootstrap.start()
        case "openWindowsSteam":
            guard !CommandLine.arguments.contains("--audit-read-only"), !runtimeIsBusy, !steamBootstrap.busy else { result(false, "Steam Windows est indisponible pendant cette opération."); return }
            refresh()
            guard let runtime = model.runtimes.first(where: { $0.id == "playmelt-windows" && $0.available }) else { result(false, "Installez d’abord Steam Windows dans Playmelt."); return }
            runWindowsClient(runtime, arguments: ["steam://open/games"], onFailure: { [weak self] message in self?.result(false, message) }) { [weak self] ok, message in self?.result(ok, ok ? "Ouverture de Steam Windows…" : message) }
        case "cancelInstallAndPlay": installCoordinator.cancel()
        case "installAndPlay":
            guard let id = dict["gameId"] as? String, let game = model.games.first(where: { $0.id == id }) else { result(false, "Jeu introuvable. Actualisez la bibliothèque."); return }
            installAndPlay(game, runtimeID: dict["runtimeId"] as? String)
        case "syncLibrary", "openSteamLogin":
            guard !model.selectedAccountID.isEmpty else { result(false, "Ouvrez Steam, connectez votre compte puis actualisez Playmelt."); return }
            if authentication == nil { authentication = SteamAuthentication(model: model) { [weak self] ok, message in self?.sendState(); self?.result(ok, message) } }
            model.beginSteamLibrarySync(); sendState()
            authentication?.open(); result(true, "Fenêtre Steam officielle ouverte. Connectez-vous pour vérifier la bibliothèque complète.")
        case "openSteam": openSteam()
        case "connectEpic": connectEpic()
        case "syncEpic":
            guard epicConnector.availability()["authenticated"] as? Bool == true else { connectEpic(); return }
            model.epicSnapshotFresh = false
            epicConnector.sync { [weak self] outcome in self?.receiveEpic(outcome) }
        case "openEpic":
            let app = URL(fileURLWithPath: "/Applications/Epic Games Launcher.app")
            if FileManager.default.fileExists(atPath: app.path) { NSWorkspace.shared.openApplication(at: app, configuration: .init()) { [weak self] _, error in DispatchQueue.main.async { self?.result(error == nil, error == nil ? "Epic Games Launcher ouvert. La bibliothèque du compte reste gérée par Epic." : "Impossible d’ouvrir Epic Games Launcher.") } } }
            else { result(false, "Epic Games Launcher n’est pas installé.") }
        case "launchGame", "installGame", "openGameFolder":
            guard let id = dict["gameId"] as? String, let game = model.games.first(where: { $0.id == id }) else { result(false, "Jeu non reconnu. Actualisez la bibliothèque."); return }
            if action == "openGameFolder" {
                guard let path = game.path, FileManager.default.fileExists(atPath: path.path) else { result(false, "Dossier installé introuvable."); return }
                NSWorkspace.shared.activateFileViewerSelecting([path]); result(true, "Dossier du jeu affiché."); return
            }
            route(game, installing: action == "installGame", requestedRuntime: dict["runtimeId"] as? String)
        default: result(false, "Action non prise en charge.")
        }
    }
    func refresh() {
        guard !closing, !loading else { return }; loading = true
        // The bounded local scan takes about 150ms on the audited machine.
        // Keep all model access on the main queue to avoid racing an auth return.
        model.windowsDescriptor = runtimeSetup.descriptor()
        model.refresh(); loading = false; sendState()
    }
    var runtimeIsBusy: Bool { ["downloading", "verifying", "extracting", "initializing"].contains(runtimeSetup.snapshot()["status"] as? String ?? "") }
    func runtimePayload() -> [String: Any] {
        var state = runtimeSetup.snapshot(); state.merge(steamBootstrap.snapshot) { _, latest in latest }; return state
    }
    func sendState() {
        model.epicAvailability = epicConnector.availability()
        var state = model.state(); state["windowsRuntime"] = runtimePayload(); state["installJob"] = installCoordinator.snapshot ?? NSNull()
        notify("onNativeState", state)
    }
    func notifyRuntime() { notify("onNativeRuntime", runtimePayload()) }
    func notifyInstallJob() {
        if let job = installCoordinator.snapshot { notify("onNativeInstallJob", job) }
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
    func connectEpic() {
        guard epicConnector.availability()["available"] as? Bool == true else { result(false, "Le connecteur Epic optionnel n’est pas installé."); sendState(); return }
        model.epicSnapshotFresh = false
        epicConnector.requestLoginURL { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .failure(let error): self.result(false, error.localizedDescription)
            case .success(let url):
                guard NSWorkspace.shared.open(url), let window = self.webView?.window else { self.result(false, "Impossible d’ouvrir la connexion Epic officielle."); return }
                let alert = NSAlert(); alert.messageText = "Connecter Epic Games"
                alert.informativeText = "Connectez-vous dans la page Epic officielle, puis collez le code authorizationCode ici. La session reste en mémoire jusqu’à la fermeture de Playmelt."
                alert.addButton(withTitle: "Connecter"); alert.addButton(withTitle: "Annuler")
                let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 430, height: 28)); field.placeholderString = "Code de connexion Epic"
                alert.accessoryView = field
                alert.beginSheetModal(for: window) { [weak self] response in
                    guard let self else { return }
                    let code = field.stringValue; field.stringValue = ""
                    guard response == .alertFirstButtonReturn else { return }
                    guard !code.isEmpty, code.count <= 4096 else { self.result(false, "Code Epic vide ou invalide."); return }
                    self.epicConnector.authenticate(code: code) { [weak self] outcome in self?.receiveEpic(outcome) }
                }
            }
        }
    }
    func receiveEpic(_ outcome: Result<EpicSnapshot, Error>) {
        switch outcome {
        case .success(let snapshot):
            model.epicSnapshot = snapshot; model.epicSnapshotFresh = true; refresh(); result(true, "Bibliothèque Epic synchronisée : \(snapshot.games.count) jeux.")
        case .failure(let error): model.epicSnapshotFresh = false; sendState(); result(false, error.localizedDescription)
        }
    }
    func installAndPlay(_ game: Game, runtimeID: String?) {
        guard !closing else { return }
        guard !CommandLine.arguments.contains("--audit-read-only") else { result(false, "Mode de vérification : installation et lancement désactivés."); return }
        guard !installCoordinator.isActive, !runtimeIsBusy, !steamBootstrap.busy else { result(false, "Une opération est déjà en cours."); return }
        guard game.store == "steam", !model.selectedAccountID.isEmpty,
              let runtime = validatedSteamRuntime(game, installing: true, requestedRuntime: runtimeID) else { return }
        if let reason = SteamGameLaunchProfile.blockReason(appID: game.appId, platform: runtime.platform) { result(false, reason); return }
        let account = model.selectedAccountID
        guard let id = installCoordinator.begin(gameID: game.id, appID: game.appId, title: game.title, runtime: runtime, accountID: account, onReady: { [weak self] id in
            guard let self, !self.closing else { return }
            guard self.model.selectedAccountID == account else { self.installCoordinator.cancel(); return }
            self.refresh()
            guard let installed = self.model.games.first(where: { $0.appId == game.appId && $0.runtimeId == runtime.id && $0.installed && $0.complete }),
                  let currentRuntime = self.validatedSteamRuntime(installed, installing: false, requestedRuntime: runtime.id) else {
                self.installCoordinator.didRequestLaunch(id: id, success: false, message: "Installation à vérifier dans Steam."); return
            }
            self.dispatchSteam(installed, runtime: currentRuntime, installing: false, onFailure: { [weak self] message in self?.installCoordinator.launchFailed(id: id, message: message) }) { [weak self] ok, message in
                self?.installCoordinator.didRequestLaunch(id: id, success: ok, message: message)
            }
        }) else { result(false, "Un suivi d’installation est déjà actif."); return }
        dispatchSteam(game, runtime: runtime, installing: true, onFailure: { [weak self] message in self?.installCoordinator.requestFailed(id: id, message: message) }) { [weak self] ok, message in
            if !ok { self?.installCoordinator.requestFailed(id: id, message: message) }
        }
    }
    func validatedSteamRuntime(_ game: Game, installing: Bool, requestedRuntime: String?) -> Runtime? {
        guard LibraryModel.validAppID(game.appId), let runtime = model.runtimes.first(where: { $0.id == (installing ? requestedRuntime ?? game.runtimeId : game.runtimeId) && $0.available }) else { result(false, "Aucun client Steam utilisable pour cette route."); return nil }
        if !installing, let reason = SteamGameLaunchProfile.blockReason(appID: game.appId, platform: runtime.platform) { result(false, reason); return nil }
        if runtime.platform == "windows" && (runtimeIsBusy || steamBootstrap.busy) { result(false, "La préparation Windows est encore en cours."); return nil }
        if installing {
            guard !game.complete, let info = model.metadata[game.appId], info.platforms.contains(runtime.platform == "mac" ? "macos" : "windows") else { result(false, "Cette édition ne peut pas être installée avec le client choisi."); return nil }
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
            let args = installing ? [uri] : Self.windowsLaunchArguments(appID: game.appId) ?? []
            runWindowsClient(runtime, arguments: args, onFailure: onFailure) { ok, error in finish(ok, ok ? message : error) }
        } else { finish(false, "Client Steam indisponible.") }
    }
    func runWindowsClient(_ runtime: Runtime, arguments: [String], onFailure: @escaping (String) -> Void,
                          completion: @escaping (Bool, String) -> Void) {
        let key = "windows-client:" + arguments.joined(separator: "\u{1f}")
        guard !closing, let token = requestGate.acquire(key) else { completion(false, "Demande déjà envoyée à Steam Windows."); return }
        defer { requestGate.finish(key, token: token) }
        let descriptor = runtimeSetup.descriptor()
        guard runtime.verifiedIndependentEngine, descriptor.readyEngine, descriptor.steamInstalled,
              runtime.prefixURL == descriptor.prefixURL, runtime.wineURL == descriptor.wineURL else { completion(false, "Le moteur Windows ou Steam Windows n’est pas prêt."); return }
        let process = Process(); let id = UUID(); process.executableURL = descriptor.wineURL
        process.arguments = [descriptor.steamRoot.appendingPathComponent("steam.exe").path] + arguments
        process.environment = descriptor.environment; process.currentDirectoryURL = descriptor.prefixURL
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] child in DispatchQueue.main.async {
            self?.clientLaunchers[id] = nil
            if child.terminationStatus != 0 { onFailure("Steam Windows s’est arrêté avec une erreur.") }
        } }
        do { try process.run(); clientLaunchers[id] = process; completion(true, "Ouverture de Steam Windows…") }
        catch { completion(false, "Impossible d’ouvrir Steam Windows.") }
    }
    func route(_ game: Game, installing: Bool, requestedRuntime: String?) {
        guard !closing else { return }
        guard !CommandLine.arguments.contains("--audit-read-only") else { result(false, "Mode de vérification : installations et lancements désactivés."); return }
        guard !installCoordinator.isActive else { result(false, "Un suivi d’installation est déjà en cours. Arrêtez le suivi avant une autre demande."); return }
        if game.store == "epic" {
            guard !installing, game.complete, !game.epicLaunchID.isEmpty, let encoded = game.epicLaunchID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), let url = URL(string: "com.epicgames.launcher://apps/\(encoded)?action=launch&silent=true") else { result(false, "Route Epic indisponible."); return }
            let key = "epic:\(game.appId)"
            guard let token = requestGate.acquire(key) else { result(false, "Demande déjà envoyée à Epic."); return }
            NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/Applications/Epic Games Launcher.app"), configuration: .init()) { [weak self] _, error in DispatchQueue.main.async {
                self?.requestGate.finish(key, token: token)
                self?.result(error == nil, error == nil ? "Ouverture de \(game.title)…" : "Epic n’a pas accepté la demande.")
            } }; return
        }
        guard let runtime = validatedSteamRuntime(game, installing: installing, requestedRuntime: requestedRuntime) else { return }
        dispatchSteam(game, runtime: runtime, installing: installing, onFailure: { [weak self] message in self?.result(false, message) }) { [weak self] ok, message in self?.result(ok, message) }
    }
    func beginShutdown() {
        closing = true; requestGate.shutdown(); installCoordinator.shutdown(); epicConnector.shutdown()
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
        let config = WKWebViewConfiguration(); config.userContentController = content; config.websiteDataStore = .nonPersistent()
        let artwork = SteamArtworkHandler(); artwork.handler = handler; config.setURLSchemeHandler(artwork, forURLScheme: "metalmaxart")
        webView = WKWebView(frame: .zero, configuration: config); webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground"); handler.webView = webView
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: min(1380, visible.width - 60), height: min(900, visible.height - 60)), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = Bundle.main.bundleIdentifier?.hasSuffix(".preview") == true ? "MetalMax Preview" : "Playmelt"
        window.minSize = NSSize(width: 820, height: 600); window.titlebarAppearsTransparent = true; window.backgroundColor = .clear; window.isOpaque = false
        window.appearance = NSAppearance(named: .aqua)
        let backdrop = NSVisualEffectView(); backdrop.material = .underWindowBackground; backdrop.blendingMode = .behindWindow; backdrop.state = .followsWindowActiveState
        backdrop.addSubview(webView); webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([webView.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor), webView.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor), webView.topAnchor.constraint(equalTo: backdrop.topAnchor), webView.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor)])
        window.contentView = backdrop; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        webView.loadFileURL(resource, allowingReadAccessTo: resource.deletingLastPathComponent())
        let menu = NSMenu(); let appMenu = NSMenu(); appMenu.addItem(withTitle: "Quitter Playmelt", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let item = NSMenuItem(); item.submenu = appMenu; menu.addItem(item); NSApp.mainMenu = menu
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { handler.refresh() }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.standardizedFileURL == handler.resourceURL.standardizedFileURL ? .allow : .cancel)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if shuttingDown { return .terminateLater }; shuttingDown = true
        guard handler != nil else { return .terminateNow }
        handler?.beginShutdown()
        handler?.steamBootstrap.shutdown { [weak self] in
            self?.handler?.runtimeSetup.shutdown { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
}
if CommandLine.arguments.contains("--self-test") {
    runSelfTests()
} else if CommandLine.arguments.contains("--diagnose-json") {
    let model = LibraryModel(); let runtime = RuntimeSetup(); model.windowsDescriptor = runtime.descriptor(); model.refresh(); model.epicAvailability = EpicConnector().availability()
    var state = model.state(); state["windowsRuntime"] = runtime.snapshot(); state["installJob"] = NSNull()
    if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) { FileHandle.standardOutput.write(data); print("") }
} else {
    let app = NSApplication.shared; app.setActivationPolicy(.regular)
    let delegate = AppDelegate(); app.delegate = delegate; app.run()
}
