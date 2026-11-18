import AppKit
import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct CodexSpeedTests {
    @Test
    func `speed edit preserves routes credentials features and other agents`() throws {
        let fixture = try SpeedFixture()
        defer { fixture.cleanup() }
        let source = """
        # Keep the selected route
        model_provider = "fixture"
        "service_tier" = 'default' # previous preference
        model = "gpt-6.1-sol"

        [features]
        fast_mode = false
        [model_providers.fixture.auth]
        command = "/fixture/credential-helper"
        args = ["credential", "fixture"]
        """
        try fixture.write(source)
        let unrelated = fixture.paths.piAgentSettingsURL
        try FileManager.default.createDirectory(
            at: unrelated.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("untouched".utf8).write(to: unrelated)
        let result = try fixture.transaction.setCodexServiceTier(.fast, paths: fixture.paths)
        let changed = try fixture.read()
        #expect(changed == source.replacingOccurrences(
            of: "\"service_tier\" = 'default' # previous preference", with: "service_tier = \"fast\"")
            .replacingOccurrences(of: "fast_mode = false", with: "fast_mode = true"))
        #expect(try CodexServiceTier.configured(in: Data(changed.utf8)) == .fast)
        #expect(try Data(contentsOf: unrelated) == Data("untouched".utf8))
        let backup = try #require(result.backupDirectory)
        _ = try fixture.transaction.restore(backupDirectory: backup, paths: fixture.paths)
        #expect(try fixture.read() == source)
    }

    @Test
    func `top level speed ignores nested settings and preserves unknown tiers until selection`() throws {
        #expect(try CodexServiceTier.configured(in: nil) == .standard)
        #expect(try CodexServiceTier.configured(in: Data("service_tier = \"priority\"\n".utf8)) == .fast)
        #expect(try CodexServiceTier.configured(in: Data("service_tier = \"fast\"\r\n".utf8)) == .fast)
        #expect(try CodexServiceTier.configured(in: Data("service_tier = \"ultrafast\"\n".utf8)) == nil)
        let fixture = try SpeedFixture()
        defer { fixture.cleanup() }
        let source = "[profiles.other]\nservice_tier = \"fast\"\n"
        try fixture.write(source)
        #expect(try CodexServiceTier.configured(in: Data(source.utf8)) == .standard)
        _ = try fixture.transaction.setCodexServiceTier(.standard, paths: fixture.paths)
        #expect(try fixture.read() == "service_tier = \"default\"\n" + source)
    }

    @Test
    func `ambiguous config and concurrent edits refuse without changing the file`() throws {
        let fixture = try SpeedFixture()
        defer { fixture.cleanup() }
        for source in [
            "service_tier = \"fast\"\n'service_tier' = 'default'\n",
            "notes = '''multiline'''\n",
            "profile = \"work\"\n[profiles.work]\nservice_tier = \"fast\"\n",
        ] {
            try fixture.write(source)
            #expect(throws: RelayConfigurationError.self) {
                _ = try fixture.transaction.setCodexServiceTier(.fast, paths: fixture.paths)
            }
            #expect(try fixture.read() == source)
        }
        try fixture.write("model = \"new-value\"\n")
        #expect(throws: RelayConfigurationError.concurrentModification(fixture.paths.codexConfigURL)) {
            _ = try fixture.transaction.setCodexServiceTier(
                .fast, paths: fixture.paths, expectedConfiguration: Data("old-value".utf8))
        }
        #expect(try fixture.read() == "model = \"new-value\"\n")
    }

    @Test
    func `fast enables the canonical feature while preserving other flags`() throws {
        let fixture = try SpeedFixture()
        defer { fixture.cleanup() }
        for source in [
            "features.fast_mode = false\nfeatures.other_flag = false\n",
            "[features]\nother_flag = false\n",
            "model = \"gpt-6.1-sol\"\n",
        ] {
            try fixture.write(source)
            _ = try fixture.transaction.setCodexServiceTier(.fast, paths: fixture.paths)
            let fast = try fixture.read()
            #expect(fast.contains("fast_mode = true"))
            #expect(!fast.contains("fast_mode = false"))
            _ = try fixture.transaction.setCodexServiceTier(.standard, paths: fixture.paths)
            #expect(try fixture.read().contains("fast_mode = true"))
            #expect(try CodexServiceTier.configured(in: Data(fixture.read().utf8)) == .standard)
        }
        let ambiguous = "features = { fast_mode = false }\n"
        try fixture.write(ambiguous)
        #expect(throws: RelayConfigurationError.self) {
            _ = try fixture.transaction.setCodexServiceTier(.fast, paths: fixture.paths)
        }
        #expect(try fixture.read() == ambiguous)
    }

    @Test
    func `speed row renders both controls and the loaded chat limitation`() throws {
        let actions = CodexSpeedActions(
            read: { CodexSpeedSnapshot(scope: .official, tier: .standard) },
            write: { tier, scope in CodexSpeedSnapshot(scope: scope, tier: tier) })
        let view = NSHostingView(rootView: CodexSpeedControl(actions: actions)
            .padding(12).frame(width: 360).background(ConsoleDesign.background))
        view.frame = NSRect(x: 0, y: 0, width: 360, height: 76)
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize.width >= 300)
        #expect(view.fittingSize.height >= 35)
        if let path = ProcessInfo.processInfo.environment["HEADROOM_FAST_PREVIEW_PATH"],
           let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: path))
        }
    }

    @Test
    func `speed preferences survive reload independently for each route`() throws {
        let fixture = try SpeedFixture()
        defer { fixture.cleanup() }
        let preferences = CodexSpeedPreferences(defaults: fixture.defaults)
        let first = CodexSpeedScope.relay(UUID())
        let second = CodexSpeedScope.relay(UUID())
        preferences.store(.fast, for: first)
        preferences.store(.standard, for: second)
        preferences.store(.standard, for: .official)
        let reloaded = CodexSpeedPreferences(defaults: fixture.defaults)
        #expect(reloaded.tier(for: first) == .fast)
        #expect(reloaded.tier(for: second) == .standard)
        #expect(reloaded.tier(for: .official) == .standard)
        #expect(reloaded.tier(for: .relay(UUID())) == nil)
    }

    @Test
    func `switch restores destination preference and records the actual outgoing speed`() throws {
        let fixture = try SpeedFixture()
        defer { fixture.cleanup() }
        let preferences = CodexSpeedPreferences(defaults: fixture.defaults)
        let first = UUID()
        let second = UUID()
        preferences.store(.standard, for: .relay(second))
        let actions = CodexSpeedActions(read: { CodexSpeedSnapshot(scope: .relay(first), tier: .fast) })
        #expect(actions.tierForSwitch(to: second, preferences: preferences) == .standard)
        #expect(preferences.tier(for: .relay(first)) == .fast)
        #expect(actions.tierForSwitch(to: first, preferences: preferences) == .fast)
    }

    @Test
    func `failed write never publishes a preference and stale route never changes config`() throws {
        let fixture = try SpeedFixture()
        defer { fixture.cleanup() }
        let source = "service_tier = \"default\"\n"
        try fixture.write(source)
        let preferences = CodexSpeedPreferences(defaults: fixture.defaults)
        let scope = CodexSpeedScope.relay(UUID())
        let failing = CodexSpeedActions.live(
            paths: fixture.paths,
            transaction: RelayConfigurationTransaction(fileSystem: SpeedFailOnceFileSystem(url: fixture.paths
                    .codexConfigURL)),
            preferences: preferences,
            resolveScope: { scope })
        #expect(throws: (any Error).self) { _ = try failing.write(.fast, scope) }
        #expect(preferences.tier(for: scope) == nil)
        #expect(try fixture.read() == source)
        let actions = CodexSpeedActions.live(
            paths: fixture.paths,
            transaction: fixture.transaction,
            preferences: preferences,
            resolveScope: { .official })
        #expect(throws: (any Error).self) { _ = try actions.write(.fast, scope) }
        #expect(try fixture.read() == source)
        #expect(preferences.tier(for: scope) == nil)
        _ = try actions.write(.fast, .official)
        #expect(try actions.read().tier == .fast)
        #expect(preferences.tier(for: .official) == .fast)
    }

    @Test
    func `profile switch and official restore apply remembered speed in the same transaction`() throws {
        let fixture = try SpeedFixture()
        defer { fixture.cleanup() }
        try fixture.write("model = \"official-model\"\nservice_tier = \"default\"\n")
        let baseline = try fixture.transaction.captureBaseline(paths: fixture.paths)
        let profile = try RelayProfile(
            name: "Fixture",
            baseURL: #require(URL(string: "https://relay.example/v1")),
            apiFormat: .openAIResponses,
            credentialReference: "fixture",
            targets: [.init(
                app: .codex,
                model: "gpt-6.1-sol")])
        _ = try fixture.transaction.apply(
            profile: profile, paths: fixture.paths, credentialStore: SpeedCredentialStore(), codexServiceTier: .fast)
        #expect(try CodexServiceTier.configured(in: Data(fixture.read().utf8)) == .fast)
        _ = try fixture.transaction.restore(
            backupDirectory: baseline, paths: fixture.paths, targets: [.codex], codexServiceTier: .fast)
        #expect(try fixture.read().contains("official-model"))
        #expect(try CodexServiceTier.configured(in: Data(fixture.read().utf8)) == .fast)
    }
}

@MainActor
private struct SpeedFixture {
    let root: URL
    let paths: RelayConfigurationPaths
    let defaults: UserDefaults
    let suite: String
    let transaction = RelayConfigurationTransaction()

    init() throws {
        self.root = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-speed-\(UUID())")
        self.paths = .standard(homeDirectory: self.root, bundleURL: self.root, environment: [:])
        self.suite = "com.ddaxia.headroom.isolated.speed.\(UUID())"
        self.defaults = try #require(UserDefaults(suiteName: self.suite))
    }

    func write(_ text: String) throws {
        try FileManager.default.createDirectory(
            at: self.paths.codexConfigURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data(text.utf8).write(to: self.paths.codexConfigURL)
    }

    func read() throws -> String {
        try String(contentsOf: self.paths.codexConfigURL, encoding: .utf8)
    }

    func cleanup() {
        self.defaults.removePersistentDomain(forName: self.suite)
        try? FileManager.default.removeItem(at: self.root)
    }
}

private struct SpeedCredentialStore: RelayCredentialStoring, RelayCredentialLocating {
    func loadCredential(reference _: String) throws -> String? {
        "fixture-only"
    }

    func storeCredential(_: String, reference _: String) throws {}
    func removeCredential(reference _: String) throws {}
    func locator(for reference: String) throws -> RelayCredentialLocator {
        RelayCredentialLocator(service: "fixture", account: reference)
    }
}

private final class SpeedFailOnceFileSystem: RelayConfigurationFileSystem, @unchecked Sendable {
    private let base = LocalRelayConfigurationFileSystem()
    private let url: URL
    private var failed = false

    init(url: URL) {
        self.url = url
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
        if url == self.url, !self.failed {
            self.failed = true
            throw CocoaError(.fileWriteUnknown)
        }
        try self.base.writeAtomically(data, to: url)
    }
}
