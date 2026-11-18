import CodexBarCore
import Foundation

@MainActor
enum CodexSessionOwnershipBootstrap {
    @discardableResult
    static func seedAtLaunch(
        settings: SettingsStore,
        store: FileCodexSessionOwnershipTimelineStore = .default,
        at date: Date = Date()) -> Bool
    {
        let projection = settings.codexVisibleAccountProjection
        guard let liveID = projection.liveVisibleAccountID,
              let account = projection.visibleAccounts.first(where: { $0.id == liveID }),
              account.selectionSource == .liveSystem,
              let storedAccountID = account.storedAccountID
        else { return false }
        let accountKey = CodexSessionOwnershipTimeline.managedAccountKey(id: storedAccountID)
        return (try? store.seedAssumedStartingBoundaryIfNeeded(accountKey: accountKey, at: date)) == true
    }
}
