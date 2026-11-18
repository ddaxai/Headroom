import CodexBarCore
import Foundation
import Observation

enum UsageSpendFocusTarget: Equatable {
    case systemUnassigned
}

/// Top-level settings destinations. Existing `SettingsPane` cases remain leaf routes so
/// persisted selections and internal entry points can keep their current behavior.
enum SettingsDestination: CaseIterable, Hashable {
    case general
    case accountsAndAPIs
    case usageAndCost
    case appearance
    case about

    var title: String {
        switch self {
        case .general: L("tab_general")
        case .accountsAndAPIs: L("settings_destination_accounts_apis")
        case .usageAndCost: L("settings_destination_usage_cost")
        case .appearance: L("settings_destination_appearance")
        case .about: L("tab_about")
        }
    }

    var defaultPane: SettingsPane {
        switch self {
        case .general: .general
        case .accountsAndAPIs: .providers
        case .usageAndCost: .usageSpend
        case .appearance: .menuBar
        case .about: .about
        }
    }
}

extension SettingsPane {
    var destination: SettingsDestination {
        switch self {
        case .general, .advanced, .hooks, .debug: .general
        case .providers, .relay, .provider: .accountsAndAPIs
        case .usageSpend, .notifications: .usageAndCost
        case .menuBar, .menu: .appearance
        case .update, .about: .about
        }
    }

    /// Leaf route used when a persisted or legacy route is restored through the regular settings UI.
    /// Option-only diagnostics remain addressable by their historical cases, but never become the
    /// default destination.
    var regularPane: SettingsPane {
        switch self {
        case .general, .providers, .relay, .usageSpend, .menuBar, .about:
            self
        case .notifications: .usageSpend
        case .menu: .menuBar
        case .provider: .providers
        case .advanced, .hooks, .debug: .general
        case .update: .about
        }
    }

    var isOptionOnly: Bool {
        switch self {
        case .advanced, .hooks, .debug: true
        default: false
        }
    }

    var isRegularlyReachable: Bool {
        self.regularPane == self && !self.isOptionOnly
    }

    /// Stable token used to remember the selected pane across launches.
    var persistenceToken: String {
        switch self {
        case .general: "general"
        case .usageSpend: "usageSpend"
        case .providers: "providers"
        case .relay: "relay"
        case .notifications: "notifications"
        case .menuBar: "menuBar"
        case .menu: "menuBar"
        case .advanced: "advanced"
        case .hooks: "advanced"
        case .update: "update"
        case .about: "about"
        case .debug: "advanced"
        case .provider: "providers"
        }
    }

    init?(persistenceToken: String) {
        switch persistenceToken {
        case "general": self = .general
        case "usageSpend": self = .usageSpend
        case "providers": self = .providers
        case "relay": self = .relay
        case "notifications": self = .notifications
        case "menuBar": self = .menuBar
        // Pre-0.41.1 releases persisted the retired Display pane; its contents moved to Menu Bar.
        case "display": self = .menuBar
        case "menu": self = .menuBar
        case "advanced": self = .advanced
        case "hooks": self = .advanced
        case "update": self = .update
        case "about": self = .about
        case "debug": self = .advanced
        default:
            let providerPrefix = "provider:"
            guard persistenceToken.hasPrefix(providerPrefix),
                  let provider = UsageProvider(rawValue: String(persistenceToken.dropFirst(providerPrefix.count)))
            else {
                return nil
            }
            _ = provider
            self = .providers
        }
    }
}

@MainActor
@Observable
final class PreferencesSelection {
    static let paneDefaultsKey = "settingsSelectedPane"

    private let userDefaults: UserDefaults

    var usageSpendFocusTarget: UsageSpendFocusTarget?

    var pane: SettingsPane {
        didSet {
            self.userDefaults.set(self.pane.persistenceToken, forKey: Self.paneDefaultsKey)
        }
    }

    init(userDefaults: UserDefaults = CodexBarPreferences.processDefaults) {
        self.userDefaults = userDefaults
        let token = userDefaults.string(forKey: Self.paneDefaultsKey) ?? ""
        self.pane = SettingsPane(persistenceToken: token)?.regularPane ?? .general
    }

    func requestUsageSpendFocus(_ target: UsageSpendFocusTarget) {
        self.usageSpendFocusTarget = target
        self.pane = .usageSpend
    }

    func consumeUsageSpendFocus(_ target: UsageSpendFocusTarget) {
        guard self.usageSpendFocusTarget == target else { return }
        self.usageSpendFocusTarget = nil
    }
}
