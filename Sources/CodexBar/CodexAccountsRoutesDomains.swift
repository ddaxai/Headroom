import CodexBarCore
import Foundation

@MainActor
protocol AccountsDomain: AnyObject {
    func identities() async -> [CodexAccountIdentity]
    func cachedQuota(for identity: CodexAccountIdentity) async -> UsageSnapshot?
    func refreshQuota(for identity: CodexAccountIdentity) async throws -> UsageSnapshot?
    func switchAccount(to identity: CodexAccountIdentity) async throws

    var visibleAccountProjection: CodexVisibleAccountProjection { get }
    @discardableResult func selectVisibleAccount(id: String) -> Bool
    func selectDisplayedAccount(_ account: CodexVisibleAccount)
    func activateAuthenticatedAccount(_ account: ManagedCodexAccount)
    @discardableResult func prepareScopedRefreshIfNeeded() -> Bool
    func refreshScopedState(
        allowDisabled: Bool,
        phaseDidChange: (@MainActor (CodexAccountScopedRefreshPhase) -> Void)?) async
}

@MainActor
protocol RoutesDomain: AnyObject {
    func profiles() throws -> [RelayProfile]
    func selectedProfileID() -> UUID?
    func selectProfile(id: UUID?) throws
    func apply(_ profile: RelayProfile) throws -> RelaySwitchResult
}

extension RoutesDomain {
    func apply(id: UUID, target: RelayTargetApp) throws -> RelaySwitchResult {
        guard let profile = try self.profiles().first(where: { $0.id == id }) else {
            throw RoutesDomainError.unknownProfile
        }
        let targetOnlyProfile = RelayProfile(
            id: profile.id,
            name: profile.name,
            baseURL: profile.baseURL,
            apiFormat: profile.apiFormat,
            defaultModel: profile.defaultModel,
            credentialReference: profile.credentialReference,
            credentialConfigured: profile.credentialConfigured,
            usageQueryMode: profile.usageQueryMode,
            customBalance: profile.customBalance,
            targets: profile.targets.map { configuration in
                var scoped = configuration
                scoped.isEnabled = configuration.app == target
                return scoped
            },
            visibleTargets: profile.visibleTargets,
            providerKey: profile.providerKey)
        return try self.apply(targetOnlyProfile)
    }
}

enum AccountsDomainError: Error {
    case unknownIdentity
}

enum RoutesDomainError: Error {
    case unknownProfile
}

@MainActor
final class LiveAccountsDomain: AccountsDomain {
    private let settings: SettingsStore
    private let usageStore: UsageStore

    init(settings: SettingsStore, usageStore: UsageStore) {
        self.settings = settings
        self.usageStore = usageStore
    }

    var visibleAccountProjection: CodexVisibleAccountProjection {
        self.settings.codexVisibleAccountProjection
    }

    func identities() async -> [CodexAccountIdentity] {
        self.visibleAccountProjection.visibleAccounts.compactMap(Self.identity(for:))
    }

    func cachedQuota(for identity: CodexAccountIdentity) async -> UsageSnapshot? {
        if let cached = self.usageStore.codexQuotaService.cachedQuota(for: identity) {
            return cached
        }
        let visible = self.visibleAccountProjection.visibleAccounts
        if visible.count == 1,
           let only = visible.first,
           Self.identity(for: only) == identity
        {
            return self.usageStore.snapshots[.codex]
        }
        return nil
    }

    func refreshQuota(for identity: CodexAccountIdentity) async throws -> UsageSnapshot? {
        guard self.account(for: identity) != nil else { throw AccountsDomainError.unknownIdentity }
        await self.refreshScopedState(allowDisabled: true, phaseDidChange: nil)
        return await self.cachedQuota(for: identity)
    }

    func switchAccount(to identity: CodexAccountIdentity) async throws {
        guard let account = self.account(for: identity) else { throw AccountsDomainError.unknownIdentity }
        self.selectDisplayedAccount(account)
        await self.refreshScopedState(allowDisabled: true, phaseDidChange: nil)
    }

    @discardableResult
    func selectVisibleAccount(id: String) -> Bool {
        self.settings.selectCodexVisibleAccount(id: id)
    }

    func selectDisplayedAccount(_ account: CodexVisibleAccount) {
        self.settings.selectDisplayedCodexVisibleAccount(account)
    }

    func activateAuthenticatedAccount(_ account: ManagedCodexAccount) {
        self.settings.selectAuthenticatedManagedCodexAccount(account)
    }

    @discardableResult
    func prepareScopedRefreshIfNeeded() -> Bool {
        self.usageStore.prepareCodexAccountScopedRefreshIfNeeded()
    }

    func refreshScopedState(
        allowDisabled: Bool,
        phaseDidChange: (@MainActor (CodexAccountScopedRefreshPhase) -> Void)? = nil) async
    {
        await self.usageStore.refreshCodexAccountScopedState(
            allowDisabled: allowDisabled,
            phaseDidChange: phaseDidChange)
    }

    private func account(for identity: CodexAccountIdentity) -> CodexVisibleAccount? {
        self.visibleAccountProjection.visibleAccounts.first { Self.identity(for: $0) == identity }
    }

    private static func identity(for account: CodexVisibleAccount) -> CodexAccountIdentity? {
        CodexAccountIdentity(email: account.email, workspaceAccountID: account.workspaceAccountID)
    }
}

@MainActor
final class LiveRoutesDomain: RoutesDomain {
    private let actions: RelaySettingsActions
    private var selectedID: UUID?

    init(actions: RelaySettingsActions = .live()) {
        self.actions = actions
    }

    func profiles() throws -> [RelayProfile] {
        try self.actions.loadProfiles()
    }

    func selectedProfileID() -> UUID? {
        self.selectedID
    }

    func selectProfile(id: UUID?) throws {
        self.selectedID = id
    }

    func apply(_ profile: RelayProfile) throws -> RelaySwitchResult {
        try self.actions.applyProfile(profile)
    }
}
