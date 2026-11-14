import Foundation
import Darwin
import CoreFoundation

struct SteamInstallObservation {
    var status: String
    var message: String
    var downloaded: UInt64 = 0
    var total: UInt64 = 0
    var ready = false
    var signature = ""
    var failed = false
    var staged: UInt64? = nil
    var stageTotal: UInt64? = nil
}

/// Only reads the selected game's manifests. A byte counter reaching 100% is
/// never considered installation completion. This does not write Steam files.
enum SteamInstallManifest {
    static func inspect(_ url: URL, appID: String, platform: String, accountID: String, cachedState: [String:Any]? = nil) -> SteamInstallObservation {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init(status: "awaiting-steam", message: "Validez l’installation dans Steam.") }
        let state = cachedState ?? TextVDF.read(url).object("AppState")
        guard state.string("appid") == appID, let flags = UInt64(state.string("StateFlags")) else { return .init(status: "awaiting-steam", message: "Steam prépare l’installation.") }
        let owner = state.string("LastOwner")
        if !owner.isEmpty, owner != "0", !accountID.isEmpty, owner != accountID {
            return .init(status: "failed", message: "Le compte Steam de l’installation a changé. Relancez l’action depuis le bon compte.", failed: true)
        }
        let downloaded = UInt64(state.string("BytesDownloaded")) ?? 0
        let total = UInt64(state.string("BytesToDownload")) ?? 0
        func observation(_ status: String, _ message: String, failed: Bool = false) -> SteamInstallObservation {
            .init(status: status, message: message, downloaded: downloaded, total: total, failed: failed,
                  staged: status == "installing" ? UInt64(state.string("BytesStaged")) : nil,
                  stageTotal: status == "installing" ? UInt64(state.string("BytesToStage")) : nil)
        }
        let updateResult = UInt64(state.string("UpdateResult"))
        if updateResult == 54 { return observation("disk-space", "Steam signale un espace disque insuffisant. Libérez de l’espace puis reprenez dans Steam.") }
        if let updateResult, updateResult != 0 && updateResult != 1 {
            return observation("failed", "Steam signale une erreur d’installation (code \(updateResult)). Consultez les téléchargements Steam.", failed: true)
        }
        if flags & 512 != 0 { return observation("paused", "Téléchargement en pause dans Steam.") }
        if flags & 131072 != 0 { return observation("validating", "Steam vérifie les fichiers.") }
        if flags & (524288 | 262144 | 2097152 | 4194304) != 0 { return observation("installing", "Steam prépare ou installe les fichiers.") }
        if flags & (32 | 128) != 0 { return observation("validating", "Steam doit vérifier ou réparer les fichiers.") }
        if flags == 4 {
            let buildID = state.string("buildid"), target = state.string("TargetBuildID")
            let stageTotal = UInt64(state.string("BytesToStage")) ?? 0
            let staged = UInt64(state.string("BytesStaged")) ?? 0
            let stageSize = UInt64(state.string("StagingSize")) ?? 0
            guard updateResult == nil || updateResult == 0 || updateResult == 1, !buildID.isEmpty, buildID != "0",
                  target.isEmpty || target == "0" || target == buildID,
                  total == 0 || downloaded >= total, staged >= stageTotal, stageSize == 0 else {
                return observation("installing", "Steam finalise l’installation.")
            }
            let directory = state.string("installdir")
            guard let path = steamInstallationPath(apps: url.deletingLastPathComponent(), directory: directory) else {
                return observation("failed", "Le dossier d’installation indiqué par Steam est invalide.", failed: true)
            }
            guard containsLaunchBinary(path, platform: platform) else { return observation("validating", "L’installation est déclarée terminée, mais le programme du jeu reste à vérifier.") }
            var result = observation("installing", "Installation vérifiée. Préparation du lancement.")
            // A moved/replaced installation of the same build is a new candidate,
            // even when Steam preserves LastUpdated. Require two matching reads.
            result.ready = true
            result.signature = [url.path, path.path, buildID, target, owner, state.string("LastUpdated"),
                                String(downloaded), String(total), String(staged), String(stageTotal)].joined(separator: "\u{1f}")
            return result
        }
        if total > 0 || flags & (256 | 1024 | 1048576) != 0 { return observation("downloading", "Téléchargement géré par Steam.") }
        return observation("awaiting-steam", "Steam attend votre validation ou une place dans la file de téléchargement.")
    }

    static func locations(steamRoot: URL, appID: String, platform: String, prefix: URL?, libraryFolders: [String:Any]? = nil) -> [URL] {
        guard LibraryModel.validAppID(appID) else { return [] }
        var roots = [steamRoot]
        let folders = libraryFolders ?? TextVDF.read(steamRoot.appendingPathComponent("steamapps/libraryfolders.vdf")).object("libraryfolders")
        for key in folders.keys.sorted().prefix(31) {
            let value = folders[key]
            let path = (value as? [String: Any])?.string("path") ?? ""
            var candidate: URL?
            if platform == "mac", path.hasPrefix("/") { candidate = URL(fileURLWithPath: path) }
            else if platform == "windows", path.lowercased().hasPrefix("c:\\"), let prefix {
                let drive = prefix.appendingPathComponent("drive_c").resolvingSymlinksInPath()
                let resolved = drive.appendingPathComponent(String(path.dropFirst(3)).replacingOccurrences(of: "\\", with: "/")).standardizedFileURL.resolvingSymlinksInPath()
                if resolved.path == drive.path || resolved.path.hasPrefix(drive.path + "/") { candidate = resolved }
            }
            if let candidate, !roots.contains(candidate) { roots.append(candidate) }
        }
        return roots.map { $0.appendingPathComponent("steamapps/appmanifest_\(appID).acf") }
    }

    static func latestManifest(in paths: [URL]) -> URL? {
        paths.compactMap { url -> (URL, Date)? in
            // Stat afresh: URL resource values can retain a pre-write timestamp.
            guard let values = try? FileManager.default.attributesOfItem(atPath: url.path),
                  values[.type] as? FileAttributeType == .typeRegular else { return nil }
            return (url, values[.modificationDate] as? Date ?? .distantPast)
        }.sorted { $0.1 == $1.1 ? $0.0.path < $1.0.path : $0.1 > $1.1 }.first?.0
    }
}

struct SteamInstallRetryContext {
    let gameID: String
    let appID: String
    let accountID: String
    let runtimeID: String
    let autoLaunch: Bool
    let resumePoint: String?
}

/// One bounded private journal, never a Steam manifest or an executable command.
/// Directory descriptors and no-follow opens keep symlink components out of both
/// reads and atomic replacement. A missing opt-in URL performs no filesystem work.
private enum SteamInstallRecoveryFile {
    static let limit = 32 * 1024
    static func parent(_ url: URL, create: Bool) -> Int32? {
        guard url.isFileURL, url.query == nil, url.fragment == nil,
              url.path == url.standardizedFileURL.path,
              !url.lastPathComponent.isEmpty, url.lastPathComponent.utf8.count <= 128 else { return nil }
        let components = url.deletingLastPathComponent().pathComponents
        guard components.first == "/", components.count > 1 else { return nil }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        for component in components.dropFirst() {
            var next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, errno == ENOENT, create {
                guard mkdirat(descriptor, component, 0o700) == 0 || errno == EEXIST else { Darwin.close(descriptor); return nil }
                next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            Darwin.close(descriptor)
            guard next >= 0 else { return nil }
            descriptor = next
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_uid == geteuid(),
              metadata.st_mode & S_IFMT == S_IFDIR else { Darwin.close(descriptor); return nil }
        if create {
            guard fchmod(descriptor, 0o700) == 0 else { Darwin.close(descriptor); return nil }
        } else if metadata.st_mode & 0o777 != 0o700 { Darwin.close(descriptor); return nil }
        return descriptor
    }
    static func read(_ descriptor: Int32) -> [String: Any]? {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(), metadata.st_nlink == 1,
              metadata.st_mode & 0o777 == 0o600, metadata.st_size > 0, metadata.st_size <= limit else { return nil }
        var bytes = Data(count: Int(metadata.st_size)), offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeMutableBytes { buffer in Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }; offset += count
        }
        var end: UInt8 = 0
        guard Darwin.read(descriptor, &end, 1) == 0 else { return nil }
        return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
    }
    static func load(_ url: URL) -> [String: Any]? {
        guard let directory = parent(url, create: false) else { return nil }
        defer { Darwin.close(directory) }
        let file = openat(directory, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { return nil }; defer { Darwin.close(file) }
        return read(file)
    }
    static func save(_ value: [String: Any], to url: URL, replacing: Bool) -> Bool {
        guard let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), bytes.count <= limit,
              let directory = parent(url, create: true) else { return false }
        defer { Darwin.close(directory) }
        let name = url.lastPathComponent
        var metadata = stat()
        if fstatat(directory, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 {
            guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == geteuid(), metadata.st_nlink == 1,
                  metadata.st_mode & 0o777 == 0o600 else { return false }
            if !replacing {
                let old = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard old >= 0 else { return false }; defer { Darwin.close(old) }
                guard read(old)?["id"] as? String == value["id"] as? String else { return false }
            }
        } else if errno != ENOENT { return false }
        let temporary = "." + name + "." + UUID().uuidString + ".tmp"
        let file = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { return false }
        defer { Darwin.close(file); unlinkat(directory, temporary, 0) }
        guard fchmod(file, 0o600) == 0 else { return false }
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { buffer in Darwin.write(file, buffer.baseAddress!.advanced(by: offset), buffer.count - offset) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return false }; offset += count
        }
        guard fsync(file) == 0, renameat(directory, temporary, directory, name) == 0 else { return false }
        return fsync(directory) == 0
    }
}

final class SteamInstallCoordinator {
    private var observer: SteamInstallObserver?
    private var token: UUID?
    private var job: [String: Any]?
    private var readySignature: String?
    private var closed = false
    private let recoveryURL: URL?
    private var preparedStageID: UUID?
    private var validatedRetryID: UUID?
    private var lastSavedData: Data?
    private var pendingStageMetrics = false
    private static let stageLabels = ["engine":"Moteur", "download":"Téléchargement", "prepare":"Préparation / copie",
                                      "verify":"Vérification", "components":"Composants Windows", "client":"Client Steam"]
    private static let stageStatuses: Set<String> = ["pending", "active", "completed", "failed", "cancelled", "waiting"]
    private static let stageUnits: Set<String> = ["bytes", "files", "items", "verified-bytes"]
    private static let runtimes: Set<String> = ["steam-mac", "playmelt-windows", "playmelt-d3dmetal"]
    private static let preparedStatuses: Set<String> = ["files-prepared", "preparing-client", "awaiting-account", "preparing-files", "awaiting-steam"]
    var onChange: (() -> Void)?
    var onCancel: (() -> Void)?
    var snapshot: [String: Any]? { job }
    var isActive: Bool { token != nil }
    var activeAppID: String? { job?["appId"] as? String }
    var activeGameID: String? { job?["gameId"] as? String }

    static func needsWindowsPayloadRepair(store:String,installed:Bool,complete:Bool,platform:String,nativePreferred:Bool,payloadMarkerPresent:Bool,payloadManifestValid:Bool)->Bool {
        store == "steam" && installed && platform == "windows" && !nativePreferred &&
        (!complete || (payloadMarkerPresent && !payloadManifestValid))
    }

    init(recoveryURL: URL? = nil) {
        self.recoveryURL = recoveryURL
        if let recoveryURL, let record = SteamInstallRecoveryFile.load(recoveryURL) { restore(record) }
    }

    @discardableResult
    func beginDirect(gameID: String, appID: String, title: String, accountID: String, runtimeID: String? = nil, autoLaunch: Bool = false) -> UUID? {
        guard !closed, token == nil, !postStageCancellable, LibraryModel.validAppID(appID), LibraryModel.validAccountID(accountID),
              Self.validGameID(gameID, appID: appID), Self.text(title, limit: 512) != nil,
              runtimeID.map({ Self.runtimes.contains($0) }) ?? true else { return nil }
        let id = UUID(); token = id; readySignature = nil
        preparedStageID = nil; validatedRetryID = nil
        job = ["id": id.uuidString, "gameId": gameID, "appId": appID, "title": title,
               "status": "downloading", "phase": "Téléchargement",
               "message": "Démarrage du téléchargement de \(title)…",
               "bytesDownloaded": 0, "bytesTotal": 0,
               "progress": NSNull(), "stages": [[String:Any]](), "cancellable": true, "autoLaunch": autoLaunch, "accountId": accountID]
        pendingStageMetrics = false
        if let runtimeID { job?["runtimeId"] = runtimeID }
        setRecovery(); persist(replacing: true)
        onChange?(); return id
    }

    @discardableResult
    func beginEpicDirect(gameID: String, appID: String, title: String, accountID: String, autoLaunch: Bool = false) -> UUID? {
        guard !closed, token == nil, !postStageCancellable, !appID.isEmpty else { return nil }
        let id = UUID(); token = id; readySignature = nil
        preparedStageID = nil; validatedRetryID = nil
        job = ["id": id.uuidString, "gameId": gameID, "appId": appID, "title": title,
               "store": "epic",
               "status": "downloading", "phase": "Téléchargement Epic Games",
               "message": "Préparation du téléchargement de \(title)…",
               "bytesDownloaded": 0, "bytesTotal": 0,
               "speed": "", "eta": "",
               "progress": NSNull(), "stages": [[String:Any]](), "cancellable": true, "autoLaunch": autoLaunch, "accountId": accountID]
        pendingStageMetrics = false
        setRecovery(); persist(replacing: true)
        onChange?(); return id
    }

    func acceptsDirect(id: UUID) -> Bool { !closed && token == id && job?["id"] as? String == id.uuidString }
    /// An explicit click on a preserved payload starts at the post-download
    /// boundary. No observer, downloader or recovered autoplay is scheduled.
    func beginPreparedFiles(gameID:String,appID:String,title:String,accountID:String,runtimeID:String,autoLaunch:Bool)->UUID? {
        guard ["playmelt-windows","playmelt-d3dmetal"].contains(runtimeID),
              let id=beginDirect(gameID:gameID,appID:appID,title:title,accountID:accountID,runtimeID:runtimeID,autoLaunch:autoLaunch),
              finishPrepared(id:id,message:"Fichiers du jeu conservés. Préparation du client officiel Steam…"),
              configurePreparedFiles(id:id,accountID:accountID,runtimeID:runtimeID) else{return nil}
        return id
    }
    @discardableResult
    func configurePreparedFiles(id:UUID,accountID:String,runtimeID:String)->Bool {
        guard !closed,token == nil,preparedStageID == id,job?["id"] as? String == id.uuidString,
              job?["accountId"] as? String == accountID,
              ["files-prepared","preparing-client"].contains(job?["status"] as? String ?? ""),
              ["playmelt-windows","playmelt-d3dmetal"].contains(runtimeID) else{return false}
        job?["runtimeId"]=runtimeID
        updatePreparedStage(id:id,status:"preparing-client",message:"Fichiers du jeu conservés. Préparation automatique de Steam Windows…")
        return true
    }
    func acceptsPrepared(id:UUID,accountID:String,runtimeID:String)->Bool {
        !closed && token == nil && preparedStageID == id && postStageCancellable &&
        job?["id"] as? String == id.uuidString && job?["accountId"] as? String == accountID && job?["runtimeId"] as? String == runtimeID
    }
    /// Only the exact live post-stage may adopt a locally complete payload into
    /// the official client's observer. This grants no licence or file readiness.
    func permitsPreparedFollowup(appID:String,accountID:String,runtimeID:String,platform:String,renderer:String,payloadRenderer:String?)->Bool {
        guard !closed,token == nil,postStageCancellable,job?["status"] as? String == "awaiting-steam",
              job?["appId"] as? String == appID,job?["accountId"] as? String == accountID,job?["runtimeId"] as? String == runtimeID,
              platform == "windows",payloadRenderer == renderer else{return false}
        return (runtimeID == "playmelt-windows" && renderer == "dxmt") || (runtimeID == "playmelt-d3dmetal" && renderer == "d3dmetal")
    }
    func permitsPayloadRepair(id:UUID,appID:String,accountID:String,runtimeID:String,needsRepair:Bool)->Bool {
        needsRepair && acceptsDirect(id:id) && job?["appId"] as? String == appID && job?["accountId"] as? String == accountID &&
        job?["runtimeId"] as? String == runtimeID && ["playmelt-windows","playmelt-d3dmetal"].contains(runtimeID)
    }
    func permitsDirectAutoLaunch(id: UUID, accountID: String, executionBlocked: Bool) -> Bool {
        !closed && !executionBlocked && job?["id"] as? String == id.uuidString &&
        job?["accountId"] as? String == accountID && job?["autoLaunch"] as? Bool == true &&
        job?["status"] as? String == "launch-ready"
    }
    func updateDirect(id: UUID, status: String, message: String, progress: Double?, downloaded: UInt64 = 0, total: UInt64 = 0, speed: String = "", phase: String = "", eta: String = "") {
        guard acceptsDirect(id: id) else { return }
        job?["status"] = status
        job?["message"] = message
        if !pendingStageMetrics { fallbackStage(status: status, progress: progress, downloaded: downloaded, total: total) }
        pendingStageMetrics = false
        projectStage(speed: speed, eta: eta)
        setRecovery(); persist()
        onChange?()
    }

    /// Batched before the existing event transition; only scoped producer metrics
    /// are accepted. Raw messages/labels and aggregated worker percent stay out.
    func recordStageMetrics(id: UUID, stages: [[String:Any]]) {
        guard acceptsDirect(id: id), !stages.isEmpty, stages.count <= Self.stageLabels.count else { return }
        var seen = Set<String>(), checked = [[String:Any]]()
        for input in stages {
            guard Set(input.keys).isSubset(of: ["id","status","progress","completedUnits","totalUnits","unit"]),
                  let key = input["id"] as? String, Self.stageLabels[key] != nil, seen.insert(key).inserted,
                  let status = input["status"] as? String, Self.stageStatuses.contains(status),
                  input["progress"] == nil || input["progress"] is NSNull || Self.fraction(input["progress"]) != nil,
                  input["completedUnits"] == nil || Self.units(input["completedUnits"]) != nil,
                  input["totalUnits"] == nil || Self.units(input["totalUnits"]) != nil,
                  input["unit"] == nil || (input["unit"] as? String).map(Self.stageUnits.contains) == true else { return }
            var row: [String:Any] = ["id":key,"label":Self.stageLabels[key]!,"status":status,"progress":NSNull()]
            let done = Self.units(input["completedUnits"]), total = Self.units(input["totalUnits"])
            if let done { row["completedUnits"] = done }
            if let total { row["totalUnits"] = total }
            if let unit = input["unit"] as? String { row["unit"] = unit }
            if let done, let total, total > 0 { if done <= total { row["progress"] = Double(done) / Double(total) } }
            else if let progress = Self.fraction(input["progress"]) { row["progress"] = progress }
            checked.append(row)
        }
        guard checked.filter({ $0["status"] as? String == "active" }).count <= 1 else { return }
        for row in checked { upsertStage(row) }
        pendingStageMetrics = true
    }

    private static func fraction(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
              (0...1).contains(n.doubleValue) else { return nil }
        return n.doubleValue
    }
    private static func units(_ value: Any?) -> UInt64? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return UInt64(n.stringValue)
    }
    private func upsertStage(_ row: [String:Any]) {
        var rows = job?["stages"] as? [[String:Any]] ?? []
        if row["status"] as? String == "active" {
            for index in rows.indices where rows[index]["status"] as? String == "active" { rows[index]["status"] = "waiting" }
        }
        if let index = rows.firstIndex(where: { $0["id"] as? String == row["id"] as? String }) { rows[index] = row }
        else { rows.append(row) }
        job?["stages"] = rows
        job?["activeStage"] = rows.first(where: { $0["status"] as? String == "active" })?["id"]
    }
    private func stopStages(_ status: String) {
        var rows = job?["stages"] as? [[String:Any]] ?? []
        for index in rows.indices where rows[index]["status"] as? String == "active" {
            rows[index]["status"] = status
            if status == "completed", Self.fraction(rows[index]["progress"]) != 1 {
                rows[index]["progress"] = NSNull()
                for key in ["completedUnits","totalUnits","unit"] { rows[index][key] = nil }
            }
        }
        job?["stages"] = rows; job?["activeStage"] = nil
        pendingStageMetrics = false
    }
    private func completeObservedStages(_ ids: Set<String>) {
        var rows = job?["stages"] as? [[String:Any]] ?? []
        for index in rows.indices where ids.contains(rows[index]["id"] as? String ?? "") {
            rows[index]["status"] = "completed"
            if Self.fraction(rows[index]["progress"]) != 1 {
                rows[index]["progress"] = NSNull()
                for key in ["completedUnits","totalUnits","unit"] { rows[index][key] = nil }
            }
        }
        job?["stages"] = rows
        job?["activeStage"] = rows.first(where: { $0["status"] as? String == "active" })?["id"]
    }
    private func fallbackStage(status: String, progress: Double? = nil, downloaded: UInt64 = 0, total: UInt64 = 0,
                               staged: UInt64? = nil, stageTotal: UInt64? = nil) {
        if ["paused","disk-space","interrupted","recovering"].contains(status) { stopStages("waiting"); return }
        let key: String
        switch status {
        case "downloading": key = "download"
        case "validating": key = "verify"
        case "installing","preparing-files": key = "prepare"
        case "preparing-engine": key = "engine"
        case "requesting","preparing-steam","preparing-client","awaiting-steam","awaiting-account": key = "client"
        default: return
        }
        var row: [String:Any] = ["id":key,"label":Self.stageLabels[key]!,"status":status.hasPrefix("awaiting-") ? "waiting" : "active","progress":NSNull()]
        let done = key == "prepare" ? staged : ["download","engine"].contains(key) && total > 0 ? downloaded : nil
        let count = key == "prepare" ? stageTotal : ["download","engine"].contains(key) && total > 0 ? total : nil
        if let done, let count, count > 0 {
            row["completedUnits"] = done; row["totalUnits"] = count; row["unit"] = "bytes"
            if done <= count { row["progress"] = Double(done) / Double(count) }
        } else if key == "engine", let progress = Self.fraction(progress) { row["progress"] = progress }
        upsertStage(row)
    }
    private func projectStage(speed: String = "", eta: String = "") {
        let row = (job?["stages"] as? [[String:Any]])?.first(where: { $0["id"] as? String == job?["activeStage"] as? String })
        let phase = row?["label"] ?? job?["phase"] ?? "Installation"
        job?["progress"] = row?["progress"] ?? NSNull()
        job?["phase"] = phase
        let bytes = ["bytes","verified-bytes"].contains(row?["unit"] as? String ?? "")
        job?["bytesDownloaded"] = bytes ? row?["completedUnits"] ?? 0 : 0
        job?["bytesTotal"] = bytes ? row?["totalUnits"] ?? 0 : 0
        let downloading = row?["id"] as? String == "download" && row?["status"] as? String == "active"
        job?["speed"] = downloading ? speed : ""; job?["eta"] = downloading ? eta : ""
    }

    @discardableResult
    func finishDirect(id: UUID, success: Bool, message: String, code: String? = nil, retryable: Bool = false, resumePoint: String? = nil) -> Bool {
        guard acceptsDirect(id: id) || (!closed && postStageCancellable && preparedStageID == id && job?["id"] as? String == id.uuidString) else { return false }
        stopObserver(); token = nil; readySignature = nil
        preparedStageID = nil; validatedRetryID = nil
        job?["status"] = success ? "launch-ready" : "failed"
        job?["message"] = message
        job?["phase"] = success ? "Terminé" : "Échec"
        stopStages(success ? "completed" : "failed"); projectStage()
        job?["cancellable"] = false
        job?["error"] = success ? nil : errorMetadata(code: code, retryable: retryable, resumePoint: resumePoint)
        setRecovery(); persist()
        onChange?()
        return true
    }
    @discardableResult
    func finishPrepared(id:UUID,message:String)->Bool {
        guard acceptsDirect(id:id) else{return false}
        stopObserver();token=nil;readySignature=nil
        preparedStageID=id;validatedRetryID=nil
        job?["status"]="files-prepared";job?["message"]=message;job?["phase"]="Fichiers préparés"
        completeObservedStages(["download","prepare","verify"]); stopStages("waiting"); projectStage()
        job?["cancellable"]=false
        job?["error"]=nil;setRecovery();persist()
        onChange?();return true
    }

    func updatePreparedStage(id: UUID, status: String, message: String, cancellable: Bool = true) {
        guard !closed, token == nil, job?["id"] as? String == id.uuidString, Self.preparedStatuses.contains(status) else { return }
        let previous = job?["status"] as? String ?? ""
        guard (preparedStageID == id && Self.preparedStatuses.contains(previous)) ||
              (["failed", "interrupted"].contains(previous) && validatedRetryID == id && retryValue() != nil) else { return }
        preparedStageID = id; validatedRetryID = nil
        job?["status"] = status; job?["message"] = message; job?["phase"] = "Préparation du lancement"
        fallbackStage(status: status); projectStage()
        job?["cancellable"] = cancellable; job?["error"] = nil
        setRecovery(); persist(); onChange?()
    }

    func retryContext(jobID: String, selectedAccount: String) -> SteamInstallRetryContext? {
        validatedRetryID = nil
        guard job?["id"] as? String == jobID, let value = retryValue(), value.accountID == selectedAccount else { return nil }
        validatedRetryID = UUID(uuidString: jobID)
        return value
    }

    func begin(gameID: String, appID: String, title: String, runtime: Runtime, accountID: String,
               timeout: TimeInterval = 12 * 60 * 60, autoLaunch:Bool = true,onReady: @escaping (UUID) -> Void) -> UUID? {
        let handoff = postStageCancellable && job?["status"] as? String == "awaiting-steam" &&
            job?["appId"] as? String == appID && job?["accountId"] as? String == accountID &&
            job?["runtimeId"] as? String == runtime.id
        guard !closed, token == nil, !postStageCancellable || handoff, LibraryModel.validAppID(appID), Self.validGameID(gameID, appID: appID) else { return nil }
        let launchIntent = handoff ? (job?["autoLaunch"] as? Bool == true && autoLaunch) : autoLaunch
        let history = handoff ? (job?["stages"] as? [[String:Any]] ?? []) : []
        let id = handoff ? preparedStageID! : UUID(); token = id; readySignature = nil
        preparedStageID = nil; validatedRetryID = nil
        job = ["id": id.uuidString, "gameId": gameID, "appId": appID, "title": title,
               "status": "requesting", "message": "Ouverture de l’installation Steam…", "bytesDownloaded": 0, "bytesTotal": 0,
               "progress": NSNull(), "stages": history, "cancellable": true, "autoLaunch": launchIntent, "accountId": accountID, "runtimeId": runtime.id]
        pendingStageMetrics = false
        fallbackStage(status: "awaiting-steam"); projectStage()
        observer = SteamInstallObserver(runtime: runtime, appID: appID, accountID: accountID, timeout: timeout) { [weak self] observation, expired, changed in
            self?.receive(observation, id: id, expired: expired, accountChanged: changed, onReady: onReady)
        }
        setRecovery(); persist(replacing: true); onChange?(); return id
    }
    // Kept separate from scheduling so cancellation and observation races can be
    // verified with fixtures without running Steam or waiting for real downloads.
    func receive(_ observation: SteamInstallObservation, id: UUID, expired: Bool = false, accountChanged: Bool = false,
                 onReady: (UUID) -> Void) {
        guard token == id, observer != nil else { return }
        if expired { finish(status: "timed-out", message: "Le suivi a atteint sa limite de 12 heures. Steam peut continuer ; aucun lancement automatique ne sera effectué."); return }
        if accountChanged { finish(status: "cancelled", message: "Compte Steam changé : lancement automatique annulé."); return }
        if observation.failed { finish(status: observation.status, message: observation.message); return }
        let previousStages = try? JSONSerialization.data(withJSONObject: job?["stages"] ?? [], options: [.sortedKeys])
        let changed = job?["status"] as? String != observation.status || job?["message"] as? String != observation.message
        job?["status"] = observation.status; job?["message"] = observation.message
        fallbackStage(status: observation.status, downloaded: observation.downloaded, total: observation.total,
                      staged: observation.staged, stageTotal: observation.stageTotal)
        projectStage()
        let stageChanged = previousStages != (try? JSONSerialization.data(withJSONObject: job?["stages"] ?? [], options: [.sortedKeys]))
        let readyTwice = observation.ready && readySignature == observation.signature
        readySignature = observation.ready ? observation.signature : nil
        if readyTwice {
            stopObserver(); completeObservedStages(["download","prepare","verify"]); stopStages("waiting"); projectStage()
        }
        if changed || stageChanged || readyTwice { setRecovery(); persist(); onChange?() }
        if readyTwice { onReady(id) }
    }
    /// A refreshed library can change the selected account while launch is
    /// pending. End that exact job, instead of leaving a token with no observer.
    func confirmLaunchContext(id: UUID, accountChanged: Bool, executionBlocked: Bool) -> Bool {
        guard token == id, observer == nil else { return false }
        if accountChanged { finish(status: "cancelled", message: "Compte Steam changé : lancement automatique annulé."); return false }
        if executionBlocked { finish(status: "cancelled", message: "Lancement automatique suspendu."); return false }
        return true
    }
    func requestFailed(id: UUID, message: String) { guard token == id else { return }; finish(status: "failed", message: message) }
    func launchFailed(id: UUID, message: String) {
        // Process.run only confirms dispatch. Preserve the last job correlation
        // so an asynchronous client failure can replace "launch-requested".
        guard !closed, job?["id"] as? String == id.uuidString,
              token == id || job?["status"] as? String == "launch-requested" else { return }
        finish(status: "failed", message: message)
    }
    func didRequestLaunch(id: UUID, success: Bool, message: String) {
        guard token == id else { return }
        finish(status: success ? "launch-requested" : "failed", message: message)
    }
    func cancel(message: String = "Suivi et lancement automatique arrêtés. Le téléchargement reste géré par Steam.") {
        // Also invalidates a launch queued behind an asynchronous library refresh.
        job?["autoLaunch"] = false
        validatedRetryID = nil
        if token != nil || postStageCancellable {
            onCancel?()
            finish(status: "cancelled", message: message)
        } else { job?["error"] = errorMetadata(code: "cancelled", retryable: false, resumePoint: nil); setRecovery(); persist() }
    }
    func shutdown() { stopStages("waiting"); projectStage(); persist(); closed = true; stopObserver(); token = nil; preparedStageID = nil; validatedRetryID = nil; setRecovery() }
    private func finish(status: String, message: String) {
        stopObserver(); token = nil; readySignature = nil
        preparedStageID = nil; validatedRetryID = nil
        job?["status"] = status; job?["message"] = message; job?["cancellable"] = false
        stopStages(["cancelled"].contains(status) ? "cancelled" : ["launch-requested","launch-ready"].contains(status) ? "completed" : "failed")
        projectStage()
        job?["error"] = errorMetadata(code: status, retryable: false, resumePoint: nil)
        setRecovery(); persist()
        onChange?()
    }
    private var postStageCancellable: Bool {
        preparedStageID != nil && job?["cancellable"] as? Bool == true &&
        Self.preparedStatuses.contains(job?["status"] as? String ?? "")
    }
    private static func text(_ value: Any?, limit: Int) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= limit,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return value
    }
    private static func flag(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    private static func validGameID(_ value: String, appID: String) -> Bool {
        let base = "steam:" + appID
        if value == base || runtimes.contains(where: { value == base + ":" + $0 }) { return true }
        // LibraryScan identifies preserved local payloads by the SHA256 of the
        // canonical folder path. Accept only that opaque digest, never a path.
        let local = base + ":local:"
        guard value.hasPrefix(local), value.utf8.count == local.utf8.count + 64 else { return false }
        return value.utf8.dropFirst(local.utf8.count).allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private func errorMetadata(code: String?, retryable: Bool, resumePoint: String?) -> [String: Any] {
        var value: [String: Any] = ["retryable": retryable]
        if let code = Self.text(code, limit: 128) { value["code"] = code }
        if let resumePoint = Self.text(resumePoint, limit: 128) { value["resumePoint"] = resumePoint }
        return value
    }
    private func verifiedContext(_ value: [String: Any]) -> SteamInstallRetryContext? {
        guard value["store"] as? String != "epic", let id = value["id"] as? String, UUID(uuidString: id) != nil,
              let appID = value["appId"] as? String, LibraryModel.validAppID(appID),
              let gameID = value["gameId"] as? String, Self.validGameID(gameID, appID: appID),
              let accountID = value["accountId"] as? String, LibraryModel.validAccountID(accountID),
              Self.text(value["title"], limit: 512) != nil,
              let runtimeID = value["runtimeId"] as? String, Self.runtimes.contains(runtimeID) else { return nil }
        return SteamInstallRetryContext(gameID: gameID, appID: appID, accountID: accountID, runtimeID: runtimeID,
            autoLaunch: value["autoLaunch"] as? Bool == true,
            resumePoint: (value["error"] as? [String: Any])?["resumePoint"] as? String)
    }
    private func retryValue() -> SteamInstallRetryContext? {
        guard !closed, token == nil, let job, ["failed", "interrupted"].contains(job["status"] as? String ?? ""),
              (job["error"] as? [String: Any])?["retryable"] as? Bool == true else { return nil }
        return verifiedContext(job)
    }
    private func setRecovery() {
        guard job != nil else { return }
        let canRetry = retryValue() != nil
        var recovery: [String: Any] = ["canRetry": canRetry, "action": "retryInstallAndPlay"]
        if !canRetry { recovery["reason"] = "Aucune reprise autorisée pour cet état ou ce contexte." }
        job?["recovery"] = recovery
    }
    private func persist(replacing: Bool = false) {
        guard let recoveryURL else { return }
        guard let job, let id = Self.text(job["id"], limit: 36), let gameID = Self.text(job["gameId"], limit: 128),
              let appID = Self.text(job["appId"], limit: 128), let title = Self.text(job["title"], limit: 512),
              let accountID = Self.text(job["accountId"], limit: 128),
              let status = Self.text(job["status"], limit: 64) else { return }
        var record: [String: Any] = ["schema": 1, "id": id, "gameId": gameID, "appId": appID,
            "title": title, "accountId": accountID, "runtimeId": job["runtimeId"] ?? NSNull(),
            "store": job["store"] as? String ?? "steam", "status": status,
            "phase": Self.text(job["phase"], limit: 128) ?? "Installation",
            "intent": ["autoLaunch": job["autoLaunch"] as? Bool == true],
            "recovery": job["recovery"] as? [String: Any] ?? ["canRetry": false, "action": "retryInstallAndPlay"]]
        if let error = job["error"] as? [String: Any] {
            record["error"] = errorMetadata(code: error["code"] as? String,
                retryable: error["retryable"] as? Bool == true, resumePoint: error["resumePoint"] as? String)
        }
        record["stages"] = (job["stages"] as? [[String:Any]] ?? []).map { ["id":$0["id"]!,"status":$0["status"]!] }
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), data.count <= SteamInstallRecoveryFile.limit,
              data != lastSavedData else { return }
        let saved = SteamInstallRecoveryFile.save(record, to: recoveryURL, replacing: replacing)
        self.job?["recoveryPersistence"] = saved ? "saved" : "unavailable"
        if saved { lastSavedData = data }
    }
    private func restore(_ record: [String: Any]) {
        let keys: Set<String> = ["schema", "id", "gameId", "appId", "title", "accountId", "runtimeId", "store", "status", "phase", "intent", "error", "recovery", "stages"]
        guard Set(record.keys).isSubset(of: keys), let schema = record["schema"] as? NSNumber,
              CFGetTypeID(schema) != CFBooleanGetTypeID(), schema.doubleValue == 1,
              let id = Self.text(record["id"], limit: 36), let uuid = UUID(uuidString: id),
              record["store"] as? String == "steam",
              let appID = record["appId"] as? String, LibraryModel.validAppID(appID),
              let gameID = record["gameId"] as? String, Self.validGameID(gameID, appID: appID),
              let accountID = record["accountId"] as? String, LibraryModel.validAccountID(accountID),
              let title = Self.text(record["title"], limit: 512), let phase = Self.text(record["phase"], limit: 128),
              let status = Self.text(record["status"], limit: 64),
              let intent = record["intent"] as? [String: Any], Set(intent.keys) == ["autoLaunch"], Self.flag(intent["autoLaunch"]) != nil,
              record["runtimeId"] is NSNull || (record["runtimeId"] as? String).map({ Self.runtimes.contains($0) }) == true else { return }
        var error: [String: Any] = ["retryable": false]
        if let input = record["error"] {
            guard let fields = input as? [String: Any], Set(fields.keys).isSubset(of: ["code", "retryable", "resumePoint"]),
                  let retryable = Self.flag(fields["retryable"]),
                  fields["code"] == nil || Self.text(fields["code"], limit: 128) != nil,
                  fields["resumePoint"] == nil || Self.text(fields["resumePoint"], limit: 128) != nil else { return }
            error = errorMetadata(code: fields["code"] as? String, retryable: retryable, resumePoint: fields["resumePoint"] as? String)
        }
        if let input = record["recovery"] {
            guard let fields = input as? [String: Any], Set(fields.keys).isSubset(of: ["canRetry", "action", "reason"]),
                  Self.flag(fields["canRetry"]) != nil, fields["action"] as? String == "retryInstallAndPlay",
                  fields["reason"] == nil || Self.text(fields["reason"], limit: 256) != nil else { return }
        }
        var stages = [[String:Any]](), seen = Set<String>()
        if let input = record["stages"] {
            guard let rows = input as? [[String:Any]], rows.count <= Self.stageLabels.count else { return }
            for row in rows {
                guard Set(row.keys) == ["id","status"], let key = row["id"] as? String, Self.stageLabels[key] != nil,
                      seen.insert(key).inserted, let status = row["status"] as? String, Self.stageStatuses.contains(status) else { return }
                stages.append(["id":key,"label":Self.stageLabels[key]!,"status":status == "active" ? "waiting" : status,"progress":NSNull()])
            }
        }
        guard !["cancelled", "launch-ready", "launch-requested"].contains(status) else { return }
        let failed = status == "failed" || status == "timed-out"
        if !failed { error["retryable"] = true }
        job = ["id": uuid.uuidString, "gameId": gameID, "appId": appID, "title": title,
            "accountId": accountID, "store": "steam", "status": failed ? "failed" : "interrupted",
            "phase": phase, "message": "La tentative précédente est arrêtée. Une reprise manuelle est nécessaire.",
            "cancellable": false, "autoLaunch": false, "restored": true, "progress": NSNull(), "stages": stages, "error": error]
        if let runtimeID = record["runtimeId"] as? String { job?["runtimeId"] = runtimeID }
        setRecovery()
    }
    private func stopObserver() { observer?.stop(); observer = nil }
    deinit { observer?.stop() }
}
