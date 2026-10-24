import Foundation
import CryptoKit
import Darwin

struct PlaymeltRuntimeDescriptor {
    let engineID: String
    let wineURL: URL
    let wineserverURL: URL
    let prefixURL: URL
    let steamRoot: URL
    let environment: [String: String]
    let readyEngine: Bool
    let steamInstalled: Bool
}

struct RuntimeComponent {
    let name: String, url: String, sha256: String, archivePath: String, destination: String, license: String
    let bytes: Int64
}

enum RuntimeSetupError: LocalizedError {
    case cancelled, failed(String)
    var errorDescription: String? {
        switch self {
        case .cancelled: return "Préparation annulée."
        case .failed(let message): return message
        }
    }
}

/// Owns only Playmelt's isolated engine and prefix. No setup is performed by init/snapshot.
/// This is a candidate Wine/DXMT combination, not a claim of game compatibility.
final class RuntimeSetup {
    static let engineID = "playmelt-wine10-dxmt-20261017"
    // The pinned winemetal.so was built with LC_BUILD_VERSION minos 15.0.
    // The upstream project's general Sonoma support does not apply to this archive.
    static var hostSupported: Bool { if #available(macOS 15, *) { return true }; return false }
    static let components: [RuntimeComponent] = [
        .init(name: "Wine Sikarugir 10.0_6", url: "https://github.com/Sikarugir-App/Engines/releases/download/v1.0/WS12WineSikarugir10.0_6.tar.xz", sha256: "9da7ee0cbf386522f3a9906943726d9c3c125dbbd9ab120e3cde80e88d6091b2", archivePath: "wswine.bundle", destination: "engine", license: "LGPL-2.1-or-later; Sikarugir-App/Engines", bytes: 166304096),
        .init(name: "Bibliothèques Wine", url: "https://github.com/Sikarugir-App/Wrapper/releases/download/v1.0/Template-1.0.11.tar.xz", sha256: "9fa15479e7ff6abd99c1d07be285fb95f41fc6991586502427152b1f7d6ccb8a", archivePath: "Template-1.0.11.app/Contents/Frameworks", destination: "frameworks", license: "Mixed: LGPL GStreamer/gnutls, Apache-2.0 MoltenVK; Sikarugir-App/Wrapper. Apple renderer excluded.", bytes: 84533420),
        .init(name: "DXMT", url: "https://github.com/gauthierpiarrette/highball-engine/releases/download/dxmt-highball-20261017T231707Z-331c552/dxmt-highball-20261017T231707Z-331c552.tar.gz", sha256: "89e731b81cc1ef741accb2e707159f121ed822a083f14f16da445cd8dbbf4703", archivePath: "highball", destination: "renderers/dxmt/wine", license: "MIT/LGPL notices upstream; Highball DXMT branch 331c552", bytes: 18928717)
    ]

    let root: URL
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "fr.playmelt.runtime-setup", qos: .utility)
    private var running = false, cancelled = false
    private var download: RuntimeDownload?
    private var process: Process?
    private var status = "missing", message = "Le moteur Windows de Playmelt doit être préparé."
    private var bytesDownloaded: Int64 = 0
    private var callback: (([String: Any]) -> Void)?
    private var operationDescriptor: PlaymeltRuntimeDescriptor?
    private var engineRoot: URL { root.appendingPathComponent(Self.engineID, isDirectory: true) }
    private var prefix: URL { root.appendingPathComponent("prefix", isDirectory: true) }
    private var receipt: URL { root.appendingPathComponent("prefix-ready.json") }

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Playmelt/Runtime", isDirectory: true)
    }

    func descriptor() -> PlaymeltRuntimeDescriptor {
        let frameworks = engineRoot.appendingPathComponent("frameworks").path
        let wine = engineRoot.appendingPathComponent("engine/bin/wine")
        let server = engineRoot.appendingPathComponent("engine/bin/wineserver")
        let steam = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam")
        let environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": root.appendingPathComponent("home").path,
            "TMPDIR": NSTemporaryDirectory(), "WINEPREFIX": prefix.path,
            "WINEDEBUG": "fixme-all", "WINEMSYNC": "0", "WINEESYNC": "0",
            "WINEDLLOVERRIDES": "winemenubuilder.exe=d",
            "WINEDLLPATH_PREPEND": engineRoot.appendingPathComponent("renderers/dxmt/wine").path,
            "DYLD_FALLBACK_LIBRARY_PATH": frameworks + ":" + frameworks + "/GStreamer.framework/Versions/1.0/lib",
            "DYLD_FALLBACK_FRAMEWORK_PATH": frameworks,
            "GST_PLUGIN_PATH": frameworks + "/GStreamer.framework/Versions/1.0/lib/gstreamer-1.0"
        ]
        let fm = FileManager.default
        let marker = (try? Data(contentsOf: receipt)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let ready = Self.hostSupported && marker?["engineID"] as? String == Self.engineID &&
            fm.isExecutableFile(atPath: wine.path) && fm.isExecutableFile(atPath: server.path) &&
            Self.hasRequiredEngineFiles(engineRoot) &&
            (try? Self.validatePrefix(prefix)) != nil
        let steamEXE = steam.appendingPathComponent("steam.exe")
        let header: Data? = (try? FileHandle(forReadingFrom: steamEXE)).flatMap { handle in
            defer { try? handle.close() }; return try? handle.read(upToCount: 2)
        }
        return .init(engineID: Self.engineID, wineURL: wine, wineserverURL: server, prefixURL: prefix,
                     steamRoot: steam, environment: environment, readyEngine: ready,
                     steamInstalled: ready && header == Data([0x4d, 0x5a]))
    }

    func snapshot() -> [String: Any] {
        lock.lock(); let cached = running ? operationDescriptor : nil; lock.unlock()
        // Download progress never changes the installed prefix; avoid opening registry/DLL
        // files on every progress tick. Explicit refresh outside setup remains a live read.
        let descriptor = cached ?? descriptor()
        lock.lock(); defer { lock.unlock() }
        let effectiveStatus = !running && status == "missing" && descriptor.readyEngine ? "ready" : status
        let total = Self.components.reduce(Int64(0)) { $0 + $1.bytes }
        return ["status": effectiveStatus, "progress": status == "downloading" ? Double(bytesDownloaded) / Double(total) as Any : NSNull(),
                "bytesDownloaded": bytesDownloaded, "bytesTotal": total,
                "message": effectiveStatus == "ready" ? (descriptor.steamInstalled ? "Moteur Wine, DXMT et Steam Windows présents. La connexion et les jeux restent à vérifier." : "Moteur Wine et DXMT prêt. Steam Windows doit encore être installé et connecté.") : message,
                "cancellable": running, "readyEngine": descriptor.readyEngine,
                "steamInstalled": descriptor.steamInstalled, "engineID": Self.engineID,
                "rendererConfigured": "dxmt", "rendererValidated": false]
    }

    func start(progress: @escaping ([String: Any]) -> Void,
               completion: @escaping (Result<PlaymeltRuntimeDescriptor, Error>) -> Void) {
        let before = descriptor()
        lock.lock()
        if running { lock.unlock(); DispatchQueue.main.async { completion(.failure(RuntimeSetupError.failed("Une préparation est déjà en cours."))) }; return }
        running = true; cancelled = false; callback = progress; bytesDownloaded = 0; operationDescriptor = before
        lock.unlock()
        queue.async {
            let result: Result<PlaymeltRuntimeDescriptor, Error>
            do {
                try self.prepare()
                let ready = self.descriptor()
                self.lock.lock(); self.operationDescriptor = ready; self.lock.unlock()
                result = .success(ready); self.update("ready", "Moteur prêt.")
            }
            catch { result = .failure(error); self.update(self.isCancelled ? "cancelled" : "failed", error.localizedDescription) }
            self.lock.lock(); self.running = false; self.download = nil; self.process = nil; self.operationDescriptor = nil; self.lock.unlock()
            self.emit()
            DispatchQueue.main.async { completion(result) }
        }
    }

    func cancel() {
        lock.lock(); cancelled = true; let download = self.download; let process = self.process; lock.unlock()
        download?.cancel()
        if let process, process.isRunning { process.terminate() }
    }
    /// Termination coordination: completion runs after the setup job's defer blocks, owned
    /// Wine server cleanup and staging cleanup. The app must wait for this before exiting.
    func shutdown(completion: @escaping () -> Void = {}) {
        cancel()
        queue.async { DispatchQueue.main.async { completion() } }
    }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    private func checkCancellation() throws { if isCancelled { throw RuntimeSetupError.cancelled } }
    private func update(_ status: String, _ message: String) {
        lock.lock(); self.status = status; self.message = message; lock.unlock(); emit()
    }
    private func emit() {
        lock.lock(); let callback = self.callback; lock.unlock()
        let value = snapshot(); DispatchQueue.main.async { callback?(value) }
    }

    static let requiredEngineFiles = ["engine/bin/wine", "engine/bin/wineserver",
        "engine/lib/wine/x86_64-unix/ntdll.so", "engine/lib/wine/x86_64-unix/winemac.so",
        "engine/lib/wine/x86_64-windows/kernel32.dll", "renderers/dxmt/wine/x86_64-unix/winemetal.so"] +
        ["x86_64-windows", "i386-windows"].flatMap { architecture in
            ["d3d10core.dll", "d3d11.dll", "dxgi.dll", "winemetal.dll"].map { "renderers/dxmt/wine/\(architecture)/\($0)" }
        }

    static func hasRequiredEngineFiles(_ root: URL) -> Bool {
        requiredEngineFiles.allSatisfy { relative in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(relative).path) else { return false }
            return attributes[.type] as? FileAttributeType == .typeRegular && ((attributes[.size] as? NSNumber)?.int64Value ?? 0) > 0
        }
    }

    private func prepare() throws {
        let fm = FileManager.default
        guard Self.hostSupported else { throw RuntimeSetupError.failed("Ce moteur graphique nécessite macOS 15 ou plus récent.") }
        guard FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime") else {
            throw RuntimeSetupError.failed("Rosetta 2 est requis. Sa présence doit être vérifiée avant la préparation; Playmelt ne l’installe pas automatiquement.")
        }
        for path in [root, engineRoot, prefix, receipt, root.appendingPathComponent("home")] { try Self.rejectSymlinkAncestors(path) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let setupLock = try Self.acquireSetupLock(root)
        defer { Self.releaseSetupLock(setupLock) }
        let free = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        guard free > 8_000_000_000 else { throw RuntimeSetupError.failed("Au moins 8 Go libres sont requis pour préparer le moteur et l’environnement Windows.") }
        if descriptor().readyEngine { return }
        let staging = root.appendingPathComponent(".setup-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) } // exact, newly created task-owned temporary directory only
        let assembled = staging.appendingPathComponent("assembled", isDirectory: true)
        try fm.createDirectory(at: assembled, withIntermediateDirectories: false)
        if !fm.fileExists(atPath: engineRoot.path) {
            var completed: Int64 = 0
            for component in Self.components {
                try checkCancellation()
                let archive = staging.appendingPathComponent(component.sha256 + ".archive")
                update("downloading", "Téléchargement : " + component.name)
                let previous = completed
                let transfer = RuntimeDownload(component: component, destination: archive) { count in
                    self.lock.lock(); self.bytesDownloaded = previous + count; self.lock.unlock(); self.emit()
                }
                lock.lock(); download = transfer; lock.unlock()
                try transfer.run()
                try checkCancellation()
                completed += component.bytes
                update("verifying", "Vérification SHA-256 : " + component.name)
                guard try Self.sha256(archive) == component.sha256 else { throw RuntimeSetupError.failed("L’archive ne correspond pas à l’empreinte publiée : " + component.name) }
                update("extracting", "Préparation : " + component.name)
                try extract(archive, component: component, assembled: assembled, staging: staging)
                try fm.removeItem(at: archive) // task download only; never retain/distribute the mixed archive
            }
            try linkRuntime(assembled)
            try Self.validateTree(assembled)
            guard Self.hasRequiredEngineFiles(assembled) else {
                throw RuntimeSetupError.failed("Le contenu du moteur ne correspond pas aux fichiers attendus. Aucune initialisation n’a été lancée.")
            }
            // Sikarugir carries the prepend extension; plain WineHQ does not. Refuse a
            // mismatched loader rather than silently ignoring DXMT and using WineD3D.
            try Self.validateOverlayLoader(assembled)
            let manifest: [String: Any] = ["engineID": Self.engineID, "candidate": true, "renderer": "dxmt", "appleRendererInstalled": false,
                "components": Self.components.map { ["name": $0.name, "url": $0.url, "sha256": $0.sha256, "license": $0.license] },
                "notice": "Candidate assembled independently; no game compatibility verified. Upstream license/source obligations require review before redistribution."]
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: assembled.appendingPathComponent("manifest.json"), options: .atomic)
            try checkCancellation()
            try fm.moveItem(at: assembled, to: engineRoot) // destination must be absent; no replacement/rotation
        } else {
            let stored = try Data(contentsOf: engineRoot.appendingPathComponent("manifest.json"))
            let manifest = try JSONSerialization.jsonObject(with: stored) as? [String: Any]
            guard manifest?["engineID"] as? String == Self.engineID else { throw RuntimeSetupError.failed("Un moteur différent occupe cet emplacement. Aucun fichier existant n’a été remplacé.") }
            try Self.validateTree(engineRoot)
            try Self.validateOverlayLoader(engineRoot)
        }
        try checkCancellation()
        let ownership = root.appendingPathComponent("prefix-owner.json")
        if fm.fileExists(atPath: prefix.path) {
            let data = try Data(contentsOf: ownership)
            let owner = try JSONSerialization.jsonObject(with: data) as? [String: String]
            guard owner?["engineID"] == Self.engineID, owner?["prefix"] == prefix.path else {
                throw RuntimeSetupError.failed("Cet environnement existant ne provient pas de cette préparation. Aucun fichier n’a été modifié.")
            }
        } else {
            try fm.createDirectory(at: prefix, withIntermediateDirectories: false)
            try JSONSerialization.data(withJSONObject: ["engineID": Self.engineID, "prefix": prefix.path]).write(to: ownership, options: .atomic)
        }
        // A retry never interrupts an active user game/server. The check is intentionally
        // conservative: any process from this dedicated engine holds initialization back.
        let processes = try command(URL(fileURLWithPath: "/bin/ps"), ["-axo", "pid=,comm="], timeout: 5)
        guard !processes.split(separator: "\n").contains(where: { $0.contains(engineRoot.path + "/") || $0.contains(prefix.path + "/") }) else {
            throw RuntimeSetupError.failed("Un programme utilise déjà cet environnement. Il reste actif; la préparation pourra être reprise lorsqu’il sera fermé.")
        }
        try fm.createDirectory(at: root.appendingPathComponent("home"), withIntermediateDirectories: true)
        update("initializing", "Initialisation de l’environnement Windows isolé. Aucun jeu n’est lancé.")
        let descriptor = descriptor()
        // Ownership and absence of existing engine processes were checked above. The app must
        // serialize launches while setup is initializing. A failed cleanup cannot produce ready.
        var initializationError: Error?
        do {
            _ = try command(descriptor.wineURL, ["wineboot", "-u"], environment: descriptor.environment, timeout: 180)
            try checkCancellation()
        } catch { initializationError = error }
        // wineboot may exit before wineserver flushes system.reg/user.reg. Validate only
        // after the prefix's server has shut down and released its lock, never before it.
        do {
            _ = try command(descriptor.wineserverURL, ["-k"], environment: descriptor.environment, timeout: 10, honourCancellation: false)
            _ = try command(descriptor.wineserverURL, ["-w"], environment: descriptor.environment, timeout: 10, honourCancellation: false)
        } catch {
            throw RuntimeSetupError.failed("L’arrêt des processus de préparation n’a pas été confirmé. Le moteur n’est pas marqué prêt; contrôler les processus de cet environnement avant de reprendre.")
        }
        if let initializationError { throw initializationError }
        try checkCancellation()
        try Self.validatePrefix(prefix)
        try JSONSerialization.data(withJSONObject: ["engineID": Self.engineID, "renderer": "dxmt", "initializedAt": ISO8601DateFormatter().string(from: Date())]).write(to: receipt, options: .atomic)
    }

    static func validatePrefix(_ prefix: URL) throws {
        let required: [(String, Data)] = [
            ("system.reg", Data("WINE REGISTRY Version 2".utf8)),
            ("user.reg", Data("WINE REGISTRY Version 2".utf8)),
            ("drive_c/windows/system32/kernel32.dll", Data([0x4d, 0x5a])),
            ("drive_c/windows/syswow64/kernel32.dll", Data([0x4d, 0x5a]))
        ]
        for (path, expected) in required {
            do {
                let handle = try FileHandle(forReadingFrom: prefix.appendingPathComponent(path))
                defer { try? handle.close() }
                let header = try handle.read(upToCount: expected.count) ?? Data()
                guard header == expected else { throw RuntimeSetupError.failed("invalid header") }
            } catch {
                throw RuntimeSetupError.failed("Après fermeture de Wine, le fichier Windows attendu est absent ou invalide : \(path). Les données sont conservées pour diagnostic.")
            }
        }
    }

    static func safeArchivePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0") &&
            !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }
    /// The persistent empty lock file is never removed. flock belongs to this descriptor
    /// and is released on close/process exit, so neither PID files nor age guesses are used.
    static func acquireSetupLock(_ root: URL) throws -> Int32 {
        let path = root.appendingPathComponent(".setup.lock").path
        let fd = Darwin.open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw RuntimeSetupError.failed("Impossible d’ouvrir le verrou de préparation du moteur.") }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_uid == geteuid(), metadata.st_nlink == 1 else {
            Darwin.close(fd)
            throw RuntimeSetupError.failed("Le verrou de préparation existant n’est pas un fichier régulier privé.")
        }
        guard fchmod(fd, mode_t(0o600)) == 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            throw RuntimeSetupError.failed("Une autre instance de Playmelt prépare déjà ce moteur, ou son verrou est inaccessible.")
        }
        return fd
    }
    static func releaseSetupLock(_ fd: Int32) {
        _ = flock(fd, LOCK_UN)
        Darwin.close(fd)
    }
    static func isAppleRenderer(_ path: String) -> Bool {
        let name = path.lowercased()
        return name.contains("d3dmetal") || name.split(separator: "/").contains("apple_gptk")
    }
    static func validateOverlayLoader(_ root: URL) throws {
        let ntdll = root.appendingPathComponent("engine/lib/wine/x86_64-unix/ntdll.so")
        let size = (try FileManager.default.attributesOfItem(atPath: ntdll.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 && size <= 64 * 1024 * 1024 else { throw RuntimeSetupError.failed("Le chargeur Wine attendu est absent ou invalide.") }
        let data = try Data(contentsOf: ntdll, options: .mappedIfSafe)
        guard data.range(of: Data("WINEDLLPATH_PREPEND\0".utf8)) != nil else {
            throw RuntimeSetupError.failed("Ce moteur Wine ne fournit pas le chargement des overlays requis par DXMT. Aucun jeu ne sera lancé.")
        }
    }
    static func rejectSymlinkAncestors(_ url: URL) throws {
        var part = url.standardizedFileURL
        while part.path != "/" {
            if let value = try? part.resourceValues(forKeys: [.isSymbolicLinkKey]), value.isSymbolicLink == true {
                throw RuntimeSetupError.failed("Le dossier du moteur ne peut pas traverser un lien symbolique.")
            }
            part.deleteLastPathComponent()
        }
    }
    static func validateTree(_ root: URL) throws {
        let base = root.standardizedFileURL.path + "/"
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { throw RuntimeSetupError.failed("Impossible de contrôler le contenu extrait.") }
        for case let url as URL in entries {
            if isAppleRenderer(String(url.path.dropFirst(base.count))) { throw RuntimeSetupError.failed("Un composant D3DMetal a été détecté; cette préparation est refusée.") }
            if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
                guard !target.hasPrefix("/"), url.resolvingSymlinksInPath().path.hasPrefix(base) else {
                    throw RuntimeSetupError.failed("Un lien extrait pointe hors du moteur. Cette préparation est refusée.")
                }
            }
        }
    }
    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func extract(_ archive: URL, component: RuntimeComponent, assembled: URL, staging: URL) throws {
        let names = try command(URL(fileURLWithPath: "/usr/bin/tar"), ["-tf", archive.path], timeout: 60)
            .split(separator: "\n").map(String.init)
        guard !names.isEmpty, names.allSatisfy(Self.safeArchivePath) else { throw RuntimeSetupError.failed("L’archive contient des chemins non autorisés.") }
        let scratch = staging.appendingPathComponent("extract-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: scratch) }
        // bsdtar's default traversal/symlink protections stay on; never use -P or -U.
        _ = try command(URL(fileURLWithPath: "/usr/bin/tar"), ["--safe-writes", "--no-same-owner", "--exclude=*d3dmetal*", "--exclude=*D3DMetal*", "--exclude=*/apple_gptk", "--exclude=*/apple_gptk/*", "-xf", archive.path, "-C", scratch.path, "--", component.archivePath], timeout: 120)
        try Self.validateTree(scratch)
        let source = scratch.appendingPathComponent(component.archivePath)
        guard FileManager.default.fileExists(atPath: source.path) else { throw RuntimeSetupError.failed("Le dossier attendu est absent de l’archive : " + component.name) }
        let destination = assembled.appendingPathComponent(component.destination)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: source, to: destination)
        // Preserve license/notice text shipped outside the selected subtree too, without executing it.
        let licenses = names.filter { name in
            let leaf = URL(fileURLWithPath: name).lastPathComponent.lowercased()
            return !name.hasSuffix("/") && !Self.isAppleRenderer(name) && ["license", "copying", "notice"].contains(where: { leaf.hasPrefix($0) })
        }
        let noticeRoot = assembled.appendingPathComponent("licenses/" + component.sha256)
        try FileManager.default.createDirectory(at: noticeRoot, withIntermediateDirectories: true)
        for (index, name) in licenses.prefix(40).enumerated() {
            let content = try command(URL(fileURLWithPath: "/usr/bin/tar"), ["-xOf", archive.path, "--", name], timeout: 20)
            try Data(content.utf8).write(to: noticeRoot.appendingPathComponent("\(index)-" + URL(fileURLWithPath: name).lastPathComponent), options: .atomic)
        }
    }
    private func linkRuntime(_ root: URL) throws {
        let fm = FileManager.default, lib = root.appendingPathComponent("engine/lib")
        for sub in ["frameworks", "frameworks/GStreamer.framework/Versions/1.0/lib"] {
            for entry in (try? fm.contentsOfDirectory(at: root.appendingPathComponent(sub), includingPropertiesForKeys: nil)) ?? [] where entry.pathExtension == "dylib" {
                let destination = lib.appendingPathComponent(entry.lastPathComponent)
                if (try? fm.attributesOfItem(atPath: destination.path)) == nil {
                    try fm.createSymbolicLink(atPath: destination.path, withDestinationPath: "../../" + sub + "/" + entry.lastPathComponent)
                }
            }
        }
        let framework = lib.appendingPathComponent("GStreamer.framework")
        if (try? fm.attributesOfItem(atPath: framework.path)) == nil {
            try fm.createSymbolicLink(atPath: framework.path, withDestinationPath: "../../frameworks/GStreamer.framework")
        }
    }
    private func command(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil,
                         timeout: TimeInterval, honourCancellation: Bool = true) throws -> String {
        if honourCancellation { try checkCancellation() }
        let process = Process(), output = Pipe()
        process.executableURL = executable; process.arguments = arguments
        process.environment = environment ?? ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0), readLock = NSLock()
        var data = Data(), overflow = false
        try process.run()
        lock.lock(); self.process = process; lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            while let chunk = try? output.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
                readLock.lock()
                if data.count + chunk.count <= 8 * 1024 * 1024 { data.append(chunk) } else { overflow = true }
                readLock.unlock()
            }
            done.signal()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline && !(honourCancellation && isCancelled) { Thread.sleep(forTimeInterval: 0.05) }
        let expired = process.isRunning
        if expired {
            process.terminate()
            let grace = Date().addingTimeInterval(2)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        _ = done.wait(timeout: .now() + 2)
        try? output.fileHandleForReading.close()
        lock.lock(); self.process = nil; lock.unlock()
        if honourCancellation { try checkCancellation() }
        guard !expired, process.terminationStatus == 0 else { throw RuntimeSetupError.failed("La commande \(executable.lastPathComponent) a échoué (code \(process.terminationStatus)). Aucune protection macOS n’a été désactivée.") }
        readLock.lock(); let result = data; let tooLarge = overflow; readLock.unlock()
        guard !tooLarge else { throw RuntimeSetupError.failed("La sortie de contrôle dépasse la limite autorisée.") }
        return String(decoding: result, as: UTF8.self)
    }
}

private final class RuntimeDownload: NSObject, URLSessionDownloadDelegate {
    private let component: RuntimeComponent, destination: URL, progress: (Int64) -> Void
    private let lock = NSLock(), done = DispatchSemaphore(value: 0)
    private var session: URLSession?, task: URLSessionDownloadTask?, result: Error?, cancelled = false, saved = false
    private var lastProgress = Date.distantPast
    init(component: RuntimeComponent, destination: URL, progress: @escaping (Int64) -> Void) {
        self.component = component; self.destination = destination; self.progress = progress
    }
    func cancel() { lock.lock(); cancelled = true; let task = self.task; lock.unlock(); task?.cancel() }
    func run() throws {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45; config.timeoutIntervalForResource = 1800
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        let task = session.downloadTask(with: URL(string: component.url)!)
        lock.lock(); self.session = session; self.task = task; let cancelled = self.cancelled; lock.unlock()
        defer { session.invalidateAndCancel(); self.session = nil }
        guard !cancelled else { throw RuntimeSetupError.cancelled }
        task.resume()
        let deadline = Date().addingTimeInterval(1805)
        while done.wait(timeout: .now() + 0.25) != .success {
            lock.lock(); let cancelled = self.cancelled; lock.unlock()
            if cancelled {
                task.cancel()
                _ = done.wait(timeout: .now() + 5)
                throw RuntimeSetupError.cancelled
            }
            if Date() >= deadline { cancel(); throw RuntimeSetupError.failed("Le téléchargement a dépassé le délai autorisé.") }
        }
        lock.lock(); let error = result; let saved = self.saved; lock.unlock()
        if let error { throw error }
        guard saved else { throw RuntimeSetupError.failed("L’archive téléchargée est absente.") }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > component.bytes { downloadTask.cancel(); return }
        if Date().timeIntervalSince(lastProgress) >= 0.15 || totalBytesWritten == component.bytes {
            lastProgress = Date(); progress(totalBytesWritten)
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            lock.lock(); let cancelled = self.cancelled; lock.unlock()
            guard !cancelled else { throw RuntimeSetupError.cancelled }
            guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200,
                  (try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value == component.bytes else {
                throw RuntimeSetupError.failed("La taille ou la réponse du téléchargement est incorrecte : " + component.name)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            lock.lock(); saved = true; lock.unlock()
        } catch { lock.lock(); result = error; lock.unlock() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); if result == nil { result = error }; lock.unlock(); done.signal()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let host = request.url?.host?.lowercased() ?? ""
        let allowed = request.url?.scheme == "https" && (host == "github.com" || host == "release-assets.githubusercontent.com" || host == "objects.githubusercontent.com")
        completionHandler(allowed ? request : nil)
    }
}
