import Foundation
import Testing
@testable import CodexBarCore

struct CacheHitRateLinuxTests {
    @Test
    func `hit rate divides cache reads by new input plus cache writes plus cache reads`() {
        #expect(CacheHitRate.fraction(newInputTokens: 100, cacheCreationTokens: 300, cacheReadTokens: 600) == 0.6)
        #expect(CacheHitRate.fraction(newInputTokens: 100, cacheCreationTokens: 0, cacheReadTokens: 0) == 0)
        #expect(CacheHitRate.fraction(newInputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0) == nil)
    }

    @Test
    func `input that already includes cache reads is not counted twice`() {
        #expect(CacheHitRate.fraction(inputTokensIncludingCacheRead: 1000, cacheReadTokens: 750) == 0.75)
        #expect(CacheHitRate.fraction(inputTokensIncludingCacheRead: 100, cacheReadTokens: 250) == 1)
        #expect(CacheHitRate.fraction(inputTokensIncludingCacheRead: 0, cacheReadTokens: 0) == nil)
    }

    @Test
    func `daily entries use the accounting of their source`() {
        let entry = CostUsageDailyReport.Entry(
            date: "2026-06-07",
            inputTokens: 100,
            outputTokens: 50,
            cacheReadTokens: 60,
            cacheCreationTokens: 40,
            totalTokens: 250,
            costUSD: 1,
            modelsUsed: nil,
            modelBreakdowns: nil)
        #expect(entry.cacheHitRate(inputIncludesCacheRead: true) == 0.6)
        #expect(entry.cacheHitRate(inputIncludesCacheRead: false) == 0.3)

        let withoutCacheFields = CostUsageDailyReport.Entry(
            date: "2026-06-07",
            inputTokens: 100,
            outputTokens: 50,
            totalTokens: 150,
            costUSD: 1,
            modelsUsed: nil,
            modelBreakdowns: nil)
        #expect(withoutCacheFields.cacheHitRate(inputIncludesCacheRead: true) == 0)
        #expect(withoutCacheFields.cacheHitRate(inputIncludesCacheRead: false) == nil)

        let withoutInput = CostUsageDailyReport.Entry(
            date: "2026-06-07",
            inputTokens: nil,
            outputTokens: nil,
            cacheReadTokens: 60,
            totalTokens: 150,
            costUSD: 1,
            modelsUsed: nil,
            modelBreakdowns: nil)
        #expect(withoutInput.cacheHitRate(inputIncludesCacheRead: true) == nil)
        #expect(withoutInput.cacheHitRate(inputIncludesCacheRead: false) == nil)
    }

    @Test
    func `Codex sessions treat cached input as part of input`() {
        func session(input: Int?, cached: Int?) -> CostUsageSessionBreakdown {
            CostUsageSessionBreakdown(
                sessionID: "session-1",
                lastActivity: Date(timeIntervalSince1970: 100),
                inputTokens: input,
                cachedInputTokens: cached,
                outputTokens: 10,
                totalTokens: nil,
                requestCount: nil,
                costUSD: nil,
                modelBreakdowns: [])
        }
        #expect(session(input: 200, cached: 150).cacheHitRate == 0.75)
        #expect(session(input: 200, cached: nil).cacheHitRate == 0)
        #expect(session(input: nil, cached: 150).cacheHitRate == nil)
    }
}
