import CodexBarCore
import Foundation
import Observation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct EighthRoundR1SpendTests {
    @Test
    func `manual attribution target resolution follows candidate changes`() {
        #expect(resolvedManualAttributionTargetKey(current: "", candidates: ["first", "second"]) == "first")
        #expect(resolvedManualAttributionTargetKey(current: "second", candidates: ["first", "second"])
            == "second")
        #expect(resolvedManualAttributionTargetKey(current: "stale", candidates: ["first", "second"])
            == "first")
        #expect(resolvedManualAttributionTargetKey(current: "stale", candidates: []).isEmpty)
        let defaultTarget = resolvedManualAttributionTargetKey(current: "", candidates: ["first", "second"])
        #expect(isValidManualAttributionTargetKey(defaultTarget, candidates: ["first", "second"]))
        #expect(isValidManualAttributionTargetKey("second", candidates: ["first", "second"]))
        #expect(!isValidManualAttributionTargetKey("stale", candidates: ["first", "second"]))
    }

    @Test
    func `manual attribution observes account reconciliation changes`() throws {
        let suite = "EighthRoundR1SpendTests-observation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        let observation = EighthRoundObservationFlag()
        withObservationTracking {
            _ = settings.codexAccountReconciliationGeneration
        } onChange: {
            observation.markChanged()
        }

        settings.invalidateCodexAccountReconciliationSnapshotCache()

        #expect(observation.didChange)
    }

    @Test
    func `menu spend plan finds shared corpus home without an unassigned request`() {
        let sharedHome = "/tmp/headroom-shared-corpus"
        let request = CodexSpendScanRequest(
            id: "account",
            displayName: "Account",
            source: .profileHome(path: "/tmp/headroom-account"),
            homePath: "/tmp/headroom-account",
            authFingerprint: nil,
            authFileWasReadable: false,
            cacheIdentity: "account-cache",
            usageIdentity: UsageIdentity(
                kind: .subscription,
                provider: .codex,
                accountKey: "codex:account",
                displayLabel: "Account",
                localHomePath: "/tmp/headroom-account"),
            sharedHomePath: sharedHome,
            sessionOwnershipTimeline: CodexSessionOwnershipTimeline())
        let plan = CodexMenuSpendPlan(
            generation: 1,
            projectionSignature: "projection",
            requests: [request])

        #expect(plan.sharedCorpusHomePath == sharedHome)
    }

    @Test
    func `menu spend plan rejects snapshots computed from a stale ownership revision`() {
        var originalTimeline = CodexSessionOwnershipTimeline()
        _ = originalTimeline.recordActivation(
            accountKey: "codex:managed:original",
            atUnixMilliseconds: 1000)
        let request = CodexSpendScanRequest(
            id: "account",
            displayName: "Account",
            source: .profileHome(path: "/tmp/headroom-account"),
            homePath: "/tmp/headroom-account",
            authFingerprint: nil,
            authFileWasReadable: false,
            cacheIdentity: "account-cache",
            usageIdentity: UsageIdentity(
                kind: .subscription,
                provider: .codex,
                accountKey: "codex:managed:original",
                displayLabel: "Account",
                localHomePath: "/tmp/headroom-account"),
            sharedHomePath: "/tmp/headroom-shared-corpus",
            sessionOwnershipTimeline: originalTimeline)
        let plan = CodexMenuSpendPlan(
            generation: 1,
            projectionSignature: "projection",
            requests: [request])
        var changedTimeline = originalTimeline
        _ = changedTimeline.recordActivation(
            accountKey: "codex:managed:changed",
            atUnixMilliseconds: 2000)

        #expect(plan.ownershipRevision == originalTimeline.revision)
        #expect(plan.hasCurrentOwnershipRevision(originalTimeline.revision))
        #expect(!plan.hasCurrentOwnershipRevision(changedTimeline.revision))
    }

    @Test
    func `launch bootstrap seeds one assumed boundary for the reconciled live account`() throws {
        let suite = "EighthRoundR1SpendTests-bootstrap-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        let accountID = UUID()
        let managed = ManagedCodexAccount(
            id: accountID,
            email: "owner@example.com",
            managedHomePath: "/tmp/headroom-bootstrap-managed",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 3)
        settings._test_activeManagedCodexAccount = managed
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: managed.email,
            codexHomePath: "/tmp/headroom-bootstrap-live",
            observedAt: Date(timeIntervalSince1970: 10))
        settings.codexActiveSource = .liveSystem
        defer {
            settings._test_activeManagedCodexAccount = nil
            settings._test_liveSystemCodexAccount = nil
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("headroom-bootstrap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileCodexSessionOwnershipTimelineStore(fileURL: root.appendingPathComponent("timeline.json"))
        let now = Date(timeIntervalSince1970: 20)

        #expect(CodexSessionOwnershipBootstrap.seedAtLaunch(settings: settings, store: store, at: now))
        #expect(!CodexSessionOwnershipBootstrap.seedAtLaunch(settings: settings, store: store, at: now))
        let timeline = try store.load()
        #expect(timeline.events.count == 1)
        #expect(timeline.events.first?.accountKey == CodexSessionOwnershipTimeline.managedAccountKey(id: accountID))
        #expect(timeline.events.first?.confidence == .assumed)
    }

    @Test
    func `each unassigned home keeps a stable distinct scan source`() {
        let first = SpendDashboardSource.systemUnassignedRequest(
            homePath: "/tmp/headroom-unassigned-a", providerName: "Codex")
        let second = SpendDashboardSource.systemUnassignedRequest(
            homePath: "/tmp/headroom-unassigned-b", providerName: "Codex")

        #expect(first.id != second.id)
        #expect(first.usageIdentity.isSystemUnassigned)
        #expect(second.usageIdentity.isSystemUnassigned)
    }

    @Test
    func `request diagnostic exposes a persisted manual attribution marker`() throws {
        let accountID = UUID()
        let accountKey = CodexSessionOwnershipTimeline.managedAccountKey(id: accountID)
        var timeline = CodexSessionOwnershipTimeline()
        _ = try timeline.recordManualAttribution(
            accountKey: accountKey,
            startUnixMilliseconds: nil,
            endUnixMillisecondsExclusive: nil,
            createdAtUnixMilliseconds: 1000)
        let request = CodexSpendScanRequest(
            id: "manual-account",
            displayName: "Manual account",
            source: .managedAccount(id: accountID),
            homePath: "/tmp/manual-account",
            authFingerprint: nil,
            authFileWasReadable: false,
            cacheIdentity: "manual-cache",
            usageIdentity: UsageIdentity(
                kind: .subscription,
                provider: .codex,
                accountKey: accountKey,
                displayLabel: "Manual account",
                localHomePath: "/tmp/manual-account"),
            storedAccountID: accountID,
            sharedHomePath: "/tmp/shared",
            sessionOwnershipTimeline: timeline)

        #expect(request.diagnostic(lastScanAt: nil).hasManualAttribution)
    }
}

private final class EighthRoundObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false

    var didChange: Bool {
        self.lock.withLock { self.changed }
    }

    func markChanged() {
        self.lock.withLock { self.changed = true }
    }
}
