import AppKit
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct HeadroomPopupHoverLifecycleTests {
    @Test
    func `local pointer input opens a real Codex account card submenu`() async throws {
        let submenu = LifecycleRecordingPopupMenu()
        let (menu, highlightState) = try Self.makeCodexAccountMenu(submenu: submenu)
        let panel = HeadroomPopupPanel(menu: menu)
        defer { panel.close() }
        panel._test_disablePointerMonitoring()
        panel.animationBehavior = .none
        panel.transition(to: .popup)
        panel.orderFront(nil)
        panel.hostingController.view.layoutSubtreeIfNeeded()

        let screenPoint = try Self.screenPoint(inRow: 0, panel: panel)
        panel.handlePointerMove(screenPoint: screenPoint, eventWindow: panel)
        for _ in 0..<50 where submenu.popUpCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(highlightState.isHighlighted)
        #expect(submenu.popUpCount == 1)
    }

    @Test
    func `pinned pointer input opens a real Codex account card submenu`() async throws {
        let submenu = LifecycleRecordingPopupMenu()
        let (menu, highlightState) = try Self.makeCodexAccountMenu(submenu: submenu)
        let panel = HeadroomPopupPanel(menu: menu)
        defer { panel.close() }
        panel._test_disablePointerMonitoring()
        panel.animationBehavior = .none
        panel.transition(to: .popup)
        panel.transition(to: .pinned)
        panel.hostingController.view.layoutSubtreeIfNeeded()

        let screenPoint = try Self.screenPoint(inRow: 0, panel: panel)
        panel.handlePointerMove(screenPoint: screenPoint, eventWindow: panel)
        for _ in 0..<50 where submenu.popUpCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(highlightState.isHighlighted)
        #expect(submenu.popUpCount == 1)
    }

    @Test
    func `moving from one popup row to another closes the old submenu before opening the new one`() async throws {
        let firstSubmenu = LifecycleRecordingPopupMenu()
        firstSubmenu.waitsForCancellation = true
        let secondSubmenu = LifecycleRecordingPopupMenu()
        let panel = HeadroomPopupPanel(menu: Self.makeMenu(submenus: [firstSubmenu, secondSubmenu]))
        defer { panel.close() }
        panel._test_disablePointerMonitoring()
        panel.animationBehavior = .none
        panel.transition(to: .popup)
        panel.orderFront(nil)
        panel.hostingController.view.layoutSubtreeIfNeeded()
        let secondPoint = try Self.screenPoint(inRow: 1, panel: panel)
        firstSubmenu.onPopUp = {
            panel.handlePointerMove(screenPoint: secondPoint, eventWindow: panel)
        }

        let firstPoint = try Self.screenPoint(inRow: 0, panel: panel)
        panel.handlePointerMove(screenPoint: firstPoint, eventWindow: panel)

        for _ in 0..<80 where secondSubmenu.popUpCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(firstSubmenu.cancelTrackingCount == 1)
        #expect(secondSubmenu.popUpCount == 1)
    }

    @Test
    func `leaving during a row handoff prevents a stale submenu from reopening`() async throws {
        let firstSubmenu = LifecycleRecordingPopupMenu()
        firstSubmenu.waitsForCancellation = true
        let secondSubmenu = LifecycleRecordingPopupMenu()
        let panel = HeadroomPopupPanel(menu: Self.makeMenu(submenus: [firstSubmenu, secondSubmenu]))
        defer { panel.close() }
        panel._test_disablePointerMonitoring()
        panel.animationBehavior = .none
        panel.transition(to: .popup)
        panel.orderFront(nil)
        panel.hostingController.view.layoutSubtreeIfNeeded()
        let secondPoint = try Self.screenPoint(inRow: 1, panel: panel)
        firstSubmenu.onPopUp = {
            panel.handlePointerMove(screenPoint: secondPoint, eventWindow: panel)
            DispatchQueue.main.async {
                panel.handlePointerMove(screenPoint: NSPoint(x: -100, y: -100), eventWindow: nil)
            }
        }

        let firstPoint = try Self.screenPoint(inRow: 0, panel: panel)
        panel.handlePointerMove(screenPoint: firstPoint, eventWindow: panel)
        for _ in 0..<80 where firstSubmenu.cancelTrackingCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(firstSubmenu.cancelTrackingCount == 1)
        #expect(secondSubmenu.popUpCount == 0)
    }

    @Test
    func `moving outside the popup closes its active submenu`() async throws {
        let submenu = LifecycleRecordingPopupMenu()
        submenu.waitsForCancellation = true
        let panel = HeadroomPopupPanel(menu: Self.makeMenu(submenus: [submenu]))
        defer { panel.close() }
        panel._test_disablePointerMonitoring()
        panel.animationBehavior = .none
        panel.transition(to: .popup)
        panel.orderFront(nil)
        panel.hostingController.view.layoutSubtreeIfNeeded()
        submenu.onPopUp = {
            panel.handlePointerMove(screenPoint: NSPoint(
                x: panel.frame.maxX + 100,
                y: panel.frame.maxY + 100), eventWindow: nil)
        }

        let screenPoint = try Self.screenPoint(inRow: 0, panel: panel)
        panel.handlePointerMove(screenPoint: screenPoint, eventWindow: panel)

        for _ in 0..<80 where submenu.cancelTrackingCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(submenu.popUpCount == 1)
        #expect(submenu.cancelTrackingCount == 1)
    }

    @Test
    func `pointer polling timer registers for event tracking`() {
        let monitor = HeadroomPopupPointerMonitor { _, _ in }
        monitor.start()
        defer { monitor.stop() }

        #expect(monitor._test_isPollingTimerRegistered(in: .eventTracking))
    }

    @Test
    func `unresolved same-process submenu window keeps popup handoff alive`() {
        #expect(HeadroomPopupPanel.acceptsUnresolvedSubmenuWindow(
            windowNumber: 42,
            panelWindowNumber: 7,
            ownerPID: 123,
            currentPID: 123,
            hasActiveSubmenu: true))
        #expect(!HeadroomPopupPanel.acceptsUnresolvedSubmenuWindow(
            windowNumber: 42,
            panelWindowNumber: 7,
            ownerPID: 999,
            currentPID: 123,
            hasActiveSubmenu: true))
        #expect(!HeadroomPopupPanel.acceptsUnresolvedSubmenuWindow(
            windowNumber: 7,
            panelWindowNumber: 7,
            ownerPID: 123,
            currentPID: 123,
            hasActiveSubmenu: true))
    }

    @Test
    func `moving outside a pinned popup closes its active submenu`() async throws {
        let submenu = LifecycleRecordingPopupMenu()
        submenu.waitsForCancellation = true
        let panel = HeadroomPopupPanel(menu: Self.makeMenu(submenus: [submenu]))
        defer { panel.close() }
        panel._test_disablePointerMonitoring()
        panel.animationBehavior = .none
        panel.transition(to: .popup)
        panel.transition(to: .pinned)
        panel.hostingController.view.layoutSubtreeIfNeeded()
        submenu.onPopUp = {
            panel.handlePointerMove(screenPoint: NSPoint(
                x: panel.frame.maxX + 100,
                y: panel.frame.maxY + 100), eventWindow: nil)
        }

        let screenPoint = try Self.screenPoint(inRow: 0, panel: panel)
        panel.handlePointerMove(screenPoint: screenPoint, eventWindow: panel)
        for _ in 0..<80 where submenu.cancelTrackingCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(submenu.popUpCount == 1)
        #expect(submenu.cancelTrackingCount == 1)
    }

    @Test
    func `repeated outside polling does not postpone active submenu dismissal`() async throws {
        let submenu = LifecycleRecordingPopupMenu()
        submenu.waitsForCancellation = true
        let panel = HeadroomPopupPanel(menu: Self.makeMenu(submenus: [submenu]))
        defer { panel.close() }
        panel._test_disablePointerMonitoring()
        panel.animationBehavior = .none
        panel.transition(to: .popup)
        panel.orderFront(nil)
        panel.hostingController.view.layoutSubtreeIfNeeded()
        let driver = LifecyclePointerPollDriver(
            panel: panel,
            screenPoint: NSPoint(x: -10000, y: -10000))
        var pollingTimer: Timer?
        defer { pollingTimer?.invalidate() }
        submenu.onPopUp = {
            let timer = Timer(
                timeInterval: 0.02,
                target: driver,
                selector: #selector(LifecyclePointerPollDriver.timerFired(_:)),
                userInfo: nil,
                repeats: true)
            pollingTimer = timer
            RunLoop.main.add(timer, forMode: .eventTracking)
        }

        let screenPoint = try Self.screenPoint(inRow: 0, panel: panel)
        panel.handlePointerMove(screenPoint: screenPoint, eventWindow: panel)
        for _ in 0..<80 where submenu.cancelTrackingCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(driver.tickCount > 1)
        #expect(submenu.cancelTrackingCount == 1)
    }

    @Test
    func `moving from a popup row into its submenu window keeps the submenu open`() async throws {
        let submenu = LifecycleRecordingPopupMenu()
        let panel = HeadroomPopupPanel(menu: Self.makeMenu(submenus: [submenu]))
        let submenuWindow = LifecyclePopupMenuWindow(
            contentRect: NSRect(x: 900, y: 500, width: 240, height: 300),
            styleMask: .borderless,
            backing: .buffered,
            defer: false)
        defer {
            submenuWindow.close()
            panel.close()
        }
        panel._test_disablePointerMonitoring()
        submenuWindow.level = .popUpMenu
        panel.animationBehavior = .none
        panel.transition(to: .popup)
        panel.orderFront(nil)
        panel.hostingController.view.layoutSubtreeIfNeeded()
        submenu.onPopUp = {
            submenuWindow.orderFront(nil)
            panel.handlePointerMove(
                screenPoint: NSPoint(x: submenuWindow.frame.midX, y: submenuWindow.frame.midY),
                eventWindow: submenuWindow)
        }

        let screenPoint = try Self.screenPoint(inRow: 0, panel: panel)
        panel.handlePointerMove(screenPoint: screenPoint, eventWindow: panel)
        for _ in 0..<50 where submenu.popUpCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(submenu.popUpCount == 1)
        #expect(submenu.cancelTrackingCount == 0)
    }

    @Test
    func `moving into the projected submenu region keeps every submenu selectable`() throws {
        let submenu = LifecycleRecordingPopupMenu()
        submenu.waitsForCancellation = true
        submenu.trackingTimeout = 0.35
        submenu.addItem(withTitle: "Selectable account", action: nil, keyEquivalent: "")
        let panel = HeadroomPopupPanel(menu: Self.makeMenu(submenus: [submenu]))
        defer { panel.close() }
        panel._test_disablePointerMonitoring()
        panel.animationBehavior = .none
        panel.transition(to: .popup)
        panel.setFrame(NSRect(x: 100, y: 100, width: 360, height: 180), display: false)
        panel.orderFront(nil)
        panel.hostingController.view.layoutSubtreeIfNeeded()
        let rowFrame = try Self.screenFrame(inRow: 0, panel: panel)
        submenu.update()
        let expectedSubmenuFrame = NSRect(
            x: rowFrame.maxX,
            y: rowFrame.maxY - submenu.size.height,
            width: submenu.size.width,
            height: submenu.size.height)
        let submenuPoint = NSPoint(
            x: expectedSubmenuFrame.minX + min(20, expectedSubmenuFrame.width / 2),
            y: expectedSubmenuFrame.midY)
        #expect(!panel.frame.contains(submenuPoint))
        #expect(expectedSubmenuFrame.contains(submenuPoint))
        submenu.onPopUp = {
            panel.handlePointerMove(screenPoint: submenuPoint, eventWindow: nil)
        }

        let stack = try #require(Self.findMenuStack(in: panel.hostingController.view))
        stack._test_openSubmenuForTesting(at: 0)

        #expect(submenu.cancelTrackingCount == 0)
    }

    @Test
    func `projected submenu follows native screen edge clamping for a low row`() throws {
        let rowFrame = NSRect(x: 100, y: 12, width: 360, height: 44)
        let submenuSize = NSSize(width: 220, height: 300)
        let visibleFrame = NSRect(x: 0, y: 0, width: 900, height: 700)

        let frames = HeadroomPopupMenuStackView.projectedSubmenuFrames(
            rowFrame: rowFrame,
            submenuSize: submenuSize,
            visibleFrames: [visibleFrame])
        let rightFrame = try #require(frames.first)

        #expect(rightFrame.minY == visibleFrame.minY)
        #expect(rightFrame.contains(NSPoint(x: rowFrame.maxX + 20, y: 200)))
    }

    @Test
    func `an unrelated popup window cannot keep the active submenu open`() async throws {
        let submenu = LifecycleRecordingPopupMenu()
        submenu.waitsForCancellation = true
        let panel = HeadroomPopupPanel(menu: Self.makeMenu(submenus: [submenu]))
        let unrelatedWindow = NSWindow(
            contentRect: NSRect(x: 900, y: 500, width: 240, height: 300),
            styleMask: .borderless,
            backing: .buffered,
            defer: false)
        defer {
            unrelatedWindow.close()
            panel.close()
        }
        panel._test_disablePointerMonitoring()
        unrelatedWindow.level = .popUpMenu
        panel.animationBehavior = .none
        panel.transition(to: .popup)
        panel.orderFront(nil)
        panel.hostingController.view.layoutSubtreeIfNeeded()
        submenu.onPopUp = {
            unrelatedWindow.orderFront(nil)
            panel.handlePointerMove(
                screenPoint: NSPoint(x: unrelatedWindow.frame.midX, y: unrelatedWindow.frame.midY),
                eventWindow: unrelatedWindow)
        }

        let screenPoint = try Self.screenPoint(inRow: 0, panel: panel)
        panel.handlePointerMove(screenPoint: screenPoint, eventWindow: panel)
        for _ in 0..<80 where submenu.cancelTrackingCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(submenu.popUpCount == 1)
        #expect(submenu.cancelTrackingCount == 1)
    }

    @Test
    func `closing or rebuilding the popup cancels an active submenu`() async throws {
        for closesPanel in [true, false] {
            let submenu = LifecycleRecordingPopupMenu()
            let panel = HeadroomPopupPanel(menu: Self.makeMenu(submenus: [submenu]))
            panel._test_disablePointerMonitoring()
            panel.animationBehavior = .none
            panel.transition(to: .popup)
            panel.orderFront(nil)
            panel.hostingController.view.layoutSubtreeIfNeeded()
            submenu.onPopUp = {
                if closesPanel {
                    panel.transition(to: .closed)
                } else {
                    panel.update(menu: Self.makeMenu(submenus: [LifecycleRecordingPopupMenu()]))
                }
            }

            let screenPoint = try Self.screenPoint(inRow: 0, panel: panel)
            panel.handlePointerMove(screenPoint: screenPoint, eventWindow: panel)
            for _ in 0..<50 where submenu.popUpCount == 0 {
                try await Task.sleep(for: .milliseconds(10))
            }

            #expect(submenu.cancelTrackingCount == 1)
            panel.close()
        }
    }

    @Test
    func `popup and pinned states share one pointer monitor lifecycle`() {
        let panel = HeadroomPopupPanel(menu: Self.makeMenu(submenus: [LifecycleRecordingPopupMenu()]))
        defer { panel.close() }

        #expect(!panel.isPointerMonitoringForTesting)
        panel.transition(to: .popup)
        #expect(panel.isPointerMonitoringForTesting)
        panel.transition(to: .pinned)
        #expect(panel.isPointerMonitoringForTesting)
        panel.transition(to: .popup)
        #expect(panel.isPointerMonitoringForTesting)
        panel.transition(to: .closed)
        #expect(!panel.isPointerMonitoringForTesting)
    }

    private static func makeCodexAccountMenu(
        submenu: NSMenu) throws -> (menu: NSMenu, highlightState: MenuCardHighlightState)
    {
        let baseline = try HeadroomDesignGalleryBaseline.load()
        let highlightState = MenuCardHighlightState()
        let wrapped = MenuCardSectionContainerView(
            highlightState: highlightState,
            showsSubmenuIndicator: false,
            submenuIndicatorAlignment: .topTrailing,
            submenuIndicatorTopPadding: 8,
            refreshMonitor: nil)
        {
            CodexAccountSummaryCardView(
                model: HeadroomDesignGalleryModels.officialAccount(
                    state: .multiAccount,
                    baseline: baseline),
                width: StatusItemController.menuCardBaseWidth)
        }
        let card = MenuCardItemHostingView(
            rootView: wrapped,
            highlightState: highlightState,
            allowsMenuHighlight: true,
            containsInteractiveControls: true)
        card.frame = NSRect(
            x: 0,
            y: 0,
            width: StatusItemController.menuCardBaseWidth,
            height: ceil(card.measuredHeight(width: StatusItemController.menuCardBaseWidth) + 7))
        let item = NSMenuItem()
        item.view = card
        item.isEnabled = true
        item.submenu = submenu
        let menu = NSMenu()
        menu.addItem(item)
        return (menu, highlightState)
    }

    private static func makeMenu(submenus: [NSMenu]) -> NSMenu {
        let menu = NSMenu()
        for (index, submenu) in submenus.enumerated() {
            let highlightState = MenuCardHighlightState()
            let card = MenuCardItemHostingView(
                rootView: Text("Card \(index)"),
                highlightState: highlightState,
                allowsMenuHighlight: true)
            card.frame = NSRect(x: 0, y: 0, width: 360, height: 44)
            let item = NSMenuItem()
            item.view = card
            item.isEnabled = true
            item.submenu = submenu
            menu.addItem(item)
        }
        return menu
    }

    private static func screenPoint(inRow index: Int, panel: HeadroomPopupPanel) throws -> NSPoint {
        let frame = try self.screenFrame(inRow: index, panel: panel)
        return NSPoint(x: frame.midX, y: frame.midY)
    }

    private static func screenFrame(inRow index: Int, panel: HeadroomPopupPanel) throws -> NSRect {
        panel.hostingController.view.layoutSubtreeIfNeeded()
        if panel.frame.size == .zero {
            panel.setFrame(
                NSRect(
                    x: 100,
                    y: 100,
                    width: max(panel.contentSize.width, 360),
                    height: panel.contentSize.height + HeadroomPopupCardStack.toolbarHeight),
                display: false)
        }
        let stack = try #require(self.findMenuStack(in: panel.hostingController.view))
        let row = try #require(stack.rowViews.indices.contains(index) ? stack.rowViews[index] : nil)
        let frameInWindow = row.convert(row.bounds, to: nil)
        return panel.convertToScreen(frameInWindow)
    }

    private static func findMenuStack(in view: NSView) -> HeadroomPopupMenuStackView? {
        if let stack = view as? HeadroomPopupMenuStackView {
            return stack
        }
        for subview in view.subviews {
            if let stack = self.findMenuStack(in: subview) {
                return stack
            }
        }
        return nil
    }
}

private final class LifecycleRecordingPopupMenu: NSMenu {
    nonisolated(unsafe) var onPopUp: (() -> Void)?
    nonisolated(unsafe) var waitsForCancellation = false
    nonisolated(unsafe) var trackingTimeout: TimeInterval = 1
    private(set) nonisolated(unsafe) var popUpCount = 0
    private(set) nonisolated(unsafe) var cancelTrackingCount = 0
    private(set) nonisolated(unsafe) var wasCancelled = false

    override func popUp(positioning item: NSMenuItem?, at location: NSPoint, in view: NSView?) -> Bool {
        self.popUpCount += 1
        self.wasCancelled = false
        self.onPopUp?()
        guard self.waitsForCancellation else { return true }
        let deadline = Date().addingTimeInterval(self.trackingTimeout)
        while !self.wasCancelled, Date() < deadline {
            _ = RunLoop.current.run(
                mode: .eventTracking,
                before: min(deadline, Date().addingTimeInterval(0.01)))
        }
        return true
    }

    override func cancelTrackingWithoutAnimation() {
        self.cancelTrackingCount += 1
        self.wasCancelled = true
    }
}

private final class LifecyclePopupMenuWindow: NSWindow {}

@MainActor
private final class LifecyclePointerPollDriver: NSObject {
    private weak var panel: HeadroomPopupPanel?
    private let screenPoint: NSPoint
    private(set) var tickCount = 0

    init(panel: HeadroomPopupPanel, screenPoint: NSPoint) {
        self.panel = panel
        self.screenPoint = screenPoint
    }

    @objc func timerFired(_: Timer) {
        self.tickCount += 1
        self.panel?.handlePointerMove(screenPoint: self.screenPoint, eventWindow: nil)
    }
}
