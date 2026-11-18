import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct HeadroomProviderEnablementTests {
    @Test
    func `launch provider order filters shelf providers and remains sortable`() {
        let settings = testSettingsStore(suiteName: "HeadroomProviderEnablementTests-order")
        settings.setProviderOrder([.factory, .claude, .codex, .antigravity, .opencode, .sub2api])

        #expect(settings.headroomProviderOrder() == [.claude, .codex, .antigravity, .opencode, .sub2api])

        settings.moveHeadroomProvider(fromOffsets: IndexSet(integer: 0), toOffset: 3)

        #expect(settings.headroomProviderOrder() == [.codex, .antigravity, .claude, .opencode, .sub2api])
        #expect(settings.orderedProviders().contains(.factory))
    }

    @Test
    func `disabled and shelf providers consume no refresh or carousel slots`() async throws {
        let settings = testSettingsStore(suiteName: "HeadroomProviderEnablementTests-disabled")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = false
        settings.providerDetectionCompleted = true

        let metadata = ProviderRegistry.shared.metadata
        for provider in UsageProvider.allCases {
            guard let providerMetadata = metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: providerMetadata, enabled: false)
        }
        try settings.setProviderEnabled(
            provider: .factory,
            metadata: #require(metadata[.factory]),
            enabled: true)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("headroom-provider-enablement-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let environment = [
            "HOME": root.path,
            "CODEX_HOME": root.appendingPathComponent(".codex", isDirectory: true).path,
            "XDG_CONFIG_HOME": root.appendingPathComponent(".config", isDirectory: true).path,
        ]
        let store = UsageStore(
            fetcher: UsageFetcher(environment: environment),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
        var refreshAttempts: [UsageProvider] = []
        store._test_providerRefreshOverride = { refreshAttempts.append($0) }
        defer { store._test_providerRefreshOverride = nil }

        #expect(store.enabledProvidersForDisplay().isEmpty)
        #expect(store.enabledProvidersForBackgroundWork().isEmpty)

        await store.refresh()

        #expect(refreshAttempts.isEmpty)
    }

    @Test
    func `system unassigned stays out of menu presentation`() {
        let presentation = CodexLocalUsagePresentation.resolve(
            summaryLine: nil,
            refreshInFlight: false,
            coverageIsComplete: true,
            sharedCorpusHasUsage: true)

        #expect(presentation.line == L("codex_usage_details_unavailable_official"))
        #expect(presentation.unassignedExplanation == nil)
    }
}
