import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct CodexSystemPromotionUITests {
    @Test
    func `promotion coordinator promotes immediately`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexSystemPromotionUITests-coordinator-immediate")
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "managed@example.com",
            authAccountID: "acct-managed")
        try container.persistAccounts([target])
        _ = try container.writeLiveOAuthAuthFile(email: "live@example.com", accountID: "acct-live")

        let managedVisibleAccountID = try #require(container.settings.codexVisibleAccountProjection.visibleAccounts
            .first(where: { $0.storedAccountID == target.id })?
            .id)
        let coordinator = CodexAccountPromotionCoordinator(service: container.makeService())

        let result = await coordinator.promote(managedAccountID: target.id)

        let promotionResult: CodexAccountPromotionResult
        switch result {
        case let .success(value):
            promotionResult = value
        case let .failure(error):
            Issue.record("Expected successful promotion, got \(error)")
            throw PromotionTestError.unexpectedDisposition
        }

        #expect(promotionResult.outcome == .promoted)
        #expect(container.settings.codexActiveSource == .liveSystem)
        #expect(container.settings.codexVisibleAccountProjection.liveVisibleAccountID == managedVisibleAccountID)
        #expect(coordinator.userFacingError == nil)
    }

    @Test
    func `promotion coordinator blocks while live reauthentication is running`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexSystemPromotionUITests-coordinator-live-reauth")
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "managed@example.com",
            authAccountID: "acct-managed")
        try container.persistAccounts([target])
        _ = try container.writeLiveOAuthAuthFile(email: "live@example.com", accountID: "acct-live")
        container.settings.codexActiveSource = .managedAccount(id: target.id)

        let coordinator = CodexAccountPromotionCoordinator(service: container.makeService())
        coordinator.setLiveReauthenticationInProgress(true)

        let result = await coordinator.promote(managedAccountID: target.id)

        let error: CodexSystemAccountPromotionUserFacingError
        switch result {
        case .success:
            Issue.record("Expected blocked promotion while live reauthentication is running")
            throw PromotionTestError.unexpectedDisposition
        case let .failure(value):
            error = value
        }

        #expect(error.title == "Could not switch system account")
        #expect(error.message == "Finish the current managed account change before switching the system account.")
        #expect(coordinator.userFacingError == error)
        #expect(coordinator.isInteractionBlocked())
        #expect(container.settings.codexActiveSource == .managedAccount(id: target.id))
    }

    @Test
    func `codex menu descriptor includes system account submenu`() throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexSystemPromotionUITests-menu-descriptor")
        defer { container.tearDown() }

        let managedAccountID = UUID()
        let managedAccount = try container.createManagedAccount(
            id: managedAccountID,
            persistedEmail: "managed@example.com",
            authAccountID: "acct-managed")
        try container.persistAccounts([managedAccount])
        container.settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: container.liveHomeURL.path,
            observedAt: Date())

        let controller = self.makeController(container: container)
        defer { controller.releaseStatusItemsForTesting() }
        let projection = container.settings.codexVisibleAccountProjection
        let display = CodexAccountMenuDisplay(
            accounts: projection.visibleAccounts,
            snapshots: [],
            activeVisibleAccountID: projection.activeVisibleAccountID,
            layout: .stacked)
        let items = controller.codexOfficialAccountSubmenuItems(display: display)

        #expect(items.map(\.title) == ["live@example.com", "managed@example.com"])
        #expect(items.count == 2)
        #expect(items[0].isChecked)
        #expect(items[0].isEnabled == false)
        #expect(items[0].action == nil)
        #expect(items[1].isChecked == false)
        #expect(items[1].isEnabled)
        #expect(items[1].action == .requestCodexSystemPromotion(managedAccountID))
    }

    @Test
    func `official account submenu follows the live system account instead of the active usage account`() throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexSystemPromotionUITests-menu-live-vs-active")
        defer { container.tearDown() }

        let managedAccountID = UUID()
        let managedAccount = try container.createManagedAccount(
            id: managedAccountID,
            persistedEmail: "managed@example.com",
            authAccountID: "acct-managed")
        try container.persistAccounts([managedAccount])
        container.settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: container.liveHomeURL.path,
            observedAt: Date())
        container.settings.codexActiveSource = .managedAccount(id: managedAccountID)

        let controller = self.makeController(container: container)
        defer { controller.releaseStatusItemsForTesting() }
        let projection = container.settings.codexVisibleAccountProjection
        let display = CodexAccountMenuDisplay(
            accounts: projection.visibleAccounts,
            snapshots: [],
            activeVisibleAccountID: projection.activeVisibleAccountID,
            layout: .stacked)
        let items = controller.codexOfficialAccountSubmenuItems(display: display)

        let liveItem = try #require(items.first { $0.title == "live@example.com" })
        let managedItem = try #require(items.first { $0.title == "managed@example.com" })
        #expect(projection.activeVisibleAccountID != projection.liveVisibleAccountID)
        #expect(liveItem.isChecked)
        #expect(!liveItem.isEnabled)
        #expect(liveItem.action == nil)
        #expect(!managedItem.isChecked)
        #expect(managedItem.isEnabled)
        #expect(managedItem.action == .requestCodexSystemPromotion(managedAccountID))
    }

    @Test
    func `codex source submenu includes saved relay API`() throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexSystemPromotionUITests-menu-relay")
        defer { container.tearDown() }

        container.settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: container.liveHomeURL.path,
            observedAt: Date())
        let profileID = UUID()
        let controller = self.makeController(container: container)
        defer { controller.releaseStatusItemsForTesting() }
        let projection = container.settings.codexVisibleAccountProjection
        let display = CodexAccountMenuDisplay(
            accounts: projection.visibleAccounts,
            snapshots: [],
            activeVisibleAccountID: projection.activeVisibleAccountID,
            layout: .stacked)
        let relaySnapshot = RelayQuickSwitchSnapshot(
            optionsByTarget: [
                .codex: [RelayQuickSwitchOption(
                    id: profileID,
                    name: "tab",
                    isReady: true,
                    blocker: nil)],
            ],
            selectionByTarget: [.codex: .profile(.codex, profileID)],
            activeProfileIDsByTarget: [.codex: profileID],
            currentLabel: "tab",
            hasActiveRelay: true,
            canRestoreOfficial: true,
            loadError: nil)
        let items = controller.codexOfficialAccountSubmenuItems(
            display: display,
            relaySnapshot: relaySnapshot)

        #expect(items.map(\.title) == ["live@example.com"])
        #expect(items[0].action == .restoreCodexOfficialConfiguration)
        #expect(items[0].isEnabled)
        #expect(!items[0].isChecked)
    }

    @Test
    func `codex menu display keeps single live system account for ambient usage`() throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexSystemPromotionUITests-menu-single-live")
        defer { container.tearDown() }

        container.settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: container.liveHomeURL.path,
            observedAt: Date())

        let controller = self.makeController(container: container)
        defer { controller.releaseStatusItemsForTesting() }

        let display = try #require(controller.codexAccountMenuDisplay(for: .codex))
        #expect(display.accounts.count == 1)
        #expect(display.accounts[0].email == "live@example.com")
        #expect(display.accounts[0].isLive)
        #expect(display.layout == .stacked)
    }

    private func makeController(container: CodexAccountPromotionTestContainer) -> StatusItemController {
        StatusItemController(
            store: container.usageStore,
            settings: container.settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            managedCodexAccountCoordinator: ManagedCodexAccountCoordinator(),
            codexAccountPromotionCoordinator: CodexAccountPromotionCoordinator(
                service: container.makeService()),
            statusBar: .system,
            menuCardRenderingEnabled: false,
            menuRefreshEnabled: false,
            observeProviderConfigNotifications: false)
    }
}
