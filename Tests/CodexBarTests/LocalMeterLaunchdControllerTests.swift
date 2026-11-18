import CodexBarCore
import Foundation
import Testing

struct LocalMeterLaunchdControllerTests {
    @Test
    func `default launchctl path uses the macOS system binary`() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let controller = LocalMeterLaunchdController(
            homeDirectory: fixture.root,
            helperURL: fixture.root.appendingPathComponent("helper"))

        #expect(controller.launchctlURL.path == "/bin/launchctl")
    }

    @Test
    func `install writes a private plist and bootstraps only the exact user job`() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let commands = CommandRecorder()
        let helper = fixture.root.appendingPathComponent("CodexBarLocalMeterHelper")
        let controller = LocalMeterLaunchdController(
            homeDirectory: fixture.root,
            helperURL: helper,
            launchctlURL: URL(fileURLWithPath: "/bin/launchctl"),
            runLaunchctl: { arguments in commands.record(arguments) })

        let plistURL = try controller.installAndStart()

        #expect(plistURL == LocalMeterLaunchdJob.launchAgentURL(homeDirectory: fixture.root))
        #expect(FileManager.default.fileExists(atPath: plistURL.path))
        let object = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: plistURL),
            options: [],
            format: nil)
        let plist = try #require(object as? [String: Any])
        #expect(plist["Label"] as? String == LocalMeterLaunchdJob.label)
        #expect(commands.values == [
            [
                "bootout",
                "gui/\(LocalMeterLaunchdController.currentUserID)/\(LocalMeterLaunchdJob.label)",
            ],
            ["bootstrap", "gui/\(LocalMeterLaunchdController.currentUserID)", plistURL.path],
        ])
    }

    @Test
    func `stop bootouts the exact job and removes only its plist`() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let commands = CommandRecorder()
        let controller = LocalMeterLaunchdController(
            homeDirectory: fixture.root,
            helperURL: fixture.root.appendingPathComponent("helper"),
            runLaunchctl: { arguments in commands.record(arguments) })
        let plistURL = try controller.installAndStart()

        try controller.stopAndRemove()

        #expect(!FileManager.default.fileExists(atPath: plistURL.path))
        #expect(commands.values.last == [
            "bootout",
            "gui/\(LocalMeterLaunchdController.currentUserID)/\(LocalMeterLaunchdJob.label)",
        ])
    }

    @Test
    func `bootstrap failure leaves plist available for the next recovery attempt`() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let controller = LocalMeterLaunchdController(
            homeDirectory: fixture.root,
            helperURL: fixture.root.appendingPathComponent("helper"),
            runLaunchctl: { arguments in
                if arguments.first == "bootstrap" { throw FixtureError.commandFailed }
            })

        #expect(throws: FixtureError.self) {
            try controller.installAndStart()
        }
        #expect(FileManager.default.fileExists(
            atPath: LocalMeterLaunchdJob.launchAgentURL(homeDirectory: fixture.root).path))
    }

    private final class CommandRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [[String]] = []

        var values: [[String]] {
            self.lock.withLock { self.entries }
        }

        func record(_ arguments: [String]) {
            self.lock.withLock { self.entries.append(arguments) }
        }
    }

    private struct Fixture {
        let root: URL

        init() throws {
            self.root = FileManager.default.temporaryDirectory
                .appendingPathComponent("Headroom-S4-5-launchd-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: self.root)
        }
    }

    private enum FixtureError: Error {
        case commandFailed
    }
}
