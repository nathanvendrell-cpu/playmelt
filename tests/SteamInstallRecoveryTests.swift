// Compile with SteamInstallCoordinator.swift only. These inert dependencies
// isolate coordinator/file lifecycle tests from Core, user data and observers.
import Foundation
import Darwin

struct Runtime { let id: String, platform: String, steamRoot: URL; var prefixURL: URL? = nil }
enum LibraryModel {
    static func validAppID(_ id: String) -> Bool { !id.isEmpty && id.count <= 10 && id.allSatisfy(\.isNumber) && UInt32(id) != nil && UInt32(id) != 0 }
    static func validAccountID(_ id: String) -> Bool { id.count == 17 && id.allSatisfy(\.isNumber) && UInt64(id) != nil }
}
enum TextVDF { static func read(_ url: URL) -> [String: Any] { [:] } }
extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String { self[key] as? String ?? "" }
    func object(_ key: String) -> [String: Any] { self[key] as? [String: Any] ?? [:] }
}
func steamInstallationPath(apps: URL, directory: String) -> URL? { nil }
func containsLaunchBinary(_ path: URL, platform: String) -> Bool { false }
final class SteamInstallObserver {
    static var starts = 0
    init(runtime: Runtime, appID: String, accountID: String, timeout: TimeInterval,
         deliver: @escaping (SteamInstallObservation, Bool, Bool) -> Void) { Self.starts += 1 }
    func stop() {}
}

@main enum SteamInstallRecoveryTests {
    static var checks = 0
    static let account = "76561198000000001", other = "76561198000000002"
    static let fm = FileManager.default
    static func expect(_ value: Bool, _ label: String) {
        checks += 1; if !value { fatalError("FAIL: " + label) }
    }
    static func begin(_ coordinator: SteamInstallCoordinator, appID: String = "10", autoLaunch: Bool = true) -> UUID {
        coordinator.beginDirect(gameID: "steam:" + appID, appID: appID, title: "Fixture Game", accountID: account,
            runtimeID: "playmelt-windows", autoLaunch: autoLaunch)!
    }
    static func recovery(_ coordinator: SteamInstallCoordinator) -> Bool {
        (coordinator.snapshot?["recovery"] as? [String: Any])?["canRetry"] as? Bool == true
    }
    static func read(_ url: URL) throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any] }
    static func stage(_ coordinator: SteamInstallCoordinator, _ id: String) -> [String:Any] {
        (coordinator.snapshot?["stages"] as? [[String:Any]])?.first(where: { $0["id"] as? String == id }) ?? [:]
    }
    static func put(_ record: [String: Any], at url: URL) throws {
        try JSONSerialization.data(withJSONObject: record).write(to: url)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func main() throws {
        let base = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Products.noindex").resolvingSymlinksInPath()
        let root = base.appendingPathComponent("steam-recovery-fixture-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func journal(_ name: String) -> URL { root.appendingPathComponent(name).appendingPathComponent("installation-state.json") }

        let noPersistence = SteamInstallCoordinator()
        let defaultID = begin(noPersistence)
        _ = noPersistence.finishDirect(id: defaultID, success: false, message: "Fixture", code: "network", retryable: true)
        expect(try fm.contentsOfDirectory(atPath: root.path).isEmpty, "default init performs no journal writes")
        expect(noPersistence.retryContext(jobID: defaultID.uuidString, selectedAccount: account) != nil, "explicit in-memory retry remains available without persistence")
        noPersistence.shutdown()
        expect(noPersistence.retryContext(jobID: defaultID.uuidString, selectedAccount: account) == nil, "closed context cannot be retried")

        let url = journal("interrupted"), first = SteamInstallCoordinator(recoveryURL: url), id = begin(first)
        let initial = try read(url)
        expect(initial["schema"] as? Int == 1, "journal schema is versioned")
        expect((initial["intent"] as? [String: Any])?["autoLaunch"] as? Bool == true, "original intent is recorded without scheduling work")
        expect((try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600, "journal mode is 0600")
        expect((try fm.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue == 0o700, "journal directory mode is 0700")
        first.updateDirect(id: id, status: "downloading", message: "Phase observed", progress: nil)
        let before = try fm.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
        first.updateDirect(id: id, status: "downloading", message: "UNPERSISTED_LOG_TOKEN", progress: 0.75, downloaded: 123, total: 200)
        expect(try Data(contentsOf: url).count <= 32 * 1024, "journal is bounded to 32KB")
        expect(!(String(data: try Data(contentsOf: url), encoding: .utf8) ?? "").contains("UNPERSISTED_LOG_TOKEN"), "raw messages and counters do not enter the whitelist")
        expect((try fm.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber) == before, "progress-only update does not rewrite the journal")
        let restored = SteamInstallCoordinator(recoveryURL: url)
        expect(restored.snapshot?["status"] as? String == "interrupted", "unfinished work restores only as interrupted")
        expect(!restored.isActive && !restored.acceptsDirect(id: id), "restore creates no active token")
        expect(SteamInstallObserver.starts == 0, "reload starts no observer or execution")
        expect(restored.snapshot?["autoLaunch"] as? Bool == false, "restore disables auto-launch")
        expect(!restored.permitsDirectAutoLaunch(id: id, accountID: account, executionBlocked: false), "restored job cannot auto-launch")
        expect(restored.retryContext(jobID: UUID().uuidString, selectedAccount: account) == nil, "wrong job id is refused")
        expect(restored.retryContext(jobID: id.uuidString, selectedAccount: other) == nil, "wrong account is refused")
        let context = restored.retryContext(jobID: id.uuidString, selectedAccount: account)
        expect(context?.gameID == "steam:10" && context?.appID == "10" && context?.accountID == account, "retry keeps exact game and account correlation")
        expect(context?.runtimeID == "playmelt-windows" && context?.autoLaunch == false, "retry retains allowlisted runtime but no restored autoplay")
        _ = restored.retryContext(jobID: id.uuidString, selectedAccount: other)
        restored.updatePreparedStage(id: id, status: "preparing-client", message: "No authorization")
        expect(restored.snapshot?["status"] as? String == "interrupted", "invalid context clears earlier preparation authorization")
        _ = restored.retryContext(jobID: id.uuidString, selectedAccount: account)
        restored.updatePreparedStage(id: id, status: "preparing-client", message: "Fixture client")
        expect(restored.snapshot?["status"] as? String == "preparing-client" && !restored.isActive, "validated manual post-stage never reactivates download token")
        expect(restored.beginDirect(gameID: "steam:20", appID: "20", title: "Other", accountID: account) == nil, "cancellable post-stage blocks another download")
        var cancels = 0; restored.onCancel = { cancels += 1 }; restored.cancel()
        expect(cancels == 1 && restored.snapshot?["status"] as? String == "cancelled", "tokenless cancellable post-stage ends on cancel")
        restored.updatePreparedStage(id: id, status: "awaiting-steam", message: "Late")
        expect(restored.snapshot?["status"] as? String == "cancelled", "late post-stage cannot resurrect cancellation")
        expect(!restored.finishDirect(id: id, success: false, message: "Late", retryable: true), "late terminal callback cannot resurrect cancellation")
        expect(restored.retryContext(jobID: id.uuidString, selectedAccount: account) == nil && !recovery(restored), "canceled work has no retry action")
        expect(SteamInstallCoordinator(recoveryURL: url).snapshot == nil, "canceled work does not restore")

        let failureURL = journal("failure"), failed = SteamInstallCoordinator(recoveryURL: failureURL), failedID = begin(failed)
        expect(failed.finishDirect(id: failedID, success: false, message: "Failure", code: "worker_network", retryable: true, resumePoint: "files-prepared"), "correlated failure finishes")
        let failureRecord = try read(failureURL), failureReload = SteamInstallCoordinator(recoveryURL: failureURL)
        expect(failureReload.snapshot?["status"] as? String == "failed" && recovery(failureReload), "retryable failed state survives reopen")
        expect((failureReload.snapshot?["error"] as? [String: Any])?["code"] as? String == "worker_network", "safe error code survives reopen")
        expect(failureReload.retryContext(jobID: failedID.uuidString, selectedAccount: account)?.resumePoint == "files-prepared", "resume point is available to caller")
        let replacement = begin(failureReload, appID: "20")
        expect(failureReload.retryContext(jobID: failedID.uuidString, selectedAccount: account) == nil, "new job invalidates previous retry lifetime")
        expect(failureReload.retryContext(jobID: replacement.uuidString, selectedAccount: account) == nil, "active job cannot be retried")
        _ = failureReload.finishDirect(id: replacement, success: false, message: "Non retryable", retryable: false)
        expect(!recovery(failureReload) && failureReload.retryContext(jobID: replacement.uuidString, selectedAccount: account) == nil, "explicit non-retryable failure has no action")
        expect(!recovery(SteamInstallCoordinator(recoveryURL: failureURL)), "non-retryable marker survives reopen")

        let metricsURL = journal("stage-metrics"), metrics = SteamInstallCoordinator(recoveryURL: metricsURL), metricsID = begin(metrics)
        metrics.updateDirect(id: metricsID, status: "downloading", message: "Measured", progress: 0.82, downloaded: 41, total: 100, speed: "18 Mo/s", phase: "Download", eta: "4 s")
        expect(stage(metrics,"download")["progress"] as? Double == 0.41, "download uses its byte counters, never the aggregated percent")
        expect(metrics.snapshot?["activeStage"] as? String == "download", "download stage is explicitly active")
        metrics.updateDirect(id: metricsID, status: "validating", message: "Unknown verification", progress: 0.82, downloaded: 100, total: 100, speed: "18 Mo/s", phase: "Installation", eta: "4 s")
        expect(stage(metrics,"verify")["progress"] is NSNull && metrics.snapshot?["progress"] is NSNull, "verification never borrows aggregated82percent or download bytes")
        expect(metrics.snapshot?["phase"] as? String == "Vérification", "verification has its own fixed phase label")
        expect(metrics.snapshot?["speed"] as? String == "" && metrics.snapshot?["eta"] as? String == "", "non-download stage clears stale speed and ETA")
        expect((metrics.snapshot?["bytesDownloaded"] as? Int) == 0 && (metrics.snapshot?["bytesTotal"] as? Int) == 0, "non-byte verification clears stale download counters")
        expect(stage(metrics,"download")["status"] as? String == "waiting" && stage(metrics,"download")["progress"] as? Double == 0.41, "a phase change freezes earlier measurements without inventing completion")
        metrics.recordStageMetrics(id: metricsID, stages: [["id":"verify","status":"active","progress":0.99,"completedUnits":20,"totalUnits":100,"unit":"files"]])
        metrics.updateDirect(id: metricsID, status: "validating", message: "Measured verification", progress: 0.82, downloaded: 100, total: 100)
        expect(stage(metrics,"verify")["progress"] as? Double == 0.2 && metrics.snapshot?["progress"] as? Double == 0.2, "scoped verification counters determine the verification ratio")
        expect(stage(metrics,"verify")["completedUnits"] as? UInt64 == 20 && stage(metrics,"verify")["unit"] as? String == "files", "scoped counters retain their actual unit")
        metrics.recordStageMetrics(id: metricsID, stages: [
            ["id":"download","status":"completed","completedUnits":100,"totalUnits":100,"unit":"verified-bytes"],
            ["id":"prepare","status":"completed","completedUnits":100,"totalUnits":100,"unit":"bytes"],
            ["id":"verify","status":"completed","completedUnits":100,"totalUnits":100,"unit":"bytes"],
            ["id":"components","status":"waiting","progress":NSNull()]])
        _ = metrics.finishPrepared(id: metricsID, message: "UNPERSISTED_PATH /Users/secret token=private")
        expect(stage(metrics,"download")["status"] as? String == "completed" && stage(metrics,"prepare")["status"] as? String == "completed", "explicit completed steps remain in history")
        expect(stage(metrics,"components")["progress"] is NSNull && metrics.snapshot?["activeStage"] == nil, "pending official components get no invented percentage or animation")
        metrics.updatePreparedStage(id: metricsID, status: "preparing-client", message: "Client")
        expect(stage(metrics,"client")["status"] as? String == "active" && stage(metrics,"client")["progress"] is NSNull, "client phase is active without an invented percentage")
        _ = metrics.finishDirect(id: metricsID, success: false, message: "UNPERSISTED_PATH /Users/secret token=private", code: "client_failed", retryable: true)
        expect(stage(metrics,"client")["status"] as? String == "failed" && metrics.snapshot?["activeStage"] == nil, "failed steps stop animating")
        expect(stage(metrics,"download")["progress"] as? Double == 1, "terminal failure preserves measured completed history")
        let stageRecord = try read(metricsURL), persistedStages = stageRecord["stages"] as! [[String:Any]]
        expect(persistedStages.allSatisfy { Set($0.keys) == ["id","status"] }, "journal persists only step identity and status")
        expect(!(String(data: try Data(contentsOf: metricsURL), encoding: .utf8) ?? "").contains("UNPERSISTED_PATH"), "raw messages and paths remain outside the journal")
        let metricReload = SteamInstallCoordinator(recoveryURL: metricsURL)
        expect(stage(metricReload,"download")["status"] as? String == "completed" && stage(metricReload,"client")["status"] as? String == "failed", "restoration preserves completed and failed step identities")
        expect(stage(metricReload,"download")["progress"] is NSNull && stage(metricReload,"download")["completedUnits"] == nil, "restoration never fabricates missing transient measurements")
        expect(metricReload.snapshot?["activeStage"] == nil && metricReload.snapshot?["autoLaunch"] as? Bool == false, "restored history has no active animation or autoplay")
        for badStages in [
            [["id":"verify","status":"active","message":"/Users/secret"]],
            [["id":"verify","status":"running"]],
            [["id":"/Users/secret","status":"active"]]
        ] {
            var record = stageRecord; record["stages"] = badStages; try put(record, at: metricsURL)
            expect(SteamInstallCoordinator(recoveryURL: metricsURL).snapshot == nil, "unallowlisted nested stage journal fields are refused")
        }
        var legacyStageRecord = stageRecord; legacyStageRecord.removeValue(forKey: "stages"); try put(legacyStageRecord, at: metricsURL)
        expect(SteamInstallCoordinator(recoveryURL: metricsURL).snapshot != nil, "legacy journal without stages remains readable")

        let stopping = SteamInstallCoordinator(recoveryURL: journal("stage-stopping")), stoppingID = begin(stopping)
        stopping.updateDirect(id: stoppingID, status: "downloading", message: "Measured", progress: nil, downloaded: 4, total: 10)
        stopping.shutdown()
        expect(stage(stopping,"download")["status"] as? String == "waiting" && stage(stopping,"download")["progress"] as? Double == 0.4, "shutdown freezes in-memory measurements")
        expect(stopping.snapshot?["activeStage"] == nil, "shutdown leaves no animated step")
        let cancelledSteps = SteamInstallCoordinator(), cancelledStepID = begin(cancelledSteps)
        cancelledSteps.recordStageMetrics(id: cancelledStepID, stages: [["id":"verify","status":"active","completedUnits":3,"totalUnits":10,"unit":"files"]])
        cancelledSteps.updateDirect(id: cancelledStepID, status: "validating", message: "Three files", progress: 0.82)
        cancelledSteps.cancel()
        expect(stage(cancelledSteps,"verify")["status"] as? String == "cancelled" && stage(cancelledSteps,"verify")["progress"] as? Double == 0.3, "cancellation preserves real progress as a static cancelled step")
        cancelledSteps.recordStageMetrics(id: cancelledStepID, stages: [["id":"verify","status":"active","progress":0.9]])
        expect(stage(cancelledSteps,"verify")["status"] as? String == "cancelled", "late scoped metrics cannot revive cancellation")
        let invalidMetric = SteamInstallCoordinator(), invalidMetricID = begin(invalidMetric)
        for invalid in [
            ["id":"verify","status":"active","progress":Double.nan] as [String:Any],
            ["id":"verify","status":"active","progress":true],
            ["id":"verify","status":"active","progress":0.5,"label":"/Users/secret"],
            ["id":"verify","status":"active","completedUnits":-1,"totalUnits":10,"unit":"files"]
        ] {
            invalidMetric.recordStageMetrics(id: invalidMetricID, stages: [invalid])
            invalidMetric.updateDirect(id: invalidMetricID, status: "validating", message: "Unknown", progress: 0.82, downloaded: 100, total: 100)
            expect(stage(invalidMetric,"verify")["progress"] is NSNull, "invalid scoped metric does not fall back to aggregate percent")
        }
        invalidMetric.recordStageMetrics(id: invalidMetricID, stages: [["id":"verify","status":"active","completedUnits":11,"totalUnits":10,"unit":"bytes"]])
        invalidMetric.updateDirect(id: invalidMetricID, status: "validating", message: "Inconsistent count", progress: 0.82)
        expect(stage(invalidMetric,"verify")["progress"] is NSNull && stage(invalidMetric,"verify")["completedUnits"] as? UInt64 == 11, "overrun counter stays factual without being clamped to100percent")
        invalidMetric.cancel()
        let completedUnmeasured = SteamInstallCoordinator(), completedUnmeasuredID = begin(completedUnmeasured)
        completedUnmeasured.recordStageMetrics(id: completedUnmeasuredID, stages: [["id":"client","status":"active","completedUnits":1,"totalUnits":2,"unit":"items"]])
        completedUnmeasured.updateDirect(id: completedUnmeasuredID, status: "preparing-client", message: "Client half measured", progress: nil)
        _ = completedUnmeasured.finishDirect(id: completedUnmeasuredID, success: true, message: "Client completed without a final counter")
        expect(stage(completedUnmeasured,"client")["status"] as? String == "completed", "explicit completion closes the client step")
        expect(stage(completedUnmeasured,"client")["progress"] is NSNull && stage(completedUnmeasured,"client")["completedUnits"] == nil, "completion without a final measurement never invents100percent")

        let post = SteamInstallCoordinator(recoveryURL: journal("post")), postID = begin(post)
        expect(post.finishPrepared(id: postID, message: "Prepared"), "download ends as files prepared")
        expect(!post.isActive && !post.acceptsDirect(id: postID), "files prepared retires the direct token")
        post.updatePreparedStage(id: UUID(), status: "preparing-client", message: "Wrong")
        expect(post.snapshot?["status"] as? String == "files-prepared", "wrong-id post-stage ignored")
        post.updatePreparedStage(id: postID, status: "preparing-client", message: "Client")
        post.updatePreparedStage(id: postID, status: "awaiting-account", message: "Account")
        post.updatePreparedStage(id: postID, status: "preparing-files", message: "Files")
        post.updatePreparedStage(id: postID, status: "awaiting-steam", message: "Steam")
        expect(post.finishDirect(id: postID, success: false, message: "Client failed", code: "client_failed", retryable: true, resumePoint: "official-steam"), "post-stage failure terminates without a token")
        expect(recovery(post) && !post.finishDirect(id: postID, success: true, message: "Late"), "terminal post-stage rejects late completion")
        post.updatePreparedStage(id: postID, status: "preparing-client", message: "No retry validation")
        expect(post.snapshot?["status"] as? String == "failed", "failed post-stage requires fresh retry validation")
        _ = post.retryContext(jobID: postID.uuidString, selectedAccount: account)
        post.updatePreparedStage(id: postID, status: "preparing-client", message: "Manual retry")
        post.cancel(); post.cancel()
        expect(post.snapshot?["status"] as? String == "cancelled" && !recovery(post), "post-stage cancellation stays terminal after repeated cancel")

        let oldAPI = SteamInstallCoordinator(recoveryURL: journal("old-api"))
        let oldID = oldAPI.beginDirect(gameID: "steam:10", appID: "10", title: "Old API", accountID: account)!
        _ = oldAPI.finishDirect(id: oldID, success: false, message: "No runtime", retryable: true)
        expect(oldAPI.retryContext(jobID: oldID.uuidString, selectedAccount: account) == nil, "missing runtime preserves old API but refuses retry")
        expect(oldAPI.beginDirect(gameID: "steam:20", appID: "20", title: "Bad runtime", accountID: account, runtimeID: "arbitrary-runtime") == nil, "unknown runtime cannot begin direct job")

        for (label, mutate) in [
            ("wrong-schema", { (r: inout [String: Any]) in r["schema"] = 9 }),
            ("wrong-id", { (r: inout [String: Any]) in r["id"] = "not-a-uuid" }),
            ("wrong-account", { (r: inout [String: Any]) in r["accountId"] = "other" }),
            ("wrong-game", { (r: inout [String: Any]) in r["gameId"] = "steam:20" }),
            ("wrong-runtime", { (r: inout [String: Any]) in r["runtimeId"] = "injected-command" }),
            ("extra-secret", { (r: inout [String: Any]) in r["token"] = "must-not-be-restored" }),
            ("invalid-intent", { (r: inout [String: Any]) in r["intent"] = ["autoLaunch": 1] }),
            ("oversized-title", { (r: inout [String: Any]) in r["title"] = String(repeating: "x", count: 513) })
        ] {
            var record = failureRecord; mutate(&record); try put(record, at: failureURL)
            expect(SteamInstallCoordinator(recoveryURL: failureURL).snapshot == nil, "corrupt record refused: " + label)
        }
        try Data(repeating: 0x78, count: 32 * 1024 + 1).write(to: failureURL)
        expect(SteamInstallCoordinator(recoveryURL: failureURL).snapshot == nil, "oversized journal refused before decode")
        try Data("{broken".utf8).write(to: failureURL)
        expect(SteamInstallCoordinator(recoveryURL: failureURL).snapshot == nil, "malformed JSON refused")
        try put(failureRecord, at: failureURL)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: failureURL.path)
        expect(SteamInstallCoordinator(recoveryURL: failureURL).snapshot == nil, "publicly readable journal refused")
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: failureURL.path)

        let symlink = failureURL.deletingLastPathComponent().appendingPathComponent("linked.json")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: failureURL)
        let original = try Data(contentsOf: failureURL), linked = SteamInstallCoordinator(recoveryURL: symlink)
        expect(linked.snapshot == nil, "journal symlink is not read")
        _ = begin(linked)
        expect(try Data(contentsOf: failureURL) == original, "journal symlink destination is never overwritten")
        let directoryAlias = root.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: directoryAlias, withDestinationURL: failureURL.deletingLastPathComponent())
        let aliased = SteamInstallCoordinator(recoveryURL: directoryAlias.appendingPathComponent("installation-state.json"))
        expect(aliased.snapshot == nil, "ancestor symlink is refused")
        _ = begin(aliased)
        expect(try Data(contentsOf: failureURL) == original, "ancestor symlink cannot redirect writes")
        let hardlink = failureURL.deletingLastPathComponent().appendingPathComponent("hardlink.json")
        try fm.linkItem(at: failureURL, to: hardlink)
        expect(SteamInstallCoordinator(recoveryURL: hardlink).snapshot == nil, "hard-linked journal is refused")

        let staleURL = journal("stale"), earlier = SteamInstallCoordinator(recoveryURL: staleURL), earlierID = begin(earlier)
        let newer = SteamInstallCoordinator(recoveryURL: staleURL), newerID = begin(newer, appID: "20")
        _ = earlier.finishDirect(id: earlierID, success: false, message: "Late old instance", retryable: true)
        expect(try read(staleURL)["id"] as? String == newerID.uuidString, "late old coordinator cannot overwrite newer job")
        _ = newer.finishDirect(id: newerID, success: true, message: "Done")
        expect(SteamInstallCoordinator(recoveryURL: staleURL).snapshot == nil, "completed job never restores as an install request")
        expect(SteamInstallObserver.starts == 0, "all recovery tests ran without observers, clients or games")
        let transfer = SteamInstallCoordinator(recoveryURL: journal("handoff")), transferID = begin(transfer)
        _ = transfer.finishPrepared(id: transferID, message: "Prepared")
        transfer.updatePreparedStage(id: transferID, status: "awaiting-steam", message: "Ready for official observer")
        let runtime = Runtime(id: "playmelt-windows", platform: "windows", steamRoot: root)
        expect(transfer.begin(gameID: "steam:20", appID: "20", title: "Wrong", runtime: runtime, accountID: account, onReady: { _ in }) == nil, "handoff refuses another app")
        expect(transfer.begin(gameID: "steam:10", appID: "10", title: "Wrong", runtime: runtime, accountID: other, onReady: { _ in }) == nil, "handoff refuses another account")
        expect(transfer.begin(gameID: "steam:10", appID: "10", title: "Wrong", runtime: Runtime(id: "playmelt-d3dmetal", platform: "windows", steamRoot: root), accountID: account, onReady: { _ in }) == nil, "handoff refuses another runtime")
        let handed = transfer.begin(gameID: "steam:10:playmelt-windows", appID: "10", title: "Discovered", runtime: runtime, accountID: account, onReady: { _ in })
        expect(handed == transferID && transfer.acceptsDirect(id: transferID), "exact awaiting-steam handoff retains UUID")
        expect(SteamInstallObserver.starts == 1, "only explicit handoff creates inert observer fixture")
        let transferReload = SteamInstallCoordinator(recoveryURL: journal("handoff"))
        expect(transferReload.retryContext(jobID: transferID.uuidString, selectedAccount: account)?.gameID == "steam:10:playmelt-windows", "discovered game ID is retained with exact app correlation")
        expect(SteamInstallObserver.starts == 1 && transferReload.snapshot?["autoLaunch"] as? Bool == false, "handoff reload does not start another observer or autoplay")
        transfer.shutdown()
        _ = transferReload.retryContext(jobID: transferID.uuidString, selectedAccount: account)
        transferReload.updatePreparedStage(id: transferID, status: "awaiting-steam", message: "Manual restored handoff")
        expect(transferReload.begin(gameID: "steam:10", appID: "10", title: "Discovered", runtime: runtime, accountID: account, autoLaunch: true, onReady: { _ in }) == transferID, "restored explicit handoff keeps original UUID")
        expect(transferReload.snapshot?["autoLaunch"] as? Bool == false, "handoff cannot re-enable restored autoplay")
        transferReload.cancel(); transferReload.shutdown()
        let observed = SteamInstallCoordinator(), observedID = observed.begin(gameID: "steam:10", appID: "10", title: "Observed fixture", runtime: runtime, accountID: account, onReady: { _ in })!
        var changes = 0; observed.onChange = { changes += 1 }
        observed.receive(.init(status: "downloading", message: "Download", downloaded: 80, total: 100), id: observedID, onReady: { _ in })
        observed.receive(.init(status: "validating", message: "Verify", downloaded: 80, total: 100), id: observedID, onReady: { _ in })
        expect(stage(observed,"verify")["progress"] is NSNull && observed.snapshot?["speed"] as? String == "", "official observer verification never inherits its download counter")
        observed.receive(.init(status: "installing", message: "Stage", downloaded: 100, total: 100, staged: 3, stageTotal: 12), id: observedID, onReady: { _ in })
        expect(stage(observed,"prepare")["progress"] as? Double == 0.25, "official staging uses its independent BytesStaged counter")
        let beforeStagingChange = changes
        observed.receive(.init(status: "installing", message: "Stage", downloaded: 100, total: 100, staged: 6, stageTotal: 12), id: observedID, onReady: { _ in })
        expect(stage(observed,"prepare")["progress"] as? Double == 0.5 && changes == beforeStagingChange + 1, "staging-only counter change publishes a fresh stage snapshot")
        observed.shutdown()
        print("Steam installation recovery: \(checks) PASS; filesystem/CPU fixtures and inert observer double only; no user data, real observer, client, game or network.")
    }
}
