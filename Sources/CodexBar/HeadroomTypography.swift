import AppKit
import SwiftUI

enum HeadroomTypography {
    static let menuBarStackedLineHeight: CGFloat = 9.5
    static let menuBarStackedLineSpacing: CGFloat = -1
    static let menuBarStackedBaselineOffset: CGFloat = -3
    static let relayStatusItemBaselineOffset: CGFloat = -1

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        for face in self.preferredFaces(for: weight) where NSFont(name: face, size: size) != nil {
            return .custom(face, size: size)
        }
        return .system(size: size, weight: weight, design: .monospaced)
    }

    static func nsMono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        for face in self.preferredFaces(for: weight) {
            if let font = NSFont(name: face, size: size) {
                return font
            }
        }
        return .monospacedSystemFont(ofSize: size, weight: weight)
    }

    static func text(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func menuBarFont(size: MenuBarLayoutSize, isStacked: Bool) -> NSFont {
        NSFont.systemFont(ofSize: self.menuBarFontSize(size: size, isStacked: isStacked))
    }

    static func menuBarFontSize(size: MenuBarLayoutSize, isStacked: Bool) -> CGFloat {
        if isStacked {
            return size == .small ? 8 : 9
        }
        return size == .small ? 11 : NSFont.systemFontSize
    }

    private static func preferredFaces(for weight: Font.Weight) -> [String] {
        switch weight {
        case .black, .heavy:
            ["BerkeleyMono-Black", "BerkeleyMono-Bold", "BerkeleyMono-Regular"]
        case .bold, .semibold:
            ["BerkeleyMono-Bold", "BerkeleyMono-Semibold", "BerkeleyMono-Regular"]
        case .medium:
            ["BerkeleyMono-Medium", "BerkeleyMono-Regular"]
        case .light, .ultraLight, .thin:
            ["BerkeleyMono-Light", "BerkeleyMono-Regular"]
        default:
            ["BerkeleyMono-Regular"]
        }
    }

    private static func preferredFaces(for weight: NSFont.Weight) -> [String] {
        switch weight {
        case .black, .heavy:
            ["BerkeleyMono-Black", "BerkeleyMono-Bold", "BerkeleyMono-Regular"]
        case .bold, .semibold:
            ["BerkeleyMono-Bold", "BerkeleyMono-Semibold", "BerkeleyMono-Regular"]
        case .medium:
            ["BerkeleyMono-Medium", "BerkeleyMono-Regular"]
        case .light, .ultraLight, .thin:
            ["BerkeleyMono-Light", "BerkeleyMono-Regular"]
        default:
            ["BerkeleyMono-Regular"]
        }
    }
}
