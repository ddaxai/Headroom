import Foundation
import Testing
@testable import CodexBarCore

struct HeadroomPhase2UpstreamSyncLinuxTests {
    @Test
    func `updated pricing table covers GPT-6 Sol Terra Luna Fast and Claude Mythos`() throws {
        // GPT-6.1 Sol Standard (<=272K): $2 / 1M input, $0.10 / 1M cached, $10 / 1M output.
        let solStandardShort = try #require(CostUsagePricing.codexCostUSD(
            model: "sub2api/gpt-6.1-sol",
            inputTokens: 100_000,
            cachedInputTokens: 20_000,
            outputTokens: 10_000))
        // 80k * 2e-6 ($0.16) + 20k * 1e-7 ($0.002) + 10k * 1e-5 ($0.10) = $0.262
        #expect(abs(solStandardShort - 0.262) < 1e-9)

        // GPT-6.1 Sol Standard Long-Context (>272K): 2x input/cached ($4/$0.20 per 1M), $15 / 1M output.
        let solStandardLong = try #require(CostUsagePricing.codexCostUSD(
            model: "sub2api/gpt-6.1-sol",
            inputTokens: 1_000_000,
            cachedInputTokens: 200_000,
            outputTokens: 100_000))
        // 800k * 4e-6 ($3.20) + 200k * 2e-7 ($0.04) + 100k * 1.5e-5 ($1.50) = $4.74
        #expect(abs(solStandardLong - 4.74) < 1e-9)

        // GPT-6.1 Sol Fast (2x multiplier), including >272K long-context requests!
        let solFastLong = try #require(CostUsagePricing.codexPriorityCostUSD(
            model: "gpt-6.1-sol",
            inputTokens: 300_000,
            cachedInputTokens: 0,
            outputTokens: 50_000))
        // Above 272K threshold: input doubles to 4e-6 ($1.20), output is 1.5e-5 ($0.75) => $1.95 * 2 (Fast) = $3.90
        #expect(abs(solFastLong - 3.90) < 1e-9)

        // GPT-6.1 Terra Fast (2x) and GPT-6 Luna Fast (2x).
        #expect(CostUsagePricing.codexAPIFastMultiplier(model: "gpt-6.1-terra") == 2)
        #expect(CostUsagePricing.codexAPIFastMultiplier(model: "gpt-6-luna") == 2)
        #expect(CostUsagePricing.codexAPIFastMultiplier(model: "gpt-5.5") == 2.5)

        // Model aliases resolve to bundled pricing.
        #expect(CostUsagePricing.normalizeCodexModel("gpt-daybreak-blue-latest") == "gpt-5.6-sol")
        #expect(CostUsagePricing.normalizeCodexModel("gpt-reserve") == "gpt-5.6-luna")
        #expect(CostUsagePricing.normalizeCodexModel("gpt-daybreak-red-latest") == "gpt-5.6-cyber")

        // Claude Mythos 5.2 pricing: $8 / 1M input, $40 / 1M output.
        let mythos52 = try #require(CostUsagePricing.claudeCostUSD(
            model: "claude-mythos-5-2",
            inputTokens: 100_000,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 25_000))
        // 100k * 8e-6 ($0.80) + 25k * 4e-5 ($1.00) = $1.80
        #expect(abs(mythos52 - 1.80) < 1e-9)
    }

    @Test
    func `scanner follows symlinked sessions directory and retains compressed jsonl zst history`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("headroom-phase2-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let physicalSessions = root.appendingPathComponent("physical-sessions/2026/11/17", isDirectory: true)
        try FileManager.default.createDirectory(at: physicalSessions, withIntermediateDirectories: true)

        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        let symlinkedSessions = codexHome.appendingPathComponent("sessions")
        try FileManager.default.createSymbolicLink(
            at: symlinkedSessions,
            withDestinationURL: root.appendingPathComponent("physical-sessions", isDirectory: true))

        let rolloutURL = physicalSessions.appendingPathComponent("rollout-2026-11-17T10-00-00-test.jsonl")
        let rolloutLines = [
            #"{"timestamp":"2026-11-17T10:00:00Z","type":"session_meta","payload":{"id":"sess-1","model_provider":"openai"}}"#,
            #"{"timestamp":"2026-11-17T10:00:01Z","type":"turn_context","payload":{"model":"gpt-6.1-sol"}}"#,
            #"{"timestamp":"2026-11-17T10:00:05Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":500,"reasoning_output_tokens":0,"total_tokens":1500}}}}"#,
        ].joined(separator: "\n") + "\n"
        try Data(rolloutLines.utf8).write(to: rolloutURL)

        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        let now = try #require(ISO8601DateFormatter().date(from: "2026-11-17T12:00:00Z"))
        let since = now.addingTimeInterval(-3 * 86_400)
        var options = CostUsageScanner.Options(
            codexSessionsRoot: symlinkedSessions,
            cacheRoot: cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let initialReport = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: since,
            until: now,
            now: now,
            options: options)
        #expect(initialReport.summary?.totalTokens == 1500)

        // Simulate Codex archiving rollout.jsonl -> rollout.jsonl.zst and deleting plain rollout.jsonl.
        let zstURL = URL(fileURLWithPath: rolloutURL.path + ".zst")
        try Data("zst-placeholder".utf8).write(to: zstURL)
        try FileManager.default.removeItem(at: rolloutURL)

        options.forceRescan = true
        let postArchiveReport = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: since,
            until: now,
            now: now,
            options: options)
        #expect(postArchiveReport.summary?.totalTokens == 1500)
    }
}
