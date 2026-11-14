import Foundation

@main enum SteamLocalAchievementsTests {
    indirect enum KV { case text(String), number(Int32), object([(String, KV)]) }
    static func encoded(_ rows: [(String, KV)]) -> Data {
        var data = Data()
        for (key, value) in rows {
            switch value { case .text: data.append(1); case .number: data.append(2); case .object: data.append(0) }
            data.append(contentsOf: key.utf8); data.append(0)
            switch value {
            case .text(let text): data.append(contentsOf: text.utf8); data.append(0)
            case .number(let number): var little = number.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
            case .object(let children): data.append(encoded(children))
            }
        }
        data.append(8); return data
    }
    static func main() throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) { checks += 1; precondition(condition(), label) }
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("PlaymeltAchievementFixture-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let accountA = "76561197960265839", accountB = "76561197960265950"
        expect(SteamLocalAchievements.userCacheNames(appID: "10", accountID: accountA).first == "UserGameStats_111_10.bin", "Steam64 binds the correct 32-bit cache")
        for pair in [("../10", accountA), ("１", accountA), ("10", "../111"), ("0", accountA), ("10", "")] {
            expect(SteamLocalAchievements.userCacheNames(appID: pair.0, accountID: pair.1).isEmpty, "invalid identifiers cannot choose a cache path")
        }
        func achievement(_ name: String) -> KV { .object([("name", .text(name)), ("display", .object([("name", .text(name)), ("desc", .text("fixture")), ("icon", .text("fixture.jpg"))]))]) }
        let schema = root.appendingPathComponent("UserGameStatsSchema_10.bin")
        try encoded([("10", .object([("stats", .object([("1", .object([("bits", .object([("0", achievement("A")), ("1", achievement("B"))]))]))]))]))]).write(to: schema)
        func writeUser(_ number: String, bits: Int32, at: Double) throws {
            let url = root.appendingPathComponent("UserGameStats_" + number + "_10.bin")
            try encoded([("10", .object([("1", .object([("data", .number(bits)), ("AchievementTimes", .object([("0", .number(10)), ("1", .number(20))]))]))]))]).write(to: url)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: at)], ofItemAtPath: url.path)
        }
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: schema.path)
        try writeUser("111", bits: 1, at: 100); try writeUser("222", bits: 2, at: 200)
        let reader = SteamLocalAchievements(directory: root)
        func names(_ account: String) -> [String] { (reader.payload(appID: "10", accountID: account)?["completed"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String } }
        expect(names(accountA) == ["A"], "a newer other-account file never replaces selected-account stats")
        expect(names(accountB) == ["B"], "switching account changes the cache identity")
        expect(names(accountA) == ["A"], "switching back does not reuse another account's payload")
        expect(reader.payload(appID: "10", accountID: "76561197960266061") == nil, "missing selected account never falls back to another user")
        try writeUser("111", bits: 3, at: 300)
        expect(names(accountA) == ["B", "A"], "user changes invalidate the cache even when the schema timestamp is newer")
        expect(reader.payload(appID: "10", accountID: accountA)?["total"] as? Int == 2, "schema total is preserved")
        expect(reader.payload(appID: "10", accountID: accountA)?["source"] as? String == "steam-local", "source remains explicit")
        expect(SteamLocalAchievements.parse([255, 0]).isEmpty, "unknown binary key-value tags are rejected")
        let fullIDPath = root.appendingPathComponent("UserGameStats_" + accountA + "_10.bin")
        try Data([8]).write(to: fullIDPath)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1500)], ofItemAtPath: fullIDPath.path)
        expect(SteamLocalAchievements(directory: root).payload(appID: "10", accountID: accountA)?["unlockedCount"] as? Int == 0, "full-ID format stays bound to the same account")
        print("Steam local achievements: \(checks) fixture checks passed; no real account, network or game")
    }
}
