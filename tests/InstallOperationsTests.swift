import Foundation

@main struct InstallOperationsTests {
    static func main() {
        var checks = 0
        func expect(_ value: Bool, _ message: String) {
            checks += 1
            if !value { fatalError(message) }
        }
        let gog: [String: Any] = ["id":"gog:1423049311:install:1", "store":"gog", "gameId":"gog:1423049311", "appId":"1423049311", "status":"installing", "progress":NSNull(), "bytesDownloaded":NSNull(), "bytesTotal":UInt64(68_606_283_631), "autoLaunch":true, "cancellable":true]
        let steam: [String: Any] = ["id":"managed", "gameId":"steam:1903340", "status":"downloading", "progress":0.25]
        let jobs = InstallOperations.snapshots(managed:steam, observed:[gog,gog])
        expect(jobs.count == 2, "Both providers share the catalogue without duplicated jobs")
        expect(jobs[0]["store"] as? String == "steam", "Legacy managed Steam gets an explicit store")
        expect(jobs[0]["progress"] as? Double == 0.25, "Managed metrics are preserved")
        expect(jobs[1]["progress"] is NSNull, "Unknown progress stays unknown")
        expect(jobs[1]["bytesDownloaded"] is NSNull, "Known total cannot fabricate downloaded bytes")
        expect((jobs[1]["bytesTotal"] as? UInt64) == 68_606_283_631, "Large byte totals retain integer precision")
        expect(jobs[1]["autoLaunch"] as? Bool == false, "Adoption never authorizes autoplay")
        expect(jobs[1]["cancellable"] as? Bool == false, "Adoption never invents cancellation")
        expect(jobs[1]["retryable"] as? Bool == false, "Adoption never invents retry")
        expect(InstallOperations.hasActiveTransfer(jobs), "An adopted transfer blocks an unsafe app replacement")
        expect(InstallOperations.snapshots(managed:nil, observed:[gog]).count == 1, "GOG remains visible without a managed Steam job")
        var wrong = gog; wrong["gameId"] = "gog:1"
        expect(InstallOperations.snapshots(managed:nil, observed:[wrong]).isEmpty, "Reject cross-game association")
        wrong = gog; wrong["appId"] = "../1"
        expect(InstallOperations.snapshots(managed:nil, observed:[wrong]).isEmpty, "Reject non-provider identifiers")
        wrong = gog; wrong["store"] = "steam"
        expect(InstallOperations.snapshots(managed:nil, observed:[wrong]).isEmpty, "An observed source cannot impersonate another provider")
        expect(!InstallOperations.hasActiveTransfer([["status":"launch-ready"],["status":"cancelled"]]), "Terminal history is not an active download")
        expect(InstallOperations.hasActiveTransfer([["status":"waiting"]]), "Uncertain completion cannot become idle success")
        var epic = steam; epic["store"] = "epic"
        expect(InstallOperations.snapshots(managed:epic, observed:[])[0]["store"] as? String == "epic", "Managed Epic keeps the same contract")
        print("InstallOperations: \(checks) checks passed")
    }
}
