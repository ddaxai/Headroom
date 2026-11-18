import Foundation

/// Stable, non-secret identity for a usage card and its local cache.
///
/// The account key is deliberately composed from persisted identifiers only;
/// API tokens and other credentials must never be used as a cache key.
public struct UsageIdentity: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case subscription
        case relayAPI
        case directAPI
    }

    public let kind: Kind
    public let provider: UsageProvider
    public let accountKey: String
    public let displayLabel: String
    public let authFingerprint: String?
    public let localHomePath: String?

    public static let systemUnassignedAccountKey = "codex:system:unassigned"

    public init(
        kind: Kind,
        provider: UsageProvider,
        accountKey: String,
        displayLabel: String,
        authFingerprint: String? = nil,
        localHomePath: String? = nil)
    {
        self.kind = kind
        self.provider = provider
        self.accountKey = Self.clean(accountKey)
        self.displayLabel = Self.clean(displayLabel)
        self.authFingerprint = Self.optionalClean(authFingerprint)
        if let home = Self.optionalClean(localHomePath) {
            self.localHomePath = URL(fileURLWithPath: home, isDirectory: true).standardizedFileURL.path
        } else {
            self.localHomePath = nil
        }
    }

    public static func subscription(
        provider: UsageProvider,
        accountKey: String,
        displayLabel: String,
        authFingerprint: String? = nil,
        localHomePath: String? = nil) -> Self
    {
        let rawKey = Self.clean(accountKey)
        let key = provider == .codex && !rawKey.hasPrefix("codex:")
            ? "codex:\(rawKey)"
            : "\(provider.rawValue):\(rawKey)"
        return Self(
            kind: .subscription,
            provider: provider,
            accountKey: key,
            displayLabel: displayLabel,
            authFingerprint: authFingerprint,
            localHomePath: localHomePath)
    }

    /// The ambient Codex home is not a proof of account ownership. Keep its
    /// history in a stable, explicitly unassigned bucket until it is written
    /// into an isolated account home.
    public static func systemUnassigned(localHomePath: String? = nil) -> Self {
        Self(
            kind: .subscription,
            provider: .codex,
            accountKey: Self.systemUnassignedAccountKey,
            displayLabel: "System / Unassigned",
            localHomePath: localHomePath)
    }

    /// A per-home source ID is kept separate from the shared attribution key:
    /// cards stay grouped as System / Unassigned without overwriting one
    /// another when multiple ambient homes are visible.
    public static func systemUnassignedSourceID(localHomePath: String) -> String {
        let normalized = URL(fileURLWithPath: localHomePath, isDirectory: true).standardizedFileURL.path
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in normalized.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "system-unassigned:%016llx", hash)
    }

    public static func codexCurrentScope(
        activeAccount: CodexVisibleAccount?,
        localHomePath: String?) -> Self?
    {
        guard let localHomePath,
              !localHomePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .systemUnassigned()
        }
        guard let activeAccount else { return .systemUnassigned(localHomePath: localHomePath) }
        return .subscription(account: activeAccount, localHomePath: localHomePath)
    }

    public var isSystemUnassigned: Bool {
        self.accountKey == Self.systemUnassignedAccountKey
    }

    public static func relayAPI(
        provider: UsageProvider,
        profileID: UUID,
        target: String,
        displayLabel: String,
        authFingerprint: String? = nil) -> Self
    {
        Self(
            kind: .relayAPI,
            provider: provider,
            accountKey: "relay:\(profileID.uuidString.lowercased()):\(self.clean(target))",
            displayLabel: displayLabel,
            authFingerprint: authFingerprint)
    }

    public static func directAPI(
        provider: UsageProvider,
        tokenAccountID: UUID,
        displayLabel: String,
        authFingerprint: String? = nil) -> Self
    {
        Self(
            kind: .directAPI,
            provider: provider,
            accountKey: "api:\(provider.rawValue):\(tokenAccountID.uuidString.lowercased())",
            displayLabel: displayLabel,
            authFingerprint: authFingerprint)
    }

    public static func subscription(
        account: CodexVisibleAccount,
        localHomePath: String? = nil) -> Self
    {
        let sourceKey = switch account.selectionSource {
        case .liveSystem:
            if let storedAccountID = account.storedAccountID {
                "managed:\(storedAccountID.uuidString.lowercased())"
            } else {
                "live:\(account.workspaceAccountID ?? account.email)"
            }
        case let .managedAccount(id):
            "managed:\(id.uuidString.lowercased())"
        case let .profileHome(path):
            "profile:\(URL(fileURLWithPath: path).standardizedFileURL.path)"
        }
        return Self.subscription(
            provider: .codex,
            accountKey: sourceKey,
            displayLabel: account.displayName,
            authFingerprint: account.authFingerprint,
            localHomePath: localHomePath)
    }

    private static func clean(_ raw: String?) -> String {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "unknown" : value
    }

    private static func optionalClean(_ raw: String?) -> String? {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
}

public enum AccountSessionAttribution: Equatable, Sendable {
    case assigned(UsageIdentity)
    case unassigned
}

/// A filesystem corpus plus the identity that is allowed to claim it.
/// Multiple identities pointing at one home are treated as ambiguous and
/// collapsed into the unassigned bucket; this prevents cached rows being
/// copied into every visible account card.
public struct AccountSessionSource: Equatable, Sendable {
    public let codexHome: URL
    public let attribution: AccountSessionAttribution

    public init(codexHome: URL, attribution: AccountSessionAttribution) {
        self.codexHome = codexHome.standardizedFileURL
        self.attribution = attribution
    }

    public var accountKey: String {
        switch self.attribution {
        case let .assigned(identity): identity.accountKey
        case .unassigned: UsageIdentity.systemUnassignedAccountKey
        }
    }

    public var usageIdentity: UsageIdentity {
        switch self.attribution {
        case let .assigned(identity): identity
        case .unassigned:
            UsageIdentity.systemUnassigned(localHomePath: self.codexHome.path)
        }
    }
}

public struct AccountSessionAttributionPlan: Equatable, Sendable {
    public let sources: [AccountSessionSource]

    public static func make(sources: [AccountSessionSource]) -> Self {
        var grouped: [String: [AccountSessionSource]] = [:]
        var order: [String] = []
        for source in sources {
            let path = source.codexHome.path
            if grouped[path] == nil { order.append(path) }
            grouped[path, default: []].append(source)
        }

        let planned = order.compactMap { path -> AccountSessionSource? in
            guard let candidates = grouped[path], let first = candidates.first else { return nil }
            let assigned = candidates.compactMap { candidate -> UsageIdentity? in
                guard case let .assigned(identity) = candidate.attribution else { return nil }
                return identity
            }
            let distinctKeys = Set(assigned.map(\.accountKey))
            guard candidates.allSatisfy({
                if case .assigned = $0.attribution { return true }
                return false
            }), distinctKeys.count == 1, let identity = assigned.first else {
                return AccountSessionSource(codexHome: first.codexHome, attribution: .unassigned)
            }
            return AccountSessionSource(codexHome: first.codexHome, attribution: .assigned(identity))
        }
        return Self(sources: planned)
    }
}
