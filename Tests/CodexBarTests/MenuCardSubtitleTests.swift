import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MenuCardSubtitleTests {
    @Test
    func `subtitle uses injected current time`() throws {
        let updatedAt = Date(timeIntervalSinceReferenceDate: 0)
        let now = updatedAt.addingTimeInterval(5 * 3600)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 22,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3000),
                resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "codex@example.com",
                accountOrganization: nil,
                loginMethod: "Plus Plan"))
        let metadata = try #require(ProviderDefaults.metadata[.codex])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .codex,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: "codex@example.com", plan: "Plus Plan"),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.subtitleText == UsageFormatter.updatedString(from: updatedAt, now: now))
    }

    @Test
    func `subtitle shows refreshing while cached snapshot remains visible`() throws {
        let updatedAt = Date(timeIntervalSinceReferenceDate: 0)
        let now = updatedAt.addingTimeInterval(5 * 3600)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 22,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3000),
                resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "codex@example.com",
                accountOrganization: nil,
                loginMethod: "Plus Plan"))
        let metadata = try #require(ProviderDefaults.metadata[.codex])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .codex,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: "codex@example.com", plan: "Plus Plan"),
            isRefreshing: true,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.subtitleText == "Refreshing…")
        #expect(model.subtitleStyle == .loading)
        #expect(!model.metrics.isEmpty)
    }

    @Test
    func `OpenCode local usage uses token snapshot update when web quota is unavailable`() throws {
        let updatedAt = Date(timeIntervalSinceReferenceDate: 0)
        let now = updatedAt.addingTimeInterval(5 * 3600)
        let metadata = try #require(ProviderDefaults.metadata[.opencode])
        let tokenSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 12,
            sessionCostUSD: 0,
            last30DaysTokens: 12,
            last30DaysCostUSD: 0,
            historyDays: 30,
            daily: [],
            updatedAt: updatedAt)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .opencode,
            metadata: metadata,
            snapshot: nil,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: tokenSnapshot,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            tokenCostMenuSectionEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.subtitleText == UsageFormatter.updatedString(from: updatedAt, now: now))
    }
}
