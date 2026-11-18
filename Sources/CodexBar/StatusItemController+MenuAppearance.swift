import AppKit

@MainActor
enum StatusMenuAppearance {
    static func pin(_ menu: NSMenu) {
        self.pin(menu, to: ConsoleDesign.nsAppearance)
    }

    static func pin(_ menu: NSMenu, to appearance: NSAppearance) {
        // The exact effective appearance carries accessibility attributes that its name can omit.
        menu.appearance = appearance
    }

    static func pin(
        _ window: NSWindow,
        to appearance: NSAppearance,
        backgroundColor: NSColor)
    {
        // AppKit creates the tracking window after menuWillOpen begins. Hosted rows are the first
        // reliable lifecycle point where that window is available, so correct both its appearance
        // and the exposed backing color here. Avoid assigning unchanged values on every row mount.
        if window.appearance?.bestMatch(from: [.aqua, .darkAqua]) !=
            appearance.bestMatch(from: [.aqua, .darkAqua])
        {
            window.appearance = appearance
        }
        if window.backgroundColor?.isEqual(backgroundColor) != true {
            window.backgroundColor = backgroundColor
        }
    }

    static func pinWindow(_ menu: NSMenu) {
        // NSMenu does not expose its private tracking window. Once menuWillOpen has fired,
        // hosted menu rows provide the public bridge back to that window.
        guard let window = menu.items.compactMap({ $0.view?.window }).first else { return }
        self.pin(
            window,
            to: menu.appearance ?? ConsoleDesign.nsAppearance,
            backgroundColor: ConsoleDesign.nsBackground)
    }
}
