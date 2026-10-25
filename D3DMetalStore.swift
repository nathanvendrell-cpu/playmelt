import Foundation
import CryptoKit
import Darwin

struct D3DMetalLaunchPlan {
    let wineURL: URL
    let prefixURL: URL
    let steamRoot: URL
    let environment: [String: String]
    let rendererHash: String
    let engineID: String
    let engineFingerprint: String
    let blockedReasons: [String]
    var canExecute: Bool { blockedReasons.isEmpty }
    var json: [String: Any] {
        ["renderer": "d3dmetal", "graphicsAPI": "DirectX 12", "rendererHash": rendererHash,
         "engineID": engineID, "prefixIsolated": true, "canExecute": canExecute,
         "blockedReasons": blockedReasons, "loadTested": false, "gameTested": false]
    }
}

struct D3DMetalProbeRequest {
    let nonce: String
    let rendererHash: String
    let engineID: String
    let executableHash: String
    let executableURL: URL
    let plan: D3DMetalLaunchPlan
    var arguments: [String] { [executableURL.path, "--nonce", nonce] }
}

/// Optional, user-supplied Apple payload. No network, process execution, EULA
/// acceptance, binary patching, quarantine removal or application-bundle import.
final class D3DMetalStore {
    static let sources = [
        "https://github.com/apple/homebrew-apple/blob/2bc44284e24d39ed64d6f492a0e1f4c47a5ced08/Formula/game-porting-toolkit.rb",
        "https://github.com/gauthierpiarrette/highball/blob/bbada878d142521a3267f0818a09cd62111b5789/Sources/HighballKit/Bottle.swift",
        "https://github.com/gauthierpiarrette/highball/blob/bbada878d142521a3267f0818a09cd62111b5789/spike/engine-manifest.json"
    ]
    let root: URL
    private let stateLock = NSLock(), importLock = NSLock()
    private var cached: [String: Any]?
    private let writeReceipt: (Data, URL) throws -> Void
    private var pendingProbes: [String: D3DMetalProbeRequest] = [:]
    private var payload: URL { root.appendingPathComponent("payload", isDirectory: true) }
    private var receipt: URL { payload.appendingPathComponent("receipt.json") }
    private var isolatedRoot: URL { root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Runtime/D3DMetal", isDirectory: true) }
    init(root: URL? = nil, writeReceipt: @escaping (Data, URL) throws -> Void = { data, url in try data.write(to: url, options: .withoutOverwriting) }) {
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Playmelt/Renderers/D3DMetal", isDirectory: true)
        self.writeReceipt = writeReceipt
        cached = Self.readObject(receipt)
    }
    func snapshot() -> [String: Any] {
        stateLock.lock(); let report = cached; stateLock.unlock()
        guard let report, let hash = report["contentHash"] as? String,
              FileManager.default.fileExists(atPath: payload.path), FileManager.default.fileExists(atPath: receipt.path) else {
            return ["status": "missing", "message": "Importez les fichiers Apple D3DMetal pour préparer DirectX 12.",
                    "imported": false, "abiStatus": "not-checked", "loadTested": false, "gameTested": false]
        }
        return ["status": "imported", "message": "D3DMetal importé. Validation Wine et DirectX 12 restante.",
                "imported": true, "abiStatus": "unverified", "loadTested": false, "gameTested": false,
                "contentHash": hash, "version": report["version"] ?? "unknown", "licenseAcceptedByPlaymelt": false]
    }
    func inspect(sourceURL: URL) throws -> [String: Any] { try inspectFiles(sourceURL).report }

    @discardableResult
    func importLocal(sourceURL: URL) throws -> [String: Any] {
        guard importLock.try() else { throw Self.failure("Un import D3DMetal est déjà en cours.") }
        defer { importLock.unlock() }
        let inspected = try inspectFiles(sourceURL)
        try RuntimeSetup.rejectSymlinkAncestors(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lockPath = root.appendingPathComponent(".import.lock")
        let fd = Darwin.open(lockPath.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw Self.failure("Le verrou d’import D3DMetal est indisponible.") }
        defer { _ = flock(fd, LOCK_UN); close(fd) }
        var lockInfo = stat()
        guard fstat(fd, &lockInfo) == 0, lockInfo.st_mode & S_IFMT == S_IFREG,
              lockInfo.st_uid == geteuid(), lockInfo.st_nlink == 1, lockInfo.st_mode & 0o077 == 0 else { throw Self.failure("Le verrou d’import D3DMetal n’est pas un fichier privé régulier.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Self.failure("Un autre import D3DMetal est déjà en cours.") }
        let existing = Self.readObject(receipt)
        if FileManager.default.fileExists(atPath: payload.path) || existing != nil {
            guard let existing, existing["contentHash"] as? String == inspected.report["contentHash"] as? String,
                  try verifyPayload(existing) else { throw Self.failure("Un import D3DMetal différent ou incomplet existe déjà. Aucun fichier n’a été remplacé.") }
            stateLock.lock(); cached = existing; stateLock.unlock(); return existing
        }
        let staging = root.appendingPathComponent(".import-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) } // only this new, exact temporary directory
        for item in inspected.files {
            let target = staging.appendingPathComponent(item.relative)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: item.source, to: target)
            guard try Self.hash(target) == item.hash else { throw Self.failure("Les fichiers D3DMetal ont changé pendant l’import.") }
        }
        // Copy canonical regular files. Framework alias links remain relative and
        // inside this payload; their targets were validated before any copy.
        for link in inspected.links {
            let target = staging.appendingPathComponent(link.relative)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: link.target)
        }
        var report = inspected.report
        report["importedAt"] = ISO8601DateFormatter().string(from: Date())
        // The receipt travels in the same atomic directory rename as its payload.
        // A failed receipt write leaves only our temporary directory to clean up.
        try writeReceipt(JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), staging.appendingPathComponent("receipt.json"))
        try FileManager.default.moveItem(at: staging, to: payload)
        stateLock.lock(); cached = report; stateLock.unlock(); return report
    }

    /// Concrete, isolated candidate configuration. It is deliberately not an
    /// executable route: static structure cannot validate Wine's bridge ABI.
    func launchPlan(base: PlaymeltRuntimeDescriptor) throws -> D3DMetalLaunchPlan {
        stateLock.lock(); let report = cached; stateLock.unlock()
        guard let report, let hash = report["contentHash"] as? String, try verifyPayload(report) else { throw Self.failure("Import D3DMetal absent ou modifié.") }
        let prefix = isolatedRoot.appendingPathComponent("prefix", isDirectory: true)
        guard prefix.standardizedFileURL.resolvingSymlinksInPath() != base.prefixURL.standardizedFileURL.resolvingSymlinksInPath(),
              !Self.forbiddenPath(prefix), !Self.forbiddenPath(base.wineURL) else { throw Self.failure("Le préfixe DirectX 12 doit être indépendant.") }
        try RuntimeSetup.rejectSymlinkAncestors(prefix)
        let external = payload.appendingPathComponent("external").path
        let overlay = payload.appendingPathComponent("wine").path
        let baseLibraries = base.environment["DYLD_FALLBACK_LIBRARY_PATH"] ?? ""
        let baseFrameworks = base.environment["DYLD_FALLBACK_FRAMEWORK_PATH"] ?? ""
        for path in (baseLibraries + ":" + baseFrameworks).split(separator: ":") {
            if Self.forbiddenPath(URL(fileURLWithPath: String(path))) || Self.isDXMTOverlay(String(path)) { throw Self.failure("Une bibliothèque d’un autre moteur apparaît dans le plan DirectX 12.") }
        }
        var env: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": isolatedRoot.appendingPathComponent("home").path,
            "TMPDIR": NSTemporaryDirectory(), "WINEPREFIX": prefix.path, "WINEDEBUG": "fixme-all",
            "WINEMSYNC": "0", "WINEESYNC": "0", "WINEDLLOVERRIDES": "winemenubuilder.exe=d",
            "WINEDLLPATH_PREPEND": overlay, "CX_D3DMETALPATH": external,
            "DYLD_FALLBACK_LIBRARY_PATH": ([external, baseLibraries].filter { !$0.isEmpty }).joined(separator: ":"),
            "DYLD_FALLBACK_FRAMEWORK_PATH": ([external, baseFrameworks].filter { !$0.isEmpty }).joined(separator: ":")
        ]
        if let plugins = base.environment["GST_PLUGIN_PATH"], !Self.forbiddenPath(URL(fileURLWithPath: plugins)), !Self.isDXMTOverlay(plugins) { env["GST_PLUGIN_PATH"] = plugins }
        var reasons = ["Le contrat ABI entre cet import Apple et ce Wine doit encore être validé."]
        reasons.append("Les composants graphiques 32 bits de ce préfixe restent à qualifier ; aucun overlay DXMT n’y est ajouté.")
        let engine = base.wineURL.deletingLastPathComponent().deletingLastPathComponent()
        let searchRoots = [payload.appendingPathComponent("external"), engine.appendingPathComponent("lib/wine/x86_64-unix"), engine.appendingPathComponent("lib")] +
            (baseLibraries + ":" + baseFrameworks).split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        var unresolved = Set<String>()
        for image in report["machO"] as? [[String: Any]] ?? [] {
            guard let path = (image["resolvedPath"] ?? image["path"]) as? String, Self.safeRelative(path) else { continue }
            for name in image["dependencies"] as? [String] ?? [] {
                if name.hasPrefix("/System/Library/") || name.hasPrefix("/usr/lib/") { continue }
                let candidates: [URL]
                if name.hasPrefix("@rpath/") { candidates = searchRoots.map { $0.appendingPathComponent(String(name.dropFirst(7))) } }
                else if name.hasPrefix("@loader_path/") { candidates = [payload.appendingPathComponent(path).deletingLastPathComponent().appendingPathComponent(String(name.dropFirst(13)))] }
                else if name.hasPrefix("@executable_path/") { candidates = [base.wineURL.deletingLastPathComponent().appendingPathComponent(String(name.dropFirst(17)))] }
                else { candidates = [] }
                if !candidates.contains(where: { FileManager.default.fileExists(atPath: $0.standardizedFileURL.path) }) { unresolved.insert(name) }
            }
        }
        if !unresolved.isEmpty { reasons.append("Dépendances natives non résolues : " + unresolved.sorted().joined(separator: ", ")) }
        if !base.readyEngine { reasons.append("Le moteur Wine de base n’est pas prêt.") }
        if (try? RuntimeSetup.validatePrefix(prefix)) == nil { reasons.append("Le préfixe DirectX 12 indépendant n’est pas initialisé.") }
        if report["hostOSCompatible"] as? Bool != true { reasons.append("La version minimale de macOS des fichiers importés n’est pas satisfaite.") }
        return .init(wineURL: base.wineURL, prefixURL: prefix, steamRoot: prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam"),
                     environment: env, rendererHash: hash, engineID: base.engineID,
                     engineFingerprint: try Self.engineFingerprint(base.wineURL), blockedReasons: reasons)
    }

    /// Prepares a request for the supplied *compiled* probe, never executes it.
    /// A future explicit native validation action must initialize this isolated
    /// prefix, prove it idle, execute the exact command, enforce a timeout and
    /// clean up only its own Wine processes before recording the response.
    func prepareProbe(base: PlaymeltRuntimeDescriptor, executableURL: URL) throws -> D3DMetalProbeRequest {
        let plan = try launchPlan(base: base)
        try Self.checkPE64(executableURL)
        guard !Self.forbiddenPath(executableURL) else { throw Self.failure("Emplacement de sonde non autorisé.") }
        let request = D3DMetalProbeRequest(nonce: UUID().uuidString, rendererHash: plan.rendererHash, engineID: base.engineID,
                                         executableHash: try Self.hash(executableURL), executableURL: executableURL, plan: plan)
        stateLock.lock(); pendingProbes = [request.nonce: request]; stateLock.unlock()
        return request
    }

    /// Validates only a future response's schema and binding, never a load test.
    /// Wine may report logical system32 paths for an overlay DLL. Neither that
    /// path nor stdout flags attest the mapped PE/Mach-O images. A controlled
    /// runner and independent host-image evidence remain unimplemented.
    func validateProbeResponse(_ data: Data, request: D3DMetalProbeRequest, exitCode: Int32) throws -> [String: Any] {
        stateLock.lock(); let current = pendingProbes.removeValue(forKey: request.nonce); stateLock.unlock()
        guard current?.rendererHash == request.rendererHash, current?.executableHash == request.executableHash,
              data.count <= 64000, exitCode == 0,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["schema"] as? Int == 1, value["kind"] as? String == "playmelt-d3d12-probe",
              value["nonce"] as? String == request.nonce,
              value["dxgiLoaded"] as? Bool == true, value["d3d12Loaded"] as? Bool == true,
              value["deviceCreated"] as? Bool == true, value["featureLevel"] as? String == "12_0",
              value["hresult"] as? Int == 0, let adapterFlags = value["adapterFlags"] as? Int, adapterFlags & 2 == 0,
              let vendor = value["adapterVendorID"] as? Int, vendor > 0,
              let dxgiPath = value["dxgiModule"] as? String, let d3d12Path = value["d3d12Module"] as? String,
              try Self.engineFingerprint(request.plan.wineURL) == request.plan.engineFingerprint,
              try Self.hash(request.executableURL) == request.executableHash else { throw Self.failure("Le résultat de la sonde DirectX 12 est absent, invalide ou périmé.") }
        stateLock.lock(); let report = cached; stateLock.unlock()
        guard let report, report["contentHash"] as? String == request.rendererHash, try verifyPayload(report) else { throw Self.failure("L’import D3DMetal a changé depuis la préparation de la sonde.") }
        for (name, path) in [("dxgi", dxgiPath), ("d3d12", d3d12Path)] {
            let normalized = path.replacingOccurrences(of: "\\", with: "/")
            guard path.utf8.count < 4096, !path.unicodeScalars.contains(where: { $0.value < 32 }),
                  !normalized.split(separator: "/").contains(".."),
                  normalized.lowercased().hasSuffix("/\(name).dll"),
                  normalized.lowercased().hasPrefix("c:/") || normalized.lowercased().hasPrefix("z:/") else { throw Self.failure("Le chemin déclaré du module DirectX est invalide.") }
        }
        return ["schema": 1, "rendererHash": request.rendererHash, "engineID": request.engineID,
                "engineFingerprint": request.plan.engineFingerprint, "probeHash": request.executableHash,
                "probeResponseValidated": true, "loadTested": false, "reportedDeviceCreated": true,
                "featureLevel": "12_0", "gameTested": false, "routeEnabled": false]
    }

    private struct FileItem { let source: URL; let relative: String; let hash: String; let bytes: Int64 }
    private struct LinkItem { let relative: String; let target: String }
    private struct Inspection { let report: [String: Any]; let files: [FileItem]; let links: [LinkItem] }
    private func inspectFiles(_ selected: URL) throws -> Inspection {
        guard selected.isFileURL, !Self.forbiddenPath(selected) else { throw Self.failure("Sélectionnez le dossier du téléchargement Apple, pas les fichiers d’une autre application.") }
        let source = selected.standardizedFileURL.resolvingSymlinksInPath()
        guard !Self.forbiddenPath(source), (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { throw Self.failure("Sélectionnez un dossier Apple D3DMetal extrait.") }
        let candidates = [("redist/lib", source.appendingPathComponent("redist/lib")), ("lib", source.appendingPathComponent("lib")), ("direct", source)]
        guard let (layout, lib) = candidates.first(where: { FileManager.default.fileExists(atPath: $0.1.appendingPathComponent("wine/x86_64-windows/d3d12.dll").path) && FileManager.default.fileExists(atPath: $0.1.appendingPathComponent("external/D3DMetal.framework").path) }) else {
            throw Self.failure("Le dossier ne contient pas les ponts Wine et le framework D3DMetal Apple attendus.")
        }
        let external = lib.appendingPathComponent("external", isDirectory: true)
        let resolvedExternal = external.resolvingSymlinksInPath()
        var files: [FileItem] = [], links: [LinkItem] = [], mach: [[String: Any]] = [], total: Int64 = 0
        func add(_ file: URL, _ relative: String, parseMach: Bool = false, parsePE: Bool = false, dereference: Bool = false) throws {
            let resolved = file.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(source.path + "/"), !Self.forbiddenPath(resolved), !Self.isDXMTOverlay(resolved.path) else { throw Self.failure("Un fichier de l’import sort du dossier Apple sélectionné.") }
            let input = dereference ? resolved : file
            let a = try FileManager.default.attributesOfItem(atPath: input.path)
            if a[.type] as? FileAttributeType == .typeSymbolicLink {
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: file.path)
                guard !target.hasPrefix("/"), resolved.path.hasPrefix(resolvedExternal.path + "/") else { throw Self.failure("Un lien du framework sort de l’import.") }
                if parseMach || parsePE {
                    let targetAttributes = try FileManager.default.attributesOfItem(atPath: resolved.path)
                    guard targetAttributes[.type] as? FileAttributeType == .typeRegular,
                          let size = (targetAttributes[.size] as? NSNumber)?.int64Value,
                          size > 0, size <= 512_000_000 else { throw Self.failure("La cible d’un pont D3DMetal n’est pas un fichier régulier valide.") }
                    if parsePE { try Self.checkPE64(resolved) }
                    if parseMach {
                        var info = try D3DMetalMachO.inspect(resolved)
                        info["path"] = relative
                        // dyld resolves @loader_path from the shared dylib, not
                        // from the Wine bridge alias that points to it.
                        info["resolvedPath"] = "external/" + resolved.pathComponents.dropFirst(resolvedExternal.pathComponents.count).joined(separator: "/")
                        mach.append(info)
                    }
                }
                links.append(.init(relative: relative, target: target)); return
            }
            guard a[.type] as? FileAttributeType == .typeRegular, let size = (a[.size] as? NSNumber)?.int64Value,
                  size > 0, size <= 512_000_000, files.count < 1024 else { throw Self.failure("Un fichier D3DMetal est vide, trop volumineux ou non régulier.") }
            total += size; guard total <= 1_500_000_000 else { throw Self.failure("L’import D3DMetal dépasse la limite prévue.") }
            if parsePE { try Self.checkPE64(input) }
            if parseMach { var info = try D3DMetalMachO.inspect(input); info["path"] = relative; mach.append(info) }
            files.append(.init(source: input, relative: relative, hash: try Self.hash(input), bytes: size))
        }
        for name in ["d3d11", "d3d12", "dxgi"] {
            try add(lib.appendingPathComponent("wine/x86_64-windows/\(name).dll"), "wine/x86_64-windows/\(name).dll", parsePE: true)
            try add(lib.appendingPathComponent("wine/x86_64-unix/\(name).so"), "wine/x86_64-unix/\(name).so", parseMach: true)
        }
        for (arch, ext) in [("x86_64-windows", "dll"), ("x86_64-unix", "so")] {
            for name in ["d3d10core", "d3d12core", "d3dshared"] {
                let relative = "wine/\(arch)/\(name).\(ext)", file = lib.appendingPathComponent("wine/\(arch)/\(name).\(ext)")
                if FileManager.default.fileExists(atPath: file.path) { try add(file, relative, parseMach: ext == "so", parsePE: ext == "dll") }
            }
        }
        guard let walker = FileManager.default.enumerator(at: external, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []) else { throw Self.failure("Le framework Apple est illisible.") }
        var entries = 0
        while let file = walker.nextObject() as? URL {
            entries += 1; guard entries < 2048, walker.level <= 12 else { throw Self.failure("Structure de framework Apple inattendue.") }
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            if attributes[.type] as? FileAttributeType == .typeDirectory { continue }
            // Directory enumeration may canonicalize /var to /private/var.
            // Derive the relative path by its enumerated depth, not byte offsets.
            let relative = "external/" + file.pathComponents.suffix(walker.level).joined(separator: "/")
            let canonicalFramework = relative == "external/D3DMetal.framework/Versions/A/D3DMetal" || relative == "external/D3DMetal.framework/D3DMetal"
            let externalDylib = file.pathExtension.lowercased() == "dylib"
            try add(file, relative, parseMach: externalDylib || (canonicalFramework && attributes[.type] as? FileAttributeType != .typeSymbolicLink))
        }
        // Notices belong to the selected folder only. An internal alias is
        // flattened to its checked contents; no parent-folder search occurs.
        for name in ["License.rtf", "Acknowledgements.rtf"] {
            let notice = source.appendingPathComponent(name)
            if (try? FileManager.default.attributesOfItem(atPath: notice.path)) != nil {
                try add(notice, "notices/" + name, dereference: true)
            }
        }
        guard mach.contains(where: { ($0["path"] as? String ?? "").contains("D3DMetal.framework/") }) else { throw Self.failure("Le framework D3DMetal x86_64 n’est pas présent.") }
        var dependencies = Set<String>(), minOS = 0
        for info in mach {
            minOS = max(minOS, info["minimumOSPacked"] as? Int ?? 0)
            for dependency in info["dependencies"] as? [String] ?? [] {
                guard !Self.forbiddenPath(URL(fileURLWithPath: dependency)), !Self.isDXMTOverlay(dependency) else { throw Self.failure("L’import dépend d’un autre moteur ou d’une autre application.") }
                dependencies.insert(dependency)
            }
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let hostPacked = (os.majorVersion << 16) | (os.minorVersion << 8) | os.patchVersion
        let list = files.sorted { $0.relative < $1.relative }.map { ["path": $0.relative, "sha256": $0.hash, "bytes": $0.bytes] as [String: Any] }
        let linkList = links.sorted { $0.relative < $1.relative }.map { ["path": $0.relative, "target": $0.target] }
        let identity = try JSONSerialization.data(withJSONObject: ["files": list, "links": linkList], options: [.sortedKeys])
        let contentHash = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        let plistPaths = ["external/D3DMetal.framework/Versions/A/Resources/Info.plist", "external/D3DMetal.framework/Resources/Info.plist", "external/D3DMetal.framework/Info.plist"]
        var version = "unknown"
        for path in plistPaths {
            let url = lib.appendingPathComponent(path).resolvingSymlinksInPath()
            if url.path.hasPrefix(source.path + "/"), let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber, size.intValue < 64000,
               let data = try? Data(contentsOf: url), data.count < 64000,
               let p = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any], let v = p["CFBundleShortVersionString"] as? String { version = String(v.prefix(80)); break }
        }
        return .init(report: ["schema": 1, "sourceDeclaration": "user-selected-local-files", "layout": layout, "contentHash": contentHash,
                              "version": version, "bytes": total, "files": list, "links": linkList, "machO": mach,
                              "dependencies": dependencies.sorted(), "hostOSCompatible": hostPacked >= minOS,
                              "abiStatus": "unverified", "loadTested": false, "gameTested": false, "licenseAcceptedByPlaymelt": false,
                              "architectures": ["x86_64"], "win32Graphics": "not-configured",
                              "sources": Self.sources], files: files, links: links)
    }
    private func verifyPayload(_ report: [String: Any]) throws -> Bool {
        guard let files = report["files"] as? [[String: Any]], !files.isEmpty, files.count < 1025 else { return false }
        try RuntimeSetup.rejectSymlinkAncestors(payload)
        for file in files {
            guard let path = file["path"] as? String, Self.safeRelative(path), let expected = file["sha256"] as? String else { return false }
            let url = payload.appendingPathComponent(path).resolvingSymlinksInPath()
            guard url.path.hasPrefix(payload.path + "/"), try Self.hash(url) == expected else { return false }
        }
        guard let links = report["links"] as? [[String: String]], links.count < 2048 else { return false }
        for link in links {
            guard let path = link["path"], Self.safeRelative(path), let target = link["target"], !target.hasPrefix("/"), !target.contains("\\") else { return false }
            let url = payload.appendingPathComponent(path)
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == target,
                  url.deletingLastPathComponent().appendingPathComponent(target).standardizedFileURL.path.hasPrefix(payload.path + "/"),
                  url.resolvingSymlinksInPath().path.hasPrefix(payload.path + "/"), FileManager.default.fileExists(atPath: url.path) else { return false }
        }
        let identity = try JSONSerialization.data(withJSONObject: ["files": files, "links": links], options: [.sortedKeys])
        guard SHA256.hash(data: identity).map({ String(format: "%02x", $0) }).joined() == report["contentHash"] as? String else { return false }
        return true
    }
    private static func engineFingerprint(_ wine: URL) throws -> String {
        let driver = wine.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib/wine/x86_64-unix/winemac.so")
        return try hash(wine) + ":" + hash(driver)
    }
    static func forbiddenPath(_ url: URL) -> Bool {
        url.pathComponents.contains { part in
            let value = part.lowercased()
            return value.hasSuffix(".app") || value == "bottles" || value == ".cxoffice" || value.contains("crossover") || value == "highball"
        }
    }
    private static func isDXMTOverlay(_ path: String) -> Bool { let p = path.lowercased(); return p.contains("/renderers/dxmt") || p.contains("/renderer/dxmt") }
    private static func safeRelative(_ path: String) -> Bool { !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..") && !path.contains("\\") }
    private static func readObject(_ url: URL) -> [String: Any]? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), attrs[.type] as? FileAttributeType == .typeRegular,
              let count = (attrs[.size] as? NSNumber)?.intValue, count < 2_000_000,
              let data = try? Data(contentsOf: url), let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], value["schema"] as? Int == 1 else { return nil }
        return value
    }
    static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hasher = SHA256(), count = 0
        while let chunk = try handle.read(upToCount: 512 * 1024), !chunk.isEmpty {
            count += chunk.count; guard count <= 512_000_000 else { throw failure("Fichier trop volumineux.") }; hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func checkPE64(_ url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 64), header.count == 64, header.starts(with: [0x4d, 0x5a]) else { throw failure("Un pont D3DMetal n’est pas un programme Windows x64 valide.") }
        let offset = Int(header[60]) | Int(header[61]) << 8 | Int(header[62]) << 16 | Int(header[63]) << 24
        guard offset >= 64, offset < 1_000_000 else { throw failure("En-tête PE invalide.") }
        try handle.seek(toOffset: UInt64(offset))
        guard let pe = try handle.read(upToCount: 26), pe.count == 26, pe.prefix(4) == Data([0x50, 0x45, 0, 0]), pe[4] == 0x64, pe[5] == 0x86,
              pe[24] == 0x0b, pe[25] == 0x02 else { throw failure("Le pont D3DMetal doit être au format PE32+ x86_64.") }
    }
    static func failure(_ text: String) -> RuntimeSetupError { .failed(text) }
}

/// Bounded load-command inspection only. No dlopen, Wine, Metal device or GPU.
enum D3DMetalMachO {
    static func inspect(_ url: URL) throws -> [String: Any] {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        func read(_ offset: UInt64, _ count: Int) throws -> Data { try handle.seek(toOffset: offset); guard let data = try handle.read(upToCount: count), data.count == count else { throw D3DMetalStore.failure("Fichier Mach-O tronqué.") }; return data }
        func u32(_ d: Data, _ p: Int, big: Bool = false) -> UInt32 {
            let b = [UInt32(d[p]), UInt32(d[p+1]), UInt32(d[p+2]), UInt32(d[p+3])]
            return big ? b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3] : b[0] | b[1] << 8 | b[2] << 16 | b[3] << 24
        }
        func u64(_ d: Data, _ p: Int, big: Bool) -> UInt64 { big ? UInt64(u32(d,p,big:true)) << 32 | UInt64(u32(d,p+4,big:true)) : UInt64(u32(d,p)) | UInt64(u32(d,p+4)) << 32 }
        let first = try read(0, 8); var offset: UInt64 = 0
        let magic = u32(first,0,big:true)
        if [0xcafebabe,0xcafebabf,0xbebafeca,0xbfbafeca].contains(magic) {
            let big = magic == 0xcafebabe || magic == 0xcafebabf, wide = magic == 0xcafebabf || magic == 0xbfbafeca
            let count = Int(u32(first,4,big:big)); guard count > 0, count <= 32 else { throw D3DMetalStore.failure("Architecture Mach-O invalide.") }
            let stride = wide ? 32 : 20, table = try read(8, count * (wide ? 32 : 20)); var found = false
            for index in 0..<count where u32(table,index * stride,big:big) == 0x01000007 {
                offset = wide ? u64(table,index * stride + 8,big:big) : UInt64(u32(table,index * stride + 8,big:big)); found = true; break
            }
            guard found else { throw D3DMetalStore.failure("Les fichiers D3DMetal doivent contenir une architecture x86_64.") }
        }
        let header = try read(offset,32)
        guard u32(header,0) == 0xfeedfacf, u32(header,4) == 0x01000007 else { throw D3DMetalStore.failure("Le pont Unix D3DMetal doit être un Mach-O x86_64.") }
        let commands = Int(u32(header,16)), size = Int(u32(header,20))
        guard commands > 0, commands <= 8192, size >= 8, size <= 1_000_000 else { throw D3DMetalStore.failure("Commandes Mach-O invalides.") }
        let data = try read(offset+32,size); var p = 0, dependencies: [String] = [], minOS = 0
        for _ in 0..<commands {
            guard p+8 <= data.count else { throw D3DMetalStore.failure("Commandes Mach-O tronquées.") }
            let cmd = u32(data,p), count = Int(u32(data,p+4))
            guard count >= 8, p+count <= data.count else { throw D3DMetalStore.failure("Commande Mach-O invalide.") }
            if [UInt32(0x0c),0x80000018,0x8000001f,0x80000023].contains(cmd) {
                guard count >= 24 else { throw D3DMetalStore.failure("Dépendance Mach-O invalide.") }
                let start = Int(u32(data,p+8)); guard start >= 24, start < count else { throw D3DMetalStore.failure("Nom de dépendance Mach-O invalide.") }
                let raw = data[(p+start)..<(p+count)].prefix { $0 != 0 }
                guard let name = String(data: raw, encoding: .utf8), !name.isEmpty else { throw D3DMetalStore.failure("Nom de dépendance Mach-O illisible.") }; dependencies.append(name)
            }
            if cmd == 0x32, count >= 24 { guard u32(data,p+8) == 1 else { throw D3DMetalStore.failure("Le framework Apple n’est pas destiné à macOS.") }; minOS = max(minOS,Int(u32(data,p+12))) }
            if cmd == 0x24, count >= 16 { minOS = max(minOS,Int(u32(data,p+8))) }
            p += count
        }
        guard p == data.count else { throw D3DMetalStore.failure("Taille des commandes Mach-O incohérente.") }
        return ["architecture": "x86_64", "dependencies": dependencies, "minimumOSPacked": minOS,
                "minimumOS": "\(minOS >> 16).\((minOS >> 8) & 255).\(minOS & 255)", "loaded": false]
    }
}
