import CodexBarCore
import Foundation

enum RelayMenuBarQuotaText {
    static func remainingPercent(_ value: Double?) -> String? {
        guard let value, value.isFinite else { return nil }
        return "\(Int(min(100, max(0, value)).rounded()))%"
    }
}

extension StatusItemController {
    func relayMenuBarCodexSnapshot() -> UsageSnapshot? {
        let activeID = self.settings.codexVisibleAccountProjection.activeVisibleAccountID
        if let activeID,
           let accountSnapshot = self.store.codexAccountSnapshots.first(where: { $0.id == activeID }),
           let snapshot = accountSnapshot.snapshot
        {
            return snapshot
        }
        return self.store.snapshot(for: .codex)
    }

    func relayMenuBarRemainingText() -> String? {
        let snapshot = self.relayMenuBarCodexSnapshot()
        let weekly = snapshot?.secondary ?? snapshot?.primary
        return RelayMenuBarQuotaText.remainingPercent(weekly?.remainingPercent)
    }
}
