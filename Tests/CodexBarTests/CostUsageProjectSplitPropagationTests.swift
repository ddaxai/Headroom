import Testing
@testable import CodexBarCore

struct CostUsageProjectSplitPropagationTests {
    @Test
    func `project aggregation preserves normalized split diagnostics`() throws {
        let entry = CostUsageDailyReport.Entry(
            date: "2026-08-09",
            inputTokens: 75,
            outputTokens: 25,
            totalTokens: 100,
            costUSD: 1,
            modelsUsed: ["gpt-5.4"],
            modelBreakdowns: [
                CostUsageDailyReport.ModelBreakdown(
                    modelName: "gpt-5.4",
                    costUSD: 1,
                    totalTokens: 100,
                    standardCostUSD: 0.75,
                    priorityCostUSD: 0.25,
                    standardTokens: 75,
                    priorityTokens: 25,
                    splitEstimateNormalized: true),
            ])

        let breakdown = try #require(
            CostUsageFetcher._projectModelBreakdownsForTesting(from: [entry])?.first)
        #expect(breakdown.standardTokens == 75)
        #expect(breakdown.priorityTokens == 25)
        #expect(breakdown.standardCostUSD == 0.75)
        #expect(breakdown.priorityCostUSD == 0.25)
        #expect(breakdown.splitEstimateNormalized)
    }
}
