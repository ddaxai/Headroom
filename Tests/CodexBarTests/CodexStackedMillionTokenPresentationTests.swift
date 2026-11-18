import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct CodexStackedMillionTokenPresentationTests {
    @Test
    func `official stacked summary keeps fixed two decimal million token units`() {
        for (tokens, expected) in [
            (123_456, "0.12M"),
            (999_999, "1.00M"),
            (10_600_000_000, "10600.00M"),
        ] {
            let line = CodexStackedUsageSummary.line(
                CostUsageRolling24HourSummary(totalTokens: tokens, costUSD: 1.25),
                preferredCurrencyCode: "USD",
                emptyText: "empty")

            #expect(line == "24h: \(expected) tokens · $1.25")
        }
    }

    @Test
    func `relay stacked summary keeps fixed two decimal million token units`() {
        for (tokens, expected) in [
            (123_456, "0.12M"),
            (999_999, "1.00M"),
            (10_600_000_000, "10600.00M"),
        ] {
            let summary = RelayUsageSummary(
                remaining: 8,
                used: 2,
                total: 10,
                unit: "USD",
                planName: nil,
                updatedAt: Date(timeIntervalSince1970: 1_785_888_000),
                recentUsage: RelayRecentUsageSummary(
                    period: .rolling24Hours,
                    totalTokens: tokens,
                    actualCostUSD: 1.25))

            #expect(RelayUsagePresentation.recentUsageLine(summary) == "24h: \(expected) tokens · $1.25")
        }
    }

    @Test
    func `full corpus is authoritative while fallback still sums assigned and unassigned`() {
        let assigned = Self.snapshot(tokens: 120, cost: 1.20)
        let unassigned = Self.snapshot(tokens: 30, cost: 0.30)
        let fullCorpus = Self.snapshot(tokens: 200, cost: 2.00)

        let authoritative = CodexStackedUsageSummary.menuTotal(
            accountSnapshots: [assigned],
            expectedAccountCount: 1,
            sharedSnapshot: unassigned,
            fullCorpusSnapshot: fullCorpus)
        let fallback = CodexStackedUsageSummary.menuTotal(
            accountSnapshots: [assigned],
            expectedAccountCount: 1,
            sharedSnapshot: unassigned)

        #expect(authoritative?.totalTokens == 200)
        #expect(authoritative?.costUSD == 2.00)
        #expect(fallback?.totalTokens == 150)
        #expect(fallback?.costUSD == 1.50)
    }

    @Test
    func `historical full corpus renders a zero rolling total instead of the empty state`() {
        let historical = CostUsageTokenSnapshot(
            sessionTokens: 0,
            sessionCostUSD: 0,
            last30DaysTokens: 250,
            last30DaysCostUSD: 1.25,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2026-07-01",
                    inputTokens: 250,
                    outputTokens: 0,
                    totalTokens: 250,
                    costUSD: 1.25,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            updatedAt: Date(timeIntervalSince1970: 1_784_179_200))

        let total = CodexStackedUsageSummary.menuTotal(
            accountSnapshots: [],
            expectedAccountCount: 1,
            sharedSnapshot: nil,
            fullCorpusSnapshot: historical)
        let line = CodexStackedUsageSummary.line(
            total,
            preferredCurrencyCode: "USD",
            emptyText: "empty")

        #expect(total?.totalTokens == 0)
        #expect(line == "24h: 0 tokens · —")
    }

    @Test
    func `unassigned total is derived by subtraction without proportional allocation`() {
        let assigned = Self.snapshot(tokens: 120, cost: 1.20)
        let fullCorpus = Self.snapshot(tokens: 200, cost: 2.00)

        let unassigned = CodexStackedUsageSummary.unassignedTotal(
            accountSnapshots: [assigned],
            relaySnapshot: nil,
            sharedSnapshot: nil,
            fullCorpusSnapshot: fullCorpus)

        #expect(unassigned?.totalTokens == 80)
        #expect(unassigned?.costUSD == 0.80)
    }

    @Test
    func `height fingerprints track total secondary line and official empty state independently`() {
        let noSecondary = MenuCardHeightFingerprint.codexStackedTotal(
            totalLine: "24h total",
            unassignedLine: nil)
        let withSecondary = MenuCardHeightFingerprint.codexStackedTotal(
            totalLine: "24h total",
            unassignedLine: "其中 未归属 0.08M tokens")
        let ordinaryAccount = MenuCardHeightFingerprint.codexAccountCard(
            baseFingerprint: "account",
            usageLine: nil)
        let emptyAccount = MenuCardHeightFingerprint.codexAccountCard(
            baseFingerprint: "account",
            usageLine: nil,
            usageEmptyText: "Usage exists under System / Unassigned")

        #expect(noSecondary != withSecondary)
        #expect(ordinaryAccount != emptyAccount)
    }

    @Test
    func `eighth round attribution strings cover every shipped localization`() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let resources = root.appendingPathComponent("Sources/CodexBar/Resources", isDirectory: true)
        let localizations = try FileManager.default.contentsOfDirectory(
            at: resources,
            includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "lproj" }
        let requiredKeys = [
            "codex_account_usage_unassigned_explanation",
            "codex_account_usage_view_unassigned",
            "codex_usage_total_unassigned_prefix",
            "spend_manual_attribution_title",
            "spend_manual_attribution_marker",
            "spend_manual_attribution_help",
            "spend_manual_attribution_scope",
            "spend_manual_attribution_entire_bucket",
            "spend_manual_attribution_date_range",
            "spend_manual_attribution_start",
            "spend_manual_attribution_end_exclusive",
            "spend_manual_attribution_target",
            "spend_manual_attribution_assign",
            "spend_manual_attribution_remove",
            "spend_manual_attribution_entire_description",
            "spend_manual_attribution_range_description",
        ]

        #expect(localizations.count == 2)
        for localization in localizations {
            let catalog = try #require(NSDictionary(
                contentsOf: localization.appendingPathComponent("Localizable.strings")) as? [String: String])
            for key in requiredKeys {
                #expect(catalog[key]?.isEmpty == false, "Missing \(key) in \(localization.lastPathComponent)")
            }
            let wholeFormat = try #require(catalog["spend_manual_attribution_entire_description"])
            let rangeFormat = try #require(catalog["spend_manual_attribution_range_description"])
            #expect(wholeFormat.components(separatedBy: "%@").count - 1 == 1)
            #expect(rangeFormat.components(separatedBy: "%@").count - 1 == 3)
        }
    }

    private static func snapshot(tokens: Int, cost: Double) -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: tokens,
            sessionCostUSD: cost,
            last30DaysTokens: tokens,
            last30DaysCostUSD: cost,
            rolling24Hours: CostUsageRolling24HourSummary(totalTokens: tokens, costUSD: cost),
            daily: [],
            updatedAt: Date())
    }
}
