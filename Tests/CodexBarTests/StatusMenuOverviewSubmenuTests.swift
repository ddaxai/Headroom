import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

extension StatusMenuTests {
    @Test
    func `overview rows expose provider detail submenus`() throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .claude
        settings.mergedMenuLastSelectedWasOverview = true
        settings.costUsageEnabled = true
        settings.costSummaryDisplayStyle = .both

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            let shouldEnable = provider == .claude || provider == .codex
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: shouldEnable)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let usage = CostUsageTokenSnapshot(
            sessionTokens: 150,
            sessionCostUSD: 9,
            last30DaysTokens: 150,
            last30DaysCostUSD: 9,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2023-11-14",
                    inputTokens: 100,
                    outputTokens: 50,
                    totalTokens: 150,
                    costUSD: 9,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            updatedAt: now)
        store._setTokenSnapshotForTesting(usage, provider: .claude)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)

        let claudeRow = try #require(menu.items.first {
            ($0.representedObject as? String) == "overviewRow-claude"
        })
        #expect(claudeRow.submenu?.items.contains {
            ($0.representedObject as? String) == StatusItemController.costHistoryChartID
        } == true)
    }

    @Test
    func `overview row shows plan usage not cost history for antigravity`() throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .antigravity
        settings.mergedMenuLastSelectedWasOverview = true
        settings.costUsageEnabled = true
        // Deliberately NOT `.costSubmenu`/`.both`: Antigravity has real rate-limit bars (unlike
        // mistral), so its Overview row must fall through to Plan Usage here rather than
        // unconditionally preferring cost history the way mistral's Overview row does.
        settings.costSummaryDisplayStyle = .inlineSummary

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            let shouldEnable = provider == .antigravity || provider == .codex
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: shouldEnable)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let antigravitySnapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 12,
                windowMinutes: 5 * 60,
                resetsAt: Date().addingTimeInterval(3600),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 57,
                windowMinutes: 7 * 24 * 60,
                resetsAt: Date().addingTimeInterval(86400),
                resetDescription: nil),
            updatedAt: Date())
        store._setSnapshotForTesting(antigravitySnapshot, provider: .antigravity)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)

        let antigravityRow = try #require(menu.items.first {
            ($0.representedObject as? String) == "overviewRow-antigravity"
        })
        #expect(antigravityRow.submenu?.items.contains {
            ($0.representedObject as? String) == StatusItemController.usageHistoryChartID
        } == true)
        #expect(antigravityRow.submenu?.items.contains {
            ($0.representedObject as? String) == StatusItemController.costHistoryChartID
        } == false)
    }

    @Test
    func `overview row submenu action does not switch provider detail`() throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .claude
        settings.mergedMenuLastSelectedWasOverview = true

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            let shouldEnable = provider == .antigravity || provider == .claude
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: shouldEnable)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let usage = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 50,
                windowMinutes: 60,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: nil,
            updatedAt: now)
        store._setSnapshotForTesting(usage, provider: .antigravity)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)

        let antigravityRow = try #require(menu.items.first {
            ($0.representedObject as? String) == "overviewRow-antigravity"
        })
        #expect(antigravityRow.submenu != nil)

        let action = try #require(antigravityRow.action)
        let target = try #require(antigravityRow.target as? StatusItemController)
        _ = target.perform(action, with: antigravityRow)

        #expect(settings.mergedMenuLastSelectedWasOverview)
        #expect(settings.selectedMenuProvider == .claude)
        #expect(menu.items.contains {
            ($0.representedObject as? String) == "overviewRow-antigravity"
        })
    }

    @Test
    func `selecting overview row defers provider detail rebuild`() async throws {
        let previousMenuCardRendering = StatusItemController.menuCardRenderingEnabled
        let previousMenuRefresh = StatusItemController.menuRefreshEnabled
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(true)
        defer {
            StatusItemController.menuCardRenderingEnabled = previousMenuCardRendering
            StatusItemController.setMenuRefreshEnabledForTesting(previousMenuRefresh)
        }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.mergedMenuLastSelectedWasOverview = true

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            let shouldEnable = provider == .codex || provider == .opencode
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: shouldEnable)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }

        let opencodeRow = try #require(menu.items.first {
            ($0.representedObject as? String) == "overviewRow-opencode"
        })
        var rebuildCount = 0
        controller._test_openMenuRebuildObserver = { _ in
            rebuildCount += 1
        }
        defer { controller._test_openMenuRebuildObserver = nil }

        let action = try #require(opencodeRow.action)
        let target = try #require(opencodeRow.target as? StatusItemController)
        _ = target.perform(action, with: opencodeRow)

        #expect(settings.mergedMenuLastSelectedWasOverview == false)
        #expect(settings.selectedMenuProvider == .opencode)
        #expect(rebuildCount == 0)
        #expect(menu.items.contains {
            ($0.representedObject as? String)?.hasPrefix("overviewRow-") == true
        })

        for _ in 0..<100 where rebuildCount == 0 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }

        let representedIDs = menu.items.compactMap { $0.representedObject as? String }
        let switcherButtons = (menu.items.first?.view as? ProviderSwitcherView)?.subviews
            .compactMap { $0 as? NSButton } ?? []
        #expect(rebuildCount == 1)
        #expect(representedIDs.contains("menuCard"))
        #expect(representedIDs.contains(where: { $0.hasPrefix("overviewRow-") }) == false)
        #expect(switcherButtons.first(where: { $0.state == .on })?.tag == 2)
    }

    @Test
    func `overview row action close renders selected provider on next open`() async throws {
        let previousMenuCardRendering = StatusItemController.menuCardRenderingEnabled
        let previousMenuRefresh = StatusItemController.menuRefreshEnabled
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(true)
        defer {
            StatusItemController.menuCardRenderingEnabled = previousMenuCardRendering
            StatusItemController.setMenuRefreshEnabledForTesting(previousMenuRefresh)
        }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.mergedMenuLastSelectedWasOverview = true

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            let shouldEnable = provider == .codex || provider == .opencode
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: shouldEnable)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)

        let opencodeRow = try #require(menu.items.first {
            ($0.representedObject as? String) == "overviewRow-opencode"
        })
        var rebuildCount = 0
        controller._test_openMenuRebuildObserver = { _ in
            rebuildCount += 1
        }
        defer { controller._test_openMenuRebuildObserver = nil }

        let action = try #require(opencodeRow.action)
        let target = try #require(opencodeRow.target as? StatusItemController)
        _ = target.perform(action, with: opencodeRow)
        controller.menuDidClose(menu)

        await Task.yield()
        await Task.yield()
        #expect(rebuildCount == 0)
        #expect(settings.selectedMenuProvider == .opencode)

        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }

        let representedIDs = menu.items.compactMap { $0.representedObject as? String }
        let switcherButtons = (menu.items.first?.view as? ProviderSwitcherView)?.subviews
            .compactMap { $0 as? NSButton } ?? []
        #expect(representedIDs.contains("menuCard"))
        #expect(representedIDs.contains(where: { $0.hasPrefix("overviewRow-") }) == false)
        #expect(switcherButtons.first(where: { $0.state == .on })?.tag == 2)
    }
}
