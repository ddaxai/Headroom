import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CodexPartitionedSubagentAccountingTests {
    @Test
    func `explicit subagent baseline follows parent when parent continued after fork`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2032, month: 4, day: 9)
        let fork = day.addingTimeInterval(20)
        let model = "openai/gpt-5.6-sol"
        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "parent.jsonl",
            contents: env.jsonl([
                ["type": "session_meta", "timestamp": env.isoString(for: day), "payload": ["id": "parent-session"]],
                Self.tokenCount(env: env, timestamp: day.addingTimeInterval(10), model: model, total: (2000, 1800, 20), last: (2000, 1800, 20)),
            ]))
        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "child.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": env.isoString(for: fork),
                    "payload": [
                        "id": "child-session",
                        "forked_from_id": "parent-session",
                        "source": ["subagent": ["thread_spawn": ["parent_thread_id": "parent-session"]]],
                    ],
                ],
                Self.tokenCount(env: env, timestamp: day.addingTimeInterval(21), model: model, total: (1000, 900, 10), last: (1000, 900, 10)),
                Self.tokenCount(env: env, timestamp: day.addingTimeInterval(22), model: model, total: (2100, 1890, 21), last: (100, 90, 1)),
            ]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        let scanned = report.data.reduce(0) {
            $0 + ($1.inputTokens ?? 0) + ($1.cacheReadTokens ?? 0) + ($1.outputTokens ?? 0)
        }
        #expect(scanned == 4011)
    }

    @Test
    func `shared subagent partition scans conserve full usage`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2032, month: 4, day: 8)
        let first = day.addingTimeInterval(1)
        let second = day.addingTimeInterval(20)
        let third = day.addingTimeInterval(30)
        let model = "openai/gpt-5.6-sol"
        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "shared-subagent.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": env.isoString(for: day),
                    "payload": [
                        "id": "child-session",
                        "forked_from_id": "parent-session",
                        "model_provider": CodexSessionProvenanceClassifier.sharedProvider,
                        "source": ["subagent": ["thread_spawn": ["parent_thread_id": "parent-session"]]],
                    ],
                ],
                Self.tokenCount(env: env, timestamp: first, model: model, total: (1000, 900, 10), last: (1000, 900, 10)),
                Self.tokenCount(env: env, timestamp: second, model: model, total: (1200, 1080, 12), last: (200, 180, 2)),
                Self.tokenCount(env: env, timestamp: third, model: model, total: (1400, 1260, 14), last: (200, 180, 2)),
            ]))

        var timeline = CodexSessionOwnershipTimeline()
        _ = timeline.recordOfficialCodexRoute(
            atUnixMilliseconds: Int64(day.timeIntervalSince1970 * 1000))
        _ = timeline.recordCodexRelayActivation(
            profileID: try #require(UUID(uuidString: "11111111-1111-4111-8111-111111111111")),
            atUnixMilliseconds: Int64(second.addingTimeInterval(-1).timeIntervalSince1970 * 1000))
        _ = timeline.recordActivation(
            accountKey: "codex:managed:official",
            atUnixMilliseconds: Int64(day.timeIntervalSince1970 * 1000))

        let full = try await CostUsageFetcher(cacheRoot: env.root.appendingPathComponent("full"))
            .loadTokenSnapshot(
                provider: .codex,
                now: third,
                forceRefresh: true,
                codexHomePath: env.codexHomeRoot.path,
                historyDays: 1,
                allowPricingRefresh: false,
                refreshPricingInBackground: false,
                includePiSessions: false)
        let official = try await CostUsageFetcher(cacheRoot: env.root.appendingPathComponent("official"))
            .loadAttributedSharedCodexTokenSnapshot(
                now: third,
                sharedCodexHomePath: env.codexHomeRoot.path,
                usageIdentity: .subscription(
                    provider: .codex,
                    accountKey: "managed:official",
                    displayLabel: "Official"),
                timeline: timeline,
                historyDays: 1,
                forceRefresh: true)
        let relay = try await CostUsageFetcher(cacheRoot: env.root.appendingPathComponent("relay"))
            .loadRelaySharedCodexTokenSnapshot(
                now: third,
                sharedCodexHomePath: env.codexHomeRoot.path,
                profileID: nil,
                timeline: timeline,
                historyDays: 1,
                forceRefresh: true)

        let fullTokens = try #require(full.last30DaysTokens)
        let partitionTokens = (official.last30DaysTokens ?? 0) + (relay.last30DaysTokens ?? 0)
        #expect(partitionTokens == fullTokens)
        #expect(relay.last30DaysTokens ?? 0 < 1000)
    }

    private static func tokenCount(
        env: CostUsageTestEnvironment,
        timestamp: Date,
        model: String,
        total: (Int, Int, Int),
        last: (Int, Int, Int)) -> [String: Any]
    {
        [
            "type": "event_msg",
            "timestamp": env.isoString(for: timestamp),
            "payload": [
                "type": "token_count",
                "info": [
                    "model": model,
                    "total_token_usage": [
                        "input_tokens": total.0,
                        "cached_input_tokens": total.1,
                        "output_tokens": total.2,
                    ],
                    "last_token_usage": [
                        "input_tokens": last.0,
                        "cached_input_tokens": last.1,
                        "output_tokens": last.2,
                    ],
                ],
            ],
        ]
    }
}
