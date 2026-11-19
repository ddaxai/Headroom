import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite("M5 S1 local usage realtime refresh")
struct LocalUsageRealtimeRefreshTests {
    @Test @MainActor
    func `local usage refresh defaults realtime and manual mode stops its timer`() {
        let settings = testSettingsStore(suiteName: "LocalUsageRealtimeRefreshTests-mode")
        #expect(settings.localUsageRefreshMode == .realtime)

        settings.refreshFrequency = .oneMinute
        settings.localUsageRefreshMode = .manual
        #expect(settings.userDefaults.string(forKey: "localUsageRefreshMode") == "manual")

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        store.startTokenTimer()

        #expect(store.tokenTimerTask == nil)
    }

    @Test
    func `session write bursts debounce to one refresh`() async {
        let recorder = RefreshRecorder()
        let debouncer = LocalUsageRefreshDebouncer(delay: .milliseconds(40)) { sources in
            await recorder.record(sources)
        }

        await debouncer.submit(.codex)
        await debouncer.submit(.codex)
        await debouncer.submit(.pi)
        await recorder.waitForBatchCount(1)

        let batches = await recorder.batches
        #expect(batches == [[.codex, .pi]])
        await debouncer.cancel()
    }

    @Test
    func `writes during a refresh coalesce into one serialized trailing refresh`() async throws {
        let gate = SerializedRefreshGate()
        let debouncer = LocalUsageRefreshDebouncer(delay: .milliseconds(30)) { sources in
            await gate.run(sources)
        }

        await debouncer.submit(.codex)
        await gate.waitForBatchCount(1)
        await debouncer.submit(.pi)
        await debouncer.submit(.openCode)
        try await Task.sleep(for: .milliseconds(100))

        #expect(await gate.batches == [[.codex]])
        #expect(await gate.maximumConcurrentActions == 1)

        await gate.releaseFirstAction()
        await gate.waitForBatchCount(2)
        #expect(await gate.batches == [[.codex], [.pi, .openCode]])
        #expect(await gate.maximumConcurrentActions == 1)
        await debouncer.cancel()
    }

    @Test @MainActor
    func `realtime coordinator performs one startup catch up`() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("headroom-realtime-startup-\(UUID().uuidString)", isDirectory: true)
        let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(
            at: codexHome.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let settings = testSettingsStore(suiteName: "LocalUsageRealtimeRefreshTests-startup")
        settings.localUsageRefreshMode = .realtime
        let recorder = RefreshRecorder()
        let coordinator = LocalUsageRealtimeCoordinator(
            settings: settings,
            environment: ["CODEX_HOME": codexHome.path],
            homeDirectory: home,
            cacheDirectory: home.appendingPathComponent("cache", isDirectory: true),
            debounceDelay: .milliseconds(30))
        { sources in
            await recorder.record(sources)
        }
        defer { coordinator.stop() }

        coordinator.restart()
        await recorder.waitForBatchCount(1, timeout: .seconds(3))
        #expect(await recorder.batches == [[.codex]])

        coordinator.restart()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await recorder.batches == [[.codex]])
    }

    @Test @MainActor
    func `automatic catch up repeats incomplete scans and remains bounded`() async {
        let completes = CatchUpOutcomeRecorder(outcomes: [true, true, false])
        let completedPasses = await LocalUsageCatchUpRunner.run(maxPasses: 12) {
            await completes.nextNeedsCatchUp()
        }
        #expect(completedPasses == 3)
        #expect(await completes.callCount == 3)

        let neverCompletes = CatchUpOutcomeRecorder(outcomes: [])
        let boundedPasses = await LocalUsageCatchUpRunner.run(maxPasses: 3) {
            await neverCompletes.nextNeedsCatchUp()
        }
        #expect(boundedPasses == 3)
        #expect(await neverCompletes.callCount == 3)
    }

    @Test
    func `watch plan excludes Headroom cache paths`() {
        let home = URL(fileURLWithPath: "/tmp/headroom-m5-home", isDirectory: true)
        let cache = home
            .appendingPathComponent("Library/Caches/CodexBar/cost-usage", isDirectory: true)
        let roots = LocalUsageWatchPlan.roots(
            environment: ["CODEX_HOME": home.appendingPathComponent("codex-home").path],
            homeDirectory: home,
            cacheDirectory: cache)

        #expect(Set(roots.map(\.source)) == Set(LocalUsageRefreshSource.allCases))
        #expect(!roots.contains { $0.url.standardizedFileURL.path.hasPrefix(cache.standardizedFileURL.path) })
        #expect(!roots.contains { $0.url.lastPathComponent == "cost-usage" })
    }

    @Test
    func `watcher observes appends to existing files in nested session directories`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("headroom-realtime-watch-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("2026/08/24", isDirectory: true)
        let session = nested.appendingPathComponent("session.jsonl", isDirectory: false)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("initial\n".utf8).write(to: session)
        defer { try? FileManager.default.removeItem(at: root) }

        let recorder = FileEventRecorder()
        let watcher = try LocalUsageDirectoryWatcher(
            roots: [LocalUsageWatchRoot(source: .codex, url: root)])
        { source in
            Task { await recorder.record(source) }
        }
        defer { watcher.cancel() }
        try await Task.sleep(for: .milliseconds(100))

        let handle = try FileHandle(forWritingTo: session)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("appended\n".utf8))
        try handle.synchronize()
        try handle.close()

        #expect(await recorder.waitFor(.codex, timeout: .seconds(2)))
    }

    @Test
    func `watcher ignores SQLite shared memory lock churn`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("headroom-realtime-opencode-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let recorder = FileEventRecorder()
        let watcher = try LocalUsageDirectoryWatcher(
            roots: [LocalUsageWatchRoot(source: .openCode, url: root)])
        { source in
            Task { await recorder.record(source) }
        }
        defer { watcher.cancel() }
        try await Task.sleep(for: .milliseconds(100))

        try Data("sqlite shared memory\n".utf8)
            .write(to: root.appendingPathComponent("opencode.db-shm"), options: .atomic)
        try await Task.sleep(for: .milliseconds(500))

        #expect(await recorder.hasRecorded(.openCode) == false)
    }

    @Test
    func `watcher still observes OpenCode database writes`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("headroom-realtime-opencode-db-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("opencode.db", isDirectory: false)
        try Data("initial\n".utf8).write(to: database)
        defer { try? FileManager.default.removeItem(at: root) }

        let recorder = FileEventRecorder()
        let watcher = try LocalUsageDirectoryWatcher(
            roots: [LocalUsageWatchRoot(source: .openCode, url: root)])
        { source in
            Task { await recorder.record(source) }
        }
        defer { watcher.cancel() }
        try await Task.sleep(for: .milliseconds(100))

        let handle = try FileHandle(forWritingTo: database)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("updated\n".utf8))
        try handle.synchronize()
        try handle.close()

        #expect(await recorder.waitFor(.openCode, timeout: .seconds(2)))
    }

    @Test
    func `incremental Codex refresh matches full rescan and conserves all windows`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let now = try env.makeLocalNoon(year: 2026, month: 8, day: 24)
        let fileURL = try env.writeCodexSessionFile(
            day: now,
            filename: "realtime.jsonl",
            contents: env.jsonl([
                Self.turnContext(at: now, environment: env),
                Self.tokenCount(at: now.addingTimeInterval(1), input: 100, output: 20, environment: env),
            ]))
        let incrementalOptions = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot)

        _ = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now,
            bypassScannerDebounce: true,
            scannerOptions: incrementalOptions,
            piScannerOptions: PiSessionCostScanner.Options(
                piSessionsRoot: env.piSessionsRoot,
                cacheRoot: env.cacheRoot))

        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let appended = try env.jsonl([
            Self.tokenCount(at: now.addingTimeInterval(2), input: 160, output: 30, environment: env),
        ])
        try handle.write(contentsOf: Data(appended.utf8))
        try handle.synchronize()

        let incremental = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now,
            bypassScannerDebounce: true,
            scannerOptions: incrementalOptions,
            piScannerOptions: PiSessionCostScanner.Options(
                piSessionsRoot: env.piSessionsRoot,
                cacheRoot: env.cacheRoot))

        let fullCache = env.root.appendingPathComponent("full-cache", isDirectory: true)
        let full = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now,
            bypassScannerDebounce: true,
            scannerOptions: CostUsageScanner.Options(
                codexSessionsRoot: env.codexSessionsRoot,
                cacheRoot: fullCache,
                forceRescan: true),
            piScannerOptions: PiSessionCostScanner.Options(
                piSessionsRoot: env.piSessionsRoot,
                cacheRoot: fullCache,
                forceRescan: true))

        #expect(incremental.daily == full.daily)
        #expect(incremental.daily.first?.totalTokens == 190)
        #expect((incremental.rolling24Hours?.totalTokens ?? 0) == (full.rolling24Hours?.totalTokens ?? 0))

        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let rows = cache.files[fileURL.path]?.codexRows ?? []
        let entries = CodexUsageLedgerAdapter.entries(
            sessionID: "realtime-session",
            modelProvider: "unknown-provider",
            rows: rows,
            timeline: CodexSessionOwnershipTimeline())
        let ledger = UsageLedger(entries: entries)

        for window in UsageLedgerWindow.allCases {
            let partition = ledger.partition(for: window, endingAt: now.addingTimeInterval(60))
            #expect(partition.isConserved)
            #expect(partition.componentTotal == partition.total)
        }
    }

    private static func turnContext(
        at date: Date,
        environment: CostUsageTestEnvironment) -> [String: Any]
    {
        [
            "type": "turn_context",
            "timestamp": environment.isoString(for: date),
            "payload": ["model": "openai/gpt-5.4"],
        ]
    }

    private static func tokenCount(
        at date: Date,
        input: Int,
        output: Int,
        environment: CostUsageTestEnvironment) -> [String: Any]
    {
        [
            "type": "event_msg",
            "timestamp": environment.isoString(for: date),
            "payload": [
                "type": "token_count",
                "info": [
                    "model": "openai/gpt-5.4",
                    "total_token_usage": [
                        "input_tokens": input,
                        "cached_input_tokens": 0,
                        "output_tokens": output,
                    ],
                ],
            ],
        ]
    }
}

private actor RefreshRecorder {
    private(set) var batches: [Set<LocalUsageRefreshSource>] = []

    func record(_ sources: Set<LocalUsageRefreshSource>) {
        self.batches.append(sources)
    }

    func waitForBatchCount(_ expectedCount: Int, timeout: Duration = .seconds(1)) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while self.batches.count < expectedCount, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor SerializedRefreshGate {
    private(set) var batches: [Set<LocalUsageRefreshSource>] = []
    private(set) var maximumConcurrentActions = 0
    private var activeActions = 0
    private var firstActionReleased = false

    func run(_ sources: Set<LocalUsageRefreshSource>) async {
        let isFirstAction = self.batches.isEmpty
        self.batches.append(sources)
        self.activeActions += 1
        self.maximumConcurrentActions = max(self.maximumConcurrentActions, self.activeActions)
        if isFirstAction {
            while !self.firstActionReleased {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        self.activeActions -= 1
    }

    func releaseFirstAction() {
        self.firstActionReleased = true
    }

    func waitForBatchCount(_ expectedCount: Int) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while self.batches.count < expectedCount, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor CatchUpOutcomeRecorder {
    private var outcomes: [Bool]
    private(set) var callCount = 0

    init(outcomes: [Bool]) {
        self.outcomes = outcomes
    }

    func nextNeedsCatchUp() -> Bool {
        self.callCount += 1
        return self.outcomes.isEmpty ? true : self.outcomes.removeFirst()
    }
}

private actor FileEventRecorder {
    private var sources: Set<LocalUsageRefreshSource> = []

    func record(_ source: LocalUsageRefreshSource) {
        self.sources.insert(source)
    }

    func waitFor(_ source: LocalUsageRefreshSource, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if self.sources.contains(source) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return self.sources.contains(source)
    }

    func hasRecorded(_ source: LocalUsageRefreshSource) -> Bool {
        self.sources.contains(source)
    }
}
