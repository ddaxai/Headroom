import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
struct CodexMenuCostSnapshotStoreTests {
    @Test
    func `persistent official usage survives restart for the same composite owner`() throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let originalProjection = Self.projection(
            id: "original-card-id",
            email: "Owner@Example.com",
            workspaceAccountID: "Workspace-A")
        let restartedProjection = Self.projection(
            id: "recreated-card-id",
            email: "owner@example.com",
            workspaceAccountID: "workspace-a")
        let snapshot = Self.snapshot()

        FileCodexMenuCostSnapshotStore(fileURL: fixture.fileURL)
            .store(["original-card-id": snapshot], for: originalProjection)

        let restored = FileCodexMenuCostSnapshotStore(fileURL: fixture.fileURL)
            .load(for: restartedProjection)

        #expect(restored == ["recreated-card-id": snapshot])
    }

    @Test
    func `persistent official usage rejects a reused card id from another workspace`() throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let originalProjection = Self.projection(
            id: "reused-card-id",
            email: "owner@example.com",
            workspaceAccountID: "workspace-a")
        let changedProjection = Self.projection(
            id: "reused-card-id",
            email: "owner@example.com",
            workspaceAccountID: "workspace-b")

        FileCodexMenuCostSnapshotStore(fileURL: fixture.fileURL)
            .store(["reused-card-id": Self.snapshot()], for: originalProjection)

        let restored = FileCodexMenuCostSnapshotStore(fileURL: fixture.fileURL)
            .load(for: changedProjection)

        #expect(restored.isEmpty)
    }

    @Test
    func `persistent relay usage survives restart for the same profile`() throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let profileID = try #require(UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        let snapshot = Self.snapshot()

        FileCodexMenuCostSnapshotStore(fileURL: fixture.fileURL)
            .storeRelay([profileID: snapshot])

        let restored = FileCodexMenuCostSnapshotStore(fileURL: fixture.fileURL)
            .loadRelay(profileIDs: [profileID])

        #expect(restored == [profileID: snapshot])
        #expect(FileCodexMenuCostSnapshotStore(fileURL: fixture.fileURL)
            .loadRelay(profileIDs: [UUID()]).isEmpty)
    }

    private func makeFixture() throws -> (directory: URL, fileURL: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("headroom-menu-last-good-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("official-usage.json"))
    }

    private static func projection(
        id: String,
        email: String,
        workspaceAccountID: String) -> CodexVisibleAccountProjection
    {
        let account = CodexVisibleAccount(
            id: id,
            email: email,
            workspaceAccountID: workspaceAccountID,
            storedAccountID: nil,
            selectionSource: .liveSystem,
            isActive: true,
            isLive: true,
            canReauthenticate: true,
            canRemove: false)
        return CodexVisibleAccountProjection(
            visibleAccounts: [account],
            activeVisibleAccountID: id,
            liveVisibleAccountID: id,
            hasUnreadableAddedAccountStore: false)
    }

    private static func snapshot() -> CostUsageTokenSnapshot {
        let updatedAt = Date(timeIntervalSince1970: 1_788_000_000)
        let providerBreakdown = CostUsageModelProviderBreakdown(
            modelProvider: "openai",
            totalTokens: 1234,
            costUSD: 0.42)
        let modelBreakdown = CostUsageDailyReport.ModelBreakdown(
            modelName: "gpt-5",
            costUSD: 0.42,
            totalTokens: 1234,
            requestCount: 3)
        return CostUsageTokenSnapshot(
            sessionTokens: 1234,
            sessionCostUSD: 0.42,
            sessionRequests: 3,
            last30DaysTokens: 1234,
            last30DaysCostUSD: 0.42,
            last30DaysRequests: 3,
            rolling24Hours: CostUsageRolling24HourSummary(
                totalTokens: 1234,
                costUSD: 0.42,
                modelProviderBreakdowns: [providerBreakdown]),
            hourly24Hours: [CostUsageHourlyEntry(
                startDate: updatedAt.addingTimeInterval(-3600),
                totalTokens: 1234,
                costUSD: 0.42,
                modelProviderBreakdowns: [providerBreakdown])],
            historyDays: 30,
            codexCorpusRevision: "corpus-revision",
            codexCorpusCoverageIsComplete: true,
            daily: [CostUsageDailyReport.Entry(
                date: "2026-08-19",
                inputTokens: 1000,
                outputTokens: 234,
                totalTokens: 1234,
                requestCount: 3,
                costUSD: 0.42,
                modelsUsed: ["gpt-5"],
                modelBreakdowns: [modelBreakdown])],
            updatedAt: updatedAt)
    }
}
