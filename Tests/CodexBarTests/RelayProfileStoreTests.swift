import Foundation
import Testing
@testable import CodexBarCore

struct RelayProfileStoreTests {
    @Test
    func `missing relay profile file loads an empty collection`() throws {
        let root = self.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = FileRelayProfileStore(fileURL: root.appendingPathComponent("profiles.json"))

        #expect(try store.loadProfiles().isEmpty)
    }

    @Test
    func `relay profiles round trip without serializing credentials`() throws {
        let root = self.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("profiles.json")
        let profile = try self.makeProfile()
        let backing = InMemoryRelayCredentialKeychainBacking()
        let credentialStore = KeychainRelayCredentialStore(service: "test.service", backing: backing)
        let profileStore = FileRelayProfileStore(fileURL: fileURL)
        let credential = "private-test-credential"

        try credentialStore.storeCredential(credential, reference: profile.credentialReference)
        try profileStore.storeProfiles([profile])

        #expect(try profileStore.loadProfiles() == [profile])
        #expect(try credentialStore.loadCredential(reference: profile.credentialReference) == credential)
        let serialized = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(serialized.contains(profile.credentialReference))
        #expect(!serialized.contains(credential))
    }

    @Test
    func `relay profile file uses owner only permissions`() throws {
        let root = self.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("profiles.json")
        let store = FileRelayProfileStore(fileURL: fileURL)

        try store.storeProfiles([])

        #if os(macOS) || os(Linux)
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o600)
        #endif
    }

    @Test
    func `unsupported relay profile version is rejected`() throws {
        let root = self.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("profiles.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try #"{"profiles":[],"version":99}"#.write(to: fileURL, atomically: true, encoding: .utf8)
        let store = FileRelayProfileStore(fileURL: fileURL)

        #expect(throws: FileRelayProfileStoreError.unsupportedVersion(99)) {
            try store.loadProfiles()
        }
    }

    @Test
    func `version one profiles enable the default usage query during migration`() throws {
        let root = self.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let profileID = UUID()
        let fileURL = root.appendingPathComponent("profiles.json")
        let profileJSON = """
        {
          "id": "\(profileID.uuidString)",
          "name": "Legacy relay",
          "baseURL": "https://relay.example/v1",
          "apiFormat": "openAIResponses",
          "credentialReference": "\(RelayCredentialReference.make(for: profileID))",
          "credentialConfigured": true,
          "usageQueryMode": "disabled",
          "targets": [{"app":"codex","isEnabled":true}]
        }
        """
        let payload = "{\"version\":1,\"profiles\":[\(profileJSON)]}"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try payload.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = FileRelayProfileStore(fileURL: fileURL)
        let profiles = try store.loadProfiles()

        #expect(profiles.first?.usageQueryMode == .sub2API)
        let migrated = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(migrated.contains("\"version\" : 3"))
    }

    @Test
    func `version two profiles infer and persist one default model`() throws {
        let root = self.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let profileID = UUID()
        let fileURL = root.appendingPathComponent("profiles.json")
        let payload = """
        {
          "version": 2,
          "profiles": [{
            "id": "\(profileID.uuidString)",
            "name": "Legacy relay",
            "baseURL": "https://relay.example/v1",
            "apiFormat": "openAIResponses",
            "credentialReference": "\(RelayCredentialReference.make(for: profileID))",
            "credentialConfigured": true,
            "usageQueryMode": "sub2api",
            "targets": [
              {"app":"codex","model":"shared-model","isEnabled":true},
              {"app":"openCode","model":"shared-model","isEnabled":true},
              {"app":"claudeCode","model":"ignored-model","isEnabled":false},
              {"app":"claudeDesktop","isEnabled":false}
            ]
          }]
        }
        """
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try payload.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = FileRelayProfileStore(fileURL: fileURL)
        let profiles = try store.loadProfiles()

        #expect(profiles.first?.defaultModel == "shared-model")
        let migrated = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(migrated.contains("\"version\" : 3"))
        #expect(migrated.contains("\"defaultModel\" : \"shared-model\""))
    }

    @Test
    func `version two migration keeps a mixed blank target default model null`() throws {
        let root = self.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let profileID = UUID()
        let fileURL = root.appendingPathComponent("profiles.json")
        let payload = """
        {
          "version": 2,
          "profiles": [{
            "id": "\(profileID.uuidString)",
            "name": "Mixed relay",
            "baseURL": "https://relay.example/v1",
            "apiFormat": "openAIResponses",
            "credentialReference": "\(RelayCredentialReference.make(for: profileID))",
            "credentialConfigured": true,
            "usageQueryMode": "sub2api",
            "targets": [
              {"app":"codex","model":"shared-model","isEnabled":true},
              {"app":"openCode","isEnabled":true}
            ]
          }]
        }
        """
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try payload.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = FileRelayProfileStore(fileURL: fileURL)
        let profiles = try store.loadProfiles()

        #expect(profiles.first?.defaultModel == nil)
        let migrated = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(migrated.contains("\"defaultModel\" : null"))
    }

    @Test
    func `version three explicit null default model is never inferred`() throws {
        let root = self.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("profiles.json")
        let profileID = UUID()
        let profile = try RelayProfile(
            id: profileID,
            name: "Explicit per-target models",
            baseURL: #require(URL(string: "https://relay.example/v1")),
            apiFormat: .openAIResponses,
            defaultModel: nil,
            credentialReference: RelayCredentialReference.make(for: profileID),
            targets: [
                .init(app: .codex, model: "shared-model", isEnabled: true),
                .init(app: .openCode, model: "shared-model", isEnabled: true),
            ])
        let store = FileRelayProfileStore(fileURL: fileURL)

        try store.storeProfiles([profile])

        let serialized = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(serialized.contains("\"defaultModel\" : null"))
        #expect(try store.loadProfiles().first?.defaultModel == nil)
    }

    @Test
    func `profile credential reference must match its profile I D`() throws {
        let root = self.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try RelayProfile(
            name: "Relay",
            baseURL: #require(URL(string: "https://relay.example/v1")),
            apiFormat: .openAIResponses,
            credentialReference: RelayCredentialReference.make(for: UUID()),
            targets: [RelayTargetConfiguration(app: .codex)])
        let store = FileRelayProfileStore(fileURL: root.appendingPathComponent("profiles.json"))

        #expect(throws: FileRelayProfileStoreError.credentialReferenceMismatch(profileID: profile.id)) {
            try store.storeProfiles([profile])
        }
    }

    @Test
    func `duplicate relay profile I Ds are rejected`() throws {
        let root = self.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try self.makeProfile()
        let store = FileRelayProfileStore(fileURL: root.appendingPathComponent("profiles.json"))

        #expect(throws: FileRelayProfileStoreError.duplicateProfileID(profile.id)) {
            try store.storeProfiles([profile, profile])
        }
    }

    private func makeProfile() throws -> RelayProfile {
        let profileID = UUID()
        return try RelayProfile(
            id: profileID,
            name: "Test Relay",
            baseURL: #require(URL(string: "https://relay.example/v1")),
            apiFormat: .openAIResponses,
            credentialReference: RelayCredentialReference.make(for: profileID),
            targets: [
                RelayTargetConfiguration(app: .codex),
                RelayTargetConfiguration(app: .openCode),
            ])
    }

    private func makeTemporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-relay-profile-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

struct RelayCredentialStoreTests {
    @Test
    func `file credential store round trips visible credentials with owner only permissions`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-relay-credential-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("relay-credentials.json")
        let store = FileRelayCredentialStore(fileURL: fileURL)
        let reference = RelayCredentialReference.make(for: UUID())

        #expect(try store.loadCredential(reference: reference) == nil)
        try store.storeCredential("  visible-test-api-key  \n", reference: reference)
        #expect(try store.loadCredential(reference: reference) == "visible-test-api-key")
        #expect(try String(contentsOf: fileURL, encoding: .utf8).contains("visible-test-api-key"))

        #if os(macOS) || os(Linux)
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o600)
        #endif

        try store.removeCredential(reference: reference)
        #expect(try store.loadCredential(reference: reference) == nil)
    }

    @Test
    func `file credential store validates references and empty values`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-relay-credential-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileRelayCredentialStore(fileURL: root.appendingPathComponent("relay-credentials.json"))
        let reference = RelayCredentialReference.make(for: UUID())

        #expect(throws: RelayCredentialStoreError.emptyCredential) {
            try store.storeCredential(" \n ", reference: reference)
        }
        #expect(throws: RelayCredentialStoreError.invalidReference) {
            try store.storeCredential("test-api-key", reference: "invalid-reference")
        }
    }

    @Test
    func `credential reference is deterministic and scoped`() {
        let profileID = UUID()
        let reference = RelayCredentialReference.make(for: profileID)

        #expect(reference == "relay-profile.\(profileID.uuidString.lowercased())")
        #expect(RelayCredentialReference.isValid(reference))
        #expect(!RelayCredentialReference.isValid(profileID.uuidString))
        #expect(!RelayCredentialReference.isValid("relay-profile.not-a-uuid"))
    }

    @Test
    func `credential locator is serializable and contains no secret`() throws {
        let store = KeychainRelayCredentialStore(service: "test.relay.service")
        let reference = RelayCredentialReference.make(for: UUID())
        let locator = try store.locator(for: reference)

        #expect(locator.service == "test.relay.service")
        #expect(locator.account == reference)
        #expect(locator.reference == reference)
        let encoded = try JSONEncoder().encode(locator)
        #expect(try JSONDecoder().decode(RelayCredentialLocator.self, from: encoded) == locator)
        let serialized = try #require(String(data: encoded, encoding: .utf8))
        #expect(!serialized.contains("credential"))
    }

    @Test
    func `keychain credential store trims stores loads and removes through injected backing`() throws {
        let backing = InMemoryRelayCredentialKeychainBacking()
        let store = KeychainRelayCredentialStore(
            service: "test.relay.service",
            label: "Test Relay Credential",
            backing: backing)
        let reference = RelayCredentialReference.make(for: UUID())

        #expect(try store.loadCredential(reference: reference) == nil)
        try store.storeCredential("  test-api-key  \n", reference: reference)
        #expect(try store.loadCredential(reference: reference) == "test-api-key")
        #expect(backing.lastStore?.service == "test.relay.service")
        #expect(backing.lastStore?.account == reference)
        #expect(backing.lastStore?.label == "Test Relay Credential")

        try store.removeCredential(reference: reference)
        #expect(try store.loadCredential(reference: reference) == nil)
    }

    @Test
    func `credential store rejects empty credentials and invalid references before storage`() throws {
        let backing = InMemoryRelayCredentialKeychainBacking()
        let store = KeychainRelayCredentialStore(service: "test.service", backing: backing)
        let reference = RelayCredentialReference.make(for: UUID())

        #expect(throws: RelayCredentialStoreError.emptyCredential) {
            try store.storeCredential(" \n ", reference: reference)
        }
        #expect(throws: RelayCredentialStoreError.invalidReference) {
            try store.storeCredential("test-api-key", reference: "not-a-keychain-reference")
        }
        #expect(backing.lastStore == nil)
    }

    @Test
    func `credential store rejects invalid keychain data`() throws {
        let backing = InMemoryRelayCredentialKeychainBacking()
        let store = KeychainRelayCredentialStore(service: "test.service", backing: backing)
        let reference = RelayCredentialReference.make(for: UUID())
        backing.seed(Data([0xFF]), service: "test.service", account: reference)

        #expect(throws: RelayCredentialStoreError.invalidCredentialData) {
            try store.loadCredential(reference: reference)
        }
    }
}

private final class InMemoryRelayCredentialKeychainBacking: RelayCredentialKeychainBacking, @unchecked Sendable {
    struct StoreCall: Equatable {
        let service: String
        let account: String
        let label: String
    }

    private struct Key: Hashable {
        let service: String
        let account: String
    }

    private let lock = NSLock()
    private var entries: [Key: Data] = [:]
    private var storedCall: StoreCall?

    var lastStore: StoreCall? {
        self.lock.withLock { self.storedCall }
    }

    func load(service: String, account: String) -> Data? {
        self.lock.withLock { self.entries[Key(service: service, account: account)] }
    }

    func store(_ data: Data, service: String, account: String, label: String) {
        self.lock.withLock {
            self.entries[Key(service: service, account: account)] = data
            self.storedCall = StoreCall(service: service, account: account, label: label)
        }
    }

    func remove(service: String, account: String) {
        self.lock.withLock {
            self.entries.removeValue(forKey: Key(service: service, account: account))
        }
    }

    func seed(_ data: Data, service: String, account: String) {
        self.lock.withLock {
            self.entries[Key(service: service, account: account)] = data
        }
    }
}
