import Foundation

/// A single presentation contract for managed transfers and transfers adopted
/// from a connected client. Reading this catalogue never starts an installation.
enum InstallOperations {
    private static let terminal: Set<String> = ["completed", "launched", "launch-ready", "failed", "cancelled"]

    static func snapshots(managed: [String: Any]?, observed: [[String: Any]]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        var identities = Set<String>()
        if var managed, let id = managed["id"] as? String, !id.isEmpty {
            // Existing Steam jobs predate the store field. Epic already emits it.
            if managed["store"] == nil { managed["store"] = "steam" }
            result.append(managed); identities.insert(id)
        }
        for var job in observed.prefix(200) {
            guard let id = job["id"] as? String, id.hasPrefix("gog:"), id.utf8.count <= 160,
                  job["store"] as? String == "gog",
                  let appID = job["appId"] as? String, !appID.isEmpty, appID.utf8.count <= 32,
                  appID.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  job["gameId"] as? String == "gog:" + appID,
                  identities.insert(id).inserted else { continue }
            // Observing a third-party job does not grant control over it, nor
            // permission to launch a game when an old transfer later completes.
            job["observed"] = true
            job["autoLaunch"] = false
            job["cancellable"] = false
            job["retryable"] = false
            result.append(job)
        }
        return result
    }

    static func hasActiveTransfer(_ jobs: [[String: Any]]) -> Bool {
        jobs.contains { job in
            guard let status = job["status"] as? String else { return false }
            return !terminal.contains(status)
        }
    }
}
