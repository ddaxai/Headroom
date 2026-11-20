import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite("Agent speed request rows")
struct AgentSpeedRequestRowTests {
    private static let base = Date(timeIntervalSince1970: 1_800_000_000)

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func sample(
        offset: TimeInterval = 0,
        model: String? = "claude-opus-4-7",
        outputTokens: Int,
        latencyMs: Int64,
        firstTokenMs: Int64?,
        newInput: Int? = nil,
        cacheRead: Int? = nil,
        cacheTTL: Int? = nil) -> AgentSpeedSample
    {
        AgentSpeedSample(
            source: .claude,
            timestamp: self.base.addingTimeInterval(offset),
            model: model,
            outputTokens: outputTokens,
            latencyMs: latencyMs,
            firstTokenMs: firstTokenMs,
            newInputTokens: newInput,
            cacheReadTokens: cacheRead,
            cacheTTLSeconds: cacheTTL)
    }

    @Test
    func `a measurable reply counts as real usage and shows its cache hit rate`() {
        let row = AgentSpeedRequestRow(sample: Self.sample(
            outputTokens: 500,
            latencyMs: 11000,
            firstTokenMs: 1000,
            newInput: 100,
            cacheRead: 900))

        #expect(row.countsAsRealUsage)
        #expect(row.speedText == "50 tok/s")
        #expect(row.firstTokenText == "1.0s")
        #expect(row.cacheHitText == "90.0%")
    }

    @Test
    func `a short reply keeps its speed but is not real usage`() {
        // 15 tokens in 100 ms reads as 150 tok/s, which is why it stays out of the card's figures.
        let row = AgentSpeedRequestRow(sample: Self.sample(outputTokens: 15, latencyMs: 100, firstTokenMs: nil))

        #expect(!row.countsAsRealUsage)
        #expect(row.speedText == "≈ 150 tok/s")
        #expect(row.firstTokenText == nil)
        #expect(row.cacheHitText == nil)
    }

    @Test
    func `columns use dashes for values the log does not have`() {
        let row = AgentSpeedRequestRow(sample: Self.sample(
            model: nil,
            outputTokens: 15,
            latencyMs: 100,
            firstTokenMs: nil))
        let columns = row.columns(calendar: Self.utc, now: Self.base.addingTimeInterval(60))

        #expect(columns.count == AgentSpeedRequestRow.columnTitles.count)
        #expect(columns[0] == "08:00:00")
        #expect(columns[1] == AgentSpeedRequestRow.placeholder)
        #expect(columns[4] == AgentSpeedRequestRow.placeholder)
        #expect(columns[5] == AgentSpeedRequestRow.placeholder)
    }

    @Test
    func `a reply from another day shows its date`() {
        let row = AgentSpeedRequestRow(sample: Self.sample(outputTokens: 500, latencyMs: 11000, firstTokenMs: 1000))
        let columns = row.columns(calendar: Self.utc, now: Self.base.addingTimeInterval(2 * 86400))

        #expect(columns[0] == "01-15 08:00")
    }

    @Test
    func `long model names are truncated to the column width`() {
        let long = String(repeating: "m", count: 40)
        let truncated = AgentSpeedRequestRow.truncatedModel(long)

        #expect(truncated.count == AgentSpeedRequestRow.modelColumnCharacterLimit)
        #expect(truncated.hasSuffix("…"))
        #expect(AgentSpeedRequestRow.truncatedModel("claude-opus-4-7") == "claude-opus-4-7")
        #expect(AgentSpeedRequestRow.truncatedModel(nil) == AgentSpeedRequestRow.placeholder)
    }

    @Test
    func `the presentation lists requests newest first with the session cache expiry`() throws {
        let samples = [
            Self.sample(offset: 0, outputTokens: 500, latencyMs: 11000, firstTokenMs: 1000),
            Self.sample(
                offset: 60,
                outputTokens: 15,
                latencyMs: 100,
                firstTokenMs: nil,
                newInput: 10,
                cacheRead: 90,
                cacheTTL: 300),
        ]
        let summary = try #require(AgentSpeedSummary.summarize(samples, now: Self.base.addingTimeInterval(120)))
        let presentation = try #require(AgentSpeedPresentation.from(summary))

        #expect(presentation.requests.count == 2)
        #expect(presentation.requests[0].countsAsRealUsage == false)
        #expect(presentation.requests[1].countsAsRealUsage)
        #expect(presentation.cacheExpiresAt == Self.base.addingTimeInterval(360))
    }
}
