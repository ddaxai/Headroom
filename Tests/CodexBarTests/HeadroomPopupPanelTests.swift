import AppKit
import CodexBarCore
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
// swiftlint:disable:next type_body_length
struct HeadroomPopupPanelTests {
    @Test
    func `popup panel feature flag defaults to the new host while preserving explicit choices`() throws {
        let suite = "HeadroomPopupPanelTests-feature-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(ForkFeaturePolicy.usesHeadroomPopupPanel(userDefaults: defaults))

        defaults.set(false, forKey: ForkFeaturePolicy.headroomPopupPanelDefaultsKey)
        #expect(!ForkFeaturePolicy.usesHeadroomPopupPanel(userDefaults: defaults))

        defaults.set(true, forKey: ForkFeaturePolicy.headroomPopupPanelDefaultsKey)
        #expect(ForkFeaturePolicy.usesHeadroomPopupPanel(userDefaults: defaults))
    }

    @Test
    func `popup panel is borderless nonactivating and hosts the existing menu rows`() throws {
        let menu = Self.makeMenu(rowHeights: [44, 9, 72])
        let originalViews = try menu.items.map { try #require($0.view) }
        let panel = HeadroomPopupPanel(menu: menu)
        defer { panel.close() }

        #expect(panel.styleMask.contains(.borderless))
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.level == .popUpMenu)
        #expect(panel.contentViewController === panel.hostingController)
        #expect(panel.sourceMenu === menu)
        #expect(panel.contentSize == NSSize(width: 360, height: 125))
        #expect(originalViews.allSatisfy { $0.isDescendant(of: panel.hostingController.view) })
    }

    @Test
    func `popup panel pins the console appearance and background`() {
        let panel = HeadroomPopupPanel(menu: Self.makeMenu(rowHeights: [44]))
        defer { panel.close() }

        #expect(panel.appearance?.name == ConsoleDesign.nsAppearance.name)
        #expect(panel.contentView?.layer?.backgroundColor != nil)
    }

    @Test
    func `popup stack keeps every menu row inside a stable width without overlap`() {
        let menu = Self.makeMenu(rowHeights: [44, 9, 72])
        let stack = HeadroomPopupMenuStackView(menu: menu)
        stack.frame = NSRect(origin: .zero, size: stack.contentSize)
        stack.layoutSubtreeIfNeeded()
        let rowViews = stack.rowViews
        #expect(rowViews.count == menu.items.count)
        let targets = rowViews.enumerated().map { index, view in
            HeadroomGeometryAssertions.Target(name: "row-\(index)", view: view)
        }

        let failures = HeadroomGeometryAssertions.failures(
            root: stack,
            targets: targets,
            minimumHitTarget: NSSize(width: 1, height: 1))

        #expect(stack.contentSize == NSSize(width: 360, height: 125))
        #expect(failures.isEmpty, "Popup stack geometry failures: \(failures)")
        #expect(targets.allSatisfy { $0.view.frame.width == 360 })
    }

    @Test
    func `popup placement anchors below the status item and avoids the right edge`() {
        let frame = HeadroomPopupPlacement.frame(
            contentSize: NSSize(width: 360, height: 400),
            anchorFrame: NSRect(x: 700, y: 880, width: 20, height: 20),
            visibleFrames: [NSRect(x: 0, y: 0, width: 800, height: 900)])

        #expect(frame == NSRect(x: 360, y: 480, width: 360, height: 400))
    }

    @Test
    func `popup placement selects the anchor display and avoids its edges`() {
        let frame = HeadroomPopupPlacement.frame(
            contentSize: NSSize(width: 360, height: 400),
            anchorFrame: NSRect(x: 1570, y: 880, width: 20, height: 20),
            visibleFrames: [
                NSRect(x: 0, y: 0, width: 800, height: 900),
                NSRect(x: 800, y: 0, width: 800, height: 900),
            ])

        #expect(frame == NSRect(x: 1230, y: 480, width: 360, height: 400))
    }

    @Test
    func `popup placement opens above when there is no room below`() {
        let frame = HeadroomPopupPlacement.frame(
            contentSize: NSSize(width: 360, height: 400),
            anchorFrame: NSRect(x: 100, y: 20, width: 20, height: 20),
            visibleFrames: [NSRect(x: 0, y: 0, width: 800, height: 900)])

        #expect(frame == NSRect(x: 8, y: 40, width: 360, height: 400))
    }

    @Test
    func `status item preserves an explicit legacy choice and routes to panel when enabled`() throws {
        let legacy = try Self.makeController(popupPanelEnabled: false)
        defer { legacy.releaseStatusItemsForTesting() }
        #expect(legacy.statusItem.menu != nil)
        #expect(legacy.statusItem.button?.action == nil)

        let panel = try Self.makeController(popupPanelEnabled: true)
        defer { panel.releaseStatusItemsForTesting() }
        #expect(panel.statusItem.menu == nil)
        #expect(panel.statusItem.button?.target === panel)
        #expect(panel.statusItem.button?.action == #selector(StatusItemController.toggleHeadroomPopupPanel(_:)))
    }

    @Test
    func `shortcut closes a visible popup panel and its tracked menu`() throws {
        let controller = try Self.makeController(popupPanelEnabled: true)
        defer { controller.releaseStatusItemsForTesting() }
        let menu = Self.makeMenu(rowHeights: [44])
        let panel = HeadroomPopupPanel(menu: menu)
        controller.headroomPopupPanel = panel
        controller.headroomPopupMenu = menu
        controller.openMenus[ObjectIdentifier(menu)] = menu
        panel.orderFront(nil)
        #expect(panel.isVisible)

        #expect(controller.closeOpenMenusFromShortcutIfNeeded())
        #expect(!panel.isVisible)
        #expect(controller.headroomPopupMenu == nil)
        #expect(controller.openMenus.isEmpty)
        #expect(!controller.closeOpenMenusFromShortcutIfNeeded())
    }

    @Test
    func `popup state machine applies the window contract without replacing hosted content`() {
        let panel = HeadroomPopupPanel(menu: Self.makeMenu(rowHeights: [44]))
        defer { panel.close() }
        let hostingController = panel.hostingController

        panel.transition(to: .popup)
        #expect(panel.presentationState == .popup)
        #expect(panel.level == .popUpMenu)
        #expect(panel.collectionBehavior == [.transient])
        #expect(!panel.isMovable)
        #expect(!panel.isMovableByWindowBackground)
        #expect(panel.hostingController === hostingController)

        panel.transition(to: .pinned)
        #expect(panel.presentationState == .pinned)
        #expect(panel.level == .floating)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(panel.isMovable)
        #expect(panel.isMovableByWindowBackground)
        #expect(panel.hostingController === hostingController)

        panel.orderFront(nil)
        panel.transition(to: .closed)
        #expect(panel.presentationState == .closed)
        #expect(!panel.isVisible)
        #expect(panel.collectionBehavior == [])
        #expect(!panel.isMovable)
        #expect(!panel.isMovableByWindowBackground)
        #expect(panel.hostingController === hostingController)
    }

    @Test
    func `pin state reanchors at the status item after every popup round trip`() {
        let anchorWindow = NSWindow(
            contentRect: NSRect(x: 200, y: 700, width: 80, height: 40),
            styleMask: .borderless,
            backing: .buffered,
            defer: false)
        anchorWindow.animationBehavior = .none
        let anchorView = NSView(frame: NSRect(x: 24, y: 8, width: 24, height: 24))
        anchorWindow.contentView?.addSubview(anchorView)
        anchorWindow.orderFront(nil)
        defer { anchorWindow.orderOut(nil) }

        let panel = HeadroomPopupPanel(menu: Self.makeMenu(rowHeights: [44]))
        defer {
            panel.transition(to: .closed)
            panel.orderOut(nil)
        }
        panel.animationBehavior = .none
        panel.show(relativeTo: anchorView)

        let anchorFrameInWindow = anchorView.convert(anchorView.bounds, to: nil)
        let anchorFrame = anchorWindow.convertToScreen(anchorFrameInWindow)
        let expectedOrigin = HeadroomPopupPlacement.frame(
            contentSize: panel.frame.size,
            anchorFrame: anchorFrame,
            visibleFrames: NSScreen.screens.map(\.visibleFrame)).origin

        panel.togglePinned()
        panel.setFrameOrigin(NSPoint(x: 240, y: 180))
        panel.togglePinned()
        panel.setFrameOrigin(NSPoint(x: 700, y: 600))
        panel.togglePinned()

        #expect(panel.frame.origin == expectedOrigin)
    }

    @Test
    func `only an outside click dismisses the unpinned popup`() {
        let panel = HeadroomPopupPanel(menu: Self.makeMenu(rowHeights: [44]))
        defer { panel.close() }
        panel.setFrame(NSRect(x: 100, y: 100, width: 360, height: 120), display: false)

        panel.transition(to: .popup)
        #expect(!panel.shouldDismissPopup(forScreenPoint: NSPoint(x: 120, y: 120)))
        #expect(panel.shouldDismissPopup(forScreenPoint: NSPoint(x: 20, y: 20)))

        panel.transition(to: .pinned)
        #expect(!panel.shouldDismissPopup(forScreenPoint: NSPoint(x: 20, y: 20)))
    }

    @Test
    func `status item anchor click is left for the button toggle to dismiss`() {
        let anchorWindow = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 80, height: 40),
            styleMask: .borderless,
            backing: .buffered,
            defer: false)
        let anchorView = NSView(frame: NSRect(x: 24, y: 8, width: 24, height: 24))
        anchorWindow.contentView?.addSubview(anchorView)
        anchorWindow.orderFront(nil)
        defer { anchorWindow.orderOut(nil) }
        let panel = HeadroomPopupPanel(menu: Self.makeMenu(rowHeights: [44]))
        defer {
            panel.transition(to: .closed)
            panel.orderOut(nil)
        }
        panel.show(relativeTo: anchorView)
        let anchorFrameInWindow = anchorView.convert(anchorView.bounds, to: nil)
        let anchorFrame = anchorWindow.convertToScreen(anchorFrameInWindow)

        #expect(!panel.frame.contains(NSPoint(x: anchorFrame.midX, y: anchorFrame.midY)))
        #expect(!panel.shouldDismissPopup(forScreenPoint: NSPoint(x: anchorFrame.midX, y: anchorFrame.midY)))
    }

    @Test
    func `popup pin control has a visible nonzero hit target inside its toolbar`() {
        let presentation = HeadroomPopupPresentationModel()
        var toggleCount = 0
        presentation.onTogglePin = { toggleCount += 1 }
        let toolbar = HeadroomPopupToolbarView(presentation: presentation)
        toolbar.frame = NSRect(x: 0, y: 0, width: 360, height: HeadroomPopupCardStack.toolbarHeight)
        toolbar.layoutSubtreeIfNeeded()

        let failures = HeadroomGeometryAssertions.failures(
            root: toolbar,
            targets: [.init(name: "pin", view: toolbar.pinButton)],
            minimumHitTarget: NSSize(width: 22, height: 22))

        #expect(toolbar.bounds.size == NSSize(width: 360, height: 30))
        #expect(toolbar.pinButton.frame.size == NSSize(width: 24, height: 22))
        #expect(failures.isEmpty, "Popup pin geometry failures: \(failures)")
        toolbar.pinButton.performClick(nil)
        #expect(toggleCount == 1)
    }

    @Test
    func `hosted pin control refreshes its feedback after pin state changes`() {
        let panel = HeadroomPopupPanel(menu: Self.makeMenu(rowHeights: [44]))
        defer { panel.close() }
        panel.transition(to: .popup)

        let toolbar = Self.findToolbar(in: panel.hostingController.view)
        #expect(toolbar?.pinButton.toolTip == L("headroom_popup_pin"))

        panel.transition(to: .pinned)
        panel.hostingController.view.layoutSubtreeIfNeeded()

        #expect(toolbar?.pinButton.toolTip == L("headroom_popup_unpin"))
        #expect(toolbar?.pinButton.image?.accessibilityDescription == L("headroom_popup_unpin"))
    }

    @Test
    func `pin round trips keep the hosted menu content attached and visible`() throws {
        let menu = Self.makeMenu(rowHeights: [44, 72])
        let contentViews = try menu.items.map { try #require($0.view) }
        let panel = HeadroomPopupPanel(menu: menu)
        defer { panel.close() }
        let hostingController = panel.hostingController
        panel.transition(to: .popup)

        for _ in 0..<10 {
            panel.togglePinned()
            panel.togglePinned()
        }
        panel.hostingController.view.layoutSubtreeIfNeeded()

        #expect(panel.presentationState == .popup)
        #expect(panel.hostingController === hostingController)
        #expect(contentViews.allSatisfy { $0.isDescendant(of: hostingController.view) })
        #expect(contentViews.allSatisfy { !$0.isHidden && $0.alphaValue > 0 })
        #expect(contentViews.allSatisfy { $0.frame.width > 0 && $0.frame.height > 0 })
    }

    @Test
    func `menu refresh cannot detach content owned by the popup`() throws {
        let menu = Self.makeMenu(rowHeights: [44])
        let sourceItem = try #require(menu.items.first)
        let contentView = try #require(sourceItem.view)
        let panel = HeadroomPopupPanel(menu: menu)
        defer { panel.close() }
        #expect(contentView.isDescendant(of: panel.hostingController.view))

        let recycledView = sourceItem.view
        sourceItem.view = nil
        let refreshedItem = NSMenuItem()
        refreshedItem.view = recycledView

        #expect(contentView.isDescendant(of: panel.hostingController.view))

        panel.transition(to: .closed)
        #expect(sourceItem.view === contentView)
    }

    @Test
    func `popup update rehosts every row without duplicating its hierarchy`() throws {
        let firstMenu = Self.makeMenu(rowHeights: [44, 72])
        let firstViews = try firstMenu.items.map { try #require($0.view) }
        let panel = HeadroomPopupPanel(menu: firstMenu)
        defer { panel.close() }
        panel.transition(to: .popup)

        panel.transition(to: .closed)
        panel.update(menu: firstMenu)
        panel.hostingController.view.layoutSubtreeIfNeeded()

        let firstStacks = Self.findMenuStacks(in: panel.hostingController.view)
        #expect(firstStacks.count == 1)
        let firstStack = try #require(firstStacks.first)
        #expect(firstViews.allSatisfy { $0.isDescendant(of: panel.hostingController.view) })
        #expect(firstStack.rowViews.count == 2)
        #expect(firstStack.rowViews.map(\.frame.height).reduce(0, +) == 116)
        #expect(firstStack.contentSize == NSSize(width: 360, height: 116))
        #expect(panel.contentSize == NSSize(width: 360, height: 116))
        #expect(panel.frame.height == 146)
        #expect(Self.findToolbars(in: panel.hostingController.view).count == 1)

        let replacementMenu = Self.makeMenu(rowHeights: [60, 80, 100])
        let replacementViews = try replacementMenu.items.map { try #require($0.view) }
        panel.update(menu: replacementMenu)
        panel.hostingController.view.layoutSubtreeIfNeeded()

        let replacementStacks = Self.findMenuStacks(in: panel.hostingController.view)
        #expect(replacementStacks.count == 1)
        let replacementStack = try #require(replacementStacks.first)
        #expect(replacementViews.allSatisfy { $0.isDescendant(of: panel.hostingController.view) })
        #expect(firstViews.allSatisfy { !$0.isDescendant(of: panel.hostingController.view) })
        #expect(replacementStack.rowViews.count == 3)
        #expect(replacementStack.rowViews.map(\.frame.height).reduce(0, +) == 240)
        #expect(replacementStack.contentSize == NSSize(width: 360, height: 240))
        #expect(panel.contentSize == NSSize(width: 360, height: 240))
        #expect(panel.frame.height == 270)
        #expect(Self.findToolbars(in: panel.hostingController.view).count == 1)
    }

    @Test
    func `ten popup updates retain one complete visible hierarchy`() throws {
        let panel = HeadroomPopupPanel(menu: Self.makeMenu(rowHeights: [44, 72]))
        defer { panel.close() }

        for cycle in 0..<10 {
            panel.transition(to: .closed)
            let menu = Self.makeMenu(rowHeights: [44 + CGFloat(cycle), 72])
            let views = try menu.items.map { try #require($0.view) }
            panel.update(menu: menu)
            panel.hostingController.view.layoutSubtreeIfNeeded()

            let stacks = Self.findMenuStacks(in: panel.hostingController.view)
            #expect(stacks.count == 1)
            let stack = try #require(stacks.first)
            #expect(views.allSatisfy { $0.isDescendant(of: panel.hostingController.view) })
            #expect(stack.rowViews.count == 2)
            #expect(stack.rowViews.map(\.frame.height).reduce(0, +) == 116 + CGFloat(cycle))
            #expect(Self.findToolbars(in: panel.hostingController.view).count == 1)
        }
    }

    @Test
    func `provider switch click rehosts the updated rows in the visible popup`() async throws {
        let controller = try Self.makeController(popupPanelEnabled: true)
        defer { controller.releaseStatusItemsForTesting() }
        controller.settings.selectedMenuProvider = .codex
        controller.settings.mergedMenuLastSelectedWasOverview = false

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let panel = HeadroomPopupPanel(menu: menu)
        defer { panel.close() }
        controller.headroomPopupPanel = panel
        controller.headroomPopupMenu = menu
        controller.openMenus[ObjectIdentifier(menu)] = menu
        panel.transition(to: .popup)

        let switcher = try #require(Self.findProviderSwitcher(in: panel.hostingController.view))
        let initialStates = switcher._test_buttonVisualStates()
        #expect(initialStates.indices.contains(1))
        #expect(initialStates[1].hasSelectedBackground)
        #expect(menu.items.allSatisfy { $0.view == nil })

        var rebuildCount = 0
        controller._test_openMenuRebuildObserver = { _ in
            rebuildCount += 1
        }
        defer { controller._test_openMenuRebuildObserver = nil }

        let buttonFrames = switcher._test_buttonFrames()
        #expect(buttonFrames.indices.contains(2))
        let targetFrame = buttonFrames[2]
        let targetPoint = NSPoint(x: targetFrame.midX, y: targetFrame.midY)
        #expect(switcher.hitTest(targetPoint) === switcher)
        let pointInWindow = switcher.convert(targetPoint, to: nil)
        let mouseDown = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: pointInWindow,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1))
        let mouseUp = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: pointInWindow,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 0))
        switcher.mouseDown(with: mouseDown)
        switcher.mouseUp(with: mouseUp)
        for _ in 0..<100 where rebuildCount == 0 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        panel.hostingController.view.layoutSubtreeIfNeeded()

        let updatedSwitcher = try #require(Self.findProviderSwitcher(in: panel.hostingController.view))
        let updatedStates = updatedSwitcher._test_buttonVisualStates()
        #expect(controller.settings.selectedMenuProvider == .claude)
        #expect(rebuildCount == 1)
        #expect(updatedStates.indices.contains(2))
        #expect(updatedStates[2].hasSelectedBackground)
        #expect(menu.items.allSatisfy { $0.view == nil })
    }

    @Test
    func `popup hover highlights immediately and opens its submenu after a delay`() async throws {
        let menu = NSMenu()
        let submenu = RecordingPopupMenu()
        let highlightState = MenuCardHighlightState()
        let card = MenuCardItemHostingView(
            rootView: Text("Card"),
            highlightState: highlightState,
            allowsMenuHighlight: true)
        card.frame = NSRect(x: 0, y: 0, width: 360, height: 44)
        let item = NSMenuItem()
        item.view = card
        item.submenu = submenu
        menu.addItem(item)

        let stack = HeadroomPopupMenuStackView(menu: menu)
        stack.frame = NSRect(origin: .zero, size: stack.contentSize)
        stack.layoutSubtreeIfNeeded()
        let row = try #require(stack.rowViews.first)
        let event = try #require(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(x: row.bounds.midX, y: row.bounds.midY),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 0,
            pressure: 0))

        row.mouseEntered(with: event)

        #expect(highlightState.isHighlighted)
        #expect(submenu.popUpCount == 0)
        for _ in 0..<100 where submenu.popUpCount == 0 {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(submenu.popUpCount == 1)

        row.mouseExited(with: event)
        #expect(!highlightState.isHighlighted)
    }

    @Test
    func `popup enables mouse movement for hosted card hover tracking`() {
        let menu = NSMenu()
        let card = MenuCardItemHostingView(
            rootView: Text("Card"),
            highlightState: MenuCardHighlightState(),
            allowsMenuHighlight: true,
            onClick: {})
        card.frame = NSRect(x: 0, y: 0, width: 360, height: 44)
        let item = NSMenuItem()
        item.view = card
        item.submenu = RecordingPopupMenu()
        menu.addItem(item)
        let panel = HeadroomPopupPanel(menu: menu)
        defer {
            panel.transition(to: .closed)
            panel.orderOut(nil)
        }
        panel.animationBehavior = .none
        panel.transition(to: .popup)
        panel.orderFront(nil)
        panel.hostingController.view.layoutSubtreeIfNeeded()
        #expect(panel.acceptsMouseMovedEvents)
        #expect(panel.isPointerMonitoringForTesting)
    }

    @Test
    func `popup mouse movement opens a hosted card submenu without clicking`() async throws {
        let menu = NSMenu()
        let submenu = RecordingPopupMenu()
        let highlightState = MenuCardHighlightState()
        let card = MenuCardItemHostingView(
            rootView: Text("Card"),
            highlightState: highlightState,
            allowsMenuHighlight: true,
            onClick: {})
        card.frame = NSRect(x: 0, y: 0, width: 360, height: 44)
        let item = NSMenuItem()
        item.view = card
        item.submenu = submenu
        menu.addItem(item)
        let stack = HeadroomPopupMenuStackView(menu: menu)
        stack.frame = NSRect(origin: .zero, size: stack.contentSize)
        stack.layoutSubtreeIfNeeded()
        let row = try #require(stack.rowViews.first)
        let targetPoint = NSPoint(x: row.bounds.midX, y: row.bounds.midY)
        #expect(row.hitTest(targetPoint) === card)
        let event = try #require(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: targetPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 0,
            pressure: 0))

        row.mouseMoved(with: event)
        try await Task.sleep(for: .milliseconds(250))

        #expect(highlightState.isHighlighted)
        #expect(submenu.popUpCount == 1)
        row.mouseExited(with: event)
    }

    @Test
    func `panel pointer tracker dispatches hosted card hover`() throws {
        let menu = NSMenu()
        let submenu = RecordingPopupMenu()
        let highlightState = MenuCardHighlightState()
        let card = MenuCardItemHostingView(
            rootView: Text("Card"),
            highlightState: highlightState,
            allowsMenuHighlight: true,
            onClick: {})
        card.frame = NSRect(x: 0, y: 0, width: 360, height: 44)
        let item = NSMenuItem()
        item.view = card
        item.submenu = submenu
        menu.addItem(item)
        let panel = HeadroomPopupPanel(menu: menu)
        defer {
            panel.transition(to: .closed)
            panel.orderOut(nil)
        }
        panel._test_disablePointerMonitoring()
        panel.animationBehavior = .none
        panel.transition(to: .popup)
        panel.hostingController.view.layoutSubtreeIfNeeded()
        panel.setFrame(
            NSRect(
                x: 100,
                y: 100,
                width: max(panel.contentSize.width, 360),
                height: panel.contentSize.height + HeadroomPopupCardStack.toolbarHeight),
            display: false)
        let stack = try #require(Self.findMenuStacks(in: panel.hostingController.view).first)
        let row = try #require(stack.rowViews.first)
        let pointInWindow = row.convert(
            NSPoint(x: row.bounds.midX, y: row.bounds.midY),
            to: nil)
        let pointInStack = stack.convert(pointInWindow, from: nil)
        let roundTrippedPointInRow = row.convert(pointInStack, from: stack)
        #expect(stack.bounds.contains(pointInStack))
        #expect(row.bounds.contains(roundTrippedPointInRow))
        #expect(row.window === panel)
        let event = try #require(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: pointInWindow,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 0,
            pressure: 0))
        #expect(event.locationInWindow == pointInWindow)

        panel.handlePointerMove(
            screenPoint: panel.convertPoint(toScreen: pointInWindow),
            eventWindow: panel)
        #expect(highlightState.isHighlighted)
        #expect(submenu.popUpCount == 0)
    }

    @Test
    func `popup pointer tracker forwards hover and clears it on exit`() throws {
        let menu = NSMenu()
        let submenu = RecordingPopupMenu()
        let highlightState = MenuCardHighlightState()
        let card = MenuCardItemHostingView(
            rootView: Text("Card"),
            highlightState: highlightState,
            allowsMenuHighlight: true,
            onClick: {})
        card.frame = NSRect(x: 0, y: 0, width: 360, height: 44)
        let item = NSMenuItem()
        item.view = card
        item.submenu = submenu
        menu.addItem(item)

        let panel = HeadroomPopupPanel(menu: menu)
        defer {
            panel.transition(to: .closed)
            panel.orderOut(nil)
        }
        panel._test_disablePointerMonitoring()
        panel.animationBehavior = .none
        panel.transition(to: .popup)
        panel.hostingController.view.layoutSubtreeIfNeeded()
        panel.setFrame(
            NSRect(
                x: 100,
                y: 100,
                width: max(panel.contentSize.width, 360),
                height: panel.contentSize.height + HeadroomPopupCardStack.toolbarHeight),
            display: false)

        let tracker = panel.pointerTrackingView
        let stack = try #require(Self.findMenuStacks(in: panel.hostingController.view).first)
        let row = try #require(stack.rowViews.first)
        let trackerPoint = tracker.convert(
            row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil),
            from: nil)
        let pointInWindow = row.convert(
            NSPoint(x: row.bounds.midX, y: row.bounds.midY),
            to: nil)
        _ = try #require(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: pointInWindow,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 0,
            pressure: 0))
        #expect(tracker.isDescendant(of: panel.hostingController.view))
        #expect(tracker.window === panel)
        #expect(tracker.frame == panel.hostingController.view.bounds)
        #expect(tracker.frame.contains(trackerPoint))
        #expect(tracker.hitTest(trackerPoint) == nil)
        #expect(panel.acceptsMouseMovedEvents)
        panel.handlePointerMove(
            screenPoint: panel.convertPoint(toScreen: pointInWindow),
            eventWindow: panel)
        #expect(highlightState.isHighlighted)
        panel.handlePointerMove(screenPoint: NSPoint(x: -100, y: -100), eventWindow: nil)
        #expect(!highlightState.isHighlighted)
    }

    @Test
    func `popup pointer tracker cancels pending submenu after a fast exit`() async throws {
        let menu = NSMenu()
        let submenu = RecordingPopupMenu()
        let highlightState = MenuCardHighlightState()
        let card = MenuCardItemHostingView(
            rootView: Text("Card"),
            highlightState: highlightState,
            allowsMenuHighlight: true,
            onClick: {})
        card.frame = NSRect(x: 0, y: 0, width: 360, height: 44)
        let item = NSMenuItem()
        item.view = card
        item.submenu = submenu
        menu.addItem(item)

        let panel = HeadroomPopupPanel(menu: menu)
        defer {
            panel.transition(to: .closed)
            panel.orderOut(nil)
        }
        panel._test_disablePointerMonitoring()
        panel.animationBehavior = .none
        panel.transition(to: .popup)
        panel.orderFront(nil)
        panel.hostingController.view.layoutSubtreeIfNeeded()
        panel.setFrame(
            NSRect(
                x: 100,
                y: 100,
                width: max(panel.contentSize.width, 360),
                height: panel.contentSize.height + HeadroomPopupCardStack.toolbarHeight),
            display: false)

        let stack = try #require(Self.findMenuStacks(in: panel.hostingController.view).first)
        let row = try #require(stack.rowViews.first)
        let pointInWindow = row.convert(
            NSPoint(x: row.bounds.midX, y: row.bounds.midY),
            to: nil)
        _ = try #require(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: pointInWindow,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 3,
            clickCount: 0,
            pressure: 0))

        panel.handlePointerMove(
            screenPoint: panel.convertPoint(toScreen: pointInWindow),
            eventWindow: panel)
        #expect(highlightState.isHighlighted)
        panel.handlePointerMove(screenPoint: NSPoint(x: -100, y: -100), eventWindow: nil)
        #expect(!highlightState.isHighlighted)
        try await Task.sleep(for: .milliseconds(250))
        #expect(submenu.popUpCount == 0)
    }

    @Test
    func `repeated popup mouse movement does not postpone submenu hover`() async throws {
        let menu = NSMenu()
        let submenu = RecordingPopupMenu()
        let card = MenuCardItemHostingView(
            rootView: Text("Card"),
            highlightState: MenuCardHighlightState(),
            allowsMenuHighlight: true,
            onClick: {})
        card.frame = NSRect(x: 0, y: 0, width: 360, height: 44)
        let item = NSMenuItem()
        item.view = card
        item.submenu = submenu
        menu.addItem(item)
        let stack = HeadroomPopupMenuStackView(menu: menu)
        stack.frame = NSRect(origin: .zero, size: stack.contentSize)
        stack.layoutSubtreeIfNeeded()
        let row = try #require(stack.rowViews.first)
        let event = try #require(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(x: row.bounds.midX, y: row.bounds.midY),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 0,
            pressure: 0))

        row.mouseMoved(with: event)
        for _ in 0..<10 where submenu.popUpCount == 0 {
            try await Task.sleep(for: .milliseconds(35))
            row.mouseMoved(with: event)
        }

        #expect(submenu.popUpCount == 1)
        row.mouseMoved(with: event)
        try await Task.sleep(for: .milliseconds(200))
        #expect(submenu.popUpCount == 1)
        row.mouseExited(with: event)
    }

    @Test
    func `pinned popup keeps one working submenu event pipeline after round trips`() async throws {
        let menu = NSMenu()
        let submenu = RecordingPopupMenu()
        let card = MenuCardItemHostingView(
            rootView: Text("Card"),
            highlightState: MenuCardHighlightState(),
            allowsMenuHighlight: true)
        card.frame = NSRect(x: 0, y: 0, width: 360, height: 44)
        let item = NSMenuItem()
        item.view = card
        item.submenu = submenu
        menu.addItem(item)
        let panel = HeadroomPopupPanel(menu: menu)
        defer {
            panel.transition(to: .closed)
            panel.orderOut(nil)
        }
        panel.animationBehavior = .none
        panel.transition(to: .popup)
        panel.orderFront(nil)
        panel.hostingController.view.layoutSubtreeIfNeeded()
        let initialStack = try #require(Self.findMenuStacks(in: panel.hostingController.view).first)
        let initialRow = try #require(initialStack.rowViews.first)
        for _ in 0..<10 {
            panel.togglePinned()
            for _ in 0..<100
                where Self.findToolbar(in: panel.hostingController.view)?.pinButton.toolTip != L("headroom_popup_unpin")
            {
                await Task.yield()
                try await Task.sleep(for: .milliseconds(2))
                panel.hostingController.view.layoutSubtreeIfNeeded()
            }
            #expect(Self.findToolbar(in: panel.hostingController.view)?.pinButton.toolTip == L("headroom_popup_unpin"))
            #expect(Self.findMenuStacks(in: panel.hostingController.view).first === initialStack)
            #expect(initialStack.rowViews.first === initialRow)

            panel.togglePinned()
            for _ in 0..<100
                where Self.findToolbar(in: panel.hostingController.view)?.pinButton.toolTip != L("headroom_popup_pin")
            {
                await Task.yield()
                try await Task.sleep(for: .milliseconds(2))
                panel.hostingController.view.layoutSubtreeIfNeeded()
            }
            #expect(Self.findToolbar(in: panel.hostingController.view)?.pinButton.toolTip == L("headroom_popup_pin"))
            #expect(Self.findMenuStacks(in: panel.hostingController.view).first === initialStack)
            #expect(initialStack.rowViews.first === initialRow)
        }
        panel.togglePinned()
        for _ in 0..<100
            where Self.findToolbar(in: panel.hostingController.view)?.pinButton.toolTip != L("headroom_popup_unpin")
        {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(2))
            panel.hostingController.view.layoutSubtreeIfNeeded()
        }

        let stack = try #require(Self.findMenuStacks(in: panel.hostingController.view).first)
        let row = try #require(stack.rowViews.first)
        let targetPoint = NSPoint(x: row.bounds.midX, y: row.bounds.midY)
        let pointInWindow = row.convert(targetPoint, to: nil)
        let mouseDown = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: pointInWindow,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1))
        let mouseUp = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: pointInWindow,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 0))

        #expect(panel.presentationState == .pinned)
        #expect(stack === initialStack)
        #expect(row === initialRow)
        #expect(card.isDescendant(of: row))
        #expect(row.hitTest(targetPoint) === row)
        row.mouseDown(with: mouseDown)
        row.mouseUp(with: mouseUp)
        #expect(submenu.popUpCount == 1)
    }

    @Test
    func `closing popup cancels a pending hover submenu`() async throws {
        let menu = NSMenu()
        let submenu = RecordingPopupMenu()
        let card = MenuCardItemHostingView(
            rootView: Text("Card"),
            highlightState: MenuCardHighlightState(),
            allowsMenuHighlight: true)
        card.frame = NSRect(x: 0, y: 0, width: 360, height: 44)
        let item = NSMenuItem()
        item.view = card
        item.submenu = submenu
        menu.addItem(item)
        let panel = HeadroomPopupPanel(menu: menu)
        defer {
            panel.transition(to: .closed)
            panel.orderOut(nil)
        }
        panel.transition(to: .popup)
        panel.hostingController.view.layoutSubtreeIfNeeded()
        let stack = try #require(Self.findMenuStacks(in: panel.hostingController.view).first)
        let row = try #require(stack.rowViews.first)
        let event = try #require(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(x: row.bounds.midX, y: row.bounds.midY),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 0,
            pressure: 0))

        row.mouseEntered(with: event)
        panel.transition(to: .closed)
        try await Task.sleep(for: .milliseconds(250))

        #expect(submenu.popUpCount == 0)
    }

    @Test
    func `popup submenu row preserves nested SwiftUI controls`() throws {
        let interactiveRegionStore = MenuCardInteractiveRegionStore()
        let highlightState = MenuCardHighlightState()
        let content = Button("Copy") {}
            .frame(width: 80, height: 30)
            .menuCardInteractiveControl()
            .frame(width: 360, height: 44, alignment: .trailing)
        let wrapped = MenuCardSectionContainerView(
            highlightState: highlightState,
            showsSubmenuIndicator: true,
            submenuIndicatorAlignment: .trailing,
            submenuIndicatorTopPadding: 0,
            refreshMonitor: nil,
            interactiveRegionStore: interactiveRegionStore)
        {
            content
        }
        let card = MenuCardItemHostingView(
            rootView: wrapped,
            highlightState: highlightState,
            allowsMenuHighlight: true,
            containsInteractiveControls: true,
            interactiveRegionStore: interactiveRegionStore)
        card.frame = NSRect(x: 0, y: 0, width: 360, height: 51)
        let menu = NSMenu()
        let item = NSMenuItem()
        item.view = card
        item.submenu = RecordingPopupMenu()
        menu.addItem(item)
        let stack = HeadroomPopupMenuStackView(menu: menu)
        stack.frame = NSRect(origin: .zero, size: stack.contentSize)
        stack.layoutSubtreeIfNeeded()
        card.needsLayout = true
        card.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        card.layoutSubtreeIfNeeded()
        let row = try #require(stack.rowViews.first)
        let buttonPointInCard = NSPoint(x: 320, y: 39)
        let buttonPointInRow = row.convert(buttonPointInCard, from: card)

        #expect(card._test_hitsHostedInteractiveControl(at: buttonPointInCard))
        #expect(row.hitTest(stack.convert(buttonPointInRow, from: row)) !== row)
    }

    @Test
    func `popup submenu row preserves its card primary action`() throws {
        var clickCount = 0
        let submenu = RecordingPopupMenu()
        let card = MenuCardItemHostingView(
            rootView: Text("Overview"),
            highlightState: MenuCardHighlightState(),
            allowsMenuHighlight: true,
            onClick: { clickCount += 1 })
        card.frame = NSRect(x: 0, y: 0, width: 360, height: 44)
        let menu = NSMenu()
        let item = NSMenuItem()
        item.view = card
        item.submenu = submenu
        menu.addItem(item)
        let stack = HeadroomPopupMenuStackView(menu: menu)
        stack.frame = NSRect(origin: .zero, size: stack.contentSize)
        stack.layoutSubtreeIfNeeded()
        let row = try #require(stack.rowViews.first)
        let pointInCard = NSPoint(x: card.bounds.midX, y: card.bounds.midY)
        let pointInRow = row.convert(pointInCard, from: card)

        #expect(row.hitTest(pointInRow) === card)
        #expect(card._test_simulateRuntimeClick(at: pointInCard))
        #expect(clickCount == 1)
        #expect(submenu.popUpCount == 0)
    }

    @Test
    func `popup submenu row preserves its gpu card primary action`() throws {
        var clickCount = 0
        let submenu = RecordingPopupMenu()
        let wrapped = MenuCardSectionContainerView(
            highlightState: MenuCardHighlightState(),
            showsSubmenuIndicator: true,
            submenuIndicatorAlignment: .trailing,
            submenuIndicatorTopPadding: 0,
            refreshMonitor: nil)
        {
            Text("Overview GPU")
        }
        let card = GPUSelectionHostingView(
            rootView: wrapped,
            allowsMenuHighlight: true,
            onClick: { clickCount += 1 })
        card.frame = NSRect(x: 0, y: 0, width: 360, height: 44)
        let menu = NSMenu()
        let item = NSMenuItem()
        item.view = card
        item.submenu = submenu
        menu.addItem(item)
        let stack = HeadroomPopupMenuStackView(menu: menu)
        stack.frame = NSRect(origin: .zero, size: stack.contentSize)
        stack.layoutSubtreeIfNeeded()
        let row = try #require(stack.rowViews.first)
        let pointInCard = NSPoint(x: card.bounds.midX, y: card.bounds.midY)
        let pointInRow = row.convert(pointInCard, from: card)

        #expect(row.hitTest(pointInRow) === card)
        #expect(card._test_simulateRuntimeClick(at: pointInCard))
        #expect(clickCount == 1)
        #expect(submenu.popUpCount == 0)
    }

    @Test
    func `popup hit testing routes card clicks to their detail submenu`() throws {
        let menu = NSMenu()
        let submenu = RecordingPopupMenu()
        let card = MenuCardItemHostingView(
            rootView: Text("Card"),
            highlightState: MenuCardHighlightState(),
            allowsMenuHighlight: true)
        card.frame = NSRect(x: 0, y: 0, width: 360, height: 44)
        let item = NSMenuItem()
        item.view = card
        item.submenu = submenu
        menu.addItem(item)

        let panel = HeadroomPopupPanel(menu: menu)
        defer {
            panel.transition(to: .closed)
            panel.orderOut(nil)
        }
        panel.animationBehavior = .none
        panel.transition(to: .popup)
        panel.orderFront(nil)
        panel.hostingController.view.layoutSubtreeIfNeeded()
        let stack = try #require(Self.findMenuStacks(in: panel.hostingController.view).first)
        let row = try #require(stack.rowViews.first)
        let targetPoint = NSPoint(x: row.bounds.midX, y: row.bounds.midY)
        #expect(row.hitTest(targetPoint) === row)
        let pointInWindow = row.convert(targetPoint, to: nil)
        let mouseDown = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: pointInWindow,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1))
        let mouseUp = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: pointInWindow,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 0))

        row.mouseDown(with: mouseDown)
        row.mouseUp(with: mouseUp)

        #expect(submenu.popUpCount == 1)
    }

    @Test
    func `popup scroll wheel over a hosted card moves the outer scroll view`() throws {
        let menu = Self.makeMenu(rowHeights: Array(repeating: 80, count: 24))
        let anchorWindow = NSWindow(
            contentRect: NSRect(x: 100, y: 400, width: 80, height: 40),
            styleMask: .borderless,
            backing: .buffered,
            defer: false)
        let anchorView = NSView(frame: NSRect(x: 20, y: 10, width: 20, height: 20))
        anchorWindow.contentView?.addSubview(anchorView)
        anchorWindow.orderFront(nil)
        defer { anchorWindow.orderOut(nil) }

        let panel = HeadroomPopupPanel(menu: menu)
        defer { panel.close() }
        panel._test_disablePointerMonitoring()
        panel.show(relativeTo: anchorView)
        panel.hostingController.view.layoutSubtreeIfNeeded()

        let scrollView = try #require(Self.findScrollView(in: panel.hostingController.view))
        let row = try #require(Self.findMenuStacks(in: panel.hostingController.view).first?.rowViews.first)
        #expect(row.enclosingScrollView === scrollView)
        #expect(scrollView.documentView?.frame.height ?? 0 > scrollView.contentView.bounds.height)
        let initialOrigin = scrollView.contentView.bounds.origin
        let event = try #require(Self.makeScrollEvent(deltaY: -8))

        row.scrollWheel(with: event)
        panel.hostingController.view.layoutSubtreeIfNeeded()

        #expect(scrollView.contentView.bounds.origin.y > initialOrigin.y)
    }

    @Test
    func `scroll wheel received by the SwiftUI card host moves the popup viewport`() throws {
        let menu = Self.makeMenu(rowHeights: Array(repeating: 80, count: 24))
        let highlightState = MenuCardHighlightState()
        let cardHost = MenuCardItemHostingView(
            rootView: Button("Hosted card") {},
            highlightState: highlightState,
            allowsMenuHighlight: true,
            containsInteractiveControls: true)
        cardHost.frame = NSRect(x: 0, y: 0, width: 320, height: 80)
        menu.items[0].view = cardHost

        let anchorWindow = NSWindow(
            contentRect: NSRect(x: 100, y: 400, width: 80, height: 40),
            styleMask: .borderless,
            backing: .buffered,
            defer: false)
        let anchorView = NSView(frame: NSRect(x: 20, y: 10, width: 20, height: 20))
        anchorWindow.contentView?.addSubview(anchorView)
        anchorWindow.orderFront(nil)
        defer { anchorWindow.orderOut(nil) }

        let panel = HeadroomPopupPanel(menu: menu)
        defer { panel.close() }
        panel._test_disablePointerMonitoring()
        panel.show(relativeTo: anchorView)
        panel.hostingController.view.layoutSubtreeIfNeeded()

        let scrollView = try #require(Self.findScrollView(in: panel.hostingController.view))
        #expect(panel.isScrollMonitoringForTesting)
        #expect(cardHost.enclosingScrollView === scrollView)
        #expect(scrollView.documentView?.frame.height ?? 0 > scrollView.contentView.bounds.height)
        let initialOrigin = scrollView.contentView.bounds.origin
        let event = try #require(Self.makeScrollEvent(deltaY: -8))

        let handled = panel.routeScrollWheel(event)
        panel.hostingController.view.layoutSubtreeIfNeeded()

        #expect(handled)
        #expect(scrollView.contentView.bounds.origin.y > initialOrigin.y)
    }

    @Test
    func `popup placement selects secondary display when menu bar anchor sits above visibleFrame`() {
        let frame = HeadroomPopupPlacement.frame(
            contentSize: NSSize(width: 360, height: 400),
            anchorFrame: NSRect(x: 2400, y: 1055, width: 24, height: 24),
            visibleFrames: [
                NSRect(x: 0, y: 0, width: 1920, height: 1050),
                NSRect(x: 1920, y: 0, width: 1920, height: 1050),
            ])

        #expect(frame == NSRect(x: 2064, y: 642, width: 360, height: 400))
    }

    @Test
    func `clamped pinned placement preserves top left while bounding height inside safe frame`() {
        let frame = HeadroomPopupPlacement.clampedPinnedFrame(
            currentFrame: NSRect(x: 220, y: 300, width: 360, height: 400),
            preferredViewportSize: NSSize(width: 360, height: 1400),
            visibleFrames: [NSRect(x: 0, y: 0, width: 1200, height: 900)])

        #expect(frame == NSRect(x: 220, y: 8, width: 360, height: 884))
    }

    @Test
    func `open and pinned popup updates clamp viewport and preserve scroll offset`() throws {
        let initialMenu = Self.makeMenu(rowHeights: Array(repeating: 90, count: 24))
        let anchorWindow = NSWindow(
            contentRect: NSRect(x: 160, y: 400, width: 80, height: 40),
            styleMask: .borderless,
            backing: .buffered,
            defer: false)
        let anchorView = NSView(frame: NSRect(x: 20, y: 10, width: 20, height: 20))
        anchorWindow.contentView?.addSubview(anchorView)
        anchorWindow.orderFront(nil)
        defer { anchorWindow.orderOut(nil) }

        let panel = HeadroomPopupPanel(menu: initialMenu)
        defer { panel.close() }
        panel._test_disablePointerMonitoring()
        panel.show(relativeTo: anchorView)
        panel.hostingController.view.layoutSubtreeIfNeeded()

        let scrollView = try #require(Self.findScrollView(in: panel.hostingController.view))
        let event = try #require(Self.makeScrollEvent(deltaY: -6))
        #expect(panel.routeScrollWheel(event))
        panel.hostingController.view.layoutSubtreeIfNeeded()
        let scrolledOriginY = scrollView.contentView.bounds.origin.y
        #expect(scrolledOriginY > 0)

        let updatedMenu = Self.makeMenu(rowHeights: Array(repeating: 92, count: 24))
        panel.update(menu: updatedMenu)
        panel.hostingController.view.layoutSubtreeIfNeeded()
        if let maxVisibleHeight = NSScreen.screens.map(\.visibleFrame.height).max() {
            #expect(panel.frame.height <= maxVisibleHeight)
        }
        let popupScrollView = try #require(Self.findScrollView(in: panel.hostingController.view))
        #expect(popupScrollView.contentView.bounds.origin.y == scrolledOriginY)

        panel.togglePinned()
        let pinnedMenu = Self.makeMenu(rowHeights: Array(repeating: 94, count: 24))
        panel.update(menu: pinnedMenu)
        panel.hostingController.view.layoutSubtreeIfNeeded()
        if let maxVisibleHeight = NSScreen.screens.map(\.visibleFrame.height).max() {
            #expect(panel.frame.height <= maxVisibleHeight)
        }
        let pinnedScrollView = try #require(Self.findScrollView(in: panel.hostingController.view))
        #expect(pinnedScrollView.contentView.bounds.origin.y == scrolledOriginY)
    }

    @Test
    func `scroll cancels a native submenu and moves the viewport in the same event`() throws {
        let menu = Self.makeMenu(rowHeights: Array(repeating: 80, count: 24))
        let submenu = RecordingPopupMenu()
        menu.items[0].submenu = submenu
        let panel = HeadroomPopupPanel(menu: menu)
        defer { panel.close() }
        panel._test_disablePointerMonitoring()
        let anchorWindow = NSWindow(
            contentRect: NSRect(x: 100, y: 400, width: 80, height: 40),
            styleMask: .borderless,
            backing: .buffered,
            defer: false)
        let anchor = NSView(frame: NSRect(x: 20, y: 10, width: 20, height: 20))
        anchorWindow.contentView?.addSubview(anchor)
        anchorWindow.orderFront(nil)
        defer { anchorWindow.orderOut(nil) }
        panel.show(relativeTo: anchor)
        panel.hostingController.view.layoutSubtreeIfNeeded()
        let scrollView = try #require(Self.findScrollView(in: panel.hostingController.view))
        let stack = try #require(Self.findMenuStacks(in: panel.hostingController.view).first)
        let row = try #require(stack.rowViews.first as? HeadroomPopupMenuRowView)
        let menuWindow = HeadroomScrollTestMenuWindow(
            contentRect: panel.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false)
        menuWindow.level = .popUpMenu
        let unrelatedWindow = NSWindow(
            contentRect: panel.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false)
        let point = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let event = try #require(Self.makeScrollEvent(deltaY: -8))
        let initialOrigin = scrollView.contentView.bounds.origin.y
        submenu.onPopUp = {
            #expect(!panel.shouldRouteScrollWheel(from: unrelatedWindow, at: point))
            #expect(panel.shouldRouteScrollWheel(from: menuWindow, at: point))
            #expect(panel.routeScrollWheel(event))
            #expect(submenu.cancelCount == 1)
        }
        row.openSubmenu()
        #expect(scrollView.contentView.bounds.origin.y > initialOrigin)
        #expect(submenu.popUpCount == 1)
        row.updateHover(isInside: true)
        row.openSubmenu()
        #expect(submenu.popUpCount == 1)
        #expect(!stack.hasActivePresentedSubmenu)
    }

    @Test
    func `popup hit testing preserves a primary action in an offset row`() throws {
        let menu = Self.makeMenu(rowHeights: [80, 44])
        let card = MenuCardItemHostingView(
            rootView: Text("Second card"),
            highlightState: MenuCardHighlightState(),
            allowsMenuHighlight: true,
            onClick: {})
        card.frame = NSRect(x: 0, y: 0, width: 360, height: 44)
        menu.items[1].view = card
        menu.items[1].submenu = RecordingPopupMenu()
        let stack = HeadroomPopupMenuStackView(menu: menu)
        stack.frame = NSRect(origin: .zero, size: stack.contentSize)
        stack.layoutSubtreeIfNeeded()
        let row = try #require(stack.rowViews.last)
        #expect(row.frame.minY > 0)
        let point = stack.convert(NSPoint(x: card.bounds.midX, y: card.bounds.midY), from: card)
        #expect(row.hitTest(point) === card)
    }

    private static func makeMenu(rowHeights: [CGFloat]) -> NSMenu {
        let menu = NSMenu()
        for (index, height) in rowHeights.enumerated() {
            let item = NSMenuItem()
            item.representedObject = "row-\(index)"
            item.view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: height))
            menu.addItem(item)
        }
        return menu
    }

    private static func findToolbar(in view: NSView) -> HeadroomPopupToolbarView? {
        if let toolbar = view as? HeadroomPopupToolbarView {
            return toolbar
        }
        for subview in view.subviews {
            if let toolbar = self.findToolbar(in: subview) {
                return toolbar
            }
        }
        return nil
    }

    private static func findToolbars(in view: NSView) -> [HeadroomPopupToolbarView] {
        var result = [view as? HeadroomPopupToolbarView].compactMap(\.self)
        for subview in view.subviews {
            result.append(contentsOf: self.findToolbars(in: subview))
        }
        return result
    }

    private static func findProviderSwitcher(in view: NSView) -> ProviderSwitcherView? {
        if let switcher = view as? ProviderSwitcherView {
            return switcher
        }
        for subview in view.subviews {
            if let switcher = self.findProviderSwitcher(in: subview) {
                return switcher
            }
        }
        return nil
    }

    private static func findMenuStacks(in view: NSView) -> [HeadroomPopupMenuStackView] {
        var result = [view as? HeadroomPopupMenuStackView].compactMap(\.self)
        for subview in view.subviews {
            result.append(contentsOf: self.findMenuStacks(in: subview))
        }
        return result
    }

    private static func findScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView {
            return scrollView
        }
        for subview in view.subviews {
            if let scrollView = self.findScrollView(in: subview) {
                return scrollView
            }
        }
        return nil
    }

    private static func makeScrollEvent(deltaY: Double) -> NSEvent? {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: Int32(deltaY),
            wheel2: 0,
            wheel3: 0)
        else {
            return nil
        }
        return NSEvent(cgEvent: event)
    }

    private static func makeController(popupPanelEnabled: Bool) throws -> StatusItemController {
        let suite = "HeadroomPopupPanelTests-controller-\(UUID().uuidString)"
        let settings = testSettingsStore(suiteName: suite)
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.providerDetectionCompleted = true
        for provider in [UsageProvider.codex, .claude] {
            let metadata = ProviderDescriptorRegistry.descriptor(for: provider).metadata
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: true)
        }
        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        return StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system,
            popupPanelEnabled: popupPanelEnabled)
    }
}

@MainActor
private final class RecordingPopupMenu: NSMenu {
    private(set) nonisolated(unsafe) var popUpCount = 0
    private(set) nonisolated(unsafe) var cancelCount = 0
    nonisolated(unsafe) var onPopUp: (@MainActor () -> Void)?

    override func cancelTrackingWithoutAnimation() {
        self.cancelCount += 1
    }

    override func popUp(positioning item: NSMenuItem?, at location: NSPoint, in view: NSView?) -> Bool {
        self.popUpCount += 1
        let onPopUp = self.onPopUp
        MainActor.assumeIsolated { onPopUp?() }
        return true
    }
}

@MainActor
private final class HeadroomScrollTestMenuWindow: NSWindow {}
