import Foundation

public enum UsageLedgerWindow: Int, CaseIterable, Codable, Sendable {
    case rolling24Hours = 1
    case rolling7Days = 7
    case rolling30Days = 30

    public var duration: TimeInterval {
        TimeInterval(self.rawValue * 24 * 60 * 60)
    }

    public func contains(_ timestamp: Date, endingAt end: Date) -> Bool {
        timestamp >= end.addingTimeInterval(-self.duration) && timestamp <= end
    }
}

public struct UsageLedgerKey: Codable, Hashable, Sendable {
    public let identityID: String
    public let routeProfileID: UUID?
    public let targetApp: RelayTargetApp
    public let model: String
    public let requestID: String?
    public let sessionID: String?
    public let timestamp: Date

    public init(
        identityID: String,
        routeProfileID: UUID?,
        targetApp: RelayTargetApp,
        model: String,
        requestID: String?,
        sessionID: String?,
        timestamp: Date)
    {
        self.identityID = identityID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.routeProfileID = routeProfileID
        self.targetApp = targetApp
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.requestID = Self.cleaned(requestID)
        self.sessionID = Self.cleaned(sessionID)
        self.timestamp = timestamp
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

public enum UsageLedgerAttribution: String, Codable, Sendable {
    case official
    case relay
    case unassigned
}

public struct UsageLedgerAmounts: Codable, Equatable, Sendable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheCreationTokens: Int
    public let totalTokens: Int
    public let requestCount: Int
    public let costUSD: Double?

    public static let zero = Self(
        inputTokens: 0,
        outputTokens: 0,
        cacheReadTokens: 0,
        cacheCreationTokens: 0,
        totalTokens: 0,
        requestCount: 0,
        costUSD: 0)

    public init(
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheCreationTokens: Int,
        totalTokens: Int,
        requestCount: Int,
        costUSD: Double?)
    {
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
        self.cacheReadTokens = max(0, cacheReadTokens)
        self.cacheCreationTokens = max(0, cacheCreationTokens)
        self.totalTokens = max(0, totalTokens)
        self.requestCount = max(0, requestCount)
        self.costUSD = costUSD.map { max(0, $0) }
    }

    public func adding(_ other: Self) -> Self {
        Self(
            inputTokens: self.inputTokens + other.inputTokens,
            outputTokens: self.outputTokens + other.outputTokens,
            cacheReadTokens: self.cacheReadTokens + other.cacheReadTokens,
            cacheCreationTokens: self.cacheCreationTokens + other.cacheCreationTokens,
            totalTokens: self.totalTokens + other.totalTokens,
            requestCount: self.requestCount + other.requestCount,
            costUSD: Self.addCosts(self.costUSD, other.costUSD))
    }

    private static func addCosts(_ lhs: Double?, _ rhs: Double?) -> Double? {
        guard let lhs, let rhs else { return nil }
        return lhs + rhs
    }
}

public struct UsageLedgerEntry: Codable, Equatable, Sendable {
    public let key: UsageLedgerKey
    public let attribution: UsageLedgerAttribution
    public let amounts: UsageLedgerAmounts

    public init(key: UsageLedgerKey, attribution: UsageLedgerAttribution, amounts: UsageLedgerAmounts) {
        self.key = key
        self.attribution = attribution
        self.amounts = amounts
    }
}

public struct UsageLedgerPartition: Equatable, Sendable {
    public let officialByIdentityID: [String: UsageLedgerAmounts]
    public let relayByIdentityID: [String: UsageLedgerAmounts]
    public let unassigned: UsageLedgerAmounts
    public let total: UsageLedgerAmounts

    public var componentTotal: UsageLedgerAmounts {
        let official = self.officialByIdentityID.values.reduce(UsageLedgerAmounts.zero) { $0.adding($1) }
        let relay = self.relayByIdentityID.values.reduce(UsageLedgerAmounts.zero) { $0.adding($1) }
        return official.adding(relay).adding(self.unassigned)
    }

    public var isConserved: Bool {
        let components = self.componentTotal
        guard components.inputTokens == self.total.inputTokens,
              components.outputTokens == self.total.outputTokens,
              components.cacheReadTokens == self.total.cacheReadTokens,
              components.cacheCreationTokens == self.total.cacheCreationTokens,
              components.totalTokens == self.total.totalTokens,
              components.requestCount == self.total.requestCount
        else { return false }
        switch (components.costUSD, self.total.costUSD) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return abs(lhs - rhs) < 0.000_001
        default:
            return false
        }
    }
}

public struct UsageLedger: Sendable {
    private let entriesByKey: [UsageLedgerKey: UsageLedgerEntry]

    public init(entries: [UsageLedgerEntry] = []) {
        self.entriesByKey = entries.reduce(into: [:]) { result, entry in
            result[entry.key] = entry
        }
    }

    public var entries: [UsageLedgerEntry] {
        self.entriesByKey.values.sorted { lhs, rhs in
            if lhs.key.timestamp != rhs.key.timestamp {
                return lhs.key.timestamp < rhs.key.timestamp
            }
            return Self.stableKey(lhs.key) < Self.stableKey(rhs.key)
        }
    }

    public func partition(for window: UsageLedgerWindow, endingAt end: Date) -> UsageLedgerPartition {
        var official: [String: UsageLedgerAmounts] = [:]
        var relay: [String: UsageLedgerAmounts] = [:]
        var unassigned = UsageLedgerAmounts.zero
        var total = UsageLedgerAmounts.zero

        for entry in self.entriesByKey.values where window.contains(entry.key.timestamp, endingAt: end) {
            total = total.adding(entry.amounts)
            switch Self.bucket(for: entry) {
            case let .official(identityID):
                official[identityID] = (official[identityID] ?? .zero).adding(entry.amounts)
            case let .relay(identityID):
                relay[identityID] = (relay[identityID] ?? .zero).adding(entry.amounts)
            case .unassigned:
                unassigned = unassigned.adding(entry.amounts)
            }
        }

        return UsageLedgerPartition(
            officialByIdentityID: official,
            relayByIdentityID: relay,
            unassigned: unassigned,
            total: total)
    }

    public func officialSummary(
        identityID: String,
        for window: UsageLedgerWindow,
        endingAt end: Date) -> UsageLedgerAmounts
    {
        self.partition(for: window, endingAt: end).officialByIdentityID[identityID] ?? .zero
    }

    private enum Bucket {
        case official(String)
        case relay(String)
        case unassigned
    }

    private static func bucket(for entry: UsageLedgerEntry) -> Bucket {
        let identityID = entry.key.identityID
        let isRelayIdentity = identityID.hasPrefix("relay:") || identityID.hasPrefix("api:")
        if entry.attribution == .relay || entry.key.routeProfileID != nil || isRelayIdentity {
            return .relay(identityID)
        }
        let isUnassignedIdentity = identityID.hasPrefix("system-unassigned:")
            || identityID == UsageIdentity.systemUnassignedAccountKey
        if entry.attribution == .official, !identityID.isEmpty, !isUnassignedIdentity {
            return .official(identityID)
        }
        return .unassigned
    }

    private static func stableKey(_ key: UsageLedgerKey) -> String {
        [
            key.identityID,
            key.routeProfileID?.uuidString.lowercased() ?? "",
            key.targetApp.rawValue,
            key.model,
            key.requestID ?? "",
            key.sessionID ?? "",
        ].joined(separator: "\u{1f}")
    }
}
