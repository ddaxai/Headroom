import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageCodexSplitNormalizationTests {
    @Test
    func `inflated mode split is normalized to the canonical total`() throws {
        let day = "2026-08-09"
        let model = "gpt-5.4"
        var cache = CostUsageCache()
        cache.days = [day: [model: [4000, 0, 1200]]]
        cache.files = [
            "parent": Self.fileUsage(
                day: day,
                model: model,
                tokens: (standard: 5000, priority: 0),
                costs: (standard: 5_000_000_000, priority: 0),
                canonicalCostNanos: 5_400_000_000),
            "child": Self.fileUsage(
                day: day,
                model: model,
                tokens: (standard: 5000, priority: 200),
                costs: (standard: 5_000_000_000, priority: 400_000_000),
                canonicalCostNanos: 0),
        ]
        let range = Self.range(for: day)

        let report = CostUsageScanner.buildCodexReportFromCache(
            cache: cache,
            range: range,
            modelsDevCatalog: ModelsDevCatalog(providers: [:]))
        let split = try #require(report.data.first?.modelBreakdowns?.first)

        #expect(split.totalTokens == 5200)
        #expect((split.standardTokens ?? 0) + (split.priorityTokens ?? 0) == 5200)
        #expect(split.standardTokens == 5098)
        #expect(split.priorityTokens == 102)
        #expect(split.splitEstimateNormalized)
        #expect(abs((split.costUSD ?? 0) - 5.4) < 0.000_000_001)
        #expect(abs((split.standardCostUSD ?? 0) + (split.priorityCostUSD ?? 0) - 5.4) < 0.000_000_001)
    }

    @Test
    func `normal mode split is not marked as normalized`() throws {
        let day = "2026-08-09"
        let model = "gpt-5.4"
        var cache = CostUsageCache()
        cache.days = [day: [model: [4000, 0, 1200]]]
        cache.files = [
            "canonical": Self.fileUsage(
                day: day,
                model: model,
                tokens: (standard: 5000, priority: 200),
                costs: (standard: 5_000_000_000, priority: 400_000_000),
                canonicalCostNanos: 5_400_000_000),
        ]

        let report = CostUsageScanner.buildCodexReportFromCache(
            cache: cache,
            range: Self.range(for: day),
            modelsDevCatalog: ModelsDevCatalog(providers: [:]))
        let split = try #require(report.data.first?.modelBreakdowns?.first)

        #expect(split.standardTokens == 5000)
        #expect(split.priorityTokens == 200)
        #expect(!split.splitEstimateNormalized)
    }

    @Test
    func `split normalization clamps corrupt and extreme cache values without overflow`() {
        let negative = CostUsageScanner.normalizedCodexModeSplit(
            canonicalTotalTokens: 100,
            standardTokens: -1,
            priorityTokens: 20,
            standardCostUSD: nil,
            priorityCostUSD: 1)
        #expect(negative.standardTokens == 0)
        #expect(negative.priorityTokens == 20)
        #expect(negative.wasNormalized)

        let extreme = CostUsageScanner.normalizedCodexModeSplit(
            canonicalTotalTokens: Int.max,
            standardTokens: Int.max,
            priorityTokens: 1,
            standardCostUSD: 1,
            priorityCostUSD: 1)
        #expect((extreme.standardTokens ?? 0) <= Int.max)
        #expect((extreme.priorityTokens ?? 0) >= 0)
        #expect((extreme.standardTokens ?? 0) + (extreme.priorityTokens ?? 0) == Int.max)
        #expect(extreme.wasNormalized)
    }

    private static func range(for day: String) -> CostUsageScanner.CostUsageDayRange {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.date(from: day)!
        return CostUsageScanner.CostUsageDayRange(since: date, until: date, calendar: formatter.calendar)
    }

    private static func fileUsage(
        day: String,
        model: String,
        tokens: (standard: Int, priority: Int),
        costs: (standard: Int64, priority: Int64),
        canonicalCostNanos: Int64) -> CostUsageFileUsage
    {
        let standardCosts = [day: [model: costs.standard]]
        let priorityCosts = [day: [model: costs.priority]]
        let canonicalCosts = [day: [model: canonicalCostNanos]]
        let standardTokenMap = [day: [model: tokens.standard]]
        let priorityTokenMap = [day: [model: tokens.priority]]
        return CostUsageScanner.makeFileUsage(
            mtimeUnixMs: 1,
            size: 1,
            days: [:],
            parsedBytes: 1,
            codexCostNanos: canonicalCosts,
            codexStandardCostNanos: standardCosts,
            codexPriorityCostNanos: priorityCosts,
            codexStandardTokens: standardTokenMap,
            codexPriorityTokens: priorityTokenMap)
    }
}
