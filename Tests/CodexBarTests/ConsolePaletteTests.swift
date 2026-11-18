import Foundation
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct ConsolePaletteTests {
    @Test
    func `all five palettes expose the specified color tokens`() {
        let expected: [ConsolePalette: [UInt32]] = [
            .consoleBlue: [
                0x151516, 0x1C1C1D, 0x232325, 0x2C2C2E, 0x313235,
                0x5E9FE8, 0x72BC8F, 0xE0B15E, 0xD96A6A,
                0xEEEFF1, 0x9A9BA0, 0x68696E,
                0x5E9FE8, 0xBF8EDA, 0x4FB9C9, 0xE0B15E,
            ],
            .slateTeal: [
                0x101314, 0x171B1C, 0x1E2426, 0x283032, 0x2E3739,
                0x4FB9C9, 0x6FBF9B, 0xE3B96A, 0xE07A6E,
                0xE9EFF0, 0x93A2A4, 0x647275,
                0x4FB9C9, 0x6FBF9B, 0x7FA8E8, 0xE3B96A,
            ],
            .nocturne: [
                0x131218, 0x1A1922, 0x221F2C, 0x2E2A3A, 0x352F44,
                0x9B8CF0, 0x6FC59C, 0xE6B45E, 0xE0708F,
                0xEDEBF4, 0x9C98AC, 0x6B6779,
                0x9B8CF0, 0x6FA8F5, 0xDF84A8, 0x6FC59C,
            ],
            .amberGraphite: [
                0x151412, 0x1C1A18, 0x232120, 0x2E2B27, 0x35322D,
                0xDE9255, 0x86BE8E, 0xE8C36B, 0xD9695F,
                0xF1EFEB, 0xA09B92, 0x6F6A62,
                0xDE9255, 0xE8C36B, 0x86BE8E, 0x6FA3DE,
            ],
            .daylight: [
                0xF2F1EF, 0xFFFFFF, 0xF7F6F4, 0xE2E0DC, 0xE7E5E1,
                0x2783DE, 0x46A171, 0xC8862F, 0xD0544A,
                0x23231F, 0x6E6B65, 0x94908A,
                0x2783DE, 0x7A5BD0, 0x1F9AA8, 0xC8862F,
            ],
        ]

        #expect(ConsolePalette.allCases.count == 5)
        for palette in ConsolePalette.allCases {
            let tokens = palette.tokens
            #expect([
                tokens.background.hex,
                tokens.surface.hex,
                tokens.surface2.hex,
                tokens.border.hex,
                tokens.track.hex,
                tokens.accent.hex,
                tokens.positive.hex,
                tokens.caution.hex,
                tokens.critical.hex,
                tokens.primaryText.hex,
                tokens.secondaryText.hex,
                tokens.tertiaryText.hex,
            ] + tokens.series.map(\.hex) == expected[palette])
        }
    }

    @Test
    func `console blue is the default and palette persists`() throws {
        let suite = "ConsolePaletteTests-persistence"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        #expect(store.consolePalette == .consoleBlue)
        #expect(defaults.string(forKey: ConsolePalette.userDefaultsKey) == nil)

        store.consolePalette = .amberGraphite
        let reloaded = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        #expect(reloaded.consolePalette == .amberGraphite)
        #expect(defaults.string(forKey: ConsolePalette.userDefaultsKey) == ConsolePalette.amberGraphite.rawValue)
    }

    @Test
    func `unknown stored palette falls back to console blue`() throws {
        let suite = "ConsolePaletteTests-unknown"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set("future-palette", forKey: ConsolePalette.userDefaultsKey)
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        #expect(store.consolePalette == .consoleBlue)
    }

    @Test
    func `only daylight requests a light color scheme`() {
        for palette in ConsolePalette.allCases {
            #expect(palette.preferredColorScheme == (palette == .daylight ? .light : .dark))
            #expect(palette.accentSoftOpacity == (palette == .daylight ? 0.10 : 0.13))
        }
    }

    @Test
    func `meter severity respects whether percent means used or remaining`() {
        #expect(ConsoleSegmentedMeter.severity(percent: 80, mode: .used) == .caution)
        #expect(ConsoleSegmentedMeter.severity(percent: 80, mode: .remaining) == .positive)
        #expect(ConsoleSegmentedMeter.severity(percent: 20, mode: .remaining) == .caution)
        #expect(ConsoleSegmentedMeter.severity(percent: 0, mode: .remaining) == .critical)
        #expect(ConsoleSegmentedMeter.severity(percent: 100, mode: .used) == .critical)
    }

    @Test
    func `primary secondary and daylight foreground text meet AA contrast`() {
        for palette in ConsolePalette.allCases {
            let tokens = palette.tokens
            for background in [tokens.background, tokens.surface, tokens.surface2] {
                #expect(Self.contrast(tokens.primaryText, background) >= 4.5)
                #expect(Self.contrast(tokens.secondaryText, background) >= 4.5)
            }
        }

        let daylight = ConsolePalette.daylight
        let surface = daylight.tokens.surface
        #expect(Self.contrast(daylight.accentForeground, surface) >= 4.5)
        #expect(Self.contrast(daylight.positiveForeground, surface) >= 4.5)
        #expect(Self.contrast(daylight.cautionForeground, surface) >= 4.5)
        #expect(Self.contrast(daylight.criticalForeground, surface) >= 4.5)
        #expect(Self.contrast(daylight.tertiaryForeground, surface) >= 4.5)
    }

    private static func contrast(_ lhs: ConsoleColorToken, _ rhs: ConsoleColorToken) -> Double {
        let high = max(self.luminance(lhs), self.luminance(rhs))
        let low = min(self.luminance(lhs), self.luminance(rhs))
        return (high + 0.05) / (low + 0.05)
    }

    private static func luminance(_ token: ConsoleColorToken) -> Double {
        let channels = [16, 8, 0].map { shift in
            let component = Double((token.hex >> UInt32(shift)) & 0xFF) / 255
            return component <= 0.03928 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    }
}
