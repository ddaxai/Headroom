import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension StatusMenuTests {
    @Test
    func `root menu still populates when opened`() {
        self.disableMenuCardsForTesting()
        let controller = self.makeChildMenuIsolationController()
        defer { controller.releaseStatusItemsForTesting() }

        let rootMenu = controller.makeMenu(for: .codex)
        #expect(rootMenu.supermenu == nil)
        let itemCountBeforeOpen = rootMenu.items.count
        controller.menuWillOpen(rootMenu)

        #expect(rootMenu.items.count > itemCountBeforeOpen)
        #expect(rootMenu.items.contains { ($0.representedObject as? String) == "relayQuickSwitch" })
    }

    @Test
    func `descriptor child menu keeps its account rows when opened`() throws {
        self.disableMenuCardsForTesting()
        let controller = self.makeChildMenuIsolationController()
        defer { controller.releaseStatusItemsForTesting() }

        let rootMenu = NSMenu()
        controller.addActionableSections(
            [MenuDescriptor.Section(entries: [
                .submenu(L("Official Accounts"), "person.crop.circle", [
                    .init(title: "official@example.com", action: nil, isEnabled: false, isChecked: true),
                    .init(title: "managed@example.com", action: .restoreCodexOfficialConfiguration),
                ]),
            ])],
            to: rootMenu,
            width: StatusItemController.menuCardBaseWidth)

        let childMenu = try #require(rootMenu.items.first?.submenu)
        let titlesBeforeOpen = childMenu.items.map(\.title)
        #expect(childMenu.supermenu === rootMenu)

        controller.menuWillOpen(childMenu)

        #expect(childMenu.items.map(\.title) == titlesBeforeOpen)
        #expect(!childMenu.items.contains { $0.view is ProviderSwitcherView })
    }

    @Test
    func `zai details child menu keeps its own rows when opened`() throws {
        self.disableMenuCardsForTesting()
        let controller = self.makeChildMenuIsolationController()
        defer { controller.releaseStatusItemsForTesting() }

        let reset = Date(timeIntervalSince1970: 1_700_003_600)
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            zaiUsage: ZaiUsageSnapshot(
                tokenLimit: nil,
                timeLimit: ZaiLimitEntry(
                    type: .timeLimit,
                    unit: .hours,
                    number: 5,
                    usage: 100,
                    currentValue: 40,
                    remaining: 60,
                    percentage: 40,
                    usageDetails: [ZaiUsageDetail(modelCode: "glm-4", usage: 40)],
                    nextResetTime: reset),
                planName: "Pro",
                updatedAt: reset),
            updatedAt: reset)
        let childMenu = try #require(controller.makeZaiUsageDetailsSubmenu(snapshot: snapshot))
        let rootMenu = self.attach(childMenu: childMenu)
        let titlesBeforeOpen = childMenu.items.map(\.title)
        #expect(childMenu.supermenu === rootMenu)

        controller.menuWillOpen(childMenu)

        #expect(childMenu.items.map(\.title) == titlesBeforeOpen)
        #expect(!childMenu.items.contains { $0.view is ProviderSwitcherView })
    }

    @Test
    func `codex hourly child menu keeps its chart row when opened`() throws {
        self.disableMenuCardsForTesting()
        let controller = self.makeChildMenuIsolationController()
        defer { controller.releaseStatusItemsForTesting() }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 12,
            sessionCostUSD: 0.01,
            last30DaysTokens: 12,
            last30DaysCostUSD: 0.01,
            hourly24Hours: [.init(startDate: now, totalTokens: 12, costUSD: 0.01)],
            daily: [],
            updatedAt: now)
        let childMenu = try #require(controller.makeCodexHourlyUsageSubmenu(
            snapshot: snapshot,
            width: StatusItemController.menuCardBaseWidth))
        let rootMenu = self.attach(childMenu: childMenu)
        let titlesBeforeOpen = childMenu.items.map(\.title)
        #expect(childMenu.supermenu === rootMenu)

        controller.menuWillOpen(childMenu)

        #expect(childMenu.items.map(\.title) == titlesBeforeOpen)
        #expect(!childMenu.items.contains { $0.view is ProviderSwitcherView })
    }

    @Test
    func `status components child menu keeps its own rows when opened`() throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = true
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let childMenu = try #require(controller.makeStatusComponentsSubmenu(provider: .codex))
        let rootMenu = self.attach(childMenu: childMenu)
        controller.menuWillOpen(childMenu)

        #expect(childMenu.supermenu === rootMenu)
        #expect(!childMenu.items.isEmpty)
        #expect(!childMenu.items.contains { $0.view is ProviderSwitcherView })
    }

    @Test
    func `explicit relay rebuild targets the root without populating an ordinary child`() async {
        self.disableMenuCardsForTesting()
        let controller = self.makeChildMenuIsolationController()
        defer { controller.releaseStatusItemsForTesting() }
        controller.menuRefreshEnabledOverrideForTesting = true

        let rootMenu = controller.makeMenu(for: .codex)
        let childMenu = NSMenu()
        childMenu.addItem(NSMenuItem(title: "Saved API", action: nil, keyEquivalent: ""))
        let childItem = NSMenuItem(title: "Codex accounts and APIs", action: nil, keyEquivalent: "")
        childItem.submenu = childMenu
        rootMenu.addItem(childItem)
        let childTitles = childMenu.items.map(\.title)
        controller.openMenus[ObjectIdentifier(rootMenu)] = rootMenu
        controller.openMenus[ObjectIdentifier(childMenu)] = childMenu
        var rebuiltMenus: [NSMenu] = []
        controller._test_openMenuRebuildObserver = { rebuiltMenus.append($0) }
        defer { controller._test_openMenuRebuildObserver = nil }

        controller.rebuildMenuTree(from: childMenu, provider: .codex)
        for _ in 0..<100 where rebuiltMenus.isEmpty {
            await Task.yield()
        }

        #expect(rebuiltMenus.contains { $0 === rootMenu })
        #expect(!rebuiltMenus.contains { $0 === childMenu })
        #expect(childMenu.items.map(\.title) == childTitles)
    }

    @Test
    func `explicit relay rebuild synchronizes native Codex submenu checkmarks`() throws {
        self.disableMenuCardsForTesting()
        let controller = self.makeChildMenuIsolationController()
        defer { controller.releaseStatusItemsForTesting() }
        controller.settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "official@example.com",
            codexHomePath: "/tmp/test-codex-home",
            observedAt: Date())
        defer { controller.settings._test_liveSystemCodexAccount = nil }

        let profileID = UUID()
        let profile = try RelayProfile(
            id: profileID,
            name: "Saved API",
            baseURL: #require(URL(string: "https://relay.example/v1")),
            apiFormat: .openAIResponses,
            credentialReference: RelayCredentialReference.make(for: profileID),
            credentialConfigured: true,
            targets: [.init(app: .codex, model: "test-model")])
        var activation: RelayActivationState?
        let actions = RelaySettingsActions(
            loadProfiles: { [profile] },
            storeProfiles: { _ in },
            loadCredential: { _ in "test-key" },
            storeCredential: { _, _ in },
            removeCredential: { _ in },
            captureBaseline: { throw NativeSubmenuTestError.unused },
            applyProfile: { _ in throw NativeSubmenuTestError.unused },
            restoreBaseline: { _ in throw NativeSubmenuTestError.unused },
            restoreBaselineForTargets: nil,
            discardBackup: { _ in },
            loadActivationState: { activation },
            storeActivationState: { activation = $0 },
            clearActivationState: { activation = nil },
            loadUnifiedHistoryEnabled: { true },
            loadUnifiedHistoryOptIn: { true },
            storeUnifiedHistoryOptIn: { _ in },
            hasCodexHistory: { true },
            isCodexLoggedIn: { true },
            enableUnifiedHistory: { throw NativeSubmenuTestError.unused },
            loadUsageSummary: { _ in nil },
            storeUsageSummary: { _, _ in },
            fetchUsageSummary: { _, _ in throw NativeSubmenuTestError.unused })
        controller.relayQuickSwitchCoordinator = RelayQuickSwitchCoordinator(actions: actions)

        let account = CodexVisibleAccount(
            id: "official-account",
            email: "official@example.com",
            storedAccountID: nil,
            selectionSource: .liveSystem,
            isActive: true,
            isLive: true,
            canReauthenticate: true,
            canRemove: false)
        controller.lastCodexAccountMenuDisplay = CodexAccountMenuDisplay(
            accounts: [account],
            snapshots: [],
            activeVisibleAccountID: account.id,
            layout: .stacked)

        let rootMenu = NSMenu()
        let childMenu = NSMenu(title: L("Official Accounts"))
        let header = NSMenuItem(title: L("Official Accounts"), action: nil, keyEquivalent: "")
        header.representedObject = "codexOfficialGroupHeader"
        header.submenu = childMenu
        rootMenu.addItem(header)
        controller.replaceNativeSubmenuItems(
            in: childMenu,
            with: [
                .init(title: "official@example.com", action: nil, isEnabled: false, isChecked: true),
            ])
        let officialItem = try #require(childMenu.items.first(where: { $0.title == "official@example.com" }))
        #expect(officialItem.state == .on)

        activation = RelayActivationState(
            activeProfileIDsByTarget: [.codex: profileID],
            baselineBackupDirectory: URL(fileURLWithPath: "/tmp/test-relay-backup"))
        controller.rebuildMenuTree(from: childMenu, provider: .codex)

        #expect(childMenu.items.first(where: { $0.title == "official@example.com" })?.state == .off)

        activation = nil
        controller.rebuildMenuTree(from: childMenu, provider: .codex)

        #expect(childMenu.items.first(where: { $0.title == "official@example.com" })?.state == .on)
    }

    private func makeChildMenuIsolationController() -> StatusItemController {
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        return StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
    }

    private func attach(childMenu: NSMenu) -> NSMenu {
        let rootMenu = NSMenu()
        let item = NSMenuItem(title: "Details", action: nil, keyEquivalent: "")
        item.submenu = childMenu
        rootMenu.addItem(item)
        return rootMenu
    }
}

private enum NativeSubmenuTestError: Error {
    case unused
}
