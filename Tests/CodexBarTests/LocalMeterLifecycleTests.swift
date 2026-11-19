import CodexBarCore
import Foundation
import Testing

struct LocalMeterLifecycleTests {
    @Test
    func `launchd job is login loaded and kept alive`() throws {
        let helperURL = URL(fileURLWithPath: "/Applications/Headroom.app/Contents/Helpers/CodexBarLocalMeterHelper")
        let job = LocalMeterLaunchdJob(helperURL: helperURL)

        let object = try PropertyListSerialization.propertyList(
            from: job.plistData(),
            options: [],
            format: nil)
        let plist = try #require(object as? [String: Any])

        #expect(plist["Label"] as? String == LocalMeterLaunchdJob.label)
        #expect(plist["KeepAlive"] as? Bool == true)
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["ProcessType"] as? String == "Background")
        #expect(plist["StandardOutPath"] as? String == "/dev/null")
        #expect(plist["StandardErrorPath"] as? String == "/dev/null")
        #expect((plist["ProgramArguments"] as? [String]) == [helperURL.path, "--port", "47891"])
        #expect(LocalMeterLaunchdJob.launchAgentURL(
            homeDirectory: URL(fileURLWithPath: "/tmp/fixture", isDirectory: true)).path
            == "/tmp/fixture/Library/LaunchAgents/com.ddaxia.headroom.local-meter.plist")
    }

    @Test
    func `unhealthy helper restores isolated relay baseline and clears activation`() async throws {
        let fixture = try Self.Fixture()
        defer { fixture.cleanup() }
        let official = "model = \"official\"\n"
        try fixture.write(official, to: fixture.paths.codexConfigURL)
        let baseline = try fixture.transaction.captureBaseline(paths: fixture.paths)
        try fixture.write(
            "model = \"relay\"\nbase_url = \"http://127.0.0.1:47891\"\n",
            to: fixture.paths.codexConfigURL)
        let state = LocalMeterActivationState(
            activeProfileIDsByTarget: [.codex: UUID()],
            baselineBackupDirectory: baseline)
        let stateStore = LocalMeterActivationStateFileStore(fileURL: fixture.stateURL)
        try stateStore.save(state)
        let service = LocalMeterRestoreService(
            paths: fixture.paths,
            stateStore: stateStore,
            transaction: fixture.transaction)
        let guarder = LocalMeterStartupGuard(
            restoreService: service,
            healthCheck: { false })

        let result = await guarder.run()

        #expect(result == .restored(changedFileCount: 1))
        #expect(try String(contentsOf: fixture.paths.codexConfigURL, encoding: .utf8) == official)
        #expect(stateStore.load() == nil)
    }

    @Test
    func `healthy helper leaves isolated relay configuration and activation untouched`() async throws {
        let fixture = try Self.Fixture()
        defer { fixture.cleanup() }
        let relay = "model = \"relay\"\nbase_url = \"http://127.0.0.1:47891\"\n"
        try fixture.write(relay, to: fixture.paths.codexConfigURL)
        let baseline = try fixture.transaction.captureBaseline(paths: fixture.paths)
        let state = LocalMeterActivationState(
            activeProfileIDsByTarget: [.codex: UUID()],
            baselineBackupDirectory: baseline)
        let stateStore = LocalMeterActivationStateFileStore(fileURL: fixture.stateURL)
        try stateStore.save(state)
        let service = LocalMeterRestoreService(
            paths: fixture.paths,
            stateStore: stateStore,
            transaction: fixture.transaction)
        let guarder = LocalMeterStartupGuard(
            restoreService: service,
            healthCheck: { true })

        let result = await guarder.run()

        #expect(result == .healthy)
        #expect(try String(contentsOf: fixture.paths.codexConfigURL, encoding: .utf8) == relay)
        #expect(stateStore.load() == state)
    }

    @Test
    func `missing activation is a no-op even when helper is unhealthy`() async throws {
        let fixture = try Self.Fixture()
        defer { fixture.cleanup() }
        let official = "model = \"official\"\n"
        try fixture.write(official, to: fixture.paths.codexConfigURL)
        let service = LocalMeterRestoreService(
            paths: fixture.paths,
            stateStore: LocalMeterActivationStateFileStore(fileURL: fixture.stateURL),
            transaction: fixture.transaction)
        let guarder = LocalMeterStartupGuard(
            restoreService: service,
            healthCheck: { false })

        let result = await guarder.run()

        #expect(result == .notConfigured)
        #expect(try String(contentsOf: fixture.paths.codexConfigURL, encoding: .utf8) == official)
    }

    @Test
    func `activation without a loopback configuration does not probe or restore`() async throws {
        let fixture = try Self.Fixture()
        defer { fixture.cleanup() }
        let official = "model = \"official\"\n"
        try fixture.write(official, to: fixture.paths.codexConfigURL)
        let baseline = try fixture.transaction.captureBaseline(paths: fixture.paths)
        let stateStore = LocalMeterActivationStateFileStore(fileURL: fixture.stateURL)
        try stateStore.save(LocalMeterActivationState(
            activeProfileIDsByTarget: [.codex: UUID()],
            baselineBackupDirectory: baseline))
        let healthChecks = Counter()
        let service = LocalMeterRestoreService(
            paths: fixture.paths,
            stateStore: stateStore,
            transaction: fixture.transaction)
        let guarder = LocalMeterStartupGuard(
            restoreService: service,
            healthCheck: {
                healthChecks.increment()
                return false
            })

        let result = await guarder.run()

        #expect(result == .notConfigured)
        #expect(healthChecks.value == 0)
        #expect(try String(contentsOf: fixture.paths.codexConfigURL, encoding: .utf8) == official)
        #expect(stateStore.load() != nil)
    }

    @Test
    func `activation state file round trips without credentials`() throws {
        let fixture = try Self.Fixture()
        defer { fixture.cleanup() }
        let state = LocalMeterActivationState(
            activeProfileIDsByTarget: [.codex: UUID(), .openCode: UUID()],
            baselineBackupDirectory: fixture.root.appendingPathComponent("backup", isDirectory: true))
        let store = LocalMeterActivationStateFileStore(fileURL: fixture.stateURL)

        try store.save(state)

        #expect(store.load() == state)
        let raw = try String(contentsOf: fixture.stateURL, encoding: .utf8)
        #expect(!raw.contains("key"))
    }

    private struct Fixture {
        let root: URL
        let paths: RelayConfigurationPaths
        let stateURL: URL
        let transaction: RelayConfigurationTransaction

        init() throws {
            self.root = FileManager.default.temporaryDirectory
                .appendingPathComponent("Headroom-S4-5-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            let config = self.root.appendingPathComponent("config", isDirectory: true)
            let backups = self.root.appendingPathComponent("backups", isDirectory: true)
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
                credentialHelperURL: config.appendingPathComponent("credential-helper"),
                backupRootURL: backups)
            self.stateURL = self.root.appendingPathComponent("activation-state.json")
            self.transaction = RelayConfigurationTransaction()
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

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int {
            self.lock.withLock { self.count }
        }

        func increment() {
            self.lock.withLock { self.count += 1 }
        }
    }
}
