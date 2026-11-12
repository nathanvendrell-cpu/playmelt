import CryptoKit
import Foundation

/// Pont DLSS → MetalFX : composant moteur Playmelt.
///
/// Installe les shims NVIDIA du Game Porting Toolkit 4 d'Apple
/// (`nvngx-on-metalfx.dll` → `nvngx.dll`, `nvapi64.dll` et les équivalents
/// unix) dans un répertoire dédié, séparé du payload D3DMetal hashé.
/// Au lancement d'un jeu D3DMetal, le répertoire `wine` du composant est
/// ajouté à `WINEDLLPATH_PREPEND` et `D3DM_ENABLE_METALFX=1` traduit les
/// appels DLSS vers MetalFX — sans jamais modifier le payload Apple.
///
/// Sources acceptées (sélection locale de l'utilisateur) :
/// - le DMG « Game Porting Toolkit 4 » (montage lecture seule, DMG imbriqué
///   « Evaluation environment for Windows games » géré automatiquement) ;
/// - un dossier extrait contenant `redist/lib` ou `lib`.
///
/// Les `.so` unix de GPTK sont des liens vers `external/libd3dshared.dylib` :
/// le composant crée ses propres liens relatifs vers la copie du payload
/// D3DMetal importé, pour n'exister qu'en un seul exemplaire par licence.
/// Le composant est lié à la version du payload : un réimport D3DMetal
/// différent l'invalide honnêtement jusqu'à réinstallation.
final class NvidiaBridgeStore {
    static let shared = NvidiaBridgeStore()

    private struct RequiredFile {
        let relative: String
        let sources: [String]
        /// `.so` unix : lien symbolique vers libd3dshared.dylib du payload.
        let isSharedLibraryLink: Bool
    }

    /// Les shims PE (forwarders Windows) sont copiés depuis la source GPTK.
    private let requiredWindowsFiles: [RequiredFile] = [
        RequiredFile(relative: "wine/x86_64-windows/nvngx.dll",
                     sources: ["nvngx-on-metalfx.dll", "nvngx.dll"], isSharedLibraryLink: false),
        RequiredFile(relative: "wine/x86_64-windows/nvapi64.dll",
                     sources: ["nvapi64.dll"], isSharedLibraryLink: false),
    ]
    /// Les modules unix de GPTK sont des liens vers libd3dshared.dylib : le
    /// composant crée les siens, pointant vers la copie unique du payload.
    private let sharedLibraryLinks: [(relative: String, required: Bool)] = [
        ("wine/x86_64-unix/nvngx.so", true),
        ("wine/x86_64-unix/nvapi64.so", false),
    ]

    private let lock = NSLock()
    private var cached: [String: Any]?
    private var busy = false
    let root: URL
    private var renderersRoot: URL { root.deletingLastPathComponent() }
    private var receiptURL: URL { root.appendingPathComponent("receipt.json") }
    /// La copie unique de la bibliothèque partagée Apple reste dans le payload
    /// D3DMetal : les `.so` du pont y pointent, jamais de copie.
    private var sharedLibraryURL: URL {
        renderersRoot.appendingPathComponent("D3DMetal/payload/external/libd3dshared.dylib")
    }
    private var payloadReceiptURL: URL {
        renderersRoot.appendingPathComponent("D3DMetal/payload/receipt.json")
    }
    var winePath: String { root.appendingPathComponent("wine").path }

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Playmelt/Renderers/NvidiaBridge", isDirectory: true)
        cached = Self.readObject(receiptURL)
    }

    // MARK: État

    /// Le pont est utilisable quand : receipt présent et conforme, la
    /// bibliothèque partagée du payload existe, chaque fichier requis
    /// correspond toujours à son SHA-256, et le payload D3DMetal est
    /// exactement celui qui était présent lors de l'installation.
    func available() -> Bool {
        lock.lock(); let report = cached; lock.unlock()
        guard let report,
              let files = report["files"] as? [[String: Any]], !files.isEmpty,
              let payloadHash = report["d3dmetalContentHash"] as? String else { return false }
        guard let shared = resolvedSharedLibrary() else { return false }
        // Aucune évasion hors du répertoire de données Playmelt (liens .so résolus).
        let allowed = renderersRoot.deletingLastPathComponent()
            .standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard shared.path.hasPrefix(allowed) else { return false }
        guard currentPayloadHash() == payloadHash else { return false }
        var expected: [String: String] = [:]
        for file in files {
            guard let path = file["path"] as? String, let sha = file["sha256"] as? String,
                  !path.isEmpty, !path.hasPrefix("/"), !path.contains("..") else { return false }
            expected[path] = sha
        }
        for required in requiredWindowsFiles {
            guard let sha = expected[required.relative] else { return false }
            let url = root.appendingPathComponent(required.relative)
            guard (try? Self.hash(url)) == sha else { return false }
        }
        for link in sharedLibraryLinks where link.required {
            guard let sha = expected[link.relative] else { return false }
            let url = root.appendingPathComponent(link.relative)
            guard (try? Self.hash(url)) == sha else { return false }
        }
        return true
    }

    private func resolvedSharedLibrary() -> URL? {
        let url = sharedLibraryURL.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue, (try? Self.machOArchitecture(url)) != nil else { return nil }
        return url
    }

    func status() -> [String: Any] {
        lock.lock(); let report = cached; let installing = busy; lock.unlock()
        let ok = available()
        let message: String
        if installing {
            message = "Installation du pont DLSS → MetalFX…"
        } else if ok {
            message = "Pont DLSS → MetalFX installé (\(report?["version"] as? String ?? "GPTK 4")). Les jeux D3DMetal peuvent charger le module DLSS."
        } else if report != nil {
            message = "Pont DLSS → MetalFX invalide (payload D3DMetal changé ou fichiers modifiés). Réinstallez-le depuis le DMG GPTK 4."
        } else {
            message = "Pont DLSS → MetalFX absent. Sélectionnez le DMG Game Porting Toolkit 4 (ou son dossier redist/lib) pour l'installer."
        }
        return ["available": ok, "busy": installing, "version": report?["version"] ?? "",
                "importedAt": report?["importedAt"] ?? "", "message": message,
                "source": report != nil ? "engine-component" : "absent"]
    }

    private func currentPayloadHash() -> String? {
        guard let report = Self.readObject(payloadReceiptURL) else { return nil }
        return report["contentHash"] as? String
    }

    // MARK: Installation

    /// Installe le pont depuis un DMG GPTK 4 ou un dossier extrait.
    /// Retourne un message utilisateur ; lance toujours onUpdate à la fin.
    func install(source: URL, completion: @escaping (Bool, String) -> Void) {
        lock.lock()
        guard !busy else { lock.unlock(); completion(false, "Une installation du pont est déjà en cours."); return }
        busy = true; lock.unlock()
        let finish: (Bool, String) -> Void = { [weak self] ok, message in
            guard let self else { return }
            self.lock.lock(); self.busy = false; self.lock.unlock()
            DispatchQueue.main.async { completion(ok, message) }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let message = try self.performInstall(source: source)
                finish(true, message)
            } catch {
                finish(false, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    private func performInstall(source rawSource: URL) throws -> String {
        let fm = FileManager.default
        guard currentPayloadHash() != nil, fm.fileExists(atPath: sharedLibraryURL.path) else {
            throw bridgeFailure("Importez d'abord le composant Apple D3DMetal : le pont s'appuie sur sa bibliothèque partagée.")
        }
        var mounted: [URL] = []
        defer { for volume in mounted.reversed() { Self.detach(volume) } }

        var source = rawSource.standardizedFileURL
        if source.pathExtension.lowercased() == "dmg" {
            let (_, mount) = try Self.attachDMG(source)
            mounted.append(mount)
            // Le DMG GPTK contient un DMG imbriqué « Evaluation environment… ».
            if let nested = Self.findNestedDMG(in: mount) {
                let (innerLib, nestedMount) = try Self.attachDMG(nested)
                mounted.append(nestedMount)
                source = innerLib
            } else {
                source = mount
            }
        }
        guard let lib = try Self.locateLibDirectory(source) else {
            throw bridgeFailure("Le dossier sélectionné ne contient pas wine/x86_64-windows avec les shims NVIDIA. Sélectionnez le DMG GPTK 4 ou son dossier redist/lib extrait.")
        }

        // 1. Localisation + vérification des shims PE requis.
        let windowsDir = lib.appendingPathComponent("wine/x86_64-windows", isDirectory: true)
        var stagedSources: [(RequiredFile, URL)] = []
        for required in requiredWindowsFiles {
            guard let file = required.sources.lazy
                .map({ windowsDir.appendingPathComponent($0) })
                .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                throw bridgeFailure("Shim NVIDIA manquant dans la source : \(required.sources.joined(separator: " ou ")).")
            }
            try Self.checkWindowsShim(file)
            stagedSources.append((required, file))
        }
        guard let shared = resolvedSharedLibrary() else {
            throw bridgeFailure("La bibliothèque partagée du payload D3DMetal est illisible.")
        }

        // 2. Installation atomique dans un répertoire de staging.
        let staging = renderersRoot.appendingPathComponent(".bridge-staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var installedReport: [[String: Any]] = []
        do {
            for (required, file) in stagedSources {
                let target = staging.appendingPathComponent(required.relative)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try fm.copyItem(at: file, to: target)
                let sha = try Self.hash(target)
                installedReport.append(["path": required.relative, "sha256": sha,
                                        "bytes": (try fm.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value ?? 0,
                                        "sourceName": file.lastPathComponent])
            }
            for link in sharedLibraryLinks {
                let target = staging.appendingPathComponent(link.relative)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let relativeTarget = "../../../D3DMetal/payload/external/\(shared.lastPathComponent)"
                try fm.createSymbolicLink(atPath: target.path, withDestinationPath: relativeTarget)
                if link.required {
                    installedReport.append(["path": link.relative, "sha256": try Self.hash(target), "bytes": 0,
                                            "sourceName": "-> \(relativeTarget)"])
                }
            }
            let payloadHash = currentPayloadHash() ?? ""
            let version = Self.readObject(payloadReceiptURL)?["version"] as? String ?? "GPTK 4"
            let report: [String: Any] = [
                "schema": 1,
                "importedAt": ISO8601DateFormatter().string(from: Date()),
                "version": version,
                "d3dmetalContentHash": payloadHash,
                "sharedLibrary": "D3DMetal/payload/external/\(shared.lastPathComponent)",
                "files": installedReport,
            ]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: staging.appendingPathComponent("receipt.json"), options: .atomic)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }

        // 3. Bascule : ancien composant de côté, staging en place.
        let old = root.appendingPathComponent(".old-\(UUID().uuidString)")
        if fm.fileExists(atPath: root.path) { try? fm.moveItem(at: root, to: old) }
        do {
            try fm.moveItem(at: staging, to: root)
        } catch {
            if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: root.path) {
                try? fm.moveItem(at: old, to: root)
            }
            try? fm.removeItem(at: staging)
            throw bridgeFailure("Impossible d'installer le pont : \(error.localizedDescription)")
        }
        try? fm.removeItem(at: old)
        lock.lock(); cached = Self.readObject(receiptURL); lock.unlock()
        let shims = stagedSources.map { $0.1.lastPathComponent }.joined(separator: ", ")
        return "Pont DLSS → MetalFX installé (\(shims)). Choisissez le backend « D3DMetal · DLSS → MetalFX » dans les Paramètres d'un jeu."
    }

    // MARK: Localisation de la source

    /// Trouve le dossier `lib` contenant `wine/x86_64-windows` avec un shim.
    private static func locateLibDirectory(_ source: URL) throws -> URL? {
        let fm = FileManager.default
        var candidates = [source, source.appendingPathComponent("redist/lib"), source.appendingPathComponent("lib")]
        if let entries = try? fm.contentsOfDirectory(atPath: source.path) {
            for entry in entries.prefix(50) {
                let child = source.appendingPathComponent(entry)
                candidates.append(child.appendingPathComponent("redist/lib"))
                candidates.append(child.appendingPathComponent("lib"))
                candidates.append(child)
            }
        }
        for candidate in candidates {
            let windows = candidate.appendingPathComponent("wine/x86_64-windows")
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: windows.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let hasShim = requiredShimNames.contains { fm.fileExists(atPath: windows.appendingPathComponent($0).path) }
            if hasShim { return candidate }
        }
        return nil
    }

    private static let requiredShimNames = ["nvngx-on-metalfx.dll", "nvngx.dll"]

    /// Cherche un DMG imbriqué (« Evaluation environment for Windows games… »)
    /// dans un volume monté, avec des bornes d'énumération strictes.
    private static func findNestedDMG(in mount: URL) -> URL? {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: mount, includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsPackageDescendants]) else { return nil }
        var visited = 0
        var fallback: URL?
        while let file = walker.nextObject() as? URL {
            visited += 1
            if visited > 800 || walker.level > 6 { break }
            guard file.pathExtension.lowercased() == "dmg" else { continue }
            let name = file.lastPathComponent.lowercased()
            if name.contains("evaluation environment") { return file }
            fallback = fallback ?? file
        }
        return fallback
    }

    // MARK: Vérifications

    /// Les shims PE sont de petits forwarders x86_64.
    private static func checkWindowsShim(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.standardizedFileURL.resolvingSymlinksInPath().path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              size > 16, size <= 64_000_000 else { throw bridgeFailure("Le shim NVIDIA n'est pas un fichier PE régulier.") }
        guard FileManager.default.fileExists(atPath: url.path) else { throw bridgeFailure("Shim NVIDIA illisible.") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let mz = try handle.read(upToCount: 0x40) ?? Data()
        guard mz.count >= 0x40, mz.prefix(2) == Data("MZ".utf8) else { throw bridgeFailure("Le shim NVIDIA n'est pas un exécutable Windows valide.") }
        try handle.seek(toOffset: 0x3C)
        let pointerBytes = try handle.read(upToCount: 4) ?? Data()
        guard pointerBytes.count == 4 else { throw bridgeFailure("En-tête PE du shim NVIDIA illisible.") }
        let pointer = pointerBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        try handle.seek(toOffset: UInt64(pointer))
        let pe = try handle.read(upToCount: 6) ?? Data()
        guard pe.count == 6, pe.prefix(4) == Data("PE\u{0}\u{0}".utf8) else { throw bridgeFailure("En-tête PE du shim NVIDIA invalide.") }
        let machine = pe.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt16.self) }
        guard machine == 0x8664 else { throw bridgeFailure("Le shim NVIDIA n'est pas un binaire x86_64.") }
    }

    /// Le `.so` unix doit être un Mach-O (libd3dshared.dylib du payload).
    private static func machOArchitecture(_ url: URL) throws -> UInt32 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let magic = try handle.read(upToCount: 4) ?? Data()
        guard magic.count == 4 else { throw bridgeFailure("Bibliothèque partagée illisible.") }
        let value = magic.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let known: Set<UInt32> = [0xFEEDFACF, 0xCFFAEDFE, 0xFEEDFACE, 0xCAFEBABE, 0xBEBAFECA]
        guard known.contains(value) else { throw bridgeFailure("La bibliothèque partagée du payload n'est pas un binaire Mach-O.") }
        return value
    }

    // MARK: DMG

    private static func attachDMG(_ dmg: URL) throws -> (libCandidate: URL, mount: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", dmg.path, "-readonly", "-nobrowse", "-verify", "no"]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { throw bridgeFailure("Impossible de monter le DMG : \(error.localizedDescription)") }
        guard Self.waitFor(process, seconds: 120) else {
            process.terminate()
            throw bridgeFailure("Le montage du DMG a expiré.")
        }
        guard process.terminationStatus == 0 else {
            let message = String(data: (try? err.fileHandleForReading.readDataToEndOfFile()) ?? Data(), encoding: .utf8) ?? ""
            throw bridgeFailure("Montage du DMG impossible. \(message.suffix(160))".trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let output = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let mount = output.split(separator: "\n")
            .compactMap({ line -> String? in
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                return parts.count >= 3 && parts[2].hasPrefix("/") ? parts[2] : nil
            }).last,
            let mountURL = URL(string: "file://" + mount.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!) else {
            throw bridgeFailure("Point de montage du DMG introuvable.")
        }
        return (mountURL, mountURL)
    }

    private static func detach(_ mount: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mount.path, "-force"]
        try? process.run()
        _ = waitFor(process, seconds: 30)
    }

    private static func waitFor(_ process: Process, seconds: Double) -> Bool {
        let group = DispatchGroup()
        group.enter()
        process.terminationHandler = { _ in group.leave() }
        return group.wait(timeout: .now() + seconds) == .success
    }

    // MARK: Registre du préfixe Wine

    /// UE4 (plugin NGX) résout nvngx via HKLM\Software\NVIDIA Corporation\Global\NGXCore.
    /// Écriture idempotente dans system.reg, sans jamais réécrire le fichier si présent.
    func ensurePrefixRegistryKeys(_ prefix: URL) {
        let systemReg = prefix.appendingPathComponent("system.reg")
        guard let content = try? String(contentsOf: systemReg, encoding: .utf8) else { return }
        guard !content.contains("NVIDIA Corporation\\\\Global\\\\NGXCore") else { return }
        let block = """

        [Software\\\\NVIDIA Corporation\\\\Global\\\\NGXCore] 1794440000
        #time=1dd713d1b54194e
        "FullPath"="C:\\\\windows\\\\system32"

        """
        let updated = content + block
        try? updated.write(to: systemReg, atomically: true, encoding: .utf8)
    }

    // MARK: Outils

    private static func readObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func hash(_ url: URL) throws -> String {
        var hasher = CryptoKit.SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

func bridgeFailure(_ text: String) -> RuntimeSetupError { .failed(text) }
