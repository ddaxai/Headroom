import SwiftUI

extension EnvironmentValues {
    @Entry var menuItemHighlighted: Bool = false

    @Entry var menuCardRefreshMonitor: MenuCardRefreshMonitor?
}

enum MenuHighlightStyle {
    static var selectionText: Color {
        ConsoleDesign.primaryText
    }

    static var normalPrimaryText: Color {
        ConsoleDesign.primaryText
    }

    static var normalSecondaryText: Color {
        ConsoleDesign.secondaryText
    }

    static func primary(_ highlighted: Bool) -> Color {
        highlighted ? self.selectionText : self.normalPrimaryText
    }

    static func secondary(_ highlighted: Bool) -> Color {
        highlighted ? self.selectionText : self.normalSecondaryText
    }

    static func error(_ highlighted: Bool) -> Color {
        highlighted ? self.selectionText : ConsoleDesign.criticalForeground
    }

    static func progressTrack(_ highlighted: Bool) -> Color {
        ConsoleDesign.track
    }

    static func progressTint(_ highlighted: Bool, fallback _: Color) -> Color {
        ConsoleDesign.accent
    }

    static func selectionBackground(_ highlighted: Bool) -> Color {
        highlighted ? ConsoleDesign.surface2 : .clear
    }
}
