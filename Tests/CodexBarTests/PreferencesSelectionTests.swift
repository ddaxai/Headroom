import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct PreferencesSelectionTests {
    @Test
    func `top-level settings destinations keep the five-column order and defaults`() {
        #expect(SettingsDestination.allCases == [
            .general,
            .accountsAndAPIs,
            .usageAndCost,
            .appearance,
            .about,
        ])
        #expect(SettingsDestination.general.defaultPane == .general)
        #expect(SettingsDestination.accountsAndAPIs.defaultPane == .providers)
        #expect(SettingsDestination.usageAndCost.defaultPane == .usageSpend)
        #expect(SettingsDestination.appearance.defaultPane == .menuBar)
        #expect(SettingsDestination.about.defaultPane == .about)
        #expect(SettingsDestination.allCases.allSatisfy { !$0.title.isEmpty })
    }

    @Test
    func `leaf panes map to their five-column destination`() {
        let cases: [(SettingsPane, SettingsDestination)] = [
            (.general, .general),
            (.advanced, .general),
            (.hooks, .general),
            (.debug, .general),
            (.providers, .accountsAndAPIs),
            (.relay, .accountsAndAPIs),
            (.provider(.claude), .accountsAndAPIs),
            (.usageSpend, .usageAndCost),
            (.notifications, .usageAndCost),
            (.menuBar, .appearance),
            (.menu, .appearance),
            (.update, .about),
            (.about, .about),
        ]

        for (pane, destination) in cases {
            #expect(pane.destination == destination)
        }
    }

    @Test
    func `hidden panes normalize to a regular five-column route`() {
        let cases: [(SettingsPane, SettingsPane)] = [
            (.general, .general),
            (.providers, .providers),
            (.relay, .relay),
            (.usageSpend, .usageSpend),
            (.menuBar, .menuBar),
            (.about, .about),
            (.notifications, .usageSpend),
            (.menu, .menuBar),
            (.provider(.claude), .providers),
            (.advanced, .general),
            (.hooks, .general),
            (.debug, .general),
            (.update, .about),
        ]

        for (pane, regularPane) in cases {
            #expect(pane.regularPane == regularPane)
        }

        let regularPanes: [SettingsPane] = [.general, .providers, .relay, .usageSpend, .menuBar, .about]
        #expect(regularPanes.allSatisfy { pane in pane.isRegularlyReachable == true })
        let hiddenPanes: [SettingsPane] = [
            .notifications,
            .menu,
            .provider(.claude),
            .advanced,
            .hooks,
            .debug,
            .update,
        ]
        #expect(hiddenPanes.allSatisfy { !$0.isRegularlyReachable })

        #expect(SettingsPane.advanced.isOptionOnly)
        #expect(SettingsPane.hooks.isOptionOnly)
        #expect(SettingsPane.debug.isOptionOnly)
        #expect(!SettingsPane.update.isOptionOnly)
    }

    @Test
    func `pane persistence tokens round-trip`() {
        let panes: [SettingsPane] = [
            .general,
            .usageSpend,
            .providers,
            .relay,
            .notifications,
            .menuBar,
            .advanced,
            .update,
            .about,
        ]
        for pane in panes {
            #expect(SettingsPane(persistenceToken: pane.persistenceToken) == pane)
        }
        #expect(SettingsPane(persistenceToken: "provider:definitely-not-a-provider") == nil)
        #expect(SettingsPane(persistenceToken: "") == nil)
    }

    @Test
    func `legacy display token restores the menu bar pane`() {
        #expect(SettingsPane(persistenceToken: "display") == .menuBar)
        #expect(SettingsPane(persistenceToken: "menu") == .menuBar)
        #expect(SettingsPane(persistenceToken: "hooks") == .advanced)
        #expect(SettingsPane(persistenceToken: "debug") == .advanced)
        #expect(SettingsPane(persistenceToken: "provider:claude") == .providers)
        #expect(SettingsPane(persistenceToken: "display")?.destination == .appearance)
        #expect(SettingsPane(persistenceToken: "hooks")?.destination == .general)
        #expect(SettingsPane(persistenceToken: "provider:claude")?.destination == .accountsAndAPIs)
    }

    @Test
    func `selection restores persisted pane and saves changes`() throws {
        let suite = "PreferencesSelectionTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(PreferencesSelection(userDefaults: defaults).pane == .general)

        let selection = PreferencesSelection(userDefaults: defaults)
        selection.pane = .providers
        #expect(defaults.string(forKey: PreferencesSelection.paneDefaultsKey) == "providers")
        #expect(PreferencesSelection(userDefaults: defaults).pane == .providers)
    }

    @Test
    func `persisted hidden panes cannot bypass regular navigation`() throws {
        let cases: [(String, SettingsPane)] = [
            ("advanced", .general),
            ("hooks", .general),
            ("debug", .general),
            ("update", .about),
            ("notifications", .usageSpend),
            ("menu", .menuBar),
            ("provider:claude", .providers),
        ]

        for (token, expectedPane) in cases {
            let suite = "PreferencesSelectionTests-hidden-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(token, forKey: PreferencesSelection.paneDefaultsKey)

            #expect(PreferencesSelection(userDefaults: defaults).pane == expectedPane)
        }
    }

    @Test
    func `usage spend focus request selects the pane and remains transient`() throws {
        let suite = "PreferencesSelectionTests-focus-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let selection = PreferencesSelection(userDefaults: defaults)

        selection.requestUsageSpendFocus(.systemUnassigned)

        #expect(selection.pane == .usageSpend)
        #expect(selection.usageSpendFocusTarget == .systemUnassigned)
        #expect(defaults.object(forKey: "usageSpendFocusTarget") == nil)
        selection.consumeUsageSpendFocus(.systemUnassigned)
        #expect(selection.usageSpendFocusTarget == nil)
    }
}
