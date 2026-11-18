import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct EighthRoundR2R3MenuTests {
    @Test
    func `card group status chooses the latest displayed update`() {
        let oldest = Date(timeIntervalSince1970: 100)
        let newestAccount = Date(timeIntervalSince1970: 300)
        let relay = Date(timeIntervalSince1970: 200)

        #expect(CodexCardGroupStatusPresentation.latestUpdatedAt(
            fullCorpusUpdatedAt: oldest,
            accountUpdatedAts: [nil, newestAccount],
            relayUpdatedAt: relay) == newestAccount)
        #expect(CodexCardGroupStatusPresentation.latestUpdatedAt(
            fullCorpusUpdatedAt: nil,
            accountUpdatedAts: [],
            relayUpdatedAt: nil) == nil)
    }

    @Test
    @MainActor
    func `card group status keeps fixed geometry while refreshing`() {
        #expect(CodexCardGroupStatusPresentation.height > 0)
        #expect(CodexCardGroupStatusPresentation.refreshButtonSize > 0)
        #expect(CodexCardGroupStatusPresentation.height(isRefreshing: false)
            == CodexCardGroupStatusPresentation.height(isRefreshing: true))
        #expect(CodexCardGroupStatusPresentation.statusText(updatedAt: nil)
            == L("codex_card_group_not_updated"))
        #expect(MenuCardHeightFingerprint.codexCardGroupStatus(
            height: CodexCardGroupStatusPresentation.height(isRefreshing: false),
            refreshButtonSize: CodexCardGroupStatusPresentation.refreshButtonSize)
            == MenuCardHeightFingerprint.codexCardGroupStatus(
                height: CodexCardGroupStatusPresentation.height(isRefreshing: true),
                refreshButtonSize: CodexCardGroupStatusPresentation.refreshButtonSize))
    }

    @Test
    @MainActor
    func `card group refresh runs codex then displayed relay and rebuilds once`() async {
        let relayID = UUID()
        var events: [String] = []

        await CodexCardGroupRefreshOrchestrator.run(
            relayProfileID: relayID,
            refreshCodex: { events.append("codex") },
            refreshRelay: { id in events.append("relay:\(id.uuidString)") },
            rebuildMenu: { events.append("rebuild") })

        #expect(events == ["codex", "relay:\(relayID.uuidString)", "rebuild"])

        events.removeAll()
        await CodexCardGroupRefreshOrchestrator.run(
            relayProfileID: nil,
            refreshCodex: { events.append("codex") },
            refreshRelay: { _ in events.append("relay") },
            rebuildMenu: { events.append("rebuild") })
        #expect(events == ["codex", "rebuild"])
    }

    @Test
    func `stacked card group owns the only refresh entry point above official accounts`() throws {
        let sources = Self.sourceRoot()
        let stacked = try String(contentsOf: sources.appendingPathComponent(
            "StatusItemController+CodexStackedMenu.swift"), encoding: .utf8)
        let accountCard = try String(contentsOf: sources.appendingPathComponent(
            "CodexAccountSummaryCardView.swift"), encoding: .utf8)
        let relayCard = try String(contentsOf: sources.appendingPathComponent(
            "CodexRelaySummaryCardView.swift"), encoding: .utf8)

        let statusIndex = try #require(stacked.range(of: "id: \"codexCardGroupStatus\"")?.lowerBound)
        let officialIndex = try #require(stacked.range(of: "id: \"codexOfficialGroupHeader\"")?.lowerBound)
        #expect(statusIndex < officialIndex)
        #expect(!accountCard.contains("CardGroupRefreshButton"))
        #expect(!accountCard.contains("let onRefresh:"))
        #expect(!relayCard.contains("CardGroupRefreshButton"))
        #expect(!relayCard.contains("let onRefresh:"))
    }

    @Test
    func `single target quick switch removes its standalone target label`() {
        let single = RelayQuickSwitchPresentation(visibleTargets: [.codex])
        let overview = RelayQuickSwitchPresentation(visibleTargets: RelayTargetApp.headroomManagedTargets)

        #expect(!single.showsTargetLabels)
        #expect(single.targetLabelWidth == 0)
        #expect(overview.showsTargetLabels)
        #expect(overview.targetLabelWidth == 56)
        #expect(RelayQuickSwitchPresentation.interitemSpacing == 6)
        #expect(RelayQuickSwitchPresentation.verticalPadding == 6)
        #expect(RelayQuickSwitchPresentation.followingSectionGap <= 10)
    }

    @Test
    func `quick switch feedback only contributes height when it has a message`() {
        #expect(RelayQuickSwitchFeedback.height(message: nil) == 0)
        #expect(RelayQuickSwitchFeedback.height(message: "   ") == 0)
        #expect(RelayQuickSwitchFeedback.height(message: "Needs attention") > 0)
        var whitespaceFeedback = RelayQuickSwitchFeedback()
        whitespaceFeedback.record(RelayQuickSwitchOutcome(
            succeeded: false,
            selection: .official(.codex),
            message: "   "))
        #expect(whitespaceFeedback.displayMessage == nil)

        let empty = MenuCardHeightFingerprint.relayQuickSwitch(
            baseFingerprint: "same",
            visibleTargetCount: 1,
            optionRowCounts: [1],
            showsLoadError: false,
            feedbackMessage: nil)
        let message = MenuCardHeightFingerprint.relayQuickSwitch(
            baseFingerprint: "same",
            visibleTargetCount: 1,
            optionRowCounts: [1],
            showsLoadError: false,
            feedbackMessage: "Needs attention")
        let differentMessage = MenuCardHeightFingerprint.relayQuickSwitch(
            baseFingerprint: "same",
            visibleTargetCount: 1,
            optionRowCounts: [1],
            showsLoadError: false,
            feedbackMessage: "Different details")

        #expect(empty != message)
        #expect(message == differentMessage)
        #expect(!message.contains("Needs attention"))
    }

    @Test
    func `successful switch keeps the open menu alive when it carries a migration warning`() {
        let warning = RelayQuickSwitchOutcome(
            succeeded: true,
            selection: .official(.codex),
            message: "Switched",
            warning: "History migration failed")
        let cleanSuccess = RelayQuickSwitchOutcome(
            succeeded: true,
            selection: .official(.codex),
            message: "Switched")

        #expect(!RelayQuickSwitchPresentation.shouldRebuildMenu(after: warning))
        #expect(RelayQuickSwitchPresentation.shouldRebuildMenu(after: cleanSuccess))
    }

    @Test
    func `relay usage card profile selection persists display only choice`() throws {
        let (defaults, suiteName) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = Self.option(name: "First")
        let second = Self.option(name: "Second")

        var selection = RelayUsageCardProfileSelection(
            options: [first, second],
            activeProfileID: first.id,
            defaults: defaults)
        #expect(selection.selectedProfileID == first.id)
        #expect(selection.showsSelector)

        selection.select(second.id)

        #expect(defaults.string(forKey: RelayUsageCardProfileSelection.defaultsKey) == second.id.uuidString)
        #expect(selection.selectedProfileID == second.id)
        #expect(selection.activeProfileID == first.id)
        #expect(defaults.dictionaryRepresentation().keys.contains("menu.relayUsageCardProfileID"))
    }

    @Test
    func `relay usage card selector hides for one candidate and rejects stale stored IDs`() throws {
        let (defaults, suiteName) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let only = Self.option(name: "Only")
        defaults.set(UUID().uuidString, forKey: RelayUsageCardProfileSelection.defaultsKey)

        let selection = RelayUsageCardProfileSelection(
            options: [only],
            activeProfileID: nil,
            defaults: defaults)

        #expect(!selection.showsSelector)
        #expect(selection.selectedProfileID == only.id)
    }

    @Test
    func `usage card candidates include every profile with usage queries enabled`() throws {
        let queryOnly = try Self.profile(name: "Query only", usageQueryMode: .sub2API, enablesCodex: false)
        let generic = try Self.profile(name: "Generic", usageQueryMode: .genericBalance, enablesCodex: false)
        let custom = try Self.profile(name: "Custom", usageQueryMode: .customBalance, enablesCodex: false)
        let disabled = try Self.profile(name: "Disabled", usageQueryMode: .disabled, enablesCodex: true)

        #expect(RelayUsageCardProfileSelection.candidateProfiles(
            from: [queryOnly, disabled, generic, custom]).map(\.id) == [queryOnly.id, generic.id, custom.id])
    }

    @Test
    func `relay usage selector has bounded single line label and localized display only help`() throws {
        #expect(RelayUsageCardSelectorPresentation.labelWidth > 0)
        #expect(RelayUsageCardSelectorPresentation.labelWidth <= 120)
        #expect(RelayUsageCardSelectorPresentation.lineLimit == 1)
        #expect(RelayUsageCardSelectorPresentation.helpKey == "relay_usage_card_selector_help")

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let resources = root.appendingPathComponent("Sources/CodexBar/Resources")
        let localeURLs = try FileManager.default.contentsOfDirectory(
            at: resources,
            includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "lproj" }
        #expect(localeURLs.count == 2)
        for localeURL in localeURLs {
            let catalogURL = localeURL.appendingPathComponent("Localizable.strings")
            let catalog = try #require(NSDictionary(contentsOf: catalogURL) as? [String: String])
            #expect(
                catalog[RelayUsageCardSelectorPresentation.helpKey]?.isEmpty == false,
                "\(localeURL.lastPathComponent).relay_usage_card_selector_help")
            #expect(
                catalog["relay_usage_card_missing_credential"]?.isEmpty == false,
                "\(localeURL.lastPathComponent).relay_usage_card_missing_credential")
        }
        let simplifiedChinese = try #require(localeURLs.first { $0.lastPathComponent == "zh-Hans.lproj" })
        let simplifiedCatalog = try #require(NSDictionary(
            contentsOf: simplifiedChinese.appendingPathComponent("Localizable.strings")) as? [String: String])
        #expect(simplifiedCatalog[RelayUsageCardSelectorPresentation.helpKey]
            == "只切换显示，不切换实际使用的中转站")
        #expect(simplifiedCatalog["relay_usage_card_missing_credential"] == "请先保存 API Key。")
    }

    @Test
    func `card group status copy is present in every localization`() throws {
        let resources = Self.sourceRoot().appendingPathComponent("Resources", isDirectory: true)
        let localeURLs = try FileManager.default.contentsOfDirectory(
            at: resources,
            includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "lproj" }
        let keys = [
            "codex_card_group_not_updated",
            "codex_card_group_refresh",
            "codex_card_group_refresh_help",
        ]

        #expect(localeURLs.count == 2)
        for localeURL in localeURLs {
            let catalog = try #require(NSDictionary(
                contentsOf: localeURL.appendingPathComponent("Localizable.strings")) as? [String: String])
            for key in keys {
                #expect(catalog[key]?.isEmpty == false, "\(localeURL.lastPathComponent).\(key)")
            }
        }
    }

    @Test
    func `missing relay usage is presented once without an orphan dash`() {
        let model = CodexRelaySummaryCardModel(
            name: "Relay",
            isActive: false,
            isReady: true,
            blocker: nil,
            usageLine: "No usage returned",
            usageSummary: nil)

        #expect(model.inlineUnavailableUsageLine == "No usage returned")
        #expect(model.footerUsageLine == nil)
        #expect(model.inlineUnavailableUsageLine != "—")
    }

    @Test
    func `unsupported relay protocol card names local metering unavailable instead of zero`() {
        let model = CodexRelaySummaryCardModel(
            name: "Anthropic Relay",
            isActive: false,
            isReady: true,
            blocker: nil,
            usageLine: "0",
            usageSummary: nil,
            usageTriad: Self.unsupportedRelayUsageTriad(),
            apiFormat: .anthropicMessages)

        #expect(model.subtitleLine == L("local_meter_protocol_unsupported"))
        #expect(model.inlineUnavailableUsageLine == L("local_meter_protocol_unsupported"))
        #expect(model.inlineUnavailableUsageLine != "0")
    }

    @Test
    func `unsupported relay protocol never shows a local zero in the card footer`() {
        let model = CodexRelaySummaryCardModel(
            name: "Anthropic Relay",
            isActive: false,
            isReady: true,
            blocker: nil,
            usageLine: "0",
            usageSummary: RelayUsageSummary(
                remaining: 1,
                used: 0,
                total: 1,
                unit: "USD",
                planName: "Fixture",
                updatedAt: Date()),
            usageTriad: Self.unsupportedRelayUsageTriad(),
            apiFormat: .anthropicMessages)

        #expect(model.footerUsageLine == L("local_meter_protocol_unsupported"))
        #expect(model.footerUsageLine != "0")
    }

    private static func unsupportedRelayUsageTriad() -> RelayUsageTriadPresentation {
        RelayUsageTriadPresentation.resolve(
            localSnapshot: nil,
            providerSummary: nil,
            apiFormat: .anthropicMessages,
            preferredCurrencyCode: "USD",
            localMeterStatus: .unsupported)
    }

    @Test
    @MainActor
    func `card detail rail keeps its reserved geometry after visible adornments are removed`() {
        #expect(CardDetailRail.width == 30)
        #expect(CardDetailRail.borderWidth == 1)
        #expect(CardDetailRail.renderingFingerprint == "detailRail=plain-v1")
    }

    @Test
    func `relay snapshot refresh loads aggregate and profiles concurrently`() async {
        let profileIDs: Set<UUID> = [UUID(), UUID()]
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 1,
            sessionCostUSD: 0.01,
            last30DaysTokens: 1,
            last30DaysCostUSD: 0.01,
            rolling24Hours: .init(totalTokens: 1, costUSD: 0.01),
            daily: [],
            updatedAt: Date())
        let probe = RelaySnapshotConcurrencyProbe()

        let result = await CodexRelayMenuSnapshots.loadConcurrently(
            profileIDs: profileIDs,
            loadAggregate: {
                await probe.begin()
                try? await Task.sleep(for: .milliseconds(30))
                await probe.end()
                return snapshot
            },
            loadProfile: { _ in
                await probe.begin()
                try? await Task.sleep(for: .milliseconds(30))
                await probe.end()
                return snapshot
            })

        #expect(result.aggregate == snapshot)
        #expect(result.byProfileID.count == profileIDs.count)
        #expect(await probe.maximumInFlight == profileIDs.count + 1)
    }

    private static let defaultsSuite = "EighthRoundR2R3MenuTests"

    private static func sourceRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CodexBar", isDirectory: true)
    }

    private static func defaults() throws -> (UserDefaults, String) {
        let suiteName = "\(Self.defaultsSuite).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private static func option(name: String) -> RelayQuickSwitchOption {
        RelayQuickSwitchOption(id: UUID(), name: name, isReady: true, blocker: nil)
    }

    private static func profile(
        name: String,
        usageQueryMode: RelayUsageQueryMode,
        enablesCodex: Bool) throws -> RelayProfile
    {
        try RelayProfile(
            name: name,
            baseURL: #require(URL(string: "https://relay.example/v1")),
            apiFormat: .openAIResponses,
            credentialReference: UUID().uuidString,
            credentialConfigured: true,
            usageQueryMode: usageQueryMode,
            targets: [.init(app: .codex, model: "test-model", isEnabled: enablesCodex)])
    }
}

private actor RelaySnapshotConcurrencyProbe {
    private var inFlight = 0
    private(set) var maximumInFlight = 0

    func begin() {
        self.inFlight += 1
        self.maximumInFlight = max(self.maximumInFlight, self.inFlight)
    }

    func end() {
        self.inFlight -= 1
    }
}
