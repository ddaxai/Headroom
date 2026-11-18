import AppKit
import CodexBarCore
import Foundation
import SwiftUI

enum RelayQuickSwitchSelection: Equatable {
    case official(RelayTargetApp)
    case profile(RelayTargetApp, UUID)
    case external(RelayTargetApp, String)
    case mixed
}

struct RelayExternalActiveChoice: Equatable {
    let providerID: String
    let displayName: String
    let baseURL: String
    let model: String?

    var chipTitle: String {
        L("relay_quick_switch_external_chip", self.displayName)
    }

    var helpText: String {
        if let model = self.model, !model.isEmpty {
            return L("relay_quick_switch_external_help_model", self.displayName, self.baseURL, model)
        }
        return L("relay_quick_switch_external_help", self.displayName, self.baseURL)
    }
}

struct RelayQuickSwitchPresentation {
    static let interitemSpacing: CGFloat = 6
    static let verticalPadding: CGFloat = 6
    static let followingSectionGap: CGFloat = 9

    enum LabelMode: Equatable {
        case provider(String)
        case targets([String])
    }

    struct Choice: Equatable {
        let isActionable: Bool
        let helpText: String?
    }

    let labelMode: LabelMode
    let showsStandaloneHeading = false

    var showsTargetLabels: Bool {
        if case let .targets(targets) = self.labelMode {
            return !targets.isEmpty
        }
        return false
    }

    var targetLabelWidth: CGFloat {
        self.showsTargetLabels ? 56 : 0
    }

    static var officialChoiceLabel: String {
        L("usage_identity_subscription")
    }

    init(visibleTargets: [RelayTargetApp]) {
        let labels = visibleTargets.map(Self.targetLabel)
        self.labelMode = labels.count == 1 ? .provider(labels[0]) : .targets(labels)
    }

    static func choice(isReady: Bool, blocker: String?) -> Choice {
        Choice(
            isActionable: isReady || blocker?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            helpText: blocker)
    }

    static func shouldRebuildMenu(after outcome: RelayQuickSwitchOutcome) -> Bool {
        outcome.succeeded && outcome.warning == nil
    }

    static func targetLabel(_ target: RelayTargetApp) -> String {
        switch target {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        case .claudeDesktop: "Claude Desktop"
        case .grokBuild: "Grok Build"
        case .openCode: "OpenCode"
        case .piAgent: "Pi Agent"
        }
    }
}

struct RelayQuickSwitchOption: Identifiable, Equatable {
    let id: UUID
    let name: String
    let isReady: Bool
    let blocker: String?
    let usageSummary: RelayUsageSummary?
    let apiFormat: RelayAPIFormat
    let providerKey: String
    let enabledTargets: Set<RelayTargetApp>

    init(
        id: UUID,
        name: String,
        isReady: Bool,
        blocker: String?,
        usageSummary: RelayUsageSummary? = nil,
        apiFormat: RelayAPIFormat = .openAIResponses,
        providerKey: String? = nil,
        enabledTargets: Set<RelayTargetApp> = [])
    {
        self.id = id
        self.name = name
        self.isReady = isReady
        self.blocker = blocker
        self.usageSummary = usageSummary
        self.apiFormat = apiFormat
        self.providerKey = RelayProviderKey.slug(for: providerKey ?? name, fallbackID: id)
        self.enabledTargets = enabledTargets
    }

    var heightCacheDescription: String {
        let usage = self.usageSummary.map(RelayUsagePresentation.summaryLine) ?? "—"
        let targets = self.enabledTargets.map(\.rawValue).sorted().joined(separator: ",")
        return "\(self.id.uuidString):\(self.providerKey):\(self.name):\(self.isReady):"
            + "\(self.blocker ?? ""):\(usage):\(self.apiFormat.rawValue):\(targets)"
    }
}

struct RelayQuickSwitchSnapshot: Equatable {
    let optionsByTarget: [RelayTargetApp: [RelayQuickSwitchOption]]
    let selectionByTarget: [RelayTargetApp: RelayQuickSwitchSelection]
    let activeProfileIDsByTarget: [RelayTargetApp: UUID]
    let externalActiveByTarget: [RelayTargetApp: RelayExternalActiveChoice]
    let currentLabel: String
    let hasActiveRelay: Bool
    let canRestoreOfficial: Bool
    let loadError: String?

    init(
        optionsByTarget: [RelayTargetApp: [RelayQuickSwitchOption]],
        selectionByTarget: [RelayTargetApp: RelayQuickSwitchSelection],
        activeProfileIDsByTarget: [RelayTargetApp: UUID],
        externalActiveByTarget: [RelayTargetApp: RelayExternalActiveChoice] = [:],
        currentLabel: String,
        hasActiveRelay: Bool,
        canRestoreOfficial: Bool,
        loadError: String?)
    {
        self.optionsByTarget = optionsByTarget
        self.selectionByTarget = selectionByTarget
        self.activeProfileIDsByTarget = activeProfileIDsByTarget
        self.externalActiveByTarget = externalActiveByTarget
        self.currentLabel = currentLabel
        self.hasActiveRelay = hasActiveRelay
        self.canRestoreOfficial = canRestoreOfficial
        self.loadError = loadError
    }
}

struct RelayQuickSwitchOutcome: Equatable {
    let succeeded: Bool
    let selection: RelayQuickSwitchSelection
    let message: String
    let requiresConfirmation: Bool
    let warning: String?
    let suggestsSettings: Bool

    init(
        succeeded: Bool,
        selection: RelayQuickSwitchSelection,
        message: String,
        requiresConfirmation: Bool = false,
        warning: String? = nil,
        suggestsSettings: Bool = false)
    {
        self.succeeded = succeeded
        self.selection = selection
        self.message = message
        self.requiresConfirmation = requiresConfirmation
        self.warning = warning
        self.suggestsSettings = suggestsSettings
    }
}

struct RelayQuickSwitchOptimisticSelectionState {
    private(set) var fingerprint: String
    private var snapshotSelections: [RelayTargetApp: RelayQuickSwitchSelection]
    private var optimisticSelections: [RelayTargetApp: RelayQuickSwitchSelection] = [:]

    init(
        fingerprint: String,
        snapshotSelections: [RelayTargetApp: RelayQuickSwitchSelection])
    {
        self.fingerprint = fingerprint
        self.snapshotSelections = snapshotSelections
    }

    var hasOptimisticSelections: Bool {
        !self.optimisticSelections.isEmpty
    }

    func selection(
        for target: RelayTargetApp,
        fingerprint: String,
        snapshotSelection: RelayQuickSwitchSelection?) -> RelayQuickSwitchSelection
    {
        guard fingerprint == self.fingerprint else {
            return snapshotSelection ?? .official(target)
        }
        return self.optimisticSelections[target]
            ?? snapshotSelection
            ?? self.snapshotSelections[target]
            ?? .official(target)
    }

    mutating func record(_ outcome: RelayQuickSwitchOutcome) {
        guard outcome.succeeded else { return }
        switch outcome.selection {
        case let .official(target), let .profile(target, _), let .external(target, _):
            self.optimisticSelections[target] = outcome.selection
        case .mixed:
            break
        }
    }

    mutating func reconcile(
        fingerprint: String,
        snapshotSelections: [RelayTargetApp: RelayQuickSwitchSelection])
    {
        self.fingerprint = fingerprint
        self.snapshotSelections = snapshotSelections
        self.optimisticSelections.removeAll(keepingCapacity: true)
    }
}

enum RelayOfficialChoicePresentation {
    static let isReady = true
}

struct RelayUsageRefreshOutcome: Equatable {
    let succeeded: Bool
    let message: String
}

struct RelayQuickSwitchFeedback: Equatable {
    static let height: CGFloat = 32

    static func height(message: String?) -> CGFloat {
        guard let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return 0
        }
        return Self.height
    }

    private(set) var message: String?
    private(set) var suggestsSettings = false

    var displayMessage: String? {
        guard let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return message
    }

    mutating func record(_ outcome: RelayQuickSwitchOutcome) {
        self.message = outcome.warning ?? (outcome.succeeded || outcome.requiresConfirmation ? nil : outcome.message)
        self.suggestsSettings = outcome.suggestsSettings
    }
}

/// The relay usage card is a display-only profile picker. It deliberately has no relay action
/// closures: selecting an item only changes which cached usage summary the card presents.
struct RelayUsageCardProfileSelection {
    static let defaultsKey = "menu.relayUsageCardProfileID"

    let options: [RelayQuickSwitchOption]
    let activeProfileID: UUID?
    private let defaults: UserDefaults

    init(
        options: [RelayQuickSwitchOption],
        activeProfileID: UUID?,
        defaults: UserDefaults = CodexBarPreferences.processDefaults)
    {
        self.options = options
        self.activeProfileID = activeProfileID
        self.defaults = defaults
    }

    var showsSelector: Bool {
        self.options.count >= 2
    }

    var selectedProfileID: UUID? {
        let stored = self.defaults.string(forKey: Self.defaultsKey).flatMap(UUID.init(uuidString:))
        if let stored, self.options.contains(where: { $0.id == stored }) {
            return stored
        }
        if let active = self.activeProfileID, self.options.contains(where: { $0.id == active }) {
            return active
        }
        return self.options.first?.id
    }

    mutating func select(_ profileID: UUID) {
        guard self.options.contains(where: { $0.id == profileID }) else { return }
        self.defaults.set(profileID.uuidString, forKey: Self.defaultsKey)
    }

    static func candidateProfiles(from profiles: [RelayProfile]) -> [RelayProfile] {
        profiles.filter { $0.usageQueryMode != .disabled }
    }

    static func options(
        from profiles: [RelayProfile],
        target: RelayTargetApp = .codex,
        localMeteredProviderKeys: Set<String> = [],
        loadUsageSummary: (UUID) -> RelayUsageSummary?)
        -> [RelayQuickSwitchOption]
    {
        let candidates = profiles.filter { profile in
            profile.usageQueryMode != .disabled || localMeteredProviderKeys.contains(profile.providerKey)
        }
        return candidates.map { profile in
            let format = profile.configuration(for: target)?.apiFormatOverride ?? profile.apiFormat
            let enabledTargets = Set(profile.targets.filter(\.isEnabled).map(\.app))
            return RelayQuickSwitchOption(
                id: profile.id,
                name: profile.name,
                isReady: profile.credentialConfigured,
                blocker: profile.credentialConfigured ? nil : L("relay_usage_card_missing_credential"),
                usageSummary: loadUsageSummary(profile.id),
                apiFormat: format,
                providerKey: profile.providerKey,
                enabledTargets: enabledTargets)
        }
    }
}

@MainActor
final class RelayQuickSwitchCoordinator {
    private let actions: RelaySettingsActions
    private let routesDomain: any RoutesDomain
    private let logger = CodexBarLog.logger(LogCategories.settings)

    init(actions: RelaySettingsActions? = nil, routesDomain: (any RoutesDomain)? = nil) {
        #if DEBUG
        if actions == nil, SettingsStore.isRunningTests {
            let isolatedActions = RelaySettingsActions.isolatedForTesting()
            self.actions = isolatedActions
            self.routesDomain = routesDomain ?? LiveRoutesDomain(actions: isolatedActions)
            return
        }
        #endif
        let resolvedActions = actions ?? .live()
        self.actions = resolvedActions
        self.routesDomain = routesDomain ?? LiveRoutesDomain(actions: resolvedActions)
    }

    func snapshot() -> RelayQuickSwitchSnapshot {
        do {
            let profiles = try self.routesDomain.profiles()
            let activation = self.actions.loadActivationState()
            let storedActiveByTarget = activation?.activeProfileIDsByTarget ?? [:]
            let externalReport = self.actions.inspectExternalConfiguration(profiles)
            let managedTargets = RelayTargetApp.allCases.filter { $0 != .claudeDesktop }

            var activeByTarget = storedActiveByTarget
            var externalActiveByTarget: [RelayTargetApp: RelayExternalActiveChoice] = [:]
            if let externalReport {
                for target in managedTargets {
                    guard let liveRoute = externalReport.liveRouteByTarget[target] else { continue }
                    switch liveRoute {
                    case let .managedProfile(profileID):
                        activeByTarget[target] = profileID
                    case let .external(detail, displayName):
                        activeByTarget.removeValue(forKey: target)
                        externalActiveByTarget[target] = RelayExternalActiveChoice(
                            providerID: detail.providerID,
                            displayName: displayName,
                            baseURL: detail.baseURL.absoluteString,
                            model: detail.model)
                    case .official:
                        activeByTarget.removeValue(forKey: target)
                    }
                }
            }

            let currentLabel: String = self.summaryLabel(
                profiles: profiles,
                activeByTarget: activeByTarget,
                externalByTarget: externalActiveByTarget,
                managedTargets: managedTargets)
            var optionsByTarget: [RelayTargetApp: [RelayQuickSwitchOption]] = [:]
            for target in managedTargets {
                optionsByTarget[target] = try profiles.compactMap { profile in
                    guard let configuration = profile.configuration(for: target), configuration.isEnabled else {
                        return nil
                    }
                    let storedCredential = try self.actions.loadCredential(profile.credentialReference)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let blocker: String? = if let profileBlocker = Self.readinessBlocker(
                        for: profile,
                        target: target)
                    {
                        profileBlocker
                    } else if storedCredential?.isEmpty == false {
                        nil
                    } else {
                        L("relay_menu_resave_api_key")
                    }
                    return RelayQuickSwitchOption(
                        id: profile.id,
                        name: profile.name,
                        isReady: blocker == nil,
                        blocker: blocker,
                        usageSummary: self.actions.loadUsageSummary(profile.id),
                        apiFormat: configuration.apiFormatOverride ?? profile.apiFormat,
                        providerKey: profile.providerKey,
                        enabledTargets: Set(profile.targets.filter(\.isEnabled).map(\.app)))
                }
            }
            let selectionByTarget = Dictionary(uniqueKeysWithValues: managedTargets.map { target in
                if let id = activeByTarget[target] {
                    return (target, RelayQuickSwitchSelection.profile(target, id))
                }
                if let ext = externalActiveByTarget[target] {
                    return (target, RelayQuickSwitchSelection.external(target, ext.displayName))
                }
                return (target, RelayQuickSwitchSelection.official(target))
            })
            return RelayQuickSwitchSnapshot(
                optionsByTarget: optionsByTarget,
                selectionByTarget: selectionByTarget,
                activeProfileIDsByTarget: activeByTarget,
                externalActiveByTarget: externalActiveByTarget,
                currentLabel: currentLabel,
                hasActiveRelay: !activeByTarget.isEmpty || !externalActiveByTarget.isEmpty,
                canRestoreOfficial: activation != nil || !externalActiveByTarget.isEmpty,
                loadError: nil)
        } catch {
            return RelayQuickSwitchSnapshot(
                optionsByTarget: [:],
                selectionByTarget: [:],
                activeProfileIDsByTarget: [:],
                externalActiveByTarget: [:],
                currentLabel: L("relay_menu_load_failed"),
                hasActiveRelay: false,
                canRestoreOfficial: false,
                loadError: Self.errorMessage(error))
        }
    }

    var codexSpeedActions: CodexSpeedActions {
        self.actions.codexSpeed
    }

    func usageCardProfileOptions(localMeteredProviderKeys: Set<String> = []) -> [RelayQuickSwitchOption] {
        do {
            let profiles = try self.routesDomain.profiles()
            return RelayUsageCardProfileSelection.options(
                from: profiles,
                target: .codex,
                localMeteredProviderKeys: localMeteredProviderKeys,
                loadUsageSummary: self.actions.loadUsageSummary)
        } catch {
            self.logger.debug("Unable to load relay usage card profiles", metadata: ["error": "\(error)"])
            return []
        }
    }

    private func summaryLabel(
        profiles: [RelayProfile],
        activeByTarget: [RelayTargetApp: UUID],
        externalByTarget: [RelayTargetApp: RelayExternalActiveChoice],
        managedTargets: [RelayTargetApp]) -> String
    {
        guard !activeByTarget.isEmpty || !externalByTarget.isEmpty else { return L("relay_menu_label_official") }
        if activeByTarget.isEmpty,
           externalByTarget.count == 1,
           let only = externalByTarget.values.first
        {
            return L("relay_quick_switch_external_chip", only.displayName)
        }
        let ids = Set(activeByTarget.values)
        if externalByTarget.isEmpty,
           ids.count == 1,
           activeByTarget.count == 1,
           let id = ids.first,
           let profile = profiles.first(where: { $0.id == id })
        {
            return profile.name
        }
        if externalByTarget.isEmpty,
           ids.count == 1,
           let id = ids.first,
           let profile = profiles.first(where: { $0.id == id }),
           managedTargets.allSatisfy({ target in activeByTarget[target] == id })
        {
            return profile.name
        }
        let parts = managedTargets.compactMap { target -> String? in
            if let id = activeByTarget[target] {
                let source = profiles.first(where: { $0.id == id })?.name ?? L("relay_menu_label_relay")
                return "\(Self.targetLabel(target)) \(source)"
            }
            if let ext = externalByTarget[target] {
                return "\(Self.targetLabel(target)) \(ext.chipTitle)"
            }
            return nil
        }
        return parts.isEmpty
            ? L("relay_menu_label_mixed")
            : L("relay_menu_label_mixed_prefix") + " · " + parts.joined(separator: " · ")
    }

    func refreshUsage(profileID: UUID, force: Bool = true) async -> RelayUsageRefreshOutcome {
        do {
            if !force, let cached = self.actions.loadFreshUsageSummary(profileID, Date()) {
                return RelayUsageRefreshOutcome(
                    succeeded: true,
                    message: L("relay_usage_cached", Self.cachedDateText(cached.updatedAt)))
            }
            let profiles = try self.routesDomain.profiles()
            guard let profile = profiles.first(where: { $0.id == profileID }) else {
                return RelayUsageRefreshOutcome(succeeded: false, message: L("relay_menu_profile_missing"))
            }
            guard profile.usageQueryMode != .disabled else {
                return RelayUsageRefreshOutcome(succeeded: false, message: L("relay_menu_usage_disabled"))
            }
            guard let credential = try self.actions.loadCredential(profile.credentialReference)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !credential.isEmpty
            else {
                return RelayUsageRefreshOutcome(succeeded: false, message: L("relay_ui_usage_error_no_key"))
            }
            let summary = try await self.actions.fetchUsageSummary(profile, credential)
            try self.actions.storeUsageSummary(summary, profile.id)
            return RelayUsageRefreshOutcome(succeeded: true, message: L("relay_menu_usage_refreshed", profile.name))
        } catch {
            self.actions.recordUsageFailure(profileID, Self.errorMessage(error), Date())
            return RelayUsageRefreshOutcome(succeeded: false, message: Self.errorMessage(error))
        }
    }

    private static func cachedDateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    func select(
        _ selection: RelayQuickSwitchSelection,
        confirmed: Bool = true) -> RelayQuickSwitchOutcome
    {
        switch selection {
        case let .official(target):
            return self.restoreOfficialConfiguration(target: target)
        case let .profile(target, id):
            if target == .codex,
               !self.actions.loadUnifiedHistoryEnabled(),
               self.actions.hasCodexHistory(),
               !confirmed
            {
                return RelayQuickSwitchOutcome(
                    succeeded: false,
                    selection: selection,
                    message: L("relay_menu_requires_migration"),
                    requiresConfirmation: true)
            }
            var migrationWarning: String?
            if target == .codex, !self.actions.loadUnifiedHistoryEnabled() {
                do {
                    // Capture the original client files before the history migration rewrites
                    // Codex's provider mode.  `applyProfile` will reuse this baseline, so a later
                    // target-scoped restore can really return Codex to the pre-migration state.
                    if self.actions.loadActivationState() == nil {
                        let baseline = try self.actions.captureBaseline()
                        self.actions.storeActivationState(
                            RelayActivationState(
                                activeProfileIDsByTarget: [:],
                                baselineBackupDirectory: baseline))
                    }
                    _ = try self.actions.enableUnifiedHistory()
                } catch {
                    migrationWarning = L(
                        "relay_switch_history_warning",
                        Self.errorMessage(error))
                    self.logger.warning(
                        "Unified Codex history migration failed; continuing relay switch",
                        metadata: ["error": Self.errorMessage(error)])
                }
            }
            let outcome = self.applyRoute(id: id, target: target)
            guard outcome.succeeded, let migrationWarning else { return outcome }
            return RelayQuickSwitchOutcome(
                succeeded: true,
                selection: outcome.selection,
                message: outcome.message,
                warning: migrationWarning)
        case let .external(target, name):
            return RelayQuickSwitchOutcome(
                succeeded: false,
                selection: .external(target, name),
                message: L("relay_quick_switch_external_manage_hint", name),
                suggestsSettings: true)
        case .mixed:
            return RelayQuickSwitchOutcome(
                succeeded: false,
                selection: .mixed,
                message: L("relay_menu_mixed_not_target"))
        }
    }

    static func readinessBlocker(for profile: RelayProfile, target: RelayTargetApp) -> String? {
        guard target != .claudeDesktop else { return nil }
        guard let configuration = profile.targets.first(where: { $0.app == target }) else {
            return L("relay_menu_target_not_enabled")
        }
        guard configuration.isEnabled else {
            return L("relay_menu_target_not_allowed", Self.targetLabel(target))
        }
        guard profile.credentialConfigured else { return L("relay_usage_card_missing_credential") }
        if let incompatibility = RelaySettingsModel.incompatibilityReason(
            target: target,
            format: configuration.apiFormatOverride ?? profile.apiFormat)
        {
            return incompatibility
        }
        let model = configuration.model ?? profile.defaultModel
        guard model?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return L("relay_menu_model_id_required", Self.targetLabel(target))
        }
        return nil
    }

    private func applyRoute(id: UUID, target: RelayTargetApp) -> RelayQuickSwitchOutcome {
        do {
            let profiles = try self.routesDomain.profiles()
            guard let profile = profiles.first(where: { $0.id == id }) else {
                return RelayQuickSwitchOutcome(
                    succeeded: false,
                    selection: .official(target),
                    message: L("relay_menu_profile_missing"))
            }
            if let blocker = Self.readinessBlocker(for: profile, target: target) {
                let model = (profile.configuration(for: target)?.model ?? profile.defaultModel)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return RelayQuickSwitchOutcome(
                    succeeded: false,
                    selection: .profile(target, id),
                    message: blocker,
                    suggestsSettings: target != .claudeDesktop && model?.isEmpty != false)
            }
            guard try self.actions.loadCredential(profile.credentialReference)?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            else {
                return RelayQuickSwitchOutcome(
                    succeeded: false,
                    selection: .profile(target, id),
                    message: L("relay_menu_resave_api_key"))
            }

            var activation = self.actions.loadActivationState()
            if activation == nil {
                let baseline = try self.actions.captureBaseline()
                let baselineState = RelayActivationState(
                    activeProfileIDsByTarget: [:],
                    baselineBackupDirectory: baseline)
                self.actions.storeActivationState(baselineState)
                activation = baselineState
            }

            let targetOnlyProfile = RelayProfile(
                id: profile.id,
                name: profile.name,
                baseURL: profile.baseURL,
                apiFormat: profile.apiFormat,
                defaultModel: profile.defaultModel,
                credentialReference: profile.credentialReference,
                credentialConfigured: profile.credentialConfigured,
                usageQueryMode: profile.usageQueryMode,
                customBalance: profile.customBalance,
                targets: profile.targets.map { configuration in
                    var scoped = configuration
                    scoped.isEnabled = configuration.app == target
                    return scoped
                },
                visibleTargets: profile.visibleTargets,
                providerKey: profile.providerKey)
            let result = try self.routesDomain.apply(targetOnlyProfile)
            guard let currentState = activation else {
                return RelayQuickSwitchOutcome(
                    succeeded: false,
                    selection: .profile(target, id),
                    message: L("relay_ui_error_baseline_backup"))
            }
            var activeProfiles = currentState.activeProfileIDsByTarget
            activeProfiles[target] = profile.id
            let updatedState = RelayActivationState(
                activeProfileIDsByTarget: activeProfiles,
                baselineBackupDirectory: currentState.baselineBackupDirectory)
            self.actions.storeActivationState(updatedState)
            self.actions.invalidateKeychainReadCache()
            self.actions.notifyRouteApplicationSucceeded()
            if let backup = result.backupDirectory {
                try self.actions.discardBackup(backup)
            }
            return RelayQuickSwitchOutcome(
                succeeded: true,
                selection: .profile(target, id),
                message: L("relay_menu_switched", Self.targetLabel(target), profile.name))
        } catch {
            return RelayQuickSwitchOutcome(
                succeeded: false,
                selection: .profile(target, id),
                message: Self.errorMessage(error))
        }
    }

    private func restoreOfficialConfiguration(target: RelayTargetApp) -> RelayQuickSwitchOutcome {
        let profiles = (try? self.routesDomain.profiles()) ?? []
        let liveRoute = self.actions.inspectExternalConfiguration(profiles)?.liveRouteByTarget[target]
        let hasExternalOrImportedLiveRoute: Bool = switch liveRoute {
        case .external, .managedProfile: true
        case .official, nil: false
        }

        guard let activation = self.actions.loadActivationState(),
              activation.activeProfileIDsByTarget[target] != nil
        else {
            guard hasExternalOrImportedLiveRoute else {
                return RelayQuickSwitchOutcome(
                    succeeded: true,
                    selection: .official(target),
                    message: L("relay_menu_already_official", Self.targetLabel(target)))
            }
            do {
                _ = try self.actions.clearExternalRouteForTarget(target)
                self.actions.invalidateKeychainReadCache()
                self.actions.notifyRouteApplicationSucceeded()
                return RelayQuickSwitchOutcome(
                    succeeded: true,
                    selection: .official(target),
                    message: target == .codex && !self.actions.isCodexLoggedIn()
                        ? L("relay_restore_official_not_logged_in")
                        : L("relay_restore_official", Self.targetLabel(target)))
            } catch {
                return RelayQuickSwitchOutcome(
                    succeeded: false,
                    selection: .official(target),
                    message: Self.errorMessage(error))
            }
        }
        do {
            let result: RelaySwitchResult = if let restoreBaselineForTargets = self.actions.restoreBaselineForTargets {
                try restoreBaselineForTargets(activation.baselineBackupDirectory, [target])
            } else {
                try self.actions.restoreBaseline(activation.baselineBackupDirectory)
            }
            var activeProfiles = activation.activeProfileIDsByTarget
            activeProfiles.removeValue(forKey: target)
            if activeProfiles.isEmpty {
                self.actions.clearActivationState()
            } else {
                self.actions.storeActivationState(
                    RelayActivationState(
                        activeProfileIDsByTarget: activeProfiles,
                        baselineBackupDirectory: activation.baselineBackupDirectory))
            }
            self.actions.invalidateKeychainReadCache()
            var directories: [URL] = []
            if let backup = result.backupDirectory {
                directories.append(backup)
            }
            if activeProfiles.isEmpty { directories.append(activation.baselineBackupDirectory) }
            for directory in directories {
                try self.actions.discardBackup(directory)
            }
            return RelayQuickSwitchOutcome(
                succeeded: true,
                selection: .official(target),
                message: target == .codex && !self.actions.isCodexLoggedIn()
                    ? L("relay_restore_official_not_logged_in")
                    : L("relay_restore_official", Self.targetLabel(target)))
        } catch {
            return RelayQuickSwitchOutcome(
                succeeded: false,
                selection: .official(target),
                message: Self.errorMessage(error))
        }
    }

    private static func targetLabel(_ target: RelayTargetApp) -> String {
        switch target {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        case .claudeDesktop: "Claude Desktop"
        case .grokBuild: "Grok Build"
        case .openCode: "OpenCode"
        case .piAgent: "Pi Agent"
        }
    }

    private static func errorMessage(_ error: any Error) -> String {
        if let localized = error as? any LocalizedError, let description = localized.errorDescription {
            return description
        }
        return L("relay_menu_switch_failed", String(describing: type(of: error)))
    }
}

@MainActor
struct RelayQuickSwitchMenuView: View {
    let snapshot: RelayQuickSwitchSnapshot
    let width: CGFloat
    let visibleTargets: [RelayTargetApp]
    let onSelect: (RelayQuickSwitchSelection, Bool) -> RelayQuickSwitchOutcome
    let onOpenSettings: () -> Void
    let codexSpeedActions: CodexSpeedActions
    let onFeedbackPresenceChange: @MainActor @Sendable () -> Void

    @State private var selectionState: RelayQuickSwitchOptimisticSelectionState
    @State private var feedback = RelayQuickSwitchFeedback()

    init(
        snapshot: RelayQuickSwitchSnapshot,
        width: CGFloat,
        visibleTargets: [RelayTargetApp] = RelayTargetApp.headroomManagedTargets,
        onSelect: @escaping (RelayQuickSwitchSelection, Bool) -> RelayQuickSwitchOutcome,
        onOpenSettings: @escaping () -> Void,
        codexSpeedActions: CodexSpeedActions = CodexSpeedActions(),
        onFeedbackPresenceChange: @escaping @MainActor @Sendable () -> Void = {})
    {
        self.snapshot = snapshot
        self.width = width
        self.visibleTargets = visibleTargets
        self.onSelect = onSelect
        self.onOpenSettings = onOpenSettings
        self.codexSpeedActions = codexSpeedActions
        self.onFeedbackPresenceChange = onFeedbackPresenceChange
        self._selectionState = State(initialValue: RelayQuickSwitchOptimisticSelectionState(
            fingerprint: Self.selectionFingerprint(snapshot: snapshot, visibleTargets: visibleTargets),
            snapshotSelections: snapshot.selectionByTarget))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RelayQuickSwitchPresentation.interitemSpacing) {
            ForEach(Array(self.visibleTargets.enumerated()), id: \.element) { index, target in
                self.targetRow(target, showsSettings: index == 0)
                if target == .codex {
                    CodexSpeedControl(actions: self.codexSpeedActions)
                        .id(self.selectionFingerprint)
                }
            }

            self.feedbackRow
            if self.visibleTargets.contains(where: { self.snapshot.optionsByTarget[$0] == nil }),
               let loadError = self.snapshot.loadError
            {
                Text(loadError)
                    .font(.caption2)
                    .foregroundStyle(ConsoleDesign.secondaryText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, RelayQuickSwitchPresentation.verticalPadding)
        .frame(width: self.width, alignment: .leading)
        .background(ConsoleDesign.background)
        .preferredColorScheme(ConsoleDesign.preferredColorScheme)
        .onChange(of: self.selectionFingerprint) { _, fingerprint in
            let hadFeedback = RelayQuickSwitchFeedback.height(message: self.feedback.message) > 0
            self.selectionState.reconcile(
                fingerprint: fingerprint,
                snapshotSelections: self.snapshot.selectionByTarget)
            self.feedback = RelayQuickSwitchFeedback()
            if hadFeedback {
                DispatchQueue.main.async(execute: self.onFeedbackPresenceChange)
            }
        }
    }

    private func targetRow(_ target: RelayTargetApp, showsSettings: Bool) -> some View {
        let options = self.snapshot.optionsByTarget[target] ?? []
        let selected = self.selectionState.selection(
            for: target,
            fingerprint: self.selectionFingerprint,
            snapshotSelection: self.snapshot.selectionByTarget[target])
        let presentation = RelayQuickSwitchPresentation(visibleTargets: self.visibleTargets)
        return HStack(alignment: .top, spacing: RelayQuickSwitchPresentation.interitemSpacing) {
            if presentation.showsTargetLabels {
                Text(RelayQuickSwitchPresentation.targetLabel(target))
                    .font(ConsoleDesign.mono(10, weight: .semibold))
                    .foregroundStyle(ConsoleDesign.primaryText)
                    .frame(width: presentation.targetLabelWidth, alignment: .leading)
            }
            RelayQuickSwitchFlowLayout(spacing: RelayQuickSwitchPresentation.interitemSpacing) {
                RelayQuickSwitchChoice(
                    title: RelayQuickSwitchPresentation.officialChoiceLabel,
                    isSelected: selected == .official(target),
                    isReady: RelayOfficialChoicePresentation.isReady,
                    helpText: nil)
                {
                    self.perform(.official(target))
                }
                ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                    RelayQuickSwitchChoice(
                        title: option.name,
                        isSelected: selected == .profile(target, option.id),
                        isReady: option.isReady,
                        helpText: option.blocker,
                        dotColor: ConsoleDesign.providerSeries[index % ConsoleDesign.providerSeries.count])
                    {
                        self.perform(.profile(target, option.id))
                    }
                }
                if let externalChoice = self.snapshot.externalActiveByTarget[target] {
                    RelayQuickSwitchChoice(
                        title: externalChoice.chipTitle,
                        isSelected: selected == .external(target, externalChoice.displayName),
                        isReady: true,
                        helpText: externalChoice.helpText,
                        dotColor: ConsoleDesign.accent)
                    {
                        self.onOpenSettings()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showsSettings {
                Button(action: self.onOpenSettings) {
                    Image(systemName: "gearshape.fill")
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .menuCardInteractiveControl()
                .help(L("relay_open_settings"))
            }
        }
    }

    @ViewBuilder
    private var feedbackRow: some View {
        if let message = self.feedback.displayMessage {
            HStack(alignment: .center, spacing: 6) {
                Text(message)
                    .font(ConsoleDesign.mono(9))
                    .foregroundStyle(ConsoleDesign.criticalForeground)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if self.feedback.suggestsSettings {
                    Button(action: self.onOpenSettings) {
                        Image(systemName: "gearshape.fill")
                    }
                    .buttonStyle(.plain)
                    .menuCardInteractiveControl()
                    .help(L("relay_open_settings"))
                }
                Button(action: self.showFeedbackDetails) {
                    Image(systemName: "info.circle.fill")
                }
                .buttonStyle(.plain)
                .menuCardInteractiveControl()
                .help(L("relay_feedback_details"))
            }
            .frame(
                maxWidth: .infinity,
                minHeight: RelayQuickSwitchFeedback.height,
                maxHeight: RelayQuickSwitchFeedback.height,
                alignment: .leading)
        }
    }

    private func perform(_ target: RelayQuickSwitchSelection, confirmed: Bool = false) {
        let hadFeedback = RelayQuickSwitchFeedback.height(message: self.feedback.message) > 0
        let outcome = self.onSelect(target, confirmed)
        self.feedback.record(outcome)
        self.selectionState.record(outcome)
        let hasFeedback = RelayQuickSwitchFeedback.height(message: self.feedback.message) > 0
        if hasFeedback != hadFeedback {
            DispatchQueue.main.async(execute: self.onFeedbackPresenceChange)
        }
        if outcome.requiresConfirmation {
            DispatchQueue.main.async {
                self.confirmHistoryMigration(for: target)
            }
        }
    }

    private func confirmHistoryMigration(for target: RelayQuickSwitchSelection) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L("relay_history_confirmation_title")
        alert.informativeText = L("relay_history_confirmation_message")
        alert.addButton(withTitle: L("relay_history_confirmation_action"))
        alert.addButton(withTitle: L("cancel"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            self.perform(target, confirmed: true)
        }
    }

    private func showFeedbackDetails() {
        guard let message = self.feedback.displayMessage else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("relay_feedback_details_title")
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: L("copy"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message, forType: .string)
        }
    }

    private var selectionFingerprint: String {
        Self.selectionFingerprint(snapshot: self.snapshot, visibleTargets: self.visibleTargets)
    }

    private static func selectionFingerprint(
        snapshot: RelayQuickSwitchSnapshot,
        visibleTargets: [RelayTargetApp]) -> String
    {
        visibleTargets.map { target in
            let selection = snapshot.selectionByTarget[target]?.cacheDescription ?? "official:\(target.rawValue)"
            let options = (snapshot.optionsByTarget[target] ?? []).map { option in
                [
                    option.id.uuidString,
                    option.isReady ? "ready" : "blocked",
                    option.blocker ?? "",
                ].joined(separator: ":")
            }.joined(separator: ",")
            return "\(target.rawValue)=\(selection)[\(options)]"
        }.joined(separator: "|")
    }
}

struct RelayQuickSwitchFlowLayout: Layout {
    let spacing: CGFloat

    static func rowCount(itemWidths: [CGFloat], availableWidth: CGFloat, spacing: CGFloat) -> Int {
        guard !itemWidths.isEmpty else { return 0 }
        var rows = 1
        var currentWidth: CGFloat = 0
        for width in itemWidths {
            let proposedWidth = currentWidth == 0 ? width : currentWidth + spacing + width
            if currentWidth > 0, proposedWidth > availableWidth {
                rows += 1
                currentWidth = width
            } else {
                currentWidth = proposedWidth
            }
        }
        return rows
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()) -> CGSize
    {
        let layout = self.layout(subviews: subviews, availableWidth: proposal.width ?? .greatestFiniteMagnitude)
        return CGSize(width: proposal.width ?? layout.width, height: layout.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ())
    {
        let layout = self.layout(subviews: subviews, availableWidth: bounds.width)
        for (index, origin) in layout.origins.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: .unspecified)
        }
    }

    private func layout(subviews: Subviews, availableWidth: CGFloat) ->
        (origins: [CGPoint], width: CGFloat, height: CGFloat)
    {
        var origins: [CGPoint] = []
        var cursor = CGPoint.zero
        var rowHeight: CGFloat = 0
        var contentWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if cursor.x > 0, cursor.x + size.width > availableWidth {
                cursor.x = 0
                cursor.y += rowHeight + self.spacing
                rowHeight = 0
            }
            origins.append(cursor)
            contentWidth = max(contentWidth, cursor.x + size.width)
            cursor.x += size.width + self.spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (origins, contentWidth, cursor.y + rowHeight)
    }
}

struct RelayQuickSwitchChoice: View {
    let title: String
    let isSelected: Bool
    let isReady: Bool
    let helpText: String?
    var dotColor: Color?
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            HStack(spacing: 5) {
                if let dotColor {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)
                }
                Text(self.title)
                    .font(ConsoleDesign.mono(10, weight: self.isSelected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .foregroundStyle(self.isSelected ? ConsoleDesign.primaryText : ConsoleDesign.secondaryText)
            .background(
                RoundedRectangle(cornerRadius: ConsoleDesign.radiusControl, style: .continuous)
                    .fill(self.isSelected ? ConsoleDesign.surface2 : ConsoleDesign.surface))
            .overlay {
                RoundedRectangle(cornerRadius: ConsoleDesign.radiusControl, style: .continuous)
                    .stroke(self.isSelected ? ConsoleDesign.accent : ConsoleDesign.border, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .opacity(self.isReady ? 1 : 0.48)
        .menuCardInteractiveControl()
        .help(self.helpText ?? "")
    }
}
