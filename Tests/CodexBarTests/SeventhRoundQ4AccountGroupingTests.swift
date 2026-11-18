import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct SeventhRoundQ4AccountGroupingTests {
    @Test
    func `stacked official account cards show their own rolling 24 hour usage`() throws {
        let fixture = try self.makeFixture(includeRelay: false)
        defer { fixture.controller.releaseStatusItemsForTesting() }

        let firstModel = try self.accountCardModel(id: "menuCard-0", in: fixture.menu)
        let secondModel = try self.accountCardModel(id: "menuCard-1", in: fixture.menu)

        #expect(firstModel.email == "alpha@example.com")
        #expect(secondModel.email == "beta@example.com")
        #expect(firstModel.usageLine == fixture.expectedUsageLines[0])
        #expect(secondModel.usageLine == fixture.expectedUsageLines[1])
        #expect(firstModel.usageLine != secondModel.usageLine)
    }

    @Test
    func `route invalidation retains last good usage for unchanged official owners`() throws {
        let fullCorpus = Self.costSnapshot(tokens: 4_125_000, cost: 23.00)
        let fixture = try self.makeFixture(includeRelay: true, fullCorpusSnapshot: fullCorpus)
        defer { fixture.controller.releaseStatusItemsForTesting() }

        let accounts = Self.accounts()
        let previousProjection = CodexVisibleAccountProjection(
            visibleAccounts: accounts,
            activeVisibleAccountID: accounts[0].id,
            liveVisibleAccountID: accounts[0].id,
            hasUnreadableAddedAccountStore: false)
        let nextProjection = CodexVisibleAccountProjection(
            visibleAccounts: accounts,
            activeVisibleAccountID: accounts[1].id,
            liveVisibleAccountID: accounts[0].id,
            hasUnreadableAddedAccountStore: false)
        let previousRequests = accounts.enumerated().map { index, account in
            CodexSpendScanRequest(
                id: account.id,
                displayName: account.displayName,
                source: account.selectionSource,
                homePath: "/tmp/q4-last-good-\(index)",
                authFingerprint: account.authFingerprint,
                authFileWasReadable: true,
                cacheIdentity: "q4-last-good-\(index)",
                usageIdentity: .subscription(account: account),
                isHomeReadable: true)
        }
        fixture.controller.codexMenuSpendPlan = CodexMenuSpendPlan(
            generation: 1,
            projectionSignature: CodexMenuSpendPlan.projectionSignature(previousProjection),
            requests: previousRequests)
        fixture.controller.codexMenuSpendProjectionSignature =
            CodexMenuSpendPlan.projectionSignature(previousProjection)
        fixture.controller.codexMenuSpendOwnershipRevision = "prior-route"
        fixture.controller.codexMenuSharedCostSnapshot = Self.costSnapshot(tokens: 375_000, cost: 2.25)
        fixture.controller.codexMenuRelayAggregateCostSnapshot = Self.costSnapshot(tokens: 250_000, cost: 1.50)

        fixture.controller.invalidateCodexMenuSpendPlanIfProjectionChanged(nextProjection)

        #expect(Set(fixture.controller.codexMenuCostSnapshotsByAccountID.keys) == Set(accounts.map(\.id)))
        #expect(fixture.controller.codexMenuFullCorpusCostSnapshot == fullCorpus)
        #expect(fixture.controller.codexMenuSharedCostSnapshot == nil)
        #expect(fixture.controller.codexMenuRelayAggregateCostSnapshot == nil)
        #expect(fixture.controller.codexMenuCostUpdatedAt == nil)
    }

    @Test
    func `consecutive route switches retain official usage before the scan plan rebuilds`() throws {
        let fixture = try self.makeFixture(includeRelay: true)
        defer { fixture.controller.releaseStatusItemsForTesting() }

        let accounts = Self.accounts()
        let projection = CodexVisibleAccountProjection(
            visibleAccounts: accounts,
            activeVisibleAccountID: accounts[0].id,
            liveVisibleAccountID: accounts[0].id,
            hasUnreadableAddedAccountStore: false)
        let requests = accounts.enumerated().map { index, account in
            CodexSpendScanRequest(
                id: account.id,
                displayName: account.displayName,
                source: account.selectionSource,
                homePath: "/tmp/q4-consecutive-route-\(index)",
                authFingerprint: account.authFingerprint,
                authFileWasReadable: true,
                cacheIdentity: "q4-consecutive-route-\(index)",
                usageIdentity: .subscription(account: account),
                isHomeReadable: true)
        }
        fixture.controller.codexMenuSpendPlan = CodexMenuSpendPlan(
            generation: 1,
            projectionSignature: CodexMenuSpendPlan.projectionSignature(projection),
            requests: requests)
        fixture.controller.codexMenuSpendProjectionSignature =
            CodexMenuSpendPlan.projectionSignature(projection)
        fixture.controller.codexMenuSpendOwnershipRevision = "first-route"

        fixture.controller.invalidateCodexMenuSpendPlanIfProjectionChanged(projection)
        #expect(fixture.controller.codexMenuSpendPlan == nil)
        #expect(Set(fixture.controller.codexMenuCostSnapshotsByAccountID.keys) == Set(accounts.map(\.id)))

        fixture.controller.codexMenuSpendOwnershipRevision = "second-route"
        fixture.controller.invalidateCodexMenuSpendPlanIfProjectionChanged(projection)

        #expect(Set(fixture.controller.codexMenuCostSnapshotsByAccountID.keys) == Set(accounts.map(\.id)))
    }

    @Test
    func `route invalidation retains relay usage before the scan plan rebuilds`() throws {
        let fixture = try self.makeFixture(includeRelay: true)
        defer { fixture.controller.releaseStatusItemsForTesting() }

        let accounts = Self.accounts()
        let projection = CodexVisibleAccountProjection(
            visibleAccounts: accounts,
            activeVisibleAccountID: accounts[0].id,
            liveVisibleAccountID: accounts[0].id,
            hasUnreadableAddedAccountStore: false)
        let profileID = try #require(fixture.controller.relayQuickSwitchCoordinator.snapshot()
            .optionsByTarget[.codex]?.first?.id)
        let relaySnapshot = Self.costSnapshot(tokens: 250_000, cost: 1.50)
        fixture.controller.codexMenuRelayCostSnapshotsByProfileID = [profileID: relaySnapshot]
        fixture.controller.codexMenuRelayAggregateCostSnapshot = relaySnapshot
        fixture.controller.codexMenuSpendProjectionSignature =
            CodexMenuSpendPlan.projectionSignature(projection)
        fixture.controller.codexMenuSpendOwnershipRevision = "first-route"

        fixture.controller.invalidateCodexMenuSpendPlanIfProjectionChanged(projection)

        #expect(fixture.controller.codexMenuRelayCostSnapshotsByProfileID == [profileID: relaySnapshot])
        #expect(fixture.controller.codexMenuRelayAggregateCostSnapshot == relaySnapshot)
    }

    @Test
    func `route invalidation rejects last good usage from a changed composite owner`() throws {
        let fixture = try self.makeFixture(includeRelay: false)
        defer { fixture.controller.releaseStatusItemsForTesting() }

        let accounts = Self.accounts()
        let previousProjection = CodexVisibleAccountProjection(
            visibleAccounts: accounts,
            activeVisibleAccountID: accounts[0].id,
            liveVisibleAccountID: accounts[0].id,
            hasUnreadableAddedAccountStore: false)
        let previousRequests = accounts.enumerated().map { index, account in
            CodexSpendScanRequest(
                id: account.id,
                displayName: account.displayName,
                source: account.selectionSource,
                homePath: "/tmp/q4-owner-change-\(index)",
                authFingerprint: account.authFingerprint,
                authFileWasReadable: true,
                cacheIdentity: "q4-owner-change-\(index)",
                usageIdentity: .subscription(account: account),
                isHomeReadable: true)
        }
        fixture.controller.codexMenuSpendPlan = CodexMenuSpendPlan(
            generation: 1,
            projectionSignature: CodexMenuSpendPlan.projectionSignature(previousProjection),
            requests: previousRequests)
        fixture.controller.codexMenuSpendProjectionSignature =
            CodexMenuSpendPlan.projectionSignature(previousProjection)

        let changedOwner = CodexVisibleAccount(
            id: accounts[0].id,
            email: accounts[0].email,
            workspaceAccountID: "different-workspace",
            storedAccountID: nil,
            selectionSource: .liveSystem,
            isActive: true,
            isLive: true,
            canReauthenticate: true,
            canRemove: false)
        let nextProjection = CodexVisibleAccountProjection(
            visibleAccounts: [changedOwner, accounts[1]],
            activeVisibleAccountID: changedOwner.id,
            liveVisibleAccountID: changedOwner.id,
            hasUnreadableAddedAccountStore: false)

        fixture.controller.invalidateCodexMenuSpendPlanIfProjectionChanged(nextProjection)

        #expect(Set(fixture.controller.codexMenuCostSnapshotsByAccountID.keys) == [accounts[1].id])
    }

    @Test
    func `full corpus keeps total and human readable official empty states available`() throws {
        let fullCorpus = Self.costSnapshot(tokens: 4_000_000, cost: 23.00)
        let fixture = try self.makeFixture(
            includeRelay: false,
            accountCostsOverride: [nil, nil],
            includesUnassignedSnapshot: false,
            fullCorpusSnapshot: fullCorpus)
        defer { fixture.controller.releaseStatusItemsForTesting() }

        let firstModel = try self.accountCardModel(id: "menuCard-0", in: fixture.menu)
        let secondModel = try self.accountCardModel(id: "menuCard-1", in: fixture.menu)
        let totalItem = try #require(fixture.menu.items.first {
            $0.representedObject as? String == "codexStackedTotal"
        })
        let totalHosting = try #require(totalItem.view as? StackedTotalHostingView)
        let totalView = totalHosting.rootView.content()

        #expect(firstModel.usageLine == L("codex_usage_details_unavailable_official"))
        #expect(secondModel.usageLine == L("codex_usage_details_unavailable_official"))
        #expect(firstModel.usageEmptyText == nil)
        #expect(secondModel.usageEmptyText == nil)
        #expect(totalView.value == CodexStackedUsageSummary.line(
            fullCorpus.rolling24Hours,
            preferredCurrencyCode: fixture.settings.preferredCurrencyCode,
            emptyText: "unused",
            estimateSnapshot: fullCorpus))
        #expect(totalView.secondaryValue == nil)
    }

    @Test
    func `stacked codex menu omits system cards while retaining official API and total order`() throws {
        let fixture = try self.makeFixture(includeRelay: true)
        defer { fixture.controller.releaseStatusItemsForTesting() }

        let relevantIDs = Set([
            "codexOfficialGroupHeader",
            "menuCard-0",
            "menuCard-1",
            "codexAPIGroupHeader",
            "codexRelaySummary",
            "codexOfficialUsageSummary",
            "codexStackedTotal",
        ])
        let observedOrder = fixture.menu.items.compactMap { item -> String? in
            guard let id = item.representedObject as? String, relevantIDs.contains(id) else { return nil }
            return id
        }

        #expect(observedOrder == [
            "codexOfficialGroupHeader",
            "menuCard-0",
            "menuCard-1",
            "codexAPIGroupHeader",
            "codexRelaySummary",
            "codexStackedTotal",
        ])
    }

    @Test
    func `official group submenu contains official accounts only`() throws {
        let fixture = try self.makeFixture(includeRelay: true)
        defer { fixture.controller.releaseStatusItemsForTesting() }

        let officialHeader = try #require(fixture.menu.items.first {
            $0.representedObject as? String == "codexOfficialGroupHeader"
        })
        let officialMenu = try #require(officialHeader.submenu)
        let titles = officialMenu.items.filter { !$0.isSeparatorItem }.map(\.title)

        #expect(titles == ["alpha@example.com", "beta@example.com"])
        #expect(!titles.contains(L("spend_diagnostic_system_unassigned")))
        #expect(!titles.contains(where: { $0.hasPrefix("API ") || $0.hasPrefix("API ·") }))
    }

    @Test
    func `legacy codex accounts and API footer submenu is removed`() throws {
        let fixture = try self.makeFixture(includeRelay: true)
        defer {
            fixture.settings._test_liveSystemCodexAccount = nil
            fixture.controller.releaseStatusItemsForTesting()
        }
        fixture.settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            codexHomePath: "/tmp/seventh-round-q4-codex-home",
            observedAt: Date())

        let descriptor = fixture.controller.makeMenuDescriptor(
            provider: .codex,
            includeContextualActions: true)
        let containsLegacySubmenu = descriptor.sections.flatMap(\.entries).contains { entry in
            guard case let .submenu(title, _, _) = entry else { return false }
            return title == "Codex 账号与 API"
        }

        #expect(!containsLegacySubmenu)
    }

    private func makeFixture(
        includeRelay: Bool,
        accountCostsOverride: [CostUsageTokenSnapshot?]? = nil,
        includesUnassignedSnapshot: Bool = true,
        fullCorpusSnapshot: CostUsageTokenSnapshot? = nil) throws -> Fixture
    {
        let settings = self.makeSettings()
        let fetcher = UsageFetcher(environment: [:])
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system,
            menuCardRenderingEnabled: true,
            menuRefreshEnabled: false,
            observeProviderConfigNotifications: false)
        controller.relayQuickSwitchCoordinator = try self.makeRelayCoordinator(includeRelay: includeRelay)

        let accounts = Self.accounts()
        let accountSnapshots = accounts.enumerated().map { index, account in
            CodexAccountUsageSnapshot(
                account: account,
                snapshot: Self.usageSnapshot(email: account.email, percent: Double(20 + index * 10)),
                error: nil,
                sourceLabel: "test")
        }
        let display = CodexAccountMenuDisplay(
            accounts: accounts,
            snapshots: accountSnapshots,
            activeVisibleAccountID: accounts[0].id,
            layout: .stacked)
        let defaultAccountCosts = [
            Self.costSnapshot(tokens: 1_250_000, cost: 7.50),
            Self.costSnapshot(tokens: 2_500_000, cost: 13.25),
        ]
        let accountCosts = accountCostsOverride ?? defaultAccountCosts.map(Optional.some)
        var costsByAccountID: [String: CostUsageTokenSnapshot] = [:]
        for (account, cost) in zip(accounts, accountCosts) {
            if let cost {
                costsByAccountID[account.id] = cost
            }
        }
        if includesUnassignedSnapshot {
            costsByAccountID["system-unassigned:test"] = Self.costSnapshot(tokens: 375_000, cost: 2.25)
        }
        controller.codexMenuCostSnapshotsByAccountID = costsByAccountID
        controller.codexMenuFullCorpusCostSnapshot = fullCorpusSnapshot

        let menu = NSMenu()
        let context = StatusItemController.MenuCardContext(
            currentProvider: .codex,
            selectedProvider: .codex,
            menuWidth: StatusItemController.menuCardBaseWidth,
            codexAccountDisplay: display,
            tokenAccountDisplay: nil,
            openAIContext: StatusItemController.OpenAIWebContext(
                hasUsageBreakdown: false,
                hasCreditsHistory: false,
                hasCostHistory: false,
                canShowBuyCredits: false,
                hasOpenAIWebMenuItems: false))
        controller.addStackedCodexMenuCards(display, to: menu, context: context)

        let expectedUsageLines = accountCosts.compactMap { snapshot in
            snapshot.map {
                CodexStackedUsageSummary.line(
                    $0.rolling24Hours,
                    preferredCurrencyCode: settings.preferredCurrencyCode,
                    emptyText: "unused")
            }
        }
        return Fixture(
            controller: controller,
            settings: settings,
            menu: menu,
            expectedUsageLines: expectedUsageLines)
    }

    private func accountCardModel(id: String, in menu: NSMenu) throws -> CodexAccountSummaryCardModel {
        let item = try #require(menu.items.first { $0.representedObject as? String == id })
        let hosting = try #require(item.view as? AccountCardHostingView)
        return hosting.rootView.content().model
    }

    private func makeSettings() -> SettingsStore {
        let suite = "SeventhRoundQ4AccountGroupingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: "providerDetectionCompleted")
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.multiAccountMenuLayout = .stacked
        settings.costUsageEnabled = true
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .codex)
        }
        return settings
    }

    private func makeRelayCoordinator(includeRelay: Bool) throws -> RelayQuickSwitchCoordinator {
        let profiles: [RelayProfile]
        if includeRelay {
            let baseURL = try #require(URL(string: "https://relay.invalid/v1"))
            let profileID = UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF") ?? UUID()
            profiles = [RelayProfile(
                id: profileID,
                name: "Test Relay",
                baseURL: baseURL,
                apiFormat: .openAIResponses,
                credentialReference: RelayCredentialReference.make(for: profileID),
                credentialConfigured: true,
                targets: [.init(app: .codex, model: "test-model")])]
        } else {
            profiles = []
        }
        let actions = RelaySettingsActions(
            loadProfiles: { profiles },
            storeProfiles: { _ in },
            loadCredential: { _ in "fixture-key" },
            storeCredential: { _, _ in },
            removeCredential: { _ in },
            captureBaseline: { throw FixtureError.unused },
            applyProfile: { _ in throw FixtureError.unused },
            restoreBaseline: { _ in throw FixtureError.unused },
            restoreBaselineForTargets: nil,
            discardBackup: { _ in },
            loadActivationState: { nil },
            storeActivationState: { _ in },
            clearActivationState: {},
            loadUnifiedHistoryEnabled: { true },
            loadUnifiedHistoryOptIn: { true },
            storeUnifiedHistoryOptIn: { _ in },
            hasCodexHistory: { false },
            isCodexLoggedIn: { true },
            enableUnifiedHistory: { throw FixtureError.unused },
            loadUsageSummary: { _ in nil },
            storeUsageSummary: { _, _ in },
            fetchUsageSummary: { _, _ in throw FixtureError.unused })
        return RelayQuickSwitchCoordinator(actions: actions)
    }

    private static func accounts() -> [CodexVisibleAccount] {
        let managedID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE") ?? UUID()
        return [
            CodexVisibleAccount(
                id: "official-alpha",
                email: "alpha@example.com",
                storedAccountID: nil,
                selectionSource: .liveSystem,
                isActive: true,
                isLive: true,
                canReauthenticate: true,
                canRemove: false),
            CodexVisibleAccount(
                id: "official-beta",
                email: "beta@example.com",
                storedAccountID: managedID,
                selectionSource: .managedAccount(id: managedID),
                isActive: false,
                isLive: false,
                canReauthenticate: true,
                canRemove: true),
        ]
    }

    private static func usageSnapshot(email: String, percent: Double) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: percent,
                windowMinutes: 300,
                resetsAt: Date().addingTimeInterval(300),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: percent,
                windowMinutes: 10080,
                resetsAt: Date().addingTimeInterval(86400),
                resetDescription: nil),
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: email,
                accountOrganization: nil,
                loginMethod: "Plus"))
    }

    private static func costSnapshot(tokens: Int, cost: Double) -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: tokens,
            sessionCostUSD: cost,
            last30DaysTokens: tokens,
            last30DaysCostUSD: cost,
            rolling24Hours: CostUsageRolling24HourSummary(
                totalTokens: tokens,
                costUSD: cost,
                modelProviderBreakdowns: [CostUsageModelProviderBreakdown(
                    modelProvider: CodexStackedUsageSummary.officialModelProvider,
                    totalTokens: tokens,
                    costUSD: cost)]),
            daily: [],
            updatedAt: Date())
    }
}

private typealias AccountCardHostingView =
    MenuCardItemHostingView<MenuCardSectionContainerView<CodexAccountSummaryCardView>>
private typealias StackedTotalHostingView =
    MenuCardItemHostingView<MenuCardSectionContainerView<CodexStackedTotalUsageView>>

@MainActor
private struct Fixture {
    let controller: StatusItemController
    let settings: SettingsStore
    let menu: NSMenu
    let expectedUsageLines: [String]
}

private enum FixtureError: Error {
    case unused
}
