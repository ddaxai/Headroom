import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct CostHistorySplitNormalizationTests {
    @Test
    nonisolated func `normalized split marker uses console caution token and localized tooltip`() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/CodexBar/CostHistoryChartMenuView.swift"),
            encoding: .utf8)

        #expect(source.contains("? ConsoleDesign.cautionForeground"))
        #expect(!source.contains("? Color.orange"))
        #expect(source.contains(".help(row.splitEstimateNormalized"))
        #expect(source.contains("L(\"codex_split_estimate_normalized_help\")"))
    }

    @Test
    @MainActor
    func `normalized split tooltip has english and simplified chinese copy`() {
        let key = "codex_split_estimate_normalized_help"
        #expect(
            L(key, language: "en") ==
                "This day's split data did not match the deduplicated total, so it was normalized to that total.")
        #expect(
            L(key, language: "zh-Hans") ==
                "该日拆分数据与去重后的总量不一致，已按总量归一化。")
    }

    @Test
    @MainActor
    func `normalized split caution marker does not change detail row height`() {
        let ordinary = CostUsageDailyReport.ModelBreakdown(
            modelName: "gpt-5.4",
            costUSD: 1,
            totalTokens: 100,
            standardCostUSD: 0.75,
            priorityCostUSD: 0.25,
            standardTokens: 75,
            priorityTokens: 25)
        let normalized = CostUsageDailyReport.ModelBreakdown(
            modelName: ordinary.modelName,
            costUSD: ordinary.costUSD,
            totalTokens: ordinary.totalTokens,
            standardCostUSD: ordinary.standardCostUSD,
            priorityCostUSD: ordinary.priorityCostUSD,
            standardTokens: ordinary.standardTokens,
            priorityTokens: ordinary.priorityTokens,
            splitEstimateNormalized: true)

        let ordinaryLayout = CostHistoryChartMenuView._detailViewportConfigurationForTesting(
            provider: .codex,
            daily: [Self.entry(ordinary)])
        let normalizedLayout = CostHistoryChartMenuView._detailViewportConfigurationForTesting(
            provider: .codex,
            daily: [Self.entry(normalized)])

        #expect(ordinaryLayout.rowCount == normalizedLayout.rowCount)
        #expect(ordinaryLayout.hasOverflow == normalizedLayout.hasOverflow)
        #expect(ordinaryLayout.rowHeight == normalizedLayout.rowHeight)
    }

    private static func entry(
        _ breakdown: CostUsageDailyReport.ModelBreakdown) -> CostUsageDailyReport.Entry
    {
        CostUsageDailyReport.Entry(
            date: "2026-08-09",
            inputTokens: 75,
            outputTokens: 25,
            totalTokens: 100,
            costUSD: 1,
            modelsUsed: [breakdown.modelName],
            modelBreakdowns: [breakdown])
    }
}
