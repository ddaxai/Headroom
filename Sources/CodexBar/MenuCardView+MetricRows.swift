import CodexBarCore
import SwiftUI

struct MetricRow: View {
    let metric: UsageMenuCardView.Model.Metric
    let title: String
    let progressColor: Color
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(self.title)
                .font(.body)
                .fontWeight(.medium)
            if let statusText = self.metric.statusText {
                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .lineLimit(1)
            } else {
                ConsoleSegmentedMeter(
                    percent: self.metric.percent,
                    percentMode: self.metric.percentStyle == .used ? .used : .remaining)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(self.metric.percentLabel)
                            .font(.footnote)
                            .lineLimit(1)
                        Spacer()
                        if let rightLabel = self.metric.resetText {
                            Text(rightLabel)
                                .font(.footnote)
                                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                                .lineLimit(1)
                        }
                    }
                    if self.metric.detailLeftText != nil || self.metric.detailRightText != nil {
                        HStack(alignment: .firstTextBaseline) {
                            if let detailLeft = self.metric.detailLeftText {
                                Text(detailLeft)
                                    .font(.footnote)
                                    .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                                    .lineLimit(1)
                            }
                            Spacer()
                            if let detailRight = self.metric.detailRightText {
                                Text(detailRight)
                                    .font(.footnote)
                                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                                    .lineLimit(1)
                            }
                        }
                    }
                    if let sessionEquivalentDetail = self.metric.sessionEquivalentDetail {
                        HStack(alignment: .firstTextBaseline) {
                            Text(sessionEquivalentDetail.leftText)
                                .font(.footnote)
                                .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                                .lineLimit(1)
                            Spacer()
                            Text(sessionEquivalentDetail.rightText)
                                .font(.footnote)
                                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                                .lineLimit(1)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(sessionEquivalentDetail.accessibilityLabel)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let detail = self.metric.detailText {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(self.metric.cardStyle ? 10 : 0)
        .background(self.metric.cardStyle ? Color.secondary.opacity(self.isHighlighted ? 0.2 : 0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: self.metric.cardStyle ? 10 : 0))
    }
}

/// A quota window in the layout of a Codex account card: title and percentage on one line, the meter, then a
/// single line of reset and pace. The remaining detail is in the tooltip.
struct CompactMetricRow: View {
    let metric: UsageMenuCardView.Model.Metric
    let title: String
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(self.title)
                    .font(ConsoleDesign.text(11, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(Int(self.metric.percent.rounded()))%")
                    .font(ConsoleDesign.mono(13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(self.percentColor)
            }
            ConsoleSegmentedMeter(
                percent: self.metric.percent,
                percentMode: self.metric.percentStyle == .used ? .used : .remaining)
            if self.metric.resetText != nil || self.metric.detailLeftText != nil {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let resetText = self.metric.resetText {
                        Text(resetText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if let pace = self.metric.detailLeftText {
                        Text(pace)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                }
                .font(ConsoleDesign.mono(10))
                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(UsageMenuCardView.compactMetricTooltip(self.metric))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(self.title), \(UsageMenuCardView.compactMetricTooltip(self.metric))")
    }

    private var percentColor: Color {
        let exhausted = self.metric.percentStyle == .used ? self.metric.percent >= 100 : self.metric.percent <= 0
        return exhausted ? ConsoleDesign.criticalForeground : MenuHighlightStyle.primary(self.isHighlighted)
    }
}

extension UsageMenuCardView {
    /// Antigravity lists four quota windows; at full size they push the rest of the card off a small screen.
    static func usesCompactMetricRows(provider: UsageProvider) -> Bool {
        provider == .antigravity
    }

    /// Everything the full-size row prints, one item per line.
    static func compactMetricTooltip(_ metric: Model.Metric) -> String {
        [
            metric.percentLabel,
            metric.resetText,
            metric.detailLeftText,
            metric.detailRightText,
            metric.sessionEquivalentDetail?.leftText,
            metric.sessionEquivalentDetail?.rightText,
            metric.detailText,
        ]
            .compactMap(\.self)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
