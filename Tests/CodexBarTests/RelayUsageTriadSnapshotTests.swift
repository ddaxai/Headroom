#if DEBUG
import AppKit
import CodexBarCore
import SnapshotTesting
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
@Suite("M4 relay usage triad snapshots", .serialized)
struct RelayUsageTriadSnapshotTests {
    private static let wideWidth: CGFloat = 300
    private static let narrowWidth: CGFloat = 220
    private static let snapshotHeight: CGFloat = 240

    @Test
    func `relay triad renders wide and narrow cards in both languages`() throws {
        try TypographySnapshotTests.registerBerkeleyMono()

        let recordMode: SnapshotTestingConfiguration.Record? =
            ProcessInfo.processInfo.environment["CODEXBAR_RECORD_RELAY_TRIAD_SNAPSHOTS"] == "1"
                ? .all
                : .never
        try withSnapshotTesting(record: recordMode) {
            for (language, languageID) in [("en", "en"), ("zh-Hans", "zh-Hans")] {
                for (width, widthID) in [
                    (Self.wideWidth, "wide"),
                    (Self.narrowWidth, "narrow"),
                ] {
                    try CodexBarLocalizationOverride.$appLanguage.withValue(language) {
                        let presentation = RelayUsageTriadPresentation.resolve(
                            localSnapshot: Self.snapshot,
                            providerSummary: Self.summary,
                            apiFormat: .openAIResponses,
                            preferredCurrencyCode: "USD")
                        let model = CodexRelaySummaryCardModel(
                            name: "Fixture Relay",
                            isActive: true,
                            isReady: true,
                            blocker: nil,
                            usageLine: "24h 0.75M",
                            usageSummary: Self.summary,
                            usageTriad: presentation,
                            apiFormat: .openAIResponses)
                        let size = CGSize(width: width, height: Self.snapshotHeight)
                        let controller = NSHostingController(
                            rootView: SnapshotRelayTriadCard(model: model, width: width, size: size))
                        controller.view.frame = NSRect(origin: .zero, size: size)
                        controller.view.layoutSubtreeIfNeeded()

                        assertSnapshot(
                            of: controller,
                            as: .image(size: size),
                            named: "relay-triad-\(widthID)-\(languageID)")
                    }
                }
            }
        }
    }

    private static let snapshot = CostUsageTokenSnapshot(
        sessionTokens: 750_000,
        sessionCostUSD: 4.25,
        last30DaysTokens: 2_500_000,
        last30DaysCostUSD: 14.25,
        rolling24Hours: .init(totalTokens: 500_000, costUSD: 4.25),
        daily: [],
        updatedAt: Date(timeIntervalSince1970: 1_800_000_000))

    private static let summary = RelayUsageSummary(
        remaining: 12.5,
        used: 87.5,
        total: 100,
        unit: "USD",
        planName: "Fixture",
        updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        recentUsage: .init(period: .rolling24Hours, totalTokens: 750_000, actualCostUSD: 4.25))
}

private struct SnapshotRelayTriadCard: View {
    let model: CodexRelaySummaryCardModel
    let width: CGFloat
    let size: CGSize

    var body: some View {
        CodexRelaySummaryCardView(model: self.model, width: self.width)
            .frame(width: self.width, alignment: .top)
            .frame(width: self.size.width, height: self.size.height, alignment: .top)
            .background(ConsoleDesign.background)
            .preferredColorScheme(ConsoleDesign.preferredColorScheme)
    }
}
#endif
