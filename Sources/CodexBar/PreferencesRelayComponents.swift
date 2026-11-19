import CodexBarCore
import SwiftUI

struct RelayLocalUsageMeterRow: View {
    let label: String
    let window: CodexRelayLocalUsageWindow

    var body: some View {
        let relay = UsageFormatter.tokenCountString(self.window.relayTokens)
        let corpus = UsageFormatter.tokenCountString(self.window.corpusTokens)
        let percent = Int(self.window.percent.rounded())
        let accessibility = L("relay_local_usage_accessibility", self.label, relay, corpus, percent)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(self.label)
                    .foregroundStyle(ConsoleDesign.secondaryText)
                Spacer(minLength: 8)
                Text(L("relay_local_usage_value_format", relay, corpus, percent))
                    .font(.caption.monospacedDigit())
            }
            ConsoleSegmentedMeter(
                percent: self.window.percent,
                percentMode: .used,
                tone: .neutral,
                accessibilityText: accessibility)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
    }
}

@MainActor
struct RelayIdentityBanner: View {
    let activeApplicationCount: Int

    private var isActive: Bool {
        self.activeApplicationCount > 0
    }

    var body: some View {
        HStack(spacing: 8) {
            // Static in Settings: the state is a persistent setting, not ongoing work, so the
            // tile changes color instead of looping an animation behind the form.
            RelaySprinklerSymbol(
                isAnimated: false,
                primaryColor: self.isActive ? .white : ConsoleDesign.secondaryText,
                size: 14)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: ConsoleDesign.radiusControl, style: .continuous)
                        .fill(self.isActive ? ConsoleDesign.accent : ConsoleDesign.surface2))

            Text(L("relay_ui_banner_title"))
                .font(.subheadline.weight(.semibold))

            Spacer(minLength: 8)

            Text(self.isActive
                ? L("relay_ui_banner_active", self.activeApplicationCount)
                : L("relay_ui_banner_inactive"))
                .font(.caption)
                .foregroundStyle(ConsoleDesign.secondaryText)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}
