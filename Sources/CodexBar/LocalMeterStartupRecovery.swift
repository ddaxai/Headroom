import CodexBarCore
import Foundation

/// Builds the startup recovery guard from the same configuration paths used by relay switching.
/// The guard is deliberately lazy about health probing: the Core implementation checks the
/// activation state and a loopback marker before invoking the supplied probe.
enum LocalMeterStartupRecovery {
    static func makeGuard(
        homeDirectory: URL,
        userDefaults: UserDefaults,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        retryPolicy: LocalMeterStartupRetryPolicy = .singleAttempt,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        },
        healthCheck: @escaping @Sendable () async -> Bool) -> LocalMeterStartupGuard
    {
        LocalMeterStartupGuard(
            restoreService: self.makeRestoreService(
                homeDirectory: homeDirectory,
                userDefaults: userDefaults,
                environment: environment),
            healthCheck: healthCheck,
            retryPolicy: retryPolicy,
            sleep: sleep)
    }

    /// Reuses the startup guard's credential-free activation state and loopback marker check.
    /// This is a read-only confirmation step after a relay configuration transaction commits.
    static func hasActiveLoopbackRoute(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        userDefaults: UserDefaults = CodexBarPreferences.processDefaults,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool
    {
        let service = self.makeRestoreService(
            homeDirectory: homeDirectory,
            userDefaults: userDefaults,
            environment: environment)
        return service.hasActivation && service.configurationPointsToLoopback
    }

    static func makeLiveGuard(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        userDefaults: UserDefaults = CodexBarPreferences.processDefaults,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        retryPolicy: LocalMeterStartupRetryPolicy = .launchdStartup,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        },
        healthCheck: (@Sendable () async -> Bool)? = nil) -> LocalMeterStartupGuard
    {
        let resolvedHomeDirectory = self.resolveHomeDirectory(
            default: homeDirectory,
            environment: environment)
        let resolvedUserDefaults = self.resolveUserDefaults(
            default: userDefaults,
            environment: environment)
        let probe = LocalMeterHealthProbe()
        let baseURL = LocalMeterEndpoint.baseURL()
        return self.makeGuard(
            homeDirectory: resolvedHomeDirectory,
            userDefaults: resolvedUserDefaults,
            environment: environment,
            retryPolicy: retryPolicy,
            sleep: sleep,
            healthCheck: healthCheck ?? { await probe.isHealthy(baseURL: baseURL) })
    }

    private static func resolveHomeDirectory(
        default defaultHomeDirectory: URL,
        environment: [String: String]) -> URL
    {
        let raw = environment["CODEXBAR_RESTORE_HOME"]
            ?? environment["CODEXBAR_HOME"]
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return defaultHomeDirectory
        }
        if raw == "~" { return defaultHomeDirectory }
        if raw.hasPrefix("~/") {
            return defaultHomeDirectory
                .appendingPathComponent(String(raw.dropFirst(2)), isDirectory: true)
                .standardizedFileURL
        }
        guard raw.hasPrefix("/") else { return defaultHomeDirectory }
        return URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
    }

    private static func makeRestoreService(
        homeDirectory: URL,
        userDefaults: UserDefaults,
        environment: [String: String]) -> LocalMeterRestoreService
    {
        let paths = RelayConfigurationPaths.standard(
            homeDirectory: homeDirectory,
            environment: environment)
        let fileStore = LocalMeterActivationStateFileStore(paths: paths)
        let defaultsStore = LocalMeterActivationStateDefaultsStore(userDefaults: userDefaults)
        let stateStore = LocalMeterActivationStateStoreChain(
            primary: fileStore,
            fallback: defaultsStore)
        let unifiedEnabled = userDefaults.bool(forKey: UserDefaultsCodexUnifiedHistoryStore.enabledKey)
        let officialTier = CodexSpeedPreferences(defaults: userDefaults).tier(for: .official)
        let isDefaultHome = homeDirectory.standardizedFileURL ==
            FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        return LocalMeterRestoreService(
            paths: paths,
            stateStore: stateStore,
            codexProviderMode: unifiedEnabled ? .unified : .isolated,
            codexServiceTier: officialTier,
            ownershipStore: isDefaultHome ? .default : nil)
    }

    private static func resolveUserDefaults(
        default defaultUserDefaults: UserDefaults,
        environment: [String: String]) -> UserDefaults
    {
        guard let suite = environment["CODEXBAR_RELAY_DEFAULTS_SUITE"],
              let isolated = UserDefaults(suiteName: suite)
        else {
            return defaultUserDefaults
        }
        return isolated
    }
}

enum LocalMeterStartupNotice: Equatable, Sendable {
    case restoredOfficial
    case restoreFailed
}

@MainActor
enum LocalMeterStartupPresentation {
    static func apply(_ result: LocalMeterStartupResult, to settings: SettingsStore) {
        switch result {
        case .notConfigured, .healthy:
            break
        case .restored:
            settings.localMeterRuntimeStatus = .unavailable
            settings.localMeterStartupNotice = .restoredOfficial
        case .failed:
            settings.localMeterRuntimeStatus = .unavailable
            settings.localMeterStartupNotice = .restoreFailed
        }
    }

    /// Clears a recovery fact only after the caller has independently confirmed that the helper
    /// is healthy and the managed client configuration is back on the loopback route. A server
    /// restart or a helper health transition alone must not erase the notice.
    static func revokeAfterVerifiedLoopbackActivation(on settings: SettingsStore) {
        settings.localMeterStartupNotice = nil
    }
}
