import Foundation

/// Applications whose live configuration is intentionally managed by this fork.
public enum RelayTargetApp: String, Codable, CaseIterable, Hashable, Sendable {
    case codex
    case claudeCode
    case claudeDesktop
    case grokBuild
    case openCode
    case piAgent
}

/// Wire format expected by a relay. Direct config writers use this to reject incompatible targets
/// instead of silently installing a configuration that needs a local protocol-conversion proxy.
public enum RelayAPIFormat: String, Codable, CaseIterable, Sendable {
    case openAIResponses
    case openAIChatCompletions
    case anthropicMessages
}

/// Optional accounting endpoint associated with a relay profile.
///
/// Sub2API is the default because it is the gateway format used by the relay profiles this fork
/// manages. Users can still choose the generic endpoint or disable balance queries entirely.
public enum RelayUsageQueryMode: String, Codable, CaseIterable, Sendable {
    case disabled
    case sub2API = "sub2api"
    case genericBalance
    case customBalance
}

/// Restricted balance mapping for a relay that exposes no supported usage API.
/// This is deliberately a balance adapter: it must not be presented as token or
/// per-request accounting because a balance delta cannot reliably be converted to tokens.
public struct RelayCustomBalanceConfiguration: Codable, Equatable, Sendable {
    public enum Authentication: String, Codable, CaseIterable, Sendable {
        case bearer
        case xAPIKey = "x-api-key"
    }

    public var endpointPath: String
    public var authentication: Authentication
    public var remainingJSONPath: String
    public var usedJSONPath: String
    public var totalJSONPath: String
    public var currencyCode: String
    public var divisor: Double

    public init(
        endpointPath: String,
        authentication: Authentication = .bearer,
        remainingJSONPath: String = "remaining",
        usedJSONPath: String = "used",
        totalJSONPath: String = "total",
        currencyCode: String = "USD",
        divisor: Double = 1)
    {
        self.endpointPath = endpointPath
        self.authentication = authentication
        self.remainingJSONPath = remainingJSONPath
        self.usedJSONPath = usedJSONPath
        self.totalJSONPath = totalJSONPath
        self.currencyCode = currencyCode
        self.divisor = divisor
    }
}

public struct RelayRecentUsageSummary: Codable, Equatable, Sendable {
    public enum Period: String, Codable, Sendable {
        case rolling24Hours
        case today
    }

    public let period: Period
    public let totalTokens: Int
    public let actualCostUSD: Double
    /// Cache tokens reported by the provider. These values stay in the reported lane and are
    /// intentionally not folded into the local ledger estimate.
    public let cacheReadTokens: Int?
    public let cacheCreationTokens: Int?

    public init(
        period: Period,
        totalTokens: Int,
        actualCostUSD: Double,
        cacheReadTokens: Int? = nil,
        cacheCreationTokens: Int? = nil)
    {
        self.period = period
        self.totalTokens = totalTokens
        self.actualCostUSD = actualCostUSD
        self.cacheReadTokens = cacheReadTokens.map { max(0, $0) }
        self.cacheCreationTokens = cacheCreationTokens.map { max(0, $0) }
    }

    public var hasReportedCacheTokens: Bool {
        (self.cacheReadTokens ?? 0) > 0 || (self.cacheCreationTokens ?? 0) > 0
    }
}

public struct RelayUsageSummary: Codable, Equatable, Sendable {
    public let remaining: Double?
    public let used: Double?
    public let total: Double?
    public let unit: String
    public let planName: String?
    public let updatedAt: Date
    public let recentUsage: RelayRecentUsageSummary?

    public init(
        remaining: Double?,
        used: Double?,
        total: Double?,
        unit: String,
        planName: String?,
        updatedAt: Date,
        recentUsage: RelayRecentUsageSummary? = nil)
    {
        self.remaining = remaining
        self.used = used
        self.total = total
        self.unit = unit
        self.planName = planName
        self.updatedAt = updatedAt
        self.recentUsage = recentUsage
    }
}

/// Controls which Codex session-history bucket relay and official configurations use.
public enum RelayCodexProviderMode: String, Codable, Sendable {
    case isolated
    case unified

    public var providerID: String {
        switch self {
        case .isolated: "codexbar_relay"
        case .unified: "codexbar_shared"
        }
    }
}

public struct RelayTargetConfiguration: Codable, Equatable, Sendable {
    public let app: RelayTargetApp
    public var model: String?
    public var baseURLOverride: URL?
    public var apiFormatOverride: RelayAPIFormat?
    public var isEnabled: Bool

    public init(
        app: RelayTargetApp,
        model: String? = nil,
        baseURLOverride: URL? = nil,
        apiFormatOverride: RelayAPIFormat? = nil,
        isEnabled: Bool = true)
    {
        self.app = app
        self.model = model
        self.baseURLOverride = baseURLOverride
        self.apiFormatOverride = apiFormatOverride
        self.isEnabled = isEnabled
    }
}

/// Persisted relay metadata. `credentialReference` points to a separate credential store so the API
/// key is not duplicated into this value or into app preferences.
public struct RelayProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    /// ASCII identifier written to OpenCode, Pi, and other client configuration files.
    /// Codex's route provider IDs remain separately controlled by `RelayCodexProviderMode`.
    public var providerKey: String
    public var name: String
    public var baseURL: URL
    public var apiFormat: RelayAPIFormat
    public var defaultModel: String?
    public var credentialReference: String
    /// Non-secret marker set only after CodexBar successfully stores this profile's credential.
    /// This keeps an incomplete draft blocked after relaunch without embedding the secret in metadata.
    public var credentialConfigured: Bool
    public var usageQueryMode: RelayUsageQueryMode
    public var customBalance: RelayCustomBalanceConfiguration?
    public var targets: [RelayTargetConfiguration]
    /// Presentation-only filter for the client rows shown in relay settings.
    /// It does not disable or remove the persisted target configurations.
    public var visibleTargets: Set<RelayTargetApp>

    public init(
        id: UUID = UUID(),
        name: String,
        baseURL: URL,
        apiFormat: RelayAPIFormat,
        defaultModel: String? = nil,
        credentialReference: String,
        credentialConfigured: Bool = false,
        usageQueryMode: RelayUsageQueryMode = .sub2API,
        customBalance: RelayCustomBalanceConfiguration? = nil,
        targets: [RelayTargetConfiguration],
        visibleTargets: Set<RelayTargetApp> = Set(RelayTargetApp.allCases),
        providerKey: String? = nil)
    {
        self.id = id
        self.providerKey = RelayProviderKey.slug(for: providerKey ?? name, fallbackID: id)
        self.name = name
        self.baseURL = baseURL
        self.apiFormat = apiFormat
        self.defaultModel = defaultModel
        self.credentialReference = credentialReference
        self.credentialConfigured = credentialConfigured
        self.usageQueryMode = usageQueryMode
        self.customBalance = customBalance
        self.targets = targets
        self.visibleTargets = visibleTargets
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case providerKey
        case name
        case baseURL
        case apiFormat
        case defaultModel
        case credentialReference
        case credentialConfigured
        case usageQueryMode
        case customBalance
        case targets
        case visibleTargets
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        let storedProviderKey = try container.decodeIfPresent(String.self, forKey: .providerKey)
        self.providerKey = RelayProviderKey.slug(for: storedProviderKey ?? self.name, fallbackID: self.id)
        self.baseURL = try container.decode(URL.self, forKey: .baseURL)
        self.apiFormat = try container.decode(RelayAPIFormat.self, forKey: .apiFormat)
        self.defaultModel = try container.decodeIfPresent(String.self, forKey: .defaultModel)
        self.credentialReference = try container.decode(String.self, forKey: .credentialReference)
        self.credentialConfigured = try container.decodeIfPresent(Bool.self, forKey: .credentialConfigured) ?? false
        self.usageQueryMode = try container.decodeIfPresent(RelayUsageQueryMode.self, forKey: .usageQueryMode)
            ?? .sub2API
        self.customBalance = try container.decodeIfPresent(RelayCustomBalanceConfiguration.self, forKey: .customBalance)
        self.targets = try container.decode([RelayTargetConfiguration].self, forKey: .targets)
        self.visibleTargets = try container.decodeIfPresent(Set<RelayTargetApp>.self, forKey: .visibleTargets)
            ?? Set(RelayTargetApp.allCases)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.providerKey, forKey: .providerKey)
        try container.encode(self.name, forKey: .name)
        try container.encode(self.baseURL, forKey: .baseURL)
        try container.encode(self.apiFormat, forKey: .apiFormat)
        if let defaultModel {
            try container.encode(defaultModel, forKey: .defaultModel)
        } else {
            try container.encodeNil(forKey: .defaultModel)
        }
        try container.encode(self.credentialReference, forKey: .credentialReference)
        try container.encode(self.credentialConfigured, forKey: .credentialConfigured)
        try container.encode(self.usageQueryMode, forKey: .usageQueryMode)
        try container.encodeIfPresent(self.customBalance, forKey: .customBalance)
        try container.encode(self.targets, forKey: .targets)
        try container.encode(self.visibleTargets, forKey: .visibleTargets)
    }

    public func configuration(for app: RelayTargetApp) -> RelayTargetConfiguration? {
        self.targets.first { $0.app == app && $0.isEnabled }
    }
}
