import Foundation
import Darwin

/// Downloads only Valve's official interactive installer. No silent install,
/// saved login, EULA acceptance, game download or game launch is performed here.
final class SteamWindowsBootstrap: NSObject, URLSessionDownloadDelegate {
    private let runtime: RuntimeSetup
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var installer: Process?
    private var installerFile: URL?
    private var stopped = false
    private(set) var busy = false
    private var phase = "idle", message = ""
    private var received: Int64 = 0, expected: Int64 = 0
    private var lastProgressNotification: TimeInterval = 0
    var onChange: (() -> Void)?
    var onInstalled: (() -> Void)?
    init(runtime: RuntimeSetup) { self.runtime = runtime }
    var snapshot: [String: Any] {
        ["steamBusy": busy, "steamPhase": phase, "steamMessage": message,
         "steamBytesDownloaded": received, "steamBytesTotal": expected]
    }
    static func allowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.port == nil || url.port == 443 else { return false }
        return ["cdn.akamai.steamstatic.com", "cdn.cloudflare.steamstatic.com", "shared.fastly.steamstatic.com"].contains(url.host ?? "")
            && url.path == "/client/installer/SteamSetup.exe"
    }
    func start() {
        guard !busy else { return }
        let descriptor = runtime.descriptor()
        guard descriptor.readyEngine else { update("failed", "Préparez d’abord le moteur Windows.", busy: false); return }
        if descriptor.steamInstalled { onInstalled?(); return }
        busy = true; stopped = false; received = 0; expected = 0; lastProgressNotification = 0
        update("downloading", "Téléchargement de l’installateur officiel Steam…", busy: true)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 300
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        task = session?.downloadTask(with: URL(string: "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe")!)
        task?.resume()
    }
    private func update(_ phase: String, _ message: String, busy: Bool) { self.phase = phase; self.message = message; self.busy = busy; onChange?() }
    private func accepts(_ session: URLSession, _ task: URLSessionTask) -> Bool {
        !stopped && self.session === session && self.task === task
    }
    static func downloadErrorMessage(_ error: Error) -> String {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError {
            return "Espace disque insuffisant pour l’installateur Steam."
        }
        if error.domain == NSURLErrorDomain && [NSURLErrorCannotWriteToFile, NSURLErrorCannotCreateFile, NSURLErrorCannotMoveFile].contains(error.code) {
            return "Impossible d’écrire l’installateur Steam. Vérifiez l’espace disque et les droits du dossier Playmelt."
        }
        if error.domain == NSCocoaErrorDomain {
            return "Impossible de préparer l’installateur Steam. Vérifiez l’espace disque et les droits du dossier Playmelt."
        }
        return error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled ? "Téléchargement Steam annulé." : "Le téléchargement Steam a échoué. Vérifiez le réseau."
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(accepts(session, task) && request.url.map(Self.allowed) == true ? request : nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard accepts(session, downloadTask), busy, phase == "downloading" else { return }
        received = totalBytesWritten; expected = max(0, totalBytesExpectedToWrite)
        if totalBytesWritten > 64_000_000 || totalBytesExpectedToWrite > 64_000_000 { task?.cancel(); update("failed", "Taille inattendue de l’installateur Steam.", busy: false); return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastProgressNotification >= 0.25 {
            lastProgressNotification = now; onChange?()
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard accepts(session, downloadTask), busy, phase == "downloading" else { return }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200,
                  let url = response.url, Self.allowed(url),
                  let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 1000, size < 64_000_000 else { throw RuntimeSetupError.failed("Le téléchargement Steam n’a pas fourni l’installateur attendu.") }
            let handle = try FileHandle(forReadingFrom: location); let header = try handle.read(upToCount: 2); try handle.close()
            guard header == Data([0x4d, 0x5a]) else { throw RuntimeSetupError.failed("Le fichier reçu n’est pas un programme d’installation Windows.") }
            let downloads = runtime.root.appendingPathComponent("downloads")
            try RuntimeSetup.rejectSymlinkAncestors(downloads)
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            let target = downloads.appendingPathComponent("SteamSetup-\(UUID().uuidString).exe")
            installerFile = target
            try FileManager.default.copyItem(at: location, to: target)
            let descriptor = runtime.descriptor()
            guard descriptor.readyEngine else { throw RuntimeSetupError.failed("Le moteur Windows n’est plus disponible.") }
            let process = Process(); process.executableURL = descriptor.wineURL; process.arguments = [target.path]
            process.environment = descriptor.environment; process.currentDirectoryURL = descriptor.prefixURL
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] child in DispatchQueue.main.async {
                guard let self else { return }; self.installer = nil; self.removeInstallerFile()
                if self.stopped { return }
                if self.runtime.descriptor().steamInstalled {
                    self.update("ready", "Steam Windows est installé. Connectez votre compte Steam.", busy: false); self.onInstalled?()
                } else { self.update("failed", child.terminationStatus == 0 ? "Installation Steam non terminée. Vous pouvez relancer l’installateur." : "L’installateur Steam s’est arrêté. Réessayez après vérification.", busy: false) }
            } }
            try process.run(); installer = process
            update("installer", "Terminez l’installation et la connexion dans la fenêtre officielle Steam.", busy: true)
        } catch {
            removeInstallerFile()
            let failure = error as NSError
            update("failed", failure.domain == NSCocoaErrorDomain ? Self.downloadErrorMessage(error) : error.localizedDescription, busy: false)
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // An old cancelled attempt may finish after the user has already retried.
        // Always release its session, but never touch the replacement attempt.
        session.finishTasksAndInvalidate()
        guard accepts(session, task) else { return }
        self.task = nil; self.session = nil
        if let error, phase == "downloading" { update("failed", Self.downloadErrorMessage(error), busy: false) }
    }
    private func removeInstallerFile() {
        if let file = installerFile { try? FileManager.default.removeItem(at: file); installerFile = nil }
    }
    /// Stops only this exact installer process. Never kills Steam or a wineserver.
    func shutdown(completion: @escaping () -> Void) {
        stopped = true; task?.cancel(); session?.invalidateAndCancel(); task = nil; session = nil
        guard let process = installer, process.isRunning else { removeInstallerFile(); completion(); return }
        process.terminate()
        DispatchQueue.global(qos: .utility).async {
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            DispatchQueue.main.async { self.removeInstallerFile(); completion() }
        }
    }
}
