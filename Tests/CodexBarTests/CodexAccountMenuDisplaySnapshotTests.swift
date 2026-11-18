import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct CodexAccountMenuDisplaySnapshotTests {
    @Test
    func `menu cache plan keeps ambient history out of a named live account`() {
        let snapshot = self.liveSnapshot(email: "ambient@example.com")
        let projection = CodexVisibleAccountProjection.make(from: snapshot)

        let requests = SpendDashboardSource.cachedCodexRequests(
            projection: projection,
            providerName: "Codex",
            ownershipTimeline: CodexSessionOwnershipTimeline())

        #expect(requests.count == 1)
        #expect(requests.first?.usageIdentity.isSystemUnassigned == true)
        #expect(requests.first?.id.hasPrefix("system-unassigned:") == true)
    }

    @Test
    func `menu cache plan adds a live official target after explicit attribution`() throws {
        let snapshot = self.liveSnapshot(email: "attributed@example.com")
        let projection = CodexVisibleAccountProjection.make(from: snapshot)
        let account = try #require(projection.visibleAccounts.first)
        let accountKey = UsageIdentity.subscription(account: account).accountKey
        var timeline = CodexSessionOwnershipTimeline()
        _ = try timeline.recordManualAttribution(
            accountKey: accountKey,
            startUnixMilliseconds: nil,
            endUnixMillisecondsExclusive: nil,
            createdAtUnixMilliseconds: 1)

        let requests = SpendDashboardSource.cachedCodexRequests(
            projection: projection,
            providerName: "Codex",
            ownershipTimeline: timeline)

        #expect(requests.count == 2)
        #expect(requests.contains { $0.usageIdentity.isSystemUnassigned })
        let official = try #require(requests.first { !$0.usageIdentity.isSystemUnassigned })
        #expect(official.usageIdentity.accountKey == accountKey)
        #expect(official.scansSharedHomeOnly)
        #expect(official.sharedHomePath == account.codexHomePath)
    }

    @Test
    func `matched live and stored account share dashboard and menu cache identity`() throws {
        let storedID = UUID()
        let account = CodexVisibleAccount(
            id: "matched@example.com",
            email: "matched@example.com",
            workspaceAccountID: "workspace-matched",
            authFingerprint: "stable-auth-fingerprint",
            storedAccountID: storedID,
            selectionSource: .liveSystem,
            isActive: true,
            isLive: true,
            canReauthenticate: true,
            canRemove: true,
            codexHomePath: "/tmp/live-matched",
            managedCodexHomePath: "/tmp/managed-matched")

        let dashboard = try #require(SpendDashboardSource.codexRequest(
            account: account,
            homePath: "/tmp/managed-matched",
            providerName: "Codex",
            index: 0,
            count: 1,
            sourceOverride: .managedAccount(id: storedID),
            readCurrentAuthFingerprint: false,
            homeReadabilityOverride: true))
        let menu = try #require(SpendDashboardSource.codexRequest(
            account: account,
            homePath: "/tmp/managed-matched",
            providerName: "Codex",
            index: 0,
            count: 1,
            sourceOverride: .liveSystem,
            readCurrentAuthFingerprint: false,
            homeReadabilityOverride: true))

        #expect(menu.source == .managedAccount(id: storedID))
        #expect(menu.cacheIdentity == dashboard.cacheIdentity)
        #expect(menu.usageIdentity == dashboard.usageIdentity)
        #expect(menu.usageIdentity.accountKey == "codex:managed:\(storedID.uuidString.lowercased())")
    }

    @Test
    func `identity generation change discards in flight cached result`() {
        let before = CodexVisibleAccountProjection(
            visibleAccounts: [self.visibleAccount(email: "before@example.com")],
            activeVisibleAccountID: "before@example.com",
            liveVisibleAccountID: "before@example.com",
            hasUnreadableAddedAccountStore: false)
        let after = CodexVisibleAccountProjection(
            visibleAccounts: [self.visibleAccount(email: "after@example.com")],
            activeVisibleAccountID: "after@example.com",
            liveVisibleAccountID: "after@example.com",
            hasUnreadableAddedAccountStore: false)
        let plan = CodexMenuSpendPlan(
            generation: 3,
            projectionSignature: CodexMenuSpendPlan.projectionSignature(before),
            requests: [])

        #expect(plan.isCurrent(generation: 3, projection: before))
        #expect(!plan.isCurrent(generation: 4, projection: after))
    }

    private func makeSettings() -> SettingsStore {
        let suite = "CodexAccountMenuDisplaySnapshotTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: "providerDetectionCompleted")
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.providerDetectionCompleted = true
        return settings
    }

    private func enableOnlyCodex(_ settings: SettingsStore) {
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .codex)
        }
    }

    private func liveSnapshot(email: String) -> CodexAccountReconciliationSnapshot {
        CodexAccountReconciliationSnapshot(
            storedAccounts: [],
            activeStoredAccount: nil,
            liveSystemAccount: ObservedSystemCodexAccount(
                email: email,
                codexHomePath: "/tmp/\(email)",
                observedAt: Date()),
            matchingStoredAccountForLiveSystemAccount: nil,
            activeSource: .liveSystem,
            hasUnreadableAddedAccountStore: false)
    }

    private func visibleAccount(email: String) -> CodexVisibleAccount {
        CodexVisibleAccount(
            id: email,
            email: email,
            storedAccountID: nil,
            selectionSource: .liveSystem,
            isActive: true,
            isLive: true,
            canReauthenticate: true,
            canRemove: false,
            codexHomePath: "/tmp/\(email)")
    }

    private func cachedProjection(
        snapshot: CodexAccountReconciliationSnapshot,
        loadedAt: Date = Date(timeIntervalSinceNow: -3600)) -> CachedCodexAccountMenuProjection
    {
        CachedCodexAccountMenuProjection(
            activeSource: snapshot.activeSource,
            loadedAt: loadedAt,
            projection: CodexVisibleAccountProjection.make(from: snapshot))
    }

    @Test
    func `cold menu projection read never loads auth state`() async {
        let settings = self.makeSettings()
        let probe = CodexAccountSnapshotLoaderProbe(snapshot: self.liveSnapshot(email: "loaded@example.com"))
        settings._test_codexAccountSnapshotLoader = { _ in probe.load() }
        defer { settings._test_codexAccountSnapshotLoader = nil }

        #expect(settings.codexVisibleAccountProjectionForMenuDisplay == nil)
        #expect(probe.callCount == 0)

        let result = await settings.revalidateCodexAccountMenuProjection()

        #expect(result == .updated)
        #expect(probe.callCount == 1)
        #expect(probe.loadedOffMainThread)
        #expect(
            settings.codexVisibleAccountProjectionForMenuDisplay?.visibleAccounts.first?.email ==
                "loaded@example.com")
    }

    @Test
    func `override snapshot load preserves persisted account menu projection`() {
        let settings = self.makeSettings()
        let activeSnapshot = self.liveSnapshot(email: "active@example.com")
        settings.cachedCodexAccountMenuProjection = self.cachedProjection(snapshot: activeSnapshot)

        let otherID = UUID()
        let otherAccount = ManagedCodexAccount(
            id: otherID,
            email: "other@example.com",
            managedHomePath: "/tmp/other",
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        let overrideSnapshot = CodexAccountReconciliationSnapshot(
            storedAccounts: [otherAccount],
            activeStoredAccount: otherAccount,
            liveSystemAccount: nil,
            matchingStoredAccountForLiveSystemAccount: nil,
            activeSource: .managedAccount(id: otherID),
            hasUnreadableAddedAccountStore: false)
        settings._test_codexAccountSnapshotLoader = { _ in overrideSnapshot }
        defer { settings._test_codexAccountSnapshotLoader = nil }

        _ = settings.codexAccountReconciliationSnapshot(activeSourceOverride: .managedAccount(id: otherID))

        #expect(
            settings.codexVisibleAccountProjectionForMenuDisplay?.visibleAccounts.first?.email ==
                "active@example.com")
    }

    @Test
    func `changing codex quota usage source preserves cached account menu projection`() {
        let settings = self.makeSettings()
        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: "/tmp/managed",
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        let snapshot = CodexAccountReconciliationSnapshot(
            storedAccounts: [managedAccount],
            activeStoredAccount: nil,
            liveSystemAccount: ObservedSystemCodexAccount(
                email: "live@example.com",
                codexHomePath: "/tmp/live",
                observedAt: Date()),
            matchingStoredAccountForLiveSystemAccount: nil,
            activeSource: .liveSystem,
            hasUnreadableAddedAccountStore: false)
        settings.cachedCodexAccountMenuProjection = self.cachedProjection(snapshot: snapshot, loadedAt: Date())

        settings.codexUsageDataSource = .oauth

        #expect(settings.codexUsageDataSource == .oauth)
        #expect(
            settings.codexVisibleAccountProjectionForMenuDisplay?.visibleAccounts.map(\.email).sorted() == [
                "live@example.com",
                "managed@example.com",
            ])
    }

    @Test
    func `managed account change refreshes account menu projection`() {
        let settings = self.makeSettings()
        let activeSnapshot = self.liveSnapshot(email: "active@example.com")
        settings.cachedCodexAccountMenuProjection = self.cachedProjection(snapshot: activeSnapshot, loadedAt: Date())

        let addedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "added@example.com",
            managedHomePath: "/tmp/added",
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        let refreshedSnapshot = CodexAccountReconciliationSnapshot(
            storedAccounts: [addedAccount],
            activeStoredAccount: nil,
            liveSystemAccount: activeSnapshot.liveSystemAccount,
            matchingStoredAccountForLiveSystemAccount: nil,
            activeSource: .liveSystem,
            hasUnreadableAddedAccountStore: false)
        settings._test_codexAccountSnapshotLoader = { _ in refreshedSnapshot }
        defer { settings._test_codexAccountSnapshotLoader = nil }

        settings.refreshCodexAccountReconciliationAfterManagedAccountsDidChange()

        #expect(
            settings.codexVisibleAccountProjectionForMenuDisplay?.visibleAccounts.contains {
                $0.email == "added@example.com"
            } == true)
    }

    @Test
    func `stacked menu matches runtime enriched snapshot for legacy managed workspace`() throws {
        let settings = self.makeSettings()
        self.enableOnlyCodex(settings)
        settings.multiAccountMenuLayout = .stacked
        let legacyID = UUID()
        let siblingID = UUID()
        let legacy = ManagedCodexAccount(
            id: legacyID,
            email: "legacy@example.com",
            workspaceAccountID: nil,
            managedHomePath: "/tmp/legacy",
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        let sibling = ManagedCodexAccount(
            id: siblingID,
            email: "sibling@example.com",
            workspaceAccountID: "account-sibling",
            managedHomePath: "/tmp/sibling",
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        let snapshot = CodexAccountReconciliationSnapshot(
            storedAccounts: [legacy, sibling],
            activeStoredAccount: legacy,
            liveSystemAccount: nil,
            matchingStoredAccountForLiveSystemAccount: nil,
            activeSource: .managedAccount(id: legacyID),
            hasUnreadableAddedAccountStore: false,
            storedAccountRuntimeIdentities: [
                legacyID: .providerAccount(id: " Account-Runtime "),
                siblingID: .providerAccount(id: "account-sibling"),
            ])
        let projection = CodexVisibleAccountProjection.make(from: snapshot)
        let legacyProjected = try #require(projection.visibleAccounts.first {
            $0.selectionSource == .managedAccount(id: legacyID)
        })
        let siblingProjected = try #require(projection.visibleAccounts.first {
            $0.selectionSource == .managedAccount(id: siblingID)
        })
        let runtimeEnrichedLegacy = CodexVisibleAccount(
            id: legacyProjected.id,
            email: legacyProjected.email,
            workspaceLabel: legacyProjected.workspaceLabel,
            workspaceAccountID: "account-runtime",
            authFingerprint: legacyProjected.authFingerprint,
            storedAccountID: legacyProjected.storedAccountID,
            selectionSource: legacyProjected.selectionSource,
            isActive: legacyProjected.isActive,
            isLive: legacyProjected.isLive,
            canReauthenticate: legacyProjected.canReauthenticate,
            canRemove: legacyProjected.canRemove)

        settings.codexActiveSource = .managedAccount(id: legacyID)
        settings.cachedCodexAccountMenuProjection = self.cachedProjection(snapshot: snapshot, loadedAt: Date())
        settings._test_codexAccountSnapshotLoader = { _ in snapshot }
        defer { settings._test_codexAccountSnapshotLoader = nil }
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system,
            menuCardRenderingEnabled: false,
            menuRefreshEnabled: false)
        defer { controller.releaseStatusItemsForTesting() }
        store.codexAccountSnapshots = [runtimeEnrichedLegacy, siblingProjected].map {
            CodexAccountUsageSnapshot(account: $0, snapshot: nil, error: nil, sourceLabel: "test")
        }

        let display = try #require(controller.codexAccountMenuDisplay(for: .codex))

        #expect(legacyProjected.workspaceAccountID == "account-runtime")
        #expect(display.snapshots.map(\.id).sorted() == [legacyProjected.id, siblingProjected.id].sorted())
    }

    @Test
    func `stale menu projection returns immediately then refreshes concurrently`() async {
        let settings = self.makeSettings()
        let staleSnapshot = self.liveSnapshot(email: "before@example.com")
        let probe = CodexAccountSnapshotLoaderProbe(snapshot: self.liveSnapshot(email: "after@example.com"))
        settings.cachedCodexAccountMenuProjection = self.cachedProjection(snapshot: staleSnapshot)
        settings._test_codexAccountSnapshotLoader = { _ in probe.load() }
        SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = 60
        defer {
            SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = nil
            settings._test_codexAccountSnapshotLoader = nil
        }

        #expect(
            settings.codexVisibleAccountProjectionForMenuDisplay?.visibleAccounts.first?.email ==
                "before@example.com")
        #expect(probe.callCount == 0)
        #expect(settings.codexAccountMenuProjectionNeedsRevalidation)

        let result = await settings.revalidateCodexAccountMenuProjection()

        #expect(result == .updated)
        #expect(probe.callCount == 1)
        #expect(probe.loadedOffMainThread)
        #expect(
            settings.codexVisibleAccountProjectionForMenuDisplay?.visibleAccounts.first?.email ==
                "after@example.com")
    }

    @Test
    func `revalidation discards result after reconciliation generation changes`() async {
        let settings = self.makeSettings()
        let staleSnapshot = self.liveSnapshot(email: "before@example.com")
        let probe = CodexAccountSnapshotLoaderProbe(
            snapshot: self.liveSnapshot(email: "discarded@example.com"),
            blocks: true)
        settings.cachedCodexAccountMenuProjection = self.cachedProjection(snapshot: staleSnapshot)
        settings._test_codexAccountSnapshotLoader = { _ in probe.load() }
        SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = 60
        defer {
            probe.release()
            SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = nil
            settings._test_codexAccountSnapshotLoader = nil
        }

        let task = Task { await settings.revalidateCodexAccountMenuProjection() }
        await probe.waitUntilCalled()
        settings.invalidateCodexAccountReconciliationSnapshotCache()
        probe.release()

        #expect(await task.value == .discarded)
        #expect(
            settings.codexVisibleAccountProjectionForMenuDisplay?.visibleAccounts.first?.email ==
                "before@example.com")
    }

    @Test
    func `fresh menu open coalesces account projection revalidation and identity stays read only`() async throws {
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        StatusItemController.setCodexAccountMenuProjectionRevalidationEnabledForTesting(true)
        defer {
            StatusItemController.resetCodexAccountMenuProjectionRevalidationEnabledForTesting()
            StatusItemController.resetMenuRefreshEnabledForTesting()
        }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        self.enableOnlyCodex(settings)
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        store._cancelPlanUtilizationHistoryLoadForTesting()
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }

        let staleSnapshot = self.liveSnapshot(email: "before@example.com")
        let probe = CodexAccountSnapshotLoaderProbe(
            snapshot: self.liveSnapshot(email: "after@example.com"),
            blocks: true)
        settings.cachedCodexAccountMenuProjection = self.cachedProjection(snapshot: staleSnapshot)
        settings._test_codexAccountSnapshotLoader = { _ in probe.load() }
        SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = 60
        defer {
            probe.release()
            SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = nil
            settings._test_codexAccountSnapshotLoader = nil
        }

        let menu = NSMenu()
        controller.menuProviders[ObjectIdentifier(menu)] = .codex
        controller.markMenuFresh(menu)
        // Ambient history must take the per-source card path even with only
        // one visible live account, so it can be rendered separately as
        // System / Unassigned rather than inherited by that account.
        #expect(controller.codexAccountMenuDisplay(for: .codex)?.layout == .stacked)
        #expect(probe.callCount == 0)

        let versionBeforeOpen = controller.menuContentVersion
        controller.menuWillOpen(menu)
        let revalidation = try #require(controller.codexAccountMenuProjectionRevalidationTask)
        controller.menuWillOpen(menu)
        await probe.waitUntilCalled()

        #expect(probe.callCount == 1)
        #expect(probe.loadedOffMainThread)
        probe.release()
        await revalidation.value

        #expect(controller.codexAccountMenuProjectionRevalidationTask == nil)
        #expect(controller.menuContentVersion == versionBeforeOpen + 1)
    }

    @Test
    func `selecting displayed account uses captured source without reconciliation`() throws {
        let settings = self.makeSettings()
        let firstID = UUID()
        let secondID = UUID()
        let first = ManagedCodexAccount(
            id: firstID,
            email: "first@example.com",
            managedHomePath: "/tmp/first",
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        let second = ManagedCodexAccount(
            id: secondID,
            email: "second@example.com",
            managedHomePath: "/tmp/second",
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        let snapshot = CodexAccountReconciliationSnapshot(
            storedAccounts: [first, second],
            activeStoredAccount: first,
            liveSystemAccount: nil,
            matchingStoredAccountForLiveSystemAccount: nil,
            activeSource: .managedAccount(id: firstID),
            hasUnreadableAddedAccountStore: false)
        let projection = CodexVisibleAccountProjection.make(from: snapshot)
        let displayedAccount = try #require(projection.visibleAccounts.first {
            $0.selectionSource == .managedAccount(id: secondID)
        })
        let probe = CodexAccountSnapshotLoaderProbe(snapshot: snapshot)
        settings.cachedCodexAccountMenuProjection = self.cachedProjection(snapshot: snapshot)
        settings._test_codexAccountSnapshotLoader = { _ in probe.load() }
        defer { settings._test_codexAccountSnapshotLoader = nil }

        settings.selectDisplayedCodexVisibleAccount(displayedAccount)

        #expect(probe.callCount == 0)
        #expect(settings.codexActiveSource == .managedAccount(id: secondID))
        #expect(settings.cachedCodexAccountMenuProjection == nil)
    }
}

private final class CodexAccountSnapshotLoaderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let snapshot: CodexAccountReconciliationSnapshot
    private let blocks: Bool
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var _callCount = 0
    private var _loadedOffMainThread = false
    private var released = false

    init(snapshot: CodexAccountReconciliationSnapshot, blocks: Bool = false) {
        self.snapshot = snapshot
        self.blocks = blocks
    }

    var callCount: Int {
        self.lock.withLock { self._callCount }
    }

    var loadedOffMainThread: Bool {
        self.lock.withLock { self._loadedOffMainThread }
    }

    func load() -> CodexAccountReconciliationSnapshot {
        self.lock.withLock {
            self._callCount += 1
            self._loadedOffMainThread = self._loadedOffMainThread || !Thread.isMainThread
        }
        if self.blocks {
            self.releaseSemaphore.wait()
        }
        return self.snapshot
    }

    func waitUntilCalled() async {
        while self.callCount == 0 {
            await Task.yield()
        }
    }

    func release() {
        let shouldSignal = self.lock.withLock {
            guard !self.released else { return false }
            self.released = true
            return true
        }
        if shouldSignal {
            self.releaseSemaphore.signal()
        }
    }
}
