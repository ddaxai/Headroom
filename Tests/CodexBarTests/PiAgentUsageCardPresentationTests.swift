import Foundation
import Testing
@testable import CodexBar

struct PiAgentUsageCardPresentationTests {
    @Test
    func `Pi usage cards expose a refresh control`() {
        #expect(PiAgentUsageCardPresentation.refreshButtonSize == 22)
        #expect(!PiAgentUsageCardPresentation.refreshAccessibilityLabel.isEmpty)
    }

    @Test
    func `Pi profiles render as compact cards with expandable usage detail`() throws {
        #expect(PiAgentUsageCardPresentation.profileCardHeight > 40)

        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CodexBar", isDirectory: true)
        let source = try String(
            contentsOf: sourceRoot.appendingPathComponent("StatusItemController+PiAgentMenu.swift"),
            encoding: .utf8)
        #expect(source.contains("snapshot.sections.enumerated()"))
        #expect(source.contains("PiAgentProfileCardView"))
        #expect(source.contains("makeCodexUsageDetailsSubmenu"))
        #expect(source.contains("usesCardDetailRail: true"))
        #expect(source.contains("submenu:"))
    }

    @Test
    func `Pi automatic cadence follows the shared refresh setting`() {
        #expect(PiAgentUsageRefreshCadence.interval(for: .oneMinute) == 60)
        #expect(PiAgentUsageRefreshCadence.interval(for: .fiveMinutes) == 300)
        #expect(PiAgentUsageRefreshCadence.interval(for: .thirtyMinutes) == 1800)
        #expect(PiAgentUsageRefreshCadence.interval(for: .manual) == nil)
    }
}
