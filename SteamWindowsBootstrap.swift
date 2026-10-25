import Foundation
import Darwin

/// Downloads only Valve's official interactive installer. No silent install,
/// saved login, EULA acceptance, game download or game launch is performed here.
final class SteamWindowsBootstrap: NSObject, URLSessionDownloadDelegate {
    private let descriptorProvider: () -> PlaymeltRuntimeDescriptor?
    private let downloadsRoot: URL
    private var operationDescriptor: PlaymeltRuntimeDescriptor?
    private var attemptID: UUID?
    private var cancelGeneration = UUID()
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private let runner: OwnedProcessRunning
    private let sessionConfiguration: () -> URLSessionConfiguration
    private let installerQueue = DispatchQueue(label: "fr.playmelt.steam-installer", qos: .utility)
    private var installerOperation: SteamInstallerOperation?
    private var installerFile: URL?
    private var stopped = false
    private var closing = false
    private(set) var busy = false
    private var phase = "idle", message = ""
    private var received: Int64 = 0, expected: Int64 = 0
    private var lastProgressNotification: TimeInterval = 0
    var onChange: (() -> Void)?
    var onInstalled: (() -> Void)?
    convenience init(runtime: RuntimeSetup) {
        self.init(downloadsRoot: runtime.root.appendingPathComponent("downloads"), descriptor: { runtime.descriptor() })
    }
    init(downloadsRoot: URL, descriptor: @escaping () -> PlaymeltRuntimeDescriptor?, runner: OwnedProcessRunning = OwnedProcessRunner(),
         sessionConfiguration: @escaping () -> URLSessionConfiguration = { .ephemeral }) {
        self.downloadsRoot = downloadsRoot; self.descriptorProvider = descriptor; self.runner = runner; self.sessionConfiguration = sessionConfiguration
    }
    static func sameRuntime(_ first: PlaymeltRuntimeDescriptor, _ second: PlaymeltRuntimeDescriptor) -> Bool {
        first.engineID == second.engineID && first.wineURL == second.wineURL && first.wineserverURL == second.wineserverURL &&
        first.prefixURL == second.prefixURL && first.steamRoot == second.steamRoot && first.environment == second.environment
    }
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
        guard !busy && !closing else { return }
        cancelGeneration = UUID()
        guard let descriptor = descriptorProvider(), descriptor.readyEngine else { update("failed", "Préparez d’abord le moteur Windows sélectionné.", busy: false); return }
        if descriptor.steamInstalled { onInstalled?(); return }
        busy = true; stopped = false; received = 0; expected = 0; lastProgressNotification = 0
        operationDescriptor = descriptor
        attemptID = UUID()
        update("downloading", "Téléchargement de l’installateur officiel Steam…", busy: true)
        let config = sessionConfiguration()
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
            let downloads = downloadsRoot
            try RuntimeSetup.rejectSymlinkAncestors(downloads)
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            let target = downloads.appendingPathComponent("SteamSetup-\(UUID().uuidString).exe")
            installerFile = target
            try FileManager.default.copyItem(at: location, to: target)
            guard let descriptor = descriptorProvider(), let original = operationDescriptor, let attempt = attemptID,
                  descriptor.readyEngine, Self.sameRuntime(original, descriptor) else { throw RuntimeSetupError.failed("Le moteur Windows sélectionné a changé. Réessayez après actualisation.") }
            let retention = try SteamInstallerRetention(file:target,descriptor:original)
            let operation = SteamInstallerOperation(runner: runner); installerOperation = operation
            update("installer", "Terminez l’installation dans la fenêtre officielle Steam.", busy: true)
            installerQueue.async { [self] in
                let outcome: Result<OwnedProcessResult,Error>
                do {
                    let result = try operation.run(installer: target, descriptor: original, current: descriptorProvider,
                        onDetachedExit: { retention.observeExit($0) })
                    if result.handedOff { retention.handoff(pid:result.pid) }
                    outcome = .success(result)
                } catch { outcome = .failure(error) }
                let retained: Bool
                switch outcome {
                case .success(let result): retained = result.handedOff
                case .failure(let error): retained = error is SteamInstallerLifecycleError
                }
                if retained { retention.preserve() } else { retention.removeOwnedFiles() }
                DispatchQueue.main.async { [self] in
                    // Release the exact attempt's file ownership even after shutdown;
                    // A handed-off installer keeps a receipt for future cleanup
                    // only after file usage is independently proven absent.
                    if installerFile == target { installerFile = nil }
                    guard attemptID == attempt else { return }
                    installerOperation = nil
                    guard !stopped else { return }
                    if let current = descriptorProvider(), Self.sameRuntime(original, current), current.steamInstalled {
                        update("ready", "Steam Windows est installé. Connectez votre compte Steam.", busy: false); onInstalled?()
                    } else {
                        let text: String
                        switch outcome {
                        case .success: text = "Installation Steam non terminée. Vous pouvez relancer l’installateur."
                        case .failure(let error): text = error.localizedDescription
                        }
                        update("failed", text, busy: false)
                    }
                }
            }
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
    /// A temporary installer is cancelled and reaped before completion. Once Steam
    /// is present, ownership is handed to the user: no client/game group is killed.
    func shutdown(completion: @escaping () -> Void) {
        closing = true
        cancel(completion: completion)
    }
    /// Render protection uses reversible cancellation; the same bootstrap may be
    /// started again after this completion, unlike application shutdown.
    func cancel(completion: @escaping () -> Void = {}) {
        let cancellation = UUID()
        cancelGeneration = cancellation
        let wasBusy = busy
        stopped = true; attemptID = nil; operationDescriptor = nil
        task?.cancel(); session?.invalidateAndCancel(); task = nil; session = nil
        installerOperation?.cancel()
        let finish = { [self] in
            // An idle cancellation may finish after a fresh start. Its completion
            // still fires, but it no longer owns that new attempt's state/files.
            guard cancelGeneration == cancellation, stopped && attemptID == nil else { completion(); return }
            cancelGeneration = UUID()
            installerOperation = nil; removeInstallerFile()
            if wasBusy { update("cancelled", "Installation Steam annulée.", busy: false) }
            completion()
        }
        installerQueue.async { DispatchQueue.main.async(execute: finish) }
    }
}

/// Testable installer ownership boundary; the only actual installer invocation
/// comes from the validated download/attempt above. No account data is captured.
final class SteamInstallerOperation {
    private let runner: OwnedProcessRunning
    private let token = OwnedOperationToken()
    init(runner: OwnedProcessRunning = OwnedProcessRunner()) { self.runner = runner }
    func cancel() { token.cancel() }
    static func steamPresent(_ descriptor: PlaymeltRuntimeDescriptor) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: descriptor.steamRoot.appendingPathComponent("steam.exe")) else { return false }
        defer { try? handle.close() }; return (try? handle.read(upToCount: 2)) == Data([0x4d,0x5a])
    }
    private static func ownsPrefix(_ descriptor: PlaymeltRuntimeDescriptor) -> Bool {
        let marker = descriptor.prefixURL.deletingLastPathComponent().appendingPathComponent("prefix-owner.json")
        guard let metadata = try? FileManager.default.attributesOfItem(atPath: marker.path), metadata[.type] as? FileAttributeType == .typeRegular,
              let bytes = (metadata[.size] as? NSNumber)?.intValue, bytes > 0, bytes < 8192,
              let data = try? Data(contentsOf:marker), let owner = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
              owner["prefix"] as? String == descriptor.prefixURL.path, let engineID = owner["engineID"] as? String else { return false }
        return engineID == descriptor.engineID || (owner["owner"] as? String == "playmelt-d3dmetal" && descriptor.engineID.hasPrefix(engineID + "/d3dmetal/"))
    }
    func run(installer: URL, descriptor: PlaymeltRuntimeDescriptor, current: () -> PlaymeltRuntimeDescriptor?,
             onDetachedExit: @escaping (Int32) -> Void) throws -> OwnedProcessResult {
        guard !token.isCancelled else { throw OwnedProcessError.cancelled }
        guard descriptor.readyEngine, Self.ownsPrefix(descriptor), let fresh = current(), SteamWindowsBootstrap.sameRuntime(descriptor,fresh) else { throw RuntimeSetupError.failed("Le préfixe Steam sélectionné n’appartient pas à cette préparation Playmelt.") }
        try RuntimeSetup.rejectSymlinkAncestors(descriptor.prefixURL)
        if Self.steamPresent(descriptor) { return .init(output:Data(),exitCode:0,pid:0,handedOff:false) }
        let engine=descriptor.wineURL.deletingLastPathComponent().deletingLastPathComponent()
        let toolsEnvironment=["PATH":"/usr/bin:/bin:/usr/sbin:/sbin","LC_ALL":"C"]
        var scan=OwnedProcessRequest(executable:URL(fileURLWithPath:"/bin/ps"),arguments:["-axo","pid=,comm="],environment:toolsEnvironment)
        scan.timeout=5;scan.outputLimit=8*1024*1024
        let before=try runner.run(scan,cancelled:{self.token.isCancelled})
        guard before.exitCode==0, !String(decoding:before.output,as:UTF8.self).split(separator:"\n").contains(where:{$0.contains(engine.path+"/") || $0.contains(descriptor.prefixURL.path+"/")}) else { throw RuntimeSetupError.failed("Un programme utilise déjà Wine. Fermez-le avant d’installer ce client Steam.") }
        guard let validated=current(), SteamWindowsBootstrap.sameRuntime(descriptor,validated) else { throw RuntimeSetupError.failed("Le moteur Steam a changé pendant la préparation.") }
        if Self.steamPresent(descriptor) { return .init(output:Data(),exitCode:0,pid:0,handedOff:false) }
        var command=OwnedProcessRequest(executable:descriptor.wineURL,arguments:[installer.path],environment:descriptor.environment)
        command.directory=descriptor.prefixURL;command.timeout=1800;command.allowsHandoff=true;command.preserveGroupOnSuccess=true;command.idlePollInterval=0.25
        var lastCheck=0.0,handedOff=false,spawned=false
        command.onSpawn={_ in spawned=true}
        let deadline=ProcessInfo.processInfo.systemUptime+command.timeout
        let outcome: Result<OwnedProcessResult,Error>
        do {
            let result=try runner.run(command,cancelled:{self.token.isCancelled},handoff:{
                let now=ProcessInfo.processInfo.systemUptime
                if now-lastCheck>=0.25 || self.token.isCancelled || now>=deadline-1 {
                    lastCheck=now;handedOff=Self.steamPresent(descriptor)
                }
                return handedOff
            },onDetachedExit:onDetachedExit)
            outcome = .success(result)
        } catch { outcome = .failure(error) }
        // The binary may have appeared as the installer exited. Never stop the
        // prefix once a user client could be running, even if the hub is closing.
        if handedOff || Self.steamPresent(descriptor) {
            if case .success(let result)=outcome{
                if !result.handedOff { DispatchQueue.main.async { onDetachedExit(result.exitCode) } }
                return .init(output:result.output,exitCode:result.exitCode,pid:result.pid,handedOff:true)
            }
            throw SteamInstallerLifecycleError.ownershipTransferred
        }
        if !spawned { return try outcome.get() }
        var cleanupFailed=false
        for argument in ["-k","-w"] {
            var stop=OwnedProcessRequest(executable:descriptor.wineserverURL,arguments:[argument],environment:descriptor.environment)
            stop.timeout=10
            do { if try runner.run(stop,cancelled:{false}).exitCode != 0{cleanupFailed=true} } catch {cleanupFailed=true}
        }
        do {
            let remaining=try runner.run(scan,cancelled:{false})
            if remaining.exitCode != 0 || String(decoding:remaining.output,as:UTF8.self).split(separator:"\n").contains(where:{$0.contains(engine.path+"/") || $0.contains(descriptor.prefixURL.path+"/")}){cleanupFailed=true}
        } catch {cleanupFailed=true}
        if cleanupFailed {throw SteamInstallerLifecycleError.cleanupUnconfirmed}
        return try outcome.get()
    }
}

enum SteamInstallerLifecycleError: LocalizedError {
    case cleanupUnconfirmed, ownershipTransferred
    var errorDescription:String?{
        switch self {
        case .cleanupUnconfirmed:return "L’arrêt des processus de l’installateur n’a pas été confirmé. Ses fichiers sont conservés."
        case .ownershipTransferred:return "Steam est présent ; vérifiez sa fenêtre officielle."
        }
    }
}

/// Narrow retention record for an exact downloaded installer. A leader exit is
/// recorded, never promoted to proof that user-owned descendants released the
/// file. No cleanup scan, age-based deletion or process termination occurs here.
final class SteamInstallerRetention {
    private let lock=NSLock(),file:URL,receipt:URL
    private var record:[String:Any]
    init(file:URL,descriptor:PlaymeltRuntimeDescriptor)throws{
        self.file=file;receipt=file.appendingPathExtension("handoff.json")
        record=["schema":1,"owner":"playmelt-steam-installer","installer":file.path,
                "prefix":descriptor.prefixURL.path,"engineID":descriptor.engineID,
                "handedOff":false,"leaderExitObserved":false,"fileUsageEnded":false,
                "cleanupRequires":"exact-owner-record-and-independent-proof-of-no-file-usage"]
        try JSONSerialization.data(withJSONObject:record,options:[.sortedKeys,.prettyPrinted]).write(to:receipt,options:.withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:receipt.path)
    }
    func handoff(pid:pid_t){lock.lock();defer{lock.unlock()};record["handedOff"]=true;record["pid"]=pid;save()}
    func observeExit(_ code:Int32){lock.lock();defer{lock.unlock()};record["leaderExitObserved"]=true;record["exitCode"]=code;save()}
    func preserve(){lock.lock();defer{lock.unlock()};record["retainedForUsageCheck"]=true;save()}
    private func save(){
        try?JSONSerialization.data(withJSONObject:record,options:[.sortedKeys,.prettyPrinted]).write(to:receipt,options:.atomic)
        try?FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:receipt.path)
    }
    func removeOwnedFiles(){lock.lock();defer{lock.unlock()};try?FileManager.default.removeItem(at:file);try?FileManager.default.removeItem(at:receipt)}
}
