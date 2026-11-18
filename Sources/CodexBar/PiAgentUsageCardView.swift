import CodexBarCore
import SwiftUI

enum PiAgentUsageCardPresentation {
    static let refreshButtonSize: CGFloat = 22
    static let profileCardHeight: CGFloat = 54
    static let profileCardHeightWithSpeed: CGFloat = 68
    static var refreshAccessibilityLabel: String { L("pi_agent_refresh") }
}

enum PiAgentUsageRefreshCadence {
    static func interval(for frequency: RefreshFrequency) -> TimeInterval? {
        frequency.usesAdaptivePolicy
            ? AdaptiveRefreshPolicy.nominalIntervalForHeuristics
            : frequency.seconds
    }
}

struct PiAgentProfileCardView: View {
    let section: PiAgentUsageCardSnapshot.ProfileSection
    let width: CGFloat
    var speedLine: String? = nil
    var speedTooltip: String? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            Circle()
                .fill(ConsoleDesign.accentForeground)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(self.section.isUnassigned ? L("pi_agent_unassigned") : self.section.providerKey)
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
                Text(UsageFormatter.tokenCountString(self.section.totalTokens))
                    .font(ConsoleDesign.mono(11.5, weight: .semibold))
                    .foregroundStyle(ConsoleDesign.primaryText)
                Text(UsageFormatter.usdString(self.section.totalCostUSD))
                    .font(ConsoleDesign.mono(9.5))
                    .foregroundStyle(ConsoleDesign.secondaryText)
            }
        }
        .padding(12)
        .padding(.trailing, CardDetailRail.width)
        .frame(
            width: self.width - 12,
            height: self.speedLine == nil
                ? PiAgentUsageCardPresentation.profileCardHeight
                : PiAgentUsageCardPresentation.profileCardHeightWithSpeed,
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

struct PiAgentUsageSummaryView: View {
    let snapshot: PiAgentUsageCardSnapshot
    let width: CGFloat
    var speedBadgeText: String? = nil
    var speedTooltip: String? = nil
    let onRefresh: @MainActor () async -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "sparkles")
                .font(HeadroomTypography.text(14, weight: .semibold))
                .foregroundStyle(ConsoleDesign.accentForeground)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("pi_agent"))
                    .font(ConsoleDesign.mono(11.5, weight: .medium))
                    .foregroundStyle(ConsoleDesign.primaryText)
                Text(self.speedBadgeText ?? L("pi_agent_local_sessions"))
                    .font(self.speedBadgeText == nil ? ConsoleDesign.text(10.5) : ConsoleDesign.mono(10))
                    .monospacedDigit()
                    .foregroundStyle(ConsoleDesign.secondaryText)
                    .lineLimit(1)
                    .help(self.speedTooltip ?? "")
            }
            Spacer(minLength: 0)
            Text(UsageFormatter.tokenCountString(self.snapshot.totalTokens))
                .font(ConsoleDesign.mono(11.5, weight: .semibold))
                .foregroundStyle(ConsoleDesign.primaryText)
            PiAgentRefreshButton(action: self.onRefresh)
        }
        .padding(12)
        .frame(width: self.width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ConsoleDesign.radiusCard, style: .continuous)
                .fill(ConsoleDesign.surface))
        .overlay(
            RoundedRectangle(cornerRadius: ConsoleDesign.radiusCard, style: .continuous)
                .stroke(ConsoleDesign.border, lineWidth: 1))
    }
}

struct PiAgentUsageCardView: View {
    let snapshot: PiAgentUsageCardSnapshot
    let width: CGFloat
    let speedPresentation: AgentSpeedPresentation?
    let onRefresh: (@MainActor () async -> Void)?

    init(
        snapshot: PiAgentUsageCardSnapshot,
        width: CGFloat,
        speedPresentation: AgentSpeedPresentation? = nil,
        onRefresh: (@MainActor () async -> Void)? = nil)
    {
        self.snapshot = snapshot
        self.width = width
        self.speedPresentation = speedPresentation
        self.onRefresh = onRefresh
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "sparkles")
                    .font(HeadroomTypography.text(14, weight: .semibold))
                    .foregroundStyle(ConsoleDesign.accentForeground)
                    .frame(width: 18, height: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(L("pi_agent"))
                        .font(ConsoleDesign.mono(11.5, weight: .medium))
                        .foregroundStyle(ConsoleDesign.primaryText)
                    Text(L("pi_agent_local_sessions"))
                        .font(ConsoleDesign.text(10.5))
                        .foregroundStyle(ConsoleDesign.secondaryText)
                }
                Spacer(minLength: 0)
                Text(UsageFormatter.tokenCountString(self.snapshot.totalTokens))
                    .font(ConsoleDesign.mono(11.5, weight: .semibold))
                    .foregroundStyle(ConsoleDesign.primaryText)
                if let onRefresh {
                    PiAgentRefreshButton(action: onRefresh)
                }
            }

            ConsoleDivider()

            if !self.snapshot.sections.isEmpty {
                ForEach(self.snapshot.sections) { section in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(section.isUnassigned ? L("pi_agent_unassigned") : section.providerKey)
                            .font(ConsoleDesign.mono(10.5, weight: .semibold))
                            .foregroundStyle(ConsoleDesign.primaryText)
                        ForEach(section.windows) { window in
                            Self.windowRow(window)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(self.snapshot.windows) { window in
                        Self.windowRow(window)
                    }
                }
            }

            if !self.snapshot.models.isEmpty {
                Text(self.snapshot.models.joined(separator: " · "))
                    .font(ConsoleDesign.mono(9.5))
                    .foregroundStyle(ConsoleDesign.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let speedPresentation = self.speedPresentation {
                ConsoleDivider()
                AgentSpeedSectionContent(presentation: speedPresentation)
            }
        }
        .padding(12)
        .frame(width: self.width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ConsoleDesign.radiusCard, style: .continuous)
                .fill(ConsoleDesign.surface))
        .overlay(
            RoundedRectangle(cornerRadius: ConsoleDesign.radiusCard, style: .continuous)
                .stroke(ConsoleDesign.border, lineWidth: 1))
    }

    private static func windowTitle(_ kind: PiAgentUsageCardSnapshot.WindowKind) -> String {
        switch kind {
        case .rolling24Hours: L("relay_local_usage_24h")
        case .last7Days: L("relay_local_usage_7d")
        case .last30Days: L("30d")
        }
    }

    private static func windowRow(_ window: PiAgentUsageCardSnapshot.Window) -> some View {
        HStack(spacing: 8) {
            Text(Self.windowTitle(window.kind))
                .font(ConsoleDesign.text(10.5))
                .foregroundStyle(ConsoleDesign.secondaryText)
                .frame(width: 48, alignment: .leading)
            Text(UsageFormatter.tokenCountString(window.totalTokens))
                .font(ConsoleDesign.mono(10.5, weight: .medium))
                .foregroundStyle(ConsoleDesign.primaryText)
            Spacer(minLength: 0)
            Text(UsageFormatter.usdString(window.totalCostUSD))
                .font(ConsoleDesign.mono(10.5))
                .foregroundStyle(ConsoleDesign.secondaryText)
        }
    }
}

private struct PiAgentRefreshButton: View {
    let action: @MainActor () async -> Void
    @State private var isRefreshing = false
    @State private var isHovered = false

    var body: some View {
        Button {
            guard !self.isRefreshing else { return }
            self.isRefreshing = true
            Task {
                await self.action()
                self.isRefreshing = false
            }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(HeadroomTypography.text(11, weight: .semibold))
                .rotationEffect(self.isRefreshing ? .degrees(360) : .zero)
                .animation(
                    self.isRefreshing
                        ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                        : .default,
                    value: self.isRefreshing)
                .frame(
                    width: PiAgentUsageCardPresentation.refreshButtonSize,
                    height: PiAgentUsageCardPresentation.refreshButtonSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background {
            Circle()
                .fill(self.isHovered ? ConsoleDesign.surface2 : ConsoleDesign.surface)
                .overlay { Circle().stroke(ConsoleDesign.border, lineWidth: 1) }
        }
        .onHover { self.isHovered = $0 }
        .menuCardInteractiveControl(isEnabled: !self.isRefreshing)
        .disabled(self.isRefreshing)
        .help(PiAgentUsageCardPresentation.refreshAccessibilityLabel)
        .accessibilityLabel(PiAgentUsageCardPresentation.refreshAccessibilityLabel)
    }
}
