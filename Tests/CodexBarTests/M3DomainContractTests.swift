import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite("M3 domain contracts")
struct M3DomainContractTests {
    @Test
    func `two fixture accounts keep independent quota snapshots`() async throws {
        let domain = try MemoryAccountsDomain(fixture: .load())
        let identities = await domain.identities()
        let first = try #require(identities.first)
        let second = try #require(identities.dropFirst().first)
        let secondBefore = await domain.cachedQuota(for: second)?.primary?.usedPercent

        domain.stageRefresh(usedPercent: 91, for: first)
        _ = try await domain.refreshQuota(for: first)

        #expect(await domain.cachedQuota(for: first)?.primary?.usedPercent == 91)
        #expect(await domain.cachedQuota(for: second)?.primary?.usedPercent == secondBefore)
    }

    @Test
    func `same email and different workspaces remain two managed identities`() {
        let first = Self.managedAccount(id: UUID(), workspaceAccountID: "workspace-a")
        let second = Self.managedAccount(id: UUID(), workspaceAccountID: "workspace-b")

        let accounts = ManagedCodexAccountSet(version: 3, accounts: [first, second])

        #expect(accounts.accounts.count == 2)
    }

    @Test
    func `route transaction detects failed readback and restores original bytes`() throws {
        let fixture = try RouteContractFixture()
        defer { fixture.cleanup() }
        let original = Data("model = \"official\"\n".utf8)
        try fixture.write(original, to: fixture.paths.codexConfigURL)
        let fileSystem = CorruptingReadbackFileSystem(corruptURL: fixture.paths.codexConfigURL)
        let transaction = RelayConfigurationTransaction(fileSystem: fileSystem)

        #expect(throws: RelayConfigurationError.self) {
            _ = try transaction.apply(
                profile: fixture.profile,
                paths: fixture.paths,
                credentialStore: fixture.credentials)
        }
        #expect(try Data(contentsOf: fixture.paths.codexConfigURL) == original)
    }

    @Test
    func `selecting a route without applying preserves config modification time and inode`() throws {
        let fixture = try RouteContractFixture()
        defer { fixture.cleanup() }
        let original = Data("model = \"official\"\n".utf8)
        try fixture.write(original, to: fixture.paths.codexConfigURL)
        let pinnedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: pinnedDate],
            ofItemAtPath: fixture.paths.codexConfigURL.path)
        let attributesBefore = try FileManager.default.attributesOfItem(
            atPath: fixture.paths.codexConfigURL.path)
        let inodeBefore = try #require(attributesBefore[.systemFileNumber] as? NSNumber)
        let domain = MemoryRoutesDomain(profiles: [fixture.profile])

        try domain.selectProfile(id: fixture.profile.id)

        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.paths.codexConfigURL.path)
        #expect(attributes[.modificationDate] as? Date == pinnedDate)
        #expect(attributes[.systemFileNumber] as? NSNumber == inodeBefore)
    }

    @Test
    func `fixture reset inventory renders only when credits exist`() async throws {
        let fixture = try UsageBaselineFixture.load()
        let domain = try MemoryAccountsDomain(fixture: fixture)
        let identities = await domain.identities()
        let withCredits = try #require(identities.first)
        let withoutCredits = try #require(identities.dropFirst().first)
        let now = Date(timeIntervalSince1970: 1_781_726_400)
        let firstSnapshot = try #require(await domain.cachedQuota(for: withCredits))
        let secondSnapshot = try #require(await domain.cachedQuota(for: withoutCredits))

        let present = firstSnapshot.codexResetCredits.flatMap {
            CodexResetCreditsPresentation.make(snapshot: $0, resetStyle: .countdown, now: now)
        }
        let absent = secondSnapshot.codexResetCredits.flatMap {
            CodexResetCreditsPresentation.make(snapshot: $0, resetStyle: .countdown, now: now)
        }

        #expect(present?.text == "2 available")
        #expect(present?.items.count == 2)
        #expect(absent == nil)
    }

    @Test
    func `refreshing one account reset inventory leaves the other account unchanged`() async throws {
        let domain = try MemoryAccountsDomain(fixture: .load())
        let identities = await domain.identities()
        let first = try #require(identities.first)
        let second = try #require(identities.dropFirst().first)

        domain.stageResetCredits(count: 1, for: second)
        _ = try await domain.refreshQuota(for: second)

        let firstSnapshot = try #require(await domain.cachedQuota(for: first)?.codexResetCredits)
        let secondSnapshot = try #require(await domain.cachedQuota(for: second)?.codexResetCredits)
        #expect(firstSnapshot.availableInventory(at: firstSnapshot.updatedAt).count == 2)
        #expect(secondSnapshot.availableInventory(at: secondSnapshot.updatedAt).count == 1)
    }

    private static func managedAccount(id: UUID, workspaceAccountID: String) -> ManagedCodexAccount {
        ManagedCodexAccount(
            id: id,
            email: "same@example.com",
            workspaceAccountID: workspaceAccountID,
            managedHomePath: "/tmp/\(id.uuidString)",
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: nil)
    }
}

@MainActor
private final class MemoryAccountsDomain: AccountsDomain {
    private let accountIdentities: [CodexAccountIdentity]
    private var quotas: [CodexAccountIdentity: UsageSnapshot]
    private var stagedRefreshes: [CodexAccountIdentity: UsageSnapshot] = [:]

    init(fixture: UsageBaselineFixture) throws {
        var identities: [CodexAccountIdentity] = []
        var snapshots: [CodexAccountIdentity: UsageSnapshot] = [:]
        for (index, account) in fixture.officialAccounts.enumerated() {
            let identity = try #require(CodexAccountIdentity(
                email: "fixture@example.com",
                workspaceAccountID: "workspace-\(index + 1)"))
            identities.append(identity)
            snapshots[identity] = Self.snapshot(account: account)
        }
        self.accountIdentities = identities
        self.quotas = snapshots
    }

    var visibleAccountProjection: CodexVisibleAccountProjection {
        CodexVisibleAccountProjection(
            visibleAccounts: [],
            activeVisibleAccountID: nil,
            liveVisibleAccountID: nil,
            hasUnreadableAddedAccountStore: false)
    }

    func identities() async -> [CodexAccountIdentity] {
        self.accountIdentities
    }

    func cachedQuota(for identity: CodexAccountIdentity) async -> UsageSnapshot? {
        self.quotas[identity]
    }

    func refreshQuota(for identity: CodexAccountIdentity) async throws -> UsageSnapshot? {
        guard let staged = self.stagedRefreshes.removeValue(forKey: identity) else {
            return self.quotas[identity]
        }
        self.quotas[identity] = staged
        return staged
    }

    func switchAccount(to _: CodexAccountIdentity) async throws {}

    func selectVisibleAccount(id _: String) -> Bool {
        false
    }

    func selectDisplayedAccount(_: CodexVisibleAccount) {}
    func activateAuthenticatedAccount(_: ManagedCodexAccount) {}
    func prepareScopedRefreshIfNeeded() -> Bool {
        false
    }

    func refreshScopedState(
        allowDisabled _: Bool,
        phaseDidChange _: (@MainActor (CodexAccountScopedRefreshPhase) -> Void)?) async
    {}

    func stageRefresh(usedPercent: Double, for identity: CodexAccountIdentity) {
        self.stagedRefreshes[identity] = UsageSnapshot(
            primary: RateWindow(
                usedPercent: usedPercent,
                windowMinutes: 1440,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date(timeIntervalSince1970: 1_781_726_400))
    }

    func stageResetCredits(count: Int, for identity: CodexAccountIdentity) {
        let now = Date(timeIntervalSince1970: 1_781_726_400)
        let resetCredits = CodexRateLimitResetCreditsSnapshot(
            credits: (0..<count).map { index in
                CodexRateLimitResetCredit(
                    id: "staged-\(index)",
                    resetType: "rate_limit",
                    status: .available,
                    grantedAt: now,
                    expiresAt: nil,
                    redeemStartedAt: nil,
                    redeemedAt: nil,
                    title: nil,
                    description: nil)
            },
            availableCount: count,
            updatedAt: now)
        self.stagedRefreshes[identity] = UsageSnapshot(
            primary: self.quotas[identity]?.primary,
            secondary: self.quotas[identity]?.secondary,
            codexResetCredits: resetCredits,
            updatedAt: now)
    }

    private static func snapshot(account: UsageBaselineFixture.OfficialAccount) -> UsageSnapshot {
        let now = Date(timeIntervalSince1970: 1_781_726_400)
        let resetCredits = account.resetCredits.map { reset in
            CodexRateLimitResetCreditsSnapshot(
                credits: (0..<reset.count).map { index in
                    CodexRateLimitResetCredit(
                        id: "\(account.id)-\(index)",
                        resetType: "rate_limit",
                        status: .available,
                        grantedAt: now,
                        expiresAt: reset.expiresAt,
                        redeemStartedAt: nil,
                        redeemedAt: nil,
                        title: nil,
                        description: nil)
                },
                availableCount: reset.count,
                updatedAt: now)
        }
        return UsageSnapshot(
            primary: RateWindow(
                usedPercent: Double(account.localTokens(for: .rolling24Hours) ?? 0),
                windowMinutes: 1440,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            codexResetCredits: resetCredits,
            updatedAt: now)
    }
}

@MainActor
private final class MemoryRoutesDomain: RoutesDomain {
    private let storedProfiles: [RelayProfile]
    private var selection: UUID?

    init(profiles: [RelayProfile]) {
        self.storedProfiles = profiles
    }

    func profiles() -> [RelayProfile] {
        self.storedProfiles
    }

    func selectedProfileID() -> UUID? {
        self.selection
    }

    func selectProfile(id: UUID?) throws {
        if let id, !self.storedProfiles.contains(where: { $0.id == id }) {
            throw RouteContractError.unknownProfile
        }
        self.selection = id
    }

    func apply(_: RelayProfile) throws -> RelaySwitchResult {
        throw RouteContractError.notImplemented
    }

    private enum RouteContractError: Error {
        case unknownProfile
        case notImplemented
    }
}

private struct RouteContractFixture {
    let root: URL
    let paths: RelayConfigurationPaths
    let profile: RelayProfile
    let credentials = RouteContractCredentialStore()

    init() throws {
        self.root = FileManager.default.temporaryDirectory
            .appendingPathComponent("headroom-m3-route-contract-\(UUID().uuidString)", isDirectory: true)
        self.paths = RelayConfigurationPaths(
            codexConfigURL: self.root.appendingPathComponent(".codex/config.toml"),
            claudeCodeSettingsURL: self.root.appendingPathComponent(".claude/settings.json"),
            claudeDesktopNormalConfigURL: self.root.appendingPathComponent("Claude/config.json"),
            claudeDesktopThreePConfigURL: self.root.appendingPathComponent("Claude-3p/config.json"),
            claudeDesktopProfileURL: self.root.appendingPathComponent("Claude-3p/profile.json"),
            claudeDesktopMetaURL: self.root.appendingPathComponent("Claude-3p/meta.json"),
            grokBuildConfigURL: self.root.appendingPathComponent(".grok/config.toml"),
            openCodeConfigURL: self.root.appendingPathComponent("opencode/opencode.jsonc"),
            credentialHelperURL: self.root.appendingPathComponent("CodexBarCLI"),
            backupRootURL: self.root.appendingPathComponent("backups", isDirectory: true))
        self.profile = try RelayProfile(
            name: "Fixture relay",
            baseURL: #require(URL(string: "https://relay.example/v1")),
            apiFormat: .openAIResponses,
            credentialReference: "fixture-reference",
            targets: [.init(app: .codex, model: "gpt-test")])
    }

    func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: self.root)
    }
}

private struct RouteContractCredentialStore: RelayCredentialStoring, RelayCredentialLocating {
    func loadCredential(reference _: String) throws -> String? {
        "fixture-secret"
    }

    func storeCredential(_: String, reference _: String) throws {}
    func removeCredential(reference _: String) throws {}

    func locator(for reference: String) throws -> RelayCredentialLocator {
        RelayCredentialLocator(service: "fixture.relay", account: reference)
    }
}

private final class CorruptingReadbackFileSystem: RelayConfigurationFileSystem, @unchecked Sendable {
    private let base = LocalRelayConfigurationFileSystem()
    private let corruptURL: URL
    private let lock = NSLock()
    private var hasCorrupted = false

    init(corruptURL: URL) {
        self.corruptURL = corruptURL
    }

    func fileExists(at url: URL) -> Bool {
        self.base.fileExists(at: url)
    }

    func readData(at url: URL) throws -> Data {
        try self.base.readData(at: url)
    }

    func createSecureDirectory(at url: URL) throws {
        try self.base.createSecureDirectory(at: url)
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        try self.base.writeAtomically(data, to: url)
        self.lock.lock()
        let shouldCorrupt = url == self.corruptURL && !self.hasCorrupted
        if shouldCorrupt { self.hasCorrupted = true }
        self.lock.unlock()
        if shouldCorrupt {
            try self.base.writeAtomically(Data("corrupt".utf8), to: url)
        }
    }

    func removeItem(at url: URL) throws {
        try self.base.removeItem(at: url)
    }
}
