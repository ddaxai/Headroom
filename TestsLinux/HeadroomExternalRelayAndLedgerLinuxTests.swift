import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct HeadroomExternalRelayAndLedgerLinuxTests {
    @Test
    func `merged Codex request ledger deduplicates legacy mirrors and rejects foreign session copies`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("headroom-ledger-linux-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let dayDir = root.appendingPathComponent("sessions/2026/10/05", isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let sessionURL = dayDir.appendingPathComponent("rollout-2026-10-05T12-00-00-ledger.jsonl")

        let lines = [
            #"{"type":"session_meta","timestamp":"2026-10-05T12:00:00Z","payload":{"id":"thread-main","session_id":"exec-1"}}"#,
            #"{"type":"token_usage_record","timestamp":"2026-10-05T12:00:02Z","payload":{"thread_id":"thread-main","session_id":"exec-1","response_id":"resp-1","model":"gpt-6.1-sol","usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":30},"thread_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":30}}}"#,
            // Duplicate response_id in same thread/session must not double-count.
            #"{"type":"token_usage_record","timestamp":"2026-10-05T12:00:02Z","payload":{"thread_id":"thread-main","session_id":"exec-1","response_id":"resp-1","model":"gpt-6.1-sol","usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":30},"thread_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":30}}}"#,
            // Mirrored legacy token_count for the same cumulative total must not double-count.
            #"{"type":"event_msg","timestamp":"2026-10-05T12:00:02Z","payload":{"type":"token_count","info":{"model":"gpt-6.1-sol","last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":30,"total_tokens":130},"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":30,"total_tokens":130}}}}"#,
            // Foreign parent/subagent record must be rejected.
            #"{"type":"token_usage_record","timestamp":"2026-10-05T12:00:03Z","payload":{"thread_id":"foreign-thread","session_id":"exec-1","response_id":"resp-foreign","model":"gpt-6.1-sol","usage":{"input_tokens":900,"cached_input_tokens":0,"output_tokens":100},"thread_token_usage":{"input_tokens":1000,"cached_input_tokens":20,"output_tokens":130}}}"#,
        ].joined(separator: "\n") + "\n"
        try Data(lines.utf8).write(to: sessionURL)

        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-05T15:00:00Z"))
        var options = CostUsageScanner.Options(
            codexSessionsRoot: root.appendingPathComponent("sessions", isDirectory: true),
            cacheRoot: root.appendingPathComponent("cache", isDirectory: true),
            codexTraceDatabaseURL: root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: now.addingTimeInterval(-86_400),
            until: now,
            now: now,
            options: options)
        #expect(report.summary?.totalTokens == 130)
    }

    @Test
    func `merged historical OpenAI Claude Fable and Pi 1h cache pricing evaluate accurately`() throws {
        // Historical GPT-5.6 Sol before 2026-08-21 cutoff ($5/$30) vs after ($4/$20).
        let cutoff = Date(timeIntervalSince1970: 1_787_270_400)
        let emptyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pricing-empty-\(UUID().uuidString)")
        let historicalSol = try #require(CostUsagePricing.codexCostUSD(
            model: "gpt-5.6-sol",
            inputTokens: 100,
            cachedInputTokens: 10,
            outputTokens: 5,
            pricingDate: cutoff.addingTimeInterval(-60),
            modelsDevCacheRoot: emptyRoot))
        let currentSol = try #require(CostUsagePricing.codexCostUSD(
            model: "gpt-5.6-sol",
            inputTokens: 100,
            cachedInputTokens: 10,
            outputTokens: 5,
            pricingDate: cutoff.addingTimeInterval(60),
            modelsDevCacheRoot: emptyRoot))
        #expect(abs(historicalSol - 0.000605) < 1e-12)
        #expect(abs(currentSol - 0.000464) < 1e-12)

        // Claude Fable 5.1 with 1-hour cache creation tokens.
        let fableCost = try #require(CostUsagePricing.claudeCostUSD(
            model: "claude-fable-5-1",
            inputTokens: 70,
            cacheReadInputTokens: 10,
            cacheCreationInputTokens: 20,
            cacheCreationInputTokens1h: 5,
            outputTokens: 5,
            modelsDevCacheRoot: emptyRoot))
        // (70*10 + 10*0.25 + 15*12.5 + 5*20 + 5*50) / 1_000_000 = 1240 / 1_000_000 = 0.00124
        #expect(abs(fableCost - 0.00124) < 1e-12)
    }

    @Test
    func `inspector discovers external APIs across all five clients and adopts them without overwriting`() throws {
        let fixture = try ExternalRelayTestFixture()
        defer { fixture.cleanup() }

        // 1. Codex: CC Switch style external provider `packycode` + OPENAI_API_KEY in auth.json.
        try fixture.write("""
        model_provider = "packycode"
        model = "gpt-5.4"

        [model_providers.packycode]
        name = "PackyCode"
        base_url = "https://api.packycode.com/v1"
        wire_api = "responses"
        """, to: fixture.paths.codexConfigURL)
        try fixture.write(
            #"{"OPENAI_API_KEY":"sk-packy-secret"}"#,
            to: fixture.paths.codexConfigURL.deletingLastPathComponent().appendingPathComponent("auth.json"))

        // 2. Claude Code: CC Switch local proxy with JSONC comment.
        try fixture.write("""
        {
          // Written externally by CC Switch
          "permissions": { "allow": ["Read"] },
          "env": {
            "ANTHROPIC_BASE_URL": "http://127.0.0.1:15721",
            "ANTHROPIC_AUTH_TOKEN": "sk-cc-switch-local",
            "ANTHROPIC_MODEL": "claude-sonnet-4-6",
          }
        }
        """, to: fixture.paths.claudeCodeSettingsURL)

        // 3. Grok Build: external `personal` model section.
        try fixture.write("""
        [models]
        default = "personal"

        [model."personal"]
        name = "Personal Grok"
        model = "grok-4"
        base_url = "https://grok.personal.example/v1"
        api_key = "sk-grok-personal"
        api_backend = "responses"
        """, to: fixture.paths.grokBuildConfigURL)

        // 4. OpenCode: JSONC with same `packycode` provider + extra `openrouter` catalog entry.
        try fixture.write("""
        {
          // User OpenCode JSONC config
          "$schema": "https://opencode.ai/config.json",
          "model": "packycode/gpt-5.4-mini",
          "provider": {
            "packycode": {
              "npm": "@ai-sdk/openai-compatible",
              "name": "PackyCode",
              "options": {
                "baseURL": "https://api.packycode.com/v1/",
                "apiKey": "sk-packy-secret",
              },
              "models": {
                "gpt-5.4-mini": { "name": "GPT-5.4 Mini" }
              }
            },
            "openrouter": {
              "npm": "@ai-sdk/openai-compatible",
              "name": "OpenRouter",
              "options": {
                "baseURL": "https://openrouter.ai/api/v1",
                "apiKey": "{env:OPENROUTER_API_KEY}"
              }
            }
          }
        }
        """, to: fixture.paths.openCodeConfigURL)

        // 5. Pi Agent: external `magpie` provider with key in ~/.pi/agent/auth.json.
        try fixture.write(
            #"{"defaultProvider":"magpie","defaultModel":"deepseek-v4"}"#,
            to: fixture.paths.piAgentSettingsURL)
        try fixture.write(
            #"{"providers":{"magpie":{"name":"Magpie","baseUrl":"https://magpie.example.tech/v1","api":"openai-completions","models":[{"id":"deepseek-v4"}]}}}"#,
            to: fixture.paths.piAgentModelsURL)
        try fixture.write(
            #"{"magpie":{"type":"api_key","key":"sk-magpie-native"}}"#,
            to: fixture.paths.piAgentModelsURL.deletingLastPathComponent().appendingPathComponent("auth.json"))

        let initialReport = RelayExternalConfigurationInspector.inspect(
            paths: fixture.paths,
            profiles: [])

        // Verify live active routes are all detected as `.external` rather than falsely `.official`.
        for target in [RelayTargetApp.codex, .claudeCode, .grokBuild, .openCode, .piAgent] {
            guard case .external = initialReport.liveRouteByTarget[target] else {
                Issue.record("Expected external active route for \(target), got \(String(describing: initialReport.liveRouteByTarget[target]))")
                continue
            }
        }

        // PackyCode across Codex + OpenCode is grouped into a single DiscoveredExternalRelay!
        let packy = try #require(initialReport.unimportedRelays.first { $0.providerKey == "packycode" })
        #expect(Set(packy.configuredTargets) == [.codex, .openCode])
        #expect(Set(packy.activeTargets) == [.codex, .openCode])
        #expect(packy.importableAPIKey == "sk-packy-secret")

        let ccSwitch = try #require(initialReport.unimportedRelays.first { $0.displayName == "CC Switch Local" })
        #expect(ccSwitch.configuredTargets == [.claudeCode])
        #expect(ccSwitch.importableAPIKey == "sk-cc-switch-local")

        let magpie = try #require(initialReport.unimportedRelays.first { $0.providerKey == "magpie" })
        #expect(magpie.importableAPIKey == "sk-magpie-native")

        let openRouter = try #require(initialReport.unimportedRelays.first { $0.providerKey == "openrouter" })
        #expect(openRouter.activeTargets.isEmpty)
        #expect(openRouter.credentialKind == .environmentVariable("OPENROUTER_API_KEY"))

        // Adopting PackyCode into Headroom profiles immediately reconciles Codex & OpenCode as `.managedProfile`
        // without touching or erasing OpenCode's JSONC comments!
        let importedPacky = packy.makeRelayProfile(
            existingProfiles: [],
            externalProviderBaseURLsByKey: initialReport.externalProviderBaseURLsByKey)
        #expect(importedPacky.providerKey == "packycode")
        #expect(importedPacky.configuration(for: .codex)?.model == "gpt-5.4")
        #expect(importedPacky.configuration(for: .openCode)?.model == "gpt-5.4-mini")
        #expect(importedPacky.configuration(for: .openCode)?.apiFormatOverride == .openAIChatCompletions)

        let postImportReport = RelayExternalConfigurationInspector.inspect(
            paths: fixture.paths,
            profiles: [importedPacky])
        #expect(postImportReport.liveRouteByTarget[.codex] == .managedProfile(importedPacky.id))
        #expect(postImportReport.liveRouteByTarget[.openCode] == .managedProfile(importedPacky.id))
        #expect(!postImportReport.unimportedRelays.contains { $0.providerKey == "packycode" })

        // Verify providerKey collision disambiguation when adding a different `PackyCode` endpoint.
        let disambiguatedKey = RelayExternalConfigurationInspector.nonConflictingProviderKey(
            preferredName: "PackyCode",
            baseURL: URL(string: "https://another-endpoint.example/v1")!,
            profileID: UUID(),
            existingProfiles: [importedPacky],
            externalProviderBaseURLsByKey: postImportReport.externalProviderBaseURLsByKey)
        #expect(disambiguatedKey == "packycode-headroom")
    }

    @Test
    func `surgical restore and external official reset preserve post-baseline providers MCPs and permissions`() throws {
        let fixture = try ExternalRelayTestFixture()
        defer { fixture.cleanup() }

        // Seed initial Official state and capture Headroom baseline on Day 1.
        try fixture.write("model = \"gpt-5-codex\"\n", to: fixture.paths.codexConfigURL)
        try fixture.write(#"{"model":"claude-sonnet-4-6"}"#, to: fixture.paths.claudeCodeSettingsURL)
        try fixture.write(#"{"$schema":"https://opencode.ai/config.json"}"#, to: fixture.paths.openCodeConfigURL)
        let baseline = try fixture.transaction.captureBaseline(paths: fixture.paths)

        let headroomProfile = RelayProfile(
            name: "Work Sub2API",
            baseURL: URL(string: "https://sub2api.example/v1")!,
            apiFormat: .openAIResponses,
            credentialReference: "ref-work",
            credentialConfigured: true,
            targets: [
                .init(app: .codex, model: "gpt-6.1-sol", isEnabled: true),
                .init(app: .grokBuild, model: "grok-4", isEnabled: true),
                .init(app: .openCode, model: "gpt-6.1-sol", isEnabled: true),
                .init(app: .piAgent, model: "gpt-6.1-sol", isEnabled: true),
            ],
            providerKey: "work-sub2api")
        _ = try fixture.transaction.apply(
            profile: headroomProfile,
            paths: fixture.paths,
            credentialStore: fixture.credentials)

        let claudeProfile = RelayProfile(
            name: "Claude Relay",
            baseURL: URL(string: "https://claude-relay.example")!,
            apiFormat: .anthropicMessages,
            credentialReference: "ref-claude",
            credentialConfigured: true,
            targets: [.init(app: .claudeCode, model: "claude-opus-4-6", isEnabled: true)],
            providerKey: "claude-relay")
        _ = try fixture.transaction.apply(
            profile: claudeProfile,
            paths: fixture.paths,
            credentialStore: fixture.credentials)

        // Simulate Day 3 external tools (CC Switch / `codex mcp` / `claude mcp`) adding providers & settings!
        let codexAfterExternal = try String(contentsOf: fixture.paths.codexConfigURL, encoding: .utf8) + """

        [mcp_servers.github]
        command = "npx"

        [model_providers.packycode]
        name = "PackyCode"
        base_url = "https://api.packycode.com/v1"
        wire_api = "responses"
        """
        try fixture.write(codexAfterExternal, to: fixture.paths.codexConfigURL)

        var claudeObj = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.paths.claudeCodeSettingsURL)) as? [String: Any])
        claudeObj["permissions"] = ["allow": ["Bash(git status)"]]
        claudeObj["mcpServers"] = ["filesystem": ["command": "npx"]]
        var claudeEnv = (claudeObj["env"] as? [String: Any]) ?? [:]
        claudeEnv["HTTP_PROXY"] = "http://127.0.0.1:7890"
        claudeObj["env"] = claudeEnv
        try JSONSerialization.data(withJSONObject: claudeObj, options: [.prettyPrinted, .sortedKeys])
            .write(to: fixture.paths.claudeCodeSettingsURL)

        let grokAfterExternal = try String(contentsOf: fixture.paths.grokBuildConfigURL, encoding: .utf8) + """

        [model."cc-external"]
        name = "CC External"
        model = "grok-external"
        base_url = "https://external.grok.example/v1"
        api_key = "sk-ext"
        api_backend = "responses"
        """
        try fixture.write(grokAfterExternal, to: fixture.paths.grokBuildConfigURL)

        var openCodeObj = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.paths.openCodeConfigURL)) as? [String: Any])
        var openCodeProviders = (openCodeObj["provider"] as? [String: Any]) ?? [:]
        openCodeProviders["openrouter"] = [
            "npm": "@ai-sdk/openai-compatible",
            "options": ["baseURL": "https://openrouter.ai/api/v1"],
        ]
        openCodeObj["provider"] = openCodeProviders
        try JSONSerialization.data(withJSONObject: openCodeObj, options: [.prettyPrinted, .sortedKeys])
            .write(to: fixture.paths.openCodeConfigURL)

        // Day 5: Restore baseline across all targets!
        _ = try fixture.transaction.restore(backupDirectory: baseline, paths: fixture.paths)

        let restoredCodex = try String(contentsOf: fixture.paths.codexConfigURL, encoding: .utf8)
        #expect(restoredCodex.contains("model = \"gpt-5-codex\""))
        #expect(!restoredCodex.contains("codexbar_relay"))
        #expect(restoredCodex.contains("[mcp_servers.github]"))
        #expect(restoredCodex.contains("[model_providers.packycode]"))

        let restoredClaude = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.paths.claudeCodeSettingsURL)) as? [String: Any])
        #expect(restoredClaude["model"] as? String == "claude-sonnet-4-6")
        #expect(restoredClaude["apiKeyHelper"] == nil)
        #expect((restoredClaude["mcpServers"] as? [String: Any])?["filesystem"] != nil)
        #expect((restoredClaude["permissions"] as? [String: Any]) != nil)
        let restoredClaudeEnv = try #require(restoredClaude["env"] as? [String: Any])
        #expect(restoredClaudeEnv["ANTHROPIC_BASE_URL"] == nil)
        #expect(restoredClaudeEnv["HTTP_PROXY"] as? String == "http://127.0.0.1:7890")

        let restoredGrok = try String(contentsOf: fixture.paths.grokBuildConfigURL, encoding: .utf8)
        #expect(!restoredGrok.contains("default = \"work-sub2api\""))
        #expect(restoredGrok.contains("[model.\"cc-external\"]"))

        let restoredOpenCode = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.paths.openCodeConfigURL)) as? [String: Any])
        #expect(restoredOpenCode["model"] == nil)
        #expect((restoredOpenCode["provider"] as? [String: Any])?["openrouter"] != nil)

        // Finally, verify `restoreOfficialWithoutBaseline` when an external tool later activates `packycode` directly!
        let externallyActivatedCodex = "model_provider = \"packycode\"\n" + restoredCodex
        try fixture.write(externallyActivatedCodex, to: fixture.paths.codexConfigURL)
        _ = try fixture.transaction.restoreOfficialWithoutBaseline(
            targets: [.codex],
            paths: fixture.paths)
        let resetCodex = try String(contentsOf: fixture.paths.codexConfigURL, encoding: .utf8)
        #expect(!resetCodex.contains("model_provider = \"packycode\""))
        #expect(resetCodex.contains("[model_providers.packycode]"))
    }
}

private struct ExternalRelayTestFixture {
    let root: URL
    let paths: RelayConfigurationPaths
    let credentials = InMemoryCredentialStore()
    let transaction = RelayConfigurationTransaction()

    init() throws {
        self.root = FileManager.default.temporaryDirectory
            .appendingPathComponent("headroom-ext-relay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        self.paths = RelayConfigurationPaths(
            codexConfigURL: self.root.appendingPathComponent(".codex/config.toml"),
            claudeCodeSettingsURL: self.root.appendingPathComponent(".claude/settings.json"),
            claudeDesktopNormalConfigURL: self.root.appendingPathComponent("Claude/config.json"),
            claudeDesktopThreePConfigURL: self.root.appendingPathComponent("Claude-3p/config.json"),
            claudeDesktopProfileURL: self.root.appendingPathComponent("Claude-3p/profile.json"),
            claudeDesktopMetaURL: self.root.appendingPathComponent("Claude-3p/meta.json"),
            grokBuildConfigURL: self.root.appendingPathComponent(".grok/config.toml"),
            openCodeConfigURL: self.root.appendingPathComponent(".config/opencode/opencode.json"),
            piAgentSettingsURL: self.root.appendingPathComponent(".pi/agent/settings.json"),
            piAgentModelsURL: self.root.appendingPathComponent(".pi/agent/models.json"),
            credentialHelperURL: self.root.appendingPathComponent("Helpers/CodexBarCLI"),
            backupRootURL: self.root.appendingPathComponent("backups", isDirectory: true))
    }

    func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: self.root)
    }
}

private struct InMemoryCredentialStore: RelayCredentialStoring, RelayCredentialLocating {
    func loadCredential(reference: String) throws -> String? {
        "secret-for-\(reference)"
    }

    func storeCredential(_: String, reference _: String) throws {}
    func removeCredential(reference _: String) throws {}

    func locator(for reference: String) throws -> RelayCredentialLocator {
        RelayCredentialLocator(service: "com.ddaxia.headroom.test", account: reference)
    }
}
