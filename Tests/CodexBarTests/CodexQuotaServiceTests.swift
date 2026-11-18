import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct CodexQuotaServiceTests {
    @Test
    func `targeted refresh keeps same-email workspace quotas isolated`() async throws {
        let service = CodexQuotaService(snapshotStore: nil)
        let first = Self.account(workspaceAccountID: "workspace-a", isActive: true)
        let second = Self.account(workspaceAccountID: "workspace-b", isActive: false)
        let firstIdentity = try #require(CodexAccountIdentity(
            email: first.email,
            workspaceAccountID: first.workspaceAccountID))
        let secondIdentity = try #require(CodexAccountIdentity(
            email: second.email,
            workspaceAccountID: second.workspaceAccountID))
        service.publish([
            Self.record(account: first, usedPercent: 10),
            Self.record(account: second, usedPercent: 20),
        ])

        let refreshed = await service.refreshQuota(for: first) {
            Self.snapshot(usedPercent: 90)
        }

        #expect(refreshed?.primary?.usedPercent == 90)
        #expect(service.cachedQuota(for: firstIdentity)?.primary?.usedPercent == 90)
        #expect(service.cachedQuota(for: secondIdentity)?.primary?.usedPercent == 20)
    }

    @Test
    func `inactive account keeps local and last-good quota after refresh failure`() async throws {
        let service = CodexQuotaService(snapshotStore: nil)
        let inactive = Self.account(workspaceAccountID: "workspace-inactive", isActive: false)
        let identity = try #require(CodexAccountIdentity(
            email: inactive.email,
            workspaceAccountID: inactive.workspaceAccountID))
        service.publish([Self.record(account: inactive, usedPercent: 42)])

        let quota = await service.refreshQuota(for: inactive) {
            throw QuotaTestError.fetchFailed
        }

        #expect(!inactive.isActive)
        #expect(inactive.codexHomePath == "/tmp/workspace-inactive")
        #expect(quota?.primary?.usedPercent == 42)
        #expect(service.cachedQuota(for: identity)?.primary?.usedPercent == 42)
    }

    private static func account(workspaceAccountID: String, isActive: Bool) -> CodexVisibleAccount {
        CodexVisibleAccount(
            id: workspaceAccountID,
            email: "same@example.com",
            workspaceAccountID: workspaceAccountID,
            storedAccountID: UUID(),
            selectionSource: .liveSystem,
            isActive: isActive,
            isLive: isActive,
            canReauthenticate: true,
            canRemove: true,
            codexHomePath: "/tmp/\(workspaceAccountID)")
    }

    private static func record(account: CodexVisibleAccount, usedPercent: Double) -> CodexAccountUsageSnapshot {
        CodexAccountUsageSnapshot(
            account: account,
            snapshot: self.snapshot(usedPercent: usedPercent),
            error: nil,
            sourceLabel: "fixture")
    }

    private static func snapshot(usedPercent: Double) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: usedPercent,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date(timeIntervalSince1970: 1_781_726_400))
    }

    private enum QuotaTestError: Error {
        case fetchFailed
    }
}
