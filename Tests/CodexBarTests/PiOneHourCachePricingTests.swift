import Foundation
import Testing
@testable import CodexBarCore

struct PiOneHourCachePricingTests {
    @Test(arguments: ["cacheWrite1h", "cache_write_1h", "ephemeral1h", "ephemeral_1h"])
    func `pi one hour cache counters retain total tokens and receive the one hour tariff`(spelling: String) throws {
        let report = try Self.scan(spelling: spelling, value: 40)
        #expect(report.summary?.totalTokens == 204)
        // Sonnet 5.5: 80 input, 20 output, 4 reads, 60 five-minute writes, 40 one-hour writes.
        #expect(abs((report.summary?.totalCostUSD ?? 0) - 0.0006708) < 1e-10)
    }

    @Test(arguments: ["cacheWrite1h", "cache_write_1h", "ephemeral1h", "ephemeral_1h"])
    func `invalid retention counters preserve measured tokens without fabricating a price`(spelling: String) throws {
        for value: Any in [NSNull(), true, "junk", -5, 101, 1e19, Double(Int.max), "9223372036854775808"] {
            let report = try Self.scan(spelling: spelling, value: value)
            #expect(report.summary?.totalTokens == 204)
            #expect(report.summary?.totalCostUSD == nil)
        }
    }

    private static func scan(spelling: String, value: Any) throws -> CostUsageDailyReport {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 10, day: 4)
        var usage: [String: Any] = ["input": 80, "output": 20, "cacheRead": 4, "cacheWrite": 100]
        if spelling.hasPrefix("ephemeral") {
            usage["cttl"] = [spelling: value]
        } else {
            usage[spelling] = value
        }
        _ = try env.writePiSessionFile(relativePath: "one-hour.jsonl", contents: env.jsonl([[
            "type": "message", "timestamp": env.isoString(for: day),
            "message": ["role": "assistant", "provider": "anthropic", "model": "claude-sonnet-5-5", "usage": usage],
        ]]))
        return PiSessionCostScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: .init(piSessionsRoot: env.piSessionsRoot, cacheRoot: env.cacheRoot))
    }
}
