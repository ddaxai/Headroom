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
    func `daily entries count each prompt token once whatever the source's accounting`() {
        func entry(input: Int?, output: Int?, read: Int?, write: Int?, total: Int?) -> CostUsageDailyReport.Entry {
            CostUsageDailyReport.Entry(
                date: "2026-06-07",
                inputTokens: input,
                outputTokens: output,
                cacheReadTokens: read,
                cacheCreationTokens: write,
                totalTokens: total,
                costUSD: 1,
                modelsUsed: nil,
                modelBreakdowns: nil)
        }

        // Codex: input includes the cache reads.
        let codex = entry(input: 1000, output: 50, read: 600, write: nil, total: 1050)
        #expect(codex.cacheHitRate == 0.6)
        // Claude and Pi: input, cache reads and cache writes are separate.
        let pi = entry(input: 100, output: 50, read: 900, write: 0, total: 1050)
        #expect(pi.cacheHitRate == 0.9)
        #expect(entry(input: 100, output: 50, read: 60, write: 40, total: 250).cacheHitRate == 0.3)

        // A Codex day with Pi usage merged in: 1500 of 2000 prompt tokens were cache reads.
        let merged = CostUsageDailyReport.merged([
            CostUsageDailyReport(data: [codex], summary: nil),
            CostUsageDailyReport(data: [pi], summary: nil),
        ])
        #expect(merged.data.first?.cacheHitRate == 0.75)

        #expect(entry(input: 100, output: 50, read: nil, write: nil, total: 150).cacheHitRate == 0)
        #expect(entry(input: 100, output: 50, read: 60, write: nil, total: nil).cacheHitRate == nil)
        #expect(entry(input: nil, output: nil, read: 60, write: nil, total: 150).cacheHitRate == nil)
        #expect(entry(input: 0, output: 50, read: 0, write: nil, total: 50).cacheHitRate == nil)
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
