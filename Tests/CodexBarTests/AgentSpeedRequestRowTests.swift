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

        // With a known first-token wait the figure is streaming-only, so it carries no "≈".
        let streamed = AgentSpeedRequestRow(sample: Self.sample(outputTokens: 30, latencyMs: 1500, firstTokenMs: 1000))
        #expect(!streamed.countsAsRealUsage)
        #expect(streamed.speedText == "60 tok/s")
    }

    @Test
    func `columns use dashes for values the log does not have`() {
        let row = AgentSpeedRequestRow(sample: Self.sample(
            model: nil,
            outputTokens: 15,
            latencyMs: 100,
            firstTokenMs: nil))
        let columns = row.columns(now: Self.base.addingTimeInterval(30))

        #expect(columns.count == AgentSpeedRequestRow.columnTitles.count)
        #expect(columns[0] == L("agent_speed_age_now"))
        #expect(columns[1] == AgentSpeedRequestRow.placeholder)
        #expect(columns[AgentSpeedRequestRow.speedColumnIndex] == "≈ 150 tok/s")
        #expect(columns[3] == AgentSpeedRequestRow.placeholder)
        #expect(columns[4] == AgentSpeedRequestRow.placeholder)
    }

    @Test
    func `age is minutes then hours then days ago`() {
        let row = AgentSpeedRequestRow(sample: Self.sample(outputTokens: 500, latencyMs: 11000, firstTokenMs: 1000))

        #expect(row.ageText(now: Self.base.addingTimeInterval(5 * 60 + 40)) == L("agent_speed_age_minutes_format", 5))
        #expect(row.ageText(now: Self.base.addingTimeInterval(3 * 3600 + 59)) == L("agent_speed_age_hours_format", 3))
        #expect(row.ageText(now: Self.base.addingTimeInterval(2 * 86400)) == L("agent_speed_age_days_format", 2))
    }

    @Test
    func `antigravity rows show the model codename once for both spellings`() {
        func row(_ model: String) -> AgentSpeedRequestRow {
            AgentSpeedRequestRow(sample: AgentSpeedSample(
                source: .antigravity,
                timestamp: Self.base,
                model: model,
                outputTokens: 500,
                latencyMs: 11000,
                firstTokenMs: 1000))
        }

        #expect(row("Gemini 9 Quartz (High)").model == "quartz-high")
        #expect(row("gemini-9-quartz-high").model == "quartz-high")
        #expect(row("gemini-9-basalt-tiered-agy").model == "basalt")
    }

    @Test
    func `the card lists fewer rows than the submenu`() throws {
        let samples = (0..<20).map {
            Self.sample(offset: TimeInterval($0), outputTokens: 500, latencyMs: 11000, firstTokenMs: 1000)
        }
        let summary = try #require(AgentSpeedSummary.summarize(samples, now: Self.base.addingTimeInterval(120)))
        let presentation = try #require(AgentSpeedPresentation.from(summary))

        #expect(presentation.requests.count == 10)
        #expect(presentation.inlineRequests.count == AgentSpeedRequestRow.inlineLimit)
        #expect(presentation.inlineRequests.first?.timestamp == Self.base.addingTimeInterval(19))
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

    @Test
    func `a reply that missed the cache keeps the earlier cache deadline`() throws {
        let samples = [
            Self.sample(
                offset: 0,
                outputTokens: 500,
                latencyMs: 11000,
                firstTokenMs: 1000,
                newInput: 10,
                cacheRead: 90,
                cacheTTL: 300),
            Self.sample(offset: 60, outputTokens: 500, latencyMs: 11000, firstTokenMs: 1000, newInput: 100),
        ]
        let summary = try #require(AgentSpeedSummary.summarize(samples, now: Self.base.addingTimeInterval(120)))

        #expect(AgentSpeedRequestRow.cacheExpiry(from: summary) == Self.base.addingTimeInterval(300))
    }
}
