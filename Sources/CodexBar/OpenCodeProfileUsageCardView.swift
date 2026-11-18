import CodexBarCore
import SwiftUI

enum OpenCodeProfileUsageCardPresentation {
    static let height: CGFloat = 54
    static let heightWithSpeed: CGFloat = 68
}

struct OpenCodeProfileUsageCardView: View {
    let breakdown: CostUsageProfileBreakdown
    let width: CGFloat
    var speedLine: String? = nil
    var speedTooltip: String? = nil

    private var title: String {
        self.breakdown.providerKey == "unassigned"
            ? L("usage_profile_unassigned")
            : self.breakdown.providerKey
    }

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            Circle()
                .fill(ConsoleDesign.accentForeground)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(self.title)
                    .font(ConsoleDesign.mono(11.5, weight: .semibold))
                    .foregroundStyle(ConsoleDesign.primaryText)
                    .lineLimit(1)
                if let speedLine = self.speedLine {
                    Text(speedLine)
                        .font(ConsoleDesign.mono(9.5))
                        .monospacedDigit()
                        .foregroundStyle(ConsoleDesign.secondaryText)
                        .lineLimit(1)
                        .help(self.speedTooltip ?? "")
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Text(self.breakdown.totalTokens.map(UsageFormatter.tokenCountString) ?? "—")
                    .font(ConsoleDesign.mono(11.5, weight: .semibold))
                    .foregroundStyle(ConsoleDesign.primaryText)
                Text(self.breakdown.totalCostUSD.map(UsageFormatter.usdString) ?? "—")
                    .font(ConsoleDesign.mono(9.5))
                    .foregroundStyle(ConsoleDesign.secondaryText)
            }
        }
        .padding(12)
        .padding(.trailing, CardDetailRail.width)
        .frame(
            width: self.width - 12,
            height: self.speedLine == nil
                ? OpenCodeProfileUsageCardPresentation.height
                : OpenCodeProfileUsageCardPresentation.heightWithSpeed,
            alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ConsoleDesign.radiusCard, style: .continuous)
                .fill(ConsoleDesign.surface))
        .overlay(alignment: .trailing) {
            CardDetailRail()
        }
        .clipShape(RoundedRectangle(cornerRadius: ConsoleDesign.radiusCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ConsoleDesign.radiusCard, style: .continuous)
                .stroke(ConsoleDesign.border, lineWidth: 1))
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(ConsoleDesign.background)
        .frame(width: self.width, alignment: .leading)
    }
}
