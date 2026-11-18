import CodexBarCore
import SwiftUI

struct CodexLocalUsagePresentation: Equatable {
    let state: LocalUsageState
    let line: String?
    let unassignedExplanation: String?

    static func resolve(
        summaryLine: String?,
        refreshInFlight: Bool,
        coverageIsComplete: Bool?,
        sharedCorpusHasUsage: Bool) -> Self
    {
        if let summaryLine {
            return Self(state: .available, line: summaryLine, unassignedExplanation: nil)
        }
        if refreshInFlight || coverageIsComplete == false {
            return Self(state: .loading, line: L("codex_local_usage_scanning"), unassignedExplanation: nil)
        }
        if sharedCorpusHasUsage {
            return Self(
                state: .unavailable,
                line: L("codex_usage_details_unavailable_official"),
                unassignedExplanation: nil)
        }
        return Self(state: .empty, line: L("codex_local_usage_empty"), unassignedExplanation: nil)
    }
}

struct CodexAccountSummaryCardModel {
    struct Quota {
        let title: String
        let remainingPercent: Double
        let resetText: String?
    }

    let ordinal: Int
    let isActive: Bool
    let providerName: String
    let email: String
    let subtitle: String
    let alertText: String?
    let workspace: String?
    let plan: String?
    let quota: Quota?
    let quotas: [Quota]
    let resetCredits: CodexResetCreditsPresentation?
    let progressColor: Color
    let usageLine: String?
    let usageEmptyText: String?
    let speedLine: String?
    let speedTooltip: String?

    init(
        model: UsageMenuCardView.Model,
        ordinal: Int,
        workspace: String?,
        isActive: Bool,
        usageLine: String? = nil,
        usageEmptyText: String? = nil,
        speedLine: String? = nil,
        speedTooltip: String? = nil)
    {
        self.ordinal = ordinal
        self.isActive = isActive
        self.providerName = model.providerName
        self.email = model.email.isEmpty ? model.providerName : model.email
        self.subtitle = model.subtitleText
        self.alertText = model.subtitleStyle == .error ? model.subtitleText : nil
        self.workspace = workspace?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        self.plan = model.planText?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        self.resetCredits = model.codexResetCredits
        self.progressColor = model.progressColor
        self.usageLine = usageLine
        self.usageEmptyText = usageEmptyText
        self.speedLine = speedLine
        self.speedTooltip = speedTooltip
        self.quotas = model.metrics.map { metric in
            Quota(
                title: metric.title,
                remainingPercent: Self.remainingPercent(for: metric),
                resetText: metric.resetText)
        }
        self.quota = Self.preferredQuota(in: model.metrics).map { metric in
            Quota(
                title: metric.title,
                remainingPercent: Self.remainingPercent(for: metric),
                resetText: metric.resetText)
        }
    }

    static func preferredQuota(
        in metrics: [UsageMenuCardView.Model.Metric]) -> UsageMenuCardView.Model.Metric?
    {
        metrics.first { $0.id == "secondary" } ?? metrics.first
    }

    static func remainingPercent(for metric: UsageMenuCardView.Model.Metric) -> Double {
        let value = switch metric.percentStyle {
        case .left: metric.percent
        case .used: 100 - metric.percent
        }
        return min(100, max(0, value))
    }
}

struct CodexAccountSummaryCardView: View {
    let model: CodexAccountSummaryCardModel
    let width: CGFloat
    var onViewUnassigned: @MainActor () -> Void = {}
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Group {
                    if let icon = ProviderBrandIcon.image(for: .codex) {
                        Image(nsImage: icon)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Image(systemName: "terminal.fill")
                    }
                }
                .frame(width: 18, height: 18)
                .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(self.model.email)
                            .font(ConsoleDesign.mono(11.5, weight: .medium))
                            .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(1)
                        if self.model.isActive {
                            Text(L("Active"))
                                .font(ConsoleDesign.text(9.5, weight: .medium))
                                .foregroundStyle(ConsoleDesign.accentForeground)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: ConsoleDesign.radiusChip, style: .continuous)
                                        .stroke(ConsoleDesign.accent, lineWidth: 1))
                                .fixedSize()
                        }
                    }
                    Text(self.accountContext)
                        .font(ConsoleDesign.text(10.5))
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let alertText = self.model.alertText {
                Label(alertText, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(MenuHighlightStyle.error(self.isHighlighted))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let usageLine = self.model.usageLine {
                Text(usageLine)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .lineLimit(1)
            }

            if let speedLine = self.model.speedLine {
                Text(speedLine)
                    .font(ConsoleDesign.mono(10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                    .lineLimit(1)
                    .help(self.model.speedTooltip ?? "")
            }

            if let usageEmptyText = self.model.usageEmptyText {
                VStack(alignment: .leading, spacing: 4) {
                    Text(usageEmptyText)
                        .font(.caption2)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        self.onViewUnassigned()
                    } label: {
                        Label(L("codex_account_usage_view_unassigned"), systemImage: "arrow.right")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .menuCardInteractiveControl()
                }
            }

            ForEach(Array(self.model.quotas.enumerated()), id: \.offset) { _, quota in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(quota.title)
                            .font(ConsoleDesign.text(11, weight: .medium))
                        Spacer()
                        Text("\(Int(quota.remainingPercent.rounded()))%")
                            .font(ConsoleDesign.mono(15, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(
                                quota.remainingPercent <= 0
                                    ? ConsoleDesign.criticalForeground
                                    : ConsoleDesign.primaryText)
                    }
                    ConsoleSegmentedMeter(percent: quota.remainingPercent)
                    if let resetText = quota.resetText {
                        Text(resetText)
                            .font(ConsoleDesign.mono(10))
                            .foregroundStyle(ConsoleDesign.secondaryText)
                            .lineLimit(1)
                    }
                }
            }

            if let resetCredits = self.model.resetCredits {
                Rectangle()
                    .fill(ConsoleDesign.border)
                    .frame(height: 1)
                CodexResetCreditsContent(presentation: resetCredits)
            }
        }
        .padding(12)
        .padding(.trailing, CardDetailRail.width)
        .frame(width: self.width - 12, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: ConsoleDesign.radiusCard, style: .continuous)
                .fill(self.cardBackground)
        }
        .overlay(alignment: .trailing) {
            CardDetailRail()
        }
        .clipShape(RoundedRectangle(cornerRadius: ConsoleDesign.radiusCard, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ConsoleDesign.radiusCard, style: .continuous)
                .stroke(
                    self.cardBorder,
                    lineWidth: self.model.isActive ? 1.5 : 1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(ConsoleDesign.background)
        .frame(width: self.width, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(self.accessibilityLabel)
        .preferredColorScheme(ConsoleDesign.preferredColorScheme)
    }

    private var accountContext: String {
        var parts: [String] = []
        if let workspace = self.model.workspace {
            parts.append(workspace)
        }
        if let plan = self.model.plan, !parts.contains(plan) {
            parts.append(plan)
        }
        if !parts.isEmpty {
            return parts.joined(separator: " · ")
        }
        return self.model.alertText == nil ? self.model.subtitle : self.model.providerName
    }

    private var cardBackground: Color {
        if self.model.isActive {
            return ConsoleDesign.surface2
        }
        return ConsoleDesign.surface
    }

    private var cardBorder: Color {
        if self.model.isActive {
            return ConsoleDesign.accent.opacity(self.isHighlighted ? 0.85 : 0.62)
        }
        return ConsoleDesign.border
    }

    private var accessibilityLabel: String {
        var parts = ["\(L("Account")) \(self.model.ordinal)", self.model.email, self.accountContext]
        if self.model.isActive {
            parts.append(L("Active"))
        }
        if let alertText = self.model.alertText {
            parts.append(alertText)
        }
        if let usageEmptyText = self.model.usageEmptyText {
            parts.append(usageEmptyText)
            parts.append(L("codex_account_usage_view_unassigned"))
        }
        for quota in self.model.quotas {
            parts.append("\(quota.title), \(Int(quota.remainingPercent.rounded()))% \(L("usage_percent_suffix_left"))")
            if let resetText = quota.resetText {
                parts.append(resetText)
            }
        }
        if let resetCredits = self.model.resetCredits {
            parts.append(resetCredits.accessibilityLabel)
        }
        return parts.joined(separator: ", ")
    }
}

struct CodexQuotaRing: View {
    let remainingPercent: Double
    let tint: Color
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        ZStack {
            Circle()
                .stroke(MenuHighlightStyle.progressTrack(self.isHighlighted), lineWidth: 7)
            Circle()
                .trim(from: 0, to: self.remainingPercent / 100)
                .stroke(
                    MenuHighlightStyle.progressTint(self.isHighlighted, fallback: self.tint),
                    style: StrokeStyle(lineWidth: 7, lineCap: .butt))
                .rotationEffect(.degrees(-90))
            VStack(spacing: -1) {
                Text("\(Int(self.remainingPercent.rounded()))%")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                Text(L("usage_percent_suffix_left"))
                    .font(.system(size: 8, weight: .medium))
            }
            .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
        }
        .frame(width: 62, height: 62)
        .accessibilityHidden(true)
    }
}

extension String {
    fileprivate var nonEmpty: String? {
        self.isEmpty ? nil : self
    }
}
