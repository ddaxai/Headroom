import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct AntigravityMenuCardTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func dayKey(daysAgo: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: self.now) ?? self.now
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func entry(daysAgo: Int, tokens: Int) -> CostUsageDailyReport.Entry {
        CostUsageDailyReport.Entry(
            date: self.dayKey(daysAgo: daysAgo),
            inputTokens: tokens,
            outputTokens: nil,
            totalTokens: tokens,
            costUSD: nil,
            modelsUsed: nil,
            modelBreakdowns: nil)
    }

    private static func snapshot() -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: 1_000_000,
            sessionCostUSD: nil,
            last30DaysTokens: 6_000_000,
            last30DaysCostUSD: nil,
            rolling24Hours: CostUsageRolling24HourSummary(totalTokens: 2_500_000, costUSD: nil),
            historyDays: 30,
            daily: [
                self.entry(daysAgo: 0, tokens: 1_000_000),
                self.entry(daysAgo: 3, tokens: 2_000_000),
                self.entry(daysAgo: 20, tokens: 3_000_000),
            ],
            updatedAt: self.now)
    }

    @Test
    func `antigravity token section is one line of totals with no cost column`() throws {
        let section = try #require(UsageMenuCardView.Model.tokenUsageSection(
            provider: .antigravity,
            enabled: true,
            comparisonPeriodsEnabled: false,
            snapshot: Self.snapshot(),
            error: nil))

        #expect(section.sessionLine == "24h 2.50M · 7d 3.00M · 30d 6.00M")
        #expect(section.monthLine.isEmpty)
        #expect(section.comparisonLines.isEmpty)
        #expect(section.hintLine == nil)
        #expect(!section.sessionLine.contains("—"))
        #expect(UsageMenuCardView.Model.tokenUsageHeader(provider: .antigravity) == L("token_usage_header_tokens"))
        #expect(UsageMenuCardView.Model.tokenUsageHeader(provider: .codex) == L("Cost"))
    }

    @Test
    func `antigravity tokens show without the cost setting but stay out of cost surfaces`() {
        #expect(UsageProvider.antigravity.hasIndependentLocalTokenUsage)
        #expect(UsageProvider.antigravity.reportsTokensWithoutCost)
        #expect(UsageProvider.opencode.hasIndependentLocalTokenUsage)
        #expect(!UsageProvider.opencode.reportsTokensWithoutCost)
        #expect(!UsageProvider.codex.hasIndependentLocalTokenUsage)
        #expect(!UsageProvider.codex.reportsTokensWithoutCost)
    }

    @Test
    func `only antigravity uses compact quota rows and its tooltip keeps every detail`() {
        #expect(UsageMenuCardView.usesCompactMetricRows(provider: .antigravity))
        #expect(!UsageMenuCardView.usesCompactMetricRows(provider: .codex))
        #expect(!UsageMenuCardView.usesCompactMetricRows(provider: .claude))

        let metric = UsageMenuCardView.Model.Metric(
            id: "secondary",
            title: "Weekly",
            percent: 62,
            percentStyle: .left,
            resetText: "Resets Nov 25, 11:26",
            detailText: nil,
            detailLeftText: "5% in deficit",
            detailRightText: "Runs out in 3d 18h",
            pacePercent: nil,
            paceOnTop: true)

        #expect(UsageMenuCardView.compactMetricTooltip(metric) == [
            metric.percentLabel,
            "Resets Nov 25, 11:26",
            "5% in deficit",
            "Runs out in 3d 18h",
        ].joined(separator: "\n"))
    }

    @Test
    func `usage detail submenu is as wide as the request list stacked under it`() throws {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "AntigravityMenuCardTests-submenu-width"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: NSStatusBar.system)

        let samples = (0..<12).map { index in
            AgentSpeedSample(
                source: .antigravity,
                timestamp: Self.now.addingTimeInterval(TimeInterval(index)),
                model: "gemini-9-quartz-high",
                outputTokens: 500,
                latencyMs: 11000,
                firstTokenMs: 1000,
                newInputTokens: 100,
                cacheReadTokens: 900)
        }
        let summary = try #require(AgentSpeedSummary.summarize(samples, now: Self.now.addingTimeInterval(120)))
        let presentation = try #require(AgentSpeedPresentation.from(summary))
        let listWidth = try #require(controller.agentSpeedRequestListWidth(presentation))
        #expect(listWidth >= StatusItemController.agentSpeedRequestMenuWidth)
        #expect(controller.agentSpeedRequestListWidth(nil) == nil)

        let submenu = controller.makeCodexUsageDetailsSubmenu(
            snapshot: Self.snapshot(),
            title: "Antigravity",
            width: 300,
            agentSpeed: presentation)
        #expect(submenu.minimumWidth == listWidth)
        // The hosted detail only exists when card rendering is on; when it does, it spans the whole menu.
        if let hosted = submenu.items.first?.view {
            #expect(hosted.frame.width == listWidth)
        }
        // Ten selectable rows; the legend wraps instead of widening the menu.
        #expect(submenu.items.count(where: { $0.attributedTitle != nil && $0.isEnabled }) == 10)
        #expect(ceil(submenu.size.width) <= listWidth)

        let plain = controller.makeCodexUsageDetailsSubmenu(snapshot: Self.snapshot(), title: "Antigravity", width: 300)
        #expect(plain.minimumWidth == 300)
    }
}
