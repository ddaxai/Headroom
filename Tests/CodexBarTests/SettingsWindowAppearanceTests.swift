import AppKit
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct SettingsWindowAppearanceTests {
    @Test
    func `settings panes get the full window width up to their maximum`() {
        #expect(SettingsPane.detailMaxWidth >= SettingsPane.windowMinWidth)
        #expect(SettingsPane.detailMaxWidth <= SettingsPane.windowWidth)
    }

    @Test
    func `every settings destination has a navigation tab icon and opens a regular pane`() {
        for destination in SettingsDestination.allCases {
            #expect(!destination.systemImage.isEmpty)
            #expect(NSImage(systemSymbolName: destination.systemImage, accessibilityDescription: nil) != nil)
            #expect(destination.defaultPane.destination == destination)
            #expect(destination.defaultPane.isRegularlyReachable)
        }
    }

    @Test
    nonisolated func `settings use top navigation and the relay list keeps its persisted split`() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let preferences = try String(
            contentsOf: root.appendingPathComponent("Sources/CodexBar/PreferencesView.swift"),
            encoding: .utf8)
        let relay = try String(
            contentsOf: root.appendingPathComponent("Sources/CodexBar/PreferencesRelayPane.swift"),
            encoding: .utf8)

        #expect(preferences.contains("SettingsNavigationBar("))
        #expect(!preferences.contains("NavigationSplitView"))
        #expect(relay.contains("HSplitView"))
        #expect(relay.contains("idealWidth: self.settings.relayListWidth"))
        #expect(relay.contains("self.settings.relayListWidth = width"))
    }

    @Test
    func `settings split widths persist and clamp across store recreation`() throws {
        let suite = "SettingsWindowAppearanceTests-split-widths-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let initial = SettingsStore(userDefaults: defaults, performInitialProviderDetection: false)
        #expect(initial.relayListWidth == 190)

        initial.relayListWidth = 20
        #expect(initial.relayListWidth == 150)

        let reloaded = SettingsStore(userDefaults: defaults, performInitialProviderDetection: false)
        #expect(reloaded.relayListWidth == 150)
        #expect(defaults.double(forKey: SettingsWindowLayout.relayListWidthKey) == 150)
    }

    @Test
    func `out of range persisted split widths are repaired while loading`() throws {
        let suite = "SettingsWindowAppearanceTests-repair-split-widths-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(800, forKey: SettingsWindowLayout.relayListWidthKey)

        let settings = SettingsStore(userDefaults: defaults, performInitialProviderDetection: false)

        #expect(settings.relayListWidth == 300)
        #expect(defaults.double(forKey: SettingsWindowLayout.relayListWidthKey) == 300)
    }

    @Test
    func `always on top defaults off and persists across store recreation`() throws {
        let suite = "SettingsWindowAppearanceTests-always-on-top-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let initial = SettingsStore(userDefaults: defaults, performInitialProviderDetection: false)
        #expect(!initial.windowAlwaysOnTop)

        initial.windowAlwaysOnTop = true

        let reloaded = SettingsStore(userDefaults: defaults, performInitialProviderDetection: false)
        #expect(reloaded.windowAlwaysOnTop)
        #expect(defaults.bool(forKey: SettingsWindowLayout.windowAlwaysOnTopKey))
    }

    @Test
    func `settings window sizing repairs collapsed saved frames`() {
        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 160, width: 180, height: 140),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        let originalMaxY = window.frame.maxY

        SettingsWindowSizing.enforceMinimumSize(window)

        #expect(window.minSize.width == SettingsPane.windowMinWidth)
        #expect(window.minSize.height >= SettingsPane.windowMinHeight)
        #expect(window.frame.width >= window.minSize.width)
        #expect(window.frame.height >= window.minSize.height)
        #expect(abs(window.frame.maxY - originalMaxY) < 1)
    }

    @Test
    func `settings window sizing leaves valid frames alone`() {
        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 160, width: SettingsPane.windowWidth, height: SettingsPane.windowHeight),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        let originalFrame = window.frame

        SettingsWindowSizing.enforceMinimumSize(window)

        #expect(window.frame == originalFrame)
        #expect(window.minSize.width == SettingsPane.windowMinWidth)
        #expect(window.minSize.height >= SettingsPane.windowMinHeight)
    }

    @Test
    func `settings window sizing does not mutate content split views`() {
        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 160, width: 180, height: 140),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        let splitView = NSSplitView(
            frame: NSRect(x: 0, y: 0, width: SettingsPane.windowWidth, height: SettingsPane.windowHeight))
        splitView.isVertical = true
        let sidebar = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: SettingsPane.windowHeight))
        let detail = NSView(
            frame: NSRect(x: 0, y: 0, width: SettingsPane.windowWidth, height: SettingsPane.windowHeight))
        splitView.addSubview(sidebar)
        splitView.addSubview(detail)
        window.contentView = splitView

        SettingsWindowSizing.enforceMinimumSize(window)

        #expect(window.frame.width >= window.minSize.width)
        #expect(sidebar.frame.width == 0)
    }

    @Test
    func `bridge pins the settings window to the selected palette appearance`() {
        let application = NSApplication.shared
        let staleSource = NSView()
        staleSource.appearance = NSAppearance(named: .aqua)
        let resetCapture = ResetCapture()
        let bridge = SettingsWindowAppearanceView { resetCapture.actions.append($0) }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.appearanceSource = staleSource
        window.contentView = bridge

        let pulseMatchesConsoleAppearance = window.appearance?.bestMatch(from: [.darkAqua]) == .darkAqua
        let sourceIsApplication = (window.appearanceSource as AnyObject?) === application
        #expect(pulseMatchesConsoleAppearance)
        #expect(sourceIsApplication)
        #expect(resetCapture.actions.count == 1)

        resetCapture.actions[0]()

        #expect(window.appearance?.bestMatch(from: [.darkAqua]) == .darkAqua)
        #expect(window.viewsNeedDisplay)

        bridge.refreshWindowAppearance(for: .light)
        resetCapture.actions.removeAll()
        #expect(window.appearance?.bestMatch(from: [.aqua]) == .aqua)
    }

    @Test
    func `bridge updates window title without pulsing appearance on pane changes`() {
        let resetCapture = ResetCapture()
        let bridge = SettingsWindowAppearanceView { resetCapture.actions.append($0) }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.contentView = bridge
        resetCapture.actions.removeAll()

        bridge.refreshWindowAppearance(for: .light, windowTitle: "Display")
        #expect(resetCapture.actions.count == 1)

        bridge.refreshWindowAppearance(for: .light, windowTitle: "General")

        #expect(window.title == "General")
        #expect(resetCapture.actions.count == 1)
    }

    @Test
    func `settings window style remains resizable`() {
        let bridge = SettingsWindowAppearanceView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)

        window.contentView = bridge

        #expect(window.styleMask.contains(.resizable))
    }

    @Test
    func `bridge applies and clears the persisted always on top level`() {
        let bridge = SettingsWindowAppearanceView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.contentView = bridge

        bridge.refreshWindowAppearance(for: .dark, windowTitle: "General", windowAlwaysOnTop: true)
        #expect(window.level == .floating)

        bridge.refreshWindowAppearance(for: .dark, windowTitle: "General", windowAlwaysOnTop: false)
        #expect(window.level == .normal)
    }

    @Test
    func `bridge applies always on top state when the settings window attaches after restoration`() {
        let bridge = SettingsWindowAppearanceView()
        bridge.refreshWindowAppearance(for: .dark, windowTitle: "General", windowAlwaysOnTop: true)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)

        window.contentView = bridge

        #expect(window.level == .floating)
        #expect(window.title == "General")
    }

    @Test
    func `window style leaves unrelated toolbar ownership alone`() {
        let bridge = SettingsWindowAppearanceView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        let toolbar = NSToolbar(identifier: "SettingsWindowAppearanceTests-toolbar")
        window.toolbar = toolbar

        window.contentView = bridge

        #expect(window.toolbar === toolbar)
    }

    @Test
    func `settings window extends content behind the titlebar for the edge-to-edge sidebar`() {
        let bridge = SettingsWindowAppearanceView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)

        window.contentView = bridge

        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.titlebarAppearsTransparent)
    }

    @Test
    func `repeated theme updates cannot leave an explicit appearance`() {
        let resetCapture = ResetCapture()
        let bridge = SettingsWindowAppearanceView { resetCapture.actions.append($0) }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.contentView = bridge

        bridge.refreshWindowAppearance(for: .light)
        bridge.refreshWindowAppearance(for: .light)
        bridge.refreshWindowAppearance(for: .dark)
        #expect(resetCapture.actions.count == 3)
        for action in resetCapture.actions {
            action()
        }

        let sourceIsApplication = (window.appearanceSource as AnyObject?) === NSApplication.shared
        #expect(window.appearance?.bestMatch(from: [.darkAqua]) == .darkAqua)
        #expect(sourceIsApplication)
    }
}

@MainActor
private final class ResetCapture {
    var actions: [SettingsWindowAppearance.ResetAction] = []
}
