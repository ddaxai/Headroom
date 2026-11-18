import CodexBarCore
import SwiftUI
import Testing
@testable import CodexBar

struct CodexAccountSummaryCardModelTests {
    @Test
    @MainActor
    func `detail rail keeps fixed geometry`() {
        #expect(CardDetailRail.width == 30)
        #expect(CardDetailRail.borderWidth == 1)
    }

    @Test
    func `weekly metric is preferred over session metric`() {
        let metrics = [
            Self.metric(id: "primary", percent: 80, style: .left),
            Self.metric(id: "secondary", percent: 35, style: .left),
        ]

        #expect(CodexAccountSummaryCardModel.preferredQuota(in: metrics)?.id == "secondary")
    }

    @Test
    func `segmented meter always expresses remaining percent`() {
        let usedMetric = Self.metric(id: "secondary", percent: 70, style: .used)
        let remainingMetric = Self.metric(id: "secondary", percent: 30, style: .left)

        #expect(CodexAccountSummaryCardModel.remainingPercent(for: usedMetric) == 30)
        #expect(CodexAccountSummaryCardModel.remainingPercent(for: remainingMetric) == 30)
    }

    @Test
    func `segmented meter clamps malformed percentages`() {
        #expect(CodexAccountSummaryCardModel.remainingPercent(
            for: Self.metric(id: "secondary", percent: 140, style: .left)) == 100)
        #expect(CodexAccountSummaryCardModel.remainingPercent(
            for: Self.metric(id: "secondary", percent: 140, style: .used)) == 0)
    }

    @Test
    func `relay balance meter expresses remaining percent when a total is available`() {
        let summary = RelayUsageSummary(
            remaining: 80,
            used: 20,
            total: 100,
            unit: "USD",
            planName: nil,
            updatedAt: Date())

        #expect(CodexRelaySummaryCardModel.remainingPercent(for: summary) == 80)
    }

    @Test
    func `relay balance without a total does not invent a percentage`() {
        let summary = RelayUsageSummary(
            remaining: 80,
            used: nil,
            total: nil,
            unit: "USD",
            planName: nil,
            updatedAt: Date())

        #expect(CodexRelaySummaryCardModel.remainingPercent(for: summary) == nil)
    }

    @Test
    func `relay card uses gateway calculated recent token cost`() {
        let summary = RelayUsageSummary(
            remaining: 80,
            used: 20,
            total: 100,
            unit: "USD",
            planName: nil,
            updatedAt: Date(),
            recentUsage: RelayRecentUsageSummary(
                period: .rolling24Hours,
                totalTokens: 1234,
                actualCostUSD: 5.67))

        #expect(RelayUsagePresentation.recentUsageLine(summary) == "24h: 0.00M tokens · $5.67")
    }

    @Test
    func `relay card hourly usage comes only from the local ledger`() {
        let local = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 1234,
            last30DaysCostUSD: 5.67,
            rolling24Hours: .init(totalTokens: 1234, costUSD: 5.67),
            daily: [],
            updatedAt: Date(timeIntervalSince1970: 10))

        let resolved = CodexRelayMenuLocalUsage.resolve(
            snapshot: local,
            preferredCurrencyCode: "USD")
        let unavailable = CodexRelayMenuLocalUsage.resolve(
            snapshot: nil,
            preferredCurrencyCode: "USD")

        #expect(resolved.line.contains(L("codex_relay_local_usage_format", "")))
        #expect(resolved.snapshot?.rolling24Hours?.totalTokens == 1234)
        #expect(unavailable.line == L("codex_local_usage_empty"))
        #expect(unavailable.snapshot == nil)
    }

    @Test
    func `zero rolling relay usage retains older history for the detail drawer`() {
        let local = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 4321,
            last30DaysCostUSD: 6.54,
            rolling24Hours: .init(totalTokens: 0, costUSD: 0),
            daily: [
                .init(
                    date: "2026-08-18",
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: 4321,
                    costUSD: 6.54,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            updatedAt: Date(timeIntervalSince1970: 1_787_000_000))

        let resolved = CodexRelayMenuLocalUsage.resolve(
            snapshot: local,
            preferredCurrencyCode: "USD")

        #expect(resolved.line.contains("24h: 0 tokens"))
        #expect(resolved.snapshot == local)
    }

    @Test
    func `active account and health error survive a stale quota snapshot`() {
        let resetCredits = CodexResetCreditsPresentation(
            text: "2 available",
            items: [CodexResetCreditPresentationItem(expiryText: "Expires in 1d", compactExpiryText: "1d")])
        let source = UsageMenuCardView.Model(
            provider: .codex,
            providerName: "Codex",
            email: "account@example.com",
            subtitleText: "Needs re-auth",
            subtitleStyle: .error,
            planText: "Team",
            metrics: [Self.metric(id: "secondary", percent: 35, style: .left)],
            usageNotes: [],
            openAIAPIUsage: nil,
            inlineUsageDashboard: nil,
            creditsText: nil,
            creditsRemaining: nil,
            creditsProgressPercent: nil,
            creditsScaleText: nil,
            creditsHintText: nil,
            creditsHintCopyText: nil,
            codexResetCredits: resetCredits,
            providerCost: nil,
            tokenUsage: nil,
            placeholder: nil,
            progressColor: .cyan)

        let card = CodexAccountSummaryCardModel(
            model: source,
            ordinal: 2,
            workspace: "Workspace",
            isActive: true)

        #expect(card.isActive)
        #expect(card.alertText == "Needs re-auth")
        #expect(card.quota?.remainingPercent == 35)
        #expect(card.quotas.map(\.remainingPercent) == [35])
        #expect(card.resetCredits == resetCredits)
        #expect(card.usageLine == nil)
    }

    @Test
    func `local usage presentation distinguishes scanning empty and unattributed states`() {
        #expect(CodexLocalUsagePresentation.resolve(
            summaryLine: nil,
            refreshInFlight: true,
            coverageIsComplete: nil,
            sharedCorpusHasUsage: false) == .init(
            state: .loading,
            line: L("codex_local_usage_scanning"),
            unassignedExplanation: nil))
        #expect(CodexLocalUsagePresentation.resolve(
            summaryLine: nil,
            refreshInFlight: false,
            coverageIsComplete: true,
            sharedCorpusHasUsage: false) == .init(
            state: .empty,
            line: L("codex_local_usage_empty"),
            unassignedExplanation: nil))
        #expect(CodexLocalUsagePresentation.resolve(
            summaryLine: nil,
            refreshInFlight: false,
            coverageIsComplete: true,
            sharedCorpusHasUsage: true) == .init(
            state: .unavailable,
            line: L("codex_usage_details_unavailable_official"),
            unassignedExplanation: nil))
        #expect(CodexLocalUsagePresentation.resolve(
            summaryLine: "24h: 1.2M tokens",
            refreshInFlight: false,
            coverageIsComplete: true,
            sharedCorpusHasUsage: true) == .init(
            state: .available,
            line: "24h: 1.2M tokens",
            unassignedExplanation: nil))
    }

    @Test
    func `shared history is split by provider instead of pretending to know OAuth account ownership`() {
        let shared = Self.snapshot(
            tokens: 700,
            cost: 8.50,
            officialTokens: 610,
            officialCost: 7.40,
            relayTokens: 90,
            relayCost: 1.10)

        let official = CodexStackedUsageSummary.officialTotal([shared])
        let relay = CodexStackedUsageSummary.relayTotal([shared])

        #expect(official?.totalTokens == 610)
        #expect(official?.costUSD == 7.40)
        #expect(relay?.totalTokens == 90)
        #expect(relay?.costUSD == 1.10)
    }

    @Test
    func `stacked total aggregates isolated account and unassigned history`() {
        let first = Self.snapshot(
            tokens: 100,
            cost: 1.25,
            officialTokens: 100,
            officialCost: 1.25,
            relayTokens: 0,
            relayCost: 0)
        let shared = Self.snapshot(
            tokens: 700,
            cost: 8.50,
            officialTokens: 610,
            officialCost: 7.40,
            relayTokens: 90,
            relayCost: 1.10)

        #expect(CodexStackedUsageSummary.menuTotal(
            accountSnapshots: [first],
            expectedAccountCount: 1,
            sharedSnapshot: shared)?.totalTokens == 800)
    }

    @Test
    func `stacked total estimates cost when new models are not priced yet`() {
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 1000,
            sessionCostUSD: 10,
            last30DaysTokens: 2000,
            last30DaysCostUSD: 20,
            rolling24Hours: CostUsageRolling24HourSummary(totalTokens: 200, costUSD: nil),
            daily: [],
            updatedAt: Date())

        #expect(CodexStackedUsageSummary.estimatedRollingCost(snapshot: snapshot) == 2)
    }

    @Test
    func `relay menu bar quota is clamped and formatted as remaining percent`() {
        #expect(RelayMenuBarQuotaText.remainingPercent(52.6) == "53%")
        #expect(RelayMenuBarQuotaText.remainingPercent(-5) == "0%")
        #expect(RelayMenuBarQuotaText.remainingPercent(140) == "100%")
        #expect(RelayMenuBarQuotaText.remainingPercent(nil) == nil)
    }

    private static func metric(
        id: String,
        percent: Double,
        style: UsageMenuCardView.Model.PercentStyle) -> UsageMenuCardView.Model.Metric
    {
        UsageMenuCardView.Model.Metric(
            id: id,
            title: "Weekly",
            percent: percent,
            percentStyle: style,
            resetText: nil,
            detailText: "This detail must not enter the ring presentation",
            detailLeftText: "Pace deficit",
            detailRightText: nil,
            pacePercent: nil,
            paceOnTop: true)
    }

    // swiftlint:disable:next function_parameter_count
    private static func snapshot(
        tokens: Int,
        cost: Double,
        officialTokens: Int,
        officialCost: Double,
        relayTokens: Int,
        relayCost: Double) -> CostUsageTokenSnapshot
    {
        CostUsageTokenSnapshot(
            sessionTokens: tokens,
            sessionCostUSD: cost,
            last30DaysTokens: tokens,
            last30DaysCostUSD: cost,
            rolling24Hours: CostUsageRolling24HourSummary(
                totalTokens: tokens,
                costUSD: cost,
                modelProviderBreakdowns: [
                    CostUsageModelProviderBreakdown(
                        modelProvider: "openai",
                        totalTokens: officialTokens,
                        costUSD: officialCost),
                    CostUsageModelProviderBreakdown(
                        modelProvider: "codexbar_relay",
                        totalTokens: relayTokens,
                        costUSD: relayCost),
                ]),
            daily: [],
            updatedAt: Date())
    }
}
