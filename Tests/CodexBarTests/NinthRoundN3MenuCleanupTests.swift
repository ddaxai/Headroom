import Foundation
import Testing
@testable import CodexBar

struct NinthRoundN3MenuCleanupTests {
    @Test
    @MainActor
    func `detail rail reserves geometry without visible adornments or reveal state`() throws {
        #expect(CardDetailRail.width == 30)
        #expect(CardDetailRail.borderWidth == 1)
        #expect(CardDetailRail.renderingFingerprint == "detailRail=plain-v1")

        let source = try Self.source(named: "CardDetailRail.swift")
        #expect(!source.contains("showsCaption"))
        #expect(!source.contains("Text("))
        #expect(!source.contains("Image("))
        #expect(!source.contains("CardDetailRailPresentation"))
        #expect(!source.contains(".animation("))
        #expect(!source.contains(".focusable("))
        #expect(source.contains(".accessibilityLabel(L(\"usage.rail.caption\"))"))
    }

    @Test
    func `codex menus omit standalone system unassigned cards and total disclosure`() throws {
        let source = try Self.source(named: "StatusItemController+CodexStackedMenu.swift")

        #expect(!source.contains("menuCard-system-unassigned"))
        #expect(!source.contains("codexSystemUnassignedGroupHeader"))
        #expect(!source.contains("addCodexSystemUnassignedCard"))
        #expect(source.contains("let unassignedSnapshot"))
        #expect(source.contains("secondaryValue: nil"))
        #expect(!source.contains("secondaryValue: unassignedLine"))
        #expect(source.contains("MenuCardHeightFingerprint.codexStackedTotal"))
        #expect(source.components(separatedBy: "submenu: self.makeCodexUsageDetailsSubmenu").count - 1 == 2)
        #expect(source.contains("submenu: hourlySubmenu"))

        let presentation = CodexStackedMenuPresentation(hasRelay: true)
        #expect(presentation.supplementaryItemIDs == [
            "codexCardGroupStatus",
            "codexRelaySummary",
            "codexStackedTotal",
        ])
    }

    private static func source(named name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("Sources/CodexBar/\(name)"),
            encoding: .utf8)
    }
}
