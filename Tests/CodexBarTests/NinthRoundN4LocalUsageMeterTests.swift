import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct NinthRoundN4LocalUsageMeterTests {
    @Test
    func `presentation uses exact rolling 24 hours and calendar seven day totals`() {
        let now = Date(timeIntervalSince1970: 1_786_512_000)
        let presentation = CodexRelayLocalUsagePresentation.make(
            fullCorpus: Self.snapshot(now: now, rolling: 1000, daily: 7000),
            relay: Self.snapshot(now: now, rolling: 250, daily: 1400),
            calendar: Self.utcCalendar)

        #expect(presentation?.rolling24Hours == .init(relayTokens: 250, corpusTokens: 1000))
        #expect(presentation?.last7Days == .init(relayTokens: 1400, corpusTokens: 7000))
        #expect(presentation?.rolling24Hours?.percent == 25)
        #expect(presentation?.last7Days?.percent == 20)
    }

    @Test
    func `rolling row never substitutes a calendar day`() {
        let now = Date(timeIntervalSince1970: 1_786_512_000)
        let presentation = CodexRelayLocalUsagePresentation.make(
            fullCorpus: Self.snapshot(now: now, rolling: nil, daily: 7000),
            relay: Self.snapshot(now: now, rolling: nil, daily: 1400),
            calendar: Self.utcCalendar)

        #expect(presentation?.rolling24Hours == nil)
        #expect(presentation?.last7Days?.relayTokens == 1400)
    }

    @Test
    func `invalid corpus generation coverage or numerator fails closed`() {
        let now = Date(timeIntervalSince1970: 1_786_512_000)
        #expect(CodexRelayLocalUsagePresentation.make(
            fullCorpus: Self.snapshot(now: now, rolling: 1000, daily: 7000),
            relay: Self.snapshot(now: now, rolling: 250, daily: 1400, corpusRevision: "corpus-b"),
            calendar: Self.utcCalendar) == nil)
        #expect(CodexRelayLocalUsagePresentation.make(
            fullCorpus: Self.snapshot(now: now, rolling: 1000, daily: 7000),
            relay: Self.snapshot(now: now, rolling: 1001, daily: 7001),
            calendar: Self.utcCalendar) == nil)

        let withoutCoverage = Self.snapshot(
            now: now,
            rolling: 250,
            daily: 1400,
            historyCoverageIsEstablished: false)
        let partial = CodexRelayLocalUsagePresentation.make(
            fullCorpus: Self.snapshot(now: now, rolling: 1000, daily: 7000),
            relay: withoutCoverage,
            calendar: Self.utcCalendar)
        #expect(partial?.rolling24Hours?.relayTokens == 250)
        #expect(partial?.last7Days == nil)
    }

    @Test
    func `neutral meter does not resolve a quota severity even at one hundred percent`() {
        #expect(ConsoleSegmentedMeter.severity(percent: 100, mode: .used, tone: .neutral) == nil)
        #expect(ConsoleSegmentedMeter.severity(percent: 100, mode: .used, tone: .severity) == .critical)
    }

    private static func snapshot(
        now: Date,
        rolling: Int?,
        daily: Int,
        historyCoverageIsEstablished: Bool = true,
        corpusRevision: String = "corpus-a") -> CostUsageTokenSnapshot
    {
        CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: daily,
            last30DaysCostUSD: nil,
            rolling24Hours: rolling.map { .init(totalTokens: $0, costUSD: nil) },
            historyDays: 30,
            historyCoverageIsEstablished: historyCoverageIsEstablished,
            codexCorpusRevision: corpusRevision,
            codexCorpusCoverageIsComplete: true,
            daily: [
                .init(
                    date: "2026-08-12",
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: daily,
                    costUSD: nil,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            updatedAt: now)
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
