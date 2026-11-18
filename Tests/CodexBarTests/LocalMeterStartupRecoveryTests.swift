import CodexBarCore
import Foundation
import Observation
import Testing
@testable import CodexBar

@Suite("M5 S4.5 startup recovery", .serialized)
struct LocalMeterStartupRecoveryTests {
    @Test
    func `unhealthy loopback activation restores the isolated baseline`() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let official = "model = \"official\"\n"
        try fixture.write(official, to: fixture.paths.codexConfigURL)
        let baseline = try fixture.transaction.captureBaseline(paths: fixture.paths)
        try fixture.write(
            "model = \"meter\"\nbase_url = \"http://127.0.0.1:47891\"\n",
            to: fixture.paths.codexConfigURL)
        try fixture.fileStore.save(LocalMeterActivationState(
            activeProfileIDsByTarget: [.codex: UUID()],
            baselineBackupDirectory: baseline))
        let probeCalls = Counter()
        let startupGuard = LocalMeterStartupRecovery.makeGuard(
            homeDirectory: fixture.home,
            userDefaults: fixture.defaults,
            environment: [:],
            healthCheck: {
                probeCalls.increment()
                return false
            })

        let result = await startupGuard.run()

        #expect(result == .restored(changedFileCount: 1))
        #expect(probeCalls.value == 1)
        #expect(try String(contentsOf: fixture.paths.codexConfigURL, encoding: .utf8) == official)
        #expect(fixture.fileStore.load() == nil)
    }

    @Test
    @MainActor
    func `startup retry budget restores and surfaces a UI notice after timeout`() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let official = "model = \"official\"\n"
        try fixture.write(official, to: fixture.paths.codexConfigURL)
        let baseline = try fixture.transaction.captureBaseline(paths: fixture.paths)
        try fixture.write(
            "model = \"meter\"\nbase_url = \"http://127.0.0.1:47891\"\n",
            to: fixture.paths.codexConfigURL)
        try fixture.fileStore.save(LocalMeterActivationState(
            activeProfileIDsByTarget: [.codex: UUID()],
            baselineBackupDirectory: baseline))
        let probeCalls = Counter()
        let sleeps = SleepRecorder()
        let startupGuard = LocalMeterStartupRecovery.makeGuard(
            homeDirectory: fixture.home,
            userDefaults: fixture.defaults,
            environment: [:],
            retryPolicy: .init(maximumAttempts: 25, delay: .milliseconds(500)),
            sleep: { duration in sleeps.record(duration) },
            healthCheck: {
                probeCalls.increment()
                return false
            })
        let settings = testSettingsStore(suiteName: "LocalMeterStartupRecoveryTests-timeout")
        settings.localMeterRuntimeStatus = .starting

        let result = await startupGuard.run()

        #expect(result == .restored(changedFileCount: 1))
        #expect(probeCalls.value == 25)
        #expect(sleeps.values.count == 24)
        #expect(sleeps.values.reduce(.zero, +) == .seconds(12))
        #expect(settings.localMeterRuntimeStatus == .starting)

        LocalMeterStartupPresentation.apply(result, to: settings)

        #expect(settings.localMeterRuntimeStatus == .unavailable)
        #expect(settings.localMeterStartupNotice == .restoredOfficial)
        #expect(LocalMeterStatusPresentation.text(
            runtimeStatus: settings.localMeterRuntimeStatus,
            startupNotice: settings.localMeterStartupNotice) == L("local_meter_status_restored_official"))
        #expect(try String(contentsOf: fixture.paths.codexConfigURL, encoding: .utf8) == official)
        #expect(fixture.fileStore.load() == nil)
    }

    @Test
    @MainActor
    func `verified loopback reactivation revokes the startup recovery notice`() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let official = "model = \"official\"\n"
        try fixture.write(official, to: fixture.paths.codexConfigURL)
        let settings = testSettingsStore(suiteName: "LocalMeterStartupRecoveryTests-reactivation")
        let fixtureHome = fixture.home
        let fixtureDefaults = SendableDefaults(fixture.defaults)
        let commands = LaunchCommandRecorder()
        let launchdController = LocalMeterLaunchdController(
            homeDirectory: fixture.home,
            helperURL: fixture.root.appendingPathComponent("CodexBarLocalMeterHelper"),
            runLaunchctl: { arguments in commands.record(arguments) })
        let coordinator = LocalMeterCoordinator(
            settings: settings,
            launchdController: launchdController,
            healthCheck: { true },
            activeLoopbackRouteCheck: {
                LocalMeterStartupRecovery.hasActiveLoopbackRoute(
                    homeDirectory: fixtureHome,
                    userDefaults: fixtureDefaults.value,
                    environment: [:])
            })
        settings.localMeterEnabled = true
        LocalMeterStartupPresentation.apply(.restored(changedFileCount: 1), to: settings)

        coordinator.restart()
        try await Task.sleep(for: .milliseconds(50))

        #expect(settings.localMeterRuntimeStatus == .healthy(port: LocalMeterEndpoint.defaultPort))
        #expect(settings.localMeterStartupNotice == .restoredOfficial)

        let baseline = try fixture.transaction.captureBaseline(paths: fixture.paths)
        try fixture.write(
            "model = \"meter\"\nbase_url = \"http://127.0.0.1:47891\"\n",
            to: fixture.paths.codexConfigURL)
        try fixture.fileStore.save(LocalMeterActivationState(
            activeProfileIDsByTarget: [.codex: UUID()],
            baselineBackupDirectory: baseline))
        coordinator.reconcileActiveRoute()

        #expect(settings.localMeterStartupNotice == nil)
        coordinator.stop()
    }

    @Test
    @MainActor
    func `startup recovery notice survives settings observer without restarting the coordinator`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Headroom-S4-5-startup-observer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = testSettingsStore(suiteName: "LocalMeterStartupRecoveryTests-observer")
        let commands = LaunchCommandRecorder()
        let observerStarts = Counter()
        let healthChecks = Counter()
        let launchdController = LocalMeterLaunchdController(
            homeDirectory: root,
            helperURL: root.appendingPathComponent("CodexBarLocalMeterHelper"),
            runLaunchctl: { arguments in commands.record(arguments) })
        let coordinator = LocalMeterCoordinator(
            settings: settings,
            launchdController: launchdController,
            healthCheck: {
                healthChecks.increment()
                return true
            })
        settings.localMeterEnabled = true
        coordinator.restart()
        try await Task.sleep(for: .milliseconds(50))

        withObservationTracking {
            _ = settings.menuObservationToken
        } onChange: { [weak coordinator] in
            Task { @MainActor in
                observerStarts.increment()
                coordinator?.restart()
            }
        }
        LocalMeterStartupPresentation.apply(.restored(changedFileCount: 1), to: settings)

        settings.localUsageRefreshMode = .scheduled
        try await Task.sleep(for: .milliseconds(50))

        #expect(observerStarts.value == 1)
        #expect(settings.localMeterStartupNotice == .restoredOfficial)
        #expect(commands.values.count(where: { $0.first == "bootstrap" }) == 1)
        #expect(healthChecks.value == 1)

        LocalMeterStartupPresentation.apply(.healthy, to: settings)

        #expect(settings.localMeterStartupNotice == .restoredOfficial)
    }

    @Test
    func `live recovery environment confines GUI startup to an isolated fixture`() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let trap = try Fixture()
        defer { trap.cleanup() }
        let official = "model = \"official\"\n"
        try fixture.write(official, to: fixture.paths.codexConfigURL)
        let baseline = try fixture.transaction.captureBaseline(paths: fixture.paths)
        try fixture.write(
            "model = \"meter\"\nbase_url = \"http://127.0.0.1:47891\"\n",
            to: fixture.paths.codexConfigURL)
        try fixture.fileStore.save(LocalMeterActivationState(
            activeProfileIDsByTarget: [.codex: UUID()],
            baselineBackupDirectory: baseline))
        trap.defaults.set("untouched", forKey: "isolation-marker")

        let startupGuard = LocalMeterStartupRecovery.makeLiveGuard(
            homeDirectory: trap.home,
            userDefaults: trap.defaults,
            environment: [
                "CODEXBAR_RESTORE_HOME": fixture.home.path,
                "CODEXBAR_RELAY_DEFAULTS_SUITE": fixture.suiteName,
            ],
            retryPolicy: .singleAttempt,
            sleep: { _ in },
            healthCheck: { false })

        let result = await startupGuard.run()

        #expect(result == .restored(changedFileCount: 1))
        #expect(try String(contentsOf: fixture.paths.codexConfigURL, encoding: .utf8) == official)
        #expect(fixture.fileStore.load() == nil)
        #expect(trap.defaults.string(forKey: "isolation-marker") == "untouched")
        #expect(!FileManager.default.fileExists(atPath: trap.paths.codexConfigURL.path))
    }

    @Test
    func `activation without a loopback route is a no-op and never probes`() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let official = "model = \"official\"\n"
        try fixture.write(official, to: fixture.paths.codexConfigURL)
        let baseline = try fixture.transaction.captureBaseline(paths: fixture.paths)
        try fixture.fileStore.save(LocalMeterActivationState(
            activeProfileIDsByTarget: [.codex: UUID()],
            baselineBackupDirectory: baseline))
        let probeCalls = Counter()
        let startupGuard = LocalMeterStartupRecovery.makeGuard(
            homeDirectory: fixture.home,
            userDefaults: fixture.defaults,
            environment: [:],
            healthCheck: {
                probeCalls.increment()
                return false
            })

        let result = await startupGuard.run()

        #expect(result == .notConfigured)
        #expect(probeCalls.value == 0)
        #expect(try String(contentsOf: fixture.paths.codexConfigURL, encoding: .utf8) == official)
        #expect(fixture.fileStore.load() != nil)
    }

    @Test
    func `legacy defaults activation is recovered when the core file is absent`() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let official = "model = \"official\"\n"
        try fixture.write(official, to: fixture.paths.codexConfigURL)
        let baseline = try fixture.transaction.captureBaseline(paths: fixture.paths)
        try fixture.write(
            "model = \"meter\"\nbase_url = \"http://127.0.0.1:47891\"\n",
            to: fixture.paths.codexConfigURL)
        fixture.defaults.set(
            baseline.path,
            forKey: LocalMeterActivationState.baselineBackupPathKey)
        fixture.defaults.set(
            [RelayTargetApp.codex.rawValue: UUID().uuidString],
            forKey: LocalMeterActivationState.activeProfileIDsByTargetKey)
        let startupGuard = LocalMeterStartupRecovery.makeGuard(
            homeDirectory: fixture.home,
            userDefaults: fixture.defaults,
            environment: [:],
            healthCheck: { false })

        let result = await startupGuard.run()

        #expect(result == .restored(changedFileCount: 1))
        #expect(try String(contentsOf: fixture.paths.codexConfigURL, encoding: .utf8) == official)
    }

    private struct Fixture {
        let root: URL
        let home: URL
        let paths: RelayConfigurationPaths
        let fileStore: LocalMeterActivationStateFileStore
        let defaults: UserDefaults
        let suiteName: String
        let transaction = RelayConfigurationTransaction()

        init() throws {
            self.root = FileManager.default.temporaryDirectory
                .appendingPathComponent("Headroom-S4-5-startup-\(UUID().uuidString)", isDirectory: true)
            self.home = self.root.appendingPathComponent("home", isDirectory: true)
            try FileManager.default.createDirectory(at: self.home, withIntermediateDirectories: true)
            self.paths = RelayConfigurationPaths.standard(homeDirectory: self.home, environment: [:])
            self.fileStore = LocalMeterActivationStateFileStore(paths: self.paths)
            self.suiteName = "Headroom-S4-5-startup-\(UUID().uuidString)"
            self.defaults = try #require(UserDefaults(suiteName: self.suiteName))
        }

        func write(_ text: String, to url: URL) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: self.root)
            self.defaults.removePersistentDomain(forName: self.suiteName)
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

    private final class SleepRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var durations: [Duration] = []

        var values: [Duration] {
            self.lock.withLock { self.durations }
        }

        func record(_ duration: Duration) {
            self.lock.withLock { self.durations.append(duration) }
        }
    }

    private final class SendableDefaults: @unchecked Sendable {
        let value: UserDefaults

        init(_ value: UserDefaults) {
            self.value = value
        }
    }

    private final class LaunchCommandRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var commands: [[String]] = []

        var values: [[String]] {
            self.lock.withLock { self.commands }
        }

        func record(_ arguments: [String]) {
            self.lock.withLock { self.commands.append(arguments) }
        }
    }
}
