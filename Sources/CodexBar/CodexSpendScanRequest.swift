import CodexBarCore
import CryptoKit
import Foundation

struct SpendDashboardAccountDiagnostic: Equatable, Sendable {
    let accountKey: String
    let email: String?
    let workspaceAccountID: String?
    let authFingerprint: String?
    let codexHome: String
    let lastScanAt: Date?
    let sidecarFingerprint: String
    let duplicateAccountKeys: [String]
    let storedAccountID: UUID?
    let canRemove: Bool
    let hasManualAttribution: Bool

    init(
        accountKey: String,
        email: String?,
        workspaceAccountID: String?,
        authFingerprint: String?,
        codexHome: String,
        lastScanAt: Date?,
        sidecarFingerprint: String,
        duplicateAccountKeys: [String],
        storedAccountID: UUID?,
        canRemove: Bool,
        hasManualAttribution: Bool = false)
    {
        self.accountKey = accountKey
        self.email = email
        self.workspaceAccountID = workspaceAccountID
        self.authFingerprint = authFingerprint
        self.codexHome = codexHome
        self.lastScanAt = lastScanAt
        self.sidecarFingerprint = sidecarFingerprint
        self.duplicateAccountKeys = duplicateAccountKeys
        self.storedAccountID = storedAccountID
        self.canRemove = canRemove
        self.hasManualAttribution = hasManualAttribution
    }

    var isDuplicate: Bool {
        !self.duplicateAccountKeys.isEmpty
    }

    var truncatedAuthFingerprint: String? {
        guard let authFingerprint, !authFingerprint.isEmpty else { return nil }
        return String(authFingerprint.prefix(12)) + "…"
    }

    /// `accountKey` deliberately groups all ambient homes, but a failed scan
    /// still needs one visible diagnostic per home.
    var stableDiagnosticID: String {
        [self.accountKey, self.codexHome, self.sidecarFingerprint].joined(separator: "\u{0}")
    }
}

struct CodexSpendScanRequest: Equatable, Sendable {
    let id: String
    let displayName: String
    let source: CodexActiveSource
    let homePath: String
    let authFingerprint: String?
    let authFileWasReadable: Bool
    let cacheIdentity: String
    let usageIdentity: UsageIdentity
    let isHomeReadable: Bool
    let email: String?
    let workspaceAccountID: String?
    let storedAccountID: UUID?
    let canRemove: Bool
    let duplicateAccountKeys: [String]
    /// This account has no isolated Codex home. It may consume only rows that
    /// the ownership timeline explicitly assigns from the shared system home.
    let scansSharedHomeOnly: Bool
    /// The real Codex runtime still writes rollout events into the shared
    /// system home. Named accounts consume only rows assigned by this timeline.
    let sharedHomePath: String?
    let sessionOwnershipTimeline: CodexSessionOwnershipTimeline?

    init(
        id: String,
        displayName: String,
        source: CodexActiveSource,
        homePath: String,
        authFingerprint: String?,
        authFileWasReadable: Bool,
        cacheIdentity: String,
        usageIdentity: UsageIdentity? = nil,
        isHomeReadable: Bool = true,
        email: String? = nil,
        workspaceAccountID: String? = nil,
        storedAccountID: UUID? = nil,
        canRemove: Bool = false,
        duplicateAccountKeys: [String] = [],
        scansSharedHomeOnly: Bool = false,
        sharedHomePath: String? = nil,
        sessionOwnershipTimeline: CodexSessionOwnershipTimeline? = nil)
    {
        self.id = id
        self.displayName = displayName
        self.source = source
        self.homePath = homePath
        self.authFingerprint = authFingerprint
        self.authFileWasReadable = authFileWasReadable
        self.cacheIdentity = cacheIdentity
        self.usageIdentity = usageIdentity ?? UsageIdentity.subscription(
            provider: .codex,
            accountKey: id,
            displayLabel: displayName,
            authFingerprint: authFingerprint,
            localHomePath: homePath)
        self.isHomeReadable = isHomeReadable
        self.email = email
        self.workspaceAccountID = workspaceAccountID
        self.storedAccountID = storedAccountID
        self.canRemove = canRemove
        self.duplicateAccountKeys = duplicateAccountKeys
        self.scansSharedHomeOnly = scansSharedHomeOnly
        self.sharedHomePath = sharedHomePath
        self.sessionOwnershipTimeline = sessionOwnershipTimeline
    }

    func attributingSharedHome(
        _ sharedHomePath: String,
        timeline: CodexSessionOwnershipTimeline) -> Self
    {
        Self(
            id: self.id,
            displayName: self.displayName,
            source: self.source,
            homePath: self.homePath,
            authFingerprint: self.authFingerprint,
            authFileWasReadable: self.authFileWasReadable,
            cacheIdentity: self.cacheIdentity,
            usageIdentity: self.usageIdentity,
            isHomeReadable: self.isHomeReadable,
            email: self.email,
            workspaceAccountID: self.workspaceAccountID,
            storedAccountID: self.storedAccountID,
            canRemove: self.canRemove,
            duplicateAccountKeys: self.duplicateAccountKeys,
            scansSharedHomeOnly: self.scansSharedHomeOnly,
            sharedHomePath: CodexHomeScope.normalizedHomePath(sharedHomePath) ?? sharedHomePath,
            sessionOwnershipTimeline: timeline)
    }

    func diagnostic(lastScanAt: Date?) -> SpendDashboardAccountDiagnostic {
        SpendDashboardAccountDiagnostic(
            accountKey: self.usageIdentity.accountKey,
            email: self.email,
            workspaceAccountID: self.workspaceAccountID,
            authFingerprint: self.authFingerprint,
            codexHome: self.homePath,
            lastScanAt: lastScanAt,
            sidecarFingerprint: self.cacheIdentity,
            duplicateAccountKeys: self.duplicateAccountKeys,
            storedAccountID: self.storedAccountID,
            canRemove: self.canRemove,
            hasManualAttribution: self.sessionOwnershipTimeline?.manualAttributions.contains {
                $0.accountKey == self.usageIdentity.accountKey
            } == true)
    }
}

struct CodexMenuSpendPlan: Equatable, Sendable {
    let generation: UInt64
    let projectionSignature: String
    let requests: [CodexSpendScanRequest]

    var sharedCorpusHomePath: String? {
        self.requests.compactMap(\.sharedHomePath).first
            ?? self.requests.first(where: { $0.usageIdentity.isSystemUnassigned })?.homePath
    }

    var ownershipRevision: String? {
        self.requests.compactMap { $0.sessionOwnershipTimeline?.revision }.first
    }

    func hasCurrentOwnershipRevision(_ revision: String?) -> Bool {
        self.ownershipRevision == revision
    }

    static func projectionSignature(_ projection: CodexVisibleAccountProjection) -> String {
        let fields = projection.visibleAccounts.flatMap { account in
            [
                account.id,
                account.storedAccountID?.uuidString.lowercased() ?? "",
                String(describing: account.selectionSource),
                account.authFingerprint ?? "",
                account.codexHomePath ?? "",
                account.managedCodexHomePath ?? "",
            ]
        } + [
            projection.activeVisibleAccountID ?? "",
            projection.liveVisibleAccountID ?? "",
            projection.hasUnreadableAddedAccountStore ? "unreadable" : "readable",
        ]
        return SHA256.hash(data: Data(fields.joined(separator: "\u{0}").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func isCurrent(generation: UInt64, projection: CodexVisibleAccountProjection?) -> Bool {
        self.generation == generation && projection.map(Self.projectionSignature) == self.projectionSignature
    }
}
