import Foundation
import CryptoKit
import Darwin

struct D3DMetalCommand {
    let executable: URL
    let arguments: [String]
    let environment: [String:String]
    let timeout: TimeInterval
}

protocol D3DMetalCommandRunning {
    func run(_ command: D3DMetalCommand, cancelled: () -> Bool) throws -> String
}

/// Each invocation owns a fresh process group. Cancellation signals only that
/// group while its leader remains unreaped, preventing PID reuse. Detached Wine
/// services are stopped separately, using only the exclusively owned prefix.
final class D3DMetalProcessRunner: D3DMetalCommandRunning {
    func run(_ command: D3DMetalCommand, cancelled: () -> Bool) throws -> String {
        if cancelled() { throw RuntimeSetupError.cancelled }
        var pipes: [Int32] = [0,0]
        guard pipe(&pipes) == 0 else { throw RuntimeSetupError.failed("Impossible de superviser le processus de préparation.") }
        var readOpen = true, writeOpen = true
        defer { if readOpen { close(pipes[0]) }; if writeOpen { close(pipes[1]) } }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw RuntimeSetupError.failed("Initialisation du superviseur impossible.") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw RuntimeSetupError.failed("Initialisation du groupe de processus impossible.") }
        defer { posix_spawnattr_destroy(&attributes) }
        let setup = [
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)),
            posix_spawnattr_setpgroup(&attributes, 0),
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
            posix_spawn_file_actions_adddup2(&actions, pipes[1], STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&actions, pipes[1], STDERR_FILENO),
            posix_spawn_file_actions_addclose(&actions, pipes[0]),
            posix_spawn_file_actions_addclose(&actions, pipes[1])
        ]
        guard setup.allSatisfy({ $0 == 0 }), fcntl(pipes[0], F_SETFL, O_NONBLOCK) == 0,
              fcntl(pipes[0], F_SETFD, FD_CLOEXEC) == 0, fcntl(pipes[1], F_SETFD, FD_CLOEXEC) == 0 else { throw RuntimeSetupError.failed("Configuration du superviseur impossible.") }
        var argv = ([command.executable.path] + command.arguments).map { strdup($0) } + [nil]
        var envp = command.environment.keys.sorted().map { strdup($0 + "=" + command.environment[$0]!) } + [nil]
        defer { for item in argv { free(item) }; for item in envp { free(item) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, command.executable.path, &actions, &attributes, &argv, &envp)
        guard spawned == 0 else { throw RuntimeSetupError.failed("Impossible de démarrer \(command.executable.lastPathComponent) (\(spawned)).") }
        close(pipes[1]); writeOpen = false
        var output = Data(), buffer = [UInt8](repeating: 0, count: 8192), status: Int32 = 0, overflow = false
        func drain() {
            // A continuous writer must not starve timeout/cancellation checks.
            for _ in 0..<8 {
                let count = Darwin.read(pipes[0], &buffer, buffer.count)
                if count <= 0 { break }
                let available = max(0, 65536 - output.count)
                if count > available { overflow = true }
                if available > 0 { output.append(contentsOf: buffer.prefix(min(count, available))) }
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + command.timeout
        while true {
            drain()
            let wantsCancel = cancelled(), timedOut = ProcessInfo.processInfo.systemUptime >= deadline
            if wantsCancel || timedOut {
                // Keep the leader unreaped until group escalation has finished.
                _ = kill(-pid, SIGTERM)
                let grace = ProcessInfo.processInfo.systemUptime + 1
                while ProcessInfo.processInfo.systemUptime < grace { drain(); Thread.sleep(forTimeInterval: 0.02) }
                _ = kill(-pid, SIGKILL)
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                drain()
                if wantsCancel { throw RuntimeSetupError.cancelled }
                throw RuntimeSetupError.failed("Le délai de \(command.executable.lastPathComponent) est dépassé.")
            }
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { break }
            if result < 0 && errno != EINTR {
                // Signal only while the known leader still owns this group.
                // Otherwise ownership cannot be re-established from a PID alone;
                // report failure and let the prefix-scoped cleanup run.
                if getpgid(pid) == pid { _ = kill(-pid,SIGKILL); while waitpid(pid,&status,0) < 0 && errno == EINTR {} }
                throw RuntimeSetupError.failed("Le processus de préparation ne peut pas être suivi.")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        drain(); close(pipes[0]); readOpen = false
        let code = (status & 0x7f) == 0 ? (status >> 8) & 255 : 128 + (status & 0x7f)
        guard code == 0 else { throw RuntimeSetupError.failed("Échec de \(command.executable.lastPathComponent) (code \(code)).") }
        if overflow && ["/bin/ps","/usr/bin/nm"].contains(command.executable.path) { throw RuntimeSetupError.failed("La sortie de contrôle est trop volumineuse pour confirmer son résultat complet.") }
        return String(decoding: output, as: UTF8.self)
    }
}

private enum D3DMetalPreparationError: LocalizedError {
    case blocked(String)
    var errorDescription: String? { if case .blocked(let message) = self { return message }; return nil }
}

/// Prefix preparation only. It never downloads/starts Steam, creates a Metal
/// device, executes a probe or qualifies a game. The app must separately enforce
/// its render-protection/explicit-action gates before calling start().
final class D3DMetalRuntime {
    private let store: D3DMetalStore
    private let runner: D3DMetalCommandRunning
    private let capacity: (URL) throws -> Int64
    private let queue = DispatchQueue(label: "fr.playmelt.d3dmetal.prepare", qos: .utility)
    private let lock = NSLock()
    private var running = false, cancelled = false, closing = false
    private var status = "not-prepared", message = "Le préfixe DirectX 12 doit être préparé.", abiStatus = "unverified"
    private var callback: (([String:Any]) -> Void)?
    private var operationBase: PlaymeltRuntimeDescriptor?
    private var previousDescriptor: PlaymeltRuntimeDescriptor?
    private var cachedReceipt: [String:Any]?, cachedReceiptIdentity: String?
    private var root: URL { store.isolatedRoot }
    private var readyURL: URL { root.appendingPathComponent("prefix-ready.json") }
    private var ownerURL: URL { root.appendingPathComponent("prefix-owner.json") }

    init(store: D3DMetalStore = D3DMetalStore(), runner: D3DMetalCommandRunning = D3DMetalProcessRunner(),
         capacity: @escaping (URL) throws -> Int64 = { try $0.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0 }) {
        self.store = store; self.runner = runner; self.capacity = capacity
    }

    /// Metadata and four bounded prefix-header reads only; no payload rehashing.
    /// Check immediately before Steam dispatch. Changed file identity invalidates
    /// this descriptor; a prepared/used prefix is never automatically rewritten.
    func descriptor(base: PlaymeltRuntimeDescriptor) throws -> PlaymeltRuntimeDescriptor? {
        guard let receipt = try loadReceipt() else { return nil }
        let config = try store.candidateConfiguration(base: base)
        guard base.readyEngine, receipt["rendererHash"] as? String == config.rendererHash,
              receipt["engineID"] as? String == base.engineID,
              receipt["environmentHash"] as? String == Self.environmentHash(config.environment),
              let recorded = receipt["bindings"] as? [String:String], recorded == (try bindings(base: base)),
              try ownsPrefix(config.prefix, rendererHash: config.rendererHash, engineID: base.engineID) else { throw D3DMetalPreparationError.blocked("La préparation DirectX 12 ne correspond plus aux fichiers présents. Les données sont conservées.") }
        try RuntimeSetup.validatePrefix(config.prefix)
        let steam = config.prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam")
        let handle = try? FileHandle(forReadingFrom: steam.appendingPathComponent("steam.exe"))
        let header = try? handle?.read(upToCount: 2); try? handle?.close()
        return .init(engineID: base.engineID + "/d3dmetal/" + config.rendererHash, wineURL: base.wineURL,
                     wineserverURL: base.wineserverURL, prefixURL: config.prefix, steamRoot: steam,
                     environment: config.environment, readyEngine: true, steamInstalled: header == Data([0x4d,0x5a]))
    }

    func snapshot(base: PlaymeltRuntimeDescriptor) -> [String:Any] {
        lock.lock(); let busy = running, current = status, text = message, abi = abiStatus, previous = previousDescriptor; lock.unlock()
        let imported = store.snapshot()["imported"] as? Bool == true
        var prepared: PlaymeltRuntimeDescriptor? = previous, descriptorError: String?
        if !busy { do { prepared = try descriptor(base: base) } catch { descriptorError = error.localizedDescription; prepared = nil } }
        let ready = prepared != nil, receiptPresent = FileManager.default.fileExists(atPath: readyURL.path)
        let phase = busy ? current : ready ? "ready" : !imported ? "missing" : descriptorError != nil ? "blocked" : current
        let info = busy ? text : ready ? "Préfixe DirectX 12 préparé." : !imported ? "Importez D3DMetal avant de préparer son préfixe." : descriptorError ?? text
        return ["status": phase, "message": info, "busy": busy, "cancellable": busy,
                "prepared": ready, "steamInstalled": prepared?.steamInstalled ?? false,
                "canPrepare": imported && base.readyEngine && !busy && !ready && !receiptPresent,
                "canLaunch": false, "abiStatus": abi, "loadTested": false, "gameTested": false]
    }

    func start(base: PlaymeltRuntimeDescriptor, progress: @escaping ([String:Any]) -> Void,
               completion: @escaping (Result<PlaymeltRuntimeDescriptor,Error>) -> Void) {
        lock.lock()
        guard !running && !closing else { lock.unlock(); DispatchQueue.main.async { completion(.failure(RuntimeSetupError.failed("Une préparation est déjà en cours ou l’application se ferme."))) }; return }
        running = true; cancelled = false; callback = progress; operationBase = base; previousDescriptor = nil
        lock.unlock()
        queue.async {
            let result: Result<PlaymeltRuntimeDescriptor,Error>
            do { let descriptor = try self.prepare(base: base); result = .success(descriptor); self.update("ready", "Préfixe DirectX 12 préparé.") }
            catch {
                result = .failure(error)
                self.update(self.isCancelled ? "cancelled" : error is D3DMetalPreparationError ? "blocked" : "failed", error.localizedDescription)
            }
            self.lock.lock(); self.running = false; self.previousDescriptor = nil; self.lock.unlock()
            self.emit(); DispatchQueue.main.async { completion(result) }
        }
    }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func shutdown(completion: @escaping () -> Void = {}) {
        lock.lock(); closing = true; cancelled = true; lock.unlock()
        queue.async { DispatchQueue.main.async { completion() } }
    }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    private func checkCancellation() throws { if isCancelled { throw RuntimeSetupError.cancelled } }
    private func update(_ phase: String, _ text: String) { lock.lock(); status = phase; message = text; lock.unlock(); emit() }
    private func emit() {
        lock.lock(); let base = operationBase, callback = self.callback; lock.unlock()
        if let base { let value = snapshot(base: base); DispatchQueue.main.async { callback?(value) } }
    }

    private func prepare(base: PlaymeltRuntimeDescriptor) throws -> PlaymeltRuntimeDescriptor {
        try checkCancellation()
        if let existing = try descriptor(base: base) { return existing }
        update("checking", "Vérification du moteur et de l’import DirectX 12…")
        let expectedBindings = try bindings(base: base)
        let plan = try store.launchPlan(base: base) // full content hashes, once per explicit preparation
        guard plan.preparationBlockers.isEmpty else { throw D3DMetalPreparationError.blocked(plan.preparationBlockers.joined(separator: " ")) }
        let engine = base.wineURL.deletingLastPathComponent().deletingLastPathComponent()
        let driver = engine.appendingPathComponent("lib/wine/x86_64-unix/winemac.so")
        let loader = engine.appendingPathComponent("lib/wine/x86_64-unix/ntdll.so")
        guard FileManager.default.isExecutableFile(atPath: base.wineURL.path), FileManager.default.isExecutableFile(atPath: base.wineserverURL.path) else { throw D3DMetalPreparationError.blocked("Les exécutables Wine attendus sont indisponibles.") }
        let toolsEnvironment = ["PATH":"/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL":"C"]
        let symbols = try runner.run(.init(executable: URL(fileURLWithPath: "/usr/bin/nm"), arguments: ["-gU",driver.path], environment: toolsEnvironment, timeout: 15), cancelled: { self.isCancelled })
        guard symbols.split(separator: "\n").contains(where: { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).last == "_macdrv_functions" }) else {
            throw D3DMetalPreparationError.blocked("Ce Wine n’exporte pas macdrv_functions, requis par le pont D3DMetal. Aucun préfixe n’a été initialisé.")
        }
        let loaderSize = (try FileManager.default.attributesOfItem(atPath: loader.path)[.size] as? NSNumber)?.intValue ?? 0
        guard loaderSize > 0, loaderSize <= 64 * 1024 * 1024,
              try Data(contentsOf: loader, options: .mappedIfSafe).range(of: Data("WINEDLLPATH_PREPEND\0".utf8)) != nil else { throw D3DMetalPreparationError.blocked("Ce Wine ne fournit pas le chargement de l’overlay D3DMetal.") }
        lock.lock(); abiStatus = "static-prerequisites-present"; lock.unlock()
        guard expectedBindings == (try bindings(base:base)) else { throw D3DMetalPreparationError.blocked("Les fichiers du moteur ont changé pendant leur contrôle.") }
        for path in [root,plan.prefixURL,ownerURL,readyURL,root.appendingPathComponent("home")] { try RuntimeSetup.rejectSymlinkAncestors(path) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
        let lease = try Self.acquireLock(root); defer { flock(lease,LOCK_UN); close(lease) }
        if let existing = try descriptor(base: base) { return existing }
        guard try capacity(root) > 2_000_000_000 else { throw RuntimeSetupError.failed("Au moins 2 Go libres sont requis pour préparer le préfixe DirectX 12.") }
        try checkCancellation()
        let processes = try runner.run(.init(executable: URL(fileURLWithPath:"/bin/ps"), arguments:["-axo","pid=,comm="], environment:toolsEnvironment, timeout:5), cancelled:{self.isCancelled})
        guard !processes.split(separator:"\n").contains(where: { $0.contains(engine.path + "/") || $0.contains(plan.prefixURL.path + "/") }) else { throw D3DMetalPreparationError.blocked("Wine est utilisé par un programme existant. Il doit être fermé avant cette préparation.") }
        let fm = FileManager.default
        if fm.fileExists(atPath: plan.prefixURL.path) {
            guard try ownsPrefix(plan.prefixURL, rendererHash: plan.rendererHash, engineID: base.engineID),
                  !fm.fileExists(atPath: plan.steamRoot.appendingPathComponent("steam.exe").path) else { throw D3DMetalPreparationError.blocked("Ce préfixe contient des données existantes non préparées par cette opération. Elles sont conservées.") }
        } else {
            let owner: [String:Any] = ["schema":1,"owner":"playmelt-d3dmetal","prefix":plan.prefixURL.path,"rendererHash":plan.rendererHash,"engineID":base.engineID]
            if fm.fileExists(atPath:ownerURL.path) {
                guard try ownsPrefix(plan.prefixURL,rendererHash:plan.rendererHash,engineID:base.engineID) else { throw D3DMetalPreparationError.blocked("Un autre propriétaire est déclaré pour ce préfixe. Aucun fichier n’a été remplacé.") }
            } else { try JSONSerialization.data(withJSONObject:owner,options:.sortedKeys).write(to:ownerURL,options:.withoutOverwriting) }
            try fm.createDirectory(at:plan.prefixURL,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        }
        try fm.createDirectory(at:root.appendingPathComponent("home"),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let log = try Self.openLog(root.appendingPathComponent("preparation.log")); defer { close(log) }
        var logged = 0
        func appendLog(_ value: String) {
            let bytes = Data(value.utf8).prefix(max(0,65536-logged))
            let count = bytes.withUnsafeBytes { Darwin.write(log,$0.baseAddress,$0.count) }; if count > 0 { logged += count }
        }
        func run(_ executable: URL, _ arguments: [String], _ timeout: TimeInterval, cleanup: Bool = false) throws {
            appendLog(executable.lastPathComponent + " " + arguments.joined(separator:" ") + "\n")
            do { let result = try runner.run(.init(executable:executable,arguments:arguments,environment:plan.environment,timeout:timeout),cancelled:{cleanup ? false : self.isCancelled}); appendLog(result + "\n") }
            catch { appendLog(error.localizedDescription + "\n"); throw error }
        }
        try checkCancellation()
        update("initializing", "Préparation du préfixe Windows DirectX 12…")
        var bootError: Error?
        do { try run(base.wineURL,["wineboot","-u"],180); try checkCancellation() } catch { bootError = error }
        update("stopping", "Finalisation et fermeture des processus de préparation…")
        var stopFailed = false
        do { try run(base.wineserverURL,["-k"],10,cleanup:true) } catch { stopFailed = true }
        do { try run(base.wineserverURL,["-w"],10,cleanup:true) } catch { stopFailed = true }
        do {
            let remaining = try runner.run(.init(executable:URL(fileURLWithPath:"/bin/ps"),arguments:["-axo","pid=,comm="],environment:toolsEnvironment,timeout:5),cancelled:{false})
            if remaining.split(separator:"\n").contains(where: { $0.contains(engine.path + "/") || $0.contains(plan.prefixURL.path + "/") }) { stopFailed = true }
        } catch { stopFailed = true }
        if stopFailed { throw RuntimeSetupError.failed("L’arrêt du Wine de ce préfixe n’a pas été confirmé. La préparation n’est pas marquée prête.") }
        if let bootError { throw bootError }
        try checkCancellation()
        try RuntimeSetup.validatePrefix(plan.prefixURL)
        guard expectedBindings == (try bindings(base:base)) else { throw D3DMetalPreparationError.blocked("Le moteur ou l’import a changé pendant la préparation. Les données sont conservées.") }
        let receipt: [String:Any] = ["schema":1,"owner":"playmelt-d3dmetal","rendererHash":plan.rendererHash,"engineID":base.engineID,
            "engineFingerprint":plan.engineFingerprint,"environmentHash":Self.environmentHash(plan.environment),"bindings":expectedBindings,
            "preparedAt":ISO8601DateFormatter().string(from:Date()),"loadTested":false,"gameTested":false,"canLaunch":false]
        let temporaryReceipt = root.appendingPathComponent(".ready-" + UUID().uuidString)
        defer { try? fm.removeItem(at:temporaryReceipt) } // only this new transaction file
        try JSONSerialization.data(withJSONObject:receipt,options:[.sortedKeys,.prettyPrinted]).write(to:temporaryReceipt,options:.withoutOverwriting)
        try fm.moveItem(at:temporaryReceipt,to:readyURL)
        guard let ready = try descriptor(base:base) else { throw RuntimeSetupError.failed("Le reçu de préparation DirectX 12 est invalide.") }
        return ready
    }

    private func bindings(base: PlaymeltRuntimeDescriptor) throws -> [String:String] {
        let engine = base.wineURL.deletingLastPathComponent().deletingLastPathComponent()
        let files = try store.validationFiles() + [base.wineURL,base.wineserverURL,engine.appendingPathComponent("lib/wine/x86_64-unix/winemac.so"),engine.appendingPathComponent("lib/wine/x86_64-unix/ntdll.so")]
        return try Dictionary(uniqueKeysWithValues: Set(files.map(\.path)).sorted().map { ($0,try Self.identity(URL(fileURLWithPath:$0))) })
    }
    private func loadReceipt() throws -> [String:Any]? {
        guard FileManager.default.fileExists(atPath:readyURL.path) else { return nil }
        let identity = try Self.identity(readyURL)
        lock.lock(); let oldIdentity = cachedReceiptIdentity, old = cachedReceipt; lock.unlock()
        if oldIdentity == identity { return old }
        let value = try Self.readObject(readyURL)
        guard value["schema"] as? Int == 1, value["owner"] as? String == "playmelt-d3dmetal", value["canLaunch"] as? Bool == false else { throw D3DMetalPreparationError.blocked("Reçu DirectX 12 non reconnu. Les données sont conservées.") }
        lock.lock(); cachedReceiptIdentity = identity; cachedReceipt = value; lock.unlock(); return value
    }
    private func ownsPrefix(_ prefix: URL, rendererHash: String, engineID: String) throws -> Bool {
        let owner = try Self.readObject(ownerURL)
        return owner["schema"] as? Int == 1 && owner["owner"] as? String == "playmelt-d3dmetal" && owner["prefix"] as? String == prefix.path && owner["rendererHash"] as? String == rendererHash && owner["engineID"] as? String == engineID
    }
    private static func readObject(_ url: URL) throws -> [String:Any] {
        let a = try FileManager.default.attributesOfItem(atPath:url.path)
        guard a[.type] as? FileAttributeType == .typeRegular, let bytes = (a[.size] as? NSNumber)?.intValue, bytes > 0, bytes <= 1_000_000,
              let value = try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any] else { throw RuntimeSetupError.failed("Le reçu de préparation est invalide.") }
        return value
    }
    private static func environmentHash(_ environment: [String:String]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject:environment,options:.sortedKeys)) ?? Data()
        return SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
    }
    private static func identity(_ url: URL) throws -> String {
        var info = stat()
        guard lstat(url.path,&info) == 0 else { throw RuntimeSetupError.failed("Un fichier lié à la préparation est absent.") }
        return "\(info.st_dev):\(info.st_ino):\(info.st_mode):\(info.st_nlink):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
    }
    private static func acquireLock(_ root: URL) throws -> Int32 {
        let fd = open(root.appendingPathComponent(".prepare.lock").path,O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK,0o600)
        guard fd >= 0 else { throw RuntimeSetupError.failed("Verrou DirectX 12 inaccessible.") }
        var info = stat()
        guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0,
              flock(fd,LOCK_EX|LOCK_NB) == 0 else { close(fd); throw RuntimeSetupError.failed("Une préparation est en cours ou son verrou est invalide.") }
        return fd
    }
    private static func openLog(_ url: URL) throws -> Int32 {
        let fd = open(url.path,O_WRONLY|O_CREAT|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK,0o600)
        guard fd >= 0 else { throw RuntimeSetupError.failed("Journal DirectX 12 inaccessible.") }
        var info = stat()
        guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1,
              fchmod(fd,0o600) == 0, ftruncate(fd,0) == 0 else { close(fd); throw RuntimeSetupError.failed("Le journal DirectX 12 n’est pas un fichier privé régulier.") }
        return fd
    }
}
