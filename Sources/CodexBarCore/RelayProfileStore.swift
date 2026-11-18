import Foundation

public enum RelayCredentialReference {
    public static let prefix = "relay-profile."

    public static func make(for profileID: UUID) -> String {
        self.prefix + profileID.uuidString.lowercased()
    }

    public static func isValid(_ reference: String) -> Bool {
        guard reference.hasPrefix(self.prefix) else { return false }
        let rawID = String(reference.dropFirst(self.prefix.count))
        return UUID(uuidString: rawID) != nil
    }
}

public enum FileRelayProfileStoreError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case duplicateProfileID(UUID)
    case credentialReferenceMismatch(profileID: UUID)
}

public protocol RelayProfileStoring: Sendable {
    func loadProfiles() throws -> [RelayProfile]
    func storeProfiles(_ profiles: [RelayProfile]) throws
    func ensureFileExists() throws -> URL
}

public struct FileRelayProfileStore: RelayProfileStoring, @unchecked Sendable {
    public static let currentVersion = 3
    private static let usageQueryLegacyVersion = 1
    private static let defaultModelLegacyVersion = 2

    private struct Payload: Codable {
        let version: Int
        let profiles: [RelayProfile]
    }

    private let fileURL: URL
    private let fileManager: FileManager

    public init(fileURL: URL = Self.defaultURL(), fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public func loadProfiles() throws -> [RelayProfile] {
        guard self.fileManager.fileExists(atPath: self.fileURL.path) else { return [] }

        let data = try Data(contentsOf: self.fileURL)
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let profiles: [RelayProfile]
        switch payload.version {
        case Self.currentVersion:
            profiles = payload.profiles
        case Self.usageQueryLegacyVersion:
            // Version 1 was written while the UI defaulted to a disabled balance query. Migrate
            // that implicit default and the default model once. Explicit values saved by version 3
            // are never inferred again.
            profiles = payload.profiles.map { profile in
                var migrated = profile
                if migrated.usageQueryMode == .disabled {
                    migrated.usageQueryMode = .sub2API
                }
                migrated.defaultModel = Self.inferredDefaultModel(from: migrated)
                return migrated
            }
            try Self.validate(profiles)
            try self.writePayload(Payload(version: Self.currentVersion, profiles: profiles))
            return profiles
        case Self.defaultModelLegacyVersion:
            profiles = payload.profiles.map { profile in
                var migrated = profile
                migrated.defaultModel = Self.inferredDefaultModel(from: migrated)
                return migrated
            }
            try Self.validate(profiles)
            try self.writePayload(Payload(version: Self.currentVersion, profiles: profiles))
            return profiles
        default:
            throw FileRelayProfileStoreError.unsupportedVersion(payload.version)
        }
        let normalizedProfiles = profiles.map(Self.ensuringAllKnownTargets)
        try Self.validate(normalizedProfiles)
        return normalizedProfiles
    }

    public func storeProfiles(_ profiles: [RelayProfile]) throws {
        try Self.validate(profiles)

        try self.writePayload(Payload(version: Self.currentVersion, profiles: profiles))
    }

    private func writePayload(_ payload: Payload) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        let directory = self.fileURL.deletingLastPathComponent()
        if !self.fileManager.fileExists(atPath: directory.path) {
            try self.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try data.write(to: self.fileURL, options: [.atomic])
        try self.applySecurePermissionsIfNeeded()
    }

    public func ensureFileExists() throws -> URL {
        if self.fileManager.fileExists(atPath: self.fileURL.path) { return self.fileURL }
        try self.storeProfiles([])
        return self.fileURL
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("relay-profiles.json", isDirectory: false)
    }

    private static func validate(_ profiles: [RelayProfile]) throws {
        var seenIDs = Set<UUID>()
        for profile in profiles {
            guard seenIDs.insert(profile.id).inserted else {
                throw FileRelayProfileStoreError.duplicateProfileID(profile.id)
            }
            guard profile.credentialReference == RelayCredentialReference.make(for: profile.id) else {
                throw FileRelayProfileStoreError.credentialReferenceMismatch(profileID: profile.id)
            }
        }
    }

    private static func ensuringAllKnownTargets(_ profile: RelayProfile) -> RelayProfile {
        let existingApps = Set(profile.targets.map(\.app))
        let missingApps = RelayTargetApp.allCases.filter { !existingApps.contains($0) }
        guard !missingApps.isEmpty else { return profile }
        var updated = profile
        updated.targets.append(contentsOf: missingApps.map { app in
            RelayTargetConfiguration(app: app, model: nil, isEnabled: false)
        })
        return updated
    }

    private static func inferredDefaultModel(from profile: RelayProfile) -> String? {
        let models = profile.targets
            .filter { $0.isEnabled && $0.app != .claudeDesktop }
            .map { ($0.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let first = models.first,
              !first.isEmpty,
              models.allSatisfy({ $0 == first })
        else {
            return nil
        }
        return first
    }

    private func applySecurePermissionsIfNeeded() throws {
        #if os(macOS) || os(Linux)
        try self.fileManager.setAttributes([
            .posixPermissions: NSNumber(value: Int16(0o600)),
        ], ofItemAtPath: self.fileURL.path)
        #endif
    }
}
