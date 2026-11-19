#if DEBUG
import AppKit
import CodexBarCore
import SnapshotTesting
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
@Suite("M1 pre-panel card snapshots", .serialized)
struct HeadroomDesignGallerySnapshotTests {
    fileprivate static let snapshotSize = CGSize(width: HeadroomDesignGalleryLayout.cardWidth, height: 360)
    fileprivate static let galleryTestName = "gallery cards preserve the pre-panel appearance"
    fileprivate static let resetCreditsTestName = "reset credit fixtures cover available and unavailable states"
    private static let galleryReferencePrefix = "gallery-cards-preserve-the-pre-panel-appearance"
    private static let resetCreditsReferencePrefix = "reset-credit-fixtures-cover-available-and-unavailable-states"

    /// These 17 M1 references stay frozen even when the separate relay-triad recording switch is enabled.
    static var legacyReferenceURLs: [URL] {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("__Snapshots__/HeadroomDesignGallerySnapshotTests", isDirectory: true)
        let gallery = HeadroomDesignGalleryCatalog.entries.map {
            directory.appendingPathComponent("\(Self.galleryReferencePrefix).\($0.id).png")
        }
        let resetCredits = HeadroomDesignGalleryCatalog.resetCreditEntries.map {
            directory.appendingPathComponent("\(Self.resetCreditsReferencePrefix).\($0.id).png")
        }
        return gallery + resetCredits
    }

    static var legacyRecordMode: SnapshotTestingConfiguration.Record {
        // The relay-triad recording switch is intentionally not consulted by this legacy suite.
        .never
    }

    @Test(.enabled(if: TypographySnapshotTests.berkeleyMonoIsInstalled))
    func `gallery cards preserve the pre-panel appearance`() throws {
        try Self.assertGalleryReferences()
    }

    @Test(.enabled(if: TypographySnapshotTests.berkeleyMonoIsInstalled))
    func `reset credit fixtures cover available and unavailable states`() throws {
        try Self.assertResetCreditReferences()
    }

    static func assertFrozenLegacyReferences() throws {
        try self.assertGalleryReferences()
        try self.assertResetCreditReferences()
    }

    private static func assertGalleryReferences() throws {
        try TypographySnapshotTests.registerBerkeleyMono()
        let baseline = try HeadroomDesignGalleryBaseline.load()
        #expect(HeadroomTypography.nsMono(11).fontName == "BerkeleyMono-Regular")

        withSnapshotTesting(record: self.legacyRecordMode) {
            for entry in HeadroomDesignGalleryCatalog.entries {
                let controller = NSHostingController(rootView: SnapshotCard(entry: entry, baseline: baseline))
                controller.view.frame = NSRect(origin: .zero, size: self.snapshotSize)
                controller.view.layoutSubtreeIfNeeded()

                assertSnapshot(
                    of: controller,
                    as: .image(size: self.snapshotSize),
                    named: entry.id,
                    testName: self.galleryTestName)
            }
        }
    }

    private static func assertResetCreditReferences() throws {
        try TypographySnapshotTests.registerBerkeleyMono()
        let baseline = try HeadroomDesignGalleryBaseline.load()
        let entries = HeadroomDesignGalleryCatalog.resetCreditEntries

        #expect(entries.map(\.id) == [
            "officialAccount-resetCredits-available",
            "officialAccount-resetCredits-unavailable",
        ])
        #expect(HeadroomDesignGalleryModels.officialAccountResetCredits(
            state: .available,
            baseline: baseline).resetCredits != nil)
        #expect(HeadroomDesignGalleryModels.officialAccountResetCredits(
            state: .unavailable,
            baseline: baseline).resetCredits == nil)

        withSnapshotTesting(record: self.legacyRecordMode) {
            for entry in entries {
                let controller = NSHostingController(rootView: SnapshotResetCreditsCard(
                    entry: entry,
                    baseline: baseline))
                controller.view.frame = NSRect(origin: .zero, size: self.snapshotSize)
                controller.view.layoutSubtreeIfNeeded()

                assertSnapshot(
                    of: controller,
                    as: .image(size: self.snapshotSize),
                    named: entry.id,
                    testName: self.resetCreditsTestName)
            }
        }
    }

    @Test(.enabled(if: TypographySnapshotTests.berkeleyMonoIsInstalled))
    func `pi agent card has a dedicated visual baseline`() throws {
        try TypographySnapshotTests.registerBerkeleyMono()
        let controller = NSHostingController(rootView: SnapshotPiAgentCard())
        controller.view.frame = NSRect(origin: .zero, size: Self.snapshotSize)
        controller.view.layoutSubtreeIfNeeded()

        assertSnapshot(
            of: controller,
            as: .image(size: Self.snapshotSize),
            named: "piAgent-localUsage")
    }
}

private struct SnapshotPiAgentCard: View {
    var body: some View {
        PiAgentUsageCardView(
            snapshot: Self.snapshot,
            width: HeadroomDesignGalleryLayout.cardWidth)
            .frame(width: HeadroomDesignGalleryLayout.cardWidth, alignment: .top)
            .frame(width: Self.snapshotSize.width, height: Self.snapshotSize.height, alignment: .top)
            .background(ConsoleDesign.background)
            .preferredColorScheme(ConsoleDesign.preferredColorScheme)
    }

    private static let snapshotSize = HeadroomDesignGallerySnapshotTests.snapshotSize

    private static let snapshot = PiAgentUsageCardSnapshot(
        codexReports: [
            .rolling24Hours: report(tokens: 148_240, cost: 1.82),
            .last7Days: report(tokens: 892_640, cost: 10.74),
            .last30Days: report(tokens: 3_458_120, cost: 41.36),
        ],
        claudeReports: [
            .rolling24Hours: report(tokens: 62510, cost: 0.94, model: "claude-sonnet-4-6"),
            .last7Days: report(tokens: 318_750, cost: 4.81, model: "claude-sonnet-4-6"),
            .last30Days: report(tokens: 1_204_880, cost: 18.27, model: "claude-sonnet-4-6"),
        ])

    private static func report(
        tokens: Int,
        cost: Double,
        model: String = "gpt-5.4") -> CostUsageDailyReport
    {
        CostUsageDailyReport(
            data: [
                .init(
                    date: "2026-08-18",
                    inputTokens: tokens,
                    outputTokens: 0,
                    totalTokens: tokens,
                    costUSD: cost,
                    modelsUsed: [model],
                    modelBreakdowns: nil),
            ],
            summary: .init(
                totalInputTokens: tokens,
                totalOutputTokens: 0,
                totalTokens: tokens,
                totalCostUSD: cost))
    }
}

private struct SnapshotResetCreditsCard: View {
    let entry: HeadroomDesignGalleryResetCreditsEntry
    let baseline: HeadroomDesignGalleryBaseline

    var body: some View {
        CodexAccountSummaryCardView(
            model: HeadroomDesignGalleryModels.officialAccountResetCredits(
                state: self.entry.state,
                baseline: self.baseline),
            width: HeadroomDesignGalleryLayout.cardWidth)
            .frame(width: HeadroomDesignGalleryLayout.cardWidth, alignment: .top)
            .frame(width: Self.snapshotSize.width, height: Self.snapshotSize.height, alignment: .top)
            .background(ConsoleDesign.background)
            .preferredColorScheme(ConsoleDesign.preferredColorScheme)
    }

    private static let snapshotSize = HeadroomDesignGallerySnapshotTests.snapshotSize
}

private struct SnapshotCard: View {
    let entry: HeadroomDesignGalleryEntry
    let baseline: HeadroomDesignGalleryBaseline

    var body: some View {
        Group {
            switch self.entry.kind {
            case .provider:
                UsageMenuCardView(
                    model: HeadroomDesignGalleryModels.provider(
                        state: self.entry.state,
                        baseline: self.baseline),
                    width: HeadroomDesignGalleryLayout.cardWidth)
            case .officialAccount:
                CodexAccountSummaryCardView(
                    model: HeadroomDesignGalleryModels.officialAccount(
                        state: self.entry.state,
                        baseline: self.baseline),
                    width: HeadroomDesignGalleryLayout.cardWidth)
            case .relay:
                CodexRelaySummaryCardView(
                    model: HeadroomDesignGalleryModels.relay(
                        state: self.entry.state,
                        baseline: self.baseline),
                    width: HeadroomDesignGalleryLayout.cardWidth)
            }
        }
        .frame(width: HeadroomDesignGalleryLayout.cardWidth, alignment: .top)
        .frame(width: Self.snapshotSize.width, height: Self.snapshotSize.height, alignment: .top)
        .background(ConsoleDesign.background)
        .preferredColorScheme(ConsoleDesign.preferredColorScheme)
    }

    private static let snapshotSize = HeadroomDesignGallerySnapshotTests.snapshotSize
}
#endif
