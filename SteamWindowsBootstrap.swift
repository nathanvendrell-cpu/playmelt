import Foundation
import CryptoKit
import Darwin
import CoreFoundation

/// Prepares Valve's official bootstrap package once per engine prefix. Steam
/// retains its own updates, authentication and EULA; no game is launched here.
final class SteamWindowsBootstrap: NSObject, URLSessionDownloadDelegate {
    private let descriptorProvider: () -> PlaymeltRuntimeDescriptor?
    private let downloadsRoot: URL
    private var operationDescriptor: PlaymeltRuntimeDescriptor?
    private var attemptID: UUID?
    private(set) var requestOwnerID:UUID?
    private var invalidationWaiters:[ObjectIdentifier:[()->Void]]=[:]
    private var cancelGeneration = UUID()
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private let runner: OwnedProcessRunning
    private let sessionConfiguration: () -> URLSessionConfiguration
    private let packages: SteamBootstrapPackageStore
    private var package: SteamBootstrapPackage?
    private var preparationToken = OwnedOperationToken()
    private var preparationLease: SteamBootstrapLease?
    private let installerQueue = DispatchQueue(label: "fr.playmelt.steam-installer", qos: .utility)
    private var installerOperation: SteamInstallerOperation?
    private var installerFile: URL?
    private var setupJournal: SteamInstallerJournal?
    private var stopped = false
    private var closing = false
    private(set) var busy = false
    private var phase = "idle", message = ""
    private var received: Int64 = 0, expected: Int64 = 0
    private var lastProgressNotification: TimeInterval = 0
    var onChange: (() -> Void)?
    var onInstalled: (() -> Void)?
    convenience init(runtime: RuntimeSetup) {
        self.init(downloadsRoot: runtime.root.appendingPathComponent("downloads"), cacheRoot: runtime.root.appendingPathComponent("downloads/SteamBootstrap"), descriptor: { runtime.descriptor() })
    }
    init(downloadsRoot: URL, cacheRoot: URL? = nil, descriptor: @escaping () -> PlaymeltRuntimeDescriptor?, runner: OwnedProcessRunning = OwnedProcessRunner(),
         sessionConfiguration: @escaping () -> URLSessionConfiguration = { .ephemeral }) {
        self.downloadsRoot = downloadsRoot; self.descriptorProvider = descriptor; self.runner = runner; self.sessionConfiguration = sessionConfiguration
        self.packages = SteamBootstrapPackageStore(root: cacheRoot ?? downloadsRoot.appendingPathComponent("SteamBootstrap"))
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
        guard ["cdn.steamstatic.com", "cdn.akamai.steamstatic.com", "cdn.cloudflare.steamstatic.com", "cdn.fastly.steamstatic.com", "shared.fastly.steamstatic.com"].contains(url.host ?? "") else { return false }
        return url.path == "/client/steam_client_win32" || url.path.range(of: "^/client/steam_win32\\.zip\\.[0-9a-f]{40}$", options: .regularExpression) != nil
    }
    func start(ownerID:UUID?=nil) {
        guard !busy && !closing else { return }
        cancelGeneration = UUID()
        requestOwnerID=ownerID
        setupJournal = nil
        guard let descriptor = descriptorProvider() else { update("failed", "Préparez d’abord le moteur Windows sélectionné.", busy: false); return }
        // A fresh on-disk Windows client wins over any previous setup outcome or
        // stale descriptor flag. This never reads/copies a Steam account/session.
        if SteamInstallerOperation.steamPresent(descriptor) { update("ready","Steam Windows est installé. Connectez votre compte Steam.",busy:false);onInstalled?(); return }
        guard descriptor.readyEngine else { update("failed", "Préparez d’abord le moteur Windows sélectionné.", busy: false); return }
        do {
            let logs = downloadsRoot.deletingLastPathComponent().appendingPathComponent("logs/SteamSetup")
            preparationLease = try SteamBootstrapLease(url: logs.appendingPathComponent("operation.lock"), runtime: descriptor)
            setupJournal = try SteamInstallerJournal(url: logs.appendingPathComponent("last-attempt.json"),
                descriptor: descriptor, automatic: ownerID != nil, method: SteamBootstrapPackage.method, intentID: ownerID, lease: preparationLease)
        } catch { update("failed", error.localizedDescription, busy: false); return }
        busy = true; stopped = false; received = 0; expected = 0; lastProgressNotification = 0
        operationDescriptor = descriptor
        attemptID = UUID()
        preparationToken = OwnedOperationToken(); package = nil
        update("downloading", "Vérification du paquet officiel du client Steam…", busy: true)
        guard !stopped, !closing, busy, attemptID != nil else { return }
        var recovery: SteamBootstrapPackage?
        do {
            if let cached = try packages.cached() {
                package = cached; setupJournal?.record("bootstrap-cache-reused")
                prepare(cached, descriptor: descriptor)
                return
            }
        } catch {
            do {
                guard let repairable = try packages.recoveryPackage() else { throw error }
                recovery = repairable; package = repairable
                setupJournal?.record("bootstrap-cache-repair")
            } catch { setupJournal?.record("stopped", fields:["errorType":String(describing:type(of:error))]); update("failed",error.localizedDescription,busy:false); return }
        }
        let config = sessionConfiguration()
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 300
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        download(recovery?.url ?? SteamBootstrapPackage.manifestURL)
    }
    private func download(_ url: URL) {
        setupJournal?.record("download-started")
        received = 0; expected = 0
        task = session?.downloadTask(with: url); task?.resume()
    }
    private func update(_ phase: String, _ message: String, busy: Bool) {
        self.phase = phase; self.message = message; self.busy = busy
        if !busy { preparationLease?.release(); preparationLease = nil }
        onChange?()
    }
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
        if totalBytesWritten > (package == nil ? 128 * 1024 : SteamBootstrapPackage.maximumArchive) || totalBytesExpectedToWrite > (package == nil ? 128 * 1024 : SteamBootstrapPackage.maximumArchive) { setupJournal?.record("download-failed", fields:["errorType":"unexpected_size"]); task?.cancel(); update("failed", "Taille inattendue de l’installateur Steam.", busy: false); return }
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
                  let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0,
                  size <= (package == nil ? 128 * 1024 : SteamBootstrapPackage.maximumArchive),
                  let original = operationDescriptor, let current = descriptorProvider(), Self.sameRuntime(original, current) else {
                throw SteamBootstrapPackageError.invalidArchive
            }
            if let package {
                guard url.lastPathComponent == package.filename else { throw SteamBootstrapPackageError.invalidArchive }
                update("verifying", "Vérification de l’intégrité du bootstrap officiel Steam…", busy: true)
                guard !stopped, !closing, busy else { return }
                try packages.store(package, downloaded: location)
                setupJournal?.record("bootstrap-verified")
                try setupJournal?.prepareInstaller(packages.archiveURL(package))
                prepare(package, descriptor: original)
            } else {
                guard url.path == SteamBootstrapPackage.manifestURL.path else { throw SteamBootstrapPackageError.invalidManifest }
                let package = try SteamBootstrapPackage(manifest: Data(contentsOf: location))
                self.package = package
                update("downloading", "Téléchargement du bootstrap officiel Steam…", busy: true)
                guard !stopped, !closing, busy else { return }
                download(package.url)
            }
        } catch {
            setupJournal?.record("stopped", fields:["errorType":String(describing:type(of:error))])
            update("failed", error.localizedDescription, busy: false)
        }
    }
    private func prepare(_ package: SteamBootstrapPackage, descriptor: PlaymeltRuntimeDescriptor) {
        guard let attempt = attemptID, let journal = setupJournal else { return }
        let token = preparationToken
        update("preparing", "Préparation commune du client Steam pour ce moteur Windows…", busy: true)
        guard !stopped, !closing, busy, !token.isCancelled else { return }
        installerQueue.async { [self] in
            let outcome: Result<Void,Error>
            do {
                try packages.prepare(package, descriptor: descriptor, current: descriptorProvider,
                                     runner: runner, cancelled: { token.isCancelled })
                outcome = .success(())
                journal.record("client-prepared")
            } catch { outcome = .failure(error); journal.record("stopped", fields:["errorType":String(describing:type(of:error))]) }
            DispatchQueue.main.async { [self] in
                guard attemptID == attempt, !stopped, !token.isCancelled else { return }
                switch outcome {
                case .success:
                    guard let current = descriptorProvider(), Self.sameRuntime(descriptor,current), SteamInstallerOperation.steamPresent(current) else {
                        update("failed", "Le moteur Steam sélectionné a changé pendant la préparation.", busy:false); return
                    }
                    journal.record("client-observed")
                    update("ready", "Client Steam Windows préparé. Une connexion officielle peut être requise.", busy:false); onInstalled?()
                case .failure(let error): update("failed", error.localizedDescription, busy:false)
                }
            }
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Manifest completion must not invalidate the package task created by its
        // download callback. Only this attempt's current task owns the session.
        guard self.session === session, self.task === task else { return }
        session.finishTasksAndInvalidate()
        self.task = nil; self.session = nil
        if let error, !stopped, phase == "downloading" {
            setupJournal?.record("download-failed", fields:["errorCode":(error as NSError).code])
            update("failed", Self.downloadErrorMessage(error), busy:false)
        }
    }
    func urlSession(_ session:URLSession,didBecomeInvalidWithError error:Error?) {
        if self.session === session {self.session=nil;self.task=nil}
        let callbacks=invalidationWaiters.removeValue(forKey:ObjectIdentifier(session)) ?? []
        for callback in callbacks{callback()}
    }
    func cancel(ifOwnedBy ownerID:UUID,completion:@escaping()->Void) {
        guard requestOwnerID == ownerID else{completion();return}
        cancel(completion:completion)
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
        if wasBusy { setupJournal?.record("cancelled") }
        stopped = true; attemptID = nil; operationDescriptor = nil
        let stoppedWork=DispatchGroup()
        if let session {
            stoppedWork.enter()
            invalidationWaiters[ObjectIdentifier(session),default:[]].append{stoppedWork.leave()}
            task?.cancel();session.invalidateAndCancel()
        }
        task = nil; session = nil
        installerOperation?.cancel()
        preparationToken.cancel()
        let finish = { [self] in
            // An idle cancellation may finish after a fresh start. Its completion
            // still fires, but it no longer owns that new attempt's state/files.
            guard cancelGeneration == cancellation, stopped && attemptID == nil else { completion(); return }
            cancelGeneration = UUID()
            installerOperation = nil; removeInstallerFile()
            if wasBusy { update("cancelled", "Installation Steam annulée.", busy: false) }
            completion()
        }
        stoppedWork.enter();installerQueue.async{stoppedWork.leave()}
        stoppedWork.notify(queue:.main,execute:finish)
    }
}

/// Owns one bootstrap attempt; polling a terminal failure can never retry it.
final class SteamBootstrapIntent {
    enum State:Equatable {case waiting,ready,stopped(String)}
    let ownerID:UUID
    private let bootstrap:SteamWindowsBootstrap
    private var started=false,cancelled=false
    init(ownerID:UUID,bootstrap:SteamWindowsBootstrap){self.ownerID=ownerID;self.bootstrap=bootstrap}
    func poll()->State {
        if cancelled{return .stopped("Préparation Steam annulée.")}
        if !started {
            guard !bootstrap.busy else{return .waiting}
            started=true;bootstrap.start(ownerID:ownerID)
        }
        guard bootstrap.requestOwnerID == ownerID else{return .stopped("Cette reprise ne possède plus la préparation Steam.")}
        switch bootstrap.snapshot["steamPhase"] as? String {
        case "ready":return .ready
        case "failed","cancelled":return .stopped(bootstrap.snapshot["steamMessage"] as? String ?? "Préparation Steam arrêtée.")
        default:return .waiting
        }
    }
    func cancel(completion:@escaping()->Void) {
        cancelled=true
        guard started else{completion();return}
        bootstrap.cancel(ifOwnedBy:ownerID,completion:completion)
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
        let url = descriptor.steamRoot.appendingPathComponent("steam.exe")
        guard (try? RuntimeSetup.rejectSymlinkAncestors(url)) != nil else { return false }
        let file = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { return false }; defer { Darwin.close(file) }
        var metadata = stat(), bytes = [UInt8](repeating:0,count:2)
        guard fstat(file,&metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == geteuid() else { return false }
        return Darwin.read(file,&bytes,2) == 2 && bytes == [0x4d,0x5a]
    }
    static func ownsPrefix(_ descriptor: PlaymeltRuntimeDescriptor) -> Bool {
        let marker = descriptor.prefixURL.deletingLastPathComponent().appendingPathComponent("prefix-owner.json")
        guard (try? RuntimeSetup.rejectSymlinkAncestors(marker)) != nil else {return false}
        var info=stat()
        guard lstat(marker.path,&info)==0, info.st_mode&S_IFMT==S_IFREG, info.st_uid==geteuid(), info.st_nlink==1,
              let metadata = try? FileManager.default.attributesOfItem(atPath: marker.path), metadata[.type] as? FileAttributeType == .typeRegular,
              let bytes = (metadata[.size] as? NSNumber)?.intValue, bytes > 0, bytes < 8192,
              let data = try? Data(contentsOf:marker), let owner = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
              owner["prefix"] as? String == descriptor.prefixURL.path, let engineID = owner["engineID"] as? String else { return false }
        return engineID == descriptor.engineID || (owner["owner"] as? String == "playmelt-d3dmetal" && descriptor.engineID.hasPrefix(engineID + "/d3dmetal/"))
    }
    func run(installer: URL, descriptor: PlaymeltRuntimeDescriptor, current: () -> PlaymeltRuntimeDescriptor?, journal: SteamInstallerJournal? = nil,
             onDetachedExit: @escaping (Int32) -> Void) throws -> OwnedProcessResult {
        guard !token.isCancelled else { throw OwnedProcessError.cancelled }
        guard descriptor.readyEngine, Self.ownsPrefix(descriptor), let fresh = current(), SteamWindowsBootstrap.sameRuntime(descriptor,fresh) else { throw RuntimeSetupError.failed("Le préfixe Steam sélectionné n’appartient pas à cette préparation Playmelt.") }
        try RuntimeSetup.rejectSymlinkAncestors(descriptor.prefixURL)
        if Self.steamPresent(descriptor) { return .init(output:Data(),exitCode:0,pid:0,handedOff:false) }
        let processRoots=WineExecutableLocations.processRoots(wine:descriptor.wineURL)
        func runtimeProcess(_ row:Substring)->Bool {
            processRoots.contains { row.contains($0.path+"/") } || row.contains(descriptor.prefixURL.path+"/")
        }
        let toolsEnvironment=["PATH":"/usr/bin:/bin:/usr/sbin:/sbin","LC_ALL":"C"]
        var scan=OwnedProcessRequest(executable:URL(fileURLWithPath:"/bin/ps"),arguments:["-axo","pid=,comm="],environment:toolsEnvironment)
        scan.timeout=5;scan.outputLimit=8*1024*1024
        let before=try runner.run(scan,cancelled:{self.token.isCancelled})
        guard before.exitCode==0, !String(decoding:before.output,as:UTF8.self).split(separator:"\n").contains(where:{runtimeProcess($0)}) else { throw RuntimeSetupError.failed("Un programme utilise déjà Wine. Fermez-le avant d’installer ce client Steam.") }
        guard let validated=current(), SteamWindowsBootstrap.sameRuntime(descriptor,validated) else { throw RuntimeSetupError.failed("Le moteur Steam a changé pendant la préparation.") }
        if Self.steamPresent(descriptor) { return .init(output:Data(),exitCode:0,pid:0,handedOff:false) }
        var command=OwnedProcessRequest(executable:descriptor.wineURL,arguments:[installer.path],environment:descriptor.environment)
        command.directory=descriptor.prefixURL;command.timeout=1800;command.allowsHandoff=true;command.preserveGroupOnSuccess=true;command.idlePollInterval=0.25
        var lastCheck=0.0,handedOff=false,spawned=false
        command.onSpawn={pid in
            spawned=true
            let group=getpgid(pid)
            journal?.record("spawned",fields:["pid":pid,"processGroup":group,"processGroupObserved":group>0])
        }
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
        if let journal {
            var observation=OwnedProcessRequest(executable:scan.executable,arguments:["-axo","pid=,ppid=,pgid=,state=,comm="],environment:toolsEnvironment)
            observation.timeout=5;observation.outputLimit=8*1024*1024
            if let result=try? runner.run(observation,cancelled:{false}),result.exitCode==0 {
                let rows=String(decoding:result.output,as:UTF8.self).split(separator:"\n").filter{
                    runtimeProcess($0) || $0.contains(installer.path)
                }.prefix(64).map{String($0.prefix(1024))}
                journal.record("before-prefix-cleanup",fields:["matchingProcesses":rows,"rawWaitStatusAvailable":false])
            } else { journal.record("before-prefix-cleanup",fields:["processObservationUnavailable":true]) }
        }
        var cleanupFailed=false
        for argument in ["-k","-w"] {
            var stop=OwnedProcessRequest(executable:descriptor.wineserverURL,arguments:[argument],environment:descriptor.environment)
            stop.timeout=10
            do { if try runner.run(stop,cancelled:{false}).exitCode != 0{cleanupFailed=true} } catch {cleanupFailed=true}
        }
        do {
            let remaining=try runner.run(scan,cancelled:{false})
            if remaining.exitCode != 0 || String(decoding:remaining.output,as:UTF8.self).split(separator:"\n").contains(where:{runtimeProcess($0)}){cleanupFailed=true}
        } catch {cleanupFailed=true}
        if cleanupFailed {throw SteamInstallerLifecycleError.cleanupUnconfirmed}
        journal?.record("prefix-cleanup-confirmed")
        return try outcome.get()
    }
}

/// Private control-plane diagnostics only: no environment, arguments, output,
/// cookies, credentials or Windows installation-stage claims are recorded.
enum SteamInstallerJournalError: LocalizedError {
    case invalid, automaticRetryBlocked
    var errorDescription: String? {
        switch self {
        case .invalid: return "Le diagnostic privé Steam ne peut pas être validé. Aucune nouvelle préparation automatique n’a été lancée."
        case .automaticRetryBlocked: return "Cette demande de préparation Steam ne sera pas relancée en boucle. Utilisez Reprendre pour démarrer une nouvelle tentative explicite."
        }
    }
}

final class SteamInstallerJournal {
    private static let gate = NSRecursiveLock(), limit = 32 * 1024
    private static let owner = "playmelt-steam-setup-diagnostic"
    private static let events: Set<String> = ["requested","download-started","download-failed","prepared","spawned","detached-leader-exit",
        "completed","stopped","cancelled","client-observed","before-prefix-cleanup","prefix-cleanup-confirmed",
        "bootstrap-cache-reused","bootstrap-verified","client-prepared","bootstrap-cache-repair"]
    private static let booleans: Set<String> = ["processGroupObserved","handedOff","rawWaitStatusAvailable","processObservationUnavailable"]
    private static let numbers: Set<String> = ["pid","processGroup","exitCode","errorCode","matchingProcessCount"]
    private let lock=NSLock(),url:URL
    private var record:[String:Any]
    init(url:URL,installer:URL?=nil,descriptor:PlaymeltRuntimeDescriptor,automatic:Bool=false,method:String="interactive-installer-v1",intentID:UUID?=nil,lease:SteamBootstrapLease?=nil)throws {
        self.url=url
        guard ["interactive-installer-v1",SteamBootstrapPackage.method].contains(method) else {throw SteamInstallerJournalError.invalid}
        if automatic && method == SteamBootstrapPackage.method && intentID == nil {throw SteamInstallerJournalError.invalid}
        Self.gate.lock(); defer { Self.gate.unlock() }
        if let old = try Self.load(url), automatic,
           old["engineID"] as? String == descriptor.engineID, old["prefix"] as? String == descriptor.prefixURL.path {
            let history=old["events"] as? [[String:Any]] ?? []
            let terminalLegacy=history.contains{ event in
                event["event"] as? String == "download-failed" || event["event"] as? String == "cancelled" ||
                (event["event"] as? String == "completed" && event["handedOff"] as? Bool == false)
            }
            guard method == SteamBootstrapPackage.method, let intentID,
                  old["intentID"] as? String != intentID.uuidString else {throw SteamInstallerJournalError.automaticRetryBlocked}
            let oldMethod=old["method"] as? String ?? "interactive-installer-v1"
            if oldMethod == SteamBootstrapPackage.method {
                // Owner UUIDs are created only for a foreground click/retry.
                // Same-intent timers cannot loop. The kernel lease also proves
                // no old ZIP operation survived a crash in another process.
                guard lease?.covers(descriptor) == true else {throw SteamInstallerJournalError.automaticRetryBlocked}
            } else {
                guard terminalLegacy else {throw SteamInstallerJournalError.automaticRetryBlocked}
            }
        }
        record=["schema":1,"owner":Self.owner,"attemptID":UUID().uuidString,
            "method":method,
            "installerSHA256":try installer.map(Self.installerHash) as Any? ?? NSNull(),
            "engineID":descriptor.engineID,"prefix":descriptor.prefixURL.path,"events":[[String:Any]](),
            "stdoutCaptured":false,"stderrCaptured":false,"signalFromWaitStatusAvailable":false]
        if let intentID {record["intentID"]=intentID.uuidString}
        try write(replacingPreviousAttempt:true)
        self.record(installer == nil ? "requested" : "prepared")
    }
    private static func text(_ value:Any?,limit:Int)->String? {
        guard let value=value as? String,!value.isEmpty,value.utf8.count<=limit,
              !value.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) else{return nil}
        return value
    }
    private static func flag(_ value:Any?)->Bool? {
        guard let value=value as? NSNumber,CFGetTypeID(value)==CFBooleanGetTypeID() else{return nil};return value.boolValue
    }
    private static func integer(_ value:Any?)->Bool {
        guard let value=value as? NSNumber,CFGetTypeID(value) != CFBooleanGetTypeID() else{return false}
        return value.doubleValue.isFinite && value.doubleValue.rounded()==value.doubleValue &&
            value.doubleValue>=Double(Int32.min) && value.doubleValue<=Double(Int32.max)
    }
    private static func load(_ url:URL)throws->[String:Any]? {
        guard url.isFileURL,url.query==nil,url.fragment==nil,url.path==url.standardizedFileURL.path else{throw SteamInstallerJournalError.invalid}
        try RuntimeSetup.rejectSymlinkAncestors(url)
        let file=Darwin.open(url.path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC)
        if file<0 {if errno==ENOENT{return nil};throw SteamInstallerJournalError.invalid}
        defer{Darwin.close(file)}
        var metadata=stat()
        guard fstat(file,&metadata)==0,metadata.st_mode&S_IFMT==S_IFREG,metadata.st_uid==geteuid(),metadata.st_nlink==1,
              metadata.st_mode&0o777==0o600,metadata.st_size>0,metadata.st_size<=Self.limit else{throw SteamInstallerJournalError.invalid}
        var data=Data(count:Int(metadata.st_size)),offset=0
        while offset<data.count {
            let count=data.withUnsafeMutableBytes{Darwin.read(file,$0.baseAddress!.advanced(by:offset),$0.count-offset)}
            if count<0 && errno==EINTR{continue};guard count>0 else{throw SteamInstallerJournalError.invalid};offset+=count
        }
        var end:UInt8=0
        guard Darwin.read(file,&end,1)==0,let value=(try?JSONSerialization.jsonObject(with:data)) as? [String:Any],
              Set(value.keys).isSubset(of:["schema","owner","attemptID","installerSHA256","engineID","prefix","events","stdoutCaptured","stderrCaptured","signalFromWaitStatusAvailable","method","intentID"]),
              Self.integer(value["schema"]),(value["schema"] as? NSNumber)?.intValue==1,value["owner"] as? String==Self.owner,
              (value["attemptID"] as? String).flatMap(UUID.init(uuidString:)) != nil,
              Self.text(value["engineID"],limit:512) != nil,let prefix=Self.text(value["prefix"],limit:4096),prefix.hasPrefix("/"),
              URL(fileURLWithPath:prefix).standardizedFileURL.path==prefix,
              Self.flag(value["stdoutCaptured"])==false,Self.flag(value["stderrCaptured"])==false,Self.flag(value["signalFromWaitStatusAvailable"])==false,
              let events=value["events"] as? [[String:Any]],events.count<=16 else{throw SteamInstallerJournalError.invalid}
        if let method=value["method"] {guard let method=method as? String,["interactive-installer-v1",SteamBootstrapPackage.method].contains(method) else{throw SteamInstallerJournalError.invalid}}
        if let id=value["intentID"] {guard let id=id as? String,UUID(uuidString:id)?.uuidString==id else{throw SteamInstallerJournalError.invalid}}
        if let hash=value["installerSHA256"],!(hash is NSNull) {
            guard let hash=hash as? String,hash.count==64,hash.allSatisfy({$0.isHexDigit && !$0.isUppercase}) else{throw SteamInstallerJournalError.invalid}
        }
        let allowed=Self.booleans.union(Self.numbers).union(["event","time","errorType","reason","matchingProcesses"])
        for event in events {
            guard Set(event.keys).isSubset(of:allowed),let name=event["event"] as? String,Self.events.contains(name),
                  Self.text(event["time"],limit:64) != nil else{throw SteamInstallerJournalError.invalid}
            for (key,input) in event where !["event","time"].contains(key) {
                if Self.booleans.contains(key){guard Self.flag(input) != nil else{throw SteamInstallerJournalError.invalid}}
                else if Self.numbers.contains(key){guard Self.integer(input) else{throw SteamInstallerJournalError.invalid}}
                else if key=="matchingProcesses" {
                    guard let rows=input as? [String],rows.count<=64,rows.allSatisfy({Self.text($0,limit:1024) != nil}) else{throw SteamInstallerJournalError.invalid}
                } else {guard Self.text(input,limit:key=="reason" ? 4096:128) != nil else{throw SteamInstallerJournalError.invalid}}
            }
        }
        return value
    }
    private static func installerHash(_ url:URL)throws->String {
        try RuntimeSetup.rejectSymlinkAncestors(url)
        guard let attributes=try?FileManager.default.attributesOfItem(atPath:url.path),attributes[.type] as? FileAttributeType == .typeRegular,
              let size=(attributes[.size] as? NSNumber)?.intValue,size>0,size<=64_000_000 else{throw SteamInstallerJournalError.invalid}
        return SHA256.hash(data:try Data(contentsOf:url,options:.mappedIfSafe)).map{String(format:"%02x",$0)}.joined()
    }
    func prepareInstaller(_ installer:URL)throws {
        lock.lock();defer{lock.unlock()}
        record["installerSHA256"]=try Self.installerHash(installer)
        try write()
        append("prepared",fields:[:])
    }
    func record(_ event:String,fields:[String:Any]=[:]) {
        lock.lock();defer{lock.unlock()}
        append(event,fields:fields)
    }
    private func append(_ event:String,fields:[String:Any]) {
        guard Self.events.contains(event) else{return}
        var item:[String:Any]=["event":event,"time":ISO8601DateFormatter().string(from:Date())]
        for (key,value) in fields {
            if Self.booleans.contains(key),Self.flag(value) != nil{item[key]=value}
            else if Self.numbers.contains(key),Self.integer(value){item[key]=value}
            else if key=="errorType",let value=Self.text(value,limit:128),value.allSatisfy({$0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0))}){item[key]=value}
            else if key=="matchingProcesses",let rows=value as? [String]{item["matchingProcessCount"]=min(64,rows.count)}
        }
        var events=record["events"] as? [[String:Any]] ?? [];events.append(item);record["events"]=Array(events.suffix(16))
        try? write()
    }
    private func write(replacingPreviousAttempt:Bool=false)throws {
        Self.gate.lock();defer{Self.gate.unlock()}
        try RuntimeSetup.rejectSymlinkAncestors(url)
        let current=try Self.load(url)
        if !replacingPreviousAttempt {
            guard current?["attemptID"] as? String == record["attemptID"] as? String else{return}
        }
        let directory=url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        var metadata=stat()
        guard lstat(directory.path,&metadata)==0,metadata.st_mode&S_IFMT==S_IFDIR,metadata.st_uid==geteuid() else{throw SteamInstallerJournalError.invalid}
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:directory.path)
        let data=try JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys])
        guard data.count<=Self.limit else{throw SteamInstallerJournalError.invalid}
        try data.write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
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
