import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct CLIRelayRestoreCommandTests {
    @Test
    func `restore-official command restores an isolated fixture without GUI`() throws {
        let fixture = try Self.Fixture()
        defer { fixture.cleanup() }
        let official = "model = \"official\"\n"
        try fixture.write(official, to: fixture.paths.codexConfigURL)
        let baseline = try fixture.transaction.captureBaseline(paths: fixture.paths)
        try fixture.write(
            "model = \"relay\"\nbase_url = \"http://127.0.0.1:47891\"\n",
            to: fixture.paths.codexConfigURL)
        try fixture.stateStore.save(LocalMeterActivationState(
            activeProfileIDsByTarget: [.codex: UUID()],
            baselineBackupDirectory: baseline))

        let report = try CodexBarCLI.restoreOfficialReport(
            paths: fixture.paths,
            stateStore: fixture.stateStore)
        let recoveryBackup = try #require(report.recoveryBackupDirectory)
        let text = CodexBarCLI.restoreOfficialText(report, dryRun: false)

        #expect(report.result == .restored(changedFileCount: 1))
        #expect(report.changedConfigurationURLs == [fixture.paths.codexConfigURL])
        #expect(FileManager.default.fileExists(
            atPath: recoveryBackup.appendingPathComponent("manifest.json").path))
        #expect(text.contains("Recovery backup: \(recoveryBackup.path)"))
        #expect(try String(contentsOf: fixture.paths.codexConfigURL, encoding: .utf8) == official)
        #expect(fixture.stateStore.load() == nil)
    }

    @Test
    func `restore-official command is safe when GUI never activated a relay`() throws {
        let fixture = try Self.Fixture()
        defer { fixture.cleanup() }
        let official = "model = \"official\"\n"
        try fixture.write(official, to: fixture.paths.codexConfigURL)

        let result = try CodexBarCLI.restoreOfficial(
            paths: fixture.paths,
            stateStore: fixture.stateStore)

        #expect(result == .noActivation)
        #expect(try String(contentsOf: fixture.paths.codexConfigURL, encoding: .utf8) == official)
    }

    @Test
    func `restore-official dry run names managed files without changing the fixture`() throws {
        let fixture = try Self.Fixture()
        defer { fixture.cleanup() }
        let official = "model = \"official\"\n"
        let loopback = "model = \"meter\"\nbase_url = \"http://127.0.0.1:47891\"\n"
        try fixture.write(official, to: fixture.paths.codexConfigURL)
        let baseline = try fixture.transaction.captureBaseline(paths: fixture.paths)
        try fixture.write(loopback, to: fixture.paths.codexConfigURL)
        try fixture.stateStore.save(LocalMeterActivationState(
            activeProfileIDsByTarget: [.codex: UUID()],
            baselineBackupDirectory: baseline))

        let report = try CodexBarCLI.restoreOfficialReport(
            paths: fixture.paths,
            stateStore: fixture.stateStore,
            dryRun: true)
        let text = CodexBarCLI.restoreOfficialText(report, dryRun: true)

        #expect(report.result == .restored(changedFileCount: 1))
        #expect(report.changedConfigurationURLs == [fixture.paths.codexConfigURL])
        #expect(report.recoveryBackupDirectory == nil)
        #expect(text.contains(fixture.paths.codexConfigURL.path))
        #expect(text.contains("would be restored"))
        #expect(try String(contentsOf: fixture.paths.codexConfigURL, encoding: .utf8) == loopback)
        #expect(fixture.stateStore.load() != nil)
    }

    private struct Fixture {
        let root: URL
        let paths: RelayConfigurationPaths
        let stateStore: LocalMeterActivationStateFileStore
        let transaction = RelayConfigurationTransaction()

        init() throws {
            self.root = FileManager.default.temporaryDirectory
                .appendingPathComponent("Headroom-S4-5-cli-\(UUID().uuidString)", isDirectory: true)
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
                credentialHelperURL: config.appendingPathComponent("credential-helper"),
                backupRootURL: self.root.appendingPathComponent("backups", isDirectory: true))
            self.stateStore = LocalMeterActivationStateFileStore(
                fileURL: self.root.appendingPathComponent("activation-state.json"))
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
