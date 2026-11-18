import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct UsageIdentityTests {
    @Test
    func `identity keys classify subscription relay and direct API without secrets`() throws {
        let managedID = try #require(UUID(uuidString: "7E8E7B30-ED13-4FE2-8DF7-3B4DBA5F1F4B"))
        let relay = UsageIdentity.relayAPI(
            provider: .codex,
            profileID: managedID,
            target: "codex",
            displayLabel: "Relay")
        let direct = UsageIdentity.directAPI(
            provider: .opencode,
            tokenAccountID: managedID,
            displayLabel: "OpenCode API",
            authFingerprint: "fingerprint")
        let subscription = UsageIdentity.subscription(
            provider: .codex,
            accountKey: "live:workspace-123",
            displayLabel: "user@example.com",
            authFingerprint: "auth-fingerprint",
            localHomePath: "/Users/test/.codex")

        #expect(relay.kind == .relayAPI)
        #expect(relay.accountKey == "relay:\(managedID.uuidString.lowercased()):codex")
        #expect(direct.kind == .directAPI)
        #expect(direct.accountKey == "api:opencode:\(managedID.uuidString.lowercased())")
        #expect(subscription.kind == .subscription)
        #expect(subscription.accountKey == "codex:live:workspace-123")
        #expect(!relay.accountKey.contains("fingerprint"))
        #expect(!direct.accountKey.contains("secret"))
    }

    @Test
    func `fingerprint includes usage identity`() {
        let usage = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: 1,
            size: 2,
            days: ["2026-08-08": ["gpt-5": [10, 0, 5]]],
            parsedBytes: 2,
            sessionId: "session")
        let first = CodexWorkspaceUsageFingerprint.make(
            for: usage,
            identity: UsageIdentity.subscription(
                provider: .codex,
                accountKey: "live:first",
                displayLabel: "First"))
        let second = CodexWorkspaceUsageFingerprint.make(
            for: usage,
            identity: UsageIdentity.subscription(
                provider: .codex,
                accountKey: "live:second",
                displayLabel: "Second"))

        #expect(first != second)
    }

    @Test
    func `explicit account home remains scoped when it does not exist`() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("headroom-missing-account-\(UUID().uuidString)")
        let scope = CodexLocalDataScope.resolve(options: CostUsageScanner.Options(
            codexSessionsRoot: home.appendingPathComponent("sessions", isDirectory: true)))

        #expect(scope.codexHome.path == home.standardizedFileURL.path)
        #expect(scope.sessionsRoot.path.hasPrefix(home.standardizedFileURL.path))
        #expect(scope.identifier.contains(home.path) == false)
    }

    @Test
    func `sidecar scope includes scanner version and account identity`() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("headroom-shared-home", isDirectory: true)
        var first = CostUsageScanner.Options(
            codexSessionsRoot: root.appendingPathComponent("sessions", isDirectory: true))
        first.usageIdentity = UsageIdentity.subscription(
            provider: .codex,
            accountKey: "live:first",
            displayLabel: "First",
            authFingerprint: "auth-1",
            localHomePath: root.path)
        var second = first
        second.usageIdentity = UsageIdentity.subscription(
            provider: .codex,
            accountKey: "live:second",
            displayLabel: "Second",
            authFingerprint: "auth-2",
            localHomePath: root.path)

        let firstScope = CodexLocalProjectUsageIndexer.stableScopeSignature(options: first)
        let secondScope = CodexLocalProjectUsageIndexer.stableScopeSignature(options: second)

        #expect(firstScope != secondScope)
        #expect(firstScope.contains("scannerVersion=\(CodexLocalProjectUsageIndexer.scannerVersion)"))
        #expect(firstScope.contains("accountKey=codex:live:first"))
    }

    @Test
    func `scanner version change invalidates the previous sidecar scope`() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("headroom-scanner-version-home", isDirectory: true)
        let options = CostUsageScanner.Options(
            codexSessionsRoot: root.appendingPathComponent("sessions", isDirectory: true))

        let previous = CodexLocalProjectUsageIndexer.stableScopeSignature(
            options: options,
            scannerVersion: CodexLocalProjectUsageIndexer.scannerVersion - 1)
        let current = CodexLocalProjectUsageIndexer.stableScopeSignature(
            options: options,
            scannerVersion: CodexLocalProjectUsageIndexer.scannerVersion)

        #expect(previous != current)
        #expect(previous.contains("scannerVersion=\(CodexLocalProjectUsageIndexer.scannerVersion - 1)"))
        #expect(current.contains("scannerVersion=\(CodexLocalProjectUsageIndexer.scannerVersion)"))
    }

    @Test
    func `unattributed and conflicting homes stay in the system unassigned bucket`() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("headroom-unassigned-home", isDirectory: true)
        let first = UsageIdentity.subscription(
            provider: .codex,
            accountKey: "managed:first",
            displayLabel: "First",
            localHomePath: root.path)
        let second = UsageIdentity.subscription(
            provider: .codex,
            accountKey: "managed:second",
            displayLabel: "Second",
            localHomePath: root.path)

        let plan = AccountSessionAttributionPlan.make(sources: [
            AccountSessionSource(codexHome: root, attribution: .unassigned),
            AccountSessionSource(codexHome: root, attribution: .assigned(first)),
            AccountSessionSource(codexHome: root, attribution: .assigned(second)),
        ])

        #expect(plan.sources.count == 1)
        #expect(plan.sources.first?.attribution == .unassigned)
        #expect(plan.sources.first?.accountKey == UsageIdentity.systemUnassignedAccountKey)
        #expect(plan.sources.contains { $0.accountKey == first.accountKey } == false)
        #expect(plan.sources.contains { $0.accountKey == second.accountKey } == false)
    }

    @Test
    func `independent account homes remain assigned to their named identities`() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("headroom-assigned-homes", isDirectory: true)
        let firstHome = root.appendingPathComponent("first", isDirectory: true)
        let secondHome = root.appendingPathComponent("second", isDirectory: true)
        let first = UsageIdentity.subscription(
            provider: .codex,
            accountKey: "managed:first",
            displayLabel: "First",
            localHomePath: firstHome.path)
        let second = UsageIdentity.subscription(
            provider: .codex,
            accountKey: "managed:second",
            displayLabel: "Second",
            localHomePath: secondHome.path)

        let plan = AccountSessionAttributionPlan.make(sources: [
            AccountSessionSource(codexHome: firstHome, attribution: .assigned(first)),
            AccountSessionSource(codexHome: secondHome, attribution: .assigned(second)),
        ])

        #expect(plan.sources.map(\.accountKey).sorted() == [first.accountKey, second.accountKey].sorted())
        #expect(plan.sources.allSatisfy { $0.attribution != .unassigned })
    }

    @Test
    func `ambient current scope is never attributed to the active account`() {
        let account = CodexVisibleAccount(
            id: "managed", email: "managed@example.com", storedAccountID: UUID(),
            selectionSource: .managedAccount(id: UUID()), isActive: true, isLive: false,
            canReauthenticate: true, canRemove: true)

        let ambient = UsageIdentity.codexCurrentScope(activeAccount: account, localHomePath: nil)
        let isolated = UsageIdentity.codexCurrentScope(activeAccount: account, localHomePath: "/tmp/managed-home")

        #expect(ambient?.isSystemUnassigned == true)
        #expect(isolated?.accountKey != UsageIdentity.systemUnassignedAccountKey)
    }
}
