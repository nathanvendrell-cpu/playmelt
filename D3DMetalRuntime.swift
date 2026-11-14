import Foundation
import CryptoKit
import Darwin

@_silgen_name("proc_listpids") private func runtimeProcListPids(_ type: UInt32, _ typeInfo: UInt32, _ buffer: UnsafeMutableRawPointer?, _ size: Int32) -> Int32
@_silgen_name("proc_pidpath") private func runtimeProcPidPath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer?, _ size: UInt32) -> Int32

/// Inspect same-user executable images, not the process display name or arguments.
enum D3DMetalProcessInspector {
    static func inactive(pid: pid_t) throws -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else {
            if errno == ESRCH { return true }
            throw RuntimeSetupError.failed("Impossible de vérifier l’état du processus utilisateur \(pid).")
        }
        if size == 0 { return true }
        guard size == MemoryLayout<kinfo_proc>.size else { throw RuntimeSetupError.failed("État de processus incomplet.") }
        return Int32(info.kp_proc.p_stat) == SZOMB
    }
    static func paths() throws -> [pid_t: String] {
        let initial = runtimeProcListPids(4, UInt32(geteuid()), nil, 0) // PROC_UID_ONLY
        guard initial > 0 else { throw RuntimeSetupError.failed("Impossible d’énumérer les processus utilisateur.") }
        var capacity = max(Int(initial) / MemoryLayout<pid_t>.size + 1024, 1024)
        var pids: [pid_t] = [], bytes: Int32 = 0
        while capacity <= 65536 {
            pids = [pid_t](repeating: 0, count: capacity)
            bytes = pids.withUnsafeMutableBytes { runtimeProcListPids(4, UInt32(geteuid()), $0.baseAddress, Int32($0.count)) }
            guard bytes >= 0 else { throw RuntimeSetupError.failed("Impossible d’énumérer les processus utilisateur.") }
            if Int(bytes) < capacity * MemoryLayout<pid_t>.size { break }
            capacity *= 2
        }
        guard capacity <= 65536, bytes > 0, Int(bytes) % MemoryLayout<pid_t>.size == 0 else { throw RuntimeSetupError.failed("L’inventaire des processus est incomplet.") }
        var result: [pid_t: String] = [:]
        for pid in pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size) where pid > 0 {
            var buffer = [CChar](repeating: 0, count: 4096)
            errno = 0
            let count = buffer.withUnsafeMutableBytes { runtimeProcPidPath(pid, $0.baseAddress, UInt32($0.count)) }
            if count <= 0 {
                if try inactive(pid: pid) { continue }
                throw RuntimeSetupError.failed("Impossible de vérifier le programme du processus utilisateur \(pid).")
            }
            result[pid] = String(cString: buffer)
        }
        return result
    }
    static func occupied(paths: [pid_t: String], engine: URL, prefix: URL) -> Bool {
        let roots = [engine, prefix].map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        return paths.values.contains { path in
            let resolved = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
            return roots.contains { resolved == $0 || resolved.hasPrefix($0 + "/") }
        }
    }
    static func occupied(engine: URL, prefix: URL) throws -> Bool {
        occupied(paths: try paths(), engine: engine, prefix: prefix)
    }
}

struct D3DMetalCommand {
    let executable: URL
    let arguments: [String]
    let environment: [String:String]
    let timeout: TimeInterval
}

protocol D3DMetalCommandRunning {
    func run(_ command: D3DMetalCommand, cancelled: () -> Bool) throws -> String
}

/// Adapter preserving the DX12 test contract while sharing lifecycle supervision.
final class D3DMetalProcessRunner: D3DMetalCommandRunning {
    private let runner: OwnedProcessRunning
    init(runner: OwnedProcessRunning = OwnedProcessRunner()) { self.runner = runner }
    func run(_ command: D3DMetalCommand, cancelled: () -> Bool) throws -> String {
        var request = OwnedProcessRequest(executable: command.executable, arguments: command.arguments, environment: command.environment)
        request.timeout = command.timeout
        request.failOnOverflow = ["/bin/ps", "/usr/bin/nm"].contains(command.executable.path)
        request.preserveGroupOnSuccess = command.arguments == ["wineboot", "-u"]
        do {
            let result = try runner.run(request, cancelled: cancelled)
            guard result.exitCode == 0 else { throw RuntimeSetupError.failed("Échec de \(command.executable.lastPathComponent) (code \(result.exitCode)).") }
            return String(decoding: result.output, as: UTF8.self)
        } catch OwnedProcessError.cancelled { throw RuntimeSetupError.cancelled }
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
    private let occupied: (URL, URL) throws -> Bool
    private let queue = DispatchQueue(label: "fr.playmelt.d3dmetal.prepare", qos: .utility)
    private let lock = NSLock()
    private var running = false, cancelled = false, closing = false
    private var operationOwnerID:UUID?,readyCommitted=false
    private var operationCompletion:DispatchGroup?
    private var status = "not-prepared", message = "Le préfixe DirectX 12 doit être préparé.", abiStatus = "unverified"
    private var callback: (([String:Any]) -> Void)?
    private var operationBase: PlaymeltRuntimeDescriptor?
    private var previousDescriptor: PlaymeltRuntimeDescriptor?
    private var cachedReceipt: [String:Any]?, cachedReceiptIdentity: String?
    private var root: URL { store.isolatedRoot }
    private var readyURL: URL { root.appendingPathComponent("prefix-ready.json") }
    private var ownerURL: URL { root.appendingPathComponent("prefix-owner.json") }

    init(store: D3DMetalStore = D3DMetalStore(), runner: D3DMetalCommandRunning = D3DMetalProcessRunner(),
         capacity: @escaping (URL) throws -> Int64 = { try $0.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0 },
         occupied: @escaping (URL, URL) throws -> Bool = { try D3DMetalProcessInspector.occupied(engine: $0, prefix: $1) }) {
        self.store = store; self.runner = runner; self.capacity = capacity; self.occupied = occupied
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
                     environment: D3DMetalStore.launchEnvironment(config.environment), readyEngine: true, steamInstalled: header == Data([0x4d,0x5a]))
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

    func start(base: PlaymeltRuntimeDescriptor, ownerID:UUID?=nil,progress: @escaping ([String:Any]) -> Void,
               completion: @escaping (Result<PlaymeltRuntimeDescriptor,Error>) -> Void) {
        lock.lock()
        guard !running && !closing else { lock.unlock(); DispatchQueue.main.async { completion(.failure(RuntimeSetupError.failed("Une préparation est déjà en cours ou l’application se ferme."))) }; return }
        running = true; cancelled = false; operationOwnerID=ownerID;readyCommitted=false;callback = progress; operationBase = base; previousDescriptor = nil
        let finished=DispatchGroup();finished.enter();operationCompletion=finished
        lock.unlock()
        queue.async {
            let result: Result<PlaymeltRuntimeDescriptor,Error>
            do { let descriptor = try self.prepare(base: base); result = .success(descriptor); self.update("ready", "Préfixe DirectX 12 préparé.") }
            catch {
                result = .failure(error)
                self.update(self.isCancelled ? "cancelled" : error is D3DMetalPreparationError ? "blocked" : "failed", error.localizedDescription)
            }
            self.lock.lock(); self.running = false; self.previousDescriptor = nil; self.lock.unlock()
            self.emit(); DispatchQueue.main.async { defer{finished.leave()};completion(result) }
        }
    }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    /// Cancel/wait only the operation belonging to this retained game intent.
    /// A manual or replacement preparation is never adopted by this caller.
    func cancel(ifOwnedBy ownerID:UUID,completion:@escaping()->Void) {
        lock.lock()
        let owns=running && operationOwnerID == ownerID
        let finished=owns ? operationCompletion:nil
        if owns && !readyCommitted{cancelled=true}
        lock.unlock()
        guard let finished else{DispatchQueue.main.async(execute:completion);return}
        finished.notify(queue:.main,execute:completion)
    }
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
        guard try !occupied(engine, plan.prefixURL) else { throw D3DMetalPreparationError.blocked("Wine est utilisé par un programme existant. Il doit être fermé avant cette préparation.") }
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
            var environment = plan.preparationEnvironment
            if executable == base.wineURL && arguments == ["wineboot", "-u"] { environment["WINEBOOT_HIDE_DIALOG"] = "1" }
            do { let result = try runner.run(.init(executable:executable,arguments:arguments,environment:environment,timeout:timeout),cancelled:{cleanup ? false : self.isCancelled}); appendLog(result + "\n") }
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
            if try occupied(engine, plan.prefixURL) { stopFailed = true }
        } catch { stopFailed = true }
        if stopFailed { throw RuntimeSetupError.failed("L’arrêt du Wine de ce préfixe n’a pas été confirmé. La préparation n’est pas marquée prête.") }
        if let bootError { throw bootError }
        try checkCancellation()
        try RuntimeSetup.validatePrefix(plan.prefixURL)
        guard expectedBindings == (try bindings(base:base)) else { throw D3DMetalPreparationError.blocked("Le moteur ou l’import a changé pendant la préparation. Les données sont conservées.") }
        let receipt: [String:Any] = ["schema":1,"owner":"playmelt-d3dmetal","rendererHash":plan.rendererHash,"engineID":base.engineID,
            "engineFingerprint":plan.engineFingerprint,"environmentHash":Self.environmentHash(plan.preparationEnvironment),"bindings":expectedBindings,
            "preparedAt":ISO8601DateFormatter().string(from:Date()),"loadTested":false,"gameTested":false,"canLaunch":false]
        let temporaryReceipt = root.appendingPathComponent(".ready-" + UUID().uuidString)
        defer { try? fm.removeItem(at:temporaryReceipt) } // only this new transaction file
        try JSONSerialization.data(withJSONObject:receipt,options:[.sortedKeys,.prettyPrinted]).write(to:temporaryReceipt,options:.withoutOverwriting)
        // The ready receipt is the transaction boundary: cancellation accepted
        // before it must not publish readiness. Completed receipts stay intact.
        lock.lock()
        guard !cancelled else{lock.unlock();throw RuntimeSetupError.cancelled}
        do {try fm.moveItem(at:temporaryReceipt,to:readyURL);readyCommitted=true;lock.unlock()}
        catch {lock.unlock();throw error}
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
