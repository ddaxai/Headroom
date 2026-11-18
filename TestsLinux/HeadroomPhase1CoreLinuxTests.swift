import Foundation
import Testing
@testable import CodexBarCore

struct HeadroomPhase1CoreLinuxTests {
    @Test
    func `app group identifier uses Headroom bundle identifier and strips widget suffix`() {
        #expect(
            AppGroupSupport.currentGroupID(teamID: "Y5PE65HELJ", bundleID: "com.ddaxia.headroom")
                == "Y5PE65HELJ.com.ddaxia.headroom")
        #expect(
            AppGroupSupport.currentGroupID(teamID: "Y5PE65HELJ", bundleID: "com.ddaxia.headroom.widget")
                == "Y5PE65HELJ.com.ddaxia.headroom")
        #expect(
            AppGroupSupport.currentGroupID(teamID: "Y5PE65HELJ", bundleID: nil)
                == "Y5PE65HELJ.com.ddaxia.headroom")
        #expect(
            AppGroupSupport.currentGroupID(teamID: "Y5PE65HELJ", bundleID: "com.steipete.codexbar")
                == "Y5PE65HELJ.com.steipete.codexbar")
    }

    @Test
    func `atomic configuration writer preserves existing dotfile symlinks`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("headroom-symlink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let realFile = root.appendingPathComponent("dotfiles/codex-config.toml")
        try FileManager.default.createDirectory(
            at: realFile.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("model = \"official\"\n".utf8).write(to: realFile)

        let symlinkURL = root.appendingPathComponent("live-config.toml")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: realFile)

        let fs = LocalRelayConfigurationFileSystem()
        try fs.writeAtomically(Data("model = \"relay\"\n".utf8), to: symlinkURL)

        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: symlinkURL.path)
        #expect(!destination.isEmpty)
        #expect(try String(contentsOf: realFile, encoding: .utf8) == "model = \"relay\"\n")
    }

    @Test
    func `switching profiles scrubs retired inline keys in Grok and OpenCode while keeping model limits`() throws {
        let fixture = try Self.Fixture()
        defer { fixture.cleanup() }

        let idA = UUID()
        let refA = RelayCredentialReference.make(for: idA)
        try fixture.credentials.storeCredential("secret-alpha-key", reference: refA)
        let profileA = RelayProfile(
            id: idA,
            name: "Alpha Relay",
            baseURL: try #require(URL(string: "https://alpha.example/v1")),
            apiFormat: .openAIResponses,
            defaultModel: "gpt-6.1-sol",
            credentialReference: refA,
            credentialConfigured: true,
            targets: [
                .init(app: .grokBuild, isEnabled: true),
                .init(app: .openCode, isEnabled: true),
            ])

        _ = try fixture.transaction.apply(
            profile: profileA,
            paths: fixture.paths,
            credentialStore: fixture.credentials)

        // Add custom model limits to Alpha in OpenCode before switching to Beta.
        var openCodeBefore = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.paths.openCodeConfigURL)) as? [String: Any])
        var providersBefore = try #require(openCodeBefore["provider"] as? [String: Any])
        var alphaBefore = try #require(providersBefore[profileA.providerKey] as? [String: Any])
        alphaBefore["models"] = ["gpt-6.1-sol": ["name": "gpt-6.1-sol", "limit": ["context": 272_000]]]
        providersBefore[profileA.providerKey] = alphaBefore
        openCodeBefore["provider"] = providersBefore
        try JSONSerialization.data(withJSONObject: openCodeBefore, options: [.prettyPrinted, .sortedKeys])
            .write(to: fixture.paths.openCodeConfigURL)

        let idB = UUID()
        let refB = RelayCredentialReference.make(for: idB)
        try fixture.credentials.storeCredential("secret-beta-key", reference: refB)
        let profileB = RelayProfile(
            id: idB,
            name: "Beta Relay",
            baseURL: try #require(URL(string: "https://beta.example/v1")),
            apiFormat: .openAIResponses,
            defaultModel: "gpt-6.1-terra",
            credentialReference: refB,
            credentialConfigured: true,
            targets: [
                .init(app: .grokBuild, isEnabled: true),
                .init(app: .openCode, isEnabled: true),
            ])

        _ = try fixture.transaction.apply(
            profile: profileB,
            paths: fixture.paths,
            credentialStore: fixture.credentials,
            retiredProviderKeys: [profileA.providerKey])

        let grokText = try String(contentsOf: fixture.paths.grokBuildConfigURL, encoding: .utf8)
        #expect(!grokText.contains("secret-alpha-key"))
        #expect(!grokText.contains("[model.\"\(profileA.providerKey)\"]"))
        #expect(grokText.contains("secret-beta-key"))

        let openCodeData = try Data(contentsOf: fixture.paths.openCodeConfigURL)
        let openCodeText = try #require(String(data: openCodeData, encoding: .utf8))
        #expect(!openCodeText.contains("secret-alpha-key"))
        #expect(openCodeText.contains("secret-beta-key"))
        let openCodeAfter = try #require(JSONSerialization.jsonObject(with: openCodeData) as? [String: Any])
        let providersAfter = try #require(openCodeAfter["provider"] as? [String: Any])
        let alphaAfter = try #require(providersAfter[profileA.providerKey] as? [String: Any])
        let alphaModels = try #require(alphaAfter["models"] as? [String: Any])
        let solModel = try #require(alphaModels["gpt-6.1-sol"] as? [String: Any])
        #expect((solModel["limit"] as? [String: Int])?["context"] == 272_000)

        // Scrubbing Beta on profile deletion removes Beta's inline keys too.
        _ = try fixture.transaction.scrubInlineCredentials(
            forProviderKeys: [profileB.providerKey],
            paths: fixture.paths)
        #expect(try !String(contentsOf: fixture.paths.grokBuildConfigURL, encoding: .utf8).contains("secret-beta-key"))
        #expect(try !String(contentsOf: fixture.paths.openCodeConfigURL, encoding: .utf8).contains("secret-beta-key"))
    }

    @Test
    func `Pi restore handles pre-Pi baseline and preserves unescaped slashes`() throws {
        let fixture = try Self.Fixture()
        defer { fixture.cleanup() }

        try fixture.write(
            #"{"defaultProvider":"official","defaultModel":"workbuddy-ai/deepseek-v4.1-flash"}"#,
            to: fixture.paths.piAgentSettingsURL)
        let baseline = try fixture.transaction.captureBaseline(paths: fixture.paths)

        try fixture.write(
            #"{"defaultProvider":"magpie","defaultModel":"other/model"}"#,
            to: fixture.paths.piAgentSettingsURL)
        _ = try fixture.transaction.restore(
            backupDirectory: baseline,
            paths: fixture.paths,
            targets: [.piAgent])
        let restoredText = try String(contentsOf: fixture.paths.piAgentSettingsURL, encoding: .utf8)
        #expect(restoredText.contains("workbuddy-ai/deepseek-v4.1-flash"))
        #expect(!restoredText.contains(#"\/"#))
        #expect(restoredText.hasSuffix("\n"))

        // Simulate a pre-Pi manifest without any .piAgent entries.
        let manifestURL = baseline.appendingPathComponent("manifest.json")
        var manifest = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        let entries = try #require(manifest["entries"] as? [[String: Any]])
        manifest["entries"] = entries.filter { ($0["target"] as? String) != RelayTargetApp.piAgent.rawValue }
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: manifestURL)

        try fixture.write(
            #"{"defaultProvider":"magpie","defaultModel":"other/model","defaultThinkingLevel":"high"}"#,
            to: fixture.paths.piAgentSettingsURL)
        _ = try fixture.transaction.restore(
            backupDirectory: baseline,
            paths: fixture.paths,
            targets: [.piAgent])
        let prePiRestored = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.paths.piAgentSettingsURL)) as? [String: Any])
        #expect(prePiRestored["defaultProvider"] == nil)
        #expect(prePiRestored["defaultModel"] == nil)
        #expect(prePiRestored["defaultThinkingLevel"] as? String == "high")
    }

    @Test
    func `LocalMeterRestoreService preserves unified history and records official route`() throws {
        let fixture = try Self.Fixture()
        defer { fixture.cleanup() }

        try fixture.write("model = \"gpt-6.1-sol\"\n", to: fixture.paths.codexConfigURL)
        let baseline = try fixture.transaction.captureBaseline(paths: fixture.paths)
        try fixture.write(
            "model = \"relay\"\nmodel_provider = \"codexbar_shared\"\nbase_url = \"http://127.0.0.1:47891\"\n",
            to: fixture.paths.codexConfigURL)

        let stateStore = LocalMeterActivationStateFileStore(
            fileURL: fixture.root.appendingPathComponent("activation.json"))
        try stateStore.save(LocalMeterActivationState(
            activeProfileIDsByTarget: [.codex: UUID()],
            baselineBackupDirectory: baseline))
        let timelineURL = fixture.root.appendingPathComponent("timeline.json")
        let ownershipStore = FileCodexSessionOwnershipTimelineStore(fileURL: timelineURL)

        let service = LocalMeterRestoreService(
            paths: fixture.paths,
            stateStore: stateStore,
            transaction: fixture.transaction,
            codexProviderMode: .unified,
            codexServiceTier: .fast,
            ownershipStore: ownershipStore)
        let report = try service.restoreOfficialReport()

        let restoredCodex = try String(contentsOf: fixture.paths.codexConfigURL, encoding: .utf8)
        #expect(restoredCodex.contains("model_provider = \"codexbar_shared\""))
        #expect(restoredCodex.contains("service_tier = \"fast\""))
        #expect(!FileManager.default.fileExists(atPath: baseline.path))
        let recoveryBackup = try #require(report.recoveryBackupDirectory)
        #expect(FileManager.default.fileExists(atPath: recoveryBackup.appendingPathComponent("manifest.json").path))
        let timeline = try ownershipStore.load()
        #expect(timeline.codexRouteEvents.last?.route == .official)
    }

    private struct Fixture {
        let root: URL
        let paths: RelayConfigurationPaths
        let credentials: FileRelayCredentialStore
        let transaction = RelayConfigurationTransaction()

        init() throws {
            self.root = FileManager.default.temporaryDirectory
                .appendingPathComponent("headroom-phase1-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            let config = self.root.appendingPathComponent("config", isDirectory: true)
            self.paths = RelayConfigurationPaths(
                codexConfigURL: config.appendingPathComponent("codex.toml"),
                claudeCodeSettingsURL: config.appendingPathComponent("claude.json"),
                claudeDesktopNormalConfigURL: config.appendingPathComponent("claude-desktop.json"),
                claudeDesktopThreePConfigURL: config.appendingPathComponent("claude-3p.json"),
                claudeDesktopProfileURL: config.appendingPathComponent("profile.json"),
                claudeDesktopMetaURL: config.appendingPathComponent("meta.json"),
                grokBuildConfigURL: config.appendingPathComponent("grok.toml"),
                openCodeConfigURL: config.appendingPathComponent("opencode.json"),
                piAgentSettingsURL: config.appendingPathComponent("pi-settings.json"),
                piAgentModelsURL: config.appendingPathComponent("pi-models.json"),
                credentialHelperURL: config.appendingPathComponent("CodexBarCLI"),
                backupRootURL: self.root.appendingPathComponent("backups", isDirectory: true))
            self.credentials = FileRelayCredentialStore(
                fileURL: self.root.appendingPathComponent("relay-credentials.json"))
        }

        func write(_ text: String, to url: URL) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: self.root)
        }
    }
}
