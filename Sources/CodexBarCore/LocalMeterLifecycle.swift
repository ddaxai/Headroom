import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The small, non-secret piece of state needed by the external Local Meter helper to recover
/// from a crash or a GUI exit.  Credentials and request contents are deliberately absent.
public struct LocalMeterActivationState: Codable, Equatable, Sendable {
    public let activeProfileIDsByTarget: [RelayTargetApp: UUID]
    public let baselineBackupDirectory: URL

    public init(
        activeProfileIDsByTarget: [RelayTargetApp: UUID],
        baselineBackupDirectory: URL)
    {
        self.activeProfileIDsByTarget = activeProfileIDsByTarget
        self.baselineBackupDirectory = baselineBackupDirectory.standardizedFileURL
    }

    public static func load(from defaults: UserDefaults) -> Self? {
        guard let path = defaults.string(forKey: baselineBackupPathKey), !path.isEmpty else {
            return nil
        }
        var activeProfiles: [RelayTargetApp: UUID] = [:]
        if let values = defaults.dictionary(forKey: Self.activeProfileIDsByTargetKey) as? [String: String] {
            for (rawTarget, rawID) in values {
                guard let target = RelayTargetApp(rawValue: rawTarget),
                      let id = UUID(uuidString: rawID)
                else { continue }
                activeProfiles[target] = id
            }
        } else if let rawID = defaults.string(forKey: Self.legacyActiveProfileIDKey),
                  let id = UUID(uuidString: rawID)
        {
            for target in RelayTargetApp.allCases where target != .claudeDesktop {
                activeProfiles[target] = id
            }
        }
        return Self(
            activeProfileIDsByTarget: activeProfiles,
            baselineBackupDirectory: URL(fileURLWithPath: path, isDirectory: true))
    }

    public static let legacyActiveProfileIDKey = "relay.activeProfileID"
    public static let activeProfileIDsByTargetKey = "relay.activeProfileIDsByTarget"
    public static let baselineBackupPathKey = "relay.baselineBackupPath"
}

public protocol LocalMeterActivationStateStore: Sendable {
    func load() -> LocalMeterActivationState?
    func save(_ state: LocalMeterActivationState) throws
    func clear() throws
}

/// A shared, permissions-restricted state file lets the standalone CLI operate after the GUI has
/// exited.  The file contains profile UUIDs and a backup directory only; it never contains keys,
/// cookies, prompts, or request bodies.
public final class LocalMeterActivationStateFileStore: LocalMeterActivationStateStore, @unchecked Sendable {
    public static let fileName = "local-meter-activation.json"

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL.standardizedFileURL
    }

    public convenience init(paths: RelayConfigurationPaths) {
        self.init(
            fileURL: paths.backupRootURL.appendingPathComponent(Self.fileName, isDirectory: false))
    }

    public func load() -> LocalMeterActivationState? {
        guard let data = try? Data(contentsOf: self.fileURL) else { return nil }
        return try? JSONDecoder().decode(LocalMeterActivationState.self, from: data)
    }

    public func save(_ state: LocalMeterActivationState) throws {
        let directory = self.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: self.fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.fileURL.path)
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: self.fileURL.path) else { return }
        try FileManager.default.removeItem(at: self.fileURL)
    }
}

/// Defaults-backed compatibility store for installations that activated a relay before the
/// standalone state file was introduced.  The GUI mirrors future writes to the file store, while
/// the CLI can still recover an older activation without inspecting credentials.
public final class LocalMeterActivationStateDefaultsStore: LocalMeterActivationStateStore, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(userDefaults: UserDefaults = CodexBarPreferences.processDefaults) {
        self.defaults = userDefaults
    }

    public func load() -> LocalMeterActivationState? {
        LocalMeterActivationState.load(from: self.defaults)
    }

    public func save(_ state: LocalMeterActivationState) throws {
        let values = Dictionary(uniqueKeysWithValues: state.activeProfileIDsByTarget.map {
            ($0.key.rawValue, $0.value.uuidString)
        })
        self.defaults.set(values, forKey: LocalMeterActivationState.activeProfileIDsByTargetKey)
        self.defaults.removeObject(forKey: LocalMeterActivationState.legacyActiveProfileIDKey)
        self.defaults.set(
            state.baselineBackupDirectory.standardizedFileURL.path,
            forKey: LocalMeterActivationState.baselineBackupPathKey)
    }

    public func clear() throws {
        self.defaults.removeObject(forKey: LocalMeterActivationState.legacyActiveProfileIDKey)
        self.defaults.removeObject(forKey: LocalMeterActivationState.activeProfileIDsByTargetKey)
        self.defaults.removeObject(forKey: LocalMeterActivationState.baselineBackupPathKey)
    }
}

/// Reads the shared file first and falls back to the legacy defaults representation.  Writes and
/// clears are mirrored to both stores so upgrading does not strand an existing activation.
public final class LocalMeterActivationStateStoreChain: LocalMeterActivationStateStore, @unchecked Sendable {
    private let primary: any LocalMeterActivationStateStore
    private let fallback: any LocalMeterActivationStateStore

    public init(
        primary: any LocalMeterActivationStateStore,
        fallback: any LocalMeterActivationStateStore)
    {
        self.primary = primary
        self.fallback = fallback
    }

    public func load() -> LocalMeterActivationState? {
        self.primary.load() ?? self.fallback.load()
    }

    public func save(_ state: LocalMeterActivationState) throws {
        try self.primary.save(state)
        try self.fallback.save(state)
    }

    public func clear() throws {
        try self.primary.clear()
        try self.fallback.clear()
    }
}

public enum LocalMeterRestoreResult: Equatable, Sendable {
    case noActivation
    case alreadyOfficial
    case restored(changedFileCount: Int)
}

public struct LocalMeterRestoreReport: Equatable, Sendable {
    public let result: LocalMeterRestoreResult
    public let changedConfigurationURLs: [URL]
    public let baselineBackupDirectory: URL?
    public let recoveryBackupDirectory: URL?

    public init(
        result: LocalMeterRestoreResult,
        changedConfigurationURLs: [URL] = [],
        baselineBackupDirectory: URL? = nil,
        recoveryBackupDirectory: URL? = nil)
    {
        self.result = result
        self.changedConfigurationURLs = changedConfigurationURLs.map(\.standardizedFileURL)
        self.baselineBackupDirectory = baselineBackupDirectory?.standardizedFileURL
        self.recoveryBackupDirectory = recoveryBackupDirectory?.standardizedFileURL
    }
}

/// Restores the baseline captured before relay activation.  The transaction itself validates that
/// every manifest entry remains inside the configured managed-path set.
public struct LocalMeterRestoreService: Sendable {
    private let paths: RelayConfigurationPaths
    private let stateStore: any LocalMeterActivationStateStore
    private let transaction: RelayConfigurationTransaction
    private let codexProviderMode: RelayCodexProviderMode
    private let codexServiceTier: CodexServiceTier?
    private let ownershipStore: FileCodexSessionOwnershipTimelineStore?

    public init(
        paths: RelayConfigurationPaths,
        stateStore: any LocalMeterActivationStateStore,
        transaction: RelayConfigurationTransaction = RelayConfigurationTransaction(),
        codexProviderMode: RelayCodexProviderMode = .isolated,
        codexServiceTier: CodexServiceTier? = nil,
        ownershipStore: FileCodexSessionOwnershipTimelineStore? = nil)
    {
        self.paths = paths
        self.stateStore = stateStore
        self.transaction = transaction
        self.codexProviderMode = codexProviderMode
        self.codexServiceTier = codexServiceTier
        self.ownershipStore = ownershipStore
    }

    public var hasActivation: Bool {
        self.stateStore.load() != nil
    }

    public var configurationPointsToLoopback: Bool {
        let markers = [
            "127.0.0.1",
            "localhost",
            "[::1]",
            "http://::1",
            "http://127.0.0.1",
            "http://localhost",
        ]
        for url in self.paths.managedConfigurationURLs {
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8)
            else { continue }
            if markers.contains(where: { text.localizedCaseInsensitiveContains($0) }) {
                return true
            }
        }
        return false
    }

    @discardableResult
    public func restoreOfficial(dryRun: Bool = false) throws -> LocalMeterRestoreResult {
        try self.restoreOfficialReport(dryRun: dryRun).result
    }

    public func restoreOfficialReport(dryRun: Bool = false) throws -> LocalMeterRestoreReport {
        guard let state = self.stateStore.load() else {
            return LocalMeterRestoreReport(result: .noActivation)
        }
        let switchResult = try self.transaction.restore(
            backupDirectory: state.baselineBackupDirectory,
            paths: self.paths,
            codexProviderMode: self.codexProviderMode,
            codexServiceTier: self.codexServiceTier,
            dryRun: dryRun)
        let result: LocalMeterRestoreResult = switchResult.preview.changedFileCount == 0
            ? .alreadyOfficial
            : .restored(changedFileCount: switchResult.preview.changedFileCount)
        if !dryRun {
            try self.stateStore.clear()
            try? self.transaction.discardBackup(
                directory: state.baselineBackupDirectory,
                paths: self.paths)
            _ = try? self.ownershipStore?.recordOfficialCodexRoute(at: Date())
        }
        return LocalMeterRestoreReport(
            result: result,
            changedConfigurationURLs: switchResult.preview.changedFileURLs,
            baselineBackupDirectory: state.baselineBackupDirectory,
            recoveryBackupDirectory: switchResult.backupDirectory)
    }
}

public enum LocalMeterStartupResult: Equatable, Sendable {
    case notConfigured
    case healthy
    case restored(changedFileCount: Int)
    case failed
}

public struct LocalMeterStartupRetryPolicy: Equatable, Sendable {
    public static let singleAttempt = Self(maximumAttempts: 1, delay: .zero)
    public static let launchdStartup = Self(maximumAttempts: 25, delay: .milliseconds(500))

    public let maximumAttempts: Int
    public let delay: Duration

    public init(maximumAttempts: Int, delay: Duration) {
        self.maximumAttempts = max(1, maximumAttempts)
        self.delay = delay
    }
}

/// Startup guard for the GUI.  It intentionally checks activation state before probing the
/// helper, so an ordinary installation never causes a network request or a configuration write.
public struct LocalMeterStartupGuard: Sendable {
    private let restoreService: LocalMeterRestoreService
    private let healthCheck: @Sendable () async -> Bool
    private let retryPolicy: LocalMeterStartupRetryPolicy
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(
        restoreService: LocalMeterRestoreService,
        healthCheck: @escaping @Sendable () async -> Bool,
        retryPolicy: LocalMeterStartupRetryPolicy = .singleAttempt,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        })
    {
        self.restoreService = restoreService
        self.healthCheck = healthCheck
        self.retryPolicy = retryPolicy
        self.sleep = sleep
    }

    public func run() async -> LocalMeterStartupResult {
        guard self.restoreService.hasActivation,
              self.restoreService.configurationPointsToLoopback
        else { return .notConfigured }
        for attempt in 0..<self.retryPolicy.maximumAttempts {
            guard !Task.isCancelled else { return .failed }
            if await self.healthCheck() { return .healthy }
            if attempt < self.retryPolicy.maximumAttempts - 1 {
                do {
                    try await self.sleep(self.retryPolicy.delay)
                } catch {
                    return .failed
                }
            }
        }
        guard !Task.isCancelled else { return .failed }
        do {
            switch try self.restoreService.restoreOfficial() {
            case .noActivation:
                return .notConfigured
            case .alreadyOfficial:
                return .restored(changedFileCount: 0)
            case let .restored(changedFileCount):
                return .restored(changedFileCount: changedFileCount)
            }
        } catch {
            // Do not expose paths or any potentially sensitive configuration detail in the
            // status channel.  The caller can offer the explicit CLI recovery command.
            return .failed
        }
    }
}

/// A launchd user-agent description for the standalone helper. The controller below owns loading
/// exactly this per-user job; the plist remains a small, credential-free declaration.
public struct LocalMeterLaunchdJob: Equatable, Sendable {
    public static let label = "com.ddaxia.headroom.local-meter"
    public static let defaultPort: UInt16 = LocalMeterEndpoint.defaultPort
    public static let fileName = "com.ddaxia.headroom.local-meter.plist"

    public let helperURL: URL
    public let port: UInt16
    public let standardOutputURL: URL
    public let standardErrorURL: URL

    public init(
        helperURL: URL,
        port: UInt16 = Self.defaultPort,
        standardOutputURL: URL = URL(fileURLWithPath: "/dev/null"),
        standardErrorURL: URL = URL(fileURLWithPath: "/dev/null"))
    {
        self.helperURL = helperURL.standardizedFileURL
        self.port = port
        self.standardOutputURL = standardOutputURL.standardizedFileURL
        self.standardErrorURL = standardErrorURL.standardizedFileURL
    }

    public func propertyList() -> [String: Any] {
        [
            "Label": Self.label,
            "ProgramArguments": [self.helperURL.path, "--port", String(self.port)],
            "KeepAlive": true,
            "RunAtLoad": true,
            "ProcessType": "Background",
            "StandardOutPath": self.standardOutputURL.path,
            "StandardErrorPath": self.standardErrorURL.path,
        ]
    }

    public func plistData() throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: self.propertyList(),
            format: .xml,
            options: 0)
    }

    public static func launchAgentURL(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent(self.fileName, isDirectory: false)
    }
}

/// Owns exactly one per-user LaunchAgent. The runner is injectable so tests can assert the
/// command boundary without invoking the user's launchd. A bootout failure is intentionally
/// ignored during install/stop: stale or already-crashed jobs must not block recovery.
public struct LocalMeterLaunchdController: Sendable {
    public typealias LaunchctlRunner = @Sendable ([String]) throws -> Void

    public static var currentUserID: Int {
        Int(getuid())
    }

    public let homeDirectory: URL
    public let helperURL: URL
    public let launchctlURL: URL
    private let runLaunchctl: LaunchctlRunner

    public init(
        homeDirectory: URL,
        helperURL: URL,
        launchctlURL: URL = URL(fileURLWithPath: "/bin/launchctl"),
        runLaunchctl: LaunchctlRunner? = nil)
    {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.helperURL = helperURL.standardizedFileURL
        self.launchctlURL = launchctlURL.standardizedFileURL
        self.runLaunchctl = runLaunchctl ?? { [launchctlURL] arguments in
            try Self.runLaunchctl(at: launchctlURL, arguments: arguments)
        }
    }

    @discardableResult
    public func installAndStart() throws -> URL {
        let plistURL = LocalMeterLaunchdJob.launchAgentURL(homeDirectory: self.homeDirectory)
        let directory = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let data = try LocalMeterLaunchdJob(helperURL: self.helperURL).plistData()
        try data.write(to: plistURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plistURL.path)

        self.ignoreBootoutFailure()
        try self.runLaunchctl([
            "bootstrap",
            "gui/\(Self.currentUserID)",
            plistURL.path,
        ])
        return plistURL
    }

    public func stopAndRemove() throws {
        self.ignoreBootoutFailure()
        let plistURL = LocalMeterLaunchdJob.launchAgentURL(homeDirectory: self.homeDirectory)
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return }
        try FileManager.default.removeItem(at: plistURL)
    }

    private func ignoreBootoutFailure() {
        try? self.runLaunchctl([
            "bootout",
            "gui/\(Self.currentUserID)/\(LocalMeterLaunchdJob.label)",
        ])
    }

    private static func runLaunchctl(at launchctlURL: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = launchctlURL
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw LocalMeterLaunchdError.commandFailed(process.terminationStatus)
        }
    }
}

public enum LocalMeterLaunchdError: LocalizedError, Equatable, Sendable {
    case commandFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case let .commandFailed(status): "launchd command failed (status \(status))."
        }
    }
}
