import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageFetcherTests {
    @Test
    func `shared codex rows are partitioned by observed account activation time`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let firstEvent = day.addingTimeInterval(10)
        let secondEvent = day.addingTimeInterval(20)
        let thirdEvent = day.addingTimeInterval(30)
        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "shared.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": env.isoString(for: day),
                    "payload": [
                        "session_id": "shared-session",
                        "model_provider": CodexSessionProvenanceClassifier.sharedProvider,
                    ],
                ],
                Self.tokenCountEntry(env: env, date: firstEvent, total: 100, last: 100),
                Self.tokenCountEntry(env: env, date: secondEvent, total: 150, last: 50),
                Self.tokenCountEntry(env: env, date: thirdEvent, total: 200, last: 50),
            ]))

        var timeline = CodexSessionOwnershipTimeline()
        let recordedOfficialRoute = timeline.recordOfficialCodexRoute(
            atUnixMilliseconds: Int64(day.timeIntervalSince1970 * 1000))
        #expect(recordedOfficialRoute)
        let recordedFirst = timeline.recordActivation(
            accountKey: "codex:managed:first",
            atUnixMilliseconds: Int64(firstEvent.addingTimeInterval(5).timeIntervalSince1970 * 1000))
        #expect(recordedFirst)

        let first = UsageIdentity.subscription(
            provider: .codex,
            accountKey: "managed:first",
            displayLabel: "First")
        let second = UsageIdentity.subscription(
            provider: .codex,
            accountKey: "managed:second",
            displayLabel: "Second")
        let system = UsageIdentity.systemUnassigned(localHomePath: env.codexHomeRoot.path)

        let fetcher = CostUsageFetcher(cacheRoot: env.cacheRoot)
        let unassigned = try await fetcher.loadAttributedSharedCodexTokenSnapshot(
            now: thirdEvent,
            sharedCodexHomePath: env.codexHomeRoot.path,
            usageIdentity: system,
            timeline: timeline,
            historyDays: 1)
        let firstAccountBeforeSwitch = try await fetcher.loadAttributedSharedCodexTokenSnapshot(
            now: thirdEvent,
            sharedCodexHomePath: env.codexHomeRoot.path,
            usageIdentity: first,
            timeline: timeline,
            historyDays: 1)
        let recordedSecond = timeline.recordActivation(
            accountKey: "codex:managed:second",
            atUnixMilliseconds: Int64(secondEvent.addingTimeInterval(5).timeIntervalSince1970 * 1000))
        #expect(recordedSecond)
        let firstAccountAfterSwitch = try await fetcher.loadAttributedSharedCodexTokenSnapshot(
            now: thirdEvent,
            sharedCodexHomePath: env.codexHomeRoot.path,
            usageIdentity: first,
            timeline: timeline,
            historyDays: 1)
        let secondAccount = try await fetcher.loadAttributedSharedCodexTokenSnapshot(
            now: thirdEvent,
            sharedCodexHomePath: env.codexHomeRoot.path,
            usageIdentity: second,
            timeline: timeline,
            historyDays: 1)

        #expect(unassigned.last30DaysTokens == 100)
        #expect(firstAccountBeforeSwitch.last30DaysTokens == 100)
        #expect(firstAccountAfterSwitch.last30DaysTokens == 50)
        #expect(secondAccount.last30DaysTokens == 50)
    }

    @Test
    func `live official attribution is disjoint from relay and unassigned across every window`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let now = try env.makeLocalNoon(year: 2026, month: 4, day: 30)
        let ages: [TimeInterval] = [60 * 60, 6 * 24 * 60 * 60, 20 * 24 * 60 * 60]
        let liveAccountKey = "codex:live:workspace-live"
        let relayProfileID = try #require(UUID(uuidString: "33333333-3333-4333-8333-333333333333"))
        let boundary = try now.addingTimeInterval(-(#require(ages.last)) - 1)
        var timeline = CodexSessionOwnershipTimeline()
        _ = timeline.recordActivation(
            accountKey: liveAccountKey,
            atUnixMilliseconds: Int64(boundary.timeIntervalSince1970 * 1000))
        _ = timeline.recordCodexRelayActivation(
            profileID: relayProfileID,
            atUnixMilliseconds: Int64(boundary.timeIntervalSince1970 * 1000))

        let providersAndTotals: [(String, String, [Int])] = [
            ("official", CodexSessionProvenanceClassifier.officialProvider, [33, 22, 11]),
            ("relay", CodexSessionProvenanceClassifier.relayProvider, [66, 55, 44]),
            ("unassigned", "unknown-provider", [99, 88, 77]),
        ]
        for (sessionID, provider, deltas) in providersAndTotals {
            var cumulative = 0
            let rows = zip(ages.reversed(), deltas.reversed()).map { age, delta in
                cumulative += delta
                return Self.tokenCountEntry(
                    env: env,
                    date: now.addingTimeInterval(-age),
                    total: cumulative,
                    last: delta)
            }
            _ = try env.writeCodexSessionFile(
                day: now,
                filename: sessionID + ".jsonl",
                contents: env.jsonl([
                    [
                        "type": "session_meta",
                        "timestamp": env.isoString(for: now),
                        "payload": [
                            "session_id": sessionID,
                            "model_provider": provider,
                        ],
                    ],
                ] + rows))
        }

        let full = try await CostUsageFetcher(
            cacheRoot: env.root.appendingPathComponent("full-cache", isDirectory: true))
            .loadTokenSnapshot(
                provider: .codex,
                now: now,
                forceRefresh: true,
                codexHomePath: env.codexHomeRoot.path,
                historyDays: 30,
                allowPricingRefresh: false,
                refreshPricingInBackground: false,
                includePiSessions: false)
        let official = try await CostUsageFetcher(
            cacheRoot: env.root.appendingPathComponent("official-cache", isDirectory: true))
            .loadAttributedSharedCodexTokenSnapshot(
                now: now,
                sharedCodexHomePath: env.codexHomeRoot.path,
                usageIdentity: .subscription(
                    provider: .codex,
                    accountKey: "live:workspace-live",
                    displayLabel: "Live Official"),
                timeline: timeline,
                historyDays: 30,
                forceRefresh: true)
        let relay = try await CostUsageFetcher(
            cacheRoot: env.root.appendingPathComponent("relay-cache", isDirectory: true))
            .loadRelaySharedCodexTokenSnapshot(
                now: now,
                sharedCodexHomePath: env.codexHomeRoot.path,
                profileID: relayProfileID,
                timeline: timeline,
                historyDays: 30,
                forceRefresh: true)
        let unassigned = try await CostUsageFetcher(
            cacheRoot: env.root.appendingPathComponent("unassigned-cache", isDirectory: true))
            .loadAttributedSharedCodexTokenSnapshot(
                now: now,
                sharedCodexHomePath: env.codexHomeRoot.path,
                usageIdentity: .systemUnassigned(localHomePath: env.codexHomeRoot.path),
                timeline: timeline,
                historyDays: 30,
                forceRefresh: true)

        let expected: [UsageLedgerWindow: (full: Int, official: Int, relay: Int, unassigned: Int)] = [
            .rolling24Hours: (198, 33, 66, 99),
            .rolling7Days: (363, 55, 121, 187),
            .rolling30Days: (495, 66, 165, 264),
        ]
        for window in UsageLedgerWindow.allCases {
            let fullSummary = try #require(Self.summary(full, window: window))
            let officialSummary = try #require(Self.summary(official, window: window))
            let relaySummary = try #require(Self.summary(relay, window: window))
            let unassignedSummary = try #require(Self.summary(unassigned, window: window))
            let values = try #require(expected[window])
            #expect(fullSummary.totalTokens == values.full)
            #expect(officialSummary.totalTokens == values.official)
            #expect(relaySummary.totalTokens == values.relay)
            #expect(unassignedSummary.totalTokens == values.unassigned)
            #expect(
                officialSummary.totalTokens + relaySummary.totalTokens + unassignedSummary.totalTokens
                    == fullSummary.totalTokens)
            #expect(CodexStackedUsageSummary.isConservedPartition(
                total: fullSummary,
                official: [officialSummary],
                relay: relaySummary,
                unassigned: unassignedSummary))
        }
    }

    @Test
    func `one cached Codex corpus partitions every menu bucket without rescanning sources`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let now = try env.makeLocalNoon(year: 2026, month: 4, day: 30)
        let ages: [TimeInterval] = [60 * 60, 6 * 24 * 60 * 60, 20 * 24 * 60 * 60]
        let accountKey = "codex:live:workspace-live"
        let relayProfileID = try #require(UUID(uuidString: "44444444-4444-4444-8444-444444444444"))
        let boundary = try now.addingTimeInterval(-(#require(ages.last)) - 1)
        var timeline = CodexSessionOwnershipTimeline()
        _ = timeline.recordActivation(
            accountKey: accountKey,
            atUnixMilliseconds: Int64(boundary.timeIntervalSince1970 * 1000))
        _ = timeline.recordCodexRelayActivation(
            profileID: relayProfileID,
            atUnixMilliseconds: Int64(boundary.timeIntervalSince1970 * 1000))

        let providersAndTotals: [(String, String, [Int])] = [
            ("official", CodexSessionProvenanceClassifier.officialProvider, [33, 22, 11]),
            ("relay", CodexSessionProvenanceClassifier.relayProvider, [66, 55, 44]),
            ("unassigned", "unknown-provider", [99, 88, 77]),
        ]
        var sessionURLs: [URL] = []
        for (sessionID, provider, deltas) in providersAndTotals {
            var cumulative = 0
            let rows = zip(ages.reversed(), deltas.reversed()).map { age, delta in
                cumulative += delta
                return Self.tokenCountEntry(
                    env: env,
                    date: now.addingTimeInterval(-age),
                    total: cumulative,
                    last: delta)
            }
            try sessionURLs.append(env.writeCodexSessionFile(
                day: now,
                filename: sessionID + ".jsonl",
                contents: env.jsonl([[
                    "type": "session_meta",
                    "timestamp": env.isoString(for: now),
                    "payload": [
                        "session_id": sessionID,
                        "model_provider": provider,
                    ],
                ]] + rows)))
        }

        _ = try await CostUsageFetcher(cacheRoot: env.cacheRoot).loadTokenSnapshot(
            provider: .codex,
            now: now,
            forceRefresh: true,
            codexHomePath: env.codexHomeRoot.path,
            historyDays: 30,
            allowPricingRefresh: false,
            refreshPricingInBackground: false,
            includePiSessions: false)
        let cachedRows = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
            .files.values.flatMap { $0.codexRows ?? [] }
        #expect(cachedRows.count == 9)
        for sessionURL in sessionURLs {
            try "not-json\n".write(to: sessionURL, atomically: true, encoding: .utf8)
        }

        let partition = try #require(CodexUsageLedgerSnapshotPartition.load(
            now: now,
            sharedCodexHomePath: env.codexHomeRoot.path,
            timeline: timeline,
            historyDays: 30,
            cacheRoot: env.cacheRoot))
        let official = try #require(partition.officialByAccountKey[accountKey])
        let relay = try #require(partition.relayByProfileID[relayProfileID])
        let relayAggregate = try #require(partition.relayAggregate)
        let unassigned = try #require(partition.unassigned)
        let full = try #require(partition.fullCorpus)

        // Automatic menu refresh used to read a separate relay-only cache. When that cache was
        // absent after relaunch, it discarded relay rows already present in this complete corpus
        // and rendered the API card as "no local usage" until an explicit refresh rebuilt it.
        let automaticRelaySnapshots = CodexRelayMenuSnapshots.preferred(
            ledgerPartition: partition,
            legacy: CodexRelayMenuSnapshots())

        #expect(partition.coverageIsComplete)
        #expect(automaticRelaySnapshots.byProfileID[relayProfileID] == relay)
        #expect(automaticRelaySnapshots.aggregate == relayAggregate)
        #expect(relay == relayAggregate)
        for window in UsageLedgerWindow.allCases {
            let fullSummary = try #require(Self.summary(full, window: window))
            let officialSummary = try #require(Self.summary(official, window: window))
            let relaySummary = try #require(Self.summary(relay, window: window))
            let unassignedSummary = try #require(Self.summary(unassigned, window: window))
            let componentTokens = officialSummary.totalTokens
                + relaySummary.totalTokens
                + unassignedSummary.totalTokens
            #expect(componentTokens == fullSummary.totalTokens)
            #expect(CodexStackedUsageSummary.isConservedPartition(
                total: fullSummary,
                official: [officialSummary],
                relay: relaySummary,
                unassigned: unassignedSummary))
        }
    }

    @Test
    func `fetcher scopes codex history to selected codex home`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let otherHome = env.root.appendingPathComponent("other-codex-home", isDirectory: true)
        try Self.writeCodexSessionFile(
            homeRoot: env.codexHomeRoot,
            env: env,
            day: day,
            filename: "ambient.jsonl",
            tokens: 100)
        try Self.writeCodexSessionFile(homeRoot: otherHome, env: env, day: day, filename: "managed.jsonl", tokens: 10)
        _ = try env.writePiSessionFile(
            relativePath: "2026-04-08T10-00-00-000Z_ambient.jsonl",
            contents: env.jsonl([[
                "type": "message",
                "timestamp": env.isoString(for: day),
                "message": [
                    "role": "assistant",
                    "provider": "openai-codex",
                    "model": "openai/gpt-5.4",
                    "timestamp": Int(day.timeIntervalSince1970 * 1000),
                    "usage": ["input": 50, "output": 5, "totalTokens": 55],
                ],
            ]]))

        let options = CostUsageScanner.Options(cacheRoot: env.cacheRoot)
        let piOptions = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0)
        let ambient = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            codexHomePath: env.codexHomeRoot.path,
            scannerOptions: options,
            piScannerOptions: piOptions)
        let managed = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            codexHomePath: otherHome.path,
            scannerOptions: options,
            piScannerOptions: piOptions)

        #expect(ambient.sessionTokens == 100)
        #expect(managed.sessionTokens == 10)
    }
}

extension CostUsageFetcherTests {
    private static func summary(
        _ snapshot: CostUsageTokenSnapshot,
        window: UsageLedgerWindow) -> CostUsageRolling24HourSummary?
    {
        switch window {
        case .rolling24Hours:
            return snapshot.rolling24Hours
        case .rolling7Days, .rolling30Days:
            let days = window.rawValue
            let summary = snapshot.summary(forLastDays: days)
            return summary.totalTokens.map {
                CostUsageRolling24HourSummary(totalTokens: $0, costUSD: summary.totalCostUSD)
            }
        }
    }

    fileprivate static func tokenCountEntry(
        env: CostUsageTestEnvironment,
        date: Date,
        total: Int,
        last: Int) -> [String: Any]
    {
        [
            "type": "event_msg",
            "timestamp": env.isoString(for: date),
            "payload": [
                "type": "token_count",
                "info": [
                    "model": "openai/gpt-5.4",
                    "last_token_usage": [
                        "input_tokens": last,
                        "cached_input_tokens": 0,
                        "output_tokens": 0,
                    ],
                    "total_token_usage": [
                        "input_tokens": total,
                        "cached_input_tokens": 0,
                        "output_tokens": 0,
                    ],
                ],
            ],
        ]
    }
}

extension CostUsageFetcherTests {
    @Test
    func `fetcher fails closed when selected codex home is unavailable`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        try Self.writeCodexSessionFile(
            homeRoot: env.codexHomeRoot,
            env: env,
            day: day,
            filename: "ambient.jsonl",
            tokens: 100)
        let missingHome = env.root.appendingPathComponent("missing-codex-home", isDirectory: true)

        do {
            _ = try await CostUsageFetcher.loadTokenSnapshot(
                provider: .codex,
                now: day,
                codexHomePath: missingHome.path,
                scannerOptions: CostUsageScanner.Options(cacheRoot: env.cacheRoot))
            Issue.record("Expected an unavailable selected Codex home to fail closed")
        } catch let error as CostUsageError {
            guard case let .codexHomeUnreadable(path) = error else {
                Issue.record("Unexpected CostUsageError: \(error)")
                return
            }
            #expect(path == missingHome.standardizedFileURL.path)
        }
    }

    @Test
    func `fetcher refreshes codex cache when legacy roots metadata is missing`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let managedHome = env.root.appendingPathComponent("managed-codex-home", isDirectory: true)
        try Self.writeCodexSessionFile(
            homeRoot: env.codexHomeRoot,
            env: env,
            day: day,
            filename: "ambient.jsonl",
            tokens: 100)
        try Self.writeCodexSessionFile(homeRoot: managedHome, env: env, day: day, filename: "managed.jsonl", tokens: 10)

        let options = CostUsageScanner.Options(cacheRoot: env.cacheRoot)
        let piOptions = PiSessionCostScanner.Options(piSessionsRoot: env.piSessionsRoot, cacheRoot: env.cacheRoot)
        let ambient = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            codexHomePath: env.codexHomeRoot.path,
            scannerOptions: options,
            piScannerOptions: piOptions)
        #expect(ambient.sessionTokens == 100)

        var cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        cache.roots = nil
        CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: env.cacheRoot)

        let managed = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day.addingTimeInterval(1),
            codexHomePath: managedHome.path,
            scannerOptions: options,
            piScannerOptions: piOptions)

        #expect(managed.sessionTokens == 10)
    }

    @Test
    func `fetcher refreshes codex cache when history window expands`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let oldDay = try env.makeLocalNoon(year: 2026, month: 4, day: 2)
        let newDay = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        try Self.writeCodexSessionFile(
            homeRoot: env.codexHomeRoot,
            env: env,
            day: oldDay,
            filename: "old.jsonl",
            tokens: 15)
        try Self.writeCodexSessionFile(
            homeRoot: env.codexHomeRoot,
            env: env,
            day: newDay,
            filename: "new.jsonl",
            tokens: 30)

        var options = CostUsageScanner.Options(cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 3600

        let narrow = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: newDay,
            codexHomePath: env.codexHomeRoot.path,
            historyDays: 1,
            scannerOptions: options)
        #expect(narrow.daily.map(\.date) == ["2026-04-08"])
        #expect(narrow.last30DaysTokens == 30)

        var legacyCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        legacyCache.scanSinceKey = nil
        legacyCache.scanUntilKey = nil
        CostUsageCacheIO.save(provider: .codex, cache: legacyCache, cacheRoot: env.cacheRoot)

        let expanded = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: newDay.addingTimeInterval(1),
            codexHomePath: env.codexHomeRoot.path,
            historyDays: 7,
            scannerOptions: options)
        #expect(expanded.daily.map(\.date) == ["2026-04-02", "2026-04-08"])
        #expect(expanded.last30DaysTokens == 45)
    }

    @Test
    func `explicit codex refresh sees a new session before the debounce interval`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        try Self.writeCodexSessionFile(
            homeRoot: env.codexHomeRoot,
            env: env,
            day: day,
            filename: "first.jsonl",
            tokens: 25)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        options.refreshMinIntervalSeconds = 3600
        let first = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            codexHomePath: env.codexHomeRoot.path,
            historyDays: 1,
            allowPricingRefresh: false,
            refreshPricingInBackground: false,
            includePiSessions: false,
            scannerOptions: options)
        #expect(first.last30DaysTokens == 25)

        // The newly-created file changes the corpus fingerprint while the cache is still
        // younger than the normal scanner debounce interval.
        try Self.writeCodexSessionFile(
            homeRoot: env.codexHomeRoot,
            env: env,
            day: day,
            filename: "second.jsonl",
            tokens: 35)

        let refreshed = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day.addingTimeInterval(1),
            codexHomePath: env.codexHomeRoot.path,
            historyDays: 1,
            allowPricingRefresh: false,
            refreshPricingInBackground: false,
            includePiSessions: false,
            bypassScannerDebounce: true,
            scannerOptions: options)

        #expect(refreshed.last30DaysTokens == 60)
    }

    @Test
    func `fetcher resolves fork parent outside requested codex window`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let parentDay = try env.makeLocalNoon(year: 2026, month: 4, day: 2)
        let childDay = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let model = "openai/gpt-5.4"
        let parentID = "parent-session"
        let parentTimestamp = env.isoString(for: parentDay.addingTimeInterval(1))
        let childTimestamp = env.isoString(for: childDay.addingTimeInterval(1))
        _ = try env.writeCodexSessionFile(
            day: parentDay,
            filename: "parent.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": env.isoString(for: parentDay),
                    "payload": ["session_id": parentID],
                ],
                [
                    "type": "event_msg",
                    "timestamp": parentTimestamp,
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "model": model,
                            "total_token_usage": [
                                "input_tokens": 100,
                                "cached_input_tokens": 0,
                                "output_tokens": 0,
                            ],
                        ],
                    ],
                ],
            ]))
        _ = try env.writeCodexSessionFile(
            day: childDay,
            filename: "child.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": env.isoString(for: childDay),
                    "payload": [
                        "session_id": "child-session",
                        "forked_from_id": parentID,
                        "timestamp": parentTimestamp,
                    ],
                ],
                [
                    "type": "event_msg",
                    "timestamp": childTimestamp,
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "model": model,
                            "total_token_usage": [
                                "input_tokens": 125,
                                "cached_input_tokens": 0,
                                "output_tokens": 5,
                            ],
                        ],
                    ],
                ],
            ]))

        let options = CostUsageScanner.Options(cacheRoot: env.cacheRoot)
        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: childDay,
            codexHomePath: env.codexHomeRoot.path,
            historyDays: 1,
            scannerOptions: options)

        #expect(snapshot.daily.map(\.date) == ["2026-04-08"])
        #expect(snapshot.last30DaysTokens == 30)
    }

    @Test
    func `force refresh only scans requested codex date window`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let oldDay = try env.makeLocalNoon(year: 2026, month: 3, day: 1)
        let newDay = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let oldURL = try env.writeCodexSessionFile(
            day: oldDay,
            filename: "old.jsonl",
            contents: env.jsonl([
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: oldDay),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "model": "openai/gpt-5.4",
                            "last_token_usage": [
                                "input_tokens": 10,
                                "cached_input_tokens": 0,
                                "output_tokens": 0,
                            ],
                        ],
                    ],
                ],
            ]))
        try FileManager.default.setAttributes([.modificationDate: oldDay], ofItemAtPath: oldURL.path)
        _ = try env.writeCodexSessionFile(
            day: newDay,
            filename: "new.jsonl",
            contents: env.jsonl([
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: newDay),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "model": "openai/gpt-5.4",
                            "last_token_usage": [
                                "input_tokens": 30,
                                "cached_input_tokens": 0,
                                "output_tokens": 0,
                            ],
                        ],
                    ],
                ],
            ]))

        let options = CostUsageScanner.Options(
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: newDay,
            forceRefresh: true,
            codexHomePath: env.codexHomeRoot.path,
            historyDays: 1,
            scannerOptions: options)
        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let cacheFileExists = FileManager.default.fileExists(
            atPath: CostUsageCacheIO.cacheFileURL(provider: .codex, cacheRoot: env.cacheRoot).path)

        #expect(snapshot.daily.map(\.date) == ["2026-04-08"])
        #expect(snapshot.last30DaysTokens == 30)
        #expect(cacheFileExists)
        #expect(cache.files.keys.sorted().map(URL.init(fileURLWithPath:)).map(\.lastPathComponent) == ["new.jsonl"])
    }

    @Test
    func `narrow codex refresh preserves wider cache window`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let oldDay = try env.makeLocalNoon(year: 2026, month: 4, day: 2)
        let newDay = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        _ = try env.writeCodexSessionFile(
            day: oldDay,
            filename: "old.jsonl",
            contents: env.jsonl([
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: oldDay),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "model": "openai/gpt-5.4",
                            "last_token_usage": [
                                "input_tokens": 15,
                                "cached_input_tokens": 0,
                                "output_tokens": 0,
                            ],
                        ],
                    ],
                ],
            ]))
        _ = try env.writeCodexSessionFile(
            day: newDay,
            filename: "new.jsonl",
            contents: env.jsonl([
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: newDay),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "model": "openai/gpt-5.4",
                            "last_token_usage": [
                                "input_tokens": 30,
                                "cached_input_tokens": 0,
                                "output_tokens": 0,
                            ],
                        ],
                    ],
                ],
            ]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: newDay,
            until: newDay,
            now: newDay,
            options: options)
        let wide = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: newDay.addingTimeInterval(1),
            codexHomePath: env.codexHomeRoot.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: options)
        let narrow = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: newDay.addingTimeInterval(2),
            codexHomePath: env.codexHomeRoot.path,
            historyDays: 1,
            refreshPricingInBackground: false,
            scannerOptions: options)
        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)

        #expect(wide.last30DaysTokens == 45)
        #expect(narrow.last30DaysTokens == 30)
        #expect(cache.files.keys.map(URL.init(fileURLWithPath:)).map(\.lastPathComponent).sorted() == [
            "new.jsonl",
            "old.jsonl",
        ])
        #expect(cache.scanSinceKey == "2026-04-01")
        #expect(cache.scanUntilKey == "2026-04-09")
    }

    @Test
    func `force codex rescan narrows cache window to refreshed range`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let oldDay = try env.makeLocalNoon(year: 2026, month: 4, day: 2)
        let newDay = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        _ = try env.writeCodexSessionFile(
            day: oldDay,
            filename: "old.jsonl",
            contents: env.jsonl([
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: oldDay),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "model": "openai/gpt-5.4",
                            "last_token_usage": [
                                "input_tokens": 15,
                                "cached_input_tokens": 0,
                                "output_tokens": 0,
                            ],
                        ],
                    ],
                ],
            ]))
        _ = try env.writeCodexSessionFile(
            day: newDay,
            filename: "new.jsonl",
            contents: env.jsonl([
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: newDay),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "model": "openai/gpt-5.4",
                            "last_token_usage": [
                                "input_tokens": 30,
                                "cached_input_tokens": 0,
                                "output_tokens": 0,
                            ],
                        ],
                    ],
                ],
            ]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        options.refreshMinIntervalSeconds = 0
        _ = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: newDay,
            codexHomePath: env.codexHomeRoot.path,
            historyDays: 7,
            refreshPricingInBackground: false,
            scannerOptions: options)

        var rescanOptions = options
        rescanOptions.forceRescan = true
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: newDay,
            until: newDay,
            now: newDay.addingTimeInterval(1),
            options: rescanOptions)
        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)

        #expect(cache.files.keys.map(URL.init(fileURLWithPath:)).map(\.lastPathComponent).sorted() == ["new.jsonl"])
        #expect(cache.scanSinceKey == "2026-04-07")
        #expect(cache.scanUntilKey == "2026-04-09")
    }

    @Test
    func `codex refresh drops stale cache entry when session moves to archive`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let contents = try env.jsonl([
            [
                "type": "session_meta",
                "timestamp": env.isoString(for: day),
                "payload": ["session_id": "moved-session"],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: day.addingTimeInterval(1)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "model": "openai/gpt-5.4",
                        "last_token_usage": [
                            "input_tokens": 30,
                            "cached_input_tokens": 0,
                            "output_tokens": 0,
                        ],
                    ],
                ],
            ],
        ])
        let originalURL = try env.writeCodexSessionFile(day: day, filename: "moved.jsonl", contents: contents)

        var options = CostUsageScanner.Options(cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        let first = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            codexHomePath: env.codexHomeRoot.path,
            historyDays: 1,
            scannerOptions: options)

        let archivedURL = env.codexArchivedSessionsRoot.appendingPathComponent("moved.jsonl", isDirectory: false)
        try FileManager.default.moveItem(at: originalURL, to: archivedURL)

        let second = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day.addingTimeInterval(1),
            codexHomePath: env.codexHomeRoot.path,
            historyDays: 1,
            scannerOptions: options)
        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)

        #expect(first.last30DaysTokens == 30)
        #expect(second.last30DaysTokens == 30)
        #expect(cache.files.count == 1)
        #expect(cache.files.keys.first.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } ==
            archivedURL.resolvingSymlinksInPath().path)
    }

    @Test
    func `fetcher merges native and pi codex history with normalized model names`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))

        let nativeTurnContext: [String: Any] = [
            "type": "turn_context",
            "timestamp": iso0,
            "payload": [
                "model": "openai/gpt-5.4",
            ],
        ]
        let nativeTokenCount: [String: Any] = [
            "type": "event_msg",
            "timestamp": iso1,
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": 100,
                        "cached_input_tokens": 20,
                        "output_tokens": 10,
                    ],
                    "model": "openai/gpt-5.4",
                ],
            ],
        ]
        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "session.jsonl",
            contents: env.jsonl([nativeTurnContext, nativeTokenCount]))

        let piAssistant: [String: Any] = [
            "type": "message",
            "timestamp": iso1,
            "message": [
                "role": "assistant",
                "provider": "openai-codex",
                "model": "openai/gpt-5.4",
                "timestamp": Int(day.timeIntervalSince1970 * 1000),
                "usage": [
                    "input": 50,
                    "cacheRead": 5,
                    "output": 5,
                    "totalTokens": 60,
                ],
            ],
        ]
        _ = try env.writePiSessionFile(
            relativePath: "2026-04-08T10-00-00-000Z_test.jsonl",
            contents: env.jsonl([piAssistant]))

        let nativeOptions = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        let piOptions = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0)

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            scannerOptions: nativeOptions,
            piScannerOptions: piOptions)
        let withoutPi = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            includePiSessions: false,
            scannerOptions: nativeOptions,
            piScannerOptions: piOptions)

        let nativeCost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.4",
            inputTokens: 100,
            cachedInputTokens: 20,
            outputTokens: 10) ?? 0
        let piCost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.4",
            inputTokens: 55,
            cachedInputTokens: 5,
            outputTokens: 5) ?? 0

        #expect(snapshot.daily.count == 1)
        #expect(snapshot.daily.first?.date == "2026-04-08")
        #expect(snapshot.daily.first?.totalTokens == 170)
        #expect(withoutPi.daily.first?.totalTokens == 110)
        #expect(abs((snapshot.daily.first?.costUSD ?? 0) - (nativeCost + piCost)) < 0.000001)
        let breakdown = try #require(snapshot.daily.first?.modelBreakdowns?.first)
        #expect(breakdown.modelName == "gpt-5.4")
        #expect(abs((breakdown.costUSD ?? 0) - (nativeCost + piCost)) < 0.000001)
        #expect(breakdown.totalTokens == 170)
        #expect(snapshot.sessions.isEmpty)
    }

    @Test
    func `fetcher merges native and pi claude history and ignores unsupported pi providers`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 9)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))

        let nativeAssistant: [String: Any] = [
            "type": "assistant",
            "timestamp": iso0,
            "message": [
                "model": "anthropic.foo.claude-sonnet-4-6-v1:0",
                "usage": [
                    "input_tokens": 100,
                    "cache_creation_input_tokens": 10,
                    "cache_read_input_tokens": 5,
                    "output_tokens": 20,
                ],
            ],
        ]
        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/session.jsonl",
            contents: env.jsonl([nativeAssistant]))

        let supportedPiAssistant: [String: Any] = [
            "type": "message",
            "timestamp": iso1,
            "message": [
                "role": "assistant",
                "provider": "anthropic",
                "model": "claude-sonnet-4-6",
                "timestamp": Int(day.addingTimeInterval(60).timeIntervalSince1970 * 1000),
                "usage": [
                    "input": 50,
                    "cacheRead": 4,
                    "cacheWrite": 6,
                    "output": 10,
                    "totalTokens": 70,
                ],
            ],
        ]
        let unsupportedPiAssistant: [String: Any] = [
            "type": "message",
            "timestamp": iso1,
            "message": [
                "role": "assistant",
                "provider": "openrouter",
                "model": "claude-sonnet-4-6",
                "timestamp": Int(day.addingTimeInterval(120).timeIntervalSince1970 * 1000),
                "usage": [
                    "input": 999,
                    "output": 1,
                    "totalTokens": 1000,
                ],
            ],
        ]
        _ = try env.writePiSessionFile(
            relativePath: "2026-04-09T10-00-00-000Z_test.jsonl",
            contents: env.jsonl([supportedPiAssistant, unsupportedPiAssistant]))

        let nativeOptions = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        let piOptions = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0)

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .claude,
            now: day,
            scannerOptions: nativeOptions,
            piScannerOptions: piOptions)

        let nativeCost = CostUsagePricing.claudeCostUSD(
            model: "claude-sonnet-4-6",
            inputTokens: 100,
            cacheReadInputTokens: 5,
            cacheCreationInputTokens: 10,
            outputTokens: 20) ?? 0
        let piCost = CostUsagePricing.claudeCostUSD(
            model: "claude-sonnet-4-6",
            inputTokens: 50,
            cacheReadInputTokens: 4,
            cacheCreationInputTokens: 6,
            outputTokens: 10) ?? 0

        #expect(snapshot.daily.count == 1)
        #expect(snapshot.daily.first?.date == "2026-04-09")
        #expect(snapshot.daily.first?.totalTokens == 205)
        #expect(abs((snapshot.daily.first?.costUSD ?? 0) - (nativeCost + piCost)) < 0.000001)
        #expect(snapshot.daily.first?.modelBreakdowns == [
            CostUsageDailyReport.ModelBreakdown(
                modelName: "claude-sonnet-4-6",
                costUSD: nativeCost + piCost,
                totalTokens: 205),
        ])
    }

    @Test
    func `fetcher prefers turn context model over token count fallback`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 10)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))

        let nativeTurnContext: [String: Any] = [
            "type": "turn_context",
            "timestamp": iso0,
            "payload": [
                "model": "openai/gpt-5.4",
            ],
        ]
        let nativeTokenCount: [String: Any] = [
            "type": "event_msg",
            "timestamp": iso1,
            "payload": [
                "type": "token_count",
                "info": [
                    "model": "gpt-5",
                    "total_token_usage": [
                        "input_tokens": 100,
                        "cached_input_tokens": 20,
                        "output_tokens": 10,
                    ],
                ],
            ],
        ]
        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "session.jsonl",
            contents: env.jsonl([nativeTurnContext, nativeTokenCount]))

        let nativeOptions = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        let piOptions = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0)

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            scannerOptions: nativeOptions,
            piScannerOptions: piOptions)
        let cost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.4",
            inputTokens: 100,
            cachedInputTokens: 20,
            outputTokens: 10) ?? 0

        let breakdown = try #require(snapshot.daily.first?.modelBreakdowns?.first)
        #expect(breakdown.modelName == "gpt-5.4")
        #expect(abs((breakdown.costUSD ?? 0) - cost) < 0.000001)
        #expect(breakdown.totalTokens == 110)
    }

    @Test
    func `app refresh bypasses scanner debounce without changing direct callers`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 11)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let iso2 = env.isoString(for: day.addingTimeInterval(2))
        let model = "openai/gpt-5.4"

        let turnContext: [String: Any] = [
            "type": "turn_context",
            "timestamp": iso0,
            "payload": ["model": model],
        ]
        let firstTokenCount: [String: Any] = [
            "type": "event_msg",
            "timestamp": iso1,
            "payload": [
                "type": "token_count",
                "info": [
                    "model": model,
                    "total_token_usage": [
                        "input_tokens": 100,
                        "cached_input_tokens": 20,
                        "output_tokens": 10,
                    ],
                ],
            ],
        ]
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "session.jsonl",
            contents: env.jsonl([turnContext, firstTokenCount]))

        let nativeOptions = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        let piOptions = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot)

        let first = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            scannerOptions: nativeOptions,
            piScannerOptions: piOptions)
        #expect(first.daily.first?.totalTokens == 110)

        let appendedTokenCount: [String: Any] = [
            "type": "event_msg",
            "timestamp": iso2,
            "payload": [
                "type": "token_count",
                "info": [
                    "model": model,
                    "total_token_usage": [
                        "input_tokens": 160,
                        "cached_input_tokens": 40,
                        "output_tokens": 16,
                    ],
                ],
            ],
        ]
        try env.jsonl([turnContext, firstTokenCount, appendedTokenCount])
            .write(to: fileURL, atomically: true, encoding: .utf8)

        let debounced = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            scannerOptions: nativeOptions,
            piScannerOptions: piOptions)
        #expect(debounced.daily.first?.totalTokens == 110)

        let refreshed = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            bypassScannerDebounce: true,
            scannerOptions: nativeOptions,
            piScannerOptions: piOptions)

        #expect(refreshed.daily.first?.totalTokens == 176)
    }

    private static func writeCodexSessionFile(
        homeRoot: URL,
        env: CostUsageTestEnvironment,
        day: Date,
        filename: String,
        tokens: Int) throws
    {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: day)
        let dir = homeRoot
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(String(format: "%04d", comps.year ?? 1970), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", comps.month ?? 1), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", comps.day ?? 1), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let model = "openai/gpt-5.4"
        let url = dir.appendingPathComponent(filename, isDirectory: false)
        try env.jsonl([
            [
                "type": "turn_context",
                "timestamp": env.isoString(for: day),
                "payload": ["model": model],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: day.addingTimeInterval(1)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "last_token_usage": [
                            "input_tokens": tokens,
                            "cached_input_tokens": 0,
                            "output_tokens": 0,
                        ],
                        "model": model,
                    ],
                ],
            ],
        ]).write(to: url, atomically: true, encoding: .utf8)
    }
}

extension CostUsageFetcherTests {
    @Test
    func `codex rolling 24 hour summary groups official and relay usage`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let now = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let recentDate = now.addingTimeInterval(-60 * 60)
        for (filename, sessionID, modelProvider, input, output) in [
            ("official.jsonl", "official-session", "openai", 50, 5),
            ("relay.jsonl", "relay-session", "codexbar_relay", 100, 10),
        ] {
            _ = try env.writeCodexSessionFile(
                day: recentDate,
                filename: filename,
                contents: env.jsonl([
                    [
                        "type": "session_meta",
                        "timestamp": env.isoString(for: recentDate),
                        "payload": [
                            "session_id": sessionID,
                            "model_provider": modelProvider,
                        ],
                    ],
                    [
                        "type": "event_msg",
                        "timestamp": env.isoString(for: recentDate),
                        "payload": [
                            "type": "token_count",
                            "info": [
                                "model": "openai/gpt-5.4",
                                "last_token_usage": [
                                    "input_tokens": input,
                                    "cached_input_tokens": 0,
                                    "output_tokens": output,
                                ],
                            ],
                        ],
                    ],
                ]))
        }

        let options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now,
            historyDays: 2,
            allowPricingRefresh: false,
            scannerOptions: options)

        #expect(snapshot.rolling24Hours?.totalTokens == 165)
        let breakdowns = snapshot.rolling24Hours?.modelProviderBreakdowns ?? []
        #expect(breakdowns.map(\.modelProvider) == ["codexbar_relay", "openai"])
        #expect(breakdowns.first(where: { $0.modelProvider == "codexbar_relay" })?.totalTokens == 110)
        #expect(breakdowns.first(where: { $0.modelProvider == "openai" })?.totalTokens == 55)
    }

    @Test
    func `codex rolling 24 hour summary excludes older event rows`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let now = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let oldDate = now.addingTimeInterval(-25 * 60 * 60)
        let recentDate = now.addingTimeInterval(-60 * 60)
        let oldURL = try env.writeCodexSessionFile(
            day: oldDate,
            filename: "old.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": env.isoString(for: oldDate),
                    "payload": ["session_id": "old-session"],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: oldDate),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "model": "openai/gpt-5.4",
                            "last_token_usage": [
                                "input_tokens": 500,
                                "cached_input_tokens": 0,
                                "output_tokens": 50,
                            ],
                        ],
                    ],
                ],
            ]))
        let recentURL = try env.writeCodexSessionFile(
            day: recentDate,
            filename: "recent.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": env.isoString(for: recentDate),
                    "payload": ["session_id": "recent-session"],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: recentDate),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "model": "openai/gpt-5.4",
                            "last_token_usage": [
                                "input_tokens": 100,
                                "cached_input_tokens": 20,
                                "output_tokens": 10,
                            ],
                        ],
                    ],
                ],
            ]))
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldURL.path)
        try FileManager.default.setAttributes([.modificationDate: recentDate], ofItemAtPath: recentURL.path)

        let options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        let piOptions = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0)
        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now,
            historyDays: 2,
            allowPricingRefresh: false,
            scannerOptions: options,
            piScannerOptions: piOptions)

        #expect(snapshot.rolling24Hours?.totalTokens == 110)
        #expect(snapshot.rolling24Hours?.costUSD != nil)
    }

    @Test
    func `fetcher returns individual codex conversations for the selected history window`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let firstURL = try env.writeCodexSessionFile(
            day: day,
            filename: "first.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": env.isoString(for: day),
                    "payload": ["session_id": "first-session"],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: day.addingTimeInterval(1)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "model": "openai/gpt-5.4",
                            "last_token_usage": [
                                "input_tokens": 100,
                                "cached_input_tokens": 20,
                                "output_tokens": 10,
                            ],
                        ],
                    ],
                ],
            ]))
        let secondURL = try env.writeCodexSessionFile(
            day: day,
            filename: "second.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": env.isoString(for: day),
                    "payload": ["session_id": "second-session"],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: day.addingTimeInterval(1)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "model": "openai/gpt-5.4",
                            "last_token_usage": [
                                "input_tokens": 40,
                                "cached_input_tokens": 5,
                                "output_tokens": 5,
                            ],
                        ],
                    ],
                ],
            ]))
        try FileManager.default.setAttributes(
            [.modificationDate: day.addingTimeInterval(10)],
            ofItemAtPath: firstURL.path)
        try FileManager.default.setAttributes(
            [.modificationDate: day.addingTimeInterval(20)],
            ofItemAtPath: secondURL.path)

        let options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        let piOptions = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0)
        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            historyDays: 1,
            allowPricingRefresh: false,
            scannerOptions: options,
            piScannerOptions: piOptions)

        #expect(snapshot.sessions.map(\.sessionID) == ["second-session", "first-session"])
        let first = try #require(snapshot.sessions.first(where: { $0.sessionID == "first-session" }))
        #expect(first.inputTokens == 100)
        #expect(first.cachedInputTokens == 20)
        #expect(first.outputTokens == 10)
        #expect(first.totalTokens == 110)
        #expect(first.requestCount == nil)
        #expect(first.modelBreakdowns.map(\.modelName) == ["gpt-5.4"])
        #expect(first.costUSD != nil)

        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        let unrelatedRoot = env.root.appendingPathComponent("unrelated/sessions", isDirectory: true)
        let filtered = CostUsageScanner.buildCodexSessionBreakdownsFromCache(
            cache: cache,
            range: range,
            modelsDevCacheRoot: env.cacheRoot,
            sessionRoots: [unrelatedRoot])
        #expect(filtered.isEmpty)
        let scopedCache = CostUsageScanner.codexCache(cache, scopedTo: [unrelatedRoot])
        #expect(scopedCache.files.isEmpty)
        #expect(scopedCache.days.isEmpty)
    }
}
