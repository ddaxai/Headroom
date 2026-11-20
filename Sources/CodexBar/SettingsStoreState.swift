import Foundation

enum SettingsWindowLayout {
    static let relayListWidthKey = "settings.relayListWidth"
    static let windowAlwaysOnTopKey = "settings.windowAlwaysOnTop"

    static let relayListWidthRange: ClosedRange<CGFloat> = 150...300
    static let relayListIdealWidth: CGFloat = 190

    static func clampedRelayListWidth(_ value: CGFloat) -> CGFloat {
        self.clamp(value, fallback: self.relayListIdealWidth, to: self.relayListWidthRange)
    }

    static func loadWidth(
        from defaults: UserDefaults,
        key: String,
        ideal: CGFloat,
        range: ClosedRange<CGFloat>) -> CGFloat
    {
        let stored = (defaults.object(forKey: key) as? NSNumber).map { CGFloat($0.doubleValue) }
        let value = self.clamp(stored ?? ideal, fallback: ideal, to: range)
        if stored != value {
            defaults.set(Double(value), forKey: key)
        }
        return value
    }

    private static func clamp(
        _ value: CGFloat,
        fallback: CGFloat,
        to range: ClosedRange<CGFloat>) -> CGFloat
    {
        guard value.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }
}

struct SettingsDefaultsState {
    var refreshFrequency: RefreshFrequency
    var localUsageRefreshMode: LocalUsageRefreshMode
    var localMeterEnabled: Bool
    var adaptiveActivityScanConsent: AdaptiveActivityScanConsent
    var refreshAllProvidersOnMenuOpen: Bool
    var launchAtLogin: Bool
    var debugMenuEnabled: Bool
    var debugDisableKeychainAccess: Bool
    var browserCookieImportEnabled: Bool
    var debugFileLoggingEnabled: Bool
    var debugLogLevelRaw: String?
    var debugLoadingPatternRaw: String?
    var debugKeepCLISessionsAlive: Bool
    var statusChecksEnabled: Bool
    var sessionQuotaNotificationsEnabled: Bool
    var quotaWarningNotificationsEnabled: Bool
    var predictivePaceWarningNotificationsEnabled: Bool
    var quotaWarningThresholdsRaw: [Int]
    var quotaWarningSessionThresholdsRaw: [Int]
    var quotaWarningWeeklyThresholdsRaw: [Int]
    var quotaWarningSessionEnabled: Bool
    var quotaWarningWeeklyEnabled: Bool
    var quotaWarningSoundEnabled: Bool
    var quotaWarningOnScreenAlertEnabled: Bool
    var quotaWarningMarkersVisible: Bool
    var weeklyProgressWorkDays: Int?
    var usageBarsShowUsed: Bool
    var resetTimesShowAbsolute: Bool
    var consolePaletteRaw: String?
    var providerChangelogLinksEnabled: Bool
    var menuBarShowsBrandIconWithPercent: Bool
    var menuBarHidesCritters: Bool
    var menuBarHighContrastOnInactiveDisplays: Bool
    var menuBarDisplayModeRaw: String?
    var menuBarShowsResetTimeWhenExhausted: Bool
    var kiroMenuBarDisplayModeRaw: String?
    var historicalTrackingEnabled: Bool
    var multiAccountMenuLayoutRaw: String
    var menuBarMetricPreferencesRaw: [String: String]
    var storedMenuBarLayout: MenuBarLayout?
    var menuBarLayoutOverridesRaw: [String: MenuBarLayout]
    var menuBarLayoutSizeRaw: String
    var menuBarLayoutGapRaw: String
    var copilotBudgetExtrasEnabled: Bool
    var copilotIconSecondaryWindowIDRaw: String
    var costUsageEnabled: Bool
    var codexLocalSessionCostLedgerEnabled: Bool
    var costUsageHistoryDays: Int
    var costComparisonPeriodsEnabled: Bool
    var costSummaryDisplayStyleRaw: String
    var hidePersonalInfo: Bool
    var randomBlinkEnabled: Bool
    var confettiOnSessionLimitResetsEnabled: Bool
    var confettiOnWeeklyLimitResetsEnabled: Bool
    var menuBarShowsHighestUsage: Bool
    var claudeOAuthKeychainPromptModeRaw: String?
    var claudeOAuthKeychainReadStrategyRaw: String?
    var claudeWebExtrasEnabledRaw: Bool
    var showOptionalCreditsAndExtraUsage: Bool
    var claudeDailyRoutinesUsageVisible: Bool
    var codexSparkUsageVisible: Bool
    var openAIWebAccessEnabled: Bool
    var openAIWebBatterySaverEnabled: Bool
    var providerStorageFootprintsEnabled: Bool
    var jetbrainsIDEBasePath: String
    var mergeIcons: Bool
    var switcherShowsIcons: Bool
    var mergedMenuLastSelectedWasOverview: Bool
    var mergedMenuLastSelectedWasPiAgent: Bool
    var mergedOverviewSelectedProvidersRaw: [String]
    var selectedMenuProviderRaw: String?
    var providerDetectionCompleted: Bool
    var providersSortedAlphabetically: Bool
    var appLanguageRaw: String?
    var terminalAppRaw: String?
    var agentSessionsEnabled: Bool
    var piAgentUsageEnabled: Bool
    var agentSessionLabelStyleRaw: String
    var agentSessionsManualHosts: String
    var preferredCurrencyCode: String
    var relayListWidth: CGFloat
    var windowAlwaysOnTop: Bool
}
