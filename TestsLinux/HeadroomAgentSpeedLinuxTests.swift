import Foundation
import Testing
@testable import CodexBarCore

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

@Suite("Local Agent Speed Scanner (Read-Only, Zero-Proxy)")
struct HeadroomAgentSpeedLinuxTests {
    @Test
    func `speed sample enforces exact vs estimated thresholds and weighted 24h aggregation`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        // Short tool call (< 100 tok) is ignored even with TTFT
        let tiny = AgentSpeedSample(
            source: .codex,
            timestamp: now.addingTimeInterval(-300),
            model: "gpt-6.1-sol",
            outputTokens: 45,
            latencyMs: 1200,
            firstTokenMs: 200)
        #expect(tiny.effectiveSpeed == nil)

        // Network burst (< 100ms streaming window) is ignored
        let burst = AgentSpeedSample(
            source: .codex,
            timestamp: now.addingTimeInterval(-240),
            model: "gpt-6.1-sol",
            outputTokens: 400,
            latencyMs: 1050,
            firstTokenMs: 1000)
        #expect(burst.effectiveSpeed == nil)

        // Exact sample A: 1000 tok / (11000 - 1000) ms = 100 tok/s
        let exactA = AgentSpeedSample(
            source: .codex,
            timestamp: now.addingTimeInterval(-120),
            model: "gpt-6.1-sol",
            outputTokens: 1000,
            latencyMs: 11_000,
            firstTokenMs: 1000)
        #expect(exactA.exactStreamingTokensPerSecond == 100)

        // Exact sample B: 300 tok / (4000 - 1000) ms = 100 tok/s (weighted: 1300 / 13s = 100)
        let exactB = AgentSpeedSample(
            source: .codex,
            timestamp: now.addingTimeInterval(-60),
            model: "gpt-6.1-sol",
            outputTokens: 300,
            latencyMs: 4000,
            firstTokenMs: 1000)

        let summary = AgentSpeedSummary.summarize([tiny, burst, exactA, exactB], now: now)
        #expect(summary?.latestTokensPerSecond == 100)
        #expect(summary?.latestKind == .streamingExact)
        #expect(summary?.rolling24hTokensPerSecond == 100)
        #expect(summary?.rolling24hMedianFirstTokenMs == 1000)
        #expect(AgentSpeedSummary.formatTokensPerSecond(100, kind: .streamingExact) == "100 tok/s")
        #expect(AgentSpeedSummary.formatTokensPerSecond(42.4, kind: .endToEndEstimated) == "≈ 42 tok/s")
    }

    @Test
    func `antigravity native SQLite protobuf decodes exact streaming tok_s and TTFT and blocks symlink escape`() throws {
        let tempHome = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let agyRoot = tempHome.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
        let sessionID = "11111111-2222-3333-4444-555555555555"
        let logsDir = agyRoot
            .appendingPathComponent("brain", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent(".system_generated/logs", isDirectory: true)
        let convDir = agyRoot.appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: convDir, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1_800_000_100)
        let iso = ISO8601DateFormatter()
        let t0 = iso.string(from: now.addingTimeInterval(-20))
        let t1 = iso.string(from: now.addingTimeInterval(-10))
        let transcript = """
        {"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"\(t0)","content":"User changed setting `Model Selection` from Gemini 4 Carbon (Medium) to Gemini 4 Carbon (High)."}
        {"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"\(t1)","input_tokens":500,"output_tokens":340}
        """
        let transcriptURL = logsDir.appendingPathComponent("transcript.jsonl")
        try transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let dbURL = convDir.appendingPathComponent("\(sessionID).db")
        try Self.writeAntigravityDatabase(
            at: dbURL,
            stepIndex: 1,
            generationIndex: 0,
            baseModel: "gemini-pro-orchestrator",
            tieredModel: "gemini-4-carbon-high",
            firstTokenMs: 1400,
            streamingMs: 5000)

        let scanner = LocalAgentSpeedScanner()
        let config = LocalAgentSpeedScanConfiguration(homeDirectory: tempHome, environment: [:])
        let report = scanner.scan(configuration: config, sources: [.antigravity], now: now)
        let summary = try #require(report.bySource[.antigravity])

        // 340 output tokens / 5.0s streaming = 68 tok/s, TTFT = 1400 ms
        #expect(summary.latestKind == .streamingExact)
        #expect(summary.latestTokensPerSecond == 68)
        #expect(summary.latestFirstTokenMs == 1400)
        #expect(summary.latestModel == "gemini-4-carbon-high")

        // Verify symlink outside Antigravity root is ignored safely (falls back to transcript timestamps: 340 / 10s = 34 tok/s estimated)
        let outsideDir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: outsideDir) }
        let outsideDB = outsideDir.appendingPathComponent("outside.db")
        try FileManager.default.moveItem(at: dbURL, to: outsideDB)
        try FileManager.default.createSymbolicLink(at: dbURL, withDestinationURL: outsideDB)

        scanner.clearCache()
        let fallbackReport = scanner.scan(configuration: config, sources: [.antigravity], now: now)
        let fallbackSummary = try #require(fallbackReport.bySource[.antigravity])
        #expect(fallbackSummary.latestKind == .endToEndEstimated)
        #expect(fallbackSummary.latestTokensPerSecond == 34)
    }

    @Test
    func `codex rollout scanner extracts started_at_ms TTFT excludes tool wait and partitions official vs relay`() throws {
        let tempHome = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let sessionsDir = tempHome.appendingPathComponent(".codex/sessions/2026/11/18", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let baseMs: Int64 = 1_800_000_000_000
        let relayID = UUID()
        var timeline = CodexSessionOwnershipTimeline()
        _ = timeline.recordActivation(accountKey: "codex:official-user-a", atUnixMilliseconds: baseMs - 60_000)
        _ = timeline.recordOfficialCodexRoute(atUnixMilliseconds: baseMs - 60_000)
        _ = timeline.recordCodexRelayActivation(profileID: relayID, atUnixMilliseconds: baseMs + 20_000)

        // Turn 1 (Official, with started_at_ms): start=baseMs, firstToken=+1000ms, end=+5000ms -> gen=4000ms, output=400 -> 100 tok/s
        // Turn 2 (Relay, tool call waited 12s before token_count): start=+30000ms, model_output=+35000ms, tool_output=+47000ms, token_count=+47020ms -> end uses model_output (+35000ms = 5s), output=300 -> ≈ 60 tok/s!
        let rollout = """
        {"timestamp":"\(Self.isoMs(baseMs))","type":"turn_context","payload":{"model":"gpt-6.1-sol","model_provider":"openai"}}
        {"timestamp":"\(Self.isoMs(baseMs + 5000))","type":"event_msg","payload":{"type":"item_completed","started_at_ms":\(baseMs + 1000),"item":{"type":"AgentMessage"}}}
        {"timestamp":"\(Self.isoMs(baseMs + 5000))","type":"response_item","payload":{"type":"message","role":"assistant"}}
        {"timestamp":"\(Self.isoMs(baseMs + 5000))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":200,"output_tokens":400},"last_token_usage":{"input_tokens":200,"output_tokens":400}}}}
        {"timestamp":"\(Self.isoMs(baseMs + 30_000))","type":"turn_context","payload":{"model":"gpt-6.1-sol","model_provider":"sub2api"}}
        {"timestamp":"\(Self.isoMs(baseMs + 35_000))","type":"response_item","payload":{"type":"function_call"}}
        {"timestamp":"\(Self.isoMs(baseMs + 47_000))","type":"response_item","payload":{"type":"function_call_output"}}
        {"timestamp":"\(Self.isoMs(baseMs + 47_020))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":500,"output_tokens":700},"last_token_usage":{"input_tokens":300,"output_tokens":300}}}}
        """
        let rolloutURL = sessionsDir.appendingPathComponent("rollout.jsonl")
        try rollout.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let now = Date(timeIntervalSince1970: Double(baseMs + 60_000) / 1000.0)
        let config = LocalAgentSpeedScanConfiguration(
            homeDirectory: tempHome,
            environment: [:],
            codexOwnershipTimeline: timeline,
            relayProviderKeyByProfileID: [relayID: "sub2api"])
        let report = LocalAgentSpeedScanner().scan(configuration: config, sources: [.codex], now: now)

        let official = try #require(report.codexByAccountKey["codex:official-user-a"])
        #expect(official.latestKind == .streamingExact)
        #expect(official.latestTokensPerSecond == 100)
        #expect(official.latestFirstTokenMs == 1000)

        let relay = try #require(report.codexByRelayProfileID[relayID])
        #expect(relay.latestKind == .endToEndEstimated)
        #expect(relay.latestTokensPerSecond == 60)
        #expect(report.relayCombinedByProviderKey["sub2api"]?.latestTokensPerSecond == 60)
    }

    @Test
    func `claude opencode and pi scanners compute accurate read-only speeds`() throws {
        let tempHome = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let baseMs: Int64 = 1_800_000_000_000
        let now = Date(timeIntervalSince1970: Double(baseMs + 60_000) / 1000.0)

        // 1. Claude Code session with attachment skip + thinkingDurationMs
        let claudeDir = tempHome.appendingPathComponent(".claude/projects/demo", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let uUser = "00000000-0000-4000-8000-000000000001"
        let uAttach = "00000000-0000-4000-8000-000000000002"
        let uAssist1 = "00000000-0000-4000-8000-000000000003"
        let uAssist2 = "00000000-0000-4000-8000-000000000004"
        // User at t=0, attachment at t=+2500ms (skipped), thinking block ends at t=+3000ms with thinkingDurationMs=2000ms (so firstOutput = +1000ms, TTFT = 1000ms!), final block ends at t=+6000ms -> streaming = 5000ms, output = 250 -> 50 tok/s!
        let claudeJSONL = """
        {"uuid":"\(uUser)","type":"user","timestamp":"\(Self.isoMs(baseMs))"}
        {"uuid":"\(uAttach)","parentUuid":"\(uUser)","type":"attachment","timestamp":"\(Self.isoMs(baseMs + 2500))"}
        {"uuid":"\(uAssist1)","parentUuid":"\(uAttach)","type":"assistant","apiBlockIndex":0,"thinkingDurationMs":2000,"timestamp":"\(Self.isoMs(baseMs + 3000))","message":{"id":"msg_1","model":"claude-opus-4-7","content":[{"type":"thinking"}],"usage":{"output_tokens":80}}}
        {"uuid":"\(uAssist2)","parentUuid":"\(uAssist1)","type":"assistant","apiBlockIndex":1,"timestamp":"\(Self.isoMs(baseMs + 6000))","message":{"id":"msg_1","model":"claude-opus-4-7","content":[{"type":"text"}],"usage":{"output_tokens":250}}}
        """
        try claudeJSONL.write(
            to: claudeDir.appendingPathComponent("session.jsonl"),
            atomically: true,
            encoding: .utf8)

        // 2. OpenCode V2 SQLite database with time.streamed (excludes tool execution up to time.completed)
        let openCodeDir = tempHome.appendingPathComponent(".local/share/opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: openCodeDir, withIntermediateDirectories: true)
        let openCodeDB = openCodeDir.appendingPathComponent("opencode.db")
        try Self.writeOpenCodeV2Database(
            at: openCodeDB,
            createdMs: baseMs + 10_000,
            streamedMs: baseMs + 15_000, // 5s stream
            completedMs: baseMs + 35_000, // 25s with tool
            outputTokens: 400,
            providerID: "sub2api",
            modelID: "gpt-6-astra")

        // 3. Pi Agent session JSONL
        let piDir = tempHome.appendingPathComponent(".pi/agent/sessions/proj", isDirectory: true)
        try FileManager.default.createDirectory(at: piDir, withIntermediateDirectories: true)
        let piJSONL = """
        {"type":"message","timestamp":"\(Self.isoMs(baseMs + 24_000))","message":{"role":"assistant","provider":"sub2api","model":"claude-mythos-5","timestamp":"\(Self.isoMs(baseMs + 20_000))","usage":{"input":100,"output":320}}}
        """
        try piJSONL.write(
            to: piDir.appendingPathComponent("pi.jsonl"),
            atomically: true,
            encoding: .utf8)

        let config = LocalAgentSpeedScanConfiguration(homeDirectory: tempHome, environment: [:])
        let report = LocalAgentSpeedScanner().scan(
            configuration: config,
            sources: [.claude, .openCode, .pi],
            now: now)

        let claude = try #require(report.bySource[.claude])
        #expect(claude.latestKind == .streamingExact)
        #expect(claude.latestTokensPerSecond == 50)
        #expect(claude.latestFirstTokenMs == 1000)
        #expect(claude.latestModel == "claude-opus-4-7")

        let openCode = try #require(report.bySource[.openCode])
        #expect(openCode.latestKind == .endToEndEstimated)
        #expect(openCode.latestTokensPerSecond == 80) // 400 / 5s (used time.streamed, not 25s time.completed!)
        #expect(report.openCodeByProviderKey["sub2api"]?.latestTokensPerSecond == 80)

        let pi = try #require(report.bySource[.pi])
        #expect(pi.latestKind == .endToEndEstimated)
        #expect(pi.latestTokensPerSecond == 80) // 320 / 4s = 80 tok/s
        #expect(report.piByProviderKey["sub2api"]?.latestTokensPerSecond == 80)
        #expect(report.relayCombinedByProviderKey["sub2api"]?.rolling24hTokensPerSecond == 80)
    }

    // MARK: - Fixture Helpers

    private static func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("headroom-speed-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func isoMs(_ ms: Int64) -> String {
        let sec = ms / 1000
        let rem = Int(ms % 1000)
        let date = Date(timeIntervalSince1970: TimeInterval(sec))
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        let base = fmt.string(from: date)
        if base.hasSuffix("Z") {
            return String(base.dropLast()) + String(format: ".%03dZ", rem)
        }
        return base
    }

    private static func encodeVarint(_ value: UInt64) -> [UInt8] {
        var v = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while v != 0
        return bytes
    }

    private static func encodeLengthDelimited(tag: UInt64, payload: [UInt8]) -> [UInt8] {
        self.encodeVarint((tag << 3) | 2) + self.encodeVarint(UInt64(payload.count)) + payload
    }

    private static func encodeDuration(tag: UInt64, millis: Int64) -> [UInt8] {
        let seconds = UInt64(bitPattern: millis / 1000)
        let nanos = UInt64(bitPattern: (millis % 1000) * 1_000_000)
        let body = self.encodeVarint((1 << 3) | 0) + self.encodeVarint(seconds)
            + self.encodeVarint((2 << 3) | 0) + self.encodeVarint(nanos)
        return self.encodeLengthDelimited(tag: tag, payload: body)
    }

    private static func writeAntigravityDatabase(
        at url: URL,
        stepIndex: Int64,
        generationIndex: UInt64,
        baseModel: String,
        tieredModel: String,
        firstTokenMs: Int64,
        streamingMs: Int64) throws
    {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw NSError(domain: "TestSQLite", code: 1)
        }
        defer { sqlite3_close(db) }

        sqlite3_exec(db, "CREATE TABLE steps (idx INTEGER PRIMARY KEY, step_type INTEGER, metadata BLOB);", nil, nil, nil)
        sqlite3_exec(db, "CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB);", nil, nil, nil)

        let genRefPayload = generationIndex == 0
            ? []
            : (self.encodeVarint((3 << 3) | 0) + self.encodeVarint(generationIndex))
        let stepMeta = Data(self.encodeLengthDelimited(tag: 20, payload: genRefPayload))

        let responsePayload = self.encodeDuration(tag: 11, millis: firstTokenMs)
            + self.encodeDuration(tag: 12, millis: streamingMs)
            + self.encodeLengthDelimited(tag: 19, payload: Array(baseModel.utf8))
            + self.encodeLengthDelimited(tag: 21, payload: Array(tieredModel.utf8))
        let genData = Data(self.encodeLengthDelimited(tag: 1, payload: responsePayload))

        var stmt1: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO steps (idx, step_type, metadata) VALUES (?1, 15, ?2)", -1, &stmt1, nil)
        sqlite3_bind_int64(stmt1, 1, stepIndex)
        stepMeta.withUnsafeBytes { ptr in
            _ = sqlite3_bind_blob(stmt1, 2, ptr.baseAddress, Int32(stepMeta.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        sqlite3_step(stmt1)
        sqlite3_finalize(stmt1)

        var stmt2: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO gen_metadata (idx, data) VALUES (?1, ?2)", -1, &stmt2, nil)
        sqlite3_bind_int64(stmt2, 1, Int64(generationIndex))
        genData.withUnsafeBytes { ptr in
            _ = sqlite3_bind_blob(stmt2, 2, ptr.baseAddress, Int32(genData.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        sqlite3_step(stmt2)
        sqlite3_finalize(stmt2)
    }

    private static func writeOpenCodeV2Database(
        at url: URL,
        createdMs: Int64,
        streamedMs: Int64,
        completedMs: Int64,
        outputTokens: Int,
        providerID: String,
        modelID: String) throws
    {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw NSError(domain: "TestSQLite", code: 2)
        }
        defer { sqlite3_close(db) }

        sqlite3_exec(db, "CREATE TABLE session_v2 (id TEXT PRIMARY KEY, time_updated INTEGER);", nil, nil, nil)
        sqlite3_exec(
            db,
            "CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, time_created INTEGER, data TEXT);",
            nil,
            nil,
            nil)
        let json = """
        {"tokens":{"input":120,"output":\(outputTokens),"reasoning":0},"model":{"id":"\(modelID)","providerID":"\(providerID)"},"time":{"created":\(createdMs),"streamed":\(streamedMs),"completed":\(completedMs)}}
        """
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(
            db,
            "INSERT INTO session_message (id, session_id, type, time_created, data) VALUES ('m1', 's1', 'assistant', ?1, ?2)",
            -1,
            &stmt,
            nil)
        sqlite3_bind_int64(stmt, 1, createdMs)
        sqlite3_bind_text(stmt, 2, json, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }
}
