import Foundation
import Testing
@testable import CodexBar

struct HeadroomSourceUpdateTests {
    @Test
    func `source update defaults match the documented multi-machine checkout`() {
        let configuration = HeadroomSourceUpdateConfiguration.default

        #expect(configuration.sourceDirectory.path.hasSuffix("/Developer/Headroom"))
        #expect(configuration.branch == "main")
        #expect(configuration.scriptURL.lastPathComponent == "update_headroom.sh")
        #expect(configuration.logURL.path.hasSuffix("/Library/Logs/Headroom/update.log"))
        #expect(configuration.cloneCommand ==
            "git clone https://github.com/ddaxai/Headroom.git ~/Developer/Headroom && " +
            "cd ~/Developer/Headroom && git checkout main")
    }

    @Test
    func `source updater recognizes stable progress stages`() {
        #expect(HeadroomSourceUpdateStage.parse("[Headroom] Fetching origin") == .fetching)
        #expect(HeadroomSourceUpdateStage.parse("[Headroom] Building Headroom") == .building)
        #expect(HeadroomSourceUpdateStage.parse("[Headroom] Installing Headroom") == .installing)
        #expect(HeadroomSourceUpdateStage.parse("unrelated output") == nil)
        #expect(HeadroomSourceUpdatePresentation.statusStripHeight == 52)
    }

    @Test
    func `source update configuration follows a selected checkout`() {
        let sourceDirectory = URL(fileURLWithPath: "/tmp/Headroom Source", isDirectory: true)
        let configuration = HeadroomSourceUpdateConfiguration.make(
            sourceDirectory: sourceDirectory,
            branch: "theodore/relay-usage-ui")

        #expect(configuration.sourceDirectory == sourceDirectory)
        #expect(configuration.scriptURL.path == "/tmp/Headroom Source/Scripts/update_headroom.sh")
        #expect(configuration.cloneCommand.contains("'/tmp/Headroom Source'"))
        #expect(configuration.cloneCommand.contains("git checkout theodore/relay-usage-ui"))
    }

    @Test
    func `structured status lines are parsed without relying on prose`() throws {
        let available = try #require(HeadroomSourceUpdateStatus.parse(
            "HEADROOM_UPDATE_STATUS=available local=abc1234 remote=def5678 behind=2"))
        #expect(available.kind == .available)
        #expect(available.localCommit == "abc1234")
        #expect(available.remoteCommit == "def5678")
        #expect(available.behind == 2)

        let scheduled = try #require(HeadroomSourceUpdateStatus.parse(
            "HEADROOM_UPDATE_STATUS=scheduled local=abc1234 remote=def5678"))
        #expect(scheduled.kind == .scheduled)

        let failed = try #require(HeadroomSourceUpdateStatus.parse(
            "HEADROOM_UPDATE_STATUS=failed reason=local_ahead local=abc1234 remote=def5678"))
        #expect(failed.kind == .failed)
        #expect(failed.reason == "local_ahead")
    }

    @Test
    func `structured status parser rejects malformed lines`() {
        #expect(HeadroomSourceUpdateStatus.parse("Headroom is already up to date") == nil)
        #expect(HeadroomSourceUpdateStatus.parse("HEADROOM_UPDATE_STATUS=") == nil)
        #expect(HeadroomSourceUpdateStatus.parse("HEADROOM_UPDATE_STATUS=unknown") == nil)
    }

    @Test
    func `update timeouts are explicit and mode dependent`() {
        #expect(HeadroomSourceUpdateController.timeout(for: .check) == 60)
        #expect(HeadroomSourceUpdateController.timeout(for: .update) == 20 * 60)
    }

    @Test
    func `source updater composes explicit safety overrides`() {
        #expect(HeadroomSourceUpdateController.arguments(
            for: .check,
            options: .init()) == ["--check-only"])
        #expect(HeadroomSourceUpdateController.arguments(
            for: .update,
            options: .init(ignoreUntracked: true, allowLocalReset: true)) == [
                "--ignore-untracked",
                "--allow-local-reset",
            ])
    }

    @Test
    func `structured failure reasons expose actionable recovery`() {
        #expect(HeadroomSourceUpdateController.recoveryAction(for: "untracked_files") ==
            .retryIgnoringUntracked)
        #expect(HeadroomSourceUpdateController.recoveryAction(for: "local_ahead") ==
            .retryReplacingLocalCommits)
        #expect(HeadroomSourceUpdateController.recoveryAction(for: "diverged") ==
            .retryReplacingLocalCommits)
        #expect(HeadroomSourceUpdateController.recoveryAction(for: "fetch_failed") ==
            .copySSHCheck)
        #expect(HeadroomSourceUpdateController.recoveryAction(for: "tracked_dirty") ==
            .revealSource)
        #expect(HeadroomSourceUpdateController.recoveryAction(for: "package_failed") == nil)
    }

    @Test @MainActor
    func `relaunched updater observes detached finalizer completion`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "headroom-source-update-controller-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let gitDirectory = root.appending(path: ".git", directoryHint: .isDirectory)
        let scriptURL = root.appending(path: "Scripts/update_headroom.sh")
        let logURL = root.appending(path: "update.log")
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: scriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        try "HEADROOM_UPDATE_STATUS=scheduled remote=abc123\n"
            .write(to: logURL, atomically: true, encoding: .utf8)

        let configuration = HeadroomSourceUpdateConfiguration(
            sourceDirectory: root,
            branch: "theodore/relay-usage-ui",
            scriptURL: scriptURL,
            logURL: logURL,
            cloneCommand: "")
        let controller = HeadroomSourceUpdateController(configuration: configuration)
        #expect(controller.state == .updating)

        try ("HEADROOM_UPDATE_STATUS=scheduled remote=abc123\n" +
            "HEADROOM_UPDATE_STATUS=completed remote=abc123\n")
            .write(to: logURL, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(700))

        #expect(controller.state == .completed)
        #expect(controller.stage == .finished)
    }
}
