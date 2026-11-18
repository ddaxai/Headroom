import Foundation
import Testing
@testable import CodexBarCore

struct PiAgentUsageCardTests {
    @Test
    func `pi card exposes relay profile sections`() {
        let report = CostUsageDailyReport(
            data: [.init(date: "2026-08-20", inputTokens: 10, outputTokens: 5, totalTokens: 15, costUSD: 0.015, modelsUsed: ["gpt-5.4"], modelBreakdowns: nil)],
            summary: .init(totalInputTokens: 10, totalOutputTokens: 5, cacheReadTokens: nil, cacheCreationTokens: nil, totalTokens: 15, totalCostUSD: 0.015))
        let snapshot = PiAgentUsageCardSnapshot(
            profileReports: ["liang": [PiAgentUsageCardSnapshot.WindowKind.last30Days: report]])

        #expect(snapshot.sections.map(\.providerKey) == ["liang"])
        #expect(snapshot.sections.first?.totalTokens == 15)
        let detail = snapshot.sections[0].tokenSnapshot(
            now: Date(timeIntervalSince1970: 1_755_720_000),
            historyDays: 30)
        #expect(detail.last30DaysTokens == 15)
        #expect(detail.daily.count == 1)
    }

    @Test
    func `profile windows do not inflate the aggregate total`() {
        func report(_ tokens: Int) -> CostUsageDailyReport {
            CostUsageDailyReport(
                data: [.init(
                    date: "2026-08-20",
                    inputTokens: tokens,
                    outputTokens: 0,
                    totalTokens: tokens,
                    costUSD: Double(tokens) / 1000,
                    modelsUsed: ["gpt-5.4"],
                    modelBreakdowns: nil)],
                summary: .init(
                    totalInputTokens: tokens,
                    totalOutputTokens: 0,
                    totalTokens: tokens,
                    totalCostUSD: Double(tokens) / 1000))
        }

        let snapshot = PiAgentUsageCardSnapshot(profileReports: [
            "cpa": [
                .rolling24Hours: report(10),
                .last7Days: report(20),
                .last30Days: report(30),
            ],
        ])

        #expect(snapshot.totalTokens == 30)
        #expect(snapshot.sections.first?.totalTokens == 30)
    }

    @Test
    func `pi agent loader scans the widest window first`() {
        #expect(PiAgentUsageCardLoader.scanOrder == [
            .last30Days,
            .last7Days,
            .rolling24Hours,
        ])
    }

    @Test
    func `pi reports project into an independent agent card snapshot`() {
        let codex = CostUsageDailyReport(
            data: [
                .init(
                    date: "2026-08-18",
                    inputTokens: 100,
                    outputTokens: 20,
                    totalTokens: 120,
                    costUSD: 0.12,
                    modelsUsed: ["gpt-5.4"],
                    modelBreakdowns: [
                        .init(modelName: "gpt-5.4", costUSD: 0.12, totalTokens: 120),
                    ]),
            ],
            summary: .init(
                totalInputTokens: 100,
                totalOutputTokens: 20,
                totalTokens: 120,
                totalCostUSD: 0.12))
        let claude = CostUsageDailyReport(
            data: [
                .init(
                    date: "2026-08-18",
                    inputTokens: 40,
                    outputTokens: 5,
                    totalTokens: 45,
                    costUSD: 0.045,
                    modelsUsed: ["claude-sonnet-4-6"],
                    modelBreakdowns: [
                        .init(modelName: "claude-sonnet-4-6", costUSD: 0.045, totalTokens: 45),
                    ]),
            ],
            summary: .init(
                totalInputTokens: 40,
                totalOutputTokens: 5,
                totalTokens: 45,
                totalCostUSD: 0.045))

        let snapshot = PiAgentUsageCardSnapshot(codexReport: codex, claudeReport: claude)

        #expect(snapshot.hasUsage)
        #expect(snapshot.totalTokens == 165)
        #expect(abs(snapshot.totalCostUSD - 0.165) < 0.000001)
        #expect(snapshot.models == ["claude-sonnet-4-6", "gpt-5.4"])
    }

    @Test
    func `empty pi reports do not produce an agent card`() {
        let empty = CostUsageDailyReport(data: [], summary: nil)
        let snapshot = PiAgentUsageCardSnapshot(codexReport: empty, claudeReport: empty)

        #expect(!snapshot.hasUsage)
        #expect(snapshot.totalTokens == 0)
        #expect(snapshot.models.isEmpty)
    }

    @Test
    func `nested pi windows do not double count the card total`() {
        func report(tokens: Int) -> CostUsageDailyReport {
            CostUsageDailyReport(
                data: [
                    .init(
                        date: "2026-08-18",
                        inputTokens: tokens,
                        outputTokens: 0,
                        totalTokens: tokens,
                        costUSD: Double(tokens) / 1000,
                        modelsUsed: ["gpt-5.4"],
                        modelBreakdowns: nil),
                ],
                summary: .init(
                    totalInputTokens: tokens,
                    totalOutputTokens: 0,
                    totalTokens: tokens,
                    totalCostUSD: Double(tokens) / 1000))
        }

        let snapshot = PiAgentUsageCardSnapshot(
            codexReports: [
                .rolling24Hours: report(tokens: 10),
                .last7Days: report(tokens: 20),
                .last30Days: report(tokens: 30),
            ],
            claudeReports: [:])

        #expect(snapshot.totalTokens == 30)
        #expect(snapshot.windows.map(\.totalTokens) == [10, 20, 30])
    }
}
