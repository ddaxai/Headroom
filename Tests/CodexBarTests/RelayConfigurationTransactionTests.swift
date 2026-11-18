import CodexBarCore
import Foundation
import Testing

struct RelayConfigurationTransactionTests {
    @Test
    func `baseline restore covers targets introduced by later profiles`() throws {
        let fixture = try RelayTransactionFixture()
        defer { fixture.cleanup() }
        let originalCodex = "model = \"official-model\"\n"
        try fixture.write(originalCodex, to: fixture.paths.codexConfigURL)
        let baseline = try fixture.transaction.captureBaseline(paths: fixture.paths)

        _ = try fixture.transaction.apply(
            profile: fixture.profile(targets: [.init(app: .codex, model: "gpt-test")]),
            paths: fixture.paths,
            credentialStore: fixture.credentials)

        try fixture.write(
            #"{"$schema":"https://opencode.ai/config.json"}"#,
            to: fixture.paths.openCodeConfigURL)
        _ = try fixture.transaction.apply(
            profile: fixture.profile(targets: [.init(app: .openCode, model: "gpt-test")]),
            paths: fixture.paths,
            credentialStore: fixture.credentials)

        _ = try fixture.transaction.restore(backupDirectory: baseline, paths: fixture.paths)

        #expect(try String(contentsOf: fixture.paths.codexConfigURL, encoding: .utf8) == originalCodex)
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.openCodeConfigURL.path))
    }

    @Test
    func `scoped restore only mutates the requested target`() throws {
        let fixture = try RelayTransactionFixture()
        defer { fixture.cleanup() }
        let originalCodex = "model = \"official\"\n"
        let originalClaude = "{\"model\":\"official\"}\n"
        try fixture.write(originalCodex, to: fixture.paths.codexConfigURL)
        try fixture.write(originalClaude, to: fixture.paths.claudeCodeSettingsURL)
        let baseline = try fixture.transaction.captureBaseline(paths: fixture.paths)

        try fixture.write("model = \"relay\"\n", to: fixture.paths.codexConfigURL)
        try fixture.write("{\"model\":\"relay\"}\n", to: fixture.paths.claudeCodeSettingsURL)

        _ = try fixture.transaction.restore(
            backupDirectory: baseline,
            paths: fixture.paths,
            targets: [.codex])

        #expect(try String(contentsOf: fixture.paths.codexConfigURL, encoding: .utf8) == originalCodex)
        #expect(try String(contentsOf: fixture.paths.claudeCodeSettingsURL, encoding: .utf8) ==
            "{\"model\":\"relay\"}\n")
    }

    @Test
    func `Codex switch preserves unrelated TOML and official auth then restores backup`() throws {
        let fixture = try RelayTransactionFixture()
        defer { fixture.cleanup() }
        let originalConfig = """
        model = "official-model"

        [features]
        web_search = true
        """
        try fixture.write(originalConfig, to: fixture.paths.codexConfigURL)
        let authURL = fixture.root.appendingPathComponent(".codex/auth.json")
        try fixture.write(#"{"tokens":{"access_token":"official"}}"#, to: authURL)

        let result = try fixture.transaction.apply(
            profile: fixture.profile(targets: [.init(app: .codex, model: "gpt-test")]),
            paths: fixture.paths,
            credentialStore: fixture.credentials)

        let switched = try String(contentsOf: fixture.paths.codexConfigURL, encoding: .utf8)
        let testSecret = try #require(fixture.credentials.secret)
        #expect(switched.contains("[features]"))
        #expect(switched.contains("model_provider = \"codexbar_relay\""))
        #expect(switched.contains("[model_providers.codexbar_relay.auth]"))
        #expect(switched.contains("https://relay.example/v1"))
        #expect(!switched.contains(testSecret))
        #expect(try String(contentsOf: authURL, encoding: .utf8).contains("official"))
        let backup = try #require(result.backupDirectory)

        _ = try fixture.transaction.restore(backupDirectory: backup, paths: fixture.paths)
        #expect(try String(contentsOf: fixture.paths.codexConfigURL, encoding: .utf8) == originalConfig)
    }

    @Test
    func `OpenAI relay is rejected for Claude Code without protocol conversion`() throws {
        let fixture = try RelayTransactionFixture()
        defer { fixture.cleanup() }
        let profile = fixture.profile(targets: [.init(app: .claudeCode)])

        #expect(throws: RelayConfigurationError.incompatibleAPIFormat(
            app: .claudeCode,
            actual: .openAIResponses,
            supported: [.anthropicMessages]))
        {
            _ = try fixture.transaction.apply(
                profile: profile,
                paths: fixture.paths,
                credentialStore: fixture.credentials)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.claudeCodeSettingsURL.path))
    }

    @Test
    func `Claude Desktop direct file mutation remains unsupported`() throws {
        let fixture = try RelayTransactionFixture()
        defer { fixture.cleanup() }
        let profile = fixture.profile(
            format: .anthropicMessages,
            targets: [.init(app: .claudeDesktop)])

        #expect(throws: RelayConfigurationError.self) {
            _ = try fixture.transaction.apply(
                profile: profile,
                paths: fixture.paths,
                credentialStore: fixture.credentials)
        }
    }

    @Test
    func `OpenCode refuses an ambiguous empty schema`() throws {
        let fixture = try RelayTransactionFixture()
        defer { fixture.cleanup() }
        try fixture.write("{}", to: fixture.paths.openCodeConfigURL)

        #expect(throws: RelayConfigurationError.schemaVersionRequired(.openCode)) {
            _ = try fixture.transaction.apply(
                profile: fixture.profile(targets: [.init(app: .openCode, model: "gpt-test")]),
                paths: fixture.paths,
                credentialStore: fixture.credentials)
        }
    }

    @Test
    func `OpenCode creates a new V1 configuration when no file exists`() throws {
        let fixture = try RelayTransactionFixture()
        defer { fixture.cleanup() }

        _ = try fixture.transaction.apply(
            profile: fixture.profile(targets: [.init(app: .openCode, model: "gpt-test")]),
            paths: fixture.paths,
            credentialStore: fixture.credentials)

        let data = try Data(contentsOf: fixture.paths.openCodeConfigURL)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["model"] as? String == "codexbar-relay/gpt-test")
        #expect((root["provider"] as? [String: Any])?["codexbar-relay"] != nil)
    }

    @Test
    func `OpenCode switch preserves model limits and reasoning options`() throws {
        let fixture = try RelayTransactionFixture()
        defer { fixture.cleanup() }
        try fixture.write(
            #"""
            {"$schema":"https://opencode.ai/config.json","provider":{"codexbar-relay":{
            "npm":"@ai-sdk/openai-compatible","models":{"gpt-test":{
            "limit":{"context":272000},"options":{"reasoningEffort":"high"}},"other-model":{}}}}}
            """#,
            to: fixture.paths.openCodeConfigURL)
        _ = try fixture.transaction.apply(
            profile: fixture.profile(targets: [.init(app: .openCode, model: "gpt-test")]),
            paths: fixture.paths,
            credentialStore: fixture.credentials)
        let root = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.paths.openCodeConfigURL)) as? [String: Any])
        let providers = try #require(root["provider"] as? [String: Any])
        let provider = try #require(providers["codexbar-relay"] as? [String: Any])
        let models = try #require(provider["models"] as? [String: Any])
        let model = try #require(models["gpt-test"] as? [String: Any])
        #expect(models.count == 2)
        #expect((model["limit"] as? [String: Int])?["context"] == 272_000)
        #expect((model["options"] as? [String: String])?["reasoningEffort"] == "high")
    }

    @Test
    func `Pi restore without baseline settings retains later preferences`() throws {
        let fixture = try RelayTransactionFixture()
        defer { fixture.cleanup() }
        let baseline = try fixture.transaction.captureBaseline(paths: fixture.paths)
        try fixture.write(
            #"{"defaultProvider":"relay","defaultModel":"gpt-test","defaultThinkingLevel":"high"}"#,
            to: fixture.paths.piAgentSettingsURL)
        _ = try fixture.transaction.restore(backupDirectory: baseline, paths: fixture.paths, targets: [.piAgent])
        let root = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.paths.piAgentSettingsURL)) as? [String: Any])
        #expect(root["defaultProvider"] == nil)
        #expect(root["defaultModel"] == nil)
        #expect(root["defaultThinkingLevel"] as? String == "high")
    }

    @Test
    func `Chinese profile name writes its pinyin key to OpenCode and Pi`() throws {
        let fixture = try RelayTransactionFixture()
        defer { fixture.cleanup() }
        let baseURL = try #require(URL(string: "https://relay.example/"))
        let profile = RelayProfile(
            name: "梁",
            baseURL: baseURL,
            apiFormat: .openAIResponses,
            credentialReference: "test-reference",
            targets: [
                .init(app: .codex, model: "gpt-test"),
                .init(app: .openCode, model: "gpt-test"),
                .init(app: .piAgent, model: "gpt-test"),
            ])

        _ = try fixture.transaction.apply(
            profile: profile,
            paths: fixture.paths,
            credentialStore: fixture.credentials)

        let openCode = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: fixture.paths.openCodeConfigURL)) as? [String: Any])
        #expect(openCode["model"] as? String == "liang/gpt-test")
        #expect((openCode["provider"] as? [String: Any])?["liang"] != nil)

        let settings = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: fixture.paths.piAgentSettingsURL)) as? [String: Any])
        #expect(settings["defaultProvider"] as? String == "liang")
        let models = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: fixture.paths.piAgentModelsURL)) as? [String: Any])
        #expect((models["providers"] as? [String: Any])?["liang"] != nil)

        let codex = try String(contentsOf: fixture.paths.codexConfigURL, encoding: .utf8)
        #expect(codex.contains("model_provider = \"codexbar_relay\""))
        #expect(!codex.contains("model_provider = \"liang\""))
    }

    @Test
    func `Chinese profile name writes its pinyin key to Grok`() throws {
        let fixture = try RelayTransactionFixture()
        defer { fixture.cleanup() }
        let baseURL = try #require(URL(string: "https://relay.example/"))
        let profile = RelayProfile(
            name: "梁",
            baseURL: baseURL,
            apiFormat: .openAIResponses,
            credentialReference: "test-reference",
            targets: [.init(app: .grokBuild, model: "grok-test")])

        _ = try fixture.transaction.apply(
            profile: profile,
            paths: fixture.paths,
            credentialStore: fixture.credentials)

        let switched = try String(contentsOf: fixture.paths.grokBuildConfigURL, encoding: .utf8)
        #expect(switched.contains("default = \"liang\""))
        #expect(switched.contains("[model.\"liang\"]"))
        #expect(switched.contains("name = \"梁\""))
    }

    @Test
    func `Pi target writes provider model and preserves unrelated configuration`() throws {
        let fixture = try RelayTransactionFixture()
        defer { fixture.cleanup() }
        try fixture.write(
            #"{"theme":"dark","defaultProvider":"official","defaultModel":"official-model"}"#,
            to: fixture.paths.piAgentSettingsURL)
        try fixture.write(
            #"{"providers":{"existing":{"baseUrl":"https://existing.example","api":"openai-responses","models":[]}},"metadata":{"keep":true}}"#,
            to: fixture.paths.piAgentModelsURL)

        let result = try fixture.transaction.apply(
            profile: fixture.profile(targets: [.init(app: .piAgent, model: "gpt-test")]),
            paths: fixture.paths,
            credentialStore: fixture.credentials)

        let settings = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: fixture.paths.piAgentSettingsURL)) as? [String: Any])
        let models = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: fixture.paths.piAgentModelsURL)) as? [String: Any])
        let provider = try #require((models["providers"] as? [String: Any])?["codexbar-relay"] as? [String: Any])
        #expect(settings["defaultProvider"] as? String == "codexbar-relay")
        #expect(settings["defaultModel"] as? String == "gpt-test")
        #expect(provider["baseUrl"] as? String == "https://relay.example/v1")
        #expect(provider["api"] as? String == "openai-responses")
        #expect(provider["apiKey"] as? String != fixture.credentials.secret)
        #expect((models["metadata"] as? [String: Any])?["keep"] as? Bool == true)
        #expect(result.preview.changedTargets == [.piAgent])

        let backup = try #require(result.backupDirectory)
        _ = try fixture.transaction.restore(backupDirectory: backup, paths: fixture.paths)
        #expect(try String(contentsOf: fixture.paths.piAgentSettingsURL, encoding: .utf8).contains("official"))
        #expect(try String(contentsOf: fixture.paths.piAgentModelsURL, encoding: .utf8).contains("existing"))
    }

    @Test
    func `Pi switch retains catalog metadata and restore preserves later user edits`() throws {
        let fixture = try RelayTransactionFixture()
        defer { fixture.cleanup() }
        try fixture.write(
            #"{"defaultProvider":"official","defaultModel":"official-model","defaultThinkingLevel":"high"}"#,
            to: fixture.paths.piAgentSettingsURL)
        try fixture.write(
            #"""
            {"providers":{"codexbar-relay":{"baseUrl":"https://old.example",
            "models":[{"id":"gpt-test","reasoning":true,"contextWindow":272000},
            {"id":"other-model","maxTokens":64000}],"headers":{"keep":"yes"}},"retired":{"models":[]}}}
            """#,
            to: fixture.paths.piAgentModelsURL)
        let baseline = try fixture.transaction.captureBaseline(paths: fixture.paths)
        _ = try fixture.transaction.apply(
            profile: fixture.profile(targets: [.init(app: .piAgent, model: "gpt-test")]),
            paths: fixture.paths,
            credentialStore: fixture.credentials)
        var root = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.paths.piAgentModelsURL)) as? [String: Any])
        var providers = try #require(root["providers"] as? [String: Any])
        let provider = try #require(providers["codexbar-relay"] as? [String: Any])
        let models = try #require(provider["models"] as? [[String: Any]])
        #expect(models.count == 2)
        #expect(models.first?["contextWindow"] as? Int == 272_000)
        #expect(models.first?["reasoning"] as? Bool == true)
        #expect((provider["headers"] as? [String: String])?["keep"] == "yes")
        providers.removeValue(forKey: "retired")
        root["providers"] = providers
        let editedCatalog = try JSONSerialization.data(withJSONObject: root)
        try editedCatalog.write(to: fixture.paths.piAgentModelsURL)
        try fixture.write(
            #"""
            {"defaultProvider":"codexbar-relay","defaultModel":"gpt-test",
            "defaultThinkingLevel":"high","theme":"new-theme"}
            """#,
            to: fixture.paths.piAgentSettingsURL)
        _ = try fixture.transaction.restore(backupDirectory: baseline, paths: fixture.paths, targets: [.piAgent])
        #expect(try Data(contentsOf: fixture.paths.piAgentModelsURL) == editedCatalog)
        let settings = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.paths.piAgentSettingsURL)) as? [String: Any])
        #expect(settings["defaultProvider"] as? String == "official")
        #expect(settings["theme"] as? String == "new-theme")
        #expect(settings["defaultThinkingLevel"] as? String == "high")
    }

    @Test
    func `Pi target inherits the profile default model when no target override is set`() throws {
        let fixture = try RelayTransactionFixture()
        defer { fixture.cleanup() }
        var profile = fixture.profile(targets: [.init(app: .piAgent, model: nil)])
        profile.defaultModel = "shared-model"

        _ = try fixture.transaction.apply(
            profile: profile,
            paths: fixture.paths,
            credentialStore: fixture.credentials)

        let models = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: fixture.paths.piAgentModelsURL)) as? [String: Any])
        let provider = try #require((models["providers"] as? [String: Any])?["codexbar-relay"] as? [String: Any])
        let configuredModels = try #require(provider["models"] as? [[String: Any]])
        #expect(configuredModels.first?["id"] as? String == "shared-model")
    }

    @Test
    func `OpenCode-only apply preserves Codex content and modification time`() throws {
        let fixture = try RelayTransactionFixture()
        defer { fixture.cleanup() }
        let originalCodex = "model = \"official\"\n"
        let pinnedModificationDate = Date(timeIntervalSince1970: 1_700_000_000)
        try fixture.write(originalCodex, to: fixture.paths.codexConfigURL)
        try FileManager.default.setAttributes(
            [.modificationDate: pinnedModificationDate],
            ofItemAtPath: fixture.paths.codexConfigURL.path)

        _ = try fixture.transaction.apply(
            profile: fixture.profile(targets: [
                .init(app: .codex, model: "codex-model", isEnabled: false),
                .init(app: .openCode, model: "open-code-model", isEnabled: true),
            ]),
            paths: fixture.paths,
            credentialStore: fixture.credentials)

        let codexContent = try String(contentsOf: fixture.paths.codexConfigURL, encoding: .utf8)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.paths.codexConfigURL.path)
        let modificationDate = try #require(attributes[.modificationDate] as? Date)
        #expect(codexContent == originalCodex)
        #expect(modificationDate == pinnedModificationDate)
    }

    @Test
    func `OpenCode refuses to erase JSONC comments`() throws {
        let fixture = try RelayTransactionFixture()
        defer { fixture.cleanup() }
        let original = """
        {
          // Keep this explanation.
          "$schema": "https://opencode.ai/config.json",
        }
        """
        try fixture.write(original, to: fixture.paths.openCodeConfigURL)

        #expect(throws: RelayConfigurationError.self) {
            _ = try fixture.transaction.apply(
                profile: fixture.profile(targets: [.init(app: .openCode, model: "gpt-test")]),
                paths: fixture.paths,
                credentialStore: fixture.credentials)
        }
        #expect(try String(contentsOf: fixture.paths.openCodeConfigURL, encoding: .utf8) == original)
    }

    @Test
    func `dry run does not load an inline credential or write files`() throws {
        let fixture = try RelayTransactionFixture()
        defer { fixture.cleanup() }
        let noSecret = TestRelayCredentialStore(secret: nil)

        let result = try fixture.transaction.apply(
            profile: fixture.profile(targets: [.init(app: .grokBuild, model: "grok-test")]),
            paths: fixture.paths,
            credentialStore: noSecret,
            dryRun: true)

        #expect(result.wasDryRun)
        #expect(result.preview.changedTargets == [.grokBuild])
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.grokBuildConfigURL.path))
    }

    @Test
    func `Codex apply rejects a missing Keychain credential`() throws {
        let fixture = try RelayTransactionFixture()
        defer { fixture.cleanup() }
        let noSecret = TestRelayCredentialStore(secret: nil)

        #expect(throws: RelayConfigurationError.emptyCredential) {
            _ = try fixture.transaction.apply(
                profile: fixture.profile(targets: [.init(app: .codex, model: "gpt-test")]),
                paths: fixture.paths,
                credentialStore: noSecret)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.codexConfigURL.path))
    }

    @Test
    func `Grok switch preserves other model profiles and models metadata`() throws {
        let fixture = try RelayTransactionFixture()
        defer { fixture.cleanup() }
        let original = """
        [models]
        default = "personal"
        note = "keep-me"

        [model."personal"]
        model = "personal-model"
        base_url = "https://personal.example/v1"
        name = "Personal"
        env_key = "PERSONAL_KEY"
        api_backend = "responses"
        context_window = 100000
        """
        try fixture.write(original, to: fixture.paths.grokBuildConfigURL)

        _ = try fixture.transaction.apply(
            profile: fixture.profile(targets: [.init(app: .grokBuild, model: "grok-test")]),
            paths: fixture.paths,
            credentialStore: fixture.credentials)

        let switched = try String(contentsOf: fixture.paths.grokBuildConfigURL, encoding: .utf8)
        #expect(switched.contains("default = \"codexbar-relay\""))
        #expect(switched.contains("note = \"keep-me\""))
        #expect(switched.contains("[model.\"personal\"]"))
        #expect(switched.contains("[model.\"codexbar-relay\"]"))
    }

    @Test
    func `Codex switch replaces equivalent quoted managed tables without duplicates`() throws {
        let fixture = try RelayTransactionFixture()
        defer { fixture.cleanup() }
        let original = """
        model = "old"

        [model_providers."codexbar_relay"]
        base_url = "https://old.example/v1"

        [model_providers.'codexbar_relay'.auth]
        command = "old-helper"
        """
        try fixture.write(original, to: fixture.paths.codexConfigURL)

        _ = try fixture.transaction.apply(
            profile: fixture.profile(targets: [.init(app: .codex, model: "gpt-test")]),
            paths: fixture.paths,
            credentialStore: fixture.credentials)

        let switched = try String(contentsOf: fixture.paths.codexConfigURL, encoding: .utf8)
        #expect(!switched.contains("[model_providers.\"codexbar_relay\"]"))
        #expect(!switched.contains("[model_providers.'codexbar_relay'.auth]"))
        #expect(switched.components(separatedBy: "[model_providers.codexbar_relay]").count == 2)
        #expect(switched.components(separatedBy: "[model_providers.codexbar_relay.auth]").count == 2)
    }

    @Test
    func `Grok switch replaces an equivalent bare managed table`() throws {
        let fixture = try RelayTransactionFixture()
        defer { fixture.cleanup() }
        let original = """
        [models]
        default = "codexbar-relay"

        [model.codexbar-relay]
        model = "old-model"
        api_key = "old-test-value"
        api_backend = "responses"
        """
        try fixture.write(original, to: fixture.paths.grokBuildConfigURL)

        _ = try fixture.transaction.apply(
            profile: fixture.profile(targets: [.init(app: .grokBuild, model: "grok-test")]),
            paths: fixture.paths,
            credentialStore: fixture.credentials)

        let switched = try String(contentsOf: fixture.paths.grokBuildConfigURL, encoding: .utf8)
        #expect(!switched.contains("[model.codexbar-relay]"))
        #expect(switched.components(separatedBy: "[model.\"codexbar-relay\"]").count == 2)
    }

    @Test
    func `failed second target rolls the first target back`() throws {
        let fixture = try RelayTransactionFixture()
        defer { fixture.cleanup() }
        let original = "model = \"official\"\n"
        try fixture.write(original, to: fixture.paths.codexConfigURL)
        let failingFileSystem = FailOnceRelayFileSystem(failURL: fixture.paths.grokBuildConfigURL)
        let transaction = RelayConfigurationTransaction(fileSystem: failingFileSystem)
        let profile = fixture.profile(targets: [
            .init(app: .codex, model: "gpt-test"),
            .init(app: .grokBuild, model: "grok-test"),
        ])

        #expect(throws: RelayConfigurationError.self) {
            _ = try transaction.apply(
                profile: profile,
                paths: fixture.paths,
                credentialStore: fixture.credentials)
        }
        #expect(try String(contentsOf: fixture.paths.codexConfigURL, encoding: .utf8) == original)
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.grokBuildConfigURL.path))
        #expect(try fixture.backupDirectories().isEmpty)
    }

    @Test
    func `rollback continues restoring earlier files after one rollback operation fails`() throws {
        let fixture = try RelayTransactionFixture()
        defer { fixture.cleanup() }
        let original = "model = \"official\"\n"
        try fixture.write(original, to: fixture.paths.codexConfigURL)
        let fileSystem = ApplyAndRollbackFailureRelayFileSystem(failURL: fixture.paths.grokBuildConfigURL)
        let transaction = RelayConfigurationTransaction(fileSystem: fileSystem)

        #expect(throws: RelayConfigurationError.self) {
            _ = try transaction.apply(
                profile: fixture.profile(targets: [
                    .init(app: .codex, model: "gpt-test"),
                    .init(app: .grokBuild, model: "grok-test"),
                ]),
                paths: fixture.paths,
                credentialStore: fixture.credentials)
        }

        #expect(try String(contentsOf: fixture.paths.codexConfigURL, encoding: .utf8) == original)
    }

    @Test
    func `discard backup removes only a direct child of the configured root`() throws {
        let fixture = try RelayTransactionFixture()
        defer { fixture.cleanup() }
        let backup = try fixture.transaction.captureBaseline(paths: fixture.paths)
        #expect(FileManager.default.fileExists(atPath: backup.path))

        try fixture.transaction.discardBackup(directory: backup, paths: fixture.paths)
        #expect(!FileManager.default.fileExists(atPath: backup.path))

        #expect(throws: RelayConfigurationError.self) {
            try fixture.transaction.discardBackup(directory: fixture.root, paths: fixture.paths)
        }
    }
}

private struct RelayTransactionFixture {
    let root: URL
    let paths: RelayConfigurationPaths
    let credentials = TestRelayCredentialStore(secret: "test-secret-not-a-real-key")
    let transaction = RelayConfigurationTransaction()

    init() throws {
        self.root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-relay-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        self.paths = RelayConfigurationPaths(
            codexConfigURL: self.root.appendingPathComponent(".codex/config.toml"),
            claudeCodeSettingsURL: self.root.appendingPathComponent(".claude/settings.json"),
            claudeDesktopNormalConfigURL: self.root.appendingPathComponent("Claude/config.json"),
            claudeDesktopThreePConfigURL: self.root.appendingPathComponent("Claude-3p/config.json"),
            claudeDesktopProfileURL: self.root.appendingPathComponent("Claude-3p/profile.json"),
            claudeDesktopMetaURL: self.root.appendingPathComponent("Claude-3p/meta.json"),
            grokBuildConfigURL: self.root.appendingPathComponent(".grok/config.toml"),
            openCodeConfigURL: self.root.appendingPathComponent("opencode/opencode.jsonc"),
            piAgentSettingsURL: self.root.appendingPathComponent(".pi/agent/settings.json"),
            piAgentModelsURL: self.root.appendingPathComponent(".pi/agent/models.json"),
            credentialHelperURL: self.root.appendingPathComponent("CodexBarCLI"),
            backupRootURL: self.root.appendingPathComponent("backups", isDirectory: true))
    }

    func profile(
        format: RelayAPIFormat = .openAIResponses,
        targets: [RelayTargetConfiguration]) -> RelayProfile
    {
        RelayProfile(
            name: "Test Relay",
            baseURL: URL(string: "https://relay.example/")!,
            apiFormat: format,
            credentialReference: "test-reference",
            targets: targets,
            providerKey: "codexbar-relay")
    }

    func write(_ value: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try value.write(to: url, atomically: true, encoding: .utf8)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: self.root)
    }

    func backupDirectories() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: self.paths.backupRootURL.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: self.paths.backupRootURL,
            includingPropertiesForKeys: nil)
    }
}

private struct TestRelayCredentialStore: RelayCredentialStoring, RelayCredentialLocating {
    let secret: String?

    func loadCredential(reference _: String) throws -> String? {
        self.secret
    }

    func storeCredential(_: String, reference _: String) throws {}
    func removeCredential(reference _: String) throws {}

    func locator(for reference: String) throws -> RelayCredentialLocator {
        RelayCredentialLocator(service: "test.relay.credentials", account: reference)
    }
}

private final class FailOnceRelayFileSystem: RelayConfigurationFileSystem, @unchecked Sendable {
    private let base = LocalRelayConfigurationFileSystem()
    private let failURL: URL
    private let lock = NSLock()
    private var hasFailed = false

    init(failURL: URL) {
        self.failURL = failURL
    }

    func fileExists(at url: URL) -> Bool {
        self.base.fileExists(at: url)
    }

    func readData(at url: URL) throws -> Data {
        try self.base.readData(at: url)
    }

    func createSecureDirectory(at url: URL) throws {
        try self.base.createSecureDirectory(at: url)
    }

    func removeItem(at url: URL) throws {
        try self.base.removeItem(at: url)
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        self.lock.lock()
        let shouldFail = url == self.failURL && !self.hasFailed
        if shouldFail { self.hasFailed = true }
        self.lock.unlock()
        if shouldFail { throw TestFailure.injected }
        try self.base.writeAtomically(data, to: url)
    }

    private enum TestFailure: Error {
        case injected
    }
}

private final class ApplyAndRollbackFailureRelayFileSystem: RelayConfigurationFileSystem, @unchecked Sendable {
    private let base = LocalRelayConfigurationFileSystem()
    private let failURL: URL
    private let lock = NSLock()
    private var applyFailureInjected = false

    init(failURL: URL) {
        self.failURL = failURL
    }

    func fileExists(at url: URL) -> Bool {
        self.base.fileExists(at: url)
    }

    func readData(at url: URL) throws -> Data {
        try self.base.readData(at: url)
    }

    func createSecureDirectory(at url: URL) throws {
        try self.base.createSecureDirectory(at: url)
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        self.lock.lock()
        let shouldFail = url == self.failURL && !self.applyFailureInjected
        if shouldFail { self.applyFailureInjected = true }
        self.lock.unlock()
        if shouldFail { throw TestFailure.apply }
        try self.base.writeAtomically(data, to: url)
    }

    func removeItem(at url: URL) throws {
        if url == self.failURL { throw TestFailure.rollback }
        try self.base.removeItem(at: url)
    }

    private enum TestFailure: Error {
        case apply
        case rollback
    }
}
