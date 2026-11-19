// swiftlint:disable file_length

import AppKit
import CodexBarCore
import Foundation
import Observation
import SwiftUI

@MainActor
struct RelaySettingsActions {
    let loadProfiles: () throws -> [RelayProfile]
    let storeProfiles: ([RelayProfile]) throws -> Void
    let loadCredential: (_ reference: String) throws -> String?
    let storeCredential: (_ credential: String, _ reference: String) throws -> Void
    let removeCredential: (_ reference: String) throws -> Void
    let captureBaseline: () throws -> URL
    let applyProfile: (_ profile: RelayProfile) throws -> RelaySwitchResult
    let restoreBaseline: (_ backupDirectory: URL) throws -> RelaySwitchResult
    /// Optional target-scoped restore hook. The legacy all-target hook remains available for
    /// injected test actions and older integrations; live actions always provide this closure.
    let restoreBaselineForTargets: ((_ backupDirectory: URL, _ targets: Set<RelayTargetApp>?) throws
        -> RelaySwitchResult)?
    let discardBackup: (_ backupDirectory: URL) throws -> Void
    let loadActivationState: () -> RelayActivationState?
    let storeActivationState: (RelayActivationState) -> Void
    let clearActivationState: () -> Void
    let loadUnifiedHistoryEnabled: () -> Bool
    let loadUnifiedHistoryOptIn: () -> Bool
    let storeUnifiedHistoryOptIn: (Bool) -> Void
    let hasCodexHistory: () -> Bool
    let isCodexLoggedIn: () -> Bool
    let enableUnifiedHistory: () throws -> CodexUnifiedHistoryMigrationOutcome
    let loadUsageSummary: (_ profileID: UUID) -> RelayUsageSummary?
    var loadFreshUsageSummary: (_ profileID: UUID, _ now: Date) -> RelayUsageSummary? = { _, _ in nil }
    let storeUsageSummary: (_ summary: RelayUsageSummary, _ profileID: UUID) throws -> Void
    var recordUsageFailure: (_ profileID: UUID, _ error: String, _ at: Date) -> Void = { _, _, _ in }
    let fetchUsageSummary: (_ profile: RelayProfile, _ apiKey: String) async throws -> RelayUsageSummary
    var loadLocalCodexUsage: (_ profileID: UUID) async -> CodexRelayLocalUsagePresentation? = { _ in nil }
    var scrubInlineCredentials: (_ providerKeys: Set<String>) throws -> Void = { _ in }
    var inspectExternalConfiguration: (_ profiles: [RelayProfile]) -> RelayExternalConfigurationReport? = { _ in nil }
    var clearExternalRouteForTarget: (_ target: RelayTargetApp) throws -> RelaySwitchResult = { _ in
        RelaySwitchResult(
            preview: RelaySwitchPreview(changedTargets: [], unchangedTargets: [], changedFileCount: 0),
            wasDryRun: false,
            backupDirectory: nil)
    }

    var invalidateKeychainReadCache: () -> Void = {
        KeychainSecurity.invalidateCopyMatchingCacheForProfileChange()
    }

    var notifyRouteApplicationSucceeded: () -> Void = {}
    var codexSpeed = CodexSpeedActions()

    #if DEBUG
    static func isolatedForTesting() -> Self {
        Self(
            loadProfiles: { [] },
            storeProfiles: { _ in },
            loadCredential: { _ in nil },
            storeCredential: { _, _ in },
            removeCredential: { _ in },
            captureBaseline: { throw RelaySettingsActionsTestingError.unsupported },
            applyProfile: { _ in throw RelaySettingsActionsTestingError.unsupported },
            restoreBaseline: { _ in throw RelaySettingsActionsTestingError.unsupported },
            restoreBaselineForTargets: nil,
            discardBackup: { _ in },
            loadActivationState: { nil },
            storeActivationState: { _ in },
            clearActivationState: {},
            loadUnifiedHistoryEnabled: { true },
            loadUnifiedHistoryOptIn: { true },
            storeUnifiedHistoryOptIn: { _ in },
            hasCodexHistory: { false },
            isCodexLoggedIn: { true },
            enableUnifiedHistory: { throw RelaySettingsActionsTestingError.unsupported },
            loadUsageSummary: { _ in nil },
            storeUsageSummary: { _, _ in },
            fetchUsageSummary: { _, _ in throw RelaySettingsActionsTestingError.unsupported })
    }
    #endif

    // swiftlint:disable:next function_body_length
    static func live() -> Self {
        let profileStore = FileRelayProfileStore()
        let credentialStore = FileRelayCredentialStore()
        let transaction = RelayConfigurationTransaction()
        let paths = RelayConfigurationPaths.standard(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        let activationStore = UserDefaultsRelayActivationStateStore()
        let unifiedHistoryStore = UserDefaultsCodexUnifiedHistoryStore()
        let usageStore = FileRelayUsageSummaryStore()
        let codexRouteStore = FileCodexSessionOwnershipTimelineStore.default
        let speedActions = CodexSpeedActions.live(paths: paths, transaction: transaction)
        var actions = Self(
            loadProfiles: { try profileStore.loadProfiles() },
            storeProfiles: { try profileStore.storeProfiles($0) },
            loadCredential: { try credentialStore.loadCredential(reference: $0) },
            storeCredential: { try credentialStore.storeCredential($0, reference: $1) },
            removeCredential: { try credentialStore.removeCredential(reference: $0) },
            captureBaseline: { try transaction.captureBaseline(paths: paths) },
            applyProfile: {
                let profile = $0
                let changesCodex = profile.configuration(for: .codex)?.isEnabled == true
                let incomingTier = changesCodex ? speedActions.tierForSwitch(to: profile.id) : nil
                let mutation = {
                    try transaction.apply(
                        profile: profile,
                        paths: paths,
                        credentialStore: credentialStore,
                        codexProviderMode: unifiedHistoryStore.isEnabled ? .unified : .isolated,
                        codexServiceTier: incomingTier)
                }
                guard profile.configuration(for: .codex)?.isEnabled == true else {
                    return try mutation()
                }
                return try CodexRouteMutationTransaction.perform(
                    store: codexRouteStore,
                    targetRoute: .relay(profileID: profile.id),
                    mutation: mutation)
            },
            restoreBaseline: {
                let backupDirectory = $0
                return try CodexRouteMutationTransaction.perform(
                    store: codexRouteStore,
                    targetRoute: .unknown,
                    committedRoute: {
                        CodexSessionRouteBootstrap.isVerifiedOfficialConfiguration(
                            paths: paths,
                            transaction: transaction,
                            fileSystem: LocalRelayConfigurationFileSystem()) ? .official : .unknown
                    },
                    mutation: {
                        try transaction.restore(
                            backupDirectory: backupDirectory,
                            paths: paths,
                            codexProviderMode: unifiedHistoryStore.isEnabled ? .unified : .isolated,
                            codexServiceTier: CodexSpeedPreferences().tier(for: .official))
                    })
            },
            restoreBaselineForTargets: { backupDirectory, targets in
                let mutation = {
                    try transaction.restore(
                        backupDirectory: backupDirectory,
                        paths: paths,
                        codexProviderMode: unifiedHistoryStore.isEnabled ? .unified : .isolated,
                        targets: targets,
                        codexServiceTier: CodexSpeedPreferences().tier(for: .official))
                }
                guard targets?.contains(.codex) != false else { return try mutation() }
                return try CodexRouteMutationTransaction.perform(
                    store: codexRouteStore,
                    targetRoute: .unknown,
                    committedRoute: {
                        CodexSessionRouteBootstrap.isVerifiedOfficialConfiguration(
                            paths: paths,
                            transaction: transaction,
                            fileSystem: LocalRelayConfigurationFileSystem()) ? .official : .unknown
                    },
                    mutation: mutation)
            },
            discardBackup: { try transaction.discardBackup(directory: $0, paths: paths) },
            loadActivationState: { activationStore.load() },
            storeActivationState: { activationStore.store($0) },
            clearActivationState: { activationStore.clear() },
            loadUnifiedHistoryEnabled: { unifiedHistoryStore.isEnabled },
            loadUnifiedHistoryOptIn: { unifiedHistoryStore.optIn },
            storeUnifiedHistoryOptIn: { unifiedHistoryStore.optIn = $0 },
            hasCodexHistory: { Self.codexHistoryExists(in: paths.codexConfigURL.deletingLastPathComponent()) },
            isCodexLoggedIn: {
                FileManager.default.fileExists(
                    atPath: paths.codexConfigURL.deletingLastPathComponent()
                        .appendingPathComponent("auth.json").path)
            },
            enableUnifiedHistory: {
                let switchResult: RelaySwitchResult = if let profileID = activationStore.load()?
                    .activeProfileIDsByTarget[.codex],
                    let profile = try profileStore.loadProfiles().first(where: { $0.id == profileID })
                {
                    try transaction.apply(
                        profile: profile,
                        paths: paths,
                        credentialStore: credentialStore,
                        codexProviderMode: .unified)
                } else {
                    try transaction.configureOfficialCodexUnified(paths: paths)
                }
                do {
                    let codexDirectory = paths.codexConfigURL.deletingLastPathComponent()
                    let migration = try CodexUnifiedHistoryMigrator(
                        codexDirectory: codexDirectory,
                        backupRootDirectory: paths.backupRootURL
                            .appendingPathComponent("UnifiedHistory", isDirectory: true))
                        .migrateExistingHistory()
                    unifiedHistoryStore.isEnabled = true
                    unifiedHistoryStore.optIn = true
                    if let backup = switchResult.backupDirectory {
                        // Cleanup is best-effort after the migration has committed. A cleanup
                        // failure must not roll live config back while history remains unified.
                        try? transaction.discardBackup(directory: backup, paths: paths)
                    }
                    return migration
                } catch {
                    if let backup = switchResult.backupDirectory {
                        if let safety = try? transaction.restore(backupDirectory: backup, paths: paths)
                            .backupDirectory
                        {
                            try? transaction.discardBackup(directory: safety, paths: paths)
                        }
                        try? transaction.discardBackup(directory: backup, paths: paths)
                    }
                    throw error
                }
            },
            loadUsageSummary: { usageStore.load(profileID: $0) },
            loadFreshUsageSummary: { usageStore.loadFresh(profileID: $0, now: $1) },
            storeUsageSummary: { try usageStore.store($0, profileID: $1) },
            recordUsageFailure: { profileID, error, at in try? usageStore.recordFailure(
                profileID: profileID,
                error: error,
                at: at) },
            fetchUsageSummary: { profile, apiKey in
                try await RelayUsageQueryFetcher.fetch(
                    mode: profile.usageQueryMode,
                    apiKey: apiKey,
                    baseURL: profile.baseURL,
                    customBalance: profile.customBalance)
            })
        actions.scrubInlineCredentials = { keys in
            _ = try transaction.scrubInlineCredentials(forProviderKeys: keys, paths: paths)
        }
        actions.inspectExternalConfiguration = { profiles in
            RelayExternalConfigurationInspector.inspect(paths: paths, profiles: profiles)
        }
        actions.clearExternalRouteForTarget = { target in
            let mutation = {
                let result = try transaction.restoreOfficialWithoutBaseline(
                    targets: [target],
                    paths: paths,
                    codexProviderMode: unifiedHistoryStore.isEnabled ? .unified : .isolated,
                    codexServiceTier: target == .codex ? CodexSpeedPreferences().tier(for: .official) : nil)
                if let backup = result.backupDirectory {
                    try? transaction.discardBackup(directory: backup, paths: paths)
                }
                return result
            }
            guard target == .codex else { return try mutation() }
            return try CodexRouteMutationTransaction.perform(
                store: codexRouteStore,
                targetRoute: .unknown,
                committedRoute: {
                    CodexSessionRouteBootstrap.isVerifiedOfficialConfiguration(
                        paths: paths,
                        transaction: transaction,
                        fileSystem: LocalRelayConfigurationFileSystem()) ? .official : .unknown
                },
                mutation: mutation)
        }
        actions.loadLocalCodexUsage = { await CodexRelayLocalUsageSource.load(profileID: $0) }
        actions.codexSpeed = speedActions
        actions.notifyRouteApplicationSucceeded = {
            NotificationCenter.default.post(name: .codexbarRelayConfigurationApplied, object: nil)
        }
        return actions
    }

    private static func codexHistoryExists(in codexDirectory: URL) -> Bool {
        let fileManager = FileManager.default
        for name in ["sessions", "archived_sessions"] {
            let directory = codexDirectory.appendingPathComponent(name, isDirectory: true)
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])
            else { continue }
            while let item = enumerator.nextObject() {
                if let url = item as? URL, url.pathExtension.lowercased() == "jsonl" {
                    return true
                }
            }
        }
        for relativePath in ["state_5.sqlite", "sqlite/state_5.sqlite"] {
            let url = codexDirectory.appendingPathComponent(relativePath)
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 {
                return true
            }
        }
        return false
    }
}

#if DEBUG
private enum RelaySettingsActionsTestingError: Error {
    case unsupported
}
#endif

@MainActor
enum CodexRouteMutationTransaction {
    static func perform<Result>(
        store: FileCodexSessionOwnershipTimelineStore,
        targetRoute: CodexSessionOwnershipTimeline.CodexRoute,
        committedRoute: (() -> CodexSessionOwnershipTimeline.CodexRoute)? = nil,
        now: () -> Date = Date.init,
        mutation: () throws -> Result) throws -> Result
    {
        let previousRoute = try store.load().codexRoute(atUnixMilliseconds: Int64.max)
        try store.recordUnknownCodexRoute(at: now())
        do {
            let result = try mutation()
            // The client configuration already committed. If provenance persistence now
            // fails, retain the unknown boundary instead of reporting a false config failure.
            try? self.record(committedRoute?() ?? targetRoute, store: store, at: now())
            return result
        } catch {
            if !self.rollbackFailed(error), let previousRoute {
                try? self.record(previousRoute, store: store, at: now())
            }
            throw error
        }
    }

    private static func record(
        _ route: CodexSessionOwnershipTimeline.CodexRoute,
        store: FileCodexSessionOwnershipTimelineStore,
        at date: Date) throws
    {
        switch route {
        case .official:
            try store.recordOfficialCodexRoute(at: date)
        case let .relay(profileID):
            try store.recordCodexRelayActivation(profileID: profileID, at: date)
        case .unknown:
            try store.recordUnknownCodexRoute(at: date)
        }
    }

    private static func rollbackFailed(_ error: any Error) -> Bool {
        guard let relayError = error as? RelayConfigurationError else { return false }
        if case .rollbackFailed = relayError { return true }
        return false
    }
}

@MainActor
final class UserDefaultsCodexUnifiedHistoryStore {
    nonisolated static let enabledKey = "relay.codexUnifiedHistoryEnabled"
    nonisolated static let optInKey = "relay.codexUnifiedHistoryOptIn"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = CodexBarPreferences.processDefaults) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        get { self.defaults.bool(forKey: Self.enabledKey) }
        set { self.defaults.set(newValue, forKey: Self.enabledKey) }
    }

    var optIn: Bool {
        get { self.defaults.bool(forKey: Self.optInKey) }
        set { self.defaults.set(newValue, forKey: Self.optInKey) }
    }
}

struct RelayActivationState: Equatable {
    let activeProfileIDsByTarget: [RelayTargetApp: UUID]
    let baselineBackupDirectory: URL
}

@MainActor
final class UserDefaultsRelayActivationStateStore {
    static let legacyActiveProfileIDKey = "relay.activeProfileID"
    static let activeProfileIDsByTargetKey = "relay.activeProfileIDsByTarget"
    static let baselineBackupPathKey = "relay.baselineBackupPath"

    private let userDefaults: UserDefaults
    private let localMeterStateFile: LocalMeterActivationStateFileStore?

    init(
        userDefaults: UserDefaults = CodexBarPreferences.processDefaults,
        localMeterStateFileURL: URL? = nil)
    {
        self.userDefaults = userDefaults
        if let localMeterStateFileURL {
            self.localMeterStateFile = LocalMeterActivationStateFileStore(fileURL: localMeterStateFileURL)
        } else if !SettingsStore.isRunningTests, userDefaults === CodexBarPreferences.processDefaults {
            let paths = RelayConfigurationPaths.standard(
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
            self.localMeterStateFile = LocalMeterActivationStateFileStore(paths: paths)
        } else {
            self.localMeterStateFile = nil
        }
    }

    func load() -> RelayActivationState? {
        if let path = self.userDefaults.string(forKey: Self.baselineBackupPathKey), !path.isEmpty {
            var activeProfiles: [RelayTargetApp: UUID] = [:]
            if let values = self.userDefaults
                .dictionary(forKey: Self.activeProfileIDsByTargetKey) as? [String: String]
            {
                for (rawTarget, rawID) in values {
                    guard let target = RelayTargetApp(rawValue: rawTarget), let id = UUID(uuidString: rawID) else {
                        continue
                    }
                    activeProfiles[target] = id
                }
            } else if let rawID = self.userDefaults.string(forKey: Self.legacyActiveProfileIDKey),
                      let id = UUID(uuidString: rawID)
            {
                for target in RelayTargetApp.allCases where target != .claudeDesktop {
                    activeProfiles[target] = id
                }
            }
            return RelayActivationState(
                activeProfileIDsByTarget: activeProfiles,
                baselineBackupDirectory: URL(fileURLWithPath: path, isDirectory: true))
        }

        guard let state = self.localMeterStateFile?.load() else { return nil }
        return RelayActivationState(
            activeProfileIDsByTarget: state.activeProfileIDsByTarget,
            baselineBackupDirectory: state.baselineBackupDirectory)
    }

    func store(_ state: RelayActivationState) {
        let values = Dictionary(uniqueKeysWithValues: state.activeProfileIDsByTarget.map {
            ($0.key.rawValue, $0.value.uuidString)
        })
        self.userDefaults.set(values, forKey: Self.activeProfileIDsByTargetKey)
        self.userDefaults.removeObject(forKey: Self.legacyActiveProfileIDKey)
        self.userDefaults.set(
            state.baselineBackupDirectory.standardizedFileURL.path,
            forKey: Self.baselineBackupPathKey)
        if let localMeterStateFile = self.localMeterStateFile {
            do {
                try localMeterStateFile.save(LocalMeterActivationState(
                    activeProfileIDsByTarget: state.activeProfileIDsByTarget,
                    baselineBackupDirectory: state.baselineBackupDirectory))
            } catch {
                CodexBarLog.logger(LogCategories.settings).warning(
                    "Could not mirror relay activation state to the recovery file",
                    metadata: ["error": String(describing: error)])
            }
        }
    }

    func clear() {
        self.userDefaults.removeObject(forKey: Self.legacyActiveProfileIDKey)
        self.userDefaults.removeObject(forKey: Self.activeProfileIDsByTargetKey)
        self.userDefaults.removeObject(forKey: Self.baselineBackupPathKey)
        if let localMeterStateFile = self.localMeterStateFile {
            do {
                try localMeterStateFile.clear()
            } catch {
                CodexBarLog.logger(LogCategories.settings).warning(
                    "Could not clear the relay activation recovery file",
                    metadata: ["error": String(describing: error)])
            }
        }
    }
}

enum RelaySettingsStatus: Equatable {
    case idle
    case saved(String)
    case importedExternal(String)
    case importedAllExternal(Int)
    case applied(name: String, clientCount: Int)
    case restoredPreviousConfiguration
    case restoredWithWarning(String)
    case unifiedHistoryEnabled(jsonlFiles: Int, stateRows: Int)
    case deletedProfile(String)
    case failed(String)

    var message: String? {
        switch self {
        case .idle:
            nil
        case let .saved(name):
            L("relay_settings_saved_message", name)
        case let .importedExternal(name):
            L("relay_external_imported_message", name)
        case let .importedAllExternal(count):
            L("relay_external_imported_all_message", count)
        case let .applied(name, clientCount):
            L("relay_settings_applied_message", name, clientCount)
        case .restoredPreviousConfiguration:
            L("relay_ui_status_restored")
        case let .restoredWithWarning(warning):
            L("relay_ui_status_restored_warning", warning)
        case let .unifiedHistoryEnabled(jsonlFiles, stateRows):
            L("relay_ui_status_unified_history_enabled", jsonlFiles, stateRows)
        case let .deletedProfile(name):
            L("relay_ui_status_deleted", name)
        case let .failed(message):
            message
        }
    }

    var isError: Bool {
        if case .failed = self { return true }
        return false
    }

    var isWarning: Bool {
        switch self {
        case .restoredWithWarning: true
        default: false
        }
    }
}

@MainActor
@Observable
final class RelaySettingsModel {
    let actions: RelaySettingsActions
    let routesDomain: any RoutesDomain
    var loadedProfileIDs = Set<UUID>()
    private(set) var isLoaded = false
    private(set) var activationState: RelayActivationState?
    private(set) var unifiedHistoryEnabled = false
    var externalConfigurationReport: RelayExternalConfigurationReport?

    var profiles: [RelayProfile] = []
    var selectedProfileID: UUID?
    var profileID = UUID()
    var name = ""
    var baseURLText = ""
    var apiFormat: RelayAPIFormat = .openAIResponses
    var usageQueryMode: RelayUsageQueryMode = .sub2API
    var customBalance = RelayCustomBalanceConfiguration(endpointPath: "/user/balance")
    var modelID = ""
    /// Per-client model values. `modelID` is only a default entered explicitly in the current edit;
    /// opening a profile never infers it from one client's model.
    var modelIDsByTarget: [RelayTargetApp: String] = [:]
    var enabledTargets: Set<RelayTargetApp> = [.codex]
    /// Presentation-only filter for the client rows shown in the editor.
    var visibleTargets: Set<RelayTargetApp> = Set(RelayTargetApp.allCases)
    var apiKeyInput = ""
    /// Explicit opt-in for the first Codex migration. A previously migrated installation is
    /// intentionally sticky: there is no reverse migration switch.
    var unifiedHistoryOptIn = false
    var credentialConfigured = false
    var usageSummary: RelayUsageSummary?
    var localCodexUsage: CodexRelayLocalUsagePresentation?
    var usageError: String?
    var isRefreshingUsage = false
    var isRefreshingLocalCodexUsage = false
    private var localCodexUsageGeneration: UInt64 = 0
    var status: RelaySettingsStatus = .idle

    init(actions: RelaySettingsActions = .live(), routesDomain: (any RoutesDomain)? = nil) {
        self.actions = actions
        self.routesDomain = routesDomain ?? LiveRoutesDomain(actions: actions)
    }

    var canSave: Bool {
        self.saveBlocker == nil
    }

    var saveBlocker: String? {
        if self.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L("relay_ui_blocker_name")
        }
        if Self.validatedBaseURL(self.baseURLText) == nil {
            return L("relay_ui_blocker_base_url")
        }
        return nil
    }

    var switchBlockers: [String] {
        var blockers: [String] = []
        if let saveBlocker { blockers.append(saveBlocker) }
        if self.enabledTargets.isEmpty {
            blockers.append(L("relay_ui_blocker_no_client"))
        }
        if !self.credentialConfigured,
           self.apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            blockers.append(L("relay_ui_blocker_api_key"))
        }
        for target in RelayTargetApp.allCases where self.enabledTargets.contains(target) {
            guard target != .claudeDesktop else { continue }
            if let reason = Self.incompatibilityReason(target: target, format: self.apiFormat) {
                blockers.append(reason)
            }
            if self.modelID(for: target).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blockers.append(L("relay_ui_blocker_model_id", Self.displayName(for: target)))
            }
        }
        return blockers
    }

    var canSwitch: Bool {
        self.switchBlockers.isEmpty
    }

    var canRestorePreviousConfiguration: Bool {
        self.activationState != nil
    }

    var activeApplicationCount: Int {
        self.effectiveActiveProfileIDsByTarget.count
    }

    static let visibleActiveMatrixTargets: [RelayTargetApp] = [
        .codex,
        .claudeCode,
        .grokBuild,
        .openCode,
        .piAgent,
    ]

    func activeTargets(for profileID: UUID? = nil) -> [RelayTargetApp] {
        let active = self.effectiveActiveProfileIDsByTarget
        return Self.visibleActiveMatrixTargets.filter { target in
            guard let activeID = active[target] else { return false }
            return profileID == nil || activeID == profileID
        }
    }

    func activeProfileName(for target: RelayTargetApp) -> String? {
        guard let profileID = self.effectiveActiveProfileIDsByTarget[target] else { return nil }
        return self.profiles.first(where: { $0.id == profileID })?.name
    }

    func isActiveProfile(_ profileID: UUID?, for target: RelayTargetApp) -> Bool {
        guard let profileID else { return false }
        return self.effectiveActiveProfileIDsByTarget[target] == profileID
    }

    func activeTargetCount(for profileID: UUID) -> Int {
        self.effectiveActiveProfileIDsByTarget.values.count(where: { $0 == profileID })
    }

    var isExistingProfile: Bool {
        self.loadedProfileIDs.contains(self.profileID)
    }

    func loadIfNeeded() {
        guard !self.isLoaded else { return }
        self.isLoaded = true
        do {
            self.profiles = try self.routesDomain.profiles()
            self.loadedProfileIDs = Set(self.profiles.map(\.id))
            self.activationState = self.actions.loadActivationState()
            self.unifiedHistoryEnabled = self.actions.loadUnifiedHistoryEnabled()
            self.unifiedHistoryOptIn = self.unifiedHistoryEnabled || self.actions.loadUnifiedHistoryOptIn()
            self.externalConfigurationReport = self.actions.inspectExternalConfiguration(self.profiles)
            if let first = self.profiles.first {
                self.selectProfile(first.id)
            } else {
                self.startNewProfile()
            }
        } catch {
            self.status = .failed(Self.safeErrorMessage(error))
            self.startNewProfile(preservingStatus: true)
        }
    }

    func startNewProfile(preservingStatus: Bool = false) {
        try? self.routesDomain.selectProfile(id: nil)
        self.selectedProfileID = nil
        self.profileID = UUID()
        self.name = ""
        self.baseURLText = ""
        self.apiFormat = .openAIResponses
        self.usageQueryMode = .sub2API
        self.customBalance = RelayCustomBalanceConfiguration(endpointPath: "/user/balance")
        self.modelID = ""
        self.modelIDsByTarget = [:]
        self.enabledTargets = [.codex]
        self.visibleTargets = Set(RelayTargetApp.allCases)
        self.apiKeyInput = ""
        self.unifiedHistoryOptIn = true
        self.credentialConfigured = false
        self.usageSummary = nil
        self.localCodexUsageGeneration &+= 1
        self.localCodexUsage = nil
        self.isRefreshingLocalCodexUsage = false
        self.usageError = nil
        self.isRefreshingUsage = false
        if !preservingStatus {
            self.status = .idle
        }
    }

    func selectProfile(_ id: UUID) {
        guard let profile = self.profiles.first(where: { $0.id == id }) else { return }
        try? self.routesDomain.selectProfile(id: id)
        self.selectedProfileID = id
        self.profileID = profile.id
        self.name = profile.name
        self.baseURLText = profile.baseURL.absoluteString
        self.apiFormat = profile.apiFormat
        self.usageQueryMode = profile.usageQueryMode
        self.customBalance = profile.customBalance ?? RelayCustomBalanceConfiguration(endpointPath: "/user/balance")
        self.modelIDsByTarget = Dictionary(uniqueKeysWithValues: profile.targets.map { ($0.app, $0.model ?? "") })
        self.modelID = profile.defaultModel ?? ""
        self.enabledTargets = Set(profile.targets.filter(\.isEnabled).map(\.app))
        self.visibleTargets = profile.visibleTargets
        // Unified history predates per-profile relay settings and remains a global preference.
        // Selecting an existing profile must therefore restore the persisted choice instead of
        // inheriting the default-on state of a newly created draft.
        self.unifiedHistoryOptIn = self.unifiedHistoryEnabled || self.actions.loadUnifiedHistoryOptIn()
        self.usageSummary = self.actions.loadUsageSummary(profile.id)
        self.localCodexUsageGeneration &+= 1
        self.localCodexUsage = nil
        self.isRefreshingLocalCodexUsage = false
        self.usageError = nil
        self.isRefreshingUsage = false
        self.status = .idle
        do {
            let credential = try self.actions.loadCredential(profile.credentialReference) ?? ""
            self.apiKeyInput = credential
            self.credentialConfigured = !credential.isEmpty
        } catch {
            self.apiKeyInput = ""
            self.credentialConfigured = false
            self.status = .failed(Self.safeErrorMessage(error))
        }
    }

    /// Settings persist metadata and credentials only. Live client files are changed by the
    /// menu's target-scoped switch action, never by opening or saving this editor.
    func save() {
        do {
            let profile = try self.persistDraft()
            self.actions.storeUnifiedHistoryOptIn(self.unifiedHistoryEnabled || self.unifiedHistoryOptIn)
            self.status = .saved(profile.name)
        } catch {
            self.status = .failed(Self.safeErrorMessage(error))
        }
    }

    func applyToEnabledClients() {
        do {
            let profile = try self.persistDraft()
            self.actions.storeUnifiedHistoryOptIn(self.unifiedHistoryEnabled || self.unifiedHistoryOptIn)
            guard self.canSwitch else {
                throw RelaySettingsInputError.invalidDraft(self.switchBlockers.joined(separator: " "))
            }

            var activationState = self.activationState
            if activationState == nil {
                let baseline = try self.actions.captureBaseline()
                let initialState = RelayActivationState(
                    activeProfileIDsByTarget: [:],
                    baselineBackupDirectory: baseline)
                self.actions.storeActivationState(initialState)
                activationState = initialState
            }

            let result = try self.routesDomain.apply(profile)
            guard let currentState = activationState else {
                throw RelaySettingsInputError.invalidDraft(L("relay_ui_error_baseline_backup"))
            }
            let targets = self.enabledTargets.filter { $0 != .claudeDesktop }
            var activeProfiles = currentState.activeProfileIDsByTarget
            for target in targets {
                activeProfiles[target] = profile.id
            }
            let updatedState = RelayActivationState(
                activeProfileIDsByTarget: activeProfiles,
                baselineBackupDirectory: currentState.baselineBackupDirectory)
            self.actions.storeActivationState(updatedState)
            self.activationState = updatedState
            self.actions.invalidateKeychainReadCache()
            self.actions.notifyRouteApplicationSucceeded()
            if let backup = result.backupDirectory {
                try self.actions.discardBackup(backup)
            }
            self.externalConfigurationReport = self.actions.inspectExternalConfiguration(self.profiles)
            self.status = .applied(name: profile.name, clientCount: targets.count)
        } catch {
            self.status = .failed(Self.safeErrorMessage(error))
        }
    }

    func restorePreviousConfiguration() {
        self.restoreTargets(nil)
    }

    /// Restores either the complete baseline (dangerous settings action) or just the selected
    /// clients. A scoped restore leaves other active profiles and their mappings untouched.
    func restoreTargets(_ targets: Set<RelayTargetApp>?) {
        guard let activationState = self.activationState else {
            self.status = .failed(L("relay_ui_error_no_baseline"))
            return
        }
        do {
            let result: RelaySwitchResult = if let restoreBaselineForTargets = self.actions.restoreBaselineForTargets {
                try restoreBaselineForTargets(activationState.baselineBackupDirectory, targets)
            } else {
                try self.actions.restoreBaseline(activationState.baselineBackupDirectory)
            }

            if let targets {
                var activeProfiles = activationState.activeProfileIDsByTarget
                for target in targets {
                    activeProfiles.removeValue(forKey: target)
                }
                if activeProfiles.isEmpty {
                    self.actions.clearActivationState()
                    self.activationState = nil
                } else {
                    let updatedState = RelayActivationState(
                        activeProfileIDsByTarget: activeProfiles,
                        baselineBackupDirectory: activationState.baselineBackupDirectory)
                    self.actions.storeActivationState(updatedState)
                    self.activationState = updatedState
                }
            } else {
                self.actions.clearActivationState()
                self.activationState = nil
            }
            self.actions.invalidateKeychainReadCache()

            var cleanupWarnings: [String] = []
            if let backup = result.backupDirectory {
                do {
                    try self.actions.discardBackup(backup)
                } catch {
                    cleanupWarnings.append(Self.safeErrorMessage(error))
                }
            }
            if targets == nil || self.activationState == nil {
                do {
                    try self.actions.discardBackup(activationState.baselineBackupDirectory)
                } catch {
                    cleanupWarnings.append(Self.safeErrorMessage(error))
                }
            }
            if !cleanupWarnings.isEmpty {
                self.status = .restoredWithWarning(cleanupWarnings.joined(separator: "; "))
            } else {
                self.status = .restoredPreviousConfiguration
            }
            self.externalConfigurationReport = self.actions.inspectExternalConfiguration(self.profiles)
        } catch {
            self.status = .failed(Self.safeErrorMessage(error))
        }
    }

    @discardableResult
    func ensureUnifiedHistoryEnabled() -> Bool {
        guard !self.unifiedHistoryEnabled else { return true }
        do {
            let outcome = try self.actions.enableUnifiedHistory()
            self.unifiedHistoryEnabled = true
            self.actions.storeUnifiedHistoryOptIn(true)
            self.status = .unifiedHistoryEnabled(
                jsonlFiles: outcome.migratedJSONLFiles,
                stateRows: outcome.migratedStateRows)
            return true
        } catch {
            self.status = .failed(Self.safeErrorMessage(error))
            return false
        }
    }

    func deleteSelectedProfile() {
        guard let selectedProfileID,
              let selectedIndex = self.profiles.firstIndex(where: { $0.id == selectedProfileID })
        else {
            self.status = .failed(L("relay_ui_error_select_to_delete"))
            return
        }
        let profile = self.profiles[selectedIndex]

        let activeTargets = Set(
            self.activationState?.activeProfileIDsByTarget.compactMap { target, id in
                id == profile.id ? target : nil
            } ?? [])
        if !activeTargets.isEmpty {
            self.restoreTargets(activeTargets)
            guard !self.status.isError else { return }
        }

        let previousProfiles = self.profiles
        let updatedProfiles = previousProfiles.filter { $0.id != profile.id }
        do {
            let previousCredential = try self.actions.loadCredential(profile.credentialReference)
            try self.actions.storeProfiles(updatedProfiles)
            do {
                try self.actions.removeCredential(profile.credentialReference)
            } catch {
                try? self.actions.storeProfiles(previousProfiles)
                if let previousCredential {
                    try? self.actions.storeCredential(previousCredential, profile.credentialReference)
                }
                throw error
            }
            try? self.actions.scrubInlineCredentials([profile.providerKey])

            self.profiles = updatedProfiles
            self.loadedProfileIDs.remove(profile.id)
            self.externalConfigurationReport = self.actions.inspectExternalConfiguration(updatedProfiles)
            if updatedProfiles.isEmpty {
                self.startNewProfile(preservingStatus: true)
            } else {
                let nextIndex = min(selectedIndex, updatedProfiles.index(before: updatedProfiles.endIndex))
                self.selectProfile(updatedProfiles[nextIndex].id)
            }
            self.status = .deletedProfile(profile.name)
        } catch {
            self.status = .failed(Self.safeErrorMessage(error))
        }
    }

    func refreshUsage(force: Bool = true) async {
        guard !self.isRefreshingUsage else { return }
        guard self.usageQueryMode != .disabled else {
            self.usageError = L("relay_ui_usage_error_no_mode")
            return
        }
        guard let profile = self.makeProfile() else {
            self.usageError = self.saveBlocker ?? L("relay_ui_usage_error_invalid")
            return
        }
        if !force, let cached = self.actions.loadFreshUsageSummary(profile.id, Date()) {
            self.usageSummary = cached
            self.usageError = nil
            return
        }
        let credential = self.apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credential.isEmpty else {
            self.usageError = L("relay_ui_usage_error_no_key")
            return
        }

        self.isRefreshingUsage = true
        self.usageError = nil
        defer { self.isRefreshingUsage = false }
        do {
            let summary = try await self.actions.fetchUsageSummary(profile, credential)
            try self.actions.storeUsageSummary(summary, profile.id)
            self.usageSummary = summary
        } catch {
            self.actions.recordUsageFailure(profile.id, Self.safeErrorMessage(error), Date())
            self.usageError = Self.safeErrorMessage(error)
        }
    }

    func refreshLocalCodexUsage(costUsageEnabled: Bool) async {
        self.localCodexUsageGeneration &+= 1
        let generation = self.localCodexUsageGeneration
        self.localCodexUsage = nil
        guard costUsageEnabled,
              let profileID = self.selectedProfileID,
              self.enabledTargets.contains(.codex)
        else {
            self.isRefreshingLocalCodexUsage = false
            return
        }

        self.isRefreshingLocalCodexUsage = true
        defer {
            if generation == self.localCodexUsageGeneration {
                self.isRefreshingLocalCodexUsage = false
            }
        }
        let presentation = await self.actions.loadLocalCodexUsage(profileID)
        guard !Task.isCancelled,
              generation == self.localCodexUsageGeneration,
              self.selectedProfileID == profileID
        else { return }
        self.localCodexUsage = presentation
    }

    func isTargetEnabled(_ target: RelayTargetApp) -> Bool {
        self.enabledTargets.contains(target)
    }

    func modelID(for target: RelayTargetApp) -> String {
        let explicit = self.modelIDsByTarget[target]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return explicit?.isEmpty == false ? explicit! : self.modelID
    }

    func setModelID(_ model: String, for target: RelayTargetApp) {
        self.modelIDsByTarget[target] = model
    }

    func fillCurrentModelIDIntoEnabledClients() {
        let value = self.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        for target in self.enabledTargets where target != .claudeDesktop {
            self.modelIDsByTarget[target] = value
        }
        self.status = .idle
    }

    func setTarget(_ target: RelayTargetApp, enabled: Bool) {
        if enabled {
            self.enabledTargets.insert(target)
        } else {
            self.enabledTargets.remove(target)
        }
        self.status = .idle
    }

    func isTargetVisible(_ target: RelayTargetApp) -> Bool {
        self.visibleTargets.contains(target)
    }

    func setTargetVisible(_ target: RelayTargetApp, visible: Bool) {
        if visible {
            self.visibleTargets.insert(target)
        } else {
            self.visibleTargets.remove(target)
        }
        self.status = .idle
    }

    static func displayName(for target: RelayTargetApp) -> String {
        switch target {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        case .claudeDesktop: "Claude Desktop"
        case .grokBuild: "Grok Build"
        case .openCode: "OpenCode"
        case .piAgent: "Pi Agent"
        }
    }

    static func incompatibilityReason(target: RelayTargetApp, format: RelayAPIFormat) -> String? {
        switch target {
        case .codex where format != .openAIResponses:
            L("relay_ui_incompatible_codex")
        case .claudeCode where format != .anthropicMessages:
            L("relay_ui_incompatible_claude_code")
        case .claudeDesktop:
            nil
        case .grokBuild where format != .openAIResponses:
            L("relay_ui_incompatible_grok")
        case .openCode, .codex, .claudeCode, .grokBuild, .piAgent:
            nil
        }
    }

    private func persistDraft() throws -> RelayProfile {
        guard let profile = self.makeProfile() else {
            throw RelaySettingsInputError.invalidDraft(self.saveBlocker ?? L("relay_ui_error_invalid_draft"))
        }
        let credential = self.apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousCredential: String? = if credential.isEmpty {
            nil
        } else {
            try self.actions.loadCredential(profile.credentialReference)
        }
        if !credential.isEmpty {
            try self.actions.storeCredential(credential, profile.credentialReference)
        }

        var updated = self.profiles.filter { $0.id != profile.id }
        updated.append(profile)
        updated.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        do {
            try self.actions.storeProfiles(updated)
        } catch {
            if !credential.isEmpty {
                if let previousCredential {
                    try? self.actions.storeCredential(previousCredential, profile.credentialReference)
                } else {
                    try? self.actions.removeCredential(profile.credentialReference)
                }
            }
            throw error
        }

        self.profiles = updated
        self.loadedProfileIDs.insert(profile.id)
        self.credentialConfigured = profile.credentialConfigured
        self.externalConfigurationReport = self.actions.inspectExternalConfiguration(updated)
        try self.routesDomain.selectProfile(id: profile.id)
        self.selectedProfileID = profile.id
        return profile
    }

    private func makeProfile() -> RelayProfile? {
        guard let baseURL = Self.validatedBaseURL(self.baseURLText) else { return nil }
        let defaultModel = self.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let targets = RelayTargetApp.allCases.map { app in
            let targetModel = (self.modelIDsByTarget[app] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return RelayTargetConfiguration(
                app: app,
                model: targetModel.isEmpty ? nil : targetModel,
                isEnabled: app == .claudeDesktop ? false : self.enabledTargets.contains(app))
        }
        let trimmedName = self.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingProviderKey = self.profiles.first(where: { $0.id == self.profileID })?.providerKey
        let resolvedProviderKey = existingProviderKey
            ?? RelayExternalConfigurationInspector.nonConflictingProviderKey(
                preferredName: trimmedName,
                baseURL: baseURL,
                profileID: self.profileID,
                existingProfiles: self.profiles,
                externalProviderBaseURLsByKey: self.externalConfigurationReport?.externalProviderBaseURLsByKey ?? [:])
        return RelayProfile(
            id: self.profileID,
            name: trimmedName,
            baseURL: baseURL,
            apiFormat: self.apiFormat,
            defaultModel: defaultModel.isEmpty ? nil : defaultModel,
            credentialReference: RelayCredentialReference.make(for: self.profileID),
            credentialConfigured: self.credentialConfigured
                || !self.apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            usageQueryMode: self.usageQueryMode,
            customBalance: self.usageQueryMode == .customBalance ? self.customBalance : nil,
            targets: targets,
            visibleTargets: self.visibleTargets,
            providerKey: resolvedProviderKey)
    }

    private static func validatedBaseURL(_ rawValue: String) -> URL? {
        RelayEndpointValidator.validatedURL(rawValue)
    }

    private static func safeErrorMessage(_ error: any Error) -> String {
        if let inputError = error as? RelaySettingsInputError {
            return inputError.errorDescription ?? L("relay_ui_error_invalid_draft")
        }
        if let localized = error as? any LocalizedError, let description = localized.errorDescription {
            return description
        }
        return L("relay_ui_error_operation_failed", String(describing: type(of: error)))
    }
}

private enum RelaySettingsInputError: LocalizedError {
    case invalidDraft(String)

    var errorDescription: String? {
        switch self {
        case let .invalidDraft(message): message
        }
    }
}

enum RelayUsageSummaryCardStatus: Equatable {
    case active
    case saved
    case notReady

    static func resolve(isActive: Bool, isReady: Bool) -> Self {
        if isActive { return .active }
        return isReady ? .saved : .notReady
    }
}

@MainActor
struct RelaySettingsPane: View {
    @Bindable var settings: SettingsStore
    @State private var model: RelaySettingsModel

    init(settings: SettingsStore, actions: RelaySettingsActions = .live()) {
        self.settings = settings
        self._model = State(initialValue: RelaySettingsModel(actions: actions))
    }

    var body: some View {
        VStack(spacing: 0) {
            if self.settings.localMeterEnabled {
                HStack(spacing: 10) {
                    Toggle(L("local_meter_title"), isOn: self.$settings.localMeterEnabled)
                        .toggleStyle(.switch)
                    Text(self.localMeterStatusText)
                        .font(.caption)
                        .foregroundStyle(ConsoleDesign.secondaryText)
                    Spacer(minLength: 8)
                    if self.model.profiles.isEmpty {
                        Text(L("local_meter_no_profiles"))
                            .font(.caption)
                            .foregroundStyle(ConsoleDesign.tertiaryText)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider()
            }

            HSplitView {
                RelayProfileList(model: self.model)
                    .frame(
                        minWidth: SettingsWindowLayout.relayListWidthRange.lowerBound,
                        idealWidth: self.settings.relayListWidth,
                        maxWidth: SettingsWindowLayout.relayListWidthRange.upperBound)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: RelayListWidthPreferenceKey.self,
                                value: proxy.size.width)
                        }
                    }

                RelayProfileEditor(
                    model: self.model,
                    costUsageEnabled: self.settings.costUsageEnabled)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .persistingSettledWidth(RelayListWidthPreferenceKey.self, current: self.settings.relayListWidth) { width in
            self.settings.relayListWidth = width
        }
        .onAppear { self.model.loadIfNeeded() }
    }

    private var localMeterStatusText: String {
        LocalMeterStatusPresentation.text(
            runtimeStatus: self.settings.localMeterRuntimeStatus,
            startupNotice: self.settings.localMeterStartupNotice)
    }
}

enum LocalMeterStatusPresentation {
    static func text(
        runtimeStatus: LocalMeterRuntimeStatus,
        startupNotice: LocalMeterStartupNotice?) -> String
    {
        if let startupNotice {
            return switch startupNotice {
            case .restoredOfficial:
                L("local_meter_status_restored_official")
            case .restoreFailed:
                L("local_meter_status_restore_failed")
            }
        }
        return switch runtimeStatus {
        case .disabled:
            L("local_meter_status_off")
        case .starting:
            L("local_meter_status_starting")
        case let .healthy(port):
            L("local_meter_status_listening", Int(port))
        case .unavailable:
            L("local_meter_status_unavailable")
        }
    }
}

private struct RelayListWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 {
            value = next
        }
    }
}

@MainActor
private struct RelayProfileList: View {
    @Bindable var model: RelaySettingsModel
    @State private var confirmsDeletion = false

    var body: some View {
        VStack(spacing: 0) {
            List(selection: self.selection) {
                ForEach(self.model.profiles) { profile in
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(profile.name)
                                .lineLimit(1)
                            Text(L("relay_ui_list_app_count", profile.targets.count(where: \.isEnabled)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 2)
                        let activeTargetCount = self.model.activeTargetCount(for: profile.id)
                        if activeTargetCount > 0 {
                            Label("\(activeTargetCount)", systemImage: "checkmark.circle.fill")
                                .labelStyle(.titleAndIcon)
                                .font(.caption)
                                .foregroundStyle(ConsoleDesign.accentForeground)
                                .accessibilityLabel(L("relay_ui_list_active_accessibility", activeTargetCount))
                        }
                    }
                    .tag(profile.id)
                }
            }
            .overlay {
                if self.model.profiles.isEmpty {
                    ContentUnavailableView(
                        L("relay_ui_list_empty_title"),
                        systemImage: "arrow.triangle.branch",
                        description: Text(L("relay_ui_list_empty_description")))
                }
            }

            if !self.model.discoveredExternalRelays.isEmpty {
                Divider()
                RelayExternalDiscoverySidebarSection(model: self.model)
            }

            Divider()

            HStack {
                Button {
                    self.model.startNewProfile()
                } label: {
                    Label(L("relay_ui_list_new"), systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Button {
                    self.model.refreshExternalConfiguration()
                } label: {
                    Label(L("relay_external_rescan_action"), systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help(L("relay_external_rescan_help"))
                Spacer()
                Button(role: .destructive) {
                    self.confirmsDeletion = true
                } label: {
                    Label(L("relay_ui_list_delete"), systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .disabled(!self.model.isExistingProfile)
                .help(L("relay_ui_list_delete_help"))
            }
            .padding(10)
        }
        .confirmationDialog(
            L("relay_ui_delete_title", self.model.name),
            isPresented: self.$confirmsDeletion,
            titleVisibility: .visible)
        {
            Button(L("relay_ui_delete_confirm"), role: .destructive) {
                self.model.deleteSelectedProfile()
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            let targets = self.model.activeTargets(for: self.model.profileID)
            if !targets.isEmpty {
                Text(L(
                    "relay_ui_delete_message_active",
                    targets.map(Self.targetLabel).joined(separator: L("relay_ui_list_separator"))))
            } else {
                Text(L("relay_ui_delete_message"))
            }
        }
    }

    private static func targetLabel(_ target: RelayTargetApp) -> String {
        RelaySettingsModel.displayName(for: target)
    }

    private var selection: Binding<UUID?> {
        Binding(
            get: { self.model.selectedProfileID },
            set: { id in
                if let id {
                    self.model.selectProfile(id)
                }
            })
    }
}

@MainActor
private struct RelayProfileEditor: View {
    private enum FocusedControl: Hashable {
        case usageQueryMode
    }

    private static let usageQueryPickerID = "relay-usage-query-picker"

    @Bindable var model: RelaySettingsModel
    let costUsageEnabled: Bool
    @State private var revealsAPIKey = false
    @State private var confirmsFullRestore = false
    @State private var isCodexHistoryExpanded = false
    @FocusState private var focusedControl: FocusedControl?

    var body: some View {
        VStack(spacing: 0) {
            RelayIdentityBanner(activeApplicationCount: self.model.activeApplicationCount)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

            Divider()

            ScrollViewReader { proxy in
                Form {
                    // The usage card scrolls with the form. Pinned above it, every height change
                    // (not queried, refreshing, summary, local usage) pushed the fields below it.
                    Section {
                        RelayUsageSummaryCard(model: self.model) {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                proxy.scrollTo(Self.usageQueryPickerID, anchor: .center)
                            }
                            self.focusedControl = .usageQueryMode
                        }
                    }

                    Section {
                        TextField(
                            L("relay_ui_field_name"),
                            text: self.$model.name,
                            prompt: Text(L("relay_ui_field_name_prompt")))
                        TextField(
                            "Base URL",
                            text: self.$model.baseURLText,
                            prompt: Text("https://relay.example/v1"))
                        Picker(L("relay_ui_field_protocol"), selection: self.$model.apiFormat) {
                            ForEach(RelayAPIFormat.allCases, id: \.self) { format in
                                Text(Self.formatLabel(format)).tag(format)
                            }
                        }
                        HStack(spacing: 8) {
                            TextField(
                                L("relay_ui_field_default_model"),
                                text: self.$model.modelID,
                                prompt: Text(L("relay_ui_field_default_model_prompt")))
                            Button {
                                self.model.fillCurrentModelIDIntoEnabledClients()
                            } label: {
                                Label(L("relay_fill_models_action"), systemImage: "rectangle.3.group.fill")
                            }
                            .disabled(self.model.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .help(L("relay_fill_models_help"))
                        }
                        HStack(spacing: 6) {
                            Group {
                                if self.revealsAPIKey {
                                    TextField("API Key", text: self.$model.apiKeyInput)
                                } else {
                                    SecureField("API Key", text: self.$model.apiKeyInput)
                                }
                            }
                            .fontDesign(.monospaced)
                            Button {
                                self.revealsAPIKey.toggle()
                            } label: {
                                Image(systemName: self.revealsAPIKey ? "eye.slash" : "eye")
                                    .frame(width: 22, height: 22)
                            }
                            .buttonStyle(.borderless)
                            .help(self.revealsAPIKey ? L("relay_ui_api_key_hide") : L("relay_ui_api_key_show"))
                            .accessibilityLabel(
                                self.revealsAPIKey ? L("relay_ui_api_key_hide") : L("relay_ui_api_key_show"))
                        }
                    } header: {
                        Text(L("relay_ui_section_configuration"))
                    } footer: {
                        SettingsSectionFooter(L("relay_ui_section_configuration_footer"))
                    }

                    Section {
                        Picker(L("relay_ui_field_usage_endpoint"), selection: self.$model.usageQueryMode) {
                            ForEach(RelayUsageQueryMode.allCases, id: \.self) { mode in
                                Text(Self.usageQueryLabel(mode)).tag(mode)
                            }
                        }
                        .id(Self.usageQueryPickerID)
                        .focused(self.$focusedControl, equals: .usageQueryMode)
                        if self.model.usageQueryMode == .customBalance {
                            TextField(
                                L("relay_custom_balance_endpoint"),
                                text: self.$model.customBalance.endpointPath)
                                .fontDesign(.monospaced)
                            Picker(
                                L("relay_custom_balance_authentication"),
                                selection: self.$model.customBalance.authentication)
                            {
                                Text(L("relay_custom_balance_bearer"))
                                    .tag(RelayCustomBalanceConfiguration.Authentication.bearer)
                                Text(L("relay_custom_balance_x_api_key"))
                                    .tag(RelayCustomBalanceConfiguration.Authentication.xAPIKey)
                            }
                            TextField(
                                L("relay_custom_balance_remaining_path"),
                                text: self.$model.customBalance.remainingJSONPath)
                                .fontDesign(.monospaced)
                            TextField(
                                L("relay_custom_balance_used_path"),
                                text: self.$model.customBalance.usedJSONPath)
                                .fontDesign(.monospaced)
                            TextField(
                                L("relay_custom_balance_total_path"),
                                text: self.$model.customBalance.totalJSONPath)
                                .fontDesign(.monospaced)
                            HStack {
                                TextField(
                                    L("relay_custom_balance_currency"),
                                    text: self.$model.customBalance.currencyCode)
                                TextField(
                                    L("relay_custom_balance_divisor"),
                                    value: self.$model.customBalance.divisor,
                                    format: .number)
                            }
                            Text(L("relay_custom_balance_disclaimer"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text(L("relay_ui_section_usage"))
                    } footer: {
                        SettingsSectionFooter(L("relay_custom_balance_footer"))
                    }

                    Section {
                        DisclosureGroup {
                            ForEach(RelayTargetApp.allCases, id: \.self) { target in
                                Toggle(isOn: self.visibleTargetBinding(target)) {
                                    Label(
                                        Self.targetLabel(target),
                                        systemImage: Self.targetSymbol(target))
                                }
                            }
                        } label: {
                            Label(L("relay_visible_targets_toggle"), systemImage: "eye")
                        }
                        if self.model.visibleTargets.isEmpty {
                            Text(L("relay_visible_targets_empty"))
                                .font(.caption)
                                .foregroundStyle(ConsoleDesign.secondaryText)
                        }
                        ForEach(
                            RelayTargetApp.allCases.filter { self.model.isTargetVisible($0) },
                            id: \.self)
                        { target in
                            self.targetRow(target)
                        }
                    } header: {
                        Text(L("relay_ui_section_targets"))
                    } footer: {
                        SettingsSectionFooter(L("relay_visible_targets_footer"))
                    }

                    Section {
                        DisclosureGroup(isExpanded: self.$isCodexHistoryExpanded) {
                            Toggle(isOn: self.$model.unifiedHistoryOptIn) {
                                Text(L("relay_ui_unified_history_toggle"))
                            }
                            .disabled(self.model.unifiedHistoryEnabled)
                            Text(L("relay_unified_history_disabled_warning"))
                                .font(.caption)
                                .foregroundStyle(ConsoleDesign.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 8) {
                                Image(systemName: self.model
                                    .unifiedHistoryEnabled ? "checkmark.circle.fill" : "info.circle")
                                Text(
                                    self.model.unifiedHistoryEnabled
                                        ? L("relay_ui_unified_history_done")
                                        : L("relay_ui_unified_history_pending"))
                            }
                            .font(.caption)
                            .foregroundStyle(ConsoleDesign.secondaryText)
                        } label: {
                            Label(
                                L("relay_ui_unified_history_title"),
                                systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                        }
                    } header: {
                        Text(L("relay_ui_section_codex_history"))
                    } footer: {
                        SettingsSectionFooter(L("relay_ui_section_codex_history_footer"))
                    }

                    if self.model.enabledTargets.contains(.grokBuild)
                        || self.model.enabledTargets.contains(.openCode)
                    {
                        Section {
                            Label(
                                L("relay_ui_key_copy_note"),
                                systemImage: "key.horizontal.fill")
                                .foregroundStyle(ConsoleDesign.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        } header: {
                            Text(L("relay_ui_section_key_copy"))
                        }
                    }
                }
                .formStyle(.grouped)
                .toggleStyle(.switch)
                .scrollContentBackground(.hidden)
            }

            RelaySettingsValidationStrip(model: self.model)
                .frame(height: 52)
                .padding(.horizontal, 12)

            Divider()

            HStack {
                Button(L("relay_ui_restore_all"), role: .destructive) { self.confirmsFullRestore = true }
                    .disabled(!self.model.canRestorePreviousConfiguration)
                    .help(L("relay_ui_restore_all_help"))
                Spacer()
                Button(L("relay_settings_save_action")) { self.model.save() }
                    .disabled(!self.model.canSave)
                Button(L("relay_settings_apply_action")) { self.model.applyToEnabledClients() }
                    .disabled(!self.model.canSwitch)
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .task(
            id: "\(self.model.selectedProfileID?.uuidString ?? "draft"):"
                + "\(self.costUsageEnabled):\(self.model.enabledTargets.contains(.codex))")
        {
            await self.model.refreshLocalCodexUsage(costUsageEnabled: self.costUsageEnabled)
        }
        .confirmationDialog(
                L("relay_ui_restore_all_title"),
                isPresented: self.$confirmsFullRestore,
                titleVisibility: .visible)
        {
            Button(L("relay_ui_restore_all_confirm"), role: .destructive) {
                self.model.restorePreviousConfiguration()
            }
            Button(L("Cancel"), role: .cancel) {}
            } message: {
                let targets = self.model.activeTargets()
                Text(
                    targets.isEmpty
                        ? L("relay_ui_restore_all_none")
                        : L(
                            "relay_ui_restore_all_message",
                            targets.map(Self.targetLabel).joined(separator: L("relay_ui_list_separator"))))
            }
    }

    private struct RelaySettingsValidationStrip: View {
        @Bindable var model: RelaySettingsModel

        var body: some View {
            HStack(alignment: .center, spacing: 8) {
                let icon = self.model.status.isError ? "xmark.circle.fill" : self.model.status
                    .isWarning ? "exclamationmark.triangle.fill" : "info.circle"
                Image(systemName: icon)
                    .foregroundStyle(
                        self.model.status.isError ? ConsoleDesign.criticalForeground : ConsoleDesign.secondaryText)
                VStack(alignment: .leading, spacing: 2) {
                    if let message = self.model.status.message {
                        Text(message).lineLimit(1)
                    } else if let blocker = self.model.saveBlocker {
                        Text(blocker).lineLimit(1)
                    } else {
                        Text(L("relay_ui_validation_idle"))
                            .foregroundStyle(ConsoleDesign.secondaryText)
                    }
                    if !self.model.switchBlockers.isEmpty {
                        Text(L("relay_ui_validation_requirements", self.model.switchBlockers.joined(separator: " · ")))
                            .font(.caption2)
                            .foregroundStyle(ConsoleDesign.secondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ConsoleDesign.surface)
            .clipShape(RoundedRectangle(cornerRadius: ConsoleDesign.radiusControl, style: .continuous))
        }
    }

    private func targetBinding(_ target: RelayTargetApp) -> Binding<Bool> {
        Binding(
            get: { self.model.isTargetEnabled(target) },
            set: { self.model.setTarget(target, enabled: $0) })
    }

    private func visibleTargetBinding(_ target: RelayTargetApp) -> Binding<Bool> {
        Binding(
            get: { self.model.isTargetVisible(target) },
            set: { self.model.setTargetVisible(target, visible: $0) })
    }

    private func targetRow(_ target: RelayTargetApp) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if target == .claudeDesktop {
                HStack(spacing: 8) {
                    Label(Self.targetLabel(target), systemImage: Self.targetSymbol(target))
                    Spacer()
                    Text(L("relay_ui_target_manual"))
                        .font(.caption)
                        .foregroundStyle(ConsoleDesign.secondaryText)
                    Button(L("relay_ui_copy_base_url")) { self.copyToPasteboard(self.model.baseURLText) }
                        .buttonStyle(.borderless)
                    Button(L("relay_ui_copy_api_key")) { self.copyToPasteboard(self.model.apiKeyInput) }
                        .buttonStyle(.borderless)
                }
            } else {
                HStack(spacing: 8) {
                    Toggle(isOn: self.targetBinding(target)) {
                        Label(Self.targetLabel(target), systemImage: Self.targetSymbol(target))
                    }
                    Spacer(minLength: 8)
                    self.targetActivationStatus(target)
                }
                TextField(
                    L("relay_ui_target_model_field", Self.targetLabel(target)),
                    text: Binding(
                        get: { self.model.modelID(for: target) },
                        set: { self.model.setModelID($0, for: target) }),
                    prompt: Text(L("relay_target_model_required_prompt")))
                    .fontDesign(.monospaced)
                    .padding(.leading, 27)
            }
            if let note = Self.targetNote(target, format: self.model.apiFormat) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(
                        RelaySettingsModel.incompatibilityReason(
                            target: target,
                            format: self.model.apiFormat) == nil
                            ? ConsoleDesign.secondaryText
                            : ConsoleDesign.criticalForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func targetActivationStatus(_ target: RelayTargetApp) -> some View {
        if self.model.isActiveProfile(self.model.selectedProfileID, for: target) {
            HStack(spacing: 5) {
                Circle()
                    .fill(ConsoleDesign.accent)
                    .frame(width: 6, height: 6)
                Text(L("relay_target_active_status"))
                    .foregroundStyle(ConsoleDesign.primaryText)
            }
            .font(.caption)
            .accessibilityElement(children: .combine)
        } else if let profileName = self.model.activeProfileName(for: target) {
            Text(profileName)
                .font(.caption)
                .foregroundStyle(ConsoleDesign.secondaryText)
                .lineLimit(1)
        } else if let externalName = self.model.externalActiveName(for: target) {
            Text(L("relay_target_external_status", externalName))
                .font(.caption)
                .foregroundStyle(ConsoleDesign.accentForeground)
                .lineLimit(1)
        }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private static func formatLabel(_ format: RelayAPIFormat) -> String {
        switch format {
        case .openAIResponses: "OpenAI Responses"
        case .openAIChatCompletions: "OpenAI Chat Completions"
        case .anthropicMessages: "Anthropic Messages"
        }
    }

    private static func usageQueryLabel(_ mode: RelayUsageQueryMode) -> String {
        switch mode {
        case .disabled: L("relay_ui_usage_mode_off")
        case .sub2API: "Sub2API (/v1/usage)"
        case .genericBalance: L("relay_ui_usage_mode_generic")
        case .customBalance: L("relay_custom_balance_mode")
        }
    }

    private static func targetLabel(_ target: RelayTargetApp) -> String {
        RelaySettingsModel.displayName(for: target)
    }

    private static func targetSymbol(_ target: RelayTargetApp) -> String {
        switch target {
        case .codex: "terminal.fill"
        case .claudeCode: "chevron.left.forwardslash.chevron.right"
        case .claudeDesktop: "macwindow"
        case .grokBuild: "hammer.fill"
        case .openCode: "curlybraces.square.fill"
        case .piAgent: "sparkles"
        }
    }

    private static func targetNote(_ target: RelayTargetApp, format: RelayAPIFormat) -> String? {
        if let incompatibility = RelaySettingsModel.incompatibilityReason(target: target, format: format) {
            return incompatibility
        }
        return switch target {
        case .codex: L("relay_ui_note_codex")
        case .claudeCode: L("relay_ui_note_claude_code")
        case .claudeDesktop: L("relay_ui_note_claude_desktop")
        case .grokBuild: L("relay_ui_note_grok")
        case .openCode: L("relay_ui_note_opencode")
        case .piAgent: L("relay_target_pi_note")
        }
    }
}

@MainActor
private struct RelayUsageSummaryCard: View {
    @Bindable var model: RelaySettingsModel
    let onConfigureUsageQuery: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "chart.bar.xaxis")
                    .foregroundStyle(ConsoleDesign.accentForeground)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(self.profileName)
                            .font(.headline)
                            .lineLimit(1)
                        Text(self.statusLabel)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(self.statusColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .overlay {
                                RoundedRectangle(cornerRadius: ConsoleDesign.radiusChip)
                                    .stroke(self.statusColor, lineWidth: 1)
                            }
                    }
                    Text(L("relay_usage_card_title"))
                        .font(.caption)
                        .foregroundStyle(ConsoleDesign.secondaryText)
                }
                Spacer(minLength: 8)
                Button {
                    Task { await self.model.refreshUsage() }
                } label: {
                    Label(L("relay_usage_card_query"), systemImage: "arrow.clockwise")
                }
                .disabled(self.model.usageQueryMode == .disabled || self.model.isRefreshingUsage)
                .help(L("relay_usage_card_query_help"))
            }

            if self.model.usageQueryMode == .disabled {
                HStack(spacing: 8) {
                    Text(L("relay_usage_card_disabled"))
                        .foregroundStyle(ConsoleDesign.secondaryText)
                    Spacer(minLength: 8)
                    Button(L("relay_usage_card_configure"), action: self.onConfigureUsageQuery)
                        .buttonStyle(.borderless)
                }
            } else if self.model.isRefreshingUsage {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L("relay_usage_card_refreshing"))
                        .foregroundStyle(ConsoleDesign.secondaryText)
                }
            } else if let summary = self.model.usageSummary {
                let summaryLine = RelayUsagePresentation.summaryLine(summary)
                let remainingLine = RelayUsagePresentation.remainingLine(summary)
                let detailLine = RelayUsagePresentation.detailLine(summary)
                if let remainingPercent = CodexRelaySummaryCardModel.remainingPercent(for: summary) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(L("relay_usage_card_remaining"))
                            .foregroundStyle(ConsoleDesign.secondaryText)
                        Text("\(Int(remainingPercent.rounded()))%")
                            .font(ConsoleDesign.mono(16, weight: .semibold))
                            .monospacedDigit()
                        Spacer(minLength: 8)
                        if let remainingLine {
                            Text(remainingLine)
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(ConsoleDesign.secondaryText)
                        }
                    }
                    ConsoleSegmentedMeter(percent: remainingPercent)
                    if let detailLine {
                        Text(detailLine)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(ConsoleDesign.secondaryText)
                    }
                } else if !summaryLine.isEmpty {
                    Text(summaryLine)
                        .font(.callout.monospacedDigit())
                } else {
                    Text(L("relay_usage_card_no_values"))
                        .foregroundStyle(ConsoleDesign.secondaryText)
                }

                if let recent = RelayUsagePresentation.recentUsageLine(summary) {
                    Text(recent)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(ConsoleDesign.secondaryText)
                }
                Text(L(
                    "relay_usage_card_updated_at",
                    summary.updatedAt.formatted(date: .omitted, time: .shortened)))
                    .font(.caption2)
                    .foregroundStyle(ConsoleDesign.secondaryText)
            } else {
                Text(L("relay_usage_card_not_queried"))
                    .foregroundStyle(ConsoleDesign.secondaryText)
            }

            if self.model.localCodexUsage != nil || self.model.isRefreshingLocalCodexUsage {
                ConsoleDivider()
                VStack(alignment: .leading, spacing: 7) {
                    Text(L("relay_local_usage_title"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ConsoleDesign.secondaryText)
                    if self.model.isRefreshingLocalCodexUsage, self.model.localCodexUsage == nil {
                        ProgressView()
                            .controlSize(.small)
                    } else if let localUsage = self.model.localCodexUsage {
                        if let rolling = localUsage.rolling24Hours {
                            RelayLocalUsageMeterRow(label: L("relay_local_usage_24h"), window: rolling)
                        }
                        if let sevenDays = localUsage.last7Days {
                            RelayLocalUsageMeterRow(label: L("relay_local_usage_7d"), window: sevenDays)
                        }
                    }
                }
            }

            if let usageError = self.model.usageError {
                Label(usageError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(ConsoleDesign.criticalForeground)
            }
        }
        // Rendered as the first grouped-form section, which already draws the container; a
        // second card border inside it would nest two frames.
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var profileName: String {
        let name = self.model.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? L("relay_usage_card_untitled") : name
    }

    private var status: RelayUsageSummaryCardStatus {
        .resolve(
            isActive: !self.model.activeTargets(for: self.model.profileID).isEmpty,
            isReady: self.model.isExistingProfile && self.model.canSwitch)
    }

    private var statusColor: Color {
        switch self.status {
        case .active: ConsoleDesign.accentForeground
        case .saved: ConsoleDesign.secondaryText
        case .notReady: ConsoleDesign.criticalForeground
        }
    }

    private var statusLabel: String {
        switch self.status {
        case .active: L("relay_usage_card_status_active")
        case .saved: L("relay_usage_card_status_saved")
        case .notReady: L("relay_usage_card_status_not_ready")
        }
    }
}
