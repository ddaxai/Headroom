import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct RelayUsageTriadPresentationTests {
    @Test
    func `triad keeps local reported and balance as independent sources`() {
        let presentation = RelayUsageTriadPresentation.resolve(
            localSnapshot: Self.snapshot(tokens: 500),
            providerSummary: Self.summary(
                remaining: 12.5,
                reportedTokens: 750,
                chargedUSD: 4.25),
            apiFormat: .openAIResponses,
            preferredCurrencyCode: "USD")

        #expect(presentation.localBaseTokens == 500)
        #expect(presentation.providerReportedTokens == 750)
        #expect(presentation.balance == 12.5)
        #expect(presentation.actualChargedUSD == 4.25)
        #expect(presentation.effectiveMultiplier == 1.5)
        #expect(presentation.metrics.map(\.id) == [
            .localBaseTokens,
            .providerReportedTokens,
            .balance,
        ])
        #expect(presentation.metrics[0].valueText == "0.00M")
        #expect(presentation.metrics[0].detailKey == "relay_usage_triad_local_estimate")
    }

    @Test
    func `cache reported tokens do not masquerade as an effective multiplier`() {
        let presentation = RelayUsageTriadPresentation.resolve(
            localSnapshot: Self.snapshot(tokens: 500),
            providerSummary: Self.summary(
                remaining: 12.5,
                reportedTokens: 750,
                chargedUSD: 4.25,
                cacheReadTokens: 250),
            apiFormat: .openAIResponses,
            preferredCurrencyCode: "USD")

        #expect(presentation.providerReportedTokens == 750)
        #expect(presentation.effectiveMultiplier == nil)
        #expect(presentation.hasReportedCacheTokens)
        #expect(presentation.cacheAccountingTooltip == L("relay_usage_triad_cache_accounting_note"))
        #expect(presentation.metrics[1].tooltipText == presentation.cacheAccountingTooltip)
    }

    @Test
    func `missing source stays missing instead of borrowing another number or zero`() {
        let presentation = RelayUsageTriadPresentation.resolve(
            localSnapshot: nil,
            providerSummary: Self.summary(
                remaining: 8,
                reportedTokens: nil,
                chargedUSD: nil),
            apiFormat: .openAIResponses,
            preferredCurrencyCode: "USD")

        #expect(presentation.localBaseTokens == nil)
        #expect(presentation.providerReportedTokens == nil)
        #expect(presentation.balance == 8)
        #expect(presentation.metrics[0].valueText == nil)
        #expect(presentation.metrics[0].detailKey == "relay_usage_triad_no_data")
        #expect(presentation.metrics[1].valueText == nil)
        #expect(presentation.metrics[1].valueText != "0")
    }

    @Test
    func `unsupported protocol suppresses local value but preserves reported and balance`() {
        let presentation = RelayUsageTriadPresentation.resolve(
            localSnapshot: Self.snapshot(tokens: 500),
            providerSummary: Self.summary(
                remaining: 9,
                reportedTokens: 900,
                chargedUSD: 3),
            apiFormat: .anthropicMessages,
            preferredCurrencyCode: "USD",
            localMeterStatus: .unsupported)

        #expect(presentation.localMeterStatus == .unsupported)
        #expect(presentation.localBaseTokens == nil)
        #expect(presentation.metrics[0].valueText == nil)
        #expect(presentation.metrics[0].detailKey == "local_meter_protocol_unsupported")
        #expect(presentation.providerReportedTokens == 900)
        #expect(presentation.balance == 9)
        #expect(presentation.effectiveMultiplier == nil)
    }

    @Test
    func `Chat Completions reuses the three independent triad lanes`() {
        let presentation = RelayUsageTriadPresentation.resolve(
            localSnapshot: Self.snapshot(tokens: 500),
            providerSummary: Self.summary(
                remaining: 9,
                reportedTokens: 900,
                chargedUSD: 3),
            apiFormat: .openAIChatCompletions,
            preferredCurrencyCode: "USD")

        #expect(presentation.localMeterStatus == .supported)
        #expect(presentation.localBaseTokens == 500)
        #expect(presentation.providerReportedTokens == 900)
        #expect(presentation.balance == 9)
        #expect(presentation.metrics.map(\.id) == [
            .localBaseTokens,
            .providerReportedTokens,
            .balance,
        ])
        #expect(presentation.metrics[0].detailKey == "relay_usage_triad_local_estimate")
    }

    @Test
    func `Chat Completions missing reported usage stays unavailable instead of zero`() {
        let presentation = RelayUsageTriadPresentation.resolve(
            localSnapshot: Self.snapshot(tokens: 500),
            providerSummary: Self.summary(
                remaining: 9,
                reportedTokens: nil,
                chargedUSD: nil),
            apiFormat: .openAIChatCompletions,
            preferredCurrencyCode: "USD")

        #expect(presentation.localBaseTokens == 500)
        #expect(presentation.providerReportedTokens == nil)
        #expect(presentation.metrics[1].valueText == nil)
        #expect(presentation.metrics[1].valueText != "0")
        #expect(presentation.metrics[1].detailKey == "relay_usage_triad_no_data")
    }

    @Test
    func `Anthropic Messages reuses triad without borrowing missing reported usage`() {
        let presentation = RelayUsageTriadPresentation.resolve(
            localSnapshot: Self.snapshot(tokens: 640),
            providerSummary: Self.summary(
                remaining: 9,
                reportedTokens: nil,
                chargedUSD: nil),
            apiFormat: .anthropicMessages,
            preferredCurrencyCode: "USD")

        #expect(presentation.localMeterStatus == .supported)
        #expect(presentation.localBaseTokens == 640)
        #expect(presentation.providerReportedTokens == nil)
        #expect(presentation.metrics[0].detailKey == "relay_usage_triad_local_estimate")
        #expect(presentation.metrics[1].valueText == nil)
        #expect(presentation.metrics[1].valueText != "0")
        #expect(presentation.metrics[1].detailKey == "relay_usage_triad_no_data")
        #expect(presentation.balance == 9)
    }

    @Test
    func `explicit reported zero is retained while absent reported usage stays unavailable`() {
        let zero = RelayUsageTriadPresentation.resolve(
            localSnapshot: Self.snapshot(tokens: 100),
            providerSummary: Self.summary(remaining: nil, reportedTokens: 0, chargedUSD: 0),
            apiFormat: .openAIResponses,
            preferredCurrencyCode: "USD")
        let absent = RelayUsageTriadPresentation.resolve(
            localSnapshot: Self.snapshot(tokens: 100),
            providerSummary: Self.summary(remaining: nil, reportedTokens: nil, chargedUSD: nil),
            apiFormat: .openAIResponses,
            preferredCurrencyCode: "USD")

        #expect(zero.providerReportedTokens == 0)
        #expect(zero.metrics[1].valueText == "0")
        #expect(absent.providerReportedTokens == nil)
        #expect(absent.metrics[1].valueText == nil)
        #expect(absent.effectiveMultiplier == nil)
    }

    @Test
    func `balance lane preserves non currency units`() {
        let presentation = RelayUsageTriadPresentation.resolve(
            localSnapshot: nil,
            providerSummary: Self.summary(
                remaining: 12.5,
                reportedTokens: nil,
                chargedUSD: nil,
                unit: "credits"),
            apiFormat: .openAIResponses,
            preferredCurrencyCode: "USD")

        #expect(presentation.metrics[2].valueText?.contains("credits") == true)
    }

    @Test
    func `height fingerprint changes when localization changes`() {
        let presentation = RelayUsageTriadPresentation.resolve(
            localSnapshot: Self.snapshot(tokens: 500),
            providerSummary: Self.summary(
                remaining: 12.5,
                reportedTokens: 750,
                chargedUSD: 4.25),
            apiFormat: .openAIResponses,
            preferredCurrencyCode: "USD")
        let english = CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            presentation.heightFingerprint
        }
        let chinese = CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hans") {
            presentation.heightFingerprint
        }

        #expect(english != chinese)
    }

    @Test
    func `triad geometry uses columns when wide and rows when narrow`() {
        #expect(RelayUsageTriadLayout.mode(forCardWidth: 300) == .columns)
        #expect(RelayUsageTriadLayout.mode(forCardWidth: 220) == .rows)
        #expect(RelayUsageTriadLayout.minimumColumnWidth >= 68)
        #expect(RelayUsageTriadLayout.contentWidth(forCardWidth: 300) > 0)
        #expect(RelayUsageTriadLayout.columnsFit(cardWidth: 300, metricCount: 3))
        #expect(!RelayUsageTriadLayout.columnsFit(cardWidth: 220, metricCount: 3))
    }

    @Test
    func `wide to narrow transition keeps three lanes while changing orientation`() {
        let presentation = RelayUsageTriadPresentation.resolve(
            localSnapshot: Self.snapshot(tokens: 500),
            providerSummary: Self.summary(remaining: 12.5, reportedTokens: 750, chargedUSD: 4.25),
            apiFormat: .openAIResponses,
            preferredCurrencyCode: "USD")

        #expect(RelayUsageTriadLayout.mode(forCardWidth: 300) == .columns)
        #expect(RelayUsageTriadLayout.mode(forCardWidth: 220) == .rows)
        #expect(RelayUsageTriadLayout.metricHeights(for: presentation, cardWidth: 300).count == 3)
        #expect(RelayUsageTriadLayout.metricHeights(for: presentation, cardWidth: 220).count == 3)
        #expect(
            RelayUsageTriadLayout.contentHeight(for: presentation, cardWidth: 220)
                > RelayUsageTriadLayout.contentHeight(for: presentation, cardWidth: 300))
    }

    @Test
    func `missing lane keeps the same narrow row height`() {
        let complete = RelayUsageTriadPresentation.resolve(
            localSnapshot: Self.snapshot(tokens: 500),
            providerSummary: Self.summary(remaining: 12.5, reportedTokens: 750, chargedUSD: 4.25),
            apiFormat: .openAIResponses,
            preferredCurrencyCode: "USD")
        let missingLocal = RelayUsageTriadPresentation.resolve(
            localSnapshot: nil,
            providerSummary: Self.summary(remaining: 12.5, reportedTokens: 750, chargedUSD: 4.25),
            apiFormat: .openAIResponses,
            preferredCurrencyCode: "USD")
        let missingProvider = RelayUsageTriadPresentation.resolve(
            localSnapshot: Self.snapshot(tokens: 500),
            providerSummary: Self.summary(remaining: 12.5, reportedTokens: nil, chargedUSD: nil),
            apiFormat: .openAIResponses,
            preferredCurrencyCode: "USD")
        let missingBalance = RelayUsageTriadPresentation.resolve(
            localSnapshot: Self.snapshot(tokens: 500),
            providerSummary: Self.summary(remaining: nil, reportedTokens: 750, chargedUSD: 4.25),
            apiFormat: .openAIResponses,
            preferredCurrencyCode: "USD")

        let completeHeights = RelayUsageTriadLayout.metricHeights(for: complete, cardWidth: 220)
        for missing in [missingLocal, missingProvider, missingBalance] {
            let missingHeights = RelayUsageTriadLayout.metricHeights(for: missing, cardWidth: 220)
            #expect(completeHeights == missingHeights)
            #expect(Set(missingHeights).count == 1)
        }
    }

    @Test
    func `multiplier appearance changes measured height and fingerprint`() {
        let withMultiplier = RelayUsageTriadPresentation.resolve(
            localSnapshot: Self.snapshot(tokens: 500),
            providerSummary: Self.summary(remaining: 12.5, reportedTokens: 750, chargedUSD: 4.25),
            apiFormat: .openAIResponses,
            preferredCurrencyCode: "USD")
        let withoutMultiplier = RelayUsageTriadPresentation.resolve(
            localSnapshot: Self.snapshot(tokens: 500),
            providerSummary: Self.summary(remaining: 12.5, reportedTokens: 500, chargedUSD: 4.25),
            apiFormat: .openAIResponses,
            preferredCurrencyCode: "USD")

        #expect(withMultiplier.effectiveMultiplier != nil)
        #expect(withoutMultiplier.effectiveMultiplier == nil)
        #expect(
            RelayUsageTriadLayout.contentHeight(for: withMultiplier, cardWidth: 220)
                > RelayUsageTriadLayout.contentHeight(for: withoutMultiplier, cardWidth: 220))
        #expect(withMultiplier.heightFingerprint != withoutMultiplier.heightFingerprint)
    }

    @Test
    func `height fingerprint changes when usage data changes`() {
        let lower = RelayUsageTriadPresentation.resolve(
            localSnapshot: Self.snapshot(tokens: 500),
            providerSummary: Self.summary(remaining: 12.5, reportedTokens: 500, chargedUSD: 4.25),
            apiFormat: .openAIResponses,
            preferredCurrencyCode: "USD")
        let higher = RelayUsageTriadPresentation.resolve(
            localSnapshot: Self.snapshot(tokens: 900),
            providerSummary: Self.summary(remaining: 12.5, reportedTokens: 900, chargedUSD: 4.25),
            apiFormat: .openAIResponses,
            preferredCurrencyCode: "USD")

        let lowerEnglish = CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            lower.heightFingerprint
        }
        let higherEnglish = CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            higher.heightFingerprint
        }
        let lowerChinese = CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hans") {
            lower.heightFingerprint
        }

        #expect(lowerEnglish != higherEnglish)
        #expect(lowerEnglish != lowerChinese)
    }

    private static func snapshot(tokens: Int) -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: tokens,
            sessionCostUSD: nil,
            last30DaysTokens: tokens,
            last30DaysCostUSD: nil,
            rolling24Hours: .init(totalTokens: tokens, costUSD: nil),
            daily: [],
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    private static func summary(
        remaining: Double?,
        reportedTokens: Int?,
        chargedUSD: Double?,
        unit: String = "USD",
        cacheReadTokens: Int? = nil,
        cacheCreationTokens: Int? = nil) -> RelayUsageSummary
    {
        RelayUsageSummary(
            remaining: remaining,
            used: nil,
            total: nil,
            unit: unit,
            planName: "Fixture",
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            recentUsage: reportedTokens.map {
                RelayRecentUsageSummary(
                    period: .rolling24Hours,
                    totalTokens: $0,
                    actualCostUSD: chargedUSD ?? 0,
                    cacheReadTokens: cacheReadTokens,
                    cacheCreationTokens: cacheCreationTokens)
            })
    }
}
