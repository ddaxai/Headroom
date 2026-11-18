import AppKit
import CodexBarCore
import Foundation
import SwiftUI

struct ConsoleColorToken: Equatable, Sendable {
    let hex: UInt32

    var color: Color {
        Color(
            red: Double((self.hex >> 16) & 0xFF) / 255,
            green: Double((self.hex >> 8) & 0xFF) / 255,
            blue: Double(self.hex & 0xFF) / 255)
    }

    var nsColor: NSColor {
        NSColor(
            srgbRed: CGFloat((self.hex >> 16) & 0xFF) / 255,
            green: CGFloat((self.hex >> 8) & 0xFF) / 255,
            blue: CGFloat(self.hex & 0xFF) / 255,
            alpha: 1)
    }
}

struct ConsoleTokens: Equatable, Sendable {
    let background: ConsoleColorToken
    let surface: ConsoleColorToken
    let surface2: ConsoleColorToken
    let border: ConsoleColorToken
    let track: ConsoleColorToken
    let accent: ConsoleColorToken
    let positive: ConsoleColorToken
    let caution: ConsoleColorToken
    let critical: ConsoleColorToken
    let primaryText: ConsoleColorToken
    let secondaryText: ConsoleColorToken
    let tertiaryText: ConsoleColorToken
    let series: [ConsoleColorToken]

    init(
        background: UInt32,
        surface: UInt32,
        surface2: UInt32,
        border: UInt32,
        track: UInt32,
        accent: UInt32,
        positive: UInt32,
        caution: UInt32,
        critical: UInt32,
        primaryText: UInt32,
        secondaryText: UInt32,
        tertiaryText: UInt32,
        series: [UInt32])
    {
        self.background = ConsoleColorToken(hex: background)
        self.surface = ConsoleColorToken(hex: surface)
        self.surface2 = ConsoleColorToken(hex: surface2)
        self.border = ConsoleColorToken(hex: border)
        self.track = ConsoleColorToken(hex: track)
        self.accent = ConsoleColorToken(hex: accent)
        self.positive = ConsoleColorToken(hex: positive)
        self.caution = ConsoleColorToken(hex: caution)
        self.critical = ConsoleColorToken(hex: critical)
        self.primaryText = ConsoleColorToken(hex: primaryText)
        self.secondaryText = ConsoleColorToken(hex: secondaryText)
        self.tertiaryText = ConsoleColorToken(hex: tertiaryText)
        self.series = series.map(ConsoleColorToken.init(hex:))
    }
}

enum ConsolePalette: String, CaseIterable, Codable, Identifiable, Sendable {
    static let userDefaultsKey = "consolePalette"

    case consoleBlue
    case slateTeal
    case nocturne
    case amberGraphite
    case daylight

    var id: String {
        self.rawValue
    }

    var displayName: String {
        switch self {
        case .consoleBlue: L("console_palette_console_blue")
        case .slateTeal: L("console_palette_slate_teal")
        case .nocturne: L("console_palette_nocturne")
        case .amberGraphite: L("console_palette_amber_graphite")
        case .daylight: L("console_palette_daylight")
        }
    }

    var preferredColorScheme: ColorScheme {
        self == .daylight ? .light : .dark
    }

    var accentSoftOpacity: Double {
        self == .daylight ? 0.10 : 0.13
    }

    /// Daylight's exact semantic colors are intended for fills, borders and charts. Its
    /// high-contrast foregrounds keep small labels above the WCAG AA text threshold.
    var accentForeground: ConsoleColorToken {
        self == .daylight ? self.tokens.primaryText : self.tokens.accent
    }

    var positiveForeground: ConsoleColorToken {
        self == .daylight ? self.tokens.primaryText : self.tokens.positive
    }

    var cautionForeground: ConsoleColorToken {
        self == .daylight ? self.tokens.primaryText : self.tokens.caution
    }

    var criticalForeground: ConsoleColorToken {
        self == .daylight ? self.tokens.primaryText : self.tokens.critical
    }

    var tertiaryForeground: ConsoleColorToken {
        self == .daylight ? self.tokens.secondaryText : self.tokens.tertiaryText
    }

    var tokens: ConsoleTokens {
        switch self {
        case .consoleBlue:
            ConsoleTokens(
                background: 0x151516,
                surface: 0x1C1C1D,
                surface2: 0x232325,
                border: 0x2C2C2E,
                track: 0x313235,
                accent: 0x5E9FE8,
                positive: 0x72BC8F,
                caution: 0xE0B15E,
                critical: 0xD96A6A,
                primaryText: 0xEEEFF1,
                secondaryText: 0x9A9BA0,
                tertiaryText: 0x68696E,
                series: [0x5E9FE8, 0xBF8EDA, 0x4FB9C9, 0xE0B15E])
        case .slateTeal:
            ConsoleTokens(
                background: 0x101314,
                surface: 0x171B1C,
                surface2: 0x1E2426,
                border: 0x283032,
                track: 0x2E3739,
                accent: 0x4FB9C9,
                positive: 0x6FBF9B,
                caution: 0xE3B96A,
                critical: 0xE07A6E,
                primaryText: 0xE9EFF0,
                secondaryText: 0x93A2A4,
                tertiaryText: 0x647275,
                series: [0x4FB9C9, 0x6FBF9B, 0x7FA8E8, 0xE3B96A])
        case .nocturne:
            ConsoleTokens(
                background: 0x131218,
                surface: 0x1A1922,
                surface2: 0x221F2C,
                border: 0x2E2A3A,
                track: 0x352F44,
                accent: 0x9B8CF0,
                positive: 0x6FC59C,
                caution: 0xE6B45E,
                critical: 0xE0708F,
                primaryText: 0xEDEBF4,
                secondaryText: 0x9C98AC,
                tertiaryText: 0x6B6779,
                series: [0x9B8CF0, 0x6FA8F5, 0xDF84A8, 0x6FC59C])
        case .amberGraphite:
            ConsoleTokens(
                background: 0x151412,
                surface: 0x1C1A18,
                surface2: 0x232120,
                border: 0x2E2B27,
                track: 0x35322D,
                accent: 0xDE9255,
                positive: 0x86BE8E,
                caution: 0xE8C36B,
                critical: 0xD9695F,
                primaryText: 0xF1EFEB,
                secondaryText: 0xA09B92,
                tertiaryText: 0x6F6A62,
                series: [0xDE9255, 0xE8C36B, 0x86BE8E, 0x6FA3DE])
        case .daylight:
            ConsoleTokens(
                background: 0xF2F1EF,
                surface: 0xFFFFFF,
                surface2: 0xF7F6F4,
                border: 0xE2E0DC,
                track: 0xE7E5E1,
                accent: 0x2783DE,
                positive: 0x46A171,
                caution: 0xC8862F,
                critical: 0xD0544A,
                primaryText: 0x23231F,
                secondaryText: 0x6E6B65,
                tertiaryText: 0x94908A,
                series: [0x2783DE, 0x7A5BD0, 0x1F9AA8, 0xC8862F])
        }
    }

    static func stored(in defaults: UserDefaults = CodexBarPreferences.processDefaults) -> ConsolePalette {
        guard let rawValue = defaults.string(forKey: self.userDefaultsKey) else { return .consoleBlue }
        return ConsolePalette(rawValue: rawValue) ?? .consoleBlue
    }
}
