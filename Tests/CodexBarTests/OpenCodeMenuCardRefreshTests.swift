import Foundation
import Testing
@testable import CodexBar

struct OpenCodeMenuCardRefreshTests {
    @Test
    func `OpenCode local usage cards expose a refresh presentation`() {
        #expect(UsageMenuCardView.RefreshPresentation.buttonSize == 22)
        #expect(!UsageMenuCardView.RefreshPresentation.accessibilityLabel.isEmpty)
    }

    @Test
    func `OpenCode refresh action is wired only for the provider card`() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CodexBar", isDirectory: true)
        let menuSource = try String(
            contentsOf: sourceRoot.appendingPathComponent("StatusItemController+Menu.swift"),
            encoding: .utf8)
        let cardSource = try String(
            contentsOf: sourceRoot.appendingPathComponent("MenuCardView.swift"),
            encoding: .utf8)

        #expect(menuSource.contains("guard provider == .opencode else { return nil }"))
        #expect(menuSource.contains("onRefresh: self.menuCardRefreshAction(for: model.provider)"))
        #expect(menuSource.contains("onRefresh: self.menuCardRefreshAction(for: provider)"))
        #expect(cardSource.contains("UsageMenuCardRefreshButton(action: onRefresh)"))
    }
}
