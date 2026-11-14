import Foundation
import Darwin
import CoreFoundation

struct GOGLocalInstallation: Equatable {
    let productID: String
    let appURL: URL
    let directoryURL: URL
    let executableURL: URL
    let installationID: String
}

struct GOGInstallRead {
    var jobs: [[String: Any]] = []
    var installations: [String: GOGLocalInstallation] = [:]
}

/// Read-only operational tables. Never selects credentials, full manifests,
/// account data or URLs; Galaxy keeps its own authentication and transfer.
struct GOGInstallMetadataReader {
    let jobsDatabase: URL
    let database: URL
    var runner: OwnedProcessRunning = OwnedProcessRunner()
    var sqliteURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    var applicationsRoot = URL(fileURLWithPath: "/Applications")
    enum Issue: Error { case unavailable, query, malformed }

    static func identifier(_ value: Any?) -> String? {
        let text: String
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.int64Value > 0, n.doubleValue == Double(n.int64Value) { text = n.stringValue }
        else if let value = value as? String { text = value }
        else { return nil }
        return text.range(of: "^[1-9][0-9]{0,19}$", options: .regularExpression) != nil ? text : nil
    }
    static func count(_ value: Any?) -> UInt64? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
              n.doubleValue >= 0, n.doubleValue < 9_007_199_254_740_992, n.doubleValue.rounded() == n.doubleValue else { return nil }
        return n.uint64Value
    }
    private func rows(_ url: URL, sql: String, cancelled: () -> Bool) throws -> [[String: Any]] {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { throw Issue.unavailable }
        var request = OwnedProcessRequest(executable: sqliteURL, arguments: ["-readonly", "-batch", "-init", "/dev/null", "-json", url.path, sql],
            environment: ["PATH":"/usr/bin:/bin", "LC_ALL":"C"])
        request.timeout = 3; request.outputLimit = 256 * 1024; request.mergeStandardError = false
        let output = try runner.run(request, cancelled: cancelled)
        guard output.exitCode == 0 else { throw Issue.query }
        guard let result = try JSONSerialization.jsonObject(with: output.output.isEmpty ? Data("[]".utf8) : output.output) as? [[String: Any]], result.count <= 1024 else { throw Issue.malformed }
        return result
    }
    func read(cancelled: () -> Bool) throws -> GOGInstallRead {
        let jobs = try rows(jobsDatabase, sql: """
        SELECT i.jobId,i.productId,i.gameName,i.downloadSize,'install' AS kind,0 AS verifying
        FROM InstallProductJobs i JOIN Jobs j ON j.jobId=i.jobId
        UNION ALL
        SELECT u.jobId,u.productId,u.gameName,u.downloadSize,'update' AS kind,u.isVerifying AS verifying
        FROM UpdateProductJobs u JOIN Jobs j ON j.jobId=u.jobId LIMIT 129;
        """, cancelled: cancelled)
        guard jobs.count <= 128 else { throw Issue.malformed }
        let products = jobs.compactMap { Self.identifier($0["productId"]) }
        let requested = products.isEmpty ? "0" : products.joined(separator: ",")
        // json_extract returns only these public scalar fields. The manifest
        // itself contains private client fields and must never be returned.
        let metadata = try rows(database, sql: """
        SELECT m.productId,
          CASE WHEN json_valid(m.manifest) THEN json_extract(m.manifest,'$.platform') END AS platform,
          CASE WHEN json_valid(m.manifest) THEN json_extract(m.manifest,'$.baseProductId') END AS baseProductId,
          CASE WHEN json_valid(m.manifest) THEN json_extract(m.manifest,'$.installDirectory') END AS installDirectory,
          CASE WHEN json_valid(m.manifest) THEN json_extract(m.manifest,'$.buildId') END AS manifestBuild,
          CASE WHEN json_valid(m.manifest) AND json_type(m.manifest,'$.products')='array'
            THEN json_array_length(m.manifest,'$.products') ELSE 0 END AS productCount,
          b.installationPath,b.buildId,b.installationId,
          CASE WHEN p.productId IS NULL THEN 0 ELSE 1 END AS registered,
          EXISTS(SELECT 1 FROM LibraryReleases lr JOIN GamePieces gp ON gp.releaseKey=lr.releaseKey
            LEFT JOIN Products cp ON cp.id=m.productId
            WHERE lr.releaseKey=('gog_' || m.productId) AND (cp.parentId IS NULL OR cp.id IS NULL)
              AND gp.gamePieceTypeId IN (101,186) AND json_valid(gp.value)
              AND json_type(gp.value,'$.title')='text'
              AND length(json_extract(gp.value,'$.title')) BETWEEN 1 AND 4096) AS catalogProduct
        FROM Manifests m LEFT JOIN InstalledBaseProducts b ON b.productId=m.productId
        LEFT JOIN InstalledProducts p ON p.productId=b.productId
        WHERE m.productId IN (\(requested)) OR p.productId IS NOT NULL LIMIT 1025;
        """, cancelled: cancelled)
        var byID: [String: [String: Any]] = [:], duplicated = Set<String>()
        for row in metadata {
            guard let id = Self.identifier(row["productId"]) else { continue }
            if byID[id] != nil { duplicated.insert(id) }; byID[id] = row
        }
        for id in duplicated { byID.removeValue(forKey: id) }
        var result = GOGInstallRead()
        for row in jobs {
            guard Self.identifier(row["jobId"]) != nil, let id = Self.identifier(row["productId"]),
                  let title = row["gameName"] as? String, !title.isEmpty, title.utf8.count <= 512,
                  ["install","update"].contains(row["kind"] as? String ?? "") else { throw Issue.malformed }
            var checked = row
            checked["platform"] = byID[id]?["platform"]
            result.jobs.append(checked)
        }
        for (id, row) in byID {
            guard row["platform"] as? String == "osx", Self.identifier(row["baseProductId"]) == id,
                  Self.count(row["registered"]) == 1, Self.count(row["catalogProduct"]) == 1,
                  (Self.count(row["productCount"]) ?? 0) > 0,
                  Self.identifier(row["buildId"]) != nil,
                  Self.identifier(row["buildId"]) == Self.identifier(row["manifestBuild"]),
                  let path = row["installationPath"] as? String,
                  let directory = row["installDirectory"] as? String,
                  let app = Self.nativeApplication(path: path, publisherDirectory: directory, applicationsRoot: applicationsRoot) else { continue }
            result.installations[id] = .init(productID: id, appURL: app.app, directoryURL: URL(fileURLWithPath: path), executableURL: app.executable,
                installationID: Self.identifier(row["installationId"]) ?? "observed")
        }
        return result
    }
    /// Registration plus a complete public manifest and real native executable
    /// are required. An app directory appearing during download is insufficient.
    static func nativeApplication(path: String, publisherDirectory: String, applicationsRoot: URL) -> (app: URL, executable: URL)? {
        guard path.hasPrefix("/"), path.utf8.count <= 4096, !publisherDirectory.isEmpty,
              publisherDirectory.utf8.count <= 256, !publisherDirectory.contains("/"), !publisherDirectory.contains("\\") else { return nil }
        let root = URL(fileURLWithPath: path)
        guard root.standardizedFileURL.path == root.path, root.resolvingSymlinksInPath().path == root.path,
              root.deletingLastPathComponent().path == applicationsRoot.path,
              root.lastPathComponent == publisherDirectory,
              (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
        let candidates: [URL]
        if root.pathExtension.lowercased() == "app" { candidates = [root] }
        else { candidates = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []).filter { $0.pathExtension.lowercased() == "app" } }
        guard candidates.count == 1, let app = candidates.first, app.resolvingSymlinksInPath().path == app.path else { return nil }
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard plist.resolvingSymlinksInPath().path == plist.path,
              let values = try? plist.resourceValues(forKeys: [.fileSizeKey,.isRegularFileKey]), values.isRegularFile == true, (values.fileSize ?? Int.max) < 128 * 1024,
              let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let name = info["CFBundleExecutable"] as? String, !name.isEmpty, name.utf8.count <= 128,
              !name.contains("/"), !name.contains("\\"), ![".",".."].contains(name) else { return nil }
        let executable = app.appendingPathComponent("Contents/MacOS").appendingPathComponent(name)
        guard executable.resolvingSymlinksInPath().path == executable.path, FileManager.default.isExecutableFile(atPath: executable.path),
              let handle = try? FileHandle(forReadingFrom: executable) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size >= 32 else { return nil }
        try? handle.seek(toOffset: 0)
        guard let header = try? handle.read(upToCount: 32), header.count == 32 else { return nil }
        func u32(_ data: Data,_ offset: Int,_ big: Bool) -> UInt32 {
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            return big ? value.bigEndian : value.littleEndian
        }
        func thin(_ data: Data,_ length: UInt64) -> Bool {
            let magic = Array(data.prefix(4)), big = magic == [0xfe,0xed,0xfa,0xcf]
            guard magic == [0xcf,0xfa,0xed,0xfe] || big, [0x0100000c,0x01000007].contains(u32(data,4,big)), u32(data,12,big) == 2,
                  UInt64(u32(data,20,big)) <= length - 32 else { return false }
            return true
        }
        if !thin(header,size) {
            let magic = Array(header.prefix(4)), big = magic == [0xca,0xfe,0xba,0xbe]
            guard big || magic == [0xbe,0xba,0xfe,0xca] else { return nil }
            let count = Int(u32(header,4,big)); guard (1...8).contains(count), size >= UInt64(8+count*20) else { return nil }
            try? handle.seek(toOffset: 8)
            guard let table = try? handle.read(upToCount: count*20), table.count == count*20 else { return nil }
            var valid = false
            for index in 0..<count {
                let offset = UInt64(u32(table,index*20+8,big)), length = UInt64(u32(table,index*20+12,big))
                guard offset >= UInt64(8+count*20), length >= 32, offset <= size, length <= size-offset else { continue }
                try? handle.seek(toOffset: offset)
                if let slice = try? handle.read(upToCount: 32), slice.count == 32, thin(slice,length) { valid = true }
            }
            guard valid else { return nil }
        }
        return (app, executable)
    }
}

/// Explicitly owned observation lifecycle. Cached getters never query SQLite,
/// touch authentication, open Galaxy or schedule a refresh.
final class GOGInstallObserver {
    private struct Version: Equatable {
        let inode: UInt64, device: Int32, mode: UInt16, size: Int64, modified: Int64, changed: Int64
        static func read(_ url: URL) -> Self? {
            var value = stat()
            guard lstat(url.path, &value) == 0 else { return nil }
            return .init(inode: value.st_ino, device: value.st_dev, mode: value.st_mode, size: value.st_size,
                modified: Int64(value.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(value.st_mtimespec.tv_nsec),
                changed: Int64(value.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(value.st_ctimespec.tv_nsec))
        }
    }
    private let queue = DispatchQueue(label: "playmelt.gog.install-observer", qos: .utility), lock = NSLock()
    private let reader: GOGInstallMetadataReader, interval: TimeInterval
    private var timer: DispatchSourceTimer?, token: OwnedOperationToken?, pending = false, closing = false
    private var waiters: [() -> Void] = [], versions: [Version?]?, jobs: [[String: Any]] = []
    private var installed: [String: GOGLocalInstallation] = [:]
    var onUpdate: (() -> Void)?
    init(reader: GOGInstallMetadataReader = .init(jobsDatabase: URL(fileURLWithPath: "/Users/Shared/GOG.com/Galaxy/Storage/jobs.db"),
         database: URL(fileURLWithPath: "/Users/Shared/GOG.com/Galaxy/Storage/galaxy-2.0.db")), interval: TimeInterval = 2) {
        self.reader = reader; self.interval = max(0.25, interval)
    }
    func snapshots() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return jobs }
    func installations() -> [String: GOGLocalInstallation] { lock.lock(); defer { lock.unlock() }; return installed }
    func start() {
        lock.lock(); guard !closing, timer == nil else { lock.unlock(); return }
        let timer = DispatchSource.makeTimerSource(queue: queue); self.timer = timer
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in self?.refresh() }; lock.unlock(); timer.resume()
    }
    func refresh() {
        lock.lock(); guard !closing, !pending else { lock.unlock(); return }
        let token = OwnedOperationToken(); self.token = token; pending = true; lock.unlock()
        queue.async {
            self.lock.lock(); let installed = self.installed.values.sorted { $0.productID < $1.productID }; self.lock.unlock()
            let nativeFiles = installed.flatMap { [$0.directoryURL,$0.appURL,$0.appURL.appendingPathComponent("Contents/Info.plist"),$0.executableURL] }
            let files = [self.reader.jobsDatabase,self.reader.database].flatMap { [$0,URL(fileURLWithPath:$0.path+"-wal")] } + nativeFiles
            let current = files.map(Version.read)
            self.lock.lock(); let changed = self.versions != current; self.lock.unlock()
            var result: GOGInstallRead?, failed = false
            if changed {
                do {
                    result = try self.reader.read(cancelled: { token.isCancelled })
                    if files.map(Version.read) != current { result = nil; failed = true }
                } catch { failed = true }
            }
            DispatchQueue.main.async { self.finish(token: token, versions: current, result: result, failed: failed) }
        }
    }
    private func finish(token: OwnedOperationToken, versions: [Version?], result: GOGInstallRead?, failed: Bool) {
        lock.lock(); guard self.token === token else { lock.unlock(); return }
        pending = false; self.token = nil
        let publish = !closing && !token.isCancelled
        if publish, let result {
            self.versions = versions
            let date = ISO8601DateFormatter().string(from: Date()), active = Set(result.jobs.compactMap { row -> String? in
                guard let product = GOGInstallMetadataReader.identifier(row["productId"]), let job = GOGInstallMetadataReader.identifier(row["jobId"]) else { return nil }
                return "gog:\(product):\(job)"
            })
            var next = result.jobs.map { Self.snapshot($0, date: date) }
            let activeProducts = Set(result.jobs.compactMap { GOGInstallMetadataReader.identifier($0["productId"]) })
            for previous in jobs where !active.contains(previous["id"] as? String ?? "") {
                var retired = previous
                let product = previous["appId"] as? String ?? ""
                let complete = result.installations[product] != nil && !activeProducts.contains(product)
                retired["status"] = complete ? "launch-ready" : "waiting"; retired["phase"] = complete ? "Installation enregistrée" : "Vérification requise"
                retired["message"] = complete ? "Galaxy a enregistré une installation Mac native valide. Le lancement reste à vérifier." : "La tâche Galaxy a disparu. La fin de l’installation reste à vérifier."
                retired["stages"] = Self.stages(complete ? "completed" : "waiting"); retired["updatedAt"] = date
                retired.removeValue(forKey: "stale")
                next.append(retired)
            }
            for (id, installation) in result.installations where !activeProducts.contains(id) && !next.contains(where: { $0["appId"] as? String == id }) {
                var observed = Self.snapshot(["productId":id,"gameName":installation.appURL.deletingPathExtension().lastPathComponent,"platform":"osx"], date: date,
                    stableID: "gog:\(id):installed-\(installation.installationID)")
                observed["status"] = "launch-ready"
                observed["phase"] = "Installation enregistrée"; observed["stages"] = Self.stages("completed")
                observed["message"] = "Installation Mac native enregistrée par Galaxy ; aucun historique de transfert observé avant ce démarrage."
                observed["provenance"] = ["kind":"galaxy-installed-registration","progressQualified":false,"transferStateVerified":false]
                next.append(observed)
            }
            jobs = Array(next.prefix(128)); installed = result.installations
        } else if publish && failed {
            installed.removeAll()
            jobs = jobs.map { previous in var value = previous; value["status"] = "waiting"; value["stages"] = Self.stages("waiting"); value["message"] = "Lecture Galaxy indisponible ; dernière tâche conservée sans nouvelle mesure."; value["stale"] = true; return value }
        }
        let callbacks = waiters; if !pending { waiters.removeAll() }; lock.unlock()
        if publish && (result != nil || failed) { onUpdate?() }
        for callback in callbacks { callback() }
    }
    private static func stages(_ status: String) -> [[String: Any]] {
        [["id":"client","label":"Client GOG Galaxy","status":status,"progress":NSNull()]]
    }
    private static func snapshot(_ row: [String: Any], date: String, stableID: String? = nil) -> [String: Any] {
        let product = GOGInstallMetadataReader.identifier(row["productId"])!
        let id = stableID ?? "gog:\(product):\(GOGInstallMetadataReader.identifier(row["jobId"])!)"
        let mac = row["platform"] as? String == "osx", verifying = GOGInstallMetadataReader.count(row["verifying"]) == 1
        var result: [String: Any] = ["id":id,"gameId":"gog:\(product)","appId":product,"title":row["gameName"]!,"store":"gog",
            "platform":mac ? "mac" : "unknown","runtimeId":mac ? "gog-mac" : "gog-galaxy","status":verifying ? "validating" : "installing",
            "phase":verifying ? "Vérification GOG Galaxy" : "Installation GOG Galaxy","message":"Installation GOG détectée ; progression du transfert non fournie.",
            "progress":NSNull(),"bytesDownloaded":NSNull(),"bytesTotal":NSNull(),"speed":"","eta":"","stages":stages("active"),
            "cancellable":false,"autoLaunch":false,"source":"galaxy","observed":true,"updatedAt":date,
            "provenance":["kind":"galaxy-local-jobs","progressQualified":false,"transferStateVerified":false]]
        if verifying { result["stages"] = [["id":"verify","label":"Vérification","status":"active","progress":NSNull()]] }
        if let total = GOGInstallMetadataReader.count(row["downloadSize"]), total > 0 { result["bytesTotal"] = total }
        return result
    }
    func shutdown(completion: @escaping () -> Void = {}) {
        lock.lock(); closing = true; timer?.setEventHandler {}; timer?.cancel(); timer = nil; token?.cancel()
        if pending { waiters.append(completion); lock.unlock() }
        else { lock.unlock(); DispatchQueue.main.async(execute: completion) }
    }
}
