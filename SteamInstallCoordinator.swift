import Foundation

struct SteamInstallObservation {
    var status: String
    var message: String
    var downloaded: UInt64 = 0
    var total: UInt64 = 0
    var ready = false
    var signature = ""
    var failed = false
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
            .init(status: status, message: message, downloaded: downloaded, total: total, failed: failed)
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

final class SteamInstallCoordinator {
    private var observer: SteamInstallObserver?
    private var token: UUID?
    private var job: [String: Any]?
    private var readySignature: String?
    private var closed = false
    var onChange: (() -> Void)?
    var onCancel: (() -> Void)?
    var snapshot: [String: Any]? { job }
    var isActive: Bool { token != nil }
    var activeAppID: String? { job?["appId"] as? String }
    var activeGameID: String? { job?["gameId"] as? String }

    @discardableResult
    func beginDirect(gameID: String, appID: String, title: String, autoLaunch: Bool = false) -> UUID? {
        guard !closed, token == nil else { return nil }
        let id = UUID(); token = id; readySignature = nil
        job = ["id": id.uuidString, "gameId": gameID, "appId": appID, "title": title,
               "status": "downloading", "phase": "Téléchargement",
               "message": "Démarrage du téléchargement de \(title)…",
               "bytesDownloaded": 0, "bytesTotal": 0,
               "progress": 0.0, "cancellable": true, "autoLaunch": autoLaunch]
        onChange?(); return id
    }

    func updateDirect(status: String, message: String, progress: Double?, downloaded: UInt64 = 0, total: UInt64 = 0, speed: String = "", phase: String = "") {
        guard token != nil else { return }
        job?["status"] = status
        job?["message"] = message
        if let progress { job?["progress"] = max(0.0, min(1.0, progress)) }
        if downloaded > 0 { job?["bytesDownloaded"] = downloaded }
        if total > 0 { job?["bytesTotal"] = total }
        if !speed.isEmpty { job?["speed"] = speed }
        if !phase.isEmpty { job?["phase"] = phase }
        onChange?()
    }

    func finishDirect(success: Bool, message: String, onReady: ((UUID) -> Void)? = nil) {
        guard let id = token else { return }
        stopObserver(); token = nil; readySignature = nil
        job?["status"] = success ? "launch-ready" : "failed"
        job?["message"] = message
        job?["phase"] = success ? "Terminé" : "Échec"
        job?["progress"] = success ? 1.0 : NSNull()
        job?["cancellable"] = false
        onChange?()
        if success { onReady?(id) }
    }

    func begin(gameID: String, appID: String, title: String, runtime: Runtime, accountID: String,
               timeout: TimeInterval = 12 * 60 * 60, onReady: @escaping (UUID) -> Void) -> UUID? {
        guard !closed, token == nil, LibraryModel.validAppID(appID) else { return nil }
        let id = UUID(); token = id; readySignature = nil
        job = ["id": id.uuidString, "gameId": gameID, "appId": appID, "title": title,
               "status": "requesting", "message": "Ouverture de l’installation Steam…", "bytesDownloaded": 0, "bytesTotal": 0,
               "progress": NSNull(), "cancellable": true, "autoLaunch": true]
        observer = SteamInstallObserver(runtime: runtime, appID: appID, accountID: accountID, timeout: timeout) { [weak self] observation, expired, changed in
            self?.receive(observation, id: id, expired: expired, accountChanged: changed, onReady: onReady)
        }
        onChange?(); return id
    }
    // Kept separate from scheduling so cancellation and observation races can be
    // verified with fixtures without running Steam or waiting for real downloads.
    func receive(_ observation: SteamInstallObservation, id: UUID, expired: Bool = false, accountChanged: Bool = false,
                 onReady: (UUID) -> Void) {
        guard token == id, observer != nil else { return }
        if expired { finish(status: "timed-out", message: "Le suivi a atteint sa limite de 12 heures. Steam peut continuer ; aucun lancement automatique ne sera effectué."); return }
        if accountChanged { finish(status: "cancelled", message: "Compte Steam changé : lancement automatique annulé."); return }
        if observation.failed { finish(status: observation.status, message: observation.message); return }
        let changed = job?["status"] as? String != observation.status || job?["message"] as? String != observation.message ||
            job?["bytesDownloaded"] as? UInt64 != observation.downloaded || job?["bytesTotal"] as? UInt64 != observation.total
        job?["status"] = observation.status; job?["message"] = observation.message
        job?["bytesDownloaded"] = observation.downloaded; job?["bytesTotal"] = observation.total
        job?["progress"] = observation.total > 0 ? min(1.0, Double(observation.downloaded) / Double(observation.total)) as Any : NSNull()
        let readyTwice = observation.ready && readySignature == observation.signature
        readySignature = observation.ready ? observation.signature : nil
        if readyTwice { stopObserver() }
        if changed || readyTwice { onChange?() }
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
        if token != nil {
            onCancel?()
            finish(status: "cancelled", message: message)
        }
    }
    func shutdown() { closed = true; stopObserver(); token = nil }
    private func finish(status: String, message: String) {
        stopObserver(); token = nil; readySignature = nil
        job?["status"] = status; job?["message"] = message; job?["cancellable"] = false
        onChange?()
    }
    private func stopObserver() { observer?.stop(); observer = nil }
    deinit { observer?.stop() }
}
