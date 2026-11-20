import Foundation
import Testing
@testable import CodexBarCore

struct AntigravityLocalUsageReaderLinuxTests {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// 2026-03-10 12:30:00 UTC
    private static let now = Date(timeIntervalSince1970: 1_773_145_800)

    private static func makeHome(sessions: [String: [[String: Any]]], compactOnly: Bool = false) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("agy-usage-\(UUID().uuidString)", isDirectory: true)
        for (sessionID, steps) in sessions {
            let logs = home
                .appendingPathComponent(".gemini/antigravity/brain/\(sessionID)/.system_generated/logs", isDirectory: true)
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            let lines = try steps.map {
                try String(bytes: JSONSerialization.data(withJSONObject: $0), encoding: .utf8) ?? ""
            }
            let name = compactOnly ? "transcript.jsonl" : "transcript_full.jsonl"
            try lines.joined(separator: "\n").write(
                to: logs.appendingPathComponent(name),
                atomically: true,
                encoding: .utf8)
        }
        return home
    }

    private static func reply(
        _ index: Int,
        at createdAt: String,
        model: String? = "gemini-9-quartz-high",
        input: Int = 100,
        cacheRead: Int = 900,
        cacheWrite: Int = 0,
        output: Int = 50,
        status: String = "DONE") -> [String: Any]
    {
        var step: [String: Any] = [
            "step_index": index,
            "type": "PLANNER_RESPONSE",
            "status": status,
            "created_at": createdAt,
            "input_tokens": input,
            "cache_read_tokens": cacheRead,
            "cache_write_tokens": cacheWrite,
            "output_tokens": output,
        ]
        step["model"] = model
        return step
    }

    @Test
    func `totals count new input cache reads cache writes and output`() throws {
        let home = try Self.makeHome(sessions: ["a": [
            Self.reply(1, at: "2026-03-10T11:10:00.000Z", cacheWrite: 25),
            Self.reply(2, at: "2026-03-10T12:05:00.000Z", input: 10, cacheRead: 0, output: 5),
        ]])
        defer { try? FileManager.default.removeItem(at: home) }

        let snapshot = try AntigravityLocalUsageReader(homeDirectory: home, environment: [:])
            .fetch(now: Self.now, historyDays: 30, calendar: Self.utc)

        #expect(snapshot.report.data.count == 1)
        let day = try #require(snapshot.report.data.first)
        #expect(day.date == "2026-03-10")
        #expect(day.inputTokens == 110)
        #expect(day.cacheReadTokens == 900)
        #expect(day.cacheCreationTokens == 25)
        #expect(day.outputTokens == 55)
        #expect(day.totalTokens == 1090)
        #expect(day.requestCount == 2)
        #expect(day.costUSD == nil)
        #expect(snapshot.rolling24Hours.totalTokens == 1090)
        #expect(snapshot.rolling24Hours.costUSD == nil)
    }

    @Test
    func `hourly usage covers the last 24 clock hours and places each reply in its hour`() throws {
        let home = try Self.makeHome(sessions: ["a": [
            Self.reply(1, at: "2026-03-10T11:10:00.000Z"),
            Self.reply(2, at: "2026-03-10T11:50:00.000Z"),
            Self.reply(3, at: "2026-03-10T12:05:00.000Z"),
            // Before the first of the 24 hours, but inside the 30-day history.
            Self.reply(4, at: "2026-03-08T09:00:00.000Z"),
        ]])
        defer { try? FileManager.default.removeItem(at: home) }

        let snapshot = try AntigravityLocalUsageReader(homeDirectory: home, environment: [:])
            .fetch(now: Self.now, historyDays: 30, calendar: Self.utc)
        let hourly = snapshot.hourly24Hours

        #expect(hourly.count == 24)
        #expect(hourly.last?.startDate == Date(timeIntervalSince1970: 1_773_144_000))
        #expect(hourly.last?.totalTokens == 1050)
        #expect(hourly[22].totalTokens == 2100)
        #expect(hourly.dropLast(2).allSatisfy { $0.totalTokens == 0 })
        #expect(snapshot.report.data.map(\.date) == ["2026-03-08", "2026-03-10"])
        #expect(snapshot.toTokenSnapshot(now: Self.now, historyDays: 30, calendar: Self.utc).hourly24Hours.count == 24)
    }

    @Test
    func `unfinished steps and replies outside the history window are left out`() throws {
        let home = try Self.makeHome(sessions: ["a": [
            Self.reply(1, at: "2026-03-10T11:10:00.000Z", status: "RUNNING"),
            Self.reply(2, at: "2026-01-01T11:10:00.000Z"),
            Self.reply(3, at: "2026-03-10T11:20:00.000Z"),
            // A later line for the same step replaces the earlier one.
            Self.reply(3, at: "2026-03-10T11:21:00.000Z", output: 70),
            ["step_index": 4, "type": "USER_INPUT", "created_at": "2026-03-10T11:22:00.000Z", "content": "next"],
        ]])
        defer { try? FileManager.default.removeItem(at: home) }

        let snapshot = try AntigravityLocalUsageReader(homeDirectory: home, environment: [:])
            .fetch(now: Self.now, historyDays: 30, calendar: Self.utc)

        #expect(snapshot.report.summary?.totalTokens == 1070)
        #expect(snapshot.report.data.first?.requestCount == 1)
    }

    @Test
    func `a one day history still counts yesterday's replies in the rolling day`() throws {
        let home = try Self.makeHome(sessions: ["a": [
            Self.reply(1, at: "2026-03-09T20:10:00.000Z"),
        ]])
        defer { try? FileManager.default.removeItem(at: home) }

        let snapshot = try AntigravityLocalUsageReader(homeDirectory: home, environment: [:])
            .fetch(now: Self.now, historyDays: 1, calendar: Self.utc)

        #expect(snapshot.report.data.isEmpty)
        #expect(snapshot.rolling24Hours.totalTokens == 1050)
        #expect(snapshot.hourly24Hours.reduce(0) { $0 + $1.totalTokens } == 1050)
    }

    @Test
    func `both spellings of a model are counted as one model`() throws {
        let home = try Self.makeHome(sessions: [
            "a": [Self.reply(1, at: "2026-03-10T11:10:00.000Z", model: "Gemini 9 Quartz (High)")],
            "b": [Self.reply(1, at: "2026-03-10T11:15:00.000Z", model: "gemini-9-quartz-high")],
        ], compactOnly: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let snapshot = try AntigravityLocalUsageReader(homeDirectory: home, environment: [:])
            .fetch(now: Self.now, historyDays: 30, calendar: Self.utc)
        let breakdowns = try #require(snapshot.report.data.first?.modelBreakdowns)

        #expect(breakdowns.map(\.modelName) == ["gemini-9-quartz-high"])
        #expect(breakdowns.first?.requestCount == 2)
        #expect(breakdowns.first?.totalTokens == 2100)
    }

    @Test
    func `no transcripts is reported as unavailable history rather than zero usage`() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("agy-usage-empty-\(UUID().uuidString)", isDirectory: true)
        #expect(throws: AntigravityLocalUsageError.historyUnavailable) {
            try AntigravityLocalUsageReader(homeDirectory: home, environment: [:])
                .fetch(now: Self.now, historyDays: 30, calendar: Self.utc)
        }
    }

    @Test
    func `antigravity token snapshots are loadable`() {
        #expect(CostUsageFetcher.supportsTokenSnapshot(.antigravity))
        #expect(AntigravityProviderDescriptor.descriptor.tokenCost.supportsTokenCost)
    }
}
