import Foundation
#if os(macOS)
import Darwin
import Security
#endif

public enum RelayCredentialStoreError: Error, Equatable, Sendable {
    case invalidReference
    case emptyCredential
    case invalidCredentialData
    case keychainUnavailable
    case keychainStatus(Int32)
    case unsupportedPlatform
}

public protocol RelayCredentialStoring: Sendable {
    func loadCredential(reference: String) throws -> String?
    func storeCredential(_ credential: String, reference: String) throws
    func removeCredential(reference: String) throws
}

public protocol RelayCredentialLocating: Sendable {
    func locator(for reference: String) throws -> RelayCredentialLocator
}

/// Plain-file relay credentials used by the local fork. Keeping this behind the same protocol as
/// the Keychain store lets the configuration helper read credentials without triggering macOS
/// authorization dialogs. The file is intentionally human-readable and restricted to its owner.
public struct FileRelayCredentialStore: RelayCredentialStoring, RelayCredentialLocating, @unchecked Sendable {
    public static let currentVersion = 1
    public static let locatorService = "com.steipete.codexbar.relay-credentials.file"

    private struct Payload: Codable {
        let version: Int
        var credentials: [String: String]
    }

    private static let lock = NSLock()
    private let fileURL: URL
    private let fileManager: FileManager

    public init(fileURL: URL = Self.defaultURL(), fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public func loadCredential(reference: String) throws -> String? {
        try Self.validate(reference: reference)
        return try Self.lock.withLock {
            try self.loadPayload().credentials[reference]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    public func storeCredential(_ credential: String, reference: String) throws {
        try Self.validate(reference: reference)
        let cleaned = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw RelayCredentialStoreError.emptyCredential }
        try Self.lock.withLock {
            var payload = try self.loadPayload()
            payload.credentials[reference] = cleaned
            try self.storePayload(payload)
        }
    }

    public func removeCredential(reference: String) throws {
        try Self.validate(reference: reference)
        try Self.lock.withLock {
            var payload = try self.loadPayload()
            guard payload.credentials.removeValue(forKey: reference) != nil else { return }
            try self.storePayload(payload)
        }
    }

    public func locator(for reference: String) throws -> RelayCredentialLocator {
        try Self.validate(reference: reference)
        return RelayCredentialLocator(service: Self.locatorService, account: reference)
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("relay-credentials.json", isDirectory: false)
    }

    private static func validate(reference: String) throws {
        guard RelayCredentialReference.isValid(reference) else {
            throw RelayCredentialStoreError.invalidReference
        }
    }

    private func loadPayload() throws -> Payload {
        guard self.fileManager.fileExists(atPath: self.fileURL.path) else {
            return Payload(version: Self.currentVersion, credentials: [:])
        }
        do {
            let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: self.fileURL))
            guard payload.version == Self.currentVersion else {
                throw RelayCredentialStoreError.invalidCredentialData
            }
            return payload
        } catch let error as RelayCredentialStoreError {
            throw error
        } catch {
            throw RelayCredentialStoreError.invalidCredentialData
        }
    }

    private func storePayload(_ payload: Payload) throws {
        let directory = self.fileURL.deletingLastPathComponent()
        if !self.fileManager.fileExists(atPath: directory.path) {
            try self.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(payload).write(to: self.fileURL, options: [.atomic])
        #if os(macOS) || os(Linux)
        try self.fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: self.fileURL.path)
        #endif
    }
}

/// Serializable coordinates for a credential item. Configuration writers may use this to build
/// command-backed authentication without embedding the credential itself.
public struct RelayCredentialLocator: Codable, Equatable, Sendable {
    public let service: String
    public let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    public var reference: String {
        self.account
    }
}

protocol RelayCredentialKeychainBacking: Sendable {
    func load(service: String, account: String) throws -> Data?
    func store(_ data: Data, service: String, account: String, label: String) throws
    func remove(service: String, account: String) throws
}

public struct KeychainRelayCredentialStore: RelayCredentialStoring, RelayCredentialLocating, Sendable {
    public static let defaultService = "com.steipete.codexbar.relay-credentials"
    public static let defaultLabel = "CodexBar Relay Credential"

    private let service: String
    private let label: String
    private let backing: any RelayCredentialKeychainBacking

    public init(
        service: String = Self.defaultService,
        label: String = Self.defaultLabel)
    {
        self.init(service: service, label: label, backing: SystemRelayCredentialKeychainBacking())
    }

    init(
        service: String,
        label: String = Self.defaultLabel,
        backing: any RelayCredentialKeychainBacking)
    {
        self.service = service
        self.label = label
        self.backing = backing
    }

    public func loadCredential(reference: String) throws -> String? {
        let account = try self.locator(for: reference).account
        guard let data = try self.backing.load(service: self.service, account: account) else {
            return nil
        }
        guard let credential = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !credential.isEmpty
        else {
            throw RelayCredentialStoreError.invalidCredentialData
        }
        return credential
    }

    public func storeCredential(_ credential: String, reference: String) throws {
        let account = try self.locator(for: reference).account
        let cleaned = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, let data = cleaned.data(using: .utf8) else {
            throw RelayCredentialStoreError.emptyCredential
        }
        try self.backing.store(data, service: self.service, account: account, label: self.label)
    }

    public func removeCredential(reference: String) throws {
        let account = try self.locator(for: reference).account
        try self.backing.remove(service: self.service, account: account)
    }

    public func locator(for reference: String) throws -> RelayCredentialLocator {
        try RelayCredentialLocator(
            service: self.service,
            account: Self.validatedReference(reference))
    }

    private static func validatedReference(_ reference: String) throws -> String {
        guard RelayCredentialReference.isValid(reference) else {
            throw RelayCredentialStoreError.invalidReference
        }
        return reference
    }
}

private struct SystemRelayCredentialKeychainBacking: RelayCredentialKeychainBacking {
    func load(service: String, account: String) throws -> Data? {
        #if os(macOS)
        try Self.requireKeychainAccess()
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        KeychainNoUIQuery.apply(to: &query)

        var result: CFTypeRef?
        let status = KeychainSecurity.copyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Self.error(for: status) }
        guard let data = result as? Data else {
            throw RelayCredentialStoreError.invalidCredentialData
        }
        return data
        #else
        throw RelayCredentialStoreError.unsupportedPlatform
        #endif
    }

    func store(_ data: Data, service: String, account: String, label: String) throws {
        #if os(macOS)
        try Self.requireKeychainAccess()
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        KeychainNoUIQuery.apply(to: &query)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = KeychainSecurity.update(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw Self.error(for: updateStatus) }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        addQuery[kSecAttrLabel as String] = label
        if let access = Self.relayCredentialAccessControl() {
            addQuery[kSecAttrAccess as String] = access
        }
        let addStatus = KeychainSecurity.add(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let retryStatus = KeychainSecurity.update(query as CFDictionary, attributes as CFDictionary)
            guard retryStatus == errSecSuccess else { throw Self.error(for: retryStatus) }
            return
        }
        guard addStatus == errSecSuccess else { throw Self.error(for: addStatus) }
        #else
        throw RelayCredentialStoreError.unsupportedPlatform
        #endif
    }

    func remove(service: String, account: String) throws {
        #if os(macOS)
        try Self.requireKeychainAccess()
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        KeychainNoUIQuery.apply(to: &query)
        let status = KeychainSecurity.delete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.error(for: status)
        }
        #else
        throw RelayCredentialStoreError.unsupportedPlatform
        #endif
    }

    #if os(macOS)
    private static func requireKeychainAccess() throws {
        guard !KeychainAccessGate.isDisabled else {
            throw RelayCredentialStoreError.keychainUnavailable
        }
    }

    private static func error(for status: OSStatus) -> RelayCredentialStoreError {
        if status == errSecInteractionNotAllowed || status == errSecNotAvailable {
            return .keychainUnavailable
        }
        return .keychainStatus(status)
    }

    private static func relayCredentialAccessControl() -> SecAccess? {
        let paths = KeychainCacheStore.trustedApplicationPathsForCacheAccess()
        guard !paths.isEmpty else { return nil }

        var trustedApplications: [SecTrustedApplication] = []
        for path in paths {
            let (status, application) = Self.createTrustedApplication(path: path)
            if status == errSecSuccess, let application {
                trustedApplications.append(application)
            }
        }
        guard !trustedApplications.isEmpty else { return nil }

        let (status, access) = Self.createAccessControl(trustedApplications: trustedApplications)
        return status == errSecSuccess ? access : nil
    }

    private typealias SecTrustedApplicationCreateFromPathFunction = @convention(c) (
        UnsafePointer<CChar>?,
        UnsafeMutablePointer<SecTrustedApplication?>?) -> OSStatus
    private typealias SecAccessCreateFunction = @convention(c) (
        CFString,
        CFArray,
        UnsafeMutablePointer<SecAccess?>?) -> OSStatus

    private static func createTrustedApplication(path: String) -> (OSStatus, SecTrustedApplication?) {
        guard let symbol = securitySymbol(named: "SecTrustedApplicationCreateFromPath") else {
            return (errSecInternalComponent, nil)
        }
        let function = unsafeBitCast(symbol, to: SecTrustedApplicationCreateFromPathFunction.self)
        var application: SecTrustedApplication?
        let status = path.withCString { function($0, &application) }
        return (status, application)
    }

    private static func createAccessControl(
        trustedApplications: [SecTrustedApplication]) -> (OSStatus, SecAccess?)
    {
        guard let symbol = securitySymbol(named: "SecAccessCreate") else {
            return (errSecInternalComponent, nil)
        }
        let function = unsafeBitCast(symbol, to: SecAccessCreateFunction.self)
        var access: SecAccess?
        let status = function(
            KeychainRelayCredentialStore.defaultLabel as CFString,
            trustedApplications as CFArray,
            &access)
        return (status, access)
    }

    private nonisolated(unsafe) static let securityFrameworkHandle: UnsafeMutableRawPointer? = {
        let path = "/System/Library/Frameworks/Security.framework/Security"
        return dlopen(path, RTLD_NOW)
    }()

    private static func securitySymbol(named name: String) -> UnsafeMutableRawPointer? {
        guard let securityFrameworkHandle else { return nil }
        return dlsym(securityFrameworkHandle, name)
    }
    #endif
}
