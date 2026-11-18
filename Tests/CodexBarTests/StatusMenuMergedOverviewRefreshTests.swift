import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct StatusMenuMergedOverviewRefreshTests {
    @Test
    func `overview stays busy for an omitted provider refresh`() async throws {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        let activeProviders: [UsageProvider] = [.antigravity, .claude, .codex, .opencode]
        self.enableOnly(Set(activeProviders), settings: settings)
        settings.setMergedOverviewProviderSelection(
            provider: .opencode,
            isSelected: false,
            activeProviders: activeProviders)
        settings.mergedMenuLastSelectedWasOverview = true

        let controller = self.makeController(settings: settings)
        let menu = try #require(controller.makeMenu() as? StatusItemMenu)
        controller.mergedMenu = menu
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }

        let visibleProviders = settings.resolvedMergedOverviewProviders(
            activeProviders: controller.store.enabledProvidersForDisplay())
        #expect(!visibleProviders.contains(.opencode))

        controller.store.refreshingProviders.insert(.opencode)
        controller.updatePersistentRefreshItemsEnabled()
        #expect(controller.isRefreshActionInFlight(for: menu))
        let moreMenu = try #require(menu.items.first { $0.title == L("More") }?.submenu)
        let refreshItem = try #require(moreMenu.items.first { $0.title == L("Refresh All") })
        #expect(controller.isPersistentRefreshItem(refreshItem))
        #expect(refreshItem.keyEquivalent == "r")
        #expect(refreshItem.keyEquivalentModifierMask == [.command])
        #expect(!refreshItem.isEnabled)

        var requestCount = 0
        controller._test_manualRefreshOperation = { requestCount += 1 }
        controller.performPersistentRefreshAction(in: ObjectIdentifier(menu))
        #expect(try menu.performKeyEquivalent(with: self.keyEvent("r", keyCode: 15)))
        for _ in 0..<20 {
            await Task.yield()
        }

        #expect(requestCount == 0)
        #expect(controller.manualRefreshTasks.isEmpty)
    }

    @Test
    func `fresh overview reconcile keeps refresh all disabled for omitted provider refresh`() throws {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        let activeProviders: [UsageProvider] = [.antigravity, .claude, .codex, .opencode]
        self.enableOnly(Set(activeProviders), settings: settings)
        settings.setMergedOverviewProviderSelection(
            provider: .opencode,
            isSelected: false,
            activeProviders: activeProviders)
        settings.mergedMenuLastSelectedWasOverview = true

        let controller = self.makeController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        let menu = try #require(controller.makeMenu() as? StatusItemMenu)
        controller.mergedMenu = menu
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }

        controller.store.refreshingProviders.insert(.opencode)
        controller.mergedSwitcherContentCaches.removeAll()
        controller.updateMenuContentPreservingSwitcher(
            menu,
            context: StatusItemController.MenuUpdateContext(
                provider: nil,
                currentProvider: .codex,
                switcherSelection: .overview,
                menuWidth: StatusItemController.menuCardBaseWidth,
                codexAccountDisplay: nil,
                tokenAccountDisplay: nil,
                openAIContext: StatusItemController.OpenAIWebContext(
                    hasUsageBreakdown: false,
                    hasCreditsHistory: false,
                    hasCostHistory: false,
                    canShowBuyCredits: false,
                    hasOpenAIWebMenuItems: false),
                descriptor: controller.makeMenuDescriptor(
                    provider: nil,
                    includeContextualActions: false)))

        let moreMenu = try #require(menu.items.first { $0.title == L("More") }?.submenu)
        let refreshItem = try #require(moreMenu.items.first { $0.title == L("Refresh All") })
        #expect(!refreshItem.isEnabled)
    }

    private func makeSettings() -> SettingsStore {
        let suite = "StatusMenuMergedOverviewRefreshTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }

    private func makeController(settings: SettingsStore) -> StatusItemController {
        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        return StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
    }

    private func enableOnly(_ providers: Set<UsageProvider>, settings: SettingsStore) {
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: providers.contains(provider))
        }
    }

    private func keyEvent(_ characters: String, keyCode: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode))
    }
}
