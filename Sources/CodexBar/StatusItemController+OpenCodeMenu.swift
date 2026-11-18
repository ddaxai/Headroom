import AppKit
import CodexBarCore

extension StatusItemController {
    func addOpenCodeProfileMenuCards(to menu: NSMenu, width: CGFloat) {
        guard let snapshot = self.store.tokenSnapshot(for: .opencode),
              !snapshot.profileBreakdowns.isEmpty
        else { return }

        if menu.items.last.map(self.isConsoleDivider) != true {
            self.addConsoleDivider(to: menu)
        }
        for (index, breakdown) in snapshot.profileBreakdowns.enumerated() {
            let title = breakdown.providerKey == "unassigned"
                ? L("usage_profile_unassigned")
                : breakdown.providerKey
            let detailTitle = String(format: L("opencode_profile_usage_title"), title)
            let detailSnapshot = breakdown.tokenSnapshot(
                now: snapshot.updatedAt,
                historyDays: snapshot.historyDays)
            let submenu = self.makeCodexUsageDetailsSubmenu(
                snapshot: detailSnapshot,
                title: detailTitle,
                width: width,
                unavailableText: L("opencode_profile_usage_unavailable"))
            submenu.delegate = self
            StatusMenuAppearance.pin(submenu)
            let profileSpeed = self.openCodeProfileSpeedPresentation(providerKey: breakdown.providerKey)
            menu.addItem(self.makeMenuCardItem(
                OpenCodeProfileUsageCardView(
                    breakdown: breakdown,
                    width: width,
                    speedLine: profileSpeed?.inlineCompactLine,
                    speedTooltip: profileSpeed?.tooltipText),
                id: "openCodeProfile-\(breakdown.providerKey)",
                width: width,
                heightCacheScope: "openCodeProfile",
                heightCacheFingerprint: [
                    breakdown.providerKey,
                    String(breakdown.totalTokens ?? -1),
                    String(format: "%.9f", breakdown.totalCostUSD ?? -1),
                    String(detailSnapshot.daily.count),
                    profileSpeed?.inlineCompactLine ?? "no-speed",
                    CardDetailRail.renderingFingerprint,
                ].joined(separator: ":"),
                submenu: submenu,
                usesCardDetailRail: true,
                containsInteractiveControls: false))
            if index < snapshot.profileBreakdowns.count - 1 {
                self.addConsoleDivider(to: menu)
            }
        }
    }
}
