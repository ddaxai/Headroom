import CodexBarCore
import Foundation

typealias ProviderMenuEntry = MenuDescriptor.Entry

struct ProviderMenuUsageContext {
    let provider: UsageProvider
    let store: UsageDomain
    let settings: SettingsStore
    let metadata: ProviderMetadata
    let snapshot: UsageSnapshot?
}

struct ProviderMenuActionContext {
    let provider: UsageProvider
    let store: UsageDomain
    let settings: SettingsStore
    let account: AccountInfo
    let managedCodexAccountCoordinator: ManagedCodexAccountCoordinator?
    let codexAccountPromotionCoordinator: CodexAccountPromotionCoordinator?
    let relayQuickSwitchSnapshot: RelayQuickSwitchSnapshot?
}

struct ProviderMenuLoginContext {
    let provider: UsageProvider
    let store: UsageDomain
    let settings: SettingsStore
    let account: AccountInfo
    let hasAccount: Bool
}
