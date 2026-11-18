import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageFetcherPartialCorpusTests {
    @Test
    func `current partial corpus still exposes scanned rows for the menu`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let now = try env.makeLocalNoon(year: 2026, month: 4, day: 30)
        _ = try env.writeCodexSessionFile(
            day: now,
            filename: "partial-menu.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": env.isoString(for: now),
                    "payload": [
                        "session_id": "partial-menu",
                        "model_provider": CodexSessionProvenanceClassifier.officialProvider,
                    ],
                ],
                Self.tokenCountEntry(
                    env: env,
                    date: now.addingTimeInterval(-1),
                    total: 42,
                    last: 42),
            ]))

        let options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot)
        _ = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now,
            forceRefresh: true,
            historyDays: 30,
            allowPricingRefresh: false,
            refreshPricingInBackground: false,
            includePiSessions: false,
            scannerOptions: options)

        var cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let revision = try #require(CostUsageScanner.codexSessionCorpusRevision(
            roots: CostUsageScanner.codexSessionsRoots(options: options)))
        cache.codexCorpusRevision = revision
        cache.codexCorpusCoverageIsComplete = false
        CostUsageCacheIO.save(
            provider: .codex,
            cache: cache,
            cacheRoot: env.cacheRoot,
            calendar: options.calendar)

        let partition = try #require(CodexUsageLedgerSnapshotPartition.load(
            now: now,
            sharedCodexHomePath: env.codexHomeRoot.path,
            timeline: CodexSessionOwnershipTimeline(),
            historyDays: 30,
            cacheRoot: env.cacheRoot,
            requireCurrentCorpus: true))

        #expect(!partition.coverageIsComplete)
        #expect(partition.fullCorpus?.last30DaysTokens == 42)
    }

    private static func tokenCountEntry(
        env: CostUsageTestEnvironment,
        date: Date,
        total: Int,
        last: Int) -> [String: Any]
    {
        [
            "type": "event_msg",
            "timestamp": env.isoString(for: date),
            "payload": [
                "type": "token_count",
                "info": [
                    "model": "openai/gpt-5.4",
                    "last_token_usage": [
                        "input_tokens": last,
                        "cached_input_tokens": 0,
                        "output_tokens": 0,
                    ],
                    "total_token_usage": [
                        "input_tokens": total,
                        "cached_input_tokens": 0,
                        "output_tokens": 0,
                    ],
                ],
            ],
        ]
    }
}
