import AppKit
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct StatusMenuAppearanceTests {
    private final class AppearanceTrackingMenu: NSMenu {
        var appearanceAssignmentCount = 0

        override var appearance: NSAppearance? {
            didSet {
                self.appearanceAssignmentCount += 1
            }
        }
    }

    @Test
    func `pin uses the exact selected console appearance`() {
        let menu = NSMenu()
        let consoleAppearance = ConsoleDesign.nsAppearance

        StatusMenuAppearance.pin(menu)

        #expect(menu.appearance?.bestMatch(from: [.aqua, .darkAqua]) ==
            consoleAppearance.bestMatch(from: [.aqua, .darkAqua]))
    }

    @Test
    func `palette appearance is light only for daylight`() {
        for palette in ConsolePalette.allCases {
            let appearance = ConsoleDesign.nsAppearance(for: palette)
            let expected: NSAppearance.Name = palette == .daylight ? .aqua : .darkAqua
            #expect(appearance.bestMatch(from: [.aqua, .darkAqua]) == expected)
        }
    }

    @Test
    func `pin reassigns an appearance even when its name is unchanged`() throws {
        let menu = AppearanceTrackingMenu()
        let appearance = try #require(NSAppearance(named: .aqua))
        menu.appearance = appearance
        let assignmentsBeforePin = menu.appearanceAssignmentCount

        StatusMenuAppearance.pin(menu, to: appearance)

        #expect(menu.appearance === appearance)
        #expect(menu.appearanceAssignmentCount == assignmentsBeforePin + 1)
    }

    @Test
    func `submenus inherit each refreshed root appearance`() throws {
        let menu = NSMenu()
        let submenu = NSMenu()
        let item = NSMenuItem(title: "Details", action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)

        let lightAppearance = try #require(NSAppearance(named: .aqua))
        StatusMenuAppearance.pin(menu, to: lightAppearance)
        #expect(menu.appearance === lightAppearance)
        #expect(submenu.appearance == nil)
        #expect(submenu.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)

        let darkAppearance = try #require(NSAppearance(named: .darkAqua))
        StatusMenuAppearance.pin(menu, to: darkAppearance)
        #expect(menu.appearance === darkAppearance)
        #expect(submenu.appearance == nil)
        #expect(submenu.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    }

    @Test
    func `hosting view attachment repairs the tracking window appearance`() throws {
        let expectedAppearance = ConsoleDesign.nsAppearance
        let expectedMatch = expectedAppearance.bestMatch(from: [.aqua, .darkAqua])
        let wrongName: NSAppearance.Name = expectedMatch == .aqua ? .darkAqua : .aqua
        let wrongAppearance = try #require(NSAppearance(named: wrongName))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.appearance = wrongAppearance

        let hosting = MenuHostingView(rootView: EmptyView())
        window.contentView?.addSubview(hosting)

        #expect(window.appearance?.bestMatch(from: [.aqua, .darkAqua]) == expectedMatch)
        #expect(window.backgroundColor.usingColorSpace(.sRGB) == ConsoleDesign.nsBackground.usingColorSpace(.sRGB))
    }
}
