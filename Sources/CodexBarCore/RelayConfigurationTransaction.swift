import Foundation

public protocol RelayConfigurationFileSystem: Sendable {
    func fileExists(at url: URL) -> Bool
    func readData(at url: URL) throws -> Data
    func createSecureDirectory(at url: URL) throws
    func writeAtomically(_ data: Data, to url: URL) throws
    func removeItem(at url: URL) throws
}

public struct LocalRelayConfigurationFileSystem: RelayConfigurationFileSystem {
    public init() {}

    public func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func readData(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    public func createSecureDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    public func writeAtomically(_ data: Data, to url: URL) throws {
        let targetURL = Self.resolvingExistingSymlinkTarget(for: url)
        try self.createSecureDirectory(at: targetURL.deletingLastPathComponent())
        try data.write(to: targetURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetURL.path)
    }

    private static func resolvingExistingSymlinkTarget(for url: URL) -> URL {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil else {
            return url
        }
        let resolved = url.resolvingSymlinksInPath()
        return resolved.path.isEmpty ? url : resolved
    }

    public func removeItem(at url: URL) throws {
        guard self.fileExists(at: url) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

public struct RelaySwitchPreview: Equatable, Sendable {
    public let changedTargets: [RelayTargetApp]
    public let unchangedTargets: [RelayTargetApp]
    public let changedFileCount: Int
    public let changedFileURLs: [URL]

    public init(
        changedTargets: [RelayTargetApp],
        unchangedTargets: [RelayTargetApp],
        changedFileCount: Int,
        changedFileURLs: [URL] = [])
    {
        self.changedTargets = changedTargets
        self.unchangedTargets = unchangedTargets
        self.changedFileCount = changedFileCount
        self.changedFileURLs = changedFileURLs.map(\.standardizedFileURL)
    }
}

public struct RelaySwitchResult: Equatable, Sendable {
    public let preview: RelaySwitchPreview
    public let wasDryRun: Bool
    public let backupDirectory: URL?

    public init(preview: RelaySwitchPreview, wasDryRun: Bool, backupDirectory: URL?) {
        self.preview = preview
        self.wasDryRun = wasDryRun
        self.backupDirectory = backupDirectory
    }
}

public enum RelayConfigurationError: LocalizedError, Equatable, Sendable {
    case invalidBaseURL
    case missingCredentialReference
    case emptyCredential
    case missingModel(RelayTargetApp)
    case invalidProfile(String)
    case incompatibleAPIFormat(app: RelayTargetApp, actual: RelayAPIFormat, supported: [RelayAPIFormat])
    case unsupportedConfiguration(app: RelayTargetApp, reason: String)
    case schemaVersionRequired(RelayTargetApp)
    case invalidExistingConfiguration(app: RelayTargetApp, reason: String)
    case concurrentModification(URL)
    case fileOperationFailed(String)
    case rollbackFailed(original: String, rollback: String)

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            "Relay URL must use HTTPS; HTTP is allowed only for localhost, 127.0.0.1, or ::1."
        case .missingCredentialReference:
            "Relay profile is missing its credential reference."
        case .emptyCredential:
            "The referenced relay credential is empty."
        case let .missingModel(app):
            "A model is required for \(app.rawValue)."
        case let .invalidProfile(reason):
            "Relay profile is invalid: \(reason)"
        case let .incompatibleAPIFormat(app, actual, supported):
            "\(app.rawValue) cannot use \(actual.rawValue) directly; supported formats: "
                + supported.map(\.rawValue).joined(separator: ", ")
                + ". No protocol-conversion proxy is available."
        case let .unsupportedConfiguration(app, reason):
            "Direct configuration for \(app.rawValue) is not supported: \(reason)"
        case let .schemaVersionRequired(app):
            "\(app.rawValue) configuration schema cannot be determined safely. Select a schema version first."
        case let .invalidExistingConfiguration(app, reason):
            "Cannot safely update \(app.rawValue) configuration: \(reason)"
        case let .concurrentModification(url):
            "Configuration changed while preparing the switch: \(url.path)"
        case let .fileOperationFailed(message):
            "Relay configuration file operation failed: \(message)"
        case let .rollbackFailed(original, rollback):
            "Relay switch failed (\(original)); rollback also failed (\(rollback))."
        }
    }
}

public struct RelayConfigurationTransaction: Sendable {
    private let fileSystem: any RelayConfigurationFileSystem
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID

    public init(fileSystem: any RelayConfigurationFileSystem = LocalRelayConfigurationFileSystem()) {
        self.fileSystem = fileSystem
        self.now = { Date() }
        self.makeID = { UUID() }
    }

    public init(
        fileSystem: any RelayConfigurationFileSystem,
        now: @escaping @Sendable () -> Date,
        makeID: @escaping @Sendable () -> UUID)
    {
        self.fileSystem = fileSystem
        self.now = now
        self.makeID = makeID
    }

    /// Captures every automatically writable client before the first relay activation.
    /// Keep the returned directory as the activation baseline; per-switch backups only cover
    /// targets touched by that individual switch.
    public func captureBaseline(paths: RelayConfigurationPaths) throws -> URL {
        let mutations = try paths.automaticallyManagedFiles.map { target, url in
            let current = try self.readOptional(url)
            return RelayPreparedMutation(
                target: target,
                url: url,
                originalData: current,
                replacementData: current)
        }
        return try self.persistBackup(of: mutations, root: paths.backupRootURL)
    }

    public func apply(
        profile: RelayProfile,
        paths: RelayConfigurationPaths,
        credentialStore: any RelayCredentialStoring & RelayCredentialLocating,
        codexProviderMode: RelayCodexProviderMode = .isolated,
        codexServiceTier: CodexServiceTier? = nil,
        retiredProviderKeys: Set<String> = [],
        dryRun: Bool = false) throws -> RelaySwitchResult
    {
        let credential = try self.resolveCredential(
            profile: profile,
            store: credentialStore,
            dryRun: dryRun)
        let mutations = try RelayConfigurationRenderer(
            fileSystem: self.fileSystem,
            paths: paths)
            .render(
                profile: profile,
                credential: credential,
                codexProviderMode: codexProviderMode,
                codexServiceTier: codexServiceTier,
                retiredProviderKeys: retiredProviderKeys.subtracting([profile.providerKey]))
        let changed = mutations.filter { $0.originalData != $0.replacementData }
        let preview = Self.makePreview(all: mutations, changed: changed)

        guard !dryRun, !changed.isEmpty else {
            return RelaySwitchResult(preview: preview, wasDryRun: dryRun, backupDirectory: nil)
        }

        let backupDirectory = try self.persistBackup(of: changed, root: paths.backupRootURL)
        do {
            try self.verifyUnchanged(changed)
            try self.applyWithRollback(changed)
        } catch {
            if !Self.requiresRecoveryBackup(error) {
                try? self.fileSystem.removeItem(at: backupDirectory)
            }
            throw error
        }
        return RelaySwitchResult(preview: preview, wasDryRun: false, backupDirectory: backupDirectory)
    }

    /// Routes the official OpenAI configuration through the shared session-history bucket while
    /// continuing to use Codex's normal `auth.json` OAuth credentials.
    public func configureOfficialCodexUnified(
        paths: RelayConfigurationPaths,
        codexServiceTier: CodexServiceTier? = nil,
        dryRun: Bool = false) throws -> RelaySwitchResult
    {
        var mutation = try RelayConfigurationRenderer(fileSystem: self.fileSystem, paths: paths)
            .unifiedOfficialCodexMutation()
        mutation = try self.applyingCodexServiceTier(codexServiceTier, to: mutation, paths: paths)
        let changed = mutation.originalData == mutation.replacementData ? [] : [mutation]
        let preview = Self.makePreview(all: [mutation], changed: changed)
        guard !dryRun, !changed.isEmpty else {
            return RelaySwitchResult(preview: preview, wasDryRun: dryRun, backupDirectory: nil)
        }
        let backupDirectory = try self.persistBackup(of: changed, root: paths.backupRootURL)
        do {
            try self.verifyUnchanged(changed)
            try self.applyWithRollback(changed)
        } catch {
            if !Self.requiresRecoveryBackup(error) { try? self.fileSystem.removeItem(at: backupDirectory) }
            throw error
        }
        return RelaySwitchResult(preview: preview, wasDryRun: false, backupDirectory: backupDirectory)
    }

    /// Restores a previous switch backup. The backup is constrained to this path set, and the
    /// current state is backed up before restoration so the operation is itself reversible.
    public func restore( // swiftlint:disable:this cyclomatic_complexity
        backupDirectory: URL,
        paths: RelayConfigurationPaths,
        codexProviderMode: RelayCodexProviderMode = .isolated,
        targets: Set<RelayTargetApp>? = nil,
        codexServiceTier: CodexServiceTier? = nil,
        dryRun: Bool = false) throws -> RelaySwitchResult
    {
        var mutations = try self.restoreMutations(backupDirectory: backupDirectory, paths: paths)
        if let targets {
            mutations = mutations.filter { targets.contains($0.target) }
        }
        // Pre-Pi baselines lack manifest entries for ~/.pi/agent/settings.json. Synthesize a
        // field-level defaultProvider/defaultModel reset when Pi is explicitly or globally restored.
        let shouldSynthesizePrePiReset = targets?.contains(.piAgent) == true
            || (targets == nil && mutations.contains(where: { $0.target != .codex }))
        if shouldSynthesizePrePiReset,
           !mutations.contains(where: { $0.url.standardizedFileURL == paths.piAgentSettingsURL.standardizedFileURL }),
           let currentPiSettings = try self.readOptional(paths.piAgentSettingsURL)
        {
            mutations.append(RelayPreparedMutation(
                target: .piAgent,
                url: paths.piAgentSettingsURL,
                originalData: currentPiSettings,
                replacementData: nil))
        }
        // Preserve post-baseline external provider sections, MCP servers, permissions, hooks, and
        // catalog edits across all managed clients instead of clobbering files wholesale.
        mutations = try mutations.map { mutation in
            switch mutation.target {
            case .codex where mutation.url.standardizedFileURL == paths.codexConfigURL.standardizedFileURL:
                let restored = try RelayConfigurationRenderer.surgicallyRestoredCodexData(
                    current: mutation.originalData,
                    baseline: mutation.replacementData)
                return RelayPreparedMutation(
                    target: mutation.target,
                    url: mutation.url,
                    originalData: mutation.originalData,
                    replacementData: restored)
            case .claudeCode where mutation.url.standardizedFileURL == paths.claudeCodeSettingsURL.standardizedFileURL:
                let restored = try RelayConfigurationRenderer.surgicallyRestoredClaudeCodeData(
                    current: mutation.originalData,
                    baseline: mutation.replacementData)
                return RelayPreparedMutation(
                    target: mutation.target,
                    url: mutation.url,
                    originalData: mutation.originalData,
                    replacementData: restored)
            case .grokBuild where mutation.url.standardizedFileURL == paths.grokBuildConfigURL.standardizedFileURL:
                let restored = try RelayConfigurationRenderer.surgicallyRestoredGrokData(
                    current: mutation.originalData,
                    baseline: mutation.replacementData)
                return RelayPreparedMutation(
                    target: mutation.target,
                    url: mutation.url,
                    originalData: mutation.originalData,
                    replacementData: restored)
            case .openCode where mutation.url.standardizedFileURL == paths.openCodeConfigURL.standardizedFileURL:
                let restored = try RelayConfigurationRenderer.surgicallyRestoredOpenCodeData(
                    current: mutation.originalData,
                    baseline: mutation.replacementData)
                return RelayPreparedMutation(
                    target: mutation.target,
                    url: mutation.url,
                    originalData: mutation.originalData,
                    replacementData: restored)
            case .piAgent:
                if mutation.url.standardizedFileURL == paths.piAgentModelsURL.standardizedFileURL {
                    return RelayPreparedMutation(
                        target: mutation.target,
                        url: mutation.url,
                        originalData: mutation.originalData,
                        replacementData: mutation.originalData)
                }
                guard let current = mutation.originalData else { return mutation }
                guard var root = try JSONSerialization.jsonObject(with: current) as? [String: Any] else {
                    throw RelayConfigurationError.invalidExistingConfiguration(
                        app: .piAgent,
                        reason: "settings must be an object")
                }
                let previous: [String: Any]
                if let baseline = mutation.replacementData {
                    guard let object = try JSONSerialization.jsonObject(with: baseline) as? [String: Any] else {
                        throw RelayConfigurationError.invalidExistingConfiguration(
                            app: .piAgent,
                            reason: "baseline settings must be an object")
                    }
                    previous = object
                } else {
                    previous = [:]
                }
                for key in ["defaultProvider", "defaultModel"] {
                    root[key] = previous[key]
                }
                let replacementData: Data?
                if mutation.replacementData == nil, root.isEmpty {
                    replacementData = nil
                } else {
                    var encoded = try JSONSerialization.data(
                        withJSONObject: root,
                        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                    encoded.append(0x0A)
                    replacementData = encoded
                }
                return RelayPreparedMutation(
                    target: mutation.target,
                    url: mutation.url,
                    originalData: current,
                    replacementData: replacementData)
            default:
                return mutation
            }
        }
        if codexProviderMode == .unified {
            mutations = try mutations.map { mutation in
                guard mutation.url.standardizedFileURL == paths.codexConfigURL.standardizedFileURL else {
                    return mutation
                }
                guard let replacementData = mutation.replacementData else {
                    // A missing baseline with no post-baseline additions preserves deletion.
                    return mutation
                }
                let baseText = try {
                    guard let text = String(data: replacementData, encoding: .utf8) else {
                        throw RelayConfigurationError.invalidExistingConfiguration(
                            app: .codex,
                            reason: "the baseline config is not UTF-8")
                    }
                    return text
                }()
                let replacement = try RelayConfigurationRenderer.unifiedOfficialCodexConfiguration(baseText)
                return RelayPreparedMutation(
                    target: mutation.target,
                    url: mutation.url,
                    originalData: mutation.originalData,
                    replacementData: Data(replacement.utf8))
            }
        }
        mutations = try mutations.map { try self.applyingCodexServiceTier(codexServiceTier, to: $0, paths: paths) }
        let changed = mutations.filter { $0.originalData != $0.replacementData }
        let preview = Self.makePreview(all: mutations, changed: changed)
        guard !dryRun, !changed.isEmpty else {
            return RelaySwitchResult(preview: preview, wasDryRun: dryRun, backupDirectory: nil)
        }
        let safetyBackup = try self.persistBackup(of: changed, root: paths.backupRootURL)
        do {
            try self.verifyUnchanged(changed)
            try self.applyWithRollback(changed)
        } catch {
            if !Self.requiresRecoveryBackup(error) {
                try? self.fileSystem.removeItem(at: safetyBackup)
            }
            throw error
        }
        return RelaySwitchResult(preview: preview, wasDryRun: false, backupDirectory: safetyBackup)
    }

    /// Resets the active relay route back to Official when an external tool (such as CC Switch or CLI)
    /// wrote the active route and Headroom has no prior activation baseline for the target. External
    /// provider definitions in the client catalog remain untouched.
    public func restoreOfficialWithoutBaseline(
        targets: Set<RelayTargetApp>,
        paths: RelayConfigurationPaths,
        codexProviderMode: RelayCodexProviderMode = .isolated,
        codexServiceTier: CodexServiceTier? = nil,
        dryRun: Bool = false) throws -> RelaySwitchResult
    {
        let renderer = RelayConfigurationRenderer(fileSystem: self.fileSystem, paths: paths)
        var mutations: [RelayPreparedMutation] = []
        if targets.contains(.codex),
           let codex = try renderer.clearExternalCodexOfficialMutation(providerMode: codexProviderMode)
        {
            try mutations.append(self.applyingCodexServiceTier(codexServiceTier, to: codex, paths: paths))
        }
        if targets.contains(.claudeCode),
           let claude = try renderer.clearExternalClaudeCodeOfficialMutation()
        {
            mutations.append(claude)
        }
        if targets.contains(.grokBuild),
           let grok = try renderer.clearExternalGrokOfficialMutation()
        {
            mutations.append(grok)
        }
        if targets.contains(.openCode),
           let openCode = try renderer.clearExternalOpenCodeOfficialMutation()
        {
            mutations.append(openCode)
        }
        if targets.contains(.piAgent),
           let pi = try renderer.clearExternalPiAgentOfficialMutation()
        {
            mutations.append(pi)
        }

        let changed = mutations.filter { $0.originalData != $0.replacementData }
        let preview = Self.makePreview(all: mutations, changed: changed)
        guard !dryRun, !changed.isEmpty else {
            return RelaySwitchResult(preview: preview, wasDryRun: dryRun, backupDirectory: nil)
        }
        let safetyBackup = try self.persistBackup(of: changed, root: paths.backupRootURL)
        do {
            try self.verifyUnchanged(changed)
            try self.applyWithRollback(changed)
        } catch {
            if !Self.requiresRecoveryBackup(error) {
                try? self.fileSystem.removeItem(at: safetyBackup)
            }
            throw error
        }
        return RelaySwitchResult(preview: preview, wasDryRun: false, backupDirectory: safetyBackup)
    }

    /// Only changes the Codex default for new chats. Already loaded threads own their tier.
    public func setCodexServiceTier(
        _ serviceTier: CodexServiceTier,
        paths: RelayConfigurationPaths,
        expectedConfiguration: Data? = nil,
        dryRun: Bool = false) throws -> RelaySwitchResult
    {
        let mutation = try RelayConfigurationRenderer(fileSystem: self.fileSystem, paths: paths)
            .codexServiceTierMutation(serviceTier)
        if let expectedConfiguration, mutation.originalData != expectedConfiguration {
            throw RelayConfigurationError.concurrentModification(paths.codexConfigURL)
        }
        let changed = mutation.originalData == mutation.replacementData ? [] : [mutation]
        let preview = Self.makePreview(all: [mutation], changed: changed)
        guard !dryRun, !changed.isEmpty else {
            return RelaySwitchResult(preview: preview, wasDryRun: dryRun, backupDirectory: nil)
        }
        let backup = try self.persistBackup(of: changed, root: paths.backupRootURL)
        do {
            try self.verifyUnchanged(changed)
            try self.applyWithRollback(changed)
        } catch {
            if !Self.requiresRecoveryBackup(error) { try? self.fileSystem.removeItem(at: backup) }
            throw error
        }
        return RelaySwitchResult(preview: preview, wasDryRun: false, backupDirectory: backup)
    }

    private func applyingCodexServiceTier(
        _ tier: CodexServiceTier?,
        to mutation: RelayPreparedMutation,
        paths: RelayConfigurationPaths) throws -> RelayPreparedMutation
    {
        guard let tier,
              mutation.url.standardizedFileURL == paths.codexConfigURL.standardizedFileURL,
              let data = mutation.replacementData,
              let source = String(data: data, encoding: .utf8)
        else { return mutation }
        return try RelayPreparedMutation(
            target: mutation.target,
            url: mutation.url,
            originalData: mutation.originalData,
            replacementData: Data(RelayConfigurationRenderer.codexConfiguration(source, serviceTier: tier).utf8))
    }

    /// Scrubs inline credentials left behind by a deleted or retired relay profile in Grok Build
    /// and OpenCode without disturbing unrelated settings or model limits.
    @discardableResult
    public func scrubInlineCredentials(
        forProviderKeys providerKeys: Set<String>,
        paths: RelayConfigurationPaths) throws -> RelaySwitchResult
    {
        guard !providerKeys.isEmpty else {
            return RelaySwitchResult(
                preview: RelaySwitchPreview(changedTargets: [], unchangedTargets: [], changedFileCount: 0),
                wasDryRun: false,
                backupDirectory: nil)
        }
        let renderer = RelayConfigurationRenderer(fileSystem: self.fileSystem, paths: paths)
        let mutations = try renderer.scrubInlineCredentialMutations(providerKeys: providerKeys)
        let changed = mutations.filter { $0.originalData != $0.replacementData }
        let preview = Self.makePreview(all: mutations, changed: changed)
        guard !changed.isEmpty else {
            return RelaySwitchResult(preview: preview, wasDryRun: false, backupDirectory: nil)
        }
        let backup = try self.persistBackup(of: changed, root: paths.backupRootURL)
        do {
            try self.verifyUnchanged(changed)
            try self.applyWithRollback(changed)
        } catch {
            if !Self.requiresRecoveryBackup(error) {
                try? self.fileSystem.removeItem(at: backup)
            }
            throw error
        }
        try? self.discardBackup(directory: backup, paths: paths)
        return RelaySwitchResult(preview: preview, wasDryRun: false, backupDirectory: nil)
    }

    /// Permanently removes a backup created by this transaction. Callers use this after a
    /// successful switch or restore so superseded copies of inline client credentials do not
    /// accumulate on disk. Only direct children of the configured backup root are accepted.
    public func discardBackup(directory: URL, paths: RelayConfigurationPaths) throws {
        try Self.validateBackupDirectory(directory, root: paths.backupRootURL)
        do {
            try self.fileSystem.removeItem(at: directory)
        } catch {
            throw RelayConfigurationError.fileOperationFailed(Self.safeMessage(error))
        }
    }

    private func resolveCredential(
        profile: RelayProfile,
        store: any RelayCredentialStoring & RelayCredentialLocating,
        dryRun: Bool) throws -> RelayRenderCredential
    {
        let reference = profile.credentialReference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty else { throw RelayConfigurationError.missingCredentialReference }
        let locator = try store.locator(for: reference)
        let needsInlineCredential = profile.targets.contains { target in
            target.isEnabled && [.grokBuild, .openCode].contains(target.app)
        }
        if dryRun {
            return RelayRenderCredential(
                locator: locator,
                inlineValue: needsInlineCredential ? "CODEXBAR_DRY_RUN_CREDENTIAL" : nil)
        }
        guard let credential = try store.loadCredential(reference: reference)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !credential.isEmpty
        else {
            throw RelayConfigurationError.emptyCredential
        }
        guard needsInlineCredential else {
            return RelayRenderCredential(locator: locator, inlineValue: nil)
        }
        return RelayRenderCredential(locator: locator, inlineValue: credential)
    }

    private static func makePreview(
        all: [RelayPreparedMutation],
        changed: [RelayPreparedMutation]) -> RelaySwitchPreview
    {
        let allTargets = Set(all.map(\.target))
        let changedTargets = Set(changed.map(\.target))
        return RelaySwitchPreview(
            changedTargets: RelayTargetApp.allCases.filter(changedTargets.contains),
            unchangedTargets: RelayTargetApp.allCases
                .filter { allTargets.contains($0) && !changedTargets.contains($0) },
            changedFileCount: changed.count,
            changedFileURLs: changed.map(\.url))
    }

    private func persistBackup(of mutations: [RelayPreparedMutation], root: URL) throws -> URL {
        let backupID = self.makeID()
        let directory = root.appendingPathComponent(backupID.uuidString.lowercased(), isDirectory: true)
        do {
            try self.fileSystem.createSecureDirectory(at: directory)
            let manifest = RelayBackupManifest(createdAt: self.now(), mutations: mutations)
            try self.writeBackupFiles(mutations, to: directory)
            let manifestData = try JSONEncoder.relayPretty.encode(manifest)
            try self.fileSystem.writeAtomically(
                manifestData,
                to: directory.appendingPathComponent("manifest.json"))
            return directory
        } catch {
            try? self.fileSystem.removeItem(at: directory)
            throw RelayConfigurationError.fileOperationFailed(Self.safeMessage(error))
        }
    }

    private func writeBackupFiles(_ mutations: [RelayPreparedMutation], to directory: URL) throws {
        for (index, mutation) in mutations.enumerated() {
            guard let originalData = mutation.originalData else { continue }
            let fileName = String(format: "%03d-%@-%@", index, mutation.target.rawValue, mutation.url.lastPathComponent)
            try self.fileSystem.writeAtomically(originalData, to: directory.appendingPathComponent(fileName))
        }
    }

    private func restoreMutations(
        backupDirectory: URL,
        paths: RelayConfigurationPaths) throws -> [RelayPreparedMutation]
    {
        try Self.validateBackupDirectory(backupDirectory, root: paths.backupRootURL)
        let manifestURL = backupDirectory.appendingPathComponent("manifest.json")
        do {
            let manifest = try JSONDecoder.relayBackup.decode(
                RelayBackupManifest.self,
                from: self.fileSystem.readData(at: manifestURL))
            let allowed = Set(paths.managedFileURLs.map(\.standardizedFileURL.path))
            return try manifest.entries.map { entry in
                try self.restoreMutation(entry: entry, directory: backupDirectory, allowedPaths: allowed)
            }
        } catch let error as RelayConfigurationError {
            throw error
        } catch {
            throw RelayConfigurationError.fileOperationFailed(Self.safeMessage(error))
        }
    }

    private func restoreMutation(
        entry: RelayBackupManifest.Entry,
        directory: URL,
        allowedPaths: Set<String>) throws -> RelayPreparedMutation
    {
        let targetURL = URL(fileURLWithPath: entry.originalPath).standardizedFileURL
        guard allowedPaths.contains(targetURL.path) else {
            throw RelayConfigurationError.fileOperationFailed("backup contains an unmanaged path")
        }
        let replacement: Data? = if entry.existed {
            try self.backupData(entry: entry, directory: directory)
        } else {
            nil
        }
        return try RelayPreparedMutation(
            target: entry.target,
            url: targetURL,
            originalData: self.readOptional(targetURL),
            replacementData: replacement)
    }

    private func backupData(entry: RelayBackupManifest.Entry, directory: URL) throws -> Data {
        guard let fileName = entry.backupFile,
              URL(fileURLWithPath: fileName).lastPathComponent == fileName
        else {
            throw RelayConfigurationError.fileOperationFailed("backup entry is missing its data file")
        }
        return try self.fileSystem.readData(at: directory.appendingPathComponent(fileName))
    }

    private func verifyUnchanged(_ mutations: [RelayPreparedMutation]) throws {
        for mutation in mutations {
            let current = try self.readOptional(mutation.url)
            guard current == mutation.originalData else {
                throw RelayConfigurationError.concurrentModification(mutation.url)
            }
        }
    }

    private func applyWithRollback(_ mutations: [RelayPreparedMutation]) throws {
        var attempted: [RelayPreparedMutation] = []
        do {
            for mutation in mutations {
                attempted.append(mutation)
                if let replacementData = mutation.replacementData {
                    try self.fileSystem.writeAtomically(replacementData, to: mutation.url)
                } else {
                    try self.fileSystem.removeItem(at: mutation.url)
                }
                guard try self.readOptional(mutation.url) == mutation.replacementData else {
                    throw RelayConfigurationError.fileOperationFailed(
                        "written configuration did not match readback for \(mutation.url.path)")
                }
            }
        } catch {
            let originalMessage = Self.safeMessage(error)
            do {
                try self.rollback(attempted.reversed())
            } catch {
                throw RelayConfigurationError.rollbackFailed(
                    original: originalMessage,
                    rollback: Self.safeMessage(error))
            }
            throw RelayConfigurationError.fileOperationFailed(originalMessage)
        }
    }

    private func rollback(_ mutations: ReversedCollection<[RelayPreparedMutation]>) throws {
        var firstError: (any Error)?
        for mutation in mutations {
            do {
                if let originalData = mutation.originalData {
                    try self.fileSystem.writeAtomically(originalData, to: mutation.url)
                } else {
                    try self.fileSystem.removeItem(at: mutation.url)
                }
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    private func readOptional(_ url: URL) throws -> Data? {
        guard self.fileSystem.fileExists(at: url) else { return nil }
        return try self.fileSystem.readData(at: url)
    }

    private static func safeMessage(_ error: any Error) -> String {
        if let relayError = error as? RelayConfigurationError {
            return relayError.localizedDescription
        }
        return String(describing: type(of: error))
    }

    private static func requiresRecoveryBackup(_ error: any Error) -> Bool {
        guard let relayError = error as? RelayConfigurationError else { return false }
        if case .rollbackFailed = relayError { return true }
        return false
    }

    private static func validateBackupDirectory(_ directory: URL, root: URL) throws {
        let parent = directory.standardizedFileURL.deletingLastPathComponent()
        guard parent == root.standardizedFileURL else {
            throw RelayConfigurationError.fileOperationFailed("backup directory is outside the configured backup root")
        }
    }
}

struct RelayPreparedMutation: Sendable {
    let target: RelayTargetApp
    let url: URL
    let originalData: Data?
    let replacementData: Data?
}

struct RelayRenderCredential: Sendable {
    let locator: RelayCredentialLocator
    let inlineValue: String?
}

private struct RelayBackupManifest: Codable {
    struct Entry: Codable {
        let target: RelayTargetApp
        let originalPath: String
        let existed: Bool
        let backupFile: String?
    }

    let createdAt: Date
    let entries: [Entry]

    init(createdAt: Date, mutations: [RelayPreparedMutation]) {
        self.createdAt = createdAt
        self.entries = mutations.enumerated().map { index, mutation in
            Entry(
                target: mutation.target,
                originalPath: mutation.url.path,
                existed: mutation.originalData != nil,
                backupFile: mutation.originalData.map { _ in
                    String(format: "%03d-%@-%@", index, mutation.target.rawValue, mutation.url.lastPathComponent)
                })
        }
    }
}

extension RelayConfigurationPaths {
    fileprivate var automaticallyManagedFiles: [(RelayTargetApp, URL)] {
        [
            (.codex, self.codexConfigURL),
            (.claudeCode, self.claudeCodeSettingsURL),
            (.grokBuild, self.grokBuildConfigURL),
            (.openCode, self.openCodeConfigURL),
            (.piAgent, self.piAgentSettingsURL),
            (.piAgent, self.piAgentModelsURL),
        ]
    }

    fileprivate var managedFileURLs: [URL] {
        self.automaticallyManagedFiles.map(\.1)
    }
}

extension JSONEncoder {
    fileprivate static var relayPretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

extension JSONDecoder {
    fileprivate static var relayBackup: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
