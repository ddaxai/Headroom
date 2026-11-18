import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite("M5 S4.5 GUI/launchd boundary", .serialized)
@MainActor
struct LocalMeterCoordinatorTests {
    @Test
    func `enabled coordinator bootstraps the helper and GUI shutdown leaves the job loaded`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Headroom-S4-5-coordinator-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = testSettingsStore(suiteName: "LocalMeterCoordinatorTests")
        let commands = CommandRecorder()
        let controller = LocalMeterLaunchdController(
            homeDirectory: root,
            helperURL: root.appendingPathComponent("CodexBarLocalMeterHelper"),
            runLaunchctl: { arguments in commands.record(arguments) })
        let coordinator = LocalMeterCoordinator(
            settings: settings,
            launchdController: controller,
            healthCheck: { true })
        settings.localMeterEnabled = true

        coordinator.restart()
        try await Task.sleep(for: .milliseconds(50))

        #expect(settings.localMeterRuntimeStatus == .healthy(port: LocalMeterEndpoint.defaultPort))
        #expect(commands.values.count == 2)
        #expect(commands.values[0].first == "bootout")
        #expect(commands.values[1].first == "bootstrap")

        coordinator.shutdown()
        #expect(commands.values.count == 2)

        coordinator.stop()
        #expect(commands.values.count == 3)
        #expect(commands.values[2].first == "bootout")
    }

    @Test
    func `coordinator tolerates a delayed launchd helper start`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Headroom-S4-5-delayed-helper-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = testSettingsStore(suiteName: "LocalMeterCoordinatorTests-delayed-helper")
        let checks = HealthCheckRecorder(succeedsOnAttempt: 6)
        let controller = LocalMeterLaunchdController(
            homeDirectory: root,
            helperURL: root.appendingPathComponent("CodexBarLocalMeterHelper"),
            runLaunchctl: { _ in })
        let coordinator = LocalMeterCoordinator(
            settings: settings,
            launchdController: controller,
            healthCheck: { checks.nextResult() })
        settings.localMeterEnabled = true

        coordinator.restart()
        try await Task.sleep(for: .seconds(3))

        #expect(settings.localMeterRuntimeStatus == .healthy(port: LocalMeterEndpoint.defaultPort))
        #expect(checks.attemptCount == 6)
        coordinator.stop()
    }

    @Test
    func `route verification revokes recovery notice only after helper and loopback are active`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Headroom-S4-5-route-verification-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = testSettingsStore(suiteName: "LocalMeterCoordinatorTests-route-verification")
        let route = RouteState()
        let controller = LocalMeterLaunchdController(
            homeDirectory: root,
            helperURL: root.appendingPathComponent("CodexBarLocalMeterHelper"),
            runLaunchctl: { _ in })
        let coordinator = LocalMeterCoordinator(
            settings: settings,
            launchdController: controller,
            healthCheck: { true },
            activeLoopbackRouteCheck: { route.isActive })
        settings.localMeterEnabled = true
        LocalMeterStartupPresentation.apply(.restored(changedFileCount: 1), to: settings)

        coordinator.restart()
        try await Task.sleep(for: .milliseconds(50))

        #expect(settings.localMeterRuntimeStatus == .healthy(port: LocalMeterEndpoint.defaultPort))
        #expect(settings.localMeterStartupNotice == .restoredOfficial)

        route.activate()
        coordinator.reconcileActiveRoute()

        #expect(settings.localMeterStartupNotice == nil)
        coordinator.stop()
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

    private final class HealthCheckRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private let succeedsOnAttempt: Int
        private var attempts = 0

        init(succeedsOnAttempt: Int) {
            self.succeedsOnAttempt = succeedsOnAttempt
        }

        var attemptCount: Int {
            self.lock.withLock { self.attempts }
        }

        func nextResult() -> Bool {
            self.lock.withLock {
                self.attempts += 1
                return self.attempts >= self.succeedsOnAttempt
            }
        }
    }

    private final class RouteState: @unchecked Sendable {
        private let lock = NSLock()
        private var active = false

        var isActive: Bool {
            self.lock.withLock { self.active }
        }

        func activate() {
            self.lock.withLock { self.active = true }
        }
    }
}
