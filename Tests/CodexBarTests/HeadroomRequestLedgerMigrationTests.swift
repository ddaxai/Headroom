import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct HeadroomRequestLedgerMigrationTests {
    @Test(arguments: [false, true])
    func `owned requests distinguish execution session identity and reject foreign copies`(subagent: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let date = try env.makeLocalNoon(year: 2026, month: 10, day: 5)
        var metadata: [String: Any] = ["id": "thread", "session_id": "execution"]
        if subagent { metadata["source"] = "subagent" }
        let rows: [[String: Any]] = [
            ["type": "session_meta", "payload": metadata],
            Self.record("owned", at: date, input: 60),
            Self.record("foreign", at: date, input: 900, thread: "parent"),
            Self.record("other-execution", at: date, input: 800, session: "other"),
        ]
        let file = try env.writeCodexSessionFile(day: date, filename: "owned.jsonl", contents: env.jsonl(rows))
        let result = CostUsageScanner.parseCodexFile(fileURL: file, range: .init(since: date, until: date))
        #expect(result.rows.compactMap(\.responseID) == ["owned"])
        #expect(result.rows.reduce(0) { $0 + $1.input + $1.output } == 66)
    }

    @Test(arguments: ["32ad8e5366acf034", "e0525d3c2f581877"])
    func `adopted JSON caches reparse in bounded passes preserving prices then resume appended responses`(
        predecessor: String) throws
    {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 10, day: 5)
        let header: [[String: Any]] = [["type": "session_meta", "payload": ["id": "thread", "session_id": "execution"]]]
        let file = try env.writeCodexSessionFile(
            day: day, filename: "migrating.jsonl", contents: env.jsonl(header + [Self.record(
                "first",
                at: day,
                input: 60)]))
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-trace.sqlite"))
        options.refreshMinIntervalSeconds = 0
        func report() -> CostUsageDailyReport {
            CostUsageScanner.loadDailyReport(provider: .codex, since: day, until: day, now: day, options: options)
        }
        #expect(report().summary?.totalTokens == 66)
        var old = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot, calendar: options.calendar)
        let raw = try Data(contentsOf: CostUsageCacheIO.cacheFileURL(provider: .codex, cacheRoot: env.cacheRoot))
        let decoded = try JSONDecoder().decode(CostUsageCache.self, from: raw)
        #expect(decoded.producerKey == CostUsageCacheIO.currentProducerKey(provider: .codex))
        #expect(decoded.timeZoneIdentifier == options.calendar.timeZone.identifier)
        #expect(!old.files.isEmpty)
        let path = try #require(old.files.keys.first { $0.hasSuffix("/" + file.lastPathComponent) })
        var usage = try #require(old.files[path])
        let row = try #require(usage.codexRows?.first)
        // Reproduce a predecessor cache with legacy-only rows and a historical price.
        usage.codexRows = [CostUsageScanner.CodexUsageRow(
            day: row.day,
            model: row.model,
            turnID: row.turnID,
            eventIndex: row.eventIndex,
            timestampUnixMs: row.timestampUnixMs,
            input: row.input,
            cached: row.cached,
            output: row.output,
            knownCostNanos: 123_000_000,
            unpricedTokens: 0,
            pricingModel: row.model,
            pricingMode: "priority")]
        usage.codexParserRevision = nil
        usage.codexRequestLedgerState = nil
        old.files[path] = usage
        CostUsageCacheIO.save(
            provider: .codex,
            cache: old,
            cacheRoot: env.cacheRoot,
            producerKey: "codex:cu:p\(predecessor)",
            calendar: options.calendar)
        #expect(CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot).files.count == 1)
        options.maxCodexScanBytesPerRefresh = 128
        options.maxCodexSessionFileBytes = 128
        var sawPartial = false
        for _ in 0..<30 {
            _ = report()
            let reopened = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot, calendar: options.calendar)
            let current = try #require(reopened.files[path])
            sawPartial = sawPartial || current.codexScanComplete == false
            if current.codexScanComplete == true { break }
        }
        #expect(sawPartial)
        let migrated = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot, calendar: options.calendar)
        let priced = try #require(migrated.files[path]?.codexRows?.first)
        #expect(priced.responseID == "first")
        #expect(priced.knownCostNanos == 123_000_000)
        #expect(priced.pricingMode == "priority")
        #expect(report().summary?.totalCostUSD == 0.123)
        #expect(migrated.files[path]?.codexLedgerMigrationRows == nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(env.jsonl([
            Self.record("first", at: day, input: 60),
            Self.record("second", at: day, input: 40),
        ]).utf8))
        try handle.close()
        options.maxCodexScanBytesPerRefresh = 1_000_000
        options.maxCodexSessionFileBytes = 1_000_000
        #expect(report().summary?.totalTokens == 112)
        let resumed = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot, calendar: options.calendar)
        #expect(resumed.files[path]?.codexRows?.compactMap(\.responseID) == [
            "first",
            "second",
        ])
        #expect(resumed.files[path]?.codexRows?.first?.knownCostNanos == 123_000_000)
        #expect(report().summary?.totalTokens == 112)
    }

    @Test
    func `response identities are isolated by thread after JSON reopen`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 10, day: 5)
        for thread in ["one", "two"] {
            _ = try env.writeCodexSessionFile(day: day, filename: "\(thread).jsonl", contents: env.jsonl([
                ["type": "session_meta", "payload": ["id": thread, "session_id": "execution"]],
                Self.record("shared-response", at: day, input: 60, thread: thread),
                Self.record("shared-response", at: day, input: 60, thread: thread),
            ]))
        }
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0
        for _ in 0..<2 {
            let report = CostUsageScanner.loadDailyReport(
                provider: .codex, since: day, until: day, now: day, options: options)
            #expect(report.summary?.totalTokens == 132)
            let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot, calendar: options.calendar)
            #expect(cache.files.values.flatMap { $0.codexRows ?? [] }.count == 2)
        }
    }

    @Test(arguments: ["32ad8e5366acf034", "e0525d3c2f581877"])
    func `compatible historical cache survives when its original source is absent`(predecessor: String) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 10, day: 5)
        let file = try env.writeCodexSessionFile(day: day, filename: "removed.jsonl", contents: env.jsonl([
            ["type": "session_meta", "payload": ["id": "thread", "session_id": "execution"]],
            Self.record("old", at: day, input: 60),
        ]))
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(provider: .codex, since: day, until: day, now: day, options: options)
        var cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot, calendar: options.calendar)
        let path = try #require(cache.files.keys.first { $0.hasSuffix("/" + file.lastPathComponent) })
        var usage = try #require(cache.files[path])
        usage.codexParserRevision = nil
        usage.codexRequestLedgerState = nil
        cache.files[path] = usage
        CostUsageCacheIO.save(
            provider: .codex,
            cache: cache,
            cacheRoot: env.cacheRoot,
            producerKey: "codex:cu:p\(predecessor)",
            calendar: options.calendar)
        try FileManager.default.removeItem(at: file)
        for _ in 0..<2 {
            let report = CostUsageScanner.loadDailyReport(
                provider: .codex, since: day, until: day, now: day, options: options)
            #expect(report.summary?.totalTokens == 66)
            #expect(CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot).files[path] != nil)
        }
        CostUsageCacheIO.save(
            provider: .codex,
            cache: cache,
            cacheRoot: env.cacheRoot,
            producerKey: "codex:cu:p-unrelated",
            calendar: options.calendar)
        #expect(CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot).files.isEmpty)
    }

    private static func record(
        _ response: String, at date: Date, input: Int, thread: String = "thread", session: String = "execution")
        -> [String: Any]
    {
        let tokens = ["input_tokens": input, "cached_input_tokens": 2, "output_tokens": 6]
        return [
            "type": "token_usage_record",
            "timestamp": ISO8601DateFormatter().string(from: date),
            "payload": [
                "thread_id": thread,
                "session_id": session,
                "response_id": response,
                "model": "gpt-5",
                "usage": tokens,
                "thread_token_usage": tokens,
            ],
        ]
    }
}
