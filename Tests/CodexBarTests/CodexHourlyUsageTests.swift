import Foundation
import Testing
@testable import CodexBarCore

struct CodexHourlyUsageTests {
    @Test
    func `hourly builder creates 24 local hour buckets and preserves provider cost truth`() {
        let now = Date(timeIntervalSince1970: 1_786_400_100)
        let recent = now.addingTimeInterval(-20 * 60)
        let earlier = now.addingTimeInterval(-80 * 60)
        let entries = CostUsageScanner.buildCodexHourly24HourEntries(
            events: [
                .init(
                    timestampUnixMs: Int64(recent.timeIntervalSince1970 * 1000),
                    modelProvider: "openai",
                    totalTokens: 120,
                    knownCostNanos: 250_000_000,
                    hasUnpricedTokens: false),
                .init(
                    timestampUnixMs: Int64(earlier.timeIntervalSince1970 * 1000),
                    modelProvider: "codexbar_relay",
                    totalTokens: 80,
                    knownCostNanos: nil,
                    hasUnpricedTokens: true),
            ],
            now: now,
            calendar: Calendar(identifier: .gregorian))

        #expect(entries.count == 24)
        #expect(entries.reduce(0) { $0 + $1.totalTokens } == 200)
        #expect(entries.flatMap(\.modelProviderBreakdowns).contains {
            $0.modelProvider == "openai" && $0.totalTokens == 120 && $0.costUSD == 0.25
        })
        #expect(entries.flatMap(\.modelProviderBreakdowns).contains {
            $0.modelProvider == "codexbar_relay" && $0.totalTokens == 80 && $0.costUSD == nil
        })
    }

    @Test
    func `hourly builder returns no chart when there are no events in the window`() {
        let now = Date(timeIntervalSince1970: 1_786_400_100)
        let old = now.addingTimeInterval(-25 * 60 * 60)
        let entries = CostUsageScanner.buildCodexHourly24HourEntries(
            events: [
                .init(
                    timestampUnixMs: Int64(old.timeIntervalSince1970 * 1000),
                    modelProvider: "openai",
                    totalTokens: 10,
                    knownCostNanos: 1,
                    hasUnpricedTokens: false),
            ],
            now: now,
            calendar: .current)

        #expect(entries.isEmpty)
    }
}
