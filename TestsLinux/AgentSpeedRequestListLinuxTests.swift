import Foundation
import Testing
@testable import CodexBarCore

@Suite("Agent speed request list")
struct AgentSpeedRequestListLinuxTests {
    private static func sample(
        offset: TimeInterval = 0,
        outputTokens: Int = 500,
        latencyMs: Int64 = 6000,
        firstTokenMs: Int64? = 1000,
        newInput: Int? = nil,
        cacheRead: Int? = nil,
        cacheWrite: Int? = nil,
        cacheTTL: Int? = nil) -> AgentSpeedSample
    {
        AgentSpeedSample(
            source: .claude,
            timestamp: Date(timeIntervalSince1970: 1_800_000_000 + offset),
            model: "claude-opus-4-7",
            outputTokens: outputTokens,
            latencyMs: latencyMs,
            firstTokenMs: firstTokenMs,
            newInputTokens: newInput,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            cacheTTLSeconds: cacheTTL)
    }

    @Test
    func `cache hit rate is cache reads over new input plus cache writes plus cache reads`() {
        #expect(Self.sample(newInput: 100, cacheRead: 600, cacheWrite: 300).cacheHitRate == 0.6)
        #expect(Self.sample(newInput: 400, cacheRead: 0).cacheHitRate == 0)
        #expect(Self.sample(newInput: 0, cacheRead: 900).cacheHitRate == 1)
    }

    @Test
    func `cache hit rate is unknown without prompt accounting`() {
        #expect(Self.sample().cacheHitRate == nil)
        #expect(Self.sample(newInput: 0, cacheRead: 0, cacheWrite: 0).cacheHitRate == nil)
    }

    @Test
    func `cache expiry is one lifetime after a request that touched the cache`() {
        let read = Self.sample(newInput: 10, cacheRead: 500, cacheTTL: 300)
        #expect(read.cacheExpiresAt == read.timestamp.addingTimeInterval(300))
        let hourWrite = Self.sample(newInput: 10, cacheWrite: 500, cacheTTL: 3600)
        #expect(hourWrite.cacheExpiresAt == hourWrite.timestamp.addingTimeInterval(3600))
        // No tier in the log, or a request that neither read nor wrote: nothing to expire.
        #expect(Self.sample(newInput: 10, cacheRead: 500).cacheExpiresAt == nil)
        #expect(Self.sample(newInput: 10, cacheTTL: 300).cacheExpiresAt == nil)
    }

    @Test
    func `short replies report an unfiltered speed but no effective speed`() throws {
        // 15 tokens over a 50 ms stream: 300 tok/s on paper, excluded from summaries.
        let judgement = Self.sample(outputTokens: 15, latencyMs: 850, firstTokenMs: 800)
        #expect(judgement.effectiveSpeed == nil)
        let unfiltered = try #require(judgement.unfilteredTokensPerSecond)
        #expect(abs(unfiltered - 15.0 / 0.85) < 0.001)

        let real = Self.sample(outputTokens: 500, latencyMs: 11000, firstTokenMs: 1000)
        #expect(real.effectiveSpeed?.tokensPerSecond == 50)
        #expect(real.unfilteredTokensPerSecond == 50)
    }

    @Test
    func `summary keeps recent requests newest first including short replies`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000 + 600)
        var samples = (0..<40).map { Self.sample(offset: TimeInterval($0), outputTokens: 500) }
        samples.append(Self.sample(offset: 100, outputTokens: 12, latencyMs: 300, firstTokenMs: nil))
        let summary = try #require(AgentSpeedSummary.summarize(samples, now: now))

        #expect(summary.recentSamples.count == AgentSpeedSummary.recentSampleLimit)
        #expect(summary.recentSamples.first?.outputTokens == 12)
        #expect(summary.recentSamples.first?.effectiveSpeed == nil)
        #expect(summary.recentSamples[1].timestamp == samples[39].timestamp)
        #expect(summary.recentSamples.map(\.timestamp) == summary.recentSamples.map(\.timestamp).sorted(by: >))
        // The short reply is listed but does not change the headline speed.
        #expect(summary.latestTokensPerSecond == 100)
    }

    @Test
    func `the request list keeps the ten newest replies`() {
        #expect(AgentSpeedSummary.recentSampleLimit == 10)
    }

    @Test
    func `antigravity model labels keep the codename and effort`() {
        func short(_ model: String?) -> String? {
            AgentSpeedModelLabel.short(model, source: .antigravity)
        }
        #expect(short("gemini-9-quartz-high") == "quartz-high")
        #expect(short("Gemini 9 Quartz (High)") == "quartz-high")
        #expect(short("gemini-9-quartz") == "quartz")
        #expect(short("gemini-9-basalt-tiered-agy") == "basalt")
        // No codename: the version is the only thing telling two of these apart.
        #expect(short("gemini-2.5-pro") == "2.5-pro")
        #expect(short("claude-sonnet-4-5") == "sonnet-4-5")
        #expect(short("gpt-5.1") == "gpt-5.1")
        #expect(short("  ") == nil)
        #expect(short(nil) == nil)
    }

    @Test
    func `other sources keep the model ID from their log`() {
        #expect(AgentSpeedModelLabel.short("gemini-2.5-pro", source: .openCode) == "gemini-2.5-pro")
        #expect(AgentSpeedModelLabel.short(" claude-opus-4-7 ", source: .claude) == "claude-opus-4-7")
    }

    @Test
    func `relative age rounds down to whole minutes hours and days`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func age(_ secondsAgo: TimeInterval) -> AgentSpeedRelativeAge {
            AgentSpeedRelativeAge(from: now.addingTimeInterval(-secondsAgo), now: now)
        }
        #expect(age(0) == .justNow)
        #expect(age(59) == .justNow)
        // A clock a few seconds ahead of the log must not read as a negative age.
        #expect(age(-30) == .justNow)
        #expect(age(60) == .minutes(1))
        #expect(age(59 * 60 + 59) == .minutes(59))
        #expect(age(3600) == .hours(1))
        #expect(age(23 * 3600 + 3599) == .hours(23))
        #expect(age(86400) == .days(1))
        #expect(age(3 * 86400 + 5) == .days(3))
    }

    @Test
    func `cache hit rate text floors to one decimal and reserves 100 percent for a full hit`() {
        #expect(AgentSpeedSummary.formatCacheHitRate(0.873) == "87.3%")
        #expect(AgentSpeedSummary.formatCacheHitRate(0.9996) == "99.9%")
        #expect(AgentSpeedSummary.formatCacheHitRate(1) == "100%")
        #expect(AgentSpeedSummary.formatCacheHitRate(0) == "0.0%")
    }

    @Test
    func `codex prompt tracker removes cached tokens from input`() {
        var tracker = LocalAgentSpeedScanner.CodexPromptTokenTracker()
        let first = tracker.observe(
            total: ["input_tokens": 1000, "cached_input_tokens": 0],
            last: ["input_tokens": 1000, "cached_input_tokens": 0])
        #expect(first?.newInput == 1000)
        #expect(first?.cacheRead == 0)

        // Without `last_token_usage` the request is the growth of the running total.
        let second = tracker.observe(
            total: ["input_tokens": 3000, "cached_input_tokens": 1500],
            last: nil)
        #expect(second?.newInput == 500)
        #expect(second?.cacheRead == 1500)

        // `last_token_usage` wins when both are present.
        let third = tracker.observe(
            total: ["input_tokens": 9000, "cached_input_tokens": 4000],
            last: ["input_tokens": 2000, "cached_input_tokens": 1800])
        #expect(third?.newInput == 200)
        #expect(third?.cacheRead == 1800)

        let missing = tracker.observe(total: nil, last: nil)
        #expect(missing == nil)
    }

    @Test
    func `claude requests carry prompt tokens and the cache tier of the session`() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("headroom-speed-list-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = home.appendingPathComponent(".claude/projects/demo", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let baseMs: Int64 = 1_800_000_000_000
        func iso(_ offsetMs: Int64) -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: Date(timeIntervalSince1970: Double(baseMs + offsetMs) / 1000.0))
        }
        // The first reply writes to the one-hour cache; the second only reads it and inherits the tier.
        let writeUsage = """
        {"input_tokens":50,"output_tokens":300,"cache_read_input_tokens":0,"cache_creation_input_tokens":950,\
        "cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":950}}
        """
        let readUsage = """
        {"input_tokens":100,"output_tokens":400,"cache_read_input_tokens":900,"cache_creation_input_tokens":0}
        """
        let lines = [
            #"{"uuid":"u1","type":"user","timestamp":"\#(iso(0))"}"#,
            #"{"uuid":"a1","parentUuid":"u1","type":"assistant","apiBlockIndex":0,"timestamp":"\#(iso(5000))","#
                +
                #""message":{"id":"msg_1","model":"claude-opus-4-7","content":[{"type":"text"}],"#
                + #""usage":\#(writeUsage)}}"#,
            #"{"uuid":"u2","parentUuid":"a1","type":"user","timestamp":"\#(iso(60000))"}"#,
            #"{"uuid":"a2","parentUuid":"u2","type":"assistant","apiBlockIndex":0,"timestamp":"\#(iso(68000))","#
                +
                #""message":{"id":"msg_2","model":"claude-opus-4-7","content":[{"type":"text"}],"#
                + #""usage":\#(readUsage)}}"#,
        ]
        try lines.joined(separator: "\n").write(
            to: dir.appendingPathComponent("session.jsonl"),
            atomically: true,
            encoding: .utf8)

        let report = LocalAgentSpeedScanner().scan(
            configuration: LocalAgentSpeedScanConfiguration(homeDirectory: home, environment: [:]),
            sources: [.claude],
            now: Date(timeIntervalSince1970: Double(baseMs + 120_000) / 1000.0))
        let recent = try #require(report.bySource[.claude]).recentSamples
        #expect(recent.count == 2)

        let latest = recent[0]
        #expect(latest.newInputTokens == 100)
        #expect(latest.cacheReadTokens == 900)
        #expect(latest.cacheHitRate == 0.9)
        #expect(latest.cacheTTLSeconds == 3600)
        #expect(latest.cacheExpiresAt == latest.timestamp.addingTimeInterval(3600))

        let first = recent[1]
        #expect(first.cacheWriteTokens == 950)
        #expect(first.cacheHitRate == 0)
        #expect(first.cacheTTLSeconds == 3600)
    }

    @Test
    func `antigravity and pi requests carry cache tokens when the log has them`() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("headroom-speed-list-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date(timeIntervalSince1970: 1_800_000_100)
        let iso = ISO8601DateFormatter()

        let logs = home.appendingPathComponent(
            ".gemini/antigravity/brain/11111111-2222-3333-4444-555555555555/.system_generated/logs",
            isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        func step(_ index: Int, _ type: String, secondsAgo: TimeInterval, _ extra: String = "") -> String {
            let created = iso.string(from: now.addingTimeInterval(-secondsAgo))
            return #"{"step_index":\#(index),"type":"\#(type)","status":"DONE","created_at":"\#(created)"\#(extra)}"#
        }
        let transcript = [
            step(0, "USER_INPUT", secondsAgo: 40),
            step(
                1,
                "PLANNER_RESPONSE",
                secondsAgo: 30,
                #","input_tokens":80,"output_tokens":400,"cache_read_tokens":320"#),
            step(2, "USER_INPUT", secondsAgo: 20),
            step(3, "PLANNER_RESPONSE", secondsAgo: 10, #","output_tokens":400"#),
        ].joined(separator: "\n")
        try transcript.write(
            to: logs.appendingPathComponent("transcript.jsonl"),
            atomically: true,
            encoding: .utf8)

        let piDir = home.appendingPathComponent(".pi/agent/sessions/proj", isDirectory: true)
        try FileManager.default.createDirectory(at: piDir, withIntermediateDirectories: true)
        let piStart = iso.string(from: now.addingTimeInterval(-8))
        let piEnd = iso.string(from: now.addingTimeInterval(-4))
        let pi = #"{"type":"message","timestamp":"\#(piEnd)","message":{"role":"assistant","provider":"sub2api","#
            + #""model":"claude-opus-4-7","timestamp":"\#(piStart)","#
            + #""usage":{"input":100,"output":320,"cacheRead":300,"cacheWrite":100}}}"#
        try pi.write(to: piDir.appendingPathComponent("pi.jsonl"), atomically: true, encoding: .utf8)

        let report = LocalAgentSpeedScanner().scan(
            configuration: LocalAgentSpeedScanConfiguration(homeDirectory: home, environment: [:]),
            sources: [.antigravity, .pi],
            now: now)

        let antigravity = try #require(report.bySource[.antigravity]).recentSamples
        #expect(antigravity.count == 2)
        // The newest step has no prompt accounting at all, so its cache column is a dash.
        #expect(antigravity[0].cacheHitRate == nil)
        #expect(antigravity[1].newInputTokens == 80)
        #expect(antigravity[1].cacheReadTokens == 320)
        #expect(antigravity[1].cacheHitRate == 0.8)

        let piSample = try #require(report.bySource[.pi]?.recentSamples.first)
        #expect(piSample.cacheReadTokens == 300)
        #expect(piSample.cacheWriteTokens == 100)
        #expect(piSample.cacheHitRate == 0.6)
    }
}
