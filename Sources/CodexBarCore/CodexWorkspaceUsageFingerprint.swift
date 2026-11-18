#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Stable sidecar identity for a normalized Codex rollout.
/// Scanner cursors are intentionally excluded: they do not alter the sidecar's
/// persisted usage, but rows, attribution, and cost maps do.
struct CodexWorkspaceUsageFingerprintPayload: Encodable {
    let accountKey: String?
    let authFingerprint: String?
    let codexHomePath: String?
    let days: [String: [String: [Int]]]
    let lastModel: String?
    let sessionID: String?
    let forkedFromID: String?
    let projectPath: String?
    let canonicalProjectPath: String?
    let session: CostUsageCodexSessionMetadata?
    let costNanos: [String: [String: Int64]]?
    let prioritySurchargeNanos: [String: [String: Int64]]?
    let standardCostNanos: [String: [String: Int64]]?
    let priorityCostNanos: [String: [String: Int64]]?
    let standardTokens: [String: [String: Int]]?
    let priorityTokens: [String: [String: Int]]?
    let rows: [CostUsageScanner.CodexUsageRow]?

    init(usage: CostUsageFileUsage, identity: UsageIdentity? = nil) {
        self.accountKey = identity?.accountKey ?? usage.usageIdentityKey
        self.authFingerprint = identity?.authFingerprint ?? usage.usageAuthFingerprint
        self.codexHomePath = identity?.localHomePath ?? usage.usageCodexHomePath
        self.days = usage.days
        self.lastModel = usage.lastModel
        self.sessionID = usage.sessionId
        self.forkedFromID = usage.forkedFromId
        self.projectPath = usage.projectPath
        self.canonicalProjectPath = usage.canonicalProjectPath
        self.session = usage.codexSession
        self.costNanos = usage.codexCostNanos
        self.prioritySurchargeNanos = usage.codexPrioritySurchargeNanos
        self.standardCostNanos = usage.codexStandardCostNanos
        self.priorityCostNanos = usage.codexPriorityCostNanos
        self.standardTokens = usage.codexStandardTokens
        self.priorityTokens = usage.codexPriorityTokens
        self.rows = usage.codexRows
    }
}

enum CodexWorkspaceUsageFingerprint {
    static func make(for usage: CostUsageFileUsage, identity: UsageIdentity? = nil) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(CodexWorkspaceUsageFingerprintPayload(
            usage: usage,
            identity: identity))
        else {
            return "unavailable"
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension CostUsageFileUsage {
    func codexWorkspaceUsageFingerprintValue() -> String {
        self.codexWorkspaceContentFingerprint ?? CodexWorkspaceUsageFingerprint.make(for: self)
    }

    func refreshingCodexWorkspaceUsageFingerprint(
        identity: UsageIdentity? = nil,
        attributionRevision: String? = nil) -> Self
    {
        var updated = self
        if let identity {
            updated.usageIdentityKey = identity.accountKey
            updated.usageAuthFingerprint = identity.authFingerprint
            updated.usageCodexHomePath = identity.localHomePath
        }
        if let attributionRevision {
            updated.usageAttributionRevision = attributionRevision
        }
        updated.codexWorkspaceContentFingerprint = CodexWorkspaceUsageFingerprint.make(
            for: updated,
            identity: identity)
        return updated
    }
}
