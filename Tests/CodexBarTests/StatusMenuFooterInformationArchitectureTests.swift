import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
private final class FooterUpdateReadyUpdater: UpdaterProviding {
    var automaticallyChecksForUpdates = false
    var automaticallyDownloadsUpdates = false
    let isAvailable = true
    let unavailableReason: String? = nil
    let updateStatus = UpdateStatus(isUpdateReady: true)

    func checkForUpdates(_: Any?) {}
    func installUpdate() {}
}

@MainActor
private final class FooterManualRefreshGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if self.isOpen {
            self.isOpen = false
            return
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        if let continuation = self.continuation {
            continuation.resume()
            self.continuation = nil
        } else {
            self.isOpen = true
        }
    }
}

extension StatusMenuTests {
    @Test
    func `footer keeps settings and more at the root with every secondary action one level down`() throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeFooterSettings()
        let controller = self.makeFooterController(
            settings: settings,
            updater: FooterUpdateReadyUpdater())
        defer { controller.releaseStatusItemsForTesting() }

        let descriptor = controller.makeMenuDescriptor(
            provider: .codex,
            includeContextualActions: true)
        let footer = try #require(descriptor.sections.last)
        let footerTitles = footer.entries.compactMap(self.footerEntryTitle)
        let updateTitle = L("Update ready, restart now?")

        #expect(Set(footerTitles) == Set([updateTitle, L("Settings..."), L("More")]))
        #expect(footerTitles.filter { $0 != updateTitle } == [L("Settings..."), L("More")])

        let moreItems = try #require(footer.entries.compactMap { entry -> [MenuDescriptor.SubmenuItem]? in
            guard case let .submenu(title, _, items) = entry, title == L("More") else { return nil }
            return items
        }.first)
        let actionTitles = Set(moreItems.map { self.canonicalFooterActionTitle($0.title) })

        #expect(actionTitles == Set([
            "Add Account",
            "Refresh All",
            "Open Logs",
            "Check Updates",
            "About",
            "Restart",
            "Quit",
        ]))
        #expect(moreItems.count == 7)
        // Keep the key path outside #expect: the macro rewrites a key-path argument into a throwing closure.
        let allMoreItemsEnabled = moreItems.allSatisfy(\.isEnabled)
        #expect(allMoreItemsEnabled)
        #expect(moreItems.allSatisfy { $0.action != nil })
    }

    @Test
    func `non codex provider footer does not expose codex account creation`() throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeFooterSettings(providers: [.codex, .claude])
        let controller = self.makeFooterController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }

        let descriptor = controller.makeMenuDescriptor(
            provider: .claude,
            includeContextualActions: true)
        let moreItems = try #require(descriptor.sections
            .flatMap(\.entries)
            .compactMap { entry -> [MenuDescriptor.SubmenuItem]? in
                guard case let .submenu(title, _, items) = entry, title == L("More") else { return nil }
                return items
            }
            .first)

        #expect(!moreItems.contains { $0.action == .addCodexAccount })
        #expect(moreItems.contains { $0.action == .refresh })
    }

    @Test
    func `overview footer keeps codex account creation when resolved content provider is non codex`() throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeFooterSettings(
            mergeIcons: true,
            providers: [.codex, .claude])
        settings.selectedMenuProvider = .claude
        settings.mergedMenuLastSelectedWasOverview = true
        let controller = self.makeFooterController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.mergedMenu = menu
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }

        let moreMenu = try #require(menu.items.first { $0.title == L("More") }?.submenu)
        #expect(moreMenu.items.contains {
            $0.action == #selector(controller.addManagedCodexAccountFromMenu(_:))
        })
    }

    @Test
    func `footer shortcuts remain attached after secondary actions move into more`() throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeFooterSettings()
        let controller = self.makeFooterController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }

        let settingsItem = try #require(menu.items.first {
            self.canonicalFooterActionTitle($0.title) == "Settings"
        })
        #expect(settingsItem.keyEquivalent == ",")
        #expect(settingsItem.keyEquivalentModifierMask == [.command])

        let moreMenu = try #require(menu.items.first { $0.title == L("More") }?.submenu)
        let refreshItem = try #require(moreMenu.items.first {
            self.canonicalFooterActionTitle($0.title) == "Refresh All"
        })
        let quitItem = try #require(moreMenu.items.first {
            self.canonicalFooterActionTitle($0.title) == "Quit"
        })

        #expect(refreshItem.keyEquivalent == "r")
        #expect(refreshItem.keyEquivalentModifierMask == [.command])
        #expect(quitItem.keyEquivalent == "q")
        #expect(quitItem.keyEquivalentModifierMask == [.command])
    }

    @Test
    func `check updates inside more is disabled when updater is unavailable`() throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeFooterSettings()
        let controller = self.makeFooterController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }
        let moreMenu = try #require(menu.items.first { $0.title == L("More") }?.submenu)
        let checkUpdatesItem = try #require(moreMenu.items.first {
            self.canonicalFooterActionTitle($0.title) == "Check Updates"
        })

        #expect(!checkUpdatesItem.isEnabled)
    }

    @Test
    func `opening more and rebuilding its root preserves the child rows`() async throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeFooterSettings()
        let controller = self.makeFooterController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }

        let rootMenu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(rootMenu)
        let moreMenu = try #require(rootMenu.items.first { $0.title == L("More") }?.submenu)
        let titlesBeforeOpen = moreMenu.items.map(\.title)

        controller.menuRefreshEnabledOverrideForTesting = true
        controller.openMenus[ObjectIdentifier(rootMenu)] = rootMenu
        controller.menuWillOpen(moreMenu)
        defer {
            controller.menuDidClose(moreMenu)
            controller.menuDidClose(rootMenu)
        }

        var rebuiltMenus: [NSMenu] = []
        controller._test_openMenuRebuildObserver = { rebuiltMenus.append($0) }
        defer { controller._test_openMenuRebuildObserver = nil }
        controller.rebuildMenuTree(from: moreMenu, provider: .codex)
        await controller.openMenuRebuildTasks[ObjectIdentifier(rootMenu)]?.value

        #expect(moreMenu.items.map(\.title) == titlesBeforeOpen)
        #expect(!moreMenu.items.contains { $0.view is ProviderSwitcherView })
        #expect(rebuiltMenus.contains { $0 === rootMenu })
        #expect(!rebuiltMenus.contains { $0 === moreMenu })
    }

    @Test
    func `refresh from child more preserves provider and overview scopes`() async {
        self.disableMenuCardsForTesting()

        let providerSettings = self.makeFooterSettings(providers: [.codex, .claude])
        let providerController = self.makeFooterController(settings: providerSettings)
        defer { providerController.releaseStatusItemsForTesting() }
        let providerRoot = providerController.makeMenu(for: .codex)
        let providerRefreshItem = self.attachSyntheticMoreMenu(
            to: providerRoot,
            controller: providerController).refreshItem
        let providerScopes = await self.captureFooterRefreshScopes(
            controller: providerController,
            refreshItem: providerRefreshItem,
            provider: .codex)

        #expect(providerScopes.provider)
        #expect(!providerScopes.global)

        let overviewSettings = self.makeFooterSettings(
            mergeIcons: true,
            providers: [.codex, .claude])
        overviewSettings.mergedMenuLastSelectedWasOverview = true
        let overviewController = self.makeFooterController(settings: overviewSettings)
        defer { overviewController.releaseStatusItemsForTesting() }
        let overviewRoot = overviewController.makeMenu()
        overviewController.mergedMenu = overviewRoot
        let overviewRefreshItem = self.attachSyntheticMoreMenu(
            to: overviewRoot,
            controller: overviewController).refreshItem
        let overviewScopes = await self.captureFooterRefreshScopes(
            controller: overviewController,
            refreshItem: overviewRefreshItem,
            provider: .codex)

        #expect(!overviewScopes.provider)
        #expect(overviewScopes.global)
    }

    @Test
    func `refresh all inside more reflects the root provider busy state`() throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeFooterSettings(providers: [.codex, .claude])
        let controller = self.makeFooterController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }
        let moreMenu = try #require(menu.items.first { $0.title == L("More") }?.submenu)
        let refreshItem = try #require(moreMenu.items.first {
            self.canonicalFooterActionTitle($0.title) == "Refresh All"
        })
        #expect(refreshItem.isEnabled)

        controller.store.refreshingProviders.insert(.claude)
        controller.updatePersistentRefreshItemsEnabled()
        #expect(refreshItem.isEnabled)

        controller.store.refreshingProviders.insert(.codex)
        controller.updatePersistentRefreshItemsEnabled()
        #expect(!refreshItem.isEnabled)

        controller.store.refreshingProviders.removeAll()
        controller.updatePersistentRefreshItemsEnabled()
        #expect(refreshItem.isEnabled)
    }

    @Test
    func `refresh from child more arms viewport restore for the root menu`() async {
        self.disableMenuCardsForTesting()
        let settings = self.makeFooterSettings()
        let controller = self.makeFooterController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        controller.menuRefreshEnabledOverrideForTesting = true

        let rootMenu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(rootMenu)
        let more = self.attachSyntheticMoreMenu(to: rootMenu, controller: controller)
        controller.menuWillOpen(more.menu)

        let gate = FooterManualRefreshGate()
        controller._test_manualRefreshOperation = { await gate.wait() }
        controller.refreshMenuItem(more.refreshItem)

        let rootID = ObjectIdentifier(rootMenu)
        let childID = ObjectIdentifier(more.menu)
        #expect(controller.menuSession.pendingViewportRestores[rootID] != nil)
        #expect(controller.menuSession.pendingViewportRestores[childID] == nil)

        let refreshTask = controller.manualRefreshTasks[.provider(.codex)]
            ?? controller.manualRefreshTasks[.global]
        gate.resume()
        await refreshTask?.value
        controller.menuDidClose(more.menu)
        controller.menuDidClose(rootMenu)
    }

    private func makeFooterSettings(
        mergeIcons: Bool = false,
        providers: Set<UsageProvider> = [.codex]) -> SettingsStore
    {
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = mergeIcons
        settings.costUsageEnabled = false
        settings.openAIWebAccessEnabled = false
        settings.codexCookieSource = .off
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(
                provider: provider,
                metadata: metadata,
                enabled: providers.contains(provider))
        }
        return settings
    }

    private func makeFooterController(
        settings: SettingsStore,
        updater: UpdaterProviding = DisabledUpdaterController()) -> StatusItemController
    {
        StatusItemController(
            store: self.makeCodexStore(settings: settings, dashboardAuthorized: false),
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: updater,
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
    }

    private func footerEntryTitle(_ entry: MenuDescriptor.Entry) -> String? {
        switch entry {
        case let .action(title, _), let .submenu(title, _, _), let .unavailable(title, _):
            title
        case .text, .divider:
            nil
        }
    }

    private func canonicalFooterActionTitle(_ title: String) -> String {
        let normalized = title
            .replacingOccurrences(of: "...", with: "")
            .replacingOccurrences(of: "…", with: "")
            .replacingOccurrences(of: " for ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("About ") { return "About" }
        if normalized.hasPrefix("Quit ") { return "Quit" }
        return normalized
    }

    private func attachSyntheticMoreMenu(
        to rootMenu: NSMenu,
        controller: StatusItemController) -> (menu: NSMenu, refreshItem: NSMenuItem)
    {
        let moreMenu = NSMenu(title: L("More"))
        moreMenu.autoenablesItems = false
        moreMenu.delegate = controller
        controller.replaceNativeSubmenuItems(
            in: moreMenu,
            with: [.init(title: L("Refresh All"), action: .refresh)])
        let moreItem = NSMenuItem(title: L("More"), action: nil, keyEquivalent: "")
        moreItem.submenu = moreMenu
        rootMenu.addItem(moreItem)
        return (moreMenu, moreMenu.items[0])
    }

    private func captureFooterRefreshScopes(
        controller: StatusItemController,
        refreshItem: NSMenuItem,
        provider: UsageProvider) async -> (provider: Bool, global: Bool)
    {
        let gate = FooterManualRefreshGate()
        controller._test_manualRefreshOperation = { await gate.wait() }
        controller.refreshMenuItem(refreshItem)

        let providerTask = controller.manualRefreshTasks[.provider(provider)]
        let globalTask = controller.manualRefreshTasks[.global]
        let scopes = (provider: providerTask != nil, global: globalTask != nil)
        gate.resume()
        await (providerTask ?? globalTask)?.value
        controller._test_manualRefreshOperation = nil
        return scopes
    }
}
