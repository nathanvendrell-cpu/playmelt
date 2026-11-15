import Foundation

enum UnifiedBrowserSessionManager {
    static func synchronizeAllSessions() {}
}

@main
enum GeForceUsageTests {
    static func main() {
        print("Running GeForceUsageTests...")
        testDefaultPerformanceTier()
        testSessionAccumulationAndMonthlyFilter()
        testUltimateTier()
        testFoundersTier()
        testFreeTier()
        testRolloverCap()
        testPersistence()
        print("All 7 GeForceUsage tests passed successfully!")
    }

    static func testDefaultPerformanceTier() {
        let usage = GeForceUsage()
        assert(usage.tier == "performance", "Default tier should be performance")
        assert(usage.sessionLimitHours() == 6, "Performance session limit should be 6h")
        assert(usage.monthlyQuotaSeconds() == 100 * 3600, "Performance monthly quota should be 100h")
        assert(usage.remainingHoursThisMonth() == 100, "Remaining hours should be 100 initially")
        let payload = usage.payload()
        assert((payload["tier"] as? String) == "performance", "Payload tier should match")
        assert((payload["remainingHours"] as? Int) == 100, "Payload remaining hours should be 100")
        assert((payload["isUnlimited"] as? Bool) == false, "Performance is not unlimited")
    }

    static func testSessionAccumulationAndMonthlyFilter() {
        let calendar = Calendar.current
        let now = Date()
        let currentMonth = calendar.component(.month, from: now)
        let currentYear = calendar.component(.year, from: now)

        var usage = GeForceUsage()
        // Session in current month: 2 hours (7200s)
        usage.sessions.append(GeForceUsage.Session(timestamp: now.timeIntervalSince1970, durationSeconds: 7200, title: "Cyberpunk 2077"))
        // Session in current month: 1.5 hours (5400s)
        usage.sessions.append(GeForceUsage.Session(timestamp: now.timeIntervalSince1970 - 3600, durationSeconds: 5400, title: "Witcher 3"))

        // Session from previous month: 10 hours (should NOT count in current month)
        var prevComponents = DateComponents()
        prevComponents.year = currentMonth == 1 ? currentYear - 1 : currentYear
        prevComponents.month = currentMonth == 1 ? 12 : currentMonth - 1
        prevComponents.day = 15
        if let prevDate = calendar.date(from: prevComponents) {
            usage.sessions.append(GeForceUsage.Session(timestamp: prevDate.timeIntervalSince1970, durationSeconds: 36000, title: "Old Game"))
        }

        let used = usage.usedSecondsThisMonth(now: now)
        assert(used == 12600, "Used seconds this month should be 12600 (3.5 hours)")
        // 100h - 3.5h = 96.5h -> ceil is 97h remaining
        assert(usage.remainingHoursThisMonth(now: now) == 97, "Remaining hours should be 97")
    }

    static func testUltimateTier() {
        var usage = GeForceUsage()
        usage.tier = "ultimate"
        assert(usage.sessionLimitHours() == 8, "Ultimate session limit should be 8h")
        assert(usage.monthlyQuotaSeconds() == 100 * 3600, "Ultimate monthly quota should be 100h")
        let payload = usage.payload()
        assert((payload["sessionLimitHours"] as? Int) == 8, "Payload session limit should be 8")
    }

    static func testFoundersTier() {
        var usage = GeForceUsage()
        usage.tier = "founders"
        assert(usage.sessionLimitHours() == 6, "Founders session limit should be 6h")
        assert(usage.monthlyQuotaSeconds() == -1, "Founders monthly quota should be -1 (unlimited)")
        assert(usage.remainingHoursThisMonth() == -1, "Founders remaining hours should be -1")
        let payload = usage.payload()
        assert((payload["isUnlimited"] as? Bool) == true, "Founders isUnlimited should be true")
        assert((payload["remainingHours"] as? Int) == -1, "Founders remaining hours in payload should be -1")
    }

    static func testFreeTier() {
        var usage = GeForceUsage()
        usage.tier = "free"
        assert(usage.sessionLimitHours() == 1, "Free tier session limit should be 1h")
        assert(usage.monthlyQuotaSeconds() == nil, "Free tier monthly quota should be nil")
        assert(usage.remainingHoursThisMonth() == nil, "Free tier remaining hours should be nil")
        let payload = usage.payload()
        assert((payload["isPerSessionOnly"] as? Bool) == true, "Free tier isPerSessionOnly should be true")
    }

    static func testRolloverCap() {
        var usage = GeForceUsage()
        usage.tier = "performance"
        // Rollover of 20 hours should be capped at 15 hours
        usage.rolloverSeconds = 20 * 3600
        let quota = usage.monthlyQuotaSeconds() ?? 0
        assert(quota == 115 * 3600, "Performance quota with max rollover should be 115 hours")
    }

    static func testPersistence() {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("geforce-usage-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        var usage = GeForceUsage()
        usage.tier = "ultimate"
        usage.sessions.append(GeForceUsage.Session(timestamp: 1731630000, durationSeconds: 3600, title: "Test Game"))
        usage.save(to: tempURL)

        let loaded = GeForceUsage.load(from: tempURL)
        assert(loaded.tier == "ultimate", "Loaded tier should match")
        assert(loaded.sessions.count == 1, "Loaded sessions count should match")
        assert(loaded.sessions.first?.title == "Test Game", "Loaded session title should match")
    }
}
