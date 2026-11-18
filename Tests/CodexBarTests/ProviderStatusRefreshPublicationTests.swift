// Adapted from steipete/CodexBar PR #4175; offline status-fetch stubs only.
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct ProviderStatusRefreshPublicationTests {
    @Test
    func `an older success cannot overwrite a newer incident`() async {
        let store = Self.makeStore()
        let gate = StatusPublicationGate()
        var requests = 0
        store._test_providerStatusFetchOverride = { _ in
            requests += 1
            if requests == 1 {
                await gate.suspend()
                return Self.status(.none, description: "Stale recovery")
            }
            return Self.status(.major, description: "Current incident")
        }
        let older = Task { await store.refreshProviderStatus(.codex) }
        await gate.waitUntilStarted()
        await store.refreshProviderStatus(.codex)
        await gate.resume()
        await older.value
        #expect(store.statuses[.codex]?.description == "Current incident")
        #expect(store.providerStatusHadIssue[.codex] == true)
    }

    @Test
    func `a newer request can publish after an overlapping older success`() async {
        let store = Self.makeStore()
        let olderGate = StatusPublicationGate()
        let newerGate = StatusPublicationGate()
        var requests = 0
        store._test_providerStatusFetchOverride = { _ in
            requests += 1
            if requests == 1 {
                await olderGate.suspend()
                return Self.status(.none, description: "Older operational status")
            }
            await newerGate.suspend()
            return Self.status(.major, description: "Current incident")
        }

        let older = Task { await store.refreshProviderStatus(.codex) }
        await olderGate.waitUntilStarted()
        let newer = Task { await store.refreshProviderStatus(.codex) }
        await newerGate.waitUntilStarted()
        await olderGate.resume()
        await older.value
        #expect(store.statuses[.codex]?.description == "Older operational status")
        await newerGate.resume()
        await newer.value

        #expect(store.statuses[.codex]?.description == "Current incident")
        #expect(store.providerStatusHadIssue[.codex] == true)
    }

    @Test
    func `an older success remains useful when a newer request fails`() async {
        let store = Self.makeStore()
        let gate = StatusPublicationGate()
        var requests = 0
        store._test_providerStatusFetchOverride = { _ in
            requests += 1
            if requests == 1 {
                await gate.suspend()
                return Self.status(.major, description: "Available incident")
            }
            throw URLError(.timedOut)
        }

        let older = Task { await store.refreshProviderStatus(.codex) }
        await gate.waitUntilStarted()
        await store.refreshProviderStatus(.codex)
        #expect(store.statuses[.codex]?.indicator == .unknown)
        await gate.resume()
        await older.value

        #expect(store.statuses[.codex]?.description == "Available incident")
        #expect(store.providerStatusHadIssue[.codex] == true)
    }

    @Test
    func `an older status failure cannot request a retry after newer success`() async {
        let store = Self.makeStore()
        let gate = StatusPublicationGate()
        var requests = 0
        store.startupConnectivityRetryRefreshActive = true
        store._test_providerStatusFetchOverride = { _ in
            requests += 1
            if requests == 1 {
                await gate.suspend()
                throw URLError(.notConnectedToInternet)
            }
            return Self.status(.major, description: "Current incident")
        }

        let older = Task { await store.refreshProviderStatus(.codex) }
        await gate.waitUntilStarted()
        await store.refreshProviderStatus(.codex)
        await gate.resume()
        await older.value

        #expect(store.statuses[.codex]?.description == "Current incident")
        #expect(store.startupConnectivityRetryNeeded == false)
    }

    @Test
    func `status publication ordering is independent for each provider`() async {
        let store = Self.makeStore(providers: [.codex, .claude])
        let gate = StatusPublicationGate()
        store._test_providerStatusFetchOverride = { provider in
            if provider == .codex {
                await gate.suspend()
            }
            return Self.status(.major, description: provider.rawValue)
        }

        let codex = Task { await store.refreshProviderStatus(.codex) }
        await gate.waitUntilStarted()
        await store.refreshProviderStatus(.claude)
        await gate.resume()
        await codex.value

        #expect(store.statuses[.codex]?.description == "codex")
        #expect(store.statuses[.claude]?.description == "claude")
    }

    @Test
    func `a later successful request can report a genuine recovery`() async {
        let store = Self.makeStore()
        store._test_providerStatusFetchOverride = { _ in
            Self.status(.major, description: "Incident")
        }
        await store.refreshProviderStatus(.codex)
        #expect(store.providerStatusHadIssue[.codex] == true)

        store._test_providerStatusFetchOverride = { _ in
            Self.status(.none, description: "Recovered")
        }
        await store.refreshProviderStatus(.codex)

        #expect(store.statuses[.codex]?.description == "Recovered")
        #expect(store.providerStatusHadIssue[.codex] == false)
    }

    private static func makeStore(providers: Set<UsageProvider> = [.codex]) -> UsageStore {
        let settings = testSettingsStore(
            suiteName: "ProviderStatusRefreshPublicationTests")
        settings._test_codexAccountSnapshotLoader = { _ in
            CodexAccountReconciliationSnapshot(
                storedAccounts: [],
                activeStoredAccount: nil,
                liveSystemAccount: nil,
                matchingStoredAccountForLiveSystemAccount: nil,
                activeSource: .liveSystem,
                hasUnreadableAddedAccountStore: false)
        }
        settings.providerDetectionCompleted = true
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = true
        settings.costUsageEnabled = false
        settings.openAIWebAccessEnabled = false
        settings.providerStorageFootprintsEnabled = false
        for (provider, metadata) in ProviderRegistry.shared.metadata {
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: providers.contains(provider))
        }
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        store._test_providerRefreshOverride = { _ in }
        store._test_codexCreditsLoaderOverride = {
            CreditsSnapshot(remaining: 0, events: [], updatedAt: Date(timeIntervalSince1970: 1_750_000_000))
        }
        store._test_tokenUsageRefreshOverride = { _, _ in }
        return store
    }

    private static func status(_ indicator: ProviderStatusIndicator, description: String) -> ProviderStatus {
        ProviderStatus(indicator: indicator, description: description, updatedAt: nil)
    }
}

private actor StatusPublicationGate {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?

    func suspend() async {
        self.started = true
        self.startWaiter?.resume()
        self.startWaiter = nil
        await withCheckedContinuation { self.release = $0 }
    }

    func waitUntilStarted() async {
        guard !self.started else { return }
        await withCheckedContinuation { self.startWaiter = $0 }
    }

    func resume() {
        self.release?.resume()
        self.release = nil
    }
}
