import Foundation
import AppKit

/// Local Galaxy metadata only. Neither its database nor config.json proves a
/// current GOG session or entitlement. All disk/SQLite work runs on one worker.
final class GOGConnector {
    private struct Snapshot {
        var games: [Game] = []
        var catalog: [String: Game] = [:]
        var galaxyInstalled = false, databasePresent = false, catalogLoaded = false
        var catalogStale = false
        var catalogCount = 0, phase = "loading", error = ""
        var catalogUpdatedAt = "", catalogSource = ""
    }
    private struct Load {
        let id = UUID(), generation: Int, token = OwnedOperationToken(), finished = DispatchGroup()
    }
    private enum SnapshotError: Error { case query, response, limit }
    private let databaseURL: URL, galaxyApp: URL, sqliteURL: URL
    private let runner: OwnedProcessRunning
    private let timeout: TimeInterval, outputLimit: Int
    private let queue = DispatchQueue(label: "playmelt.gog.local-snapshot", qos: .utility)
    private let lock = NSLock()
    private var cached = Snapshot(), pending: Load?
    private var generation = 0, loaded = false, needsRefresh = true, closing = false
    private let installObserver: GOGInstallObserver
    private var verifiedInstallations: [String: GOGLocalInstallation] = [:]
    private var launchAvailability = Set<String>()
    /// Set on the main thread; emitted once per completed snapshot, never by getters.
    var onUpdate: (() -> Void)?
    var onInstallUpdate: (() -> Void)?

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         databaseURL: URL = URL(fileURLWithPath: "/Users/Shared/GOG.com/Galaxy/Storage/galaxy-2.0.db"),
         galaxyApp: URL = URL(fileURLWithPath: "/Applications/GOG Galaxy.app"),
         sqliteURL: URL = URL(fileURLWithPath: "/usr/bin/sqlite3"),
         runner: OwnedProcessRunning = OwnedProcessRunner(), timeout: TimeInterval = 15,
         outputLimit: Int = 32 * 1024 * 1024, installObserver: GOGInstallObserver? = nil) {
        self.databaseURL = databaseURL; self.galaxyApp = galaxyApp; self.sqliteURL = sqliteURL
        self.runner = runner; self.timeout = timeout; self.outputLimit = outputLimit
        self.installObserver = installObserver ?? GOGInstallObserver(reader: .init(jobsDatabase: databaseURL.deletingLastPathComponent().appendingPathComponent("jobs.db"), database: databaseURL, runner: runner, sqliteURL: sqliteURL))
        self.installObserver.onUpdate = { [weak self] in
            guard let self else { return }
            let installations = self.installObserver.installations()
            let busy = Set(self.installObserver.snapshots().filter { $0["status"] as? String != "launch-ready" }.compactMap { $0["appId"] as? String })
            let available = Set(installations.keys).subtracting(busy)
            self.lock.lock(); let changed = self.verifiedInstallations != installations || self.launchAvailability != available
            self.verifiedInstallations = installations; self.launchAvailability = available
            let publish = !self.closing; self.lock.unlock()
            guard publish else { return }
            self.onInstallUpdate?()
            // Progress notifications never trigger a full library refresh.
            if changed { self.onUpdate?() }
        }
        refresh()
    }

    /// Cached getters: no SQL, subprocess, filesystem reads or refresh loop.
    func games() -> [Game] {
        lock.lock(); let original = cached.games, installations = verifiedInstallations; lock.unlock()
        let jobs = installObserver.snapshots()
        let active = Set(jobs.filter { $0["status"] as? String != "launch-ready" }.compactMap { $0["appId"] as? String })
        var entries = Dictionary(uniqueKeysWithValues: original.map { ($0.appId,$0) })
        for (id, installation) in installations {
            var game = entries[id] ?? Self.game(id: id, installed: true)
            game.installed = true; game.complete = !active.contains(id); game.path = installation.appURL
            game.platform = "mac"; game.runtimeId = "gog-mac"; game.runtimeName = "GOG · Mac natif"; entries[id] = game
        }
        for job in jobs {
            guard let id = job["appId"] as? String, entries[id] == nil else { continue }
            var game = Self.game(id: id, installed: false)
            game.title = job["title"] as? String ?? game.title; game.complete = false
            if job["platform"] as? String == "mac" { game.platform = "mac"; game.runtimeId = "gog-mac" }
            entries[id] = game
        }
        return entries.values.sorted { $0.id < $1.id }
    }
    /// Merge only this connector's current cache. A GOG change must not trigger
    /// a scan of Steam/Epic files. History is local; installation evidence is fresh.
    func mergingLibraryGames(_ current: [Game], preservingLocalHistoryFrom previous: [Game] = []) -> [Game] {
        var history: [String: Int64] = [:]
        for game in current + previous where game.store == "gog" {
            history[game.id] = max(history[game.id] ?? 0, game.lastPlayed)
        }
        let fresh = games().map { game -> Game in
            var merged = game
            merged.lastPlayed = max(game.lastPlayed, history[game.id] ?? 0)
            return merged
        }
        let merged = current.filter { $0.store != "gog" } + fresh
        return merged.enumerated().sorted { lhs, rhs in
            let order = lhs.element.title.localizedStandardCompare(rhs.element.title)
            return order == .orderedSame ? lhs.offset < rhs.offset : order == .orderedAscending
        }.map(\.element)
    }
    func installationJobs() -> [[String: Any]] { installObserver.snapshots() }
    func startInstallObservation() { installObserver.start() }
    func nativeLaunchURL(gameID: String) -> URL? {
        verifiedInstallation(gameID: gameID)?.appURL
    }
    func verifiedInstallationDirectory(gameID: String) -> URL? {
        verifiedInstallation(gameID: gameID)?.directoryURL
    }
    private func verifiedInstallation(gameID: String) -> GOGLocalInstallation? {
        let id = gameID.hasPrefix("gog:") ? String(gameID.dropFirst(4)) : gameID
        guard Self.validID(id) else { return nil }
        guard !installObserver.snapshots().contains(where: { $0["appId"] as? String == id && $0["status"] as? String != "launch-ready" }) else { return nil }
        lock.lock(); defer { lock.unlock() }; return verifiedInstallations[id]
    }
    func availability() -> [String: Any] {
        lock.lock(); let snapshot = cached, busy = pending != nil; lock.unlock()
        let available = snapshot.galaxyInstalled || snapshot.databasePresent || !snapshot.games.isEmpty
        let message: String
        if snapshot.phase == "error" || snapshot.phase == "unavailable" {
            message = snapshot.error + (snapshot.catalogStale ? " Dernier cache local conservé : \(snapshot.catalogCount) jeux (périmé, \(snapshot.catalogUpdatedAt))." : "")
        }
        else if snapshot.phase == "cancelled" { message = "Lecture locale GOG annulée. Aucune session GOG vérifiée." }
        else if snapshot.phase == "loading" { message = "Lecture du cache local GOG Galaxy… Aucune session GOG vérifiée." }
        else if snapshot.catalogLoaded { message = "Cache local GOG Galaxy : \(snapshot.catalogCount) jeux. Aucune session GOG vérifiée." }
        else { message = snapshot.galaxyInstalled ? "GOG Galaxy détecté sur ce Mac. Aucune session GOG vérifiée." : "GOG Galaxy non détecté. Aucune session GOG vérifiée." }
        return ["status": ["error", "unavailable"].contains(snapshot.phase) ? snapshot.phase : available ? "ready" : "not-installed",
                "available": available, "authenticated": false, "sessionVerified": false, "username": "",
                "galaxyInstalled": snapshot.galaxyInstalled, "catalogCount": snapshot.catalogCount,
                "catalogStatus": snapshot.phase, "catalogLoaded": snapshot.catalogLoaded,
                "catalogAvailable": snapshot.catalogLoaded, "catalogStale": snapshot.catalogStale,
                "catalogUpdatedAt": snapshot.catalogUpdatedAt, "catalogSource": snapshot.catalogSource,
                "installationsStale": installObserver.snapshots().contains { $0["stale"] as? Bool == true },
                "source": snapshot.catalogLoaded ? snapshot.catalogSource : "local-installations",
                "error": snapshot.error, "busy": busy, "message": message]
    }

    /// Coalesces callers and reuses a completed snapshot, including an error.
    /// Explicit invalidation is required to reread changed launcher files.
    func refresh() {
        lock.lock()
        guard !closing, pending == nil, !loaded || needsRefresh else { lock.unlock(); return }
        let load = Load(generation: generation); load.finished.enter(); pending = load; needsRefresh = false
        lock.unlock()
        queue.async {
            let snapshot = self.readSnapshot(cancelled: { load.token.isCancelled })
            DispatchQueue.main.async {
                defer { load.finished.leave() }
                self.lock.lock()
                guard self.pending?.id == load.id else { self.lock.unlock(); return }
                self.pending = nil
                let publish = !self.closing && self.generation == load.generation && !load.token.isCancelled
                if publish {
                    var next = snapshot
                    // A transient read failure cannot erase the last known local
                    // catalog. Its timestamp/provenance stay unchanged and stale.
                    if !next.catalogLoaded && self.cached.catalogLoaded {
                        next.catalog = self.cached.catalog; next.catalogLoaded = true; next.catalogStale = true
                        next.catalogCount = self.cached.catalogCount
                        next.catalogUpdatedAt = self.cached.catalogUpdatedAt; next.catalogSource = self.cached.catalogSource
                    }
                    next.games = next.catalog.values.sorted { $0.id < $1.id }
                    self.cached = next; self.loaded = true
                }
                let retry = !self.closing && self.needsRefresh
                let notify = !self.closing && (publish || !retry)
                self.lock.unlock()
                if retry { self.refresh() }
                if notify { self.onUpdate?() }
            }
        }
    }
    func invalidate() {
        lock.lock()
        guard !closing else { lock.unlock(); return }
        generation += 1; needsRefresh = true; cached.phase = "loading"; cached.error = ""; cached.catalogStale = cached.catalogLoaded
        pending?.token.cancel(); lock.unlock(); refresh()
    }
    func cancel(completion: @escaping () -> Void = {}) {
        lock.lock()
        generation += 1; needsRefresh = false; loaded = true; cached.phase = "cancelled"
        let load = pending; load?.token.cancel(); lock.unlock()
        if let load { load.finished.notify(queue: .main, execute: completion) }
        else { DispatchQueue.main.async(execute: completion) }
    }
    func shutdown(completion: @escaping () -> Void = {}) {
        lock.lock(); closing = true; lock.unlock()
        let group = DispatchGroup(); group.enter(); cancel { group.leave() }
        group.enter(); installObserver.shutdown { group.leave() }
        group.notify(queue: .main, execute: completion)
    }

    private static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 32 && id.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }
    private func readSnapshot(cancelled: () -> Bool) -> Snapshot {
        let fm = FileManager.default
        var snapshot = Snapshot()
        snapshot.galaxyInstalled = fm.fileExists(atPath: galaxyApp.path)
        snapshot.databasePresent = fm.fileExists(atPath: databaseURL.path)
        do {
            if cancelled() { throw OwnedProcessError.cancelled }
            if snapshot.databasePresent {
                let sql = """
                SELECT lr.releaseKey,
                       COALESCE(MAX(CASE WHEN gp.gamePieceTypeId = 186 THEN gp.value END),
                                MAX(CASE WHEN gp.gamePieceTypeId = 101 THEN gp.value END)) AS titleJson,
                       MAX(CASE WHEN gp.gamePieceTypeId = 98 THEN gp.value END) AS imagesJson,
                       MAX(CASE WHEN gp.gamePieceTypeId = 227 THEN gp.value END) AS storeImagesJson
                FROM LibraryReleases lr JOIN GamePieces gp ON gp.releaseKey = lr.releaseKey
                LEFT JOIN Products p ON ('gog_' || p.id) = lr.releaseKey
                WHERE lr.releaseKey GLOB 'gog_[0-9]*'
                  AND gp.gamePieceTypeId IN (101,186,98,227) AND (p.parentId IS NULL OR p.id IS NULL)
                GROUP BY lr.releaseKey;
                """
                var request = OwnedProcessRequest(executable: sqliteURL,
                    arguments: ["-readonly", "-batch", "-init", "/dev/null", "-json", databaseURL.path, sql],
                    environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C"])
                request.timeout = timeout; request.outputLimit = outputLimit; request.mergeStandardError = false
                let result = try runner.run(request, cancelled: cancelled)
                guard result.exitCode == 0 else { throw SnapshotError.query }
                // sqlite emits no bytes for a successful zero-row SELECT.
                let data = result.output.isEmpty ? Data("[]".utf8) : result.output
                guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw SnapshotError.response }
                guard rows.count <= 20_000 else { throw SnapshotError.limit }
                for row in rows {
                    if cancelled() { throw OwnedProcessError.cancelled }
                    guard let key = row["releaseKey"] as? String, key.hasPrefix("gog_") else { continue }
                    let id = String(key.dropFirst(4)); guard Self.validID(id) else { continue }
                    let titleObject = Self.object(row["titleJson"])
                    let title = (titleObject["title"] as? String).flatMap { !$0.isEmpty && $0.utf8.count <= 4096 ? $0 : nil } ?? "GOG Game (\(id))"
                    let lower = title.lowercased()
                    if ["discount code", "promo code", "merch store", "gear - discount"].contains(where: lower.contains) { continue }
                    let images = Self.object(row["imagesJson"]), storeImages = Self.object(row["storeImagesJson"])
                    var landscape = Self.image(images["background"])
                    var portrait = Self.image(images["verticalCover"]); if portrait.isEmpty { portrait = Self.image(images["squareIcon"]) }
                    if let template = storeImages["horizontalCover"] as? String, template.utf8.count <= 8192,
                       template.hasPrefix("https://images.gog-statics.com/"), template.contains("{formatter}") {
                        if landscape.isEmpty { landscape = template.replacingOccurrences(of: "{formatter}", with: "product_card_v2_mobile_slider_639") }
                        if portrait.isEmpty { portrait = template.replacingOccurrences(of: "{formatter}", with: "glx_vertical_cover") }
                    }
                    if landscape.isEmpty { landscape = portrait }; if portrait.isEmpty { portrait = landscape }
                    var game = Self.game(id: id, installed: false)
                    game.title = title; game.ownership = "gog-local-cache"
                    game.customImageURL = landscape; game.customPortraitURL = portrait
                    snapshot.catalog[id] = game
                }
                snapshot.catalogLoaded = true; snapshot.catalogCount = snapshot.catalog.count
                snapshot.catalogUpdatedAt = ISO8601DateFormatter().string(from: Date())
                snapshot.catalogSource = "galaxy-local-cache"
                snapshot.phase = "ready"
            } else {
                snapshot.phase = "unavailable"
                snapshot.error = "Cache local GOG Galaxy indisponible. Aucune session GOG vérifiée."
            }
        } catch {
            // A failed/partial query is never published as a synchronized library.
            snapshot.catalog.removeAll(); snapshot.catalogLoaded = false; snapshot.catalogCount = 0
            snapshot.phase = "error"
            snapshot.error = "Lecture du cache local GOG impossible ou interrompue. Aucune session GOG vérifiée."
        }
        // Galaxy/Applications holds launcher wrappers, not registered games.
        // Only the operational registry observer can qualify a native installation.
        return snapshot
    }
    private static func object(_ value: Any?) -> [String: Any] {
        guard let text = value as? String, let data = text.data(using: .utf8) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
    private static func image(_ value: Any?) -> String {
        guard let value = value as? String, value.utf8.count <= 8192 else { return "" }; return value
    }
    private static func game(id: String, installed: Bool) -> Game {
        Game(id: "gog:" + id, appId: id, title: "GOG Game (\(id))", store: "gog", installed: installed,
             platform: installed ? "mac" : "windows", runtimeId: installed ? "gog-mac" : "gog-galaxy",
             runtimeName: "GOG Galaxy", ownership: "installed-only", path: nil, complete: false,
             epicLaunchID: id, supportedPlatforms: ["mac", "windows"], installSource: "gog")
    }

    func launch(gameID: String, completion: @escaping (Bool, String) -> Void) {
        let cleanID = gameID.hasPrefix("gog:") ? String(gameID.dropFirst(4)) : gameID
        guard Self.validID(cleanID) else { completion(false, "Identifiant GOG invalide."); return }
        if let url = URL(string: "goggalaxy://launchGame/\(cleanID)"), NSWorkspace.shared.open(url) {
            completion(true, "Lancement du jeu via GOG Galaxy…"); return
        }
        if let url = URL(string: "goggalaxy://openGameView/\(cleanID)"), NSWorkspace.shared.open(url) {
            completion(true, "Ouverture de la fiche du jeu dans GOG Galaxy…"); return
        }
        openGalaxy(completion: completion)
    }
    func openGalaxy(completion: @escaping (Bool, String) -> Void) {
        if FileManager.default.fileExists(atPath: galaxyApp.path) {
            NSWorkspace.shared.openApplication(at: galaxyApp, configuration: .init()) { _, error in
                completion(error == nil, error == nil ? "GOG Galaxy ouvert." : "Impossible d’ouvrir GOG Galaxy.")
            }
        } else if let web = URL(string: "https://www.gog.com") {
            NSWorkspace.shared.open(web); completion(true, "Ouverture de GOG.com…")
        }
    }
}
