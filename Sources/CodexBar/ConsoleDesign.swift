import AppKit
import SwiftUI

enum ConsoleDesign {
    static var palette: ConsolePalette {
        ConsolePalette.stored()
    }

    static var tokens: ConsoleTokens {
        self.palette.tokens
    }

    static var preferredColorScheme: ColorScheme {
        self.palette.preferredColorScheme
    }

    @MainActor
    static func nsAppearance(for palette: ConsolePalette) -> NSAppearance {
        let name: NSAppearance.Name = palette == .daylight ? .aqua : .darkAqua
        return NSAppearance(named: name) ?? NSApplication.shared.effectiveAppearance
    }

    @MainActor
    static var nsAppearance: NSAppearance {
        self.nsAppearance(for: self.palette)
    }

    static var background: Color {
        self.tokens.background.color
    }

    static var surface: Color {
        self.tokens.surface.color
    }

    static var surface2: Color {
        self.tokens.surface2.color
    }

    static var border: Color {
        self.tokens.border.color
    }

    static var track: Color {
        self.tokens.track.color
    }

    static var accent: Color {
        self.tokens.accent.color
    }

    static var accentSoft: Color {
        self.accent.opacity(self.palette.accentSoftOpacity)
    }

    static var accentForeground: Color {
        self.palette.accentForeground.color
    }

    static var positive: Color {
        self.tokens.positive.color
    }

    static var positiveForeground: Color {
        self.palette.positiveForeground.color
    }

    static var caution: Color {
        self.tokens.caution.color
    }

    static var cautionForeground: Color {
        self.palette.cautionForeground.color
    }

    static var critical: Color {
        self.tokens.critical.color
    }

    static var criticalForeground: Color {
        self.palette.criticalForeground.color
    }

    static var primaryText: Color {
        self.tokens.primaryText.color
    }

    static var secondaryText: Color {
        self.tokens.secondaryText.color
    }

    static var tertiaryText: Color {
        self.tokens.tertiaryText.color
    }

    static var tertiaryForeground: Color {
        self.palette.tertiaryForeground.color
    }

    static var providerSeries: [Color] {
        self.tokens.series.map(\.color)
    }

    static let radiusCard: CGFloat = 6
    static let radiusControl: CGFloat = 4
    static let radiusChip: CGFloat = 3
    static let radiusMeter: CGFloat = 1.5

    // Keep AppKit menu rows and SwiftUI cards on the same horizontal grid.
    static let menuHorizontalInset: CGFloat = 6
    static let menuRowLeadingPadding: CGFloat = 14
    static let menuRowTrailingPadding: CGFloat = 10
    static let menuRowIconSize: CGFloat = 16
    static let menuRowIconTitleSpacing: CGFloat = 8
    static let menuRowSelectionHorizontalInset: CGFloat = 5
    static let menuRowSelectionVerticalInset: CGFloat = 1
    static let menuRowTitleShortcutGap: CGFloat = 8
    static let menuChevronPointSize: CGFloat = 11
    static let menuChevronHitSize: CGFloat = 22
    static let menuChevronTrailingInset: CGFloat = 10

    /// AppKit views used by the provider switcher and menu footer cannot consume SwiftUI Color
    /// directly. Keep the same tokens in one place so native and SwiftUI surfaces do not drift.
    static var nsBackground: NSColor {
        self.tokens.background.nsColor
    }

    static var nsSurface: NSColor {
        self.tokens.surface.nsColor
    }

    static var nsSurface2: NSColor {
        self.tokens.surface2.nsColor
    }

    static var nsBorder: NSColor {
        self.tokens.border.nsColor
    }

    static var nsTrack: NSColor {
        self.tokens.track.nsColor
    }

    static var nsAccent: NSColor {
        self.tokens.accent.nsColor
    }

    static var nsAccentForeground: NSColor {
        self.palette.accentForeground.nsColor
    }

    static var nsPositive: NSColor {
        self.tokens.positive.nsColor
    }

    static var nsCaution: NSColor {
        self.tokens.caution.nsColor
    }

    static var nsCritical: NSColor {
        self.tokens.critical.nsColor
    }

    static var nsCriticalForeground: NSColor {
        self.palette.criticalForeground.nsColor
    }

    static var nsPrimaryText: NSColor {
        self.tokens.primaryText.nsColor
    }

    static var nsSecondaryText: NSColor {
        self.tokens.secondaryText.nsColor
    }

    static var nsTertiaryText: NSColor {
        self.tokens.tertiaryText.nsColor
    }

    static var nsTertiaryForeground: NSColor {
        self.palette.tertiaryForeground.nsColor
    }

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        HeadroomTypography.mono(size, weight: weight)
    }

    static func nsMono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        HeadroomTypography.nsMono(size, weight: weight)
    }

    static func text(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        HeadroomTypography.text(size, weight: weight)
    }
}

struct ConsoleSegmentedMeter: View {
    enum PercentMode: Equatable, Sendable {
        case remaining
        case used
    }

    enum Severity: Equatable, Sendable {
        case positive
        case caution
        case critical
    }

    enum Tone: Equatable, Sendable {
        case severity
        case neutral
    }

    let percent: Double
    var percentMode: PercentMode = .remaining
    var tone: Tone = .severity
    var segmentCount = 20
    var accessibilityText: String?

    private var filledSegmentCount: Int {
        guard self.percent > 0 else { return 0 }
        return min(self.segmentCount, Int(ceil(min(100, self.percent) / 100 * Double(self.segmentCount))))
    }

    private var fillColor: Color {
        if self.tone == .neutral { return ConsoleDesign.accentForeground }
        return switch Self.severity(percent: self.percent, mode: self.percentMode) {
        case .positive: ConsoleDesign.positive
        case .caution: ConsoleDesign.caution
        case .critical: ConsoleDesign.critical
        }
    }

    nonisolated static func severity(percent: Double, mode: PercentMode) -> Severity {
        let usedPercent = mode == .used ? percent : 100 - percent
        if usedPercent >= 100 { return .critical }
        if usedPercent >= 75 { return .caution }
        return .positive
    }

    nonisolated static func severity(percent: Double, mode: PercentMode, tone: Tone) -> Severity? {
        tone == .neutral ? nil : self.severity(percent: percent, mode: mode)
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<self.segmentCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: ConsoleDesign.radiusMeter, style: .continuous)
                    .fill(index < self.filledSegmentCount ? self.fillColor : ConsoleDesign.track)
            }
        }
        .frame(height: 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.accessibilityText ?? "\(Int(self.percent.rounded()))%")
    }
}

struct ConsoleDivider: View {
    var body: some View {
        Rectangle()
            .fill(ConsoleDesign.border)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}
