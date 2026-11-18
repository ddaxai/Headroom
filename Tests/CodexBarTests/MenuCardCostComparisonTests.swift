import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MenuCardCostComparisonTests {
    @Test
    func `cost section adds shorter periods from the same history snapshot`() throws {
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 400,
            sessionCostUSD: 4,
            last30DaysTokens: 1000,
            last30DaysCostUSD: 10,
            historyDays: 90,
            daily: [
                Self.entry(day: "2026-06-01", cost: 1, tokens: 100),
                Self.entry(day: "2026-06-25", cost: 2, tokens: 200),
                Self.entry(day: "2026-07-01", cost: 4, tokens: 400),
            ],
            updatedAt: Self.localNoon(year: 2026, month: 7, day: 1))

        let section = try #require(UsageMenuCardView.Model.tokenUsageSection(
            provider: .claude,
            enabled: true,
            comparisonPeriodsEnabled: true,
            snapshot: snapshot,
            error: nil))

        #expect(section.comparisonLines == [
            "Last 7 days: $6.00 · 0.00M tokens",
            "Last 30 days: $6.00 · 0.00M tokens",
        ])
    }

    @Test
    func `comparison periods remain opt in`() throws {
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 1,
            sessionCostUSD: 1,
            last30DaysTokens: 1,
            last30DaysCostUSD: 1,
            historyDays: 90,
            daily: [],
            updatedAt: Date())

        let section = try #require(UsageMenuCardView.Model.tokenUsageSection(
            provider: .claude,
            enabled: true,
            comparisonPeriodsEnabled: false,
            snapshot: snapshot,
            error: nil))
        #expect(section.comparisonLines.isEmpty)
    }

    @Test
    func `OpenCode local usage always shows 24h 7d and 30d windows`() throws {
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 300,
            last30DaysCostUSD: 3,
            rolling24Hours: CostUsageRolling24HourSummary(totalTokens: 24, costUSD: 0.24),
            historyDays: 30,
            daily: [Self.entry(day: "2026-07-01", cost: 1, tokens: 100)],
            updatedAt: Self.localNoon(year: 2026, month: 7, day: 1))

        let section = try #require(UsageMenuCardView.Model.tokenUsageSection(
            provider: .opencode,
            enabled: true,
            comparisonPeriodsEnabled: false,
            snapshot: snapshot,
            error: nil))

        #expect(section.sessionLine.hasPrefix("24h:"))
        #expect(section.comparisonLines.count == 1)
        #expect(section.comparisonLines[0].hasPrefix("Last 7 days:"))
        #expect(section.monthLine.hasPrefix("Last 30 days:"))
    }

    @Test
    func `codex rolling 24 hour cost uses labelled blended estimate when pricing is incomplete`() throws {
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 99,
            sessionCostUSD: 9.99,
            last30DaysTokens: 999,
            last30DaysCostUSD: 99.99,
            rolling24Hours: CostUsageRolling24HourSummary(totalTokens: 321, costUSD: nil),
            daily: [],
            updatedAt: Date())

        let section = try #require(UsageMenuCardView.Model.tokenUsageSection(
            provider: .codex,
            enabled: true,
            comparisonPeriodsEnabled: false,
            snapshot: snapshot,
            error: nil))

        // 99.99 / 999 * 321 rounds to $32.13. Keep the expected display tied
        // to the fixture's actual blended-rate arithmetic.
        #expect(section.sessionLine == "24h: ≈$32.13 · 0.00M tokens")
    }

    @Test
    func `codex rolling estimate stays unavailable without a known blended rate`() throws {
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 999,
            last30DaysCostUSD: nil,
            rolling24Hours: CostUsageRolling24HourSummary(totalTokens: 321, costUSD: nil),
            daily: [],
            updatedAt: Date())

        let section = try #require(UsageMenuCardView.Model.tokenUsageSection(
            provider: .codex,
            enabled: true,
            comparisonPeriodsEnabled: false,
            snapshot: snapshot,
            error: nil))

        #expect(section.sessionLine == "24h: — · 0.00M tokens")
    }

    @Test
    func `inline dashboard shows enabled comparison periods`() throws {
        let now = Date(timeIntervalSince1970: 1_783_123_200)
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 400,
            sessionCostUSD: 4,
            last30DaysTokens: 1000,
            last30DaysCostUSD: 10,
            historyDays: 90,
            daily: [
                Self.entry(day: "2026-06-01", cost: 1, tokens: 100),
                Self.entry(day: "2026-06-25", cost: 2, tokens: 200),
                Self.entry(day: "2026-07-01", cost: 4, tokens: 400),
            ],
            updatedAt: now)
        let metadata = try #require(ProviderDefaults.metadata[.codex])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .codex,
            metadata: metadata,
            snapshot: nil,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: snapshot,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: true,
            costComparisonPeriodsEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.inlineUsageDashboard?.detailLines.prefix(2) == [
            "Last 7 days: $4.00 · 0.00M tokens",
            "Last 30 days: $6.00 · 0.00M tokens",
        ])
    }

    private static func entry(day: String, cost: Double, tokens: Int) -> CostUsageDailyReport.Entry {
        CostUsageDailyReport.Entry(
            date: day,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: tokens,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: nil)
    }

    private static func localNoon(year: Int, month: Int, day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }
}
