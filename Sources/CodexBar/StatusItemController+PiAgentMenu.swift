import AppKit
import CodexBarCore
import SwiftUI

private struct PiAgentUnavailableMenuCard: View {
    let width: CGFloat
    let onRefresh: @MainActor () async -> Void
    @State private var isRefreshing = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .font(HeadroomTypography.text(14, weight: .semibold))
                .foregroundStyle(ConsoleDesign.accentForeground)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(L("pi_agent"))
                    .font(ConsoleDesign.mono(11.5, weight: .medium))
                    .foregroundStyle(ConsoleDesign.primaryText)
                Text(L("pi_agent_status_unavailable"))
                    .font(ConsoleDesign.text(10.5))
                    .foregroundStyle(ConsoleDesign.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button {
                guard !self.isRefreshing else { return }
                self.isRefreshing = true
                Task {
                    await self.onRefresh()
                    self.isRefreshing = false
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(HeadroomTypography.text(11, weight: .semibold))
                    .frame(
                        width: PiAgentUsageCardPresentation.refreshButtonSize,
                        height: PiAgentUsageCardPresentation.refreshButtonSize)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .menuCardInteractiveControl(isEnabled: !self.isRefreshing)
            .disabled(self.isRefreshing)
            .help(PiAgentUsageCardPresentation.refreshAccessibilityLabel)
            .accessibilityLabel(PiAgentUsageCardPresentation.refreshAccessibilityLabel)
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

extension StatusItemController {
    func addPiAgentMenuCard(to menu: NSMenu, width: CGFloat) {
        let refresh: @MainActor () async -> Void = { [weak self] in
            guard let self else { return }
            await self.refreshPiAgentUsageCardAfterExplicitRefresh()
            await self.refreshLocalAgentSpeedReport(sources: [.pi])
            self.refreshOpenMenusAfterExplicitStoreAction()
        }
        if let snapshot = self.piAgentUsageCardSnapshot {
            let overallSpeed = self.piAgentOverallSpeedPresentation
            menu.addItem(self.makeMenuCardItem(
                PiAgentUsageSummaryView(
                    snapshot: snapshot,
                    width: width,
                    speedBadgeText: overallSpeed?.badgeText,
                    speedTooltip: overallSpeed?.tooltipText,
                    onRefresh: refresh),
                id: "piAgentUsageSummary",
                width: width,
                heightCacheScope: "piAgentUsageSummary",
                heightCacheFingerprint: "\(snapshot.totalTokens)|\(overallSpeed?.badgeText ?? "no-speed")",
                containsInteractiveControls: true))
            self.addConsoleDivider(to: menu)

            if snapshot.sections.isEmpty {
                menu.addItem(self.makeMenuCardItem(
                    PiAgentUsageCardView(
                        snapshot: snapshot,
                        width: width,
                        speedPresentation: overallSpeed),
                    id: "piAgentUsageCard",
                    width: width,
                    heightCacheScope: "piAgentUsageCard",
                    heightCacheFingerprint: "\(snapshot.totalTokens)|\(overallSpeed?.heightFingerprint ?? "no-speed")",
                    containsInteractiveControls: false))
            }
            for (index, section) in snapshot.sections.enumerated() {
                let detailSnapshot = section.tokenSnapshot(
                    now: self.piAgentUsageUpdatedAt ?? Date(),
                    historyDays: snapshot.windows.contains(where: { $0.kind == .last30Days }) ? 30 : 7)
                let detailTitle = section.isUnassigned
                    ? L("pi_agent_unassigned")
                    : section.providerKey
                let profileSpeed = self.piAgentProfileSpeedPresentation(providerKey: section.providerKey)
                let expanded = self.makeCodexUsageDetailsSubmenu(
                    snapshot: detailSnapshot,
                    title: detailTitle,
                    width: width,
                    unavailableText: L("pi_agent_status_unavailable"),
                    agentSpeed: profileSpeed)
                expanded.delegate = self
                StatusMenuAppearance.pin(expanded)
                menu.addItem(self.makeMenuCardItem(
                    PiAgentProfileCardView(
                        section: section,
                        width: width,
                        speedLine: profileSpeed?.inlineCompactLine,
                        speedTooltip: profileSpeed?.tooltipText),
                    id: "piAgentProfile-\(section.providerKey)",
                    width: width,
                    heightCacheScope: "piAgentProfile-\(section.providerKey)",
                    heightCacheFingerprint: [
                        String(section.totalTokens),
                        String(format: "%.9f", section.totalCostUSD),
                        String(section.windows.count),
                        profileSpeed?.inlineCompactLine ?? "no-speed",
                        CardDetailRail.renderingFingerprint,
                    ].joined(separator: "|"),
                    submenu: expanded,
                    usesCardDetailRail: true,
                    containsInteractiveControls: false))
                if index < snapshot.sections.count - 1 {
                    self.addConsoleDivider(to: menu)
                }
            }
            self.addConsoleDivider(to: menu)
        } else {
            menu.addItem(self.makeMenuCardItem(
                PiAgentUnavailableMenuCard(width: width, onRefresh: refresh),
                id: "piAgentUnavailable",
                width: width,
                heightCacheScope: "piAgentUnavailable",
                heightCacheFingerprint: L("pi_agent_status_unavailable"),
                containsInteractiveControls: true))
        }
        self.addConsoleDivider(to: menu)
    }
}
