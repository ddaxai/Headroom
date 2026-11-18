import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct RelayDefaultModelSettingsTests {
    @Test
    func `default model survives reload without filling blank target models`() throws {
        let recorder = RelaySettingsRecorder()
        let model = RelaySettingsModel(actions: recorder.actions)
        model.loadIfNeeded()
        model.name = "Per-target relay"
        model.baseURLText = "https://relay.example/v1"
        model.modelID = "shared-default"
        model.enabledTargets = [.codex, .openCode]
        model.setModelID("codex-model", for: .codex)
        model.setModelID("", for: .openCode)

        model.save()

        let stored = try #require(recorder.storedProfiles.last?.first)
        #expect(stored.defaultModel == "shared-default")
        #expect(stored.configuration(for: .codex)?.model == "codex-model")
        #expect(stored.configuration(for: .openCode)?.model == nil)

        recorder.profilesToLoad = [stored]
        let reloaded = RelaySettingsModel(actions: recorder.actions)
        reloaded.loadIfNeeded()

        #expect(reloaded.modelID == "shared-default")
        #expect(reloaded.modelID(for: .codex) == "codex-model")
        #expect(reloaded.modelID(for: .openCode) == "shared-default")
    }

    @Test
    func `visible target selection persists without changing enabled clients`() throws {
        let recorder = RelaySettingsRecorder()
        let model = RelaySettingsModel(actions: recorder.actions)
        model.loadIfNeeded()
        model.name = "Visible targets"
        model.baseURLText = "https://relay.example/v1"
        model.modelID = "shared-model"
        model.enabledTargets = [.codex, .openCode]
        model.visibleTargets = [.codex, .openCode, .piAgent]

        model.save()

        let stored = try #require(recorder.storedProfiles.last?.first)
        #expect(stored.visibleTargets == [.codex, .openCode, .piAgent])
        #expect(Set(stored.targets.filter(\.isEnabled).map(\.app)) == [.codex, .openCode])

        recorder.profilesToLoad = [stored]
        let reloaded = RelaySettingsModel(actions: recorder.actions)
        reloaded.loadIfNeeded()

        #expect(reloaded.visibleTargets == [.codex, .openCode, .piAgent])
        #expect(reloaded.enabledTargets == [.codex, .openCode])
    }

    @Test
    func `target activation distinguishes current other and official clients`() throws {
        let recorder = RelaySettingsRecorder()
        let currentID = UUID()
        let otherID = UUID()
        recorder.profilesToLoad = try [
            RelayProfile(
                id: currentID,
                name: "Current relay",
                baseURL: #require(URL(string: "https://current.example/v1")),
                apiFormat: .openAIResponses,
                credentialReference: RelayCredentialReference.make(for: currentID),
                targets: [.init(app: .codex, model: "codex-model")]),
            RelayProfile(
                id: otherID,
                name: "Other relay",
                baseURL: #require(URL(string: "https://other.example/v1")),
                apiFormat: .openAIResponses,
                credentialReference: RelayCredentialReference.make(for: otherID),
                targets: [.init(app: .openCode, model: "open-code-model")]),
        ]
        recorder.activationState = RelayActivationState(
            activeProfileIDsByTarget: [.codex: currentID, .openCode: otherID],
            baselineBackupDirectory: URL(fileURLWithPath: "/tmp/relay-baseline", isDirectory: true))
        let model = RelaySettingsModel(actions: recorder.actions)
        model.loadIfNeeded()

        #expect(model.isActiveProfile(currentID, for: .codex))
        #expect(model.activeProfileName(for: .codex) == "Current relay")
        #expect(!model.isActiveProfile(currentID, for: .openCode))
        #expect(model.activeProfileName(for: .openCode) == "Other relay")
        #expect(model.activeProfileName(for: .claudeCode) == nil)
    }

    @Test
    nonisolated func `relay editor presents configuration before history and removes active section`() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/CodexBar/PreferencesRelayPane.swift"),
            encoding: .utf8)
        let editor = try #require(
            source.split(separator: "private struct RelayProfileEditor: View", maxSplits: 1).last.map(String.init))
        let usageCard = try #require(editor.range(of: "RelayUsageSummaryCard(")?.lowerBound)
        let configuration = try #require(editor.range(of: #"Text("中转站配置")"#)?.lowerBound)
        let usage = try #require(editor.range(of: #"Text("中转站额度")"#)?.lowerBound)
        let targets = try #require(editor.range(of: #"Text("可用于")"#)?.lowerBound)
        let history = try #require(editor.range(of: #"Text("Codex 历史")"#)?.lowerBound)
        #expect(editor.contains("self.visibleTargetBinding(target)"))
        #expect(editor.contains("self.model.isTargetVisible($0)"))
        #expect(editor.contains(#"L("relay_visible_targets_toggle")"#))

        #expect(usageCard < configuration)
        #expect(configuration < usage)
        #expect(usage < targets)
        #expect(targets < history)
        #expect(!editor.contains(#"Text("当前生效")"#))
    }

    @Test
    nonisolated func `relay usage card owns refresh and quota section keeps configuration only`() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/CodexBar/PreferencesRelayPane.swift"),
            encoding: .utf8)
        let editor = try #require(
            source.split(separator: "private struct RelayProfileEditor: View", maxSplits: 1).last.map(String.init))
        let usageSectionStart = try #require(editor.range(of: #"Picker("额度接口""#)?.lowerBound)
        let usageSectionEnd = try #require(editor.range(of: #"Text("中转站额度")"#)?.upperBound)
        let usageConfiguration = String(editor[usageSectionStart..<usageSectionEnd])

        #expect(source.contains("private struct RelayUsageSummaryCard: View"))
        #expect(source.contains("RelayUsagePresentation.recentUsageLine"))
        #expect(source.contains("ConsoleSegmentedMeter(percent:"))
        #expect(!usageConfiguration.contains("refreshUsage"))
        #expect(!usageConfiguration.contains("usageSummary"))
        #expect(!usageConfiguration.contains(#"Label("查询额度""#))
    }

    @Test
    func `relay usage card status prioritizes active then saved readiness`() {
        #expect(RelayUsageSummaryCardStatus.resolve(isActive: true, isReady: false) == .active)
        #expect(RelayUsageSummaryCardStatus.resolve(isActive: true, isReady: true) == .active)
        #expect(RelayUsageSummaryCardStatus.resolve(isActive: false, isReady: true) == .saved)
        #expect(RelayUsageSummaryCardStatus.resolve(isActive: false, isReady: false) == .notReady)
    }

    @Test
    nonisolated func `relay editor exposes separate save and apply commands`() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/CodexBar/PreferencesRelayPane.swift"),
            encoding: .utf8)
        let editor = try #require(
            source.split(separator: "private struct RelayProfileEditor: View", maxSplits: 1).last.map(String.init))

        #expect(editor.contains(#"Button(L("relay_settings_save_action")) { self.model.save() }"#))
        #expect(editor.contains(
            #"Button(L("relay_settings_apply_action")) { self.model.applyToEnabledClients() }"#))
        #expect(L("relay_settings_save_action", language: "en") == "Save")
        #expect(L("relay_settings_apply_action", language: "en") == "Apply to clients")
        #expect(L("relay_settings_save_action", language: "zh-Hans") == "保存")
        #expect(L("relay_settings_apply_action", language: "zh-Hans") == "应用到客户端")
    }

    @Test
    nonisolated func `disabled relay usage card links to the usage interface picker`() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/CodexBar/PreferencesRelayPane.swift"),
            encoding: .utf8)

        #expect(source.contains(#"self.model.usageQueryMode == .disabled"#))
        #expect(source.contains(#"L("relay_usage_card_disabled")"#))
        #expect(source.contains(#"L("relay_usage_card_configure")"#))
        #expect(source.contains("proxy.scrollTo(Self.usageQueryPickerID"))
        #expect(source.contains(".focused(self.$focusedControl, equals: .usageQueryMode)"))
    }

    @Test
    nonisolated func `eighth round settings strings cover every shipped localization`() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let resources = root.appendingPathComponent("Sources/CodexBar/Resources", isDirectory: true)
        let localizations = try FileManager.default.contentsOfDirectory(
            at: resources,
            includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "lproj" }
        #expect(localizations.count == 2)

        let requiredKeys = [
            "relay_usage_card_title",
            "relay_usage_card_query",
            "relay_usage_card_query_help",
            "relay_usage_card_status_active",
            "relay_usage_card_status_saved",
            "relay_usage_card_status_not_ready",
            "relay_usage_card_untitled",
            "relay_usage_card_refreshing",
            "relay_usage_card_remaining",
            "relay_usage_card_no_values",
            "relay_usage_card_updated_at",
            "relay_usage_card_not_queried",
            "relay_usage_card_disabled",
            "relay_usage_card_configure",
            "settings_window_always_on_top",
            "settings_window_always_on_top_help",
            "relay_visible_targets_toggle",
            "relay_visible_targets_footer",
            "relay_visible_targets_empty",
        ]
        for localization in localizations {
            let contents = try String(
                contentsOf: localization.appendingPathComponent("Localizable.strings"),
                encoding: .utf8)
            for key in requiredKeys {
                #expect(contents.contains("\"\(key)\" ="), "Missing \(key) in \(localization.lastPathComponent)")
            }
        }

        let simplifiedChinese = try String(
            contentsOf: resources.appendingPathComponent("zh-Hans.lproj/Localizable.strings"),
            encoding: .utf8)
        #expect(simplifiedChinese.contains(
            #""relay_usage_card_disabled" = "该中转站未启用额度查询";"#))
        #expect(simplifiedChinese.contains(#""relay_usage_card_status_active" = "生效中";"#))
        #expect(simplifiedChinese.contains(#""relay_usage_card_status_saved" = "已保存";"#))
        #expect(simplifiedChinese.contains(#""relay_usage_card_status_not_ready" = "未就绪";"#))
    }
}

@MainActor
struct RelaySettingsModelTests {
    @Test
    func `relay switcher follows the selected provider scope`() {
        #expect(ProviderSwitcherSelection.provider(.codex).relayVisibleTargets == [.codex])
        #expect(ProviderSwitcherSelection.provider(.opencode).relayVisibleTargets == [.openCode])
        #expect(ProviderSwitcherSelection.provider(.opencodego).relayVisibleTargets == [.openCode])
        #expect(ProviderSwitcherSelection.provider(.claude).relayVisibleTargets == [.claudeCode])
        #expect(ProviderSwitcherSelection.provider(.grok).relayVisibleTargets == [.grokBuild])
        #expect(ProviderSwitcherSelection.provider(.antigravity).relayVisibleTargets.isEmpty)
        #expect(ProviderSwitcherSelection.piAgent.relayVisibleTargets == [.piAgent])
        #expect(ProviderSwitcherSelection.overview.relayVisibleTargets == RelayTargetApp.headroomManagedTargets)
    }

    @Test
    func `new relay settings default to the Sub2API usage endpoint`() {
        let recorder = RelaySettingsRecorder()
        let model = RelaySettingsModel(actions: recorder.actions)

        model.loadIfNeeded()

        #expect(model.usageQueryMode == .sub2API)
    }

    @Test
    func `incomplete profile can be saved and reports switch requirements`() throws {
        let recorder = RelaySettingsRecorder()
        let model = RelaySettingsModel(actions: recorder.actions)
        model.loadIfNeeded()
        model.name = "Draft relay"
        model.baseURLText = "https://relay.example/v1"
        model.apiFormat = .openAIResponses
        model.modelID = ""

        #expect(model.canSave)
        #expect(model.switchBlockers.contains { $0.contains("模型 ID") })
        #expect(!model.canSwitch)

        model.save()
        let stored = try #require(recorder.storedProfiles.last?.first)
        #expect(stored.name == "Draft relay")
        #expect(stored.configuration(for: .codex)?.model == nil)
    }

    @Test
    func `new draft saved without a credential remains blocked from apply`() {
        let recorder = RelaySettingsRecorder()
        let model = RelaySettingsModel(actions: recorder.actions)
        model.loadIfNeeded()
        model.name = "Draft relay"
        model.baseURLText = "https://relay.example/v1"
        model.modelID = "test-model"

        model.save()

        #expect(model.switchBlockers.contains { $0.contains("API Key") })
        #expect(recorder.appliedProfiles.isEmpty)
    }

    @Test
    func `applying persists the draft and updates enabled client ownership`() throws {
        let recorder = RelaySettingsRecorder()
        let model = RelaySettingsModel(actions: recorder.actions)
        model.loadIfNeeded()
        model.name = "Applied relay"
        model.baseURLText = "https://relay.example/v1"
        model.apiKeyInput = "test-api-key"
        model.modelID = "shared-model"
        model.enabledTargets = [.codex, .openCode]
        model.setModelID("codex-model", for: .codex)
        model.setModelID("open-code-model", for: .openCode)

        model.applyToEnabledClients()

        let applied = try #require(recorder.appliedProfiles.last)
        #expect(recorder.events == ["storeProfiles", "applyProfile"])
        #expect(recorder.baselineCaptureCount == 1)
        #expect(applied.id == model.profileID)
        #expect(applied.configuration(for: .codex)?.isEnabled == true)
        #expect(applied.configuration(for: .openCode)?.isEnabled == true)
        #expect(recorder.activationState?.activeProfileIDsByTarget == [
            .codex: model.profileID,
            .openCode: model.profileID,
        ])
        #expect(recorder.keychainReadCacheInvalidationCount == 1)
        #expect(recorder.routeApplicationNotificationCount == 1)
        #expect(recorder.discardedBackupDirectories == [recorder.applyBackupDirectory])
        #expect(model.status == .applied(name: "Applied relay", clientCount: 2))
    }

    @Test
    func `new draft without a credential remains blocked after reload`() throws {
        let recorder = RelaySettingsRecorder()
        let firstModel = RelaySettingsModel(actions: recorder.actions)
        firstModel.loadIfNeeded()
        firstModel.name = "Draft relay"
        firstModel.baseURLText = "https://relay.example/v1"
        firstModel.modelID = "test-model"
        firstModel.save()
        recorder.profilesToLoad = try #require(recorder.storedProfiles.last)

        let reloadedModel = RelaySettingsModel(actions: recorder.actions)
        reloadedModel.loadIfNeeded()

        #expect(reloadedModel.switchBlockers.contains { $0.contains("API Key") })
    }

    @Test
    func `credential is submitted and remains visible without entering profile JSON`() throws {
        let recorder = RelaySettingsRecorder()
        let model = RelaySettingsModel(actions: recorder.actions)
        model.loadIfNeeded()
        model.name = "Test relay"
        model.baseURLText = "https://relay.example/v1"
        model.modelID = "test-model"
        model.apiKeyInput = "test-api-key-value"

        model.save()

        #expect(recorder.credentials == ["test-api-key-value"])
        #expect(model.apiKeyInput == "test-api-key-value")
        let stored = try #require(recorder.storedProfiles.last?.first)
        #expect(stored.credentialConfigured)
        let encoded = try JSONEncoder().encode(stored)
        let persistedText = try #require(String(data: encoded, encoding: .utf8))
        #expect(!persistedText.contains("test-api-key-value"))
        #expect(!(model.status.message ?? "").contains("test-api-key-value"))
        #expect(model.status == .saved("Test relay"))
    }

    @Test
    func `saved credential is loaded into the visible API key field`() throws {
        let recorder = RelaySettingsRecorder()
        let profileID = UUID()
        let reference = RelayCredentialReference.make(for: profileID)
        recorder.profilesToLoad = try [RelayProfile(
            id: profileID,
            name: "Visible credential",
            baseURL: #require(URL(string: "https://relay.example/v1")),
            apiFormat: .openAIResponses,
            credentialReference: reference,
            credentialConfigured: true,
            targets: [.init(app: .codex, model: "test-model")])]
        recorder.credentialsByReference[reference] = "visible-test-value"

        let model = RelaySettingsModel(actions: recorder.actions)
        model.loadIfNeeded()

        #expect(model.apiKeyInput == "visible-test-value")
    }

    @Test
    func `quick switch readiness requires a key model and compatible target`() throws {
        let profileID = UUID()
        let baseURL = try #require(URL(string: "https://relay.example/v1"))
        let incomplete = RelayProfile(
            id: profileID,
            name: "Incomplete",
            baseURL: baseURL,
            apiFormat: .openAIResponses,
            credentialReference: RelayCredentialReference.make(for: profileID),
            credentialConfigured: false,
            targets: [.init(app: .codex, model: nil)])
        let ready = RelayProfile(
            id: profileID,
            name: "Ready",
            baseURL: baseURL,
            apiFormat: .openAIResponses,
            credentialReference: RelayCredentialReference.make(for: profileID),
            credentialConfigured: true,
            targets: [.init(app: .codex, model: "test-model")])

        #expect(RelayQuickSwitchCoordinator.readinessBlocker(for: incomplete, target: .codex) ==
            L("relay_usage_card_missing_credential"))
        #expect(RelayQuickSwitchCoordinator.readinessBlocker(for: ready, target: .codex) == nil)

        let defaulted = RelayProfile(
            id: profileID,
            name: "Defaulted",
            baseURL: baseURL,
            apiFormat: .openAIResponses,
            defaultModel: "shared-model",
            credentialReference: RelayCredentialReference.make(for: profileID),
            credentialConfigured: true,
            targets: [.init(app: .piAgent, model: nil)])
        #expect(RelayQuickSwitchCoordinator.readinessBlocker(for: defaulted, target: .piAgent) == nil)
    }

    @Test
    func `quick switch only lists profiles explicitly enabled for each target`() throws {
        let recorder = RelaySettingsRecorder()
        let profileID = UUID()
        let reference = RelayCredentialReference.make(for: profileID)
        let profile = try Self.profile(
            id: profileID,
            name: "OpenCode only",
            credentialReference: reference,
            targets: [
                .init(app: .codex, model: "codex-model", isEnabled: false),
                .init(app: .openCode, model: "open-code-model", isEnabled: true),
            ])
        recorder.profilesToLoad = [profile]
        recorder.credentialsByReference[reference] = "open-code-key"

        let snapshot = RelayQuickSwitchCoordinator(actions: recorder.actions).snapshot()

        #expect(snapshot.optionsByTarget[.codex]?.isEmpty == true)
        #expect(snapshot.optionsByTarget[.openCode]?.map(\.id) == [profileID])
        #expect(RelayQuickSwitchCoordinator.readinessBlocker(for: profile, target: .codex)
            == "这个配置未允许用于 Codex。")
    }

    @Test
    func `quick switch enables unified history before applying a relay`() throws {
        let recorder = RelaySettingsRecorder()
        let profileID = UUID()
        let reference = RelayCredentialReference.make(for: profileID)
        recorder.profilesToLoad = try [Self.profile(
            id: profileID,
            name: "Quick relay",
            credentialReference: reference)]
        recorder.credentialsByReference[reference] = "quick-test-key"
        let coordinator = RelayQuickSwitchCoordinator(actions: recorder.actions)

        let outcome = coordinator.select(.profile(.codex, profileID))

        #expect(outcome.succeeded)
        #expect(recorder.unifiedHistoryEnableCount == 1)
        #expect(recorder.events.first == "enableUnifiedHistory")
        #expect(recorder.appliedProfiles.map(\.id) == [profileID])
        #expect(recorder.keychainReadCacheInvalidationCount == 1)
        #expect(recorder.routeApplicationNotificationCount == 1)
    }

    @Test
    func `quick switch continues with a warning when unified history migration fails`() throws {
        let recorder = RelaySettingsRecorder()
        let profileID = UUID()
        let reference = RelayCredentialReference.make(for: profileID)
        recorder.profilesToLoad = try [Self.profile(
            id: profileID,
            name: "Quick relay",
            credentialReference: reference)]
        recorder.credentialsByReference[reference] = "quick-test-key"
        recorder.unifiedHistoryError = RelaySettingsTestError.unifiedHistoryFailed
        let coordinator = RelayQuickSwitchCoordinator(actions: recorder.actions)

        let outcome = coordinator.select(.profile(.codex, profileID))

        #expect(outcome.succeeded)
        #expect(recorder.events == ["enableUnifiedHistory", "applyProfile"])
        #expect(recorder.appliedProfiles.map(\.id) == [profileID])
        #expect(outcome.warning?.contains("RelaySettingsTestError") == true)
    }

    @Test
    func `switching OpenCode only leaves Codex official and does not migrate history`() throws {
        let recorder = RelaySettingsRecorder()
        let profileID = UUID()
        let reference = RelayCredentialReference.make(for: profileID)
        recorder.profilesToLoad = try [Self.profile(
            id: profileID,
            name: "OpenCode relay",
            credentialReference: reference,
            targets: [
                .init(app: .codex, model: "codex-model"),
                .init(app: .openCode, model: "open-code-model"),
            ])]
        recorder.credentialsByReference[reference] = "open-code-key"

        let coordinator = RelayQuickSwitchCoordinator(actions: recorder.actions)
        let outcome = coordinator.select(.profile(.openCode, profileID))

        #expect(outcome.succeeded)
        #expect(recorder.unifiedHistoryEnableCount == 0)
        let applied = try #require(recorder.appliedProfiles.first)
        #expect(applied.configuration(for: .codex) == nil)
        #expect(applied.configuration(for: .openCode)?.model == "open-code-model")
        #expect(recorder.activationState?.activeProfileIDsByTarget == [.openCode: profileID])
    }

    @Test
    func `first Codex switch asks for explicit history confirmation`() throws {
        let recorder = RelaySettingsRecorder()
        let profileID = UUID()
        let reference = RelayCredentialReference.make(for: profileID)
        recorder.profilesToLoad = try [Self.profile(
            id: profileID,
            name: "Codex relay",
            credentialReference: reference)]
        recorder.credentialsByReference[reference] = "codex-key"
        recorder.hasCodexHistory = true

        let coordinator = RelayQuickSwitchCoordinator(actions: recorder.actions)
        let outcome = coordinator.select(.profile(.codex, profileID), confirmed: false)

        #expect(!outcome.succeeded)
        #expect(outcome.requiresConfirmation)
        #expect(recorder.unifiedHistoryEnableCount == 0)
        #expect(recorder.appliedProfiles.isEmpty)
    }

    @Test
    func `first Codex switch without history skips confirmation`() throws {
        let recorder = RelaySettingsRecorder()
        let profileID = UUID()
        let reference = RelayCredentialReference.make(for: profileID)
        recorder.profilesToLoad = try [Self.profile(
            id: profileID,
            name: "Codex relay",
            credentialReference: reference)]
        recorder.credentialsByReference[reference] = "codex-key"
        recorder.hasCodexHistory = false

        let coordinator = RelayQuickSwitchCoordinator(actions: recorder.actions)
        let outcome = coordinator.select(.profile(.codex, profileID), confirmed: false)

        #expect(outcome.succeeded)
        #expect(!outcome.requiresConfirmation)
        #expect(recorder.events == ["enableUnifiedHistory", "applyProfile"])
        #expect(recorder.keychainReadCacheInvalidationCount == 1)
    }

    @Test
    func `restoring official configuration invalidates keychain read cache`() {
        let recorder = RelaySettingsRecorder()
        recorder.activationState = RelayActivationState(
            activeProfileIDsByTarget: [.codex: UUID()],
            baselineBackupDirectory: recorder.baselineCaptureDirectory)
        let coordinator = RelayQuickSwitchCoordinator(actions: recorder.actions)

        let outcome = coordinator.select(.official(.codex))

        #expect(outcome.succeeded)
        #expect(recorder.activationState == nil)
        #expect(recorder.keychainReadCacheInvalidationCount == 1)
    }

    @Test
    func `relay card refresh fetches and stores only the requested profile`() async throws {
        let recorder = RelaySettingsRecorder()
        let firstID = UUID()
        let secondID = UUID()
        let firstReference = RelayCredentialReference.make(for: firstID)
        let secondReference = RelayCredentialReference.make(for: secondID)
        recorder.profilesToLoad = try [
            Self.profile(id: firstID, name: "First", credentialReference: firstReference),
            Self.profile(id: secondID, name: "Second", credentialReference: secondReference),
        ]
        recorder.credentialsByReference[firstReference] = "first-key"
        recorder.credentialsByReference[secondReference] = "second-key"
        recorder.fetchedUsageSummary = RelayUsageSummary(
            remaining: 9,
            used: 1,
            total: 10,
            unit: "USD",
            planName: "Relay",
            updatedAt: Date())
        let coordinator = RelayQuickSwitchCoordinator(actions: recorder.actions)

        let outcome = await coordinator.refreshUsage(profileID: secondID)

        #expect(outcome.succeeded)
        #expect(recorder.fetchedUsageProfileIDs == [secondID])
        #expect(recorder.usageSummariesByProfileID[secondID] == recorder.fetchedUsageSummary)
        #expect(recorder.usageSummariesByProfileID[firstID] == nil)
    }

    @Test
    func `relay option height cache identity changes when usage changes`() {
        let profileID = UUID()
        let withoutUsage = RelayQuickSwitchOption(
            id: profileID,
            name: "Relay",
            isReady: true,
            blocker: nil)
        let withUsage = RelayQuickSwitchOption(
            id: profileID,
            name: "Relay",
            isReady: true,
            blocker: nil,
            usageSummary: RelayUsageSummary(
                remaining: 8,
                used: 2,
                total: 10,
                unit: "USD",
                planName: "Plan",
                updatedAt: Date(timeIntervalSince1970: 20)))

        #expect(withoutUsage.heightCacheDescription != withUsage.heightCacheDescription)
    }

    @Test
    func `quick switch failure stays in the fixed inline status row`() {
        var feedback = RelayQuickSwitchFeedback()
        feedback.record(RelayQuickSwitchOutcome(
            succeeded: false,
            selection: .profile(.openCode, UUID()),
            message: "OpenCode is not ready."))

        #expect(RelayQuickSwitchFeedback.height == 32)
        #expect(feedback.message == "OpenCode is not ready.")

        feedback.record(RelayQuickSwitchOutcome(
            succeeded: true,
            selection: .official(.openCode),
            message: "Restored.",
            warning: "History migration failed."))
        #expect(feedback.message == "History migration failed.")
    }

    @Test
    func `relay quick switch choices wrap onto another row when needed`() {
        let rowCount = RelayQuickSwitchFlowLayout.rowCount(
            itemWidths: [48, 86, 86, 86],
            availableWidth: 230,
            spacing: 6)

        #expect(rowCount == 2)
    }

    @Test
    func `compatibility blockers follow direct writer capabilities`() {
        let recorder = RelaySettingsRecorder()
        let model = RelaySettingsModel(actions: recorder.actions)
        model.loadIfNeeded()
        model.name = "Relay"
        model.baseURLText = "https://relay.example/v1"
        model.modelID = "test-model"
        model.apiKeyInput = "test-api-key-value"
        model.enabledTargets = [.codex, .claudeCode, .claudeDesktop, .grokBuild, .openCode]
        model.apiFormat = .openAIResponses

        #expect(model.switchBlockers.contains { $0.contains("Claude Code") })
        #expect(!model.switchBlockers.contains { $0.contains("Third-Party Inference") })
        #expect(!model.switchBlockers.contains { $0.contains("OpenCode 直连") })

        model.apiFormat = .anthropicMessages
        #expect(model.switchBlockers.contains { $0.contains("Codex 直连") })
        #expect(model.switchBlockers.contains { $0.contains("Grok Build") })
    }

    @Test
    func `current model ID can fill every enabled client without touching disabled clients`() {
        let recorder = RelaySettingsRecorder()
        let model = RelaySettingsModel(actions: recorder.actions)
        model.loadIfNeeded()
        model.modelID = "shared-model"
        model.enabledTargets = [.codex, .openCode]
        model.modelIDsByTarget = [
            .codex: "old-codex",
            .openCode: "old-opencode",
            .claudeCode: "keep-disabled",
        ]

        model.fillCurrentModelIDIntoEnabledClients()

        #expect(model.modelID(for: .codex) == "shared-model")
        #expect(model.modelID(for: .openCode) == "shared-model")
        #expect(model.modelID(for: .claudeCode) == "keep-disabled")
    }

    @Test
    nonisolated func `unready relay choices stay actionable and expose tooltips`() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/CodexBar/RelayQuickSwitchMenu.swift"),
            encoding: .utf8)
        let choiceSource = try #require(source.split(separator: "struct RelayQuickSwitchChoice: View", maxSplits: 1)
            .last.map(String.init))

        #expect(!choiceSource.contains(".disabled"))
        #expect(choiceSource.contains(".help(self.helpText ?? \"\")"))
        #expect(choiceSource.contains("let helpText: String?"))
    }

    @Test
    func `saving settings never migrates history captures a baseline or writes client files`() {
        let recorder = RelaySettingsRecorder()
        let model = RelaySettingsModel(actions: recorder.actions)
        model.loadIfNeeded()
        model.name = "Ready relay"
        model.baseURLText = "https://relay.example/v1"
        model.modelID = "test-model"
        model.apiKeyInput = "test-api-key-value"

        model.save()

        #expect(recorder.events == ["storeProfiles"])
        #expect(recorder.unifiedHistoryEnableCount == 0)
        #expect(recorder.appliedProfiles.isEmpty)
        #expect(recorder.activationState == nil)
        #expect(recorder.baselineCaptureCount == 0)
    }

    @Test
    func `successful previous configuration restore clears persisted activation state`() {
        let recorder = RelaySettingsRecorder()
        let baseline = URL(fileURLWithPath: "/test/backups/original", isDirectory: true)
        recorder.activationState = RelayActivationState(
            activeProfileIDsByTarget: [.codex: UUID()],
            baselineBackupDirectory: baseline)
        let model = RelaySettingsModel(actions: recorder.actions)
        model.loadIfNeeded()

        #expect(model.canRestorePreviousConfiguration)
        model.restorePreviousConfiguration()

        #expect(recorder.restoredBackupDirectories == [baseline])
        #expect(recorder.discardedBackupDirectories == [
            URL(fileURLWithPath: "/test/backups/restore-safety", isDirectory: true),
            baseline,
        ])
        #expect(recorder.activationState == nil)
        #expect(model.status == .restoredPreviousConfiguration)
    }

    @Test
    func `activation state survives a UserDefaults round trip`() throws {
        let suite = "RelayActivationStateTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsRelayActivationStateStore(userDefaults: defaults)
        let state = RelayActivationState(
            activeProfileIDsByTarget: [.codex: UUID(), .openCode: UUID()],
            baselineBackupDirectory: URL(fileURLWithPath: "/test/backups/baseline", isDirectory: true))

        store.store(state)
        #expect(store.load() == state)

        store.clear()
        #expect(store.load() == nil)
    }

    @Test
    func `activation state mirrors the core recovery file and clears both stores`() throws {
        let suite = "RelayActivationStateTests-file-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Headroom-activation-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("local-meter-activation.json")
        let store = UserDefaultsRelayActivationStateStore(
            userDefaults: defaults,
            localMeterStateFileURL: fileURL)
        let profileID = UUID()
        let baseline = root.appendingPathComponent("baseline", isDirectory: true)
        let state = RelayActivationState(
            activeProfileIDsByTarget: [.codex: profileID, .openCode: UUID()],
            baselineBackupDirectory: baseline)

        store.store(state)

        let coreStore = LocalMeterActivationStateFileStore(fileURL: fileURL)
        #expect(coreStore.load() == LocalMeterActivationState(
            activeProfileIDsByTarget: state.activeProfileIDsByTarget,
            baselineBackupDirectory: baseline))
        #expect(store.load() == state)

        store.clear()

        #expect(store.load() == nil)
        #expect(coreStore.load() == nil)
    }

    @Test
    func `unified history is not enabled when settings load`() {
        let recorder = RelaySettingsRecorder()
        let model = RelaySettingsModel(actions: recorder.actions)
        model.loadIfNeeded()

        #expect(!model.unifiedHistoryEnabled)
        #expect(recorder.unifiedHistoryEnableCount == 0)
        #expect(model.status == .idle)
    }

    @Test
    func `opening and saving a profile preserves blank per-target models`() throws {
        let recorder = RelaySettingsRecorder()
        let profileID = UUID()
        let reference = RelayCredentialReference.make(for: profileID)
        recorder.profilesToLoad = try [RelayProfile(
            id: profileID,
            name: "Per-target relay",
            baseURL: #require(URL(string: "https://relay.example/v1")),
            apiFormat: .openAIResponses,
            credentialReference: reference,
            credentialConfigured: true,
            targets: [
                .init(app: .codex, model: "codex-model", isEnabled: true),
                .init(app: .openCode, model: nil, isEnabled: true),
            ])]
        recorder.credentialsByReference[reference] = "test-api-key-value"
        let model = RelaySettingsModel(actions: recorder.actions)
        model.loadIfNeeded()

        model.save()

        let profile = try #require(recorder.storedProfiles.last?.first)
        #expect(profile.configuration(for: .codex)?.model == "codex-model")
        #expect(profile.configuration(for: .openCode)?.model == nil)
        #expect(model.switchBlockers.contains { $0.contains("OpenCode") && $0.contains("模型 ID") })
    }

    @Test
    func `optimistic relay selection yields to a changed snapshot fingerprint`() {
        let firstID = UUID()
        let secondID = UUID()
        var state = RelayQuickSwitchOptimisticSelectionState(
            fingerprint: "official",
            snapshotSelections: [.codex: .official(.codex)])
        state.record(RelayQuickSwitchOutcome(
            succeeded: true,
            selection: .profile(.codex, firstID),
            message: "switched"))

        #expect(state.selection(
            for: .codex,
            fingerprint: "official",
            snapshotSelection: .official(.codex)) == .profile(.codex, firstID))
        #expect(state.selection(
            for: .codex,
            fingerprint: "second",
            snapshotSelection: .profile(.codex, secondID)) == .profile(.codex, secondID))

        state.reconcile(
            fingerprint: "second",
            snapshotSelections: [.codex: .profile(.codex, secondID)])
        #expect(!state.hasOptimisticSelections)
        #expect(state.selection(
            for: .codex,
            fingerprint: "second",
            snapshotSelection: .profile(.codex, secondID)) == .profile(.codex, secondID))
    }

    @Test
    func `official relay choices are ready without a restore baseline`() {
        #expect(RelayOfficialChoicePresentation.isReady)
    }

    @Test
    func `relay aggregate usage maps into a real drawer snapshot`() throws {
        let updatedAt = Date(timeIntervalSince1970: 1_781_726_400)
        let summary = RelayUsageSummary(
            remaining: 9,
            used: 1,
            total: 10,
            unit: "USD",
            planName: "Relay",
            updatedAt: updatedAt,
            recentUsage: RelayRecentUsageSummary(
                period: .rolling24Hours,
                totalTokens: 1_250_000,
                actualCostUSD: 5.5))

        let snapshot = try #require(RelayUsagePresentation.costUsageSnapshot(summary))
        #expect(snapshot.rolling24Hours?.totalTokens == 1_250_000)
        #expect(snapshot.rolling24Hours?.costUSD == 5.5)
        #expect(snapshot.historyLabel == "24h")
        #expect(snapshot.hourly24Hours.isEmpty)
        #expect(RelayUsagePresentation.costUsageSnapshot(RelayUsageSummary(
            remaining: 9,
            used: 1,
            total: 10,
            unit: "USD",
            planName: nil,
            updatedAt: updatedAt)) == nil)
    }

    @Test
    func `deleting an inactive profile removes metadata and credential then selects the next profile`() throws {
        let recorder = RelaySettingsRecorder()
        let firstID = UUID()
        let secondID = UUID()
        let firstReference = RelayCredentialReference.make(for: firstID)
        let secondReference = RelayCredentialReference.make(for: secondID)
        recorder.profilesToLoad = try [
            Self.profile(id: firstID, name: "Alpha", credentialReference: firstReference),
            Self.profile(id: secondID, name: "Beta", credentialReference: secondReference),
        ]
        recorder.credentialsByReference[firstReference] = "first-test-key"
        recorder.credentialsByReference[secondReference] = "second-test-key"
        recorder.unifiedHistoryEnabled = true
        let model = RelaySettingsModel(actions: recorder.actions)
        model.loadIfNeeded()

        model.deleteSelectedProfile()

        #expect(recorder.storedProfiles.last?.map(\.id) == [secondID])
        #expect(recorder.removedCredentialReferences == [firstReference])
        #expect(model.profiles.map(\.id) == [secondID])
        #expect(model.selectedProfileID == secondID)
        #expect(model.apiKeyInput == "second-test-key")
    }

    @Test
    func `deleting an active profile restores official configuration first`() throws {
        let recorder = RelaySettingsRecorder()
        let profileID = UUID()
        let reference = RelayCredentialReference.make(for: profileID)
        let baseline = URL(fileURLWithPath: "/test/backups/original", isDirectory: true)
        recorder.profilesToLoad = try [Self.profile(
            id: profileID,
            name: "Active",
            credentialReference: reference)]
        recorder.credentialsByReference[reference] = "active-test-key"
        recorder.activationState = RelayActivationState(
            activeProfileIDsByTarget: [.codex: profileID],
            baselineBackupDirectory: baseline)
        recorder.unifiedHistoryEnabled = true
        let model = RelaySettingsModel(actions: recorder.actions)
        model.loadIfNeeded()

        model.deleteSelectedProfile()

        #expect(recorder.events.first == "restoreBaseline")
        #expect(recorder.restoredBackupDirectories == [baseline])
        #expect(recorder.activationState == nil)
        #expect(recorder.storedProfiles.last?.isEmpty == true)
        #expect(recorder.removedCredentialReferences == [reference])
        #expect(model.profiles.isEmpty)
        #expect(model.selectedProfileID == nil)
        #expect(recorder.keychainReadCacheInvalidationCount == 1)
    }

    @Test
    func `failed active profile restore keeps the profile and credential`() throws {
        let recorder = RelaySettingsRecorder()
        let profileID = UUID()
        let reference = RelayCredentialReference.make(for: profileID)
        recorder.profilesToLoad = try [Self.profile(
            id: profileID,
            name: "Active",
            credentialReference: reference)]
        recorder.credentialsByReference[reference] = "active-test-key"
        recorder.activationState = RelayActivationState(
            activeProfileIDsByTarget: [.codex: profileID],
            baselineBackupDirectory: URL(fileURLWithPath: "/test/backups/original", isDirectory: true))
        recorder.restoreError = RelaySettingsTestError.restoreFailed
        recorder.unifiedHistoryEnabled = true
        let model = RelaySettingsModel(actions: recorder.actions)
        model.loadIfNeeded()

        model.deleteSelectedProfile()

        #expect(model.status.isError)
        #expect(model.profiles.map(\.id) == [profileID])
        #expect(recorder.storedProfiles.isEmpty)
        #expect(recorder.removedCredentialReferences.isEmpty)
        #expect(recorder.credentialsByReference[reference] == "active-test-key")
        #expect(recorder.keychainReadCacheInvalidationCount == 0)
    }

    @Test
    func `failed new profile persistence removes its newly stored credential`() {
        let recorder = RelaySettingsRecorder()
        recorder.profileStoreError = RelaySettingsTestError.storeFailed
        let model = RelaySettingsModel(actions: recorder.actions)
        model.loadIfNeeded()
        model.name = "Relay"
        model.baseURLText = "https://relay.example/v1"
        model.apiKeyInput = "test-api-key-value"

        model.save()

        #expect(recorder.removedCredentialReferences.count == 1)
        #expect(model.status.isError)
        #expect(!(model.status.message ?? "").contains("test-api-key-value"))
    }

    @Test
    func `failed existing profile persistence restores its previous credential`() throws {
        let recorder = RelaySettingsRecorder()
        let profileID = UUID()
        let reference = RelayCredentialReference.make(for: profileID)
        recorder.profilesToLoad = try [RelayProfile(
            id: profileID,
            name: "Existing",
            baseURL: #require(URL(string: "https://relay.example/v1")),
            apiFormat: .openAIResponses,
            credentialReference: reference,
            credentialConfigured: true,
            targets: [.init(app: .codex, model: "test-model")])]
        recorder.credentialsByReference[reference] = "old-test-value"
        let model = RelaySettingsModel(actions: recorder.actions)
        model.loadIfNeeded()
        recorder.profileStoreError = RelaySettingsTestError.storeFailed
        model.apiKeyInput = "new-test-value"

        model.save()

        #expect(recorder.credentialsByReference[reference] == "old-test-value")
        #expect(Array(recorder.credentials.suffix(2)) == ["new-test-value", "old-test-value"])
        #expect(model.status.isError)
    }

    @Test
    func `usage refresh stores the result and reloads it with the profile`() async throws {
        let recorder = RelaySettingsRecorder()
        let profileID = UUID()
        let reference = RelayCredentialReference.make(for: profileID)
        recorder.profilesToLoad = try [RelayProfile(
            id: profileID,
            name: "Usage relay",
            baseURL: #require(URL(string: "https://relay.example/v1")),
            apiFormat: .openAIResponses,
            credentialReference: reference,
            credentialConfigured: true,
            usageQueryMode: .sub2API,
            targets: [.init(app: .codex, model: "test-model")])]
        recorder.credentialsByReference[reference] = "test-api-key"
        let model = RelaySettingsModel(actions: recorder.actions)
        model.loadIfNeeded()

        await model.refreshUsage()

        #expect(model.usageSummary == recorder.fetchedUsageSummary)
        #expect(recorder.usageSummariesByProfileID[profileID] == recorder.fetchedUsageSummary)
        model.startNewProfile()
        model.selectProfile(profileID)
        #expect(model.usageSummary == recorder.fetchedUsageSummary)
    }

    private static func profile(
        id: UUID,
        name: String,
        credentialReference: String,
        targets: [RelayTargetConfiguration] = [.init(app: .codex, model: "test-model")]) throws -> RelayProfile
    {
        try RelayProfile(
            id: id,
            name: name,
            baseURL: #require(URL(string: "https://relay.example/v1")),
            apiFormat: .openAIResponses,
            credentialReference: credentialReference,
            credentialConfigured: true,
            targets: targets)
    }
}

@MainActor
private final class RelaySettingsRecorder {
    var storedProfiles: [[RelayProfile]] = []
    var profilesToLoad: [RelayProfile] = []
    var credentials: [String] = []
    var credentialsByReference: [String: String] = [:]
    var removedCredentialReferences: [String] = []
    var appliedProfiles: [RelayProfile] = []
    var restoredBackupDirectories: [URL] = []
    var discardedBackupDirectories: [URL] = []
    var activationState: RelayActivationState?
    var profileStoreError: (any Error)?
    var applyError: (any Error)?
    var restoreError: (any Error)?
    var baselineCaptureCount = 0
    var unifiedHistoryEnabled = false
    var unifiedHistoryOptIn = false
    var hasCodexHistory = false
    var isCodexLoggedIn = true
    var unifiedHistoryEnableCount = 0
    var unifiedHistoryError: (any Error)?
    var keychainReadCacheInvalidationCount = 0
    var routeApplicationNotificationCount = 0
    var events: [String] = []
    var usageSummariesByProfileID: [UUID: RelayUsageSummary] = [:]
    var fetchedUsageProfileIDs: [UUID] = []
    var fetchedUsageSummary = RelayUsageSummary(
        remaining: 9,
        used: 1,
        total: 10,
        unit: "USD",
        planName: nil,
        updatedAt: Date(timeIntervalSince1970: 10))
    let baselineCaptureDirectory = URL(fileURLWithPath: "/test/backups/baseline-capture", isDirectory: true)
    let applyBackupDirectory = URL(fileURLWithPath: "/test/backups/latest", isDirectory: true)

    var actions: RelaySettingsActions {
        var actions = RelaySettingsActions(
            loadProfiles: { [weak self] in self?.profilesToLoad ?? [] },
            storeProfiles: { [weak self] profiles in
                guard let self else { return }
                self.events.append("storeProfiles")
                if let profileStoreError = self.profileStoreError { throw profileStoreError }
                self.storedProfiles.append(profiles)
            },
            loadCredential: { [weak self] reference in
                self?.credentialsByReference[reference]
            },
            storeCredential: { [weak self] credential, reference in
                self?.credentials.append(credential)
                self?.credentialsByReference[reference] = credential
            },
            removeCredential: { [weak self] reference in
                self?.removedCredentialReferences.append(reference)
                self?.credentialsByReference.removeValue(forKey: reference)
            },
            captureBaseline: { [weak self] in
                self?.baselineCaptureCount += 1
                return self?.baselineCaptureDirectory
                    ?? URL(fileURLWithPath: "/test/backups/fallback", isDirectory: true)
            },
            applyProfile: { [weak self] profile in
                if let applyError = self?.applyError { throw applyError }
                self?.events.append("applyProfile")
                self?.appliedProfiles.append(profile)
                return RelaySwitchResult(
                    preview: RelaySwitchPreview(
                        changedTargets: [.codex],
                        unchangedTargets: [],
                        changedFileCount: 1),
                    wasDryRun: false,
                    backupDirectory: self?.applyBackupDirectory)
            },
            restoreBaseline: { [weak self] backupDirectory in
                self?.events.append("restoreBaseline")
                if let restoreError = self?.restoreError { throw restoreError }
                self?.restoredBackupDirectories.append(backupDirectory)
                return RelaySwitchResult(
                    preview: RelaySwitchPreview(
                        changedTargets: [.codex],
                        unchangedTargets: [],
                        changedFileCount: 1),
                    wasDryRun: false,
                    backupDirectory: URL(fileURLWithPath: "/test/backups/restore-safety", isDirectory: true))
            },
            restoreBaselineForTargets: nil,
            discardBackup: { [weak self] backupDirectory in
                self?.discardedBackupDirectories.append(backupDirectory)
            },
            loadActivationState: { [weak self] in self?.activationState },
            storeActivationState: { [weak self] in self?.activationState = $0 },
            clearActivationState: { [weak self] in self?.activationState = nil },
            loadUnifiedHistoryEnabled: { [weak self] in self?.unifiedHistoryEnabled ?? false },
            loadUnifiedHistoryOptIn: { [weak self] in self?.unifiedHistoryOptIn ?? false },
            storeUnifiedHistoryOptIn: { [weak self] value in self?.unifiedHistoryOptIn = value },
            hasCodexHistory: { [weak self] in self?.hasCodexHistory ?? false },
            isCodexLoggedIn: { [weak self] in self?.isCodexLoggedIn ?? true },
            enableUnifiedHistory: { [weak self] in
                self?.events.append("enableUnifiedHistory")
                if let unifiedHistoryError = self?.unifiedHistoryError { throw unifiedHistoryError }
                self?.unifiedHistoryEnableCount += 1
                self?.unifiedHistoryEnabled = true
                self?.unifiedHistoryOptIn = true
                return CodexUnifiedHistoryMigrationOutcome(
                    migratedJSONLFiles: 2,
                    migratedStateRows: 3,
                    backupDirectory: nil)
            },
            loadUsageSummary: { [weak self] in self?.usageSummariesByProfileID[$0] },
            storeUsageSummary: { [weak self] summary, profileID in
                self?.usageSummariesByProfileID[profileID] = summary
            },
            fetchUsageSummary: { [weak self] profile, _ in
                self?.fetchedUsageProfileIDs.append(profile.id)
                return self?.fetchedUsageSummary ?? RelayUsageSummary(
                    remaining: nil,
                    used: nil,
                    total: nil,
                    unit: "USD",
                    planName: nil,
                    updatedAt: .distantPast)
            })
        actions.invalidateKeychainReadCache = { [weak self] in
            self?.keychainReadCacheInvalidationCount += 1
        }
        actions.notifyRouteApplicationSucceeded = { [weak self] in
            self?.routeApplicationNotificationCount += 1
        }
        return actions
    }
}

private enum RelaySettingsTestError: Error {
    case storeFailed
    case applyFailed
    case restoreFailed
    case unifiedHistoryFailed
}
