import Foundation
import Testing
@testable import CodexBarCore

@Suite("M5 S3 local meter deduplication")
struct LocalMeterDeduplicationTests {
    private let profileID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    @Test
    func `retry replaces an aborted attempt instead of double counting it`() async {
        let accumulator = LocalMeterUsageAccumulator()
        let context = self.context(requestID: "request-retry")

        await accumulator.record(.begin(context: context, attemptID: "attempt-1", inputTokens: 120))
        await accumulator.record(.output(
            requestID: context.requestID,
            attemptID: "attempt-1",
            unitID: "partial",
            tokens: 20))
        await accumulator.record(.abort(requestID: context.requestID, attemptID: "attempt-1"))
        await accumulator.record(.begin(context: context, attemptID: "attempt-2", inputTokens: 120))
        await accumulator.record(.output(
            requestID: context.requestID,
            attemptID: "attempt-2",
            unitID: "final",
            tokens: 30))
        await accumulator.record(.complete(requestID: context.requestID, attemptID: "attempt-2"))

        let records = await accumulator.records
        #expect(records.count == 1)
        #expect(records.first?.entry.amounts.inputTokens == 120)
        #expect(records.first?.entry.amounts.outputTokens == 30)
        #expect(records.first?.entry.amounts.totalTokens == 150)
        #expect(records.first?.entry.amounts.requestCount == 1)
    }

    @Test
    func `stream reconnect replay counts each output unit once`() async {
        let accumulator = LocalMeterUsageAccumulator()
        let context = self.context(requestID: "request-reconnect")

        await accumulator.record(.begin(context: context, attemptID: "attempt-1", inputTokens: 80))
        for (unitID, tokens) in [("event-1", 10), ("event-2", 12), ("event-1", 10), ("event-2", 12),
                                 ("event-3", 8)]
        {
            await accumulator.record(.output(
                requestID: context.requestID,
                attemptID: "attempt-1",
                unitID: unitID,
                tokens: tokens))
        }
        await accumulator.record(.complete(requestID: context.requestID, attemptID: "attempt-1"))

        let record = await accumulator.records.first
        #expect(record?.entry.amounts.outputTokens == 30)
        #expect(record?.entry.amounts.totalTokens == 110)
    }

    @Test
    func `aborted stream does not publish an incomplete ledger entry`() async {
        let accumulator = LocalMeterUsageAccumulator()
        let context = self.context(requestID: "request-aborted")

        await accumulator.record(.begin(context: context, attemptID: "attempt-1", inputTokens: 40))
        await accumulator.record(.output(
            requestID: context.requestID,
            attemptID: "attempt-1",
            unitID: "partial",
            tokens: 9))
        await accumulator.record(.abort(requestID: context.requestID, attemptID: "attempt-1"))

        #expect(await accumulator.records.isEmpty)
    }

    @Test
    func `same request id written and completed repeatedly stays one entry`() async {
        let accumulator = LocalMeterUsageAccumulator()
        let context = self.context(requestID: "request-duplicate")

        for attemptID in ["attempt-1", "attempt-2"] {
            await accumulator.record(.begin(context: context, attemptID: attemptID, inputTokens: 50))
            await accumulator.record(.output(
                requestID: context.requestID,
                attemptID: attemptID,
                unitID: "whole-response",
                tokens: 25))
            await accumulator.record(.complete(requestID: context.requestID, attemptID: attemptID))
        }

        let records = await accumulator.records
        #expect(records.count == 1)
        #expect(records.first?.entry.amounts.totalTokens == 75)
        #expect(records.first?.entry.key.requestID == context.requestID)
    }

    @Test
    func `meter records use the M4 key and conserve all three windows`() async {
        let now = Date(timeIntervalSince1970: 1_787_500_000)
        let accumulator = LocalMeterUsageAccumulator()
        let fixtures: [(String, TimeInterval, Int)] = [
            ("recent", 60 * 60, 100),
            ("week", 2 * 24 * 60 * 60, 200),
            ("month", 10 * 24 * 60 * 60, 300),
        ]

        for (requestID, age, tokens) in fixtures {
            let context = self.context(
                requestID: requestID,
                startedAt: now.addingTimeInterval(-age))
            await accumulator.record(.begin(context: context, attemptID: "attempt", inputTokens: tokens))
            await accumulator.record(.complete(requestID: requestID, attemptID: "attempt"))
        }

        let records = await accumulator.records
        let recent = records.first { $0.entry.key.requestID == "recent" }
        #expect(recent?.entry.key == UsageLedgerKey(
            identityID: "relay:\(self.profileID.uuidString.lowercased()):codex",
            routeProfileID: self.profileID,
            targetApp: .codex,
            model: "gpt-5.4",
            requestID: "recent",
            sessionID: "session-fixture",
            timestamp: now.addingTimeInterval(-60 * 60)))

        let ledger = UsageLedger(entries: records.map(\.entry))
        let expectedTotals: [UsageLedgerWindow: Int] = [
            .rolling24Hours: 100,
            .rolling7Days: 300,
            .rolling30Days: 600,
        ]
        for window in UsageLedgerWindow.allCases {
            let partition = ledger.partition(for: window, endingAt: now)
            #expect(partition.total.totalTokens == expectedTotals[window])
            #expect(partition.componentTotal == partition.total)
            #expect(partition.isConserved)
        }
    }

    @Test
    func `serialized meter record contains fingerprint but never plaintext key`() async throws {
        let plaintextKey = "sk-live-must-never-be-persisted"
        let fingerprint = try #require(LocalMeterCredentialFingerprint(apiKey: plaintextKey))
        let accumulator = LocalMeterUsageAccumulator()
        let context = self.context(
            requestID: "request-secret",
            credentialFingerprint: fingerprint)

        await accumulator.record(.begin(context: context, attemptID: "attempt", inputTokens: 10))
        await accumulator.record(.complete(requestID: context.requestID, attemptID: "attempt"))

        let record = try #require(await accumulator.records.first)
        let encoded = try JSONEncoder().encode(record)
        let json = String(decoding: encoded, as: UTF8.self)
        #expect(!json.contains(plaintextKey))
        #expect(json.contains(fingerprint.value))
        #expect(fingerprint.value.count == 64)
    }

    private func context(
        requestID: String,
        startedAt: Date = Date(timeIntervalSince1970: 1_787_500_000),
        credentialFingerprint: LocalMeterCredentialFingerprint? = nil) -> LocalMeterRequestContext
    {
        LocalMeterRequestContext(
            requestID: requestID,
            sessionID: "session-fixture",
            routeProfileID: self.profileID,
            targetApp: .codex,
            model: "gpt-5.4",
            startedAt: startedAt,
            credentialFingerprint: credentialFingerprint)
    }
}
