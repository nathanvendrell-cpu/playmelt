import AppKit
import WebKit
import Foundation
import Darwin

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
    private let gameSettingsStore = GameSettingsStore(root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Playmelt/GameSettings", isDirectory: true))
    private let gameSettingsQueue = DispatchQueue(label: "fr.playmelt.game-settings", qos: .utility)
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
    init(resourceURL: URL) {
        self.resourceURL = resourceURL; super.init()
        installCoordinator.onChange = { [weak self] in self?.notifyInstallJob() }
        installCoordinator.onCancel = { [weak self] in
            self?.stopNativeInstaller()
        }
        steamBootstrap.onChange = { [weak self] in self?.notifyRuntime() }
        steamBootstrap.onInstalled = { [weak self] in self?.refresh() }
        d3dMetalSteamBootstrap.onChange = { [weak self] in self?.notifyRuntime() }
        d3dMetalSteamBootstrap.onInstalled = { [weak self] in self?.refresh() }
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
        default: result(false, "Action non prise en charge.")
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
        directX12["busy"] = rendererImportBusy || d3dMetalIsBusy
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
    func sendState() {
        model.epicAvailability = epicConnector.availability()
        var state = model.state(); state["windowsRuntime"] = runtimePayload(); state["installJob"] = installCoordinator.snapshot ?? NSNull()
        state["renderProtectionEnabled"] = renderProtectionEnabled
        if let gameSettingsPayload { state["gameSettings"] = gameSettingsPayload }
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
    private func openEpicSignIn() {
        guard !closing else { return }
        epicConnector.requestLoginURL { [weak self] outcome in
            guard let self, !self.closing else { return }
            switch outcome {
            case .failure(let error): self.result(false, error.localizedDescription)
            case .success(let url):
                guard NSWorkspace.shared.open(url), let window = self.webView?.window else { self.result(false, "Impossible d’ouvrir la connexion Epic officielle."); return }
                let alert = NSAlert(); alert.messageText = "Connecter Epic Games"
                alert.informativeText = "Connectez-vous dans la page Epic officielle, puis collez le code authorizationCode ici. Connexion mémorisée sur ce Mac lorsque le Trousseau est disponible."
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
            let availability = epicConnector.availability()
            guard !closing, availability["accountId"] as? String == snapshot.accountId,
                  availability["authenticated"] as? Bool == true,
                  availability["sessionVerified"] as? Bool == true else {
                model.epicSnapshotFresh = false; sendState(); return
            }
            model.epicSnapshot = snapshot; model.epicSnapshotFresh = true; refresh()
            let storageIssue = availability["storageError"] as? String ?? ""
            result(true, "Bibliothèque Epic synchronisée : \(snapshot.games.count) jeux." + (storageIssue.isEmpty ? "" : " " + storageIssue))
        case .failure(let error): model.epicSnapshotFresh = false; sendState(); result(false, error.localizedDescription)
        }
    }
    func installAndPlay(_ game: Game, runtimeID: String?) {
        guard !closing, !renderProtectionEnabled else { result(false, "Rendus en cours : lancement suspendu."); return }
        guard !CommandLine.arguments.contains("--audit-read-only") else { result(false, "Mode de vérification : installation et lancement désactivés."); return }
        guard !installCoordinator.isActive, !runtimeIsBusy, !steamBootstrap.busy else { result(false, "Une opération est déjà en cours."); return }
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
                _ = try clientLauncher.launch(executable: URL(fileURLWithPath: "/bin/bash"),
                                              arguments: [script.path] + (game.appId == "2651280" ? [] : extraArguments),
                                              environment: ProcessInfo.processInfo.environment,
                                              directory: script.deletingLastPathComponent()) { code in
                    if code != 0 { self.result(false, "Le jeu s’est arrêté (code \(code)). Consultez le diagnostic du lancement.") }
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
            guard WindowsExecutionPolicy.permits(platform: game.platform) else { result(false, WindowsExecutionPolicy.message); return }
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
            alert.messageText = "Déplacer \(game.title) dans la Corbeille ?"
            alert.informativeText = "Cibles exactes :\n" + plan.items.map(\.path).joined(separator: "\n") + "\n\nAucune sauvegarde des parties n’est vérifiée. Ces éléments resteront récupérables dans la Corbeille tant qu’elle n’est pas vidée."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Annuler")
            alert.addButton(withTitle: "Déplacer dans la Corbeille")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
            guard !closing, !renderProtectionEnabled, !installCoordinator.isActive, clientLauncher.activeCount == 0,
                  try GameUninstallPlan.make(game: game, installRoots: roots, steamRoots: steamRoots) == plan else {
                result(false, "L’installation a changé. Aucun fichier n’a été déplacé."); return
            }
            for item in plan.items { try fm.trashItem(at: item, resultingItemURL: nil) }
            refresh { [weak self] in self?.result(true, "Les fichiers détectés de \(game.title) ont été déplacés dans la Corbeille.") }
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
