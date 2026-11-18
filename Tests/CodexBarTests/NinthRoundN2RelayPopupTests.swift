import AppKit
import Foundation
import Testing
@testable import CodexBar

struct NinthRoundN2RelayPopupTests {
    @Test
    @MainActor
    func `relay profile popup publishes selection only after tracking returns`() {
        let first = Self.option(name: "First")
        let second = Self.option(name: "Second")
        let third = Self.option(name: "Third")
        let options = [first, second, third]
        var events: [String] = []

        let coordinator = RelayUsageCardProfilePopupCoordinator { menu, positioningItem, _, _ in
            events.append("tracking")
            #expect(menu.items.map(\.title) == options.map(\.name))
            #expect(menu.items.map(\.state) == [.off, .on, .off])
            #expect(positioningItem?.representedObject as? UUID == second.id)

            let selectedItem = menu.items.last
            (selectedItem?.target as? RelayUsageCardProfilePopupCoordinator)?.captureSelection(selectedItem)
            #expect(events == ["tracking"])
            events.append("tracking-returned")
            return true
        }
        coordinator.update(
            options: options,
            selectedProfileID: second.id,
            onSelectProfile: { events.append("selected:\($0.uuidString)") })

        coordinator.present(relativeTo: NSView(frame: NSRect(x: 0, y: 0, width: 104, height: 24)))

        #expect(events == ["tracking", "tracking-returned", "selected:\(third.id.uuidString)"])
    }

    @Test
    @MainActor
    func `relay profile popup cancellation keeps display selection unchanged`() {
        let first = Self.option(name: "First")
        let second = Self.option(name: "Second")
        var selectedIDs: [UUID] = []
        let coordinator = RelayUsageCardProfilePopupCoordinator { menu, _, _, _ in
            #expect(menu.items.count == 2)
            return false
        }
        coordinator.update(
            options: [first, second],
            selectedProfileID: first.id,
            onSelectProfile: { selectedIDs.append($0) })

        coordinator.present(relativeTo: NSView(frame: .zero))

        #expect(selectedIDs.isEmpty)
    }

    @Test
    @MainActor
    func `native relay popup control owns the menu tracking click`() throws {
        let first = Self.option(name: "First")
        let second = Self.option(name: "Second")
        var popupCount = 0
        let coordinator = RelayUsageCardProfilePopupCoordinator { _, _, _, _ in
            popupCount += 1
            return false
        }
        coordinator.update(
            options: [first, second],
            selectedProfileID: first.id,
            onSelectProfile: { _ in })
        let control = RelayUsageCardProfilePopupControl(
            frame: NSRect(x: 0, y: 0, width: RelayUsageCardSelectorPresentation.labelWidth, height: 24))
        control.configure(
            coordinator: coordinator,
            title: first.name,
            dotColor: .systemBlue)

        #expect(control.hitTest(NSPoint(x: 20, y: 12)) === control)
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 20, y: 12),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1))
        control.mouseDown(with: event)

        #expect(popupCount == 1)
    }

    @Test
    func `relay card uses one chevron and the AppKit popup bridge`() throws {
        let source = try String(contentsOf: Self.sourceRoot().appendingPathComponent(
            "CodexRelaySummaryCardView.swift"), encoding: .utf8)
        let stackedMenuSource = try String(contentsOf: Self.sourceRoot().appendingPathComponent(
            "StatusItemController+CodexStackedMenu.swift"), encoding: .utf8)

        #expect(!source.contains("Menu {"))
        #expect(source.contains("RelayUsageCardProfilePopupView("))
        #expect(source.contains("final class RelayUsageCardProfilePopupControl: NSControl"))
        #expect(source.contains(".accessibilityElement(children: .contain)"))
        #expect(source.contains("options: self.model.profileOptions"))
        #expect(source.contains("menu.popUp(positioning:"))
        #expect(source.components(separatedBy: "NSImage(systemSymbolName: \"chevron.down\"").count - 1 == 1)
        #expect(stackedMenuSource.contains("containsInteractiveControls: true"))
    }

    @Test
    func `single relay candidate still hides the display selector`() {
        let only = Self.option(name: "Only")
        let selection = RelayUsageCardProfileSelection(options: [only], activeProfileID: only.id)

        #expect(!selection.showsSelector)
        #expect(selection.selectedProfileID == only.id)
    }

    private static func option(name: String) -> RelayQuickSwitchOption {
        RelayQuickSwitchOption(id: UUID(), name: name, isReady: true, blocker: nil)
    }

    private static func sourceRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CodexBar", isDirectory: true)
    }
}
