import CodexBarCore
import Foundation

/// Deliberately small product-scope switches for this fork. Keeping these decisions in one place
/// avoids deleting upstream data plumbing that is still useful when rebasing CodexBar.
enum ForkFeaturePolicy {
    private static let defaultsRevision = 2
    static let usesHeadroomMenuShell = true
    static let headroomPopupPanelDefaultsKey = "headroomPopupPanelEnabled"

    /// Applies the opinionated first-run presentation for this fork once. A revision key lets later
    /// launches preserve choices the user makes after the migration.
    static func applyDefaultPreferences(userDefaults: UserDefaults = CodexBarPreferences.processDefaults) {
        let key = "theodoreRelayDefaultsRevision"
        guard userDefaults.integer(forKey: key) < self.defaultsRevision else { return }

        userDefaults.set(true, forKey: "mergeIcons")
        userDefaults.set(true, forKey: "menuBarShowsBrandIconWithPercent")
        userDefaults.set(MenuBarDisplayMode.percent.rawValue, forKey: "menuBarDisplayMode")
        userDefaults.set(MultiAccountMenuLayout.stacked.rawValue, forKey: "multiAccountMenuLayout")
        userDefaults.set(true, forKey: "tokenCostUsageEnabled")
        userDefaults.set(CostSummaryDisplayStyle.both.rawValue, forKey: "costSummaryDisplayStyle")
        userDefaults.set(false, forKey: "showOptionalCreditsAndExtraUsage")
        userDefaults.set(false, forKey: "mergedMenuLastSelectedWasOverview")
        userDefaults.set(false, forKey: "mergedMenuLastSelectedWasPiAgent")
        userDefaults.set(UsageProvider.codex.rawValue, forKey: "selectedMenuProvider")
        userDefaults.set(self.defaultsRevision, forKey: key)
    }

    static func showsPlanUsage(for provider: UsageProvider) -> Bool {
        provider != .codex
    }

    static func showsOptionalCreditsAndExtraUsage(for provider: UsageProvider) -> Bool {
        provider != .codex
    }

    static func showsBuyCredits(for provider: UsageProvider) -> Bool {
        provider != .codex
    }

    static func showsUsageDashboard(for provider: UsageProvider) -> Bool {
        provider != .codex
    }

    static func usesHeadroomPopupPanel(userDefaults: UserDefaults = CodexBarPreferences.processDefaults) -> Bool {
        guard userDefaults.object(forKey: self.headroomPopupPanelDefaultsKey) != nil else { return true }
        return userDefaults.bool(forKey: self.headroomPopupPanelDefaultsKey)
    }
}
