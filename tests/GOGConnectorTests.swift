import Foundation
import Darwin

// Compile the connector in isolation with -D GOG_CONNECTOR_ISOLATED_TESTS.
// This projection contains the actual Game fields used by GOGConnector; no app,
// launcher, account, network, Wine or game is started by this test executable.
#if GOG_CONNECTOR_ISOLATED_TESTS
struct Game {
    var id: String, appId: String, title: String, store: String, installed: Bool, platform: String, runtimeId: String, runtimeName: String, ownership: String
    var path: URL?, complete = false, epicLaunchID = ""
    var supportedPlatforms: [String] = []
    var customImageURL = "", customPortraitURL = ""
    var lastPlayed: Int64 = 0
    var installSource = "steam"
}
#endif

private final class GOGMockRunner: OwnedProcessRunning {
    let lock = NSLock()
    private var calls: [OwnedProcessRequest] = [], payload: Data, exitCode: Int32
    private var hold: Bool
    private(set) var ranOnMain = false
    init(_ data: Data, exitCode: Int32 = 0, hold: Bool = false) { payload = data; self.exitCode = exitCode; self.hold = hold }
    func update(_ data: Data, exitCode: Int32 = 0) { lock.lock(); payload = data; self.exitCode = exitCode; hold = false; lock.unlock() }
    func requests() -> [OwnedProcessRequest] { lock.lock(); defer { lock.unlock() }; return calls }
    func run(_ request: OwnedProcessRequest, cancelled: () -> Bool, handoff: () -> Bool, onDetachedExit: @escaping (Int32) -> Void) throws -> OwnedProcessResult {
        lock.lock(); calls.append(request); ranOnMain = Thread.isMainThread
        let data = payload, code = exitCode, shouldHold = hold; lock.unlock()
        if shouldHold {
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while !cancelled() && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.005) }
        }
        // Deliberately return a stale success even after cancellation: the cache
        // must reject it by generation, independently of runner cooperation.
        return .init(output: data, exitCode: code, pid: 0, handedOff: false)
    }
}
private final class GOGSleepingRunner: OwnedProcessRunning {
    let pidFile: URL
    init(_ pidFile: URL) { self.pidFile = pidFile }
    func run(_ request: OwnedProcessRequest, cancelled: () -> Bool, handoff: () -> Bool, onDetachedExit: @escaping (Int32) -> Void) throws -> OwnedProcessResult {
        var fixture = OwnedProcessRequest(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s' \"$$\" > \"$1\"; exec /bin/sleep 10", "fixture", pidFile.path],
            environment: ["PATH": "/usr/bin:/bin"])
        fixture.timeout = request.timeout; fixture.outputLimit = request.outputLimit
        return try GOGFixtureProcesses.run(fixture, cancelled: cancelled)
    }
}
private enum GOGFixtureProcesses {
    static let lock = NSLock()
    static var pids: [pid_t] = []
    static func all() -> [pid_t] { lock.lock(); defer { lock.unlock() }; return pids }
    static func run(_ request: OwnedProcessRequest, cancelled: () -> Bool) throws -> OwnedProcessResult {
        var tracked = request
        tracked.onSpawn = { pid in lock.lock(); pids.append(pid); lock.unlock(); request.onSpawn?(pid) }
        return try OwnedProcessRunner().run(tracked, cancelled: cancelled)
    }
}
private struct GOGLiveRunner: OwnedProcessRunning {
    func run(_ request: OwnedProcessRequest, cancelled: () -> Bool, handoff: () -> Bool, onDetachedExit: @escaping (Int32) -> Void) throws -> OwnedProcessResult {
        try GOGFixtureProcesses.run(request, cancelled: cancelled)
    }
}

@main enum GOGConnectorTests {
    struct Failure: Error { let label: String }
    static let fm = FileManager.default
    static var checks = 0
    static func expect(_ value: @autoclosure () -> Bool, _ label: String) throws {
        checks += 1; if !value() { throw Failure(label: label) }
    }
    static func until(_ done: () -> Bool) throws {
        let end = ProcessInfo.processInfo.systemUptime + 8
        while !done() && ProcessInfo.processInfo.systemUptime < end { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
        try expect(done(), "bounded asynchronous completion")
    }
    static func put(_ data: Data, _ url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    static func rows(_ ids: [String], title: String = "Fixture") throws -> Data {
        try JSONSerialization.data(withJSONObject: ids.map { ["releaseKey": $0, "titleJson": "{\"title\":\"\(title)\"}", "storeImagesJson": "{\"horizontalCover\":\"https://images.gog-statics.com/fixture_{formatter}.jpg\"}"] })
    }
    static func main() throws {
        let root = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Products.noindex/gog-tests-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var connectors: [GOGConnector] = []
        defer {
            for connector in connectors {
                var stopped = false; connector.shutdown { stopped = true }
                let end = Date().addingTimeInterval(10)
                while !stopped && Date() < end { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
            }
            try? fm.removeItem(at: root) // only this task's new fixture tree
        }
        func connector(_ name: String, _ runner: OwnedProcessRunning, timeout: TimeInterval = 2,
                       limit: Int = 32 * 1024 * 1024, database: URL? = nil) throws -> GOGConnector {
            let home = root.appendingPathComponent(name), db = database ?? home.appendingPathComponent("galaxy.db")
            if database == nil { try put(Data("fixture placeholder".utf8), db) }
            let result = GOGConnector(home: home, databaseURL: db, galaxyApp: home.appendingPathComponent("absent.app"), runner: runner, timeout: timeout, outputLimit: limit)
            connectors.append(result); return result
        }
        do {
            let runner = GOGMockRunner(try rows(["gog_1", "gog_2", "steam_3", "amazon_1", "luna_2", "gog_../bad"]))
            let home = root.appendingPathComponent("merge"), apps = home.appendingPathComponent("Library/Application Support/GOG.com/Galaxy/Applications")
            for id in ["1", "3", "46899977096215655", "53652320436400298"] { try fm.createDirectory(at: apps.appendingPathComponent(id), withIntermediateDirectories: true) }
            let preserved = apps.appendingPathComponent("53652320436400298/opaque-client-fixture")
            try put(Data("preserve this client data".utf8), preserved)
            try put(Data(), apps.appendingPathComponent("4"))
            try fm.createSymbolicLink(at: apps.appendingPathComponent("5"), withDestinationURL: apps.appendingPathComponent("3"))
            try put(Data("{\"username\":\"unverified-local-name\"}".utf8), home.appendingPathComponent("Library/Application Support/GOG.com/Galaxy/config.json"))
            let c = try connector("merge", runner)
            var updates = 0; c.onUpdate = { updates += 1; _ = c.games(); _ = c.availability(); c.refresh() }
            try until { c.availability()["catalogStatus"] as? String == "ready" }
            let games = c.games(), merged = games.first { $0.appId == "1" }
            try expect(games.count == 2 && games.filter { $0.appId == "1" }.count == 1, "only actual catalog products become library entries")
            try expect(merged?.installed == false && merged?.complete == false && merged?.path == nil, "numeric wrapper matching a catalog product never proves an installation")
            try expect(merged?.ownership == "gog-local-cache" && merged?.title == "Fixture", "local catalog title and ownership source survive merge")
            try expect(merged?.customImageURL.contains("product_card_v2_mobile_slider_639") == true && merged?.customPortraitURL.contains("glx_vertical_cover") == true, "current Galaxy store image mapping preserved")
            try expect(!games.contains { ["3", "4", "5", "46899977096215655", "53652320436400298"].contains($0.appId) }, "numeric wrappers, files, symlinks and both client packages never become installed games")
            try expect((try? Data(contentsOf: preserved)) == Data("preserve this client data".utf8), "phantom removal leaves the underlying client directory and data untouched")
            try expect(c.nativeLaunchURL(gameID: "53652320436400298") == nil && c.verifiedInstallationDirectory(gameID: "53652320436400298") == nil, "a wrapper has neither a launch nor uninstall target")
            try expect(c.availability()["catalogCount"] as? Int == 2 && c.availability()["authenticated"] as? Bool == false && c.availability()["username"] as? String == "", "local config never proves account or session")
            try expect(games.filter { $0.ownership == "gog-local-cache" }.map(\.appId) == ["1", "2"], "Amazon, Luna and Steam integrations never become GOG-owned entries")
            var invalidLaunch: Bool?
            c.launch(gameID: "amazon:1") { ok, _ in invalidLaunch = ok }
            try expect(invalidLaunch == false, "non-GOG URI rejected before any launcher is opened")
            for _ in 0..<100 { _ = c.games(); _ = c.availability(); c.refresh() }
            try expect(runner.requests().count == 1 && updates == 1 && !runner.ranOnMain, "getters and callback refresh never rerun SQL or block UI")
            let request = runner.requests()[0]
            try expect(Array(request.arguments.prefix(5)) == ["-readonly", "-batch", "-init", "/dev/null", "-json"] && request.mergeStandardError == false, "SQLite is readonly, ignores user init scripts and separates JSON from errors")
            try expect(request.timeout == 2 && request.outputLimit == 32 * 1024 * 1024, "finite timeout and strict output limit configured")
            runner.update(try rows(["gog_9"], title: "Changed")); c.invalidate()
            try until { c.games().contains { $0.appId == "9" } }
            try expect(runner.requests().count == 2 && !c.games().contains { $0.appId == "2" }, "explicit invalidation replaces rather than appends a stale catalog")
        }
        do {
            let runner = GOGMockRunner(try rows(["gog_10"]), hold: true), c = try connector("coalesced", runner)
            try until { runner.requests().count == 1 }
            for _ in 0..<50 { c.refresh(); _ = c.availability(); _ = c.games() }
            try expect(runner.requests().count == 1, "pending refresh requests coalesce")
            runner.update(try rows(["gog_11"])); c.invalidate(); c.invalidate()
            try until { c.availability()["catalogStatus"] as? String == "ready" }
            try expect(runner.requests().count == 2 && c.games().map(\.appId) == ["11"], "invalidations coalesce and stale success cannot publish")
        }
        for (name, data, code) in [("sql-error", try rows(["gog_1"]), Int32(1)), ("malformed", Data("private-error-marker".utf8), Int32(0))] {
            let c = try connector(name, GOGMockRunner(data, exitCode: code))
            try until { c.availability()["catalogStatus"] as? String == "error" }
            let state = c.availability(), message = state["message"] as? String ?? ""
            try expect(c.games().isEmpty && state["catalogLoaded"] as? Bool == false && state["catalogCount"] as? Int == 0, "failed query has no partial or fabricated library")
            try expect(state["catalogAvailable"] as? Bool == false && state["catalogStale"] as? Bool == false && state["catalogUpdatedAt"] as? String == "" && state["catalogSource"] as? String == "", "first failure has no invented catalog, timestamp or provenance")
            try expect(state["authenticated"] as? Bool == false && state["username"] as? String == "" && !message.contains("private-error-marker") && !message.contains("100+"), "error exposes neither false account nor raw process output")
        }
        do {
            let runner = GOGMockRunner(try rows(["gog_1", "gog_2"], title: "Last good"))
            let home = root.appendingPathComponent("stale-catalog"), apps = home.appendingPathComponent("Library/Application Support/GOG.com/Galaxy/Applications")
            try fm.createDirectory(at: apps.appendingPathComponent("1"), withIntermediateDirectories: true)
            let c = try connector("stale-catalog", runner)
            try until { c.availability()["catalogStatus"] as? String == "ready" }
            let before = c.availability(), date = before["catalogUpdatedAt"] as? String ?? ""
            try expect(!date.isEmpty && before["catalogStale"] as? Bool == false, "successful local catalog has a timestamp and provenance")
            try fm.removeItem(at: apps.appendingPathComponent("1")) // only this task's inert fixture directory
            for id in ["2", "3"] { try fm.createDirectory(at: apps.appendingPathComponent(id), withIntermediateDirectories: true) }
            runner.update(try rows(["gog_999"]), exitCode: 1); c.invalidate()
            try until { c.availability()["catalogStatus"] as? String == "error" && c.availability()["busy"] as? Bool == false }
            let stale = c.availability(), games = c.games()
            try expect(games.map(\.appId) == ["1", "2"] && !games.contains { $0.appId == "999" }, "SQL failure retains the last good catalog and rejects partial response")
            try expect(stale["catalogAvailable"] as? Bool == true && stale["catalogStale"] as? Bool == true && stale["catalogCount"] as? Int == 2, "retained catalog remains explicitly stale with its exact count")
            try expect(stale["catalogUpdatedAt"] as? String == date && stale["catalogSource"] as? String == before["catalogSource"] as? String && stale["source"] as? String == before["source"] as? String, "failure preserves the original catalog date and provenance")
            try expect(!(stale["error"] as? String ?? "").isEmpty && (stale["message"] as? String ?? "").contains("périmé") && stale["authenticated"] as? Bool == false, "stale cache is never labeled as a current or authenticated success")
            try expect(games.first { $0.appId == "1" }?.installed == false && games.first { $0.appId == "1" }?.title == "Last good", "stale catalog retains metadata without asserting local installation")
            try expect(games.allSatisfy { !$0.installed && !$0.complete && $0.path == nil } && !games.contains { $0.appId == "3" }, "new numeric wrappers cannot become installations during a catalog read failure")
            runner.update(try rows(["gog_4"], title: "Recovered")); c.invalidate()
            try until { c.availability()["catalogStatus"] as? String == "ready" }
            try expect(c.availability()["catalogStale"] as? Bool == false && c.availability()["catalogCount"] as? Int == 1 && c.availability()["error"] as? String == "", "successful retry replaces the stale catalog and clears its error")
            try expect(c.games().map(\.appId) == ["4"] && c.games().allSatisfy { !$0.installed }, "catalog recovery does not reintroduce numeric wrapper installations")
        }
        do {
            let c = try connector("empty", GOGMockRunner(Data()))
            try until { c.availability()["catalogStatus"] as? String == "ready" }
            try expect(c.games().isEmpty && c.availability()["catalogCount"] as? Int == 0, "zero-row SQLite output is a genuine empty local cache")
        }
        // Real SQLite on a new fixture DB: >1 MiB JSON must be drained while the
        // child writes. This exercises the original deadlock with no real account.
        let largeDB = root.appendingPathComponent("large.db")
        let sql = """
        CREATE TABLE LibraryReleases(releaseKey TEXT);
        CREATE TABLE Products(id INTEGER,parentId INTEGER);
        CREATE TABLE GamePieces(releaseKey TEXT,gamePieceTypeId INTEGER,value TEXT);
        WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<7000)
        INSERT INTO LibraryReleases SELECT 'gog_'||x FROM n;
        INSERT INTO LibraryReleases VALUES('amazon_1'),('luna_2'),('steam_3');
        INSERT INTO GamePieces SELECT releaseKey,186,json_object('title','Fixture '||releaseKey||'\(String(repeating: "x", count: 200))') FROM LibraryReleases;
        """
        var creation = OwnedProcessRequest(executable: URL(fileURLWithPath: "/usr/bin/sqlite3"), arguments: [largeDB.path], environment: ["PATH": "/usr/bin:/bin"])
        creation.input = Data(sql.utf8); creation.timeout = 5
        let created = try GOGFixtureProcesses.run(creation, cancelled: { false })
        try expect(created.exitCode == 0 && kill(created.pid, 0) == -1 && errno == ESRCH, "fixture creation child reaped")
        let before = try Data(contentsOf: largeDB)
        do {
            let c = try connector("large", GOGLiveRunner(), timeout: 5, database: largeDB)
            let start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<100 { _ = c.games(); _ = c.availability() }
            try expect(ProcessInfo.processInfo.systemUptime - start < 0.5, "UI getters stay responsive during large SQLite output")
            try until { c.availability()["busy"] as? Bool == false }
            try expect(c.games().count == 7000 && c.availability()["catalogLoaded"] as? Bool == true, ">1 MiB JSON read completes without pipe deadlock")
            try expect(c.games().reduce(0) { $0 + $1.title.utf8.count } > 1024 * 1024, "fixture genuinely exceeds one MiB")
            let after = try Data(contentsOf: largeDB)
            try expect(after == before, "readonly snapshot preserves fixture database bytes")
        }
        do {
            let c = try connector("overflow", GOGLiveRunner(), timeout: 5, limit: 1024, database: largeDB)
            try until { c.availability()["busy"] as? Bool == false }
            try expect(c.games().isEmpty && c.availability()["catalogStatus"] as? String == "error", "output overflow rejects partial JSON without false success")
        }
        for name in ["timeout", "cancel", "shutdown"] {
            let pidFile = root.appendingPathComponent(name + ".pid")
            let c = try connector(name, GOGSleepingRunner(pidFile), timeout: name == "timeout" ? 0.15 : 5)
            try until { fm.fileExists(atPath: pidFile.path) }
            let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8))!
            if name == "cancel" { var stopped = false; c.cancel { stopped = true }; try until { stopped } }
            else if name == "shutdown" { var stopped = false; c.shutdown { stopped = true }; try until { stopped } }
            else { try until { c.availability()["busy"] as? Bool == false } }
            try expect(kill(pid, 0) == -1 && errno == ESRCH, "cancel/timeout reaps only its fixture child before completion")
            try expect(c.games().isEmpty && c.availability()["catalogStatus"] as? String == (name == "timeout" ? "error" : "cancelled"), "timeout/cancel never reports a successful account or catalog")
            var stopped = false; c.shutdown { stopped = true }; try until { stopped }
            c.invalidate(); c.refresh()
            try expect(c.availability()["busy"] as? Bool == false, "closed connector cannot resurrect a worker")
        }
        for pid in GOGFixtureProcesses.all() { try expect(kill(pid, 0) == -1 && errno == ESRCH, "every fixture process is gone, including no zombie") }
        print("fixture_pids=\(GOGFixtureProcesses.all())")
        print("\(checks) GOG connector checks passed; isolated SQLite and owned shell/sleep fixtures only; no account/network/app/Wine/game")
    }
}
