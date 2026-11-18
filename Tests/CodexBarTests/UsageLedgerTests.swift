import Foundation
import Testing
@testable import CodexBarCore

struct UsageLedgerTests {
    private let relayA = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let relayB = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    @Test
    func `ledger key preserves every M4 ownership dimension`() {
        let timestamp = Date(timeIntervalSince1970: 1_776_139_200)
        let key = UsageLedgerKey(
            identityID: "relay:\(self.relayA.uuidString.lowercased()):codex",
            routeProfileID: self.relayA,
            targetApp: .codex,
            model: "gpt-5.4",
            requestID: "request-7",
            sessionID: "session-3",
            timestamp: timestamp)

        #expect(key.identityID == "relay:11111111-1111-4111-8111-111111111111:codex")
        #expect(key.routeProfileID == self.relayA)
        #expect(key.targetApp == .codex)
        #expect(key.model == "gpt-5.4")
        #expect(key.requestID == "request-7")
        #expect(key.sessionID == "session-3")
        #expect(key.timestamp == timestamp)
    }

    @Test(arguments: UsageLedgerWindow.allCases)
    func `two official two relay and unassigned conserve every window`(window: UsageLedgerWindow) {
        let now = Date(timeIntervalSince1970: 1_776_225_600)
        let ages: [TimeInterval] = [60 * 60, 2 * 24 * 60 * 60, 10 * 24 * 60 * 60]
        let entries = ages.flatMap { age in
            [
                self.entry(identityID: "codex:managed:account-a", tokens: 10, age: age, now: now),
                self.entry(identityID: "codex:live:workspace-b", tokens: 20, age: age, now: now),
                self.entry(
                    identityID: "relay:\(self.relayA.uuidString.lowercased()):codex",
                    routeProfileID: self.relayA,
                    attribution: .relay,
                    tokens: 30,
                    age: age,
                    now: now),
                self.entry(
                    identityID: "relay:\(self.relayB.uuidString.lowercased()):codex",
                    routeProfileID: self.relayB,
                    attribution: .relay,
                    tokens: 40,
                    age: age,
                    now: now),
                self.entry(
                    identityID: "system-unassigned:fixture",
                    attribution: .unassigned,
                    tokens: 50,
                    age: age,
                    now: now),
            ]
        }
        let partition = UsageLedger(entries: entries).partition(for: window, endingAt: now)
        let includedPeriods = switch window {
        case .rolling24Hours: 1
        case .rolling7Days: 2
        case .rolling30Days: 3
        }

        #expect(partition.officialByIdentityID.count == 2)
        #expect(partition.relayByIdentityID.count == 2)
        #expect(partition.total.totalTokens == 150 * includedPeriods)
        #expect(partition.componentTotal.totalTokens == partition.total.totalTokens)
        #expect(partition.isConserved)
    }

    @Test
    func `inactive official account excludes relay and direct API usage`() {
        let now = Date(timeIntervalSince1970: 1_776_225_600)
        let inactiveID = "codex:live:workspace-b"
        let directAPIID = "api:openai:33333333-3333-4333-8333-333333333333"
        let ledger = UsageLedger(entries: [
            self.entry(identityID: "codex:managed:account-a", tokens: 100, age: 10, now: now),
            self.entry(identityID: inactiveID, tokens: 200, age: 20, now: now),
            self.entry(
                identityID: inactiveID,
                routeProfileID: self.relayA,
                attribution: .relay,
                tokens: 300,
                age: 30,
                now: now),
            self.entry(
                identityID: directAPIID,
                attribution: .relay,
                tokens: 400,
                age: 40,
                now: now),
        ])

        let partition = ledger.partition(for: .rolling24Hours, endingAt: now)
        #expect(partition.officialByIdentityID[inactiveID]?.totalTokens == 200)
        #expect(partition.relayByIdentityID.values.reduce(0) { $0 + $1.totalTokens } == 700)
        #expect(ledger.officialSummary(
            identityID: inactiveID,
            for: .rolling24Hours,
            endingAt: now).totalTokens == 200)
        #expect(partition.isConserved)
    }

    private func entry(
        identityID: String,
        routeProfileID: UUID? = nil,
        attribution: UsageLedgerAttribution = .official,
        tokens: Int,
        age: TimeInterval,
        now: Date) -> UsageLedgerEntry
    {
        UsageLedgerEntry(
            key: UsageLedgerKey(
                identityID: identityID,
                routeProfileID: routeProfileID,
                targetApp: .codex,
                model: "gpt-5.4",
                requestID: "request-\(tokens)-\(Int(age))",
                sessionID: "session-\(identityID)",
                timestamp: now.addingTimeInterval(-age)),
            attribution: attribution,
            amounts: UsageLedgerAmounts(
                inputTokens: tokens,
                outputTokens: 0,
                cacheReadTokens: 0,
                cacheCreationTokens: 0,
                totalTokens: tokens,
                requestCount: 1,
                costUSD: Double(tokens) / 1000))
    }
}
