import Foundation

final class ProfileProgression {
    static let hours = [0.0, 1, 10, 50, 100, 250, 500, 1000]
    static let rewards = [1, 2, 5, 10, 50, 100, 1000, 10000]
    static let levels: [(Int, String)] = [(0,"Nouveau venu"),(25,"Curieux"),(100,"Explorateur"),(250,"Passionné"),(1000,"Collectionneur"),(2500,"Vétéran"),(10000,"Maître du jeu"),(25000,"Légende Playmelt"),(100000,"Mythe")]
    private let file: URL
    private var accounts: [String:[String:[String:Any]]] = [:]
    init(file: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Playmelt/profile-progression.json")) {
        self.file = file
        if let data = try? Data(contentsOf:file), data.count < 12_000_000,
           let root = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
           root["schema"] as? Int == 1,
           let saved = root["accounts"] as? [String:[String:[String:Any]]] { accounts = saved }
    }
    static func points(rank: Int) -> Int { rewards.prefix(max(0, min(rank, 7)) + 1).reduce(0,+) }
    func snapshot(games: [[String:Any]], account: String) -> [String:Any] {
        let account = account.isEmpty ? "local" : account
        var entries = accounts[account] ?? [:], changed = false
        for game in games {
            guard let title = game["title"] as? String, !title.isEmpty, title.count <= 200 else { continue }
            let seconds = max(0, ((game["playtime"] as? NSNumber)?.doubleValue ?? 0))
            guard seconds.isFinite, seconds > 0 || game["installed"] as? Bool == true else { continue }
            let key = HubText.normalized(title)
            let level = Self.hours.lastIndex(where: { seconds >= $0 * 3600 }) ?? 0
            let previous = entries[key]
            let highest = max(previous?["rank"] as? Int ?? 0, level)
            let knownTime = max(previous?["playtime"] as? Double ?? 0, seconds)
            if previous == nil || highest > (previous?["rank"] as? Int ?? 0) || knownTime > (previous?["playtime"] as? Double ?? 0) {
                entries[key] = ["title":title, "rank":highest, "playtime":knownTime,
                    "store":game["store"] as? String ?? "local", "gameId":game["id"] as? String ?? "",
                    "image":game["portraitImageURL"] as? String ?? game["imageURL"] as? String ?? ""]
                changed = true
            }
        }
        var warning = ""
        if changed {
            accounts[account] = entries
            do {
                try FileManager.default.createDirectory(at:file.deletingLastPathComponent(), withIntermediateDirectories:true)
                let data = try JSONSerialization.data(withJSONObject:["schema":1,"accounts":accounts], options:[.sortedKeys])
                try data.write(to:file, options:.atomic)
            } catch { warning = "Les points n’ont pas pu être enregistrés sur ce Mac." }
        }
        let rows: [[String:Any]] = entries.values.map { entry in
            var item = entry; item["points"] = Self.points(rank:entry["rank"] as? Int ?? 0); return item
        }.sorted { a,b in
            let av = a["points"] as? Int ?? 0, bv = b["points"] as? Int ?? 0
            return av == bv ? (a["title"] as? String ?? "") < (b["title"] as? String ?? "") : av > bv
        }
        let total = rows.reduce(0) { $0 + ($1["points"] as? Int ?? 0) }
        let level = Self.levels.lastIndex(where: { total >= $0.0 }) ?? 0
        return ["points":total, "level":level + 1, "name":Self.levels[level].1,
            "floor":Self.levels[level].0, "next":level + 1 < Self.levels.count ? Self.levels[level + 1].0 : NSNull(),
            "entries":rows, "rewards":Self.rewards, "warning":warning,
            "levels":Self.levels.enumerated().map { ["level":$0.offset + 1,"points":$0.element.0,"name":$0.element.1] }]
    }
}
