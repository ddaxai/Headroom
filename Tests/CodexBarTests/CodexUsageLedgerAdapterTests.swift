import Foundation
import Testing
@testable import CodexBarCore

struct CodexUsageLedgerAdapterTests {
    @Test
    func `Codex token rows keep disjoint token columns without double counting reasoning`() throws {
        let timestamp = Date(timeIntervalSince1970: 1_720_000_000)
        var timeline = CodexSessionOwnershipTimeline()
        timeline.recordActivation(
            accountKey: "codex:managed:account-a",
            atUnixMilliseconds: Int64(timestamp.timeIntervalSince1970 * 1000) - 1)
        timeline.recordOfficialCodexRoute(
            atUnixMilliseconds: Int64(timestamp.timeIntervalSince1970 * 1000) - 1)

        let entries = CodexUsageLedgerAdapter.entries(
            sessionID: "session-a",
            modelProvider: CodexSessionProvenanceClassifier.sharedProvider,
            rows: [Self.row(timestamp: timestamp, input: 100, cached: 40, output: 30, reasoning: 10)],
            timeline: timeline)

        let entry = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(entry.key.identityID == "codex:managed:account-a")
        #expect(entry.attribution == .official)
        #expect(entry.amounts.inputTokens == 60)
        #expect(entry.amounts.cacheReadTokens == 40)
        #expect(entry.amounts.cacheCreationTokens == 0)
        #expect(entry.amounts.outputTokens == 30)
        #expect(entry.amounts.totalTokens == 130)
        #expect(entry.amounts.requestCount == 1)
    }

    @Test
    func `relay and unknown rows remain in conserved ledger buckets`() throws {
        let base = Date(timeIntervalSince1970: 1_720_000_000)
        let relayProfileID = try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        var timeline = CodexSessionOwnershipTimeline()
        timeline.recordCodexRelayActivation(
            profileID: relayProfileID,
            atUnixMilliseconds: Int64(base.timeIntervalSince1970 * 1000) - 1)

        let relayEntries = CodexUsageLedgerAdapter.entries(
            sessionID: "relay-session",
            modelProvider: CodexSessionProvenanceClassifier.sharedProvider,
            rows: [Self.row(timestamp: base, input: 20, cached: 5, output: 10)],
            timeline: timeline)
        let unknownEntries = CodexUsageLedgerAdapter.entries(
            sessionID: "unknown-session",
            modelProvider: "unknown-provider",
            rows: [Self.row(timestamp: base.addingTimeInterval(1), input: 8, cached: 0, output: 2)],
            timeline: timeline)

        let relay = try #require(relayEntries.first)
        #expect(relay.key.identityID == "relay:\(relayProfileID.uuidString.lowercased()):codex")
        #expect(relay.key.routeProfileID == relayProfileID)
        #expect(relay.attribution == .relay)
        let unknown = try #require(unknownEntries.first)
        #expect(unknown.key.identityID == "system-unassigned:codex")
        #expect(unknown.attribution == .unassigned)

        let partition = UsageLedger(entries: relayEntries + unknownEntries)
            .partition(for: .rolling24Hours, endingAt: base.addingTimeInterval(60))
        #expect(partition.isConserved)
        #expect(partition.total.totalTokens == 40)
        #expect(partition.unassigned.totalTokens == 10)
    }

    @Test
    func `distinct scanner rows sharing one request id remain distinct ledger events`() {
        let base = Date(timeIntervalSince1970: 1_720_000_000)
        let rows = [
            Self.row(timestamp: base, eventIndex: 1, input: 10, cached: 0, output: 1),
            Self.row(timestamp: base.addingTimeInterval(1), eventIndex: 2, input: 15, cached: 5, output: 2),
        ]
        let entries = CodexUsageLedgerAdapter.entries(
            sessionID: "session-a",
            modelProvider: "unknown-provider",
            rows: rows,
            timeline: CodexSessionOwnershipTimeline())

        #expect(entries.count == 2)
        #expect(UsageLedger(entries: entries).partition(
            for: .rolling24Hours,
            endingAt: base.addingTimeInterval(60)).total.totalTokens == 28)
    }

    private static func row(
        timestamp: Date,
        eventIndex: Int = 1,
        input: Int,
        cached: Int,
        output: Int,
        reasoning: Int? = nil) -> CostUsageScanner.CodexUsageRow
    {
        CostUsageScanner.CodexUsageRow(
            day: "2024-07-03",
            model: "gpt-5",
            turnID: "turn-a",
            eventIndex: eventIndex,
            timestampUnixMs: Int64(timestamp.timeIntervalSince1970 * 1000),
            input: input,
            cached: cached,
            output: output,
            reasoning: reasoning,
            knownCostNanos: 100_000_000)
    }
}
